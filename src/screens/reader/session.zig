//! An open book: its pages, where the reader is, and its highlights.
const std = @import("std");
const assert = std.debug.assert;
const page_store = @import("page_store.zig");
const paginate = @import("paginate.zig");
const check = @import("../../base/check.zig");
const Page = @import("../../gfx/page.zig").Page;
const book_model = @import("../../model/book.zig");
const stats = @import("../../model/stats.zig");
const settings_model = @import("../../model/settings.zig");
const Words = @import("words.zig").Words;
const bookmarks = @import("../../model/bookmarks.zig");
const icons = @import("../../ui/icons.zig");
const catalog = @import("../../model/catalog.zig");
const os = @import("../../sys/os.zig");
const state = @import("../../sys/state.zig");
const text = @import("../../layout/text.zig");
const now_us = os.now_us;
const unix_time = os.unix_time;
const app = @import("../../app.zig");
const display = @import("../../display.zig");
const style = @import("../../ui/style.zig");
const Zone = @import("../../kindle/input.zig").Zone;
const back_button = @import("back_button.zig");
const reading_clock = @import("reading_clock.zig");
const book_notes = @import("book_notes.zig");
const hwtcon = @import("../../kindle/hwtcon.zig");

/// The page counter in the footer's middle: its left, this far left of the middle.
const counter_left_of_middle_px = 50;
/// The footer: the page number and time left, repainted alone when the count arrives.
const footer_height_px = 110;
const footer_baseline_above_bottom_px = 60;

comptime {
    assert(footer_baseline_above_bottom_px < footer_height_px);
    // The Back button sits in the footer, its clearing over the footer's top at most
    assert(back_button.above_bottom_px <= footer_height_px + back_button.clear_above_px);
    assert(counter_left_of_middle_px < style.screen.width_px / 2);
}

/// How the reader got to a page (back_button.zig).
pub const Move = back_button.Move;

