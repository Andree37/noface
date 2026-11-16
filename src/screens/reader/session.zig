//! An open book: its pages, where the reader is, and its highlights.
const std = @import("std");
const assert = std.debug.assert;
const page_store = @import("page_store.zig");
const paginate = @import("paginate.zig");
const check = @import("../../base/check.zig");
const Page = @import("../../gfx/page.zig").Page;
const book_model = @import("../../model/book.zig");
const note_rules = @import("../../model/notes.zig");
const stats = @import("../../model/stats.zig");
const bookmarks = @import("../../model/bookmarks.zig");
const icons = @import("../../ui/icons.zig");
const catalog = @import("../../model/catalog.zig");
const os = @import("../../sys/os.zig");
const cache = @import("../../layout/page_cache.zig");
const highlights = @import("../../model/highlights.zig");
const note_store = @import("note_store.zig");
const state = @import("../../sys/state.zig");
const text = @import("../../layout/text.zig");
const now_us = os.now_us;
const unix_time = os.unix_time;
const failed = os.failed;
const app = @import("../../app.zig");
const draw = @import("../../ui/draw.zig");
const Zone = @import("../../kindle/input.zig").Zone;

pub const Query = @import("../../model/search.zig").Query;

/// Turns from a jump after which the Back button goes: the reader is reading there.
const back_turns = 10;
/// The Back button, at the bottom left over the footer.
const back_x_px = 40;
const back_width_px = 330;
const back_height_px = 84;
const back_above_bottom_px = 112; // From the button's top to the screen's bottom
/// A fingertip's margin around the Back button, where a touch still counts.
const back_reach_px = 12;
/// The footer: the page number and time left, repainted alone when the count arrives.
const footer_height_px = 110;
const footer_baseline_above_bottom_px = 60;

comptime {
    assert(back_turns > 0);
    // The button and its fingertip margin stay on the screen, inside the footer
    assert(back_x_px >= back_reach_px);
    assert(back_above_bottom_px > back_height_px);
    assert(back_above_bottom_px <= footer_height_px + 8);
    assert(footer_baseline_above_bottom_px < footer_height_px);
}

pub const Session = struct {
    app: *app.App,
    paragraphs: []const book_model.Paragraph,
    pages: []const book_model.Pos,
    current: u32,
    /// What the reader is at. Settings changes keep to this, not the page edge.
    anchor: book_model.Pos,
    note_parts: [note_rules.max_note_parts]book_model.Paragraph = undefined,
    note_len: u32 = 0,
    note_top: u32 = 0,
    note_next: ?book_model.Pos = null,
    highlights: std.ArrayList(highlights.Highlight) = .empty,
    bookmarks: std.ArrayList(bookmarks.Bookmark) = .empty,
    /// What layout shades, rebuilt from highlights.
    marks: std.ArrayList(book_model.Mark) = .empty,
    pages_path: [:0]const u8 = "", // Where this book's page breaks are saved
    /// Where highlights and bookmarks are kept, chosen as the book opens.
    notes: note_store.NoteStore = .off,
    book_bytes: u64 = 0, // The book file's size, part of the saved breaks' key
    // A first open still being laid out: pages count from the reader's place until done
    progress: ?*paginate.Progressive = null,
    query: Query = .{}, // The last search, kept while the book is open
    chapters: []const book_model.Chapter = &.{},
    words_before: []const u64 = &.{}, // Words before each paragraph, for time left
    shown_us: ?u64 = null, // When the clock last started on this page; null while paused
    /// Where the reader was before jumping elsewhere (Go To, search, a chapter, the
    /// slider, a link): a Back button on the page returns there. The first place is
    /// kept through several jumps, and let go after `back_turns` turns from the jump.
    back: ?book_model.Pos = null,
    turns_since_jump: u32 = 0,
    turns: u32 = 0, // Pages shown, for a clean refresh every 20 when asked for
    turning: bool = false, // Set by a normal page turn, so `show` can tell it from a jump
    page_us: u64 = 0, // Time on the current page before that
    seconds_read: u64 = 0, // Time spent in this book, saved with the position

    /// How many pages there are so far: a page per break, which a book's paragraphs bound.
    pub fn page_count(s: *const Session) u32 {
        assert(s.pages.len > 0);
        assert(s.pages.len <= std.math.maxInt(u32));
        return @intCast(s.pages.len);
    }

    pub fn layout_pending(s: *const Session) bool {
        // A book has a page from the moment it opens, and the reader is on one
        assert(s.pages.len > 0);
        assert(s.current < s.pages.len);
        return s.progress != null;
    }

    /// One step of a layout running in the background, for an idle moment. Once the
    /// whole book is laid out, it takes over: page numbers count from the start and
    /// the breaks are saved. True when that just happened, so whatever is on screen
    /// can show the page count it was missing.
    pub fn layout_step(s: *Session) !bool {
        assert(s.current < s.pages.len);
        const p = s.progress orelse return false;
        try p.step(s.app);
        s.pages = p.pages();
        if (!p.done()) return false;
        const whole = try p.joined();
        s.pages = whole.pages;
        s.current += whole.before;
        s.progress = null;
        assert(s.current < s.pages.len);
        page_store.save(p.alloc, s.pages_path, page_store.key(s.app, s.book_bytes), s.pages);
        std.debug.print(
            "laid out in the background: {d} pages, {d} before the reader's place\n",
            .{ s.pages.len, whole.before },
        );
        s.app.forget_pages(); // Indexes moved, so pages drawn so far are stale
        return true;
    }

    /// Puts the page number on the page on screen once it's known: only the footer
    /// changes, so only it repaints.
    pub fn show_footer(s: *Session) !void {
        assert(s.current < s.pages.len);
        @memcpy(s.app.screen.pixels, try s.ensure(s.current, s.current));
        const footer_top = s.app.screen.height - footer_height_px;
        assert(footer_top < s.app.screen.height);
        try s.app.show_band(footer_top, s.app.screen.height - footer_top);
    }

    /// Lays out until page `index` exists, or the book ends, for turning on.
    pub fn layout_until(s: *Session, index: u32) !void {
        assert(s.current < s.pages.len);
        // Only turning on waits for pages: the ones before are there
        assert(index > s.current);
        while (s.progress) |p| {
            if (index < s.pages.len) return;
            if (p.forward_done()) return;
            _ = try s.layout_step();
        }
    }

    /// Finishes a first open's layout now, before anything that needs every page.
    /// Finishing forgets the pages drawn so far, so the one on screen is drawn again
    /// at once: what comes next hit-tests its words, links and highlights.
    pub fn finish_layout(s: *Session) !void {
        while (s.progress != null) _ = try s.layout_step();
        assert(s.progress == null);
        assert(s.current < s.pages.len);
        _ = try s.ensure(s.current, s.current);
    }

    /// Words from the start of the book to a position.
    pub fn words_at(s: *const Session, p: book_model.Pos) u64 {
        assert(s.words_before.len == s.paragraphs.len + 1);
        check.that(p.para < s.paragraphs.len, "position inside the book");
        check.that(p.para + 1 < s.words_before.len, "position inside the counted words");
        const para = s.paragraphs[p.para];
        if (para.note) return s.words_before[p.para];
        const before = para.text[0..@min(p.byte, para.text.len)];
        return s.words_before[p.para] + stats.count_words(before);
    }

    fn words_on_page(s: *const Session, index: u32) u64 {
        assert(index < s.pages.len);
        assert(s.words_before.len > 0);
        const total = s.words_before[s.words_before.len - 1];
        const end = if (s.page_end(index)) |e| s.words_at(e) else total;
        return end -| s.words_at(s.pages[index]);
    }

    /// Minutes left in the chapter and in the book from a page, once speed is known.
    pub fn time_left(s: *const Session, index: u32) struct { chapter: ?u64, book: ?u64 } {
        assert(index < s.pages.len);
        assert(s.words_before.len == s.paragraphs.len + 1);
        const here = s.words_at(s.pages[index]);
        const total = s.words_before[s.words_before.len - 1];
        var chapter_end: ?u64 = null;
        for (s.chapters) |c| {
            const at = s.words_before[c.para];
            if (at <= here) continue;
            if (chapter_end == null or at < chapter_end.?) chapter_end = at;
        }
        const speed = s.app.speed;
        const book_minutes = speed.minutes_for(total -| here);
        // Past the last chapter's start, the chapter runs to the book's end
        var chapter_minutes: ?u64 = null;
        if (chapter_end) |end| {
            assert(end > here);
            chapter_minutes = speed.minutes_for(end - here);
        } else if (s.chapters.len > 0) {
            chapter_minutes = book_minutes;
        }
        return .{ .chapter = chapter_minutes, .book = book_minutes };
    }

    /// Adds the time since the clock last started to the current page's reading time.
    fn tick(s: *Session) void {
        const shown = s.shown_us orelse return; // Paused: nothing to add
        const page_us_before = s.page_us;
        const now = now_us();
        s.page_us += now -| shown;
        s.shown_us = now;
        assert(s.page_us >= page_us_before);
    }

    /// The page being left: its time goes to the book, and a page read forward teaches
    /// the reading speed. Time on it adds up across footnotes, menus and sleep, so a
    /// page read in two sittings counts as one page read in the time of both.
    fn leave_page(s: *Session, to: u32) void {
        assert(to < s.pages.len);
        assert(s.current < s.pages.len);
        s.tick();
        const us = s.page_us;
        s.page_us = 0;
        const counted = stats.counted_seconds(us / 1_000_000);
        s.seconds_read += counted;
        // The day's journal: the time, and the page when it was read on to the next
        const read_on = to == s.current + 1 and counted > 0;
        const journal_seconds: u32 = @intCast(@min(counted, std.math.maxInt(u32)));
        s.app.journal.add(s.app.today(), journal_seconds, if (read_on) 1 else 0);
        if (to != s.current + 1 or us == 0) return;
        const left = s.current;
        // Time on a picture isn't reading speed
        if (s.page_has_picture(left)) return;
        const speed = &s.app.speed;
        const was_known = speed.known();
        speed.record(s.words_on_page(left), us);
        // Pages already drawn have no time left on them yet.
        if (!was_known and speed.known()) s.app.forget_pages();
    }

    fn page_has_picture(s: *const Session, index: u32) bool {
        assert(index < s.pages.len);
        const first = s.pages[index].para;
        const last = if (s.page_end(index)) |e| e.para else s.paragraphs.len - 1;
        // Pages only move forward
        assert(first <= last);
        for (s.paragraphs[first .. @min(last, s.paragraphs.len - 1) + 1]) |p| {
            if (p.image != null) return true;
        }
        return false;
    }

    /// Reading time so far, with the page in front of the reader.
    pub fn seconds_read_total(s: *Session) u64 {
        s.tick();
        const total = s.seconds_read + stats.counted_seconds(s.page_us / 1_000_000);
        assert(total >= s.seconds_read);
        return total;
    }

    /// Stops the reading clock while something covers the page, or the Kindle sleeps.
    pub fn pause_clock(s: *Session) void {
        assert(s.current < s.pages.len);
        s.tick();
        s.shown_us = null;
    }

    /// Starts the clock again when the page is back in front of the reader.
    pub fn resume_clock(s: *Session) void {
        assert(s.current < s.pages.len);
        if (s.shown_us == null) s.shown_us = now_us();
    }

    /// Where a page ends: the next page's start, or null on the last page.
    pub fn page_end(s: *const Session, index: u32) ?book_model.Pos {
        assert(index < s.pages.len);
        if (index + 1 >= s.pages.len) return null;
        const end = s.pages[index + 1];
        assert(is_before(s.pages[index], end));
        return end;
    }

    pub fn is_bookmarked(s: *const Session, index: u32) bool {
        assert(index < s.pages.len);
        assert(s.pages.len > 0);
        return bookmarks.any_on_page(s.bookmarks.items, s.pages[index], s.page_end(index));
    }

    /// Every move to another page comes through here, so reading time stays right.
    pub fn set_page(s: *Session, index: u32) void {
        check.thatf(index < s.pages.len, "page {d} of {d}", .{ index, s.pages.len });
        s.note_jump(index);
        s.leave_page(index);
        s.current = index;
        s.anchor = s.pages[index];
        if (s.shown_us != null) s.shown_us = now_us();
        assert(s.current == index);
    }

    /// The picture at a point on the page on screen, if any. The page is drawn again
    /// first if its drawing was dropped (a finished layout forgets them all).
    pub fn picture_at(s: *Session, x: i32, y: i32) !?book_model.Image {
        _ = try s.ensure(s.current, s.current);
        const slot = s.app.slot_for(s.current) orelse return null;
        // Just drawn: the slot holds the page on screen
        assert(slot.page.? == s.current); // Found by its page
        const para = slot.hits.picture_at(x, y) orelse return null;
        assert(para < s.paragraphs.len); // Set by layout, from this book's paragraphs
        return s.paragraphs[para].image;
    }

    pub fn reference_at(s: *Session, x: i32, y: i32) ?u32 {
        assert(s.current < s.pages.len);
        const slot = s.app.slot_for(s.current) orelse return null;
        assert(slot.page.? == s.current); // Found by its page
        return slot.hits.find(x, y);
    }

    /// Keeps the Back button's place up to date for a move to page `index`: a jump
    /// remembers where the reader was (unless an earlier jump's place is still kept),
    /// arriving back there lets go of it, and so does reading on a while.
    fn note_jump(s: *Session, index: u32) void {
        assert(index < s.pages.len);
        assert(s.current < s.pages.len);
        const turning = s.turning;
        s.turning = false;
        const before = s.back;
        // Page numbers are only final once the whole book is laid out: until then an
        // earlier place would look like page 0, so nothing is let go of
        const settled = s.progress == null;
        if (s.back) |b| {
            if (settled and page_containing(s.pages, b.para, b.byte) == index) {
                s.back = null; // Back where they were, however they got there
            } else if (index == s.current) {
                // Drawn again in place: nothing moved
            } else if (turning) {
                s.turns_since_jump += 1;
                if (s.turns_since_jump >= back_turns) s.back = null; // Reading here now
            } else {
                s.turns_since_jump = 0; // Another jump: the count starts again from here
            }
        } else if (!turning and index != s.current) {
            s.back = s.pages[s.current];
            s.turns_since_jump = 0;
        }
        // Pages are kept drawn with the button on or off: draw them again
        if ((before == null) != (s.back == null)) s.app.forget_pages();
    }

    /// The Back button's place on the page: the bottom left, over the footer.
    pub fn back_rect(s: *const Session) struct { x: u32, y: u32, width: u32, height: u32 } {
        assert(s.app.screen.height > back_above_bottom_px);
        assert(s.app.screen.width > back_x_px + back_width_px);
        return .{
            .x = back_x_px,
            .y = s.app.screen.height - back_above_bottom_px,
            .width = back_width_px,
            .height = back_height_px,
        };
    }

    /// Where touches count as the Back button although the thumb filter is on there:
    /// its rectangle and a fingertip around it. Null with no button.
    pub fn back_zone(s: *const Session) ?Zone {
        if (s.back == null) return null;
        const r = s.back_rect();
        assert(r.x >= back_reach_px);
        assert(r.y >= back_reach_px);
        return .{
            .x = @as(i32, @intCast(r.x)) - back_reach_px,
            .y = @as(i32, @intCast(r.y)) - back_reach_px,
            .w = @intCast(r.width + 2 * back_reach_px),
            .h = @intCast(r.height + 2 * back_reach_px),
        };
    }

    pub fn on_back(s: *const Session, x: i32, y: i32) bool {
        if (s.back == null) return false;
        const r = s.back_rect();
        assert(r.width > 0);
        assert(r.height > 0);
        // A fingertip's margin around it
        const left = @as(i32, @intCast(r.x)) - back_reach_px;
        const right = @as(i32, @intCast(r.x + r.width)) + back_reach_px;
        const top = @as(i32, @intCast(r.y)) - back_reach_px;
        const bottom = @as(i32, @intCast(r.y + r.height)) + back_reach_px;
        return x >= left and x < right and y >= top and y < bottom;
    }

    /// The page the Back button returns to.
    pub fn back_page(s: *const Session) ?u32 {
        const b = s.back orelse return null;
        const index = page_containing(s.pages, b.para, b.byte);
        assert(index < s.pages.len);
        return index;
    }

    fn draw_back(s: *const Session, page: Page) !void {
        // Drawn only while there's somewhere to go back to
        assert(s.back != null);
        const a = s.app;
        const r = s.back_rect();
        assert(r.y >= 8);
        // Over the footer's text there
        page.fill_rect(0, r.y - 8, r.x + r.width + 24, a.screen.height - (r.y - 8), 0xff);
        draw.box(page, r.x, r.y, r.width, r.height);
        var label_buffer: [32]u8 = undefined;
        // The page number only once the whole book is laid out
        const back_number = (s.back_page() orelse 0) + 1;
        var label: []const u8 = "Back";
        if (s.progress == null) {
            label = std.fmt.bufPrint(&label_buffer, "Back to p. {d}", .{back_number}) catch "Back";
        }
        const center_y: f32 = @floatFromInt(r.y + r.height / 2);
        icons.back(page, @floatFromInt(r.x + 44), center_y);
        try a.ui.small.draw(page, @floatFromInt(r.x + 80), @intFromFloat(center_y + 12), label);
    }

    /// "12 min left in chapter" on the left of the footer, the book's on the right.
    fn draw_time_left(s: *const Session, page: Page, index: u32) !void {
        assert(index < s.pages.len);
        assert(s.app.settings.time_left); // Only drawn when asked for
        const a = s.app;
        const left = s.time_left(index);
        const y: i32 = @intCast(a.screen.height - footer_baseline_above_bottom_px);
        const margin: f32 = @floatFromInt(a.layout.margin_x);
        var minutes_buffer: [48]u8 = undefined;
        var line: [64]u8 = undefined;
        // The Back button takes the left side while it's there
        if (left.chapter) |m| if (s.back == null) {
            const minutes = stats.format_minutes(&minutes_buffer, m);
            const t = std.fmt.bufPrint(&line, "{s} left in chapter", .{minutes}) catch "";
            try a.footer.draw(page, margin, y, t);
        };
        // Like the Kindle, say so while the speed is still being learned rather than guess.
        var t: []const u8 = "Learning reading speed";
        if (left.book) |m| {
            const minutes = stats.format_minutes(&minutes_buffer, m);
            t = std.fmt.bufPrint(&line, "{s} left in book", .{minutes}) catch "";
        }
        const right: f32 = @as(f32, @floatFromInt(a.screen.width)) - margin;
        try a.footer.draw(page, right - try a.footer.measure(t), y, t);
    }

    /// Get a rendered page, reusing a cached one when possible.
    pub fn ensure(s: *Session, index: u32, center: u32) ![]const u8 {
        check.thatf(index < s.pages.len, "page {d} of {d}", .{ index, s.pages.len });
        check.thatf(center < s.pages.len, "page {d} of {d}", .{ center, s.pages.len });
        const a = s.app;
        if (a.slot_for(index)) |slot| return slot.buf;
        var cached: [3]?u32 = undefined;
        for (&a.slots, &cached) |*slot, *c| c.* = slot.page;
        const victim = cache.victim(cached, center);
        assert(victim < a.slots.len);
        const buf = a.slots[victim].buf;
        const page = a.page(buf);
        a.slots[victim].hits.clear();
        const hits = &a.slots[victim].hits;
        _ = try text.render_page(a.body, page, s.paragraphs, s.pages[index], a.layout, hits);

        var label: [32]u8 = undefined;
        // Left out until the whole book is laid out, rather than a wrong number
        var counter: []const u8 = "";
        if (s.progress == null) {
            counter = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, s.pages.len }) catch "";
        }
        const x = @as(f32, @floatFromInt(a.screen.width)) / 2 - 50;
        const y: i32 = @intCast(a.screen.height - footer_baseline_above_bottom_px);
        try a.footer.draw(page, x, y, counter);
        if (s.is_bookmarked(index)) icons.ribbon(page, a.screen.width);
        if (a.settings.time_left) try s.draw_time_left(page, index);
        if (s.back != null) try s.draw_back(page);

        a.slots[victim].page = index;
        assert(a.slot_for(index).? == &a.slots[victim]);
        return buf;
    }

    pub fn show(s: *Session, index: u32, touched_us: ?u64, force_clean: bool) !void {
        const a = s.app;
        s.set_page(index);
        assert(s.current == index);
        const buf = try s.ensure(index, index);
        @memcpy(a.screen.pixels, buf);
        a.stamp_clock();
        s.turns += 1;
        const clean = force_clean or (a.settings.refresh and s.turns % 20 == 0);
        const marker = try a.screen.show(if (clean) .flash else .page);
        const queued = now_us();
        try a.screen.wait_complete(marker);
        const done = now_us();
        if (touched_us) |t| {
            std.debug.print("turn to {d}: touch to queued {d} us, touch to done {d} ms{s}\n", .{
                index + 1, queued -| t, (done -| t) / 1000, if (clean) " (clean)" else "",
            });
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < s.pages.len) _ = try s.ensure(index + 1, index);
        if (index > 0) _ = try s.ensure(index - 1, index);
        assert(s.current == index);
    }
};