pub const Session = struct {
    app: *app.App,
    paragraphs: []const book_model.Paragraph,
    pages: []const book_model.Pos,
    current: u32,
    /// Whether a page read forward teaches the reader's speed: not while running mode
    /// moves on at its own pace (reader/run.zig).
    learns_speed: bool = true,
    /// What the reader is at. Settings changes keep to this, not the page edge.
    anchor: book_model.Pos,
    /// Highlights and bookmarks, and where they are kept.
    notes: book_notes.BookNotes = .{},
    pages_path: [:0]const u8 = "", // Where this book's page breaks are saved
    book_bytes: u64 = 0, // The book file's size, part of the saved breaks' key
    // A first open still being laid out: pages count from the reader's place until done
    progress: ?*paginate.Progressive = null,
    chapters: []const book_model.Chapter = &.{},
    words: Words = .{}, // Counted as the book opens, for time left and the speed
    clock: reading_clock.Clock = .{},
    /// Where the reader was before jumping elsewhere, for the Back button.
    back: back_button.Back = .{},
    turns: u32 = 0, // Pages shown, for the clean refresh (`settings_model.clean_every_pages`)

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
    /// can show the page count it was missing. Taking over forgets the pages drawn so
    /// far, so the one on screen is drawn again at once: whatever is over it (a
    /// highlight's handles, a tap on a link) hit-tests its words.
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
        s.app.display.forget_pages(); // Indexes moved, so pages drawn so far are stale
        _ = try s.ensure(s.current, s.current);
        return true;
    }

    /// Puts the page number on the page on screen once it's known: only the footer
    /// changes, so only it repaints.
    pub fn show_footer(s: *Session) !void {
        assert(s.current < s.pages.len);
        @memcpy(s.app.display.screen.pixels, try s.ensure(s.current, s.current));
        const footer_top = s.app.display.screen.height - footer_height_px;
        assert(footer_top < s.app.display.screen.height);
        try s.app.display.show_band(footer_top, s.app.display.screen.height - footer_top);
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
    pub fn finish_layout(s: *Session) !void {
        while (s.progress != null) _ = try s.layout_step();
        assert(s.progress == null);
        assert(s.current < s.pages.len);
    }

    /// Words from the start of the book to a position.
    fn words_on_page(s: *const Session, index: u32) u64 {
        assert(index < s.pages.len);
        const end = if (s.page_end(index)) |e| s.words.at(s.paragraphs, e) else s.words.total();
        return end -| s.words.at(s.paragraphs, s.pages[index]);
    }

    /// Minutes left in the chapter and in the book from a page, once speed is known.
    pub fn time_left(s: *const Session, index: u32) struct { chapter: ?u64, book: ?u64 } {
        assert(index < s.pages.len);
        const here = s.words.at(s.paragraphs, s.pages[index]);
        const speed = s.app.user.speed;
        const book_minutes = speed.minutes_for(s.words.total() -| here);
        // Past the last chapter's start, the chapter runs to the book's end
        const chapter_minutes: ?u64 = if (s.chapters.len == 0)
            null
        else
            speed.minutes_for(s.words.chapter_left(s.chapters, here));
        return .{ .chapter = chapter_minutes, .book = book_minutes };
    }

    /// The words from `at` to its chapter's end, for running's minutes left
    /// (reader/run.zig). A book without chapters is one.
    pub fn chapter_words_left(s: *const Session, at: book_model.Pos) u64 {
        return s.words.chapter_left(s.chapters, s.words.at(s.paragraphs, at));
    }

    /// The page being left: its time goes to the book and the day's journal, and a
    /// page read forward teaches the reading speed.
    fn leave_page(s: *Session, to: u32) void {
        assert(to < s.pages.len);
        assert(s.current < s.pages.len);
        const left_page = s.clock.leave_page(now_us());
        const us = left_page.us;
        const counted = left_page.counted_seconds;
        // The day's journal: the time, and the page when it was read on to the next
        const read_on = to == s.current + 1 and counted > 0;
        const journal_seconds: u32 = @intCast(@min(counted, std.math.maxInt(u32)));
        s.app.user.journal.add(s.app.today(), journal_seconds, if (read_on) 1 else 0);
        if (to != s.current + 1 or us == 0) return;
        // Pages gone past by running mode take its pace's time, which says nothing of
        // the reader's speed in the hand
        if (!s.learns_speed) return;
        const left = s.current;
        // Time on a picture isn't reading speed
        if (s.page_has_picture(left)) return;
        const speed = &s.app.user.speed;
        const was_known = speed.known();
        speed.record(s.words_on_page(left), us);
        // Pages already drawn have no time left on them yet.
        if (!was_known and speed.known()) s.app.display.forget_pages();
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
        assert(s.current < s.pages.len);
        return s.clock.seconds_total(now_us());
    }

    /// Stops the reading clock while something covers the page, or the Kindle sleeps.
    pub fn pause_clock(s: *Session) void {
        assert(s.current < s.pages.len);
        s.clock.stop(now_us());
    }

    /// Starts the clock again when the page is back in front of the reader.
    pub fn resume_clock(s: *Session) void {
        assert(s.current < s.pages.len);
        s.clock.start(now_us());
    }

    /// How far into the book the reader's page is, in percent, or null while a first
    /// open is still laid out and the page count isn't known.
    pub fn percent(s: *const Session) ?u32 {
        assert(s.current < s.pages.len);
        if (s.progress != null) return null;
        const through: u32 = @intCast((@as(u64, s.current) + 1) * 100 / s.pages.len);
        assert(through <= 100);
        return through;
    }

    /// Where a page ends: the next page's start, or null on the last page.
    pub fn page_end(s: *const Session, index: u32) ?book_model.Pos {
        assert(index < s.pages.len);
        if (index + 1 >= s.pages.len) return null;
        const end = s.pages[index + 1];
        assert(s.pages[index].is_before(end));
        return end;
    }

    /// The words of the current page as it was drawn, where each is on the screen:
    /// none while it isn't drawn.
    pub fn page_words(s: *const Session) []const book_model.Word {
        assert(s.current < s.pages.len);
        const slot = s.app.display.slot_for(s.current) orelse return &.{};
        assert(slot.hits.word_count <= slot.hits.words.len);
        return slot.hits.words[0..slot.hits.word_count];
    }

    /// The reader's place moved to `at` by itself, as running mode moves on: the page
    /// holding it becomes the current one, page by page, so the reading time and the
    /// journal count as turning does, and the place is `at`, more exactly than its
    /// page's start. Returns how many pages it went on.
    pub fn follow(s: *Session, at: book_model.Pos) !u32 {
        assert(at.para < s.paragraphs.len);
        // On a first open, the pages ahead may not be laid out yet
        if (s.layout_pending()) try s.layout_until(s.current + 2);
        var forward: u32 = 0;
        // Each turn moves a page: bounded by the pages
        for (0..s.pages.len) |_| {
            if (s.current + 1 < s.pages.len and !at.is_before(s.pages[s.current + 1])) {
                s.set_page(s.current + 1, .turn);
                forward += 1;
            } else if (s.current > 0 and at.is_before(s.pages[s.current])) {
                s.set_page(s.current - 1, .turn);
            } else break;
        }
        assert(!at.is_before(s.pages[s.current]) or s.current == 0);
        s.anchor = at;
        return forward;
    }

    pub fn is_bookmarked(s: *const Session, index: u32) bool {
        assert(index < s.pages.len);
        assert(s.pages.len > 0);
        return bookmarks.any_on_page(s.notes.bookmarks.items, s.pages[index], s.page_end(index));
    }

    /// Starts showing a full-width band of the screen where the page on screen is put
    /// back or covered (the toolbar's bars, a note's panel), and returns the update.
    pub fn show_band(s: *const Session, top: u32, height: u32) !u32 {
        const a = s.app;
        assert(height > 0);
        assert(top + height <= a.display.screen.height);
        return a.display.screen.show_region(0, top, a.display.screen.width, height, .page);
    }

    /// Every move to another page comes through here, so reading time stays right.
    pub fn set_page(s: *Session, index: u32, move: Move) void {
        check.thatf(index < s.pages.len, "page {d} of {d}", .{ index, s.pages.len });
        const settled = s.progress == null;
        // Pages are kept drawn with the button on or off: draw them again
        const back_changed = s.back.note_move(s.pages, s.current, index, move, settled);
        if (back_changed) s.app.display.forget_pages();
        s.leave_page(index);
        s.current = index;
        s.anchor = s.pages[index];
        assert(s.current == index);
    }

    /// The picture at a point on the page on screen, if any. The page is drawn again
    /// first if its drawing was dropped (a finished layout forgets them all).
    pub fn picture_at(s: *Session, x: i32, y: i32) !?book_model.Image {
        _ = try s.ensure(s.current, s.current);
        const slot = s.app.display.slot_for(s.current) orelse return null;
        // Just drawn: the slot holds the page on screen
        assert(slot.page.? == s.current); // Found by its page
        const para = slot.hits.picture_at(x, y) orelse return null;
        assert(para < s.paragraphs.len); // Set by layout, from this book's paragraphs
        return s.paragraphs[para].image;
    }

    pub fn reference_at(s: *Session, x: i32, y: i32) ?u32 {
        assert(s.current < s.pages.len);
        const slot = s.app.display.slot_for(s.current) orelse return null;
        assert(slot.page.? == s.current); // Found by its page
        return slot.hits.find(x, y);
    }

    /// Where touches count as the Back button although the thumb filter is on there.
    pub fn back_zone(s: *const Session) ?Zone {
        assert(s.current < s.pages.len);
        return s.back.zone(s.app.display.screen.height);
    }

    pub fn on_back(s: *const Session, x: i32, y: i32) bool {
        assert(s.current < s.pages.len);
        return s.back.hit(s.app.display.screen.height, x, y);
    }

    /// The page the Back button returns to.
    pub fn back_page(s: *const Session) ?u32 {
        assert(s.current < s.pages.len);
        return s.back.page(s.pages);
    }

    /// "12 min left in chapter" on the left of the footer, the book's on the right.
    fn draw_time_left(s: *const Session, page: Page, index: u32) !void {
        assert(index < s.pages.len);
        assert(s.app.user.settings.time_left); // Only drawn when asked for
        const a = s.app;
        const left = s.time_left(index);
        const y: i32 = @intCast(a.display.screen.height - footer_baseline_above_bottom_px);
        const margin: f32 = @floatFromInt(a.layout.margin_x);
        var minutes_buffer: [48]u8 = undefined;
        var line: [64]u8 = undefined;
        // The Back button takes the left side while it's there
        if (left.chapter) |m| if (s.back.place == null) {
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
        const right: f32 = @as(f32, @floatFromInt(a.display.screen.width)) - margin;
        try a.footer.draw(page, right - try a.footer.measure(t), y, t);
    }

    /// Get a rendered page, reusing a cached one when possible.
    pub fn ensure(s: *Session, index: u32, center: u32) ![]const u8 {
        check.thatf(index < s.pages.len, "page {d} of {d}", .{ index, s.pages.len });
        check.thatf(center < s.pages.len, "page {d} of {d}", .{ center, s.pages.len });
        const a = s.app;
        if (a.display.slot_for(index)) |slot| return slot.buf;
        const slot = a.display.begin_draw(index, center);
        const buf = slot.buf;
        const page = a.display.page(buf);
        const hits = &slot.hits;
        // Drawn to end where the next page starts, as it was laid out: the page before
        // the reader's place was cut short there, and would otherwise run on into it
        var layout = a.layout;
        layout.stop = s.page_end(index);
        _ = try text.render_page(a.body, page, s.paragraphs, s.pages[index], &layout, hits);

        var label: [32]u8 = undefined;
        // Left out until the whole book is laid out, rather than a wrong number
        var counter: []const u8 = "";
        if (s.progress == null) {
            counter = std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, s.pages.len }) catch "";
        }
        const x = @as(f32, @floatFromInt(a.display.screen.width / 2 - counter_left_of_middle_px));
        const y: i32 = @intCast(a.display.screen.height - footer_baseline_above_bottom_px);
        try a.footer.draw(page, x, y, counter);
        if (s.is_bookmarked(index)) icons.ribbon(page, a.display.screen.width);
        if (a.user.settings.time_left) try s.draw_time_left(page, index);
        if (s.back.place != null) {
            try s.back.draw_on(page, a.ui.small, s.pages, s.progress == null);
        }

        a.display.end_draw(slot, index);
        return buf;
    }

    /// The page the reader is on, drawn, lent from the page cache to a sheet drawn over
    /// it. It stays that page while the sheet is open, as nothing under a sheet draws
    /// another page there; if something did, the sheet's next use of it stops on it.
    pub fn lend_current(s: *Session) !display.Backdrop {
        const pixels = try s.ensure(s.current, s.current);
        const a = s.app;
        for (&a.display.slots, 0..) |*slot, i| {
            if (slot.buf.ptr != pixels.ptr) continue;
            assert(slot.page == s.current);
            return .{ .pixels = pixels, .lent = .{ .slot = @intCast(i), .drawn = slot.drawn } };
        }
        unreachable; // `ensure` gives back one of the slots' pixels
    }

    pub fn show(s: *Session, index: u32, move: Move, touched_us: ?u64, force_clean: bool) !void {
        const a = s.app;
        s.set_page(index, move);
        assert(s.current == index);
        const buf = try s.ensure(index, index);
        @memcpy(a.display.screen.pixels, buf);
        a.stamp_clock();
        s.turns += 1;
        const due = s.turns % settings_model.clean_every_pages == 0;
        const clean = force_clean or (a.user.settings.refresh and due);
        const refresh: hwtcon.Refresh = if (clean) .flash else .page;
        const marker = try a.display.screen.show(refresh);
        const queued = now_us();
        try a.display.screen.wait_complete(marker);
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

/// Saves the reader's place, `s.anchor`, which stays what they're at even while the
/// pages are being laid out again or failed to be. `percent` is how far in they are,
/// or null to keep the one saved: the pages don't say (see `Session.percent`).
pub fn save_progress(
    entry: *catalog.Entry,
    path: [*:0]const u8,
    s: *Session,
    percent_read: ?u32,
) void {
    assert(s.current < s.pages.len);
    assert(s.anchor.para < s.paragraphs.len);
    s.pause_clock(); // The reader's loop starts it again
    const seconds = s.seconds_read_total();
    const pos = s.anchor;
    if (percent_read) |p| assert(p <= 100);
    const percent = percent_read orelse entry.percent;
    const now = unix_time();
    // Changed in place, so anything else kept with the place is kept too
    var saved = state.load(path);
    saved.para = book_model.text_index(s.paragraphs, pos.para);
    saved.byte = pos.byte;
    saved.percent = percent;
    saved.opened = now;
    saved.seconds = seconds;
    saved.finished = entry.finished;
    const back = s.back.place;
    saved.back_para = if (back) |b| book_model.text_index(s.paragraphs, b.para) else null;
    saved.back_byte = if (back) |b| b.byte else 0;
    saved.back_turns = s.back.turns_since_jump;
    state.save(path, saved);
    s.app.user.save_speed();
    s.app.user.save_journal();
    entry.percent = percent;
    entry.last = now;
    entry.seconds_read = seconds;
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
    assert(a.regions.pages_budget.region.?.kind == .bump);
    a.apply_settings() catch |err| {
        std.debug.print("settings failed: {s}\n", .{@errorName(err)});
        a.user.settings = a.user.saved_settings();
        return a.apply_settings();
    };
    a.user.save_settings();
    a.display.forget_pages();
    const t0 = now_us();
    const pages_key = page_store.key(a, s.book_bytes);
    s.progress = null; // A layout still running was for the old settings
    s.pages = &pages_fallback;
    s.current = 0;
    a.regions.pages_budget.reset(.keep);
    const alloc = a.regions.pages_budget.allocator();
    const stored = page_store.load(alloc, s.pages_path, pages_key, s.paragraphs);
    if (stored) |pages| {
        s.pages = pages;
        s.current = book_model.page_containing(s.pages, s.anchor.para, s.anchor.byte);
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