/// Whether `first` comes strictly before `second` in the book.
fn is_before(first: book_model.Pos, second: book_model.Pos) bool {
    if (first.para != second.para) return first.para < second.para;
    return first.byte < second.byte;
}

pub fn save_progress(entry: *catalog.Entry, path: [*:0]const u8, s: *Session) void {
    assert(s.current < s.pages.len);
    s.pause_clock(); // The reader's loop starts it again
    const seconds = s.seconds_read_total();
    const pos = s.pages[s.current];
    // While a first open is laid out, the page count isn't known: keep the last percent
    var percent: u32 = entry.percent;
    if (s.progress == null) {
        percent = @intCast((s.current + 1) * 100 / s.pages.len);
        assert(percent <= 100);
    }
    const now = unix_time();
    // Changed in place, so anything else kept with the place is kept too
    var saved = state.load(path);
    saved.para = book_model.text_index(s.paragraphs, pos.para);
    saved.byte = pos.byte;
    saved.percent = percent;
    saved.opened = now;
    saved.seconds = seconds;
    saved.finished = entry.finished;
    saved.back_para = if (s.back) |b| book_model.text_index(s.paragraphs, b.para) else null;
    saved.back_byte = if (s.back) |b| b.byte else 0;
    saved.back_turns = s.turns_since_jump;
    state.save(path, saved);
    app.save_speed(s.app);
    app.save_journal(s.app);
    entry.percent = percent;
    entry.last = now;
    entry.seconds_read = seconds;
}

pub fn page_containing(pages: []const book_model.Pos, para: u32, byte: u32) u32 {
    assert(pages.len > 0);
    assert(pages.len <= std.math.maxInt(u32));
    var found: u32 = 0;
    for (pages, 0..) |p, i| {
        if (p.para < para or (p.para == para and p.byte <= byte)) found = @intCast(i);
    }
    assert(found < pages.len);
    return found;
}

/// Where a session's pages point while a layout that failed partway had let go of the
/// old ones: the book's start, a page that always exists.
const pages_fallback = [_]book_model.Pos{.{}};

/// Re-lays out the book after a text setting changed, keeping the reading position.
/// The new pages go in the pages region, emptied first: the pages of the last change,
/// and of a layout still running for it, are no longer wanted, so changing settings
/// again and again takes no more memory.
pub fn relayout(a: *app.App, s: *Session) !void {
    assert(s.current < s.pages.len);
    assert(a.pages_budget.region.?.kind == .bump);
    a.apply_settings() catch |err| {
        std.debug.print("settings failed: {s}\n", .{@errorName(err)});
        a.settings = app.load_settings(a.settings_path);
        return a.apply_settings();
    };
    app.save_settings(a.settings_path, a.settings);
    a.forget_pages();
    const t0 = now_us();
    const pages_key = page_store.key(a, s.book_bytes);
    const paragraph_count: u32 = @intCast(s.paragraphs.len);
    s.progress = null; // A layout still running was for the old settings
    s.pages = &pages_fallback;
    s.current = 0;
    a.pages_budget.reset(.keep);
    const alloc = a.pages_budget.allocator();
    const stored = page_store.load(alloc, s.pages_path, pages_key, paragraph_count);
    if (stored) |pages| {
        s.pages = pages;
        s.current = page_containing(s.pages, s.anchor.para, s.anchor.byte);
    } else {
        // The reader's page at once, laid out from its first word with the new
        // settings; the rest follows in idle moments, as on a first open
        const p = try alloc.create(paginate.Progressive);
        // The anchor starts the page that was on screen, so a page is laid out from it
        p.* = (try paginate.Progressive.start(a, alloc, s.paragraphs, s.anchor)).?;
        s.progress = p;
        s.pages = p.pages();
        s.current = 0;
    }
    assert(s.pages.len > 0);
    assert(s.current < s.pages.len);
    std.debug.print("relayout {s} in {d} ms\n", .{
        if (stored != null) "from saved pages" else "first pages",
        (now_us() - t0) / 1000,
    });
    std.debug.print("relayout: page {d} of {d}, anchor {d}:{d}\n", .{
        s.current + 1,
        s.pages.len,
        s.anchor.para,
        s.anchor.byte,
    });
}
