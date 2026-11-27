//! An open book: its pages, where the reader is, and its highlights.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../../text/line.zig").of;
const page_store = @import("page_store.zig");
const hyphen = @import("../../layout/hyphen.zig");
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
const platform = @import("../../platform.zig");
const file = @import("../../sys/file.zig");
const text = @import("../../layout/text.zig");
const now_us = os.now_us;
const unix_time = os.unix_time;
const app = @import("../../app.zig");
const display = @import("../../display.zig");
const style = @import("../../ui/style.zig");
const Zone = @import("../../kindle/input.zig").Zone;
const back_button = @import("back_button.zig");
const placed = @import("../placed.zig");
const reading_clock = @import("reading_clock.zig");
const book_notes = @import("book_notes.zig");
const hwtcon = @import("../../kindle/hwtcon.zig");
const touch_zones = @import("../../kindle/touch.zig");

/// The page counter in the footer's middle: its left, this far left of the middle.
const counter_left_of_middle_px = style.space.wide;
/// The footer: the page number and time left, repainted alone when the count arrives.
const footer_height_px = style.space.band;
const footer_baseline_above_bottom_px = style.space.wider;

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
    /// The hyphenation of the book's language, or none: the book's, never the App's.
    hyphenator: ?*const hyphen.Hyphenator,
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
    /// The book's place file, as read when it opened: never saved over if unreadable.
    place: file.Kept,
    /// The place as read when the book opened, then as last saved: each save changes
    /// it, so anything else kept with the place is kept too, and it's never read again.
    saved: state.State,
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
        const pages_key = page_store.key(s.app, s.book_bytes, s.book_text());
        page_store.save(p.alloc, s.pages_path, pages_key, s.pages);
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

    /// The words from `at` to the book's end, saved with the place for the library's
    /// time left.
    pub fn book_words_left(s: *const Session, at: book_model.Pos) u64 {
        const here = s.words.at(s.paragraphs, at);
        assert(here <= s.words.total());
        return s.words.total() - here;
    }

    /// How far in a place `words_left` words from the end is, by the words before it,
    /// for when the pages can't say: null for a book without words (pictures only).
    pub fn words_percent(s: *const Session, words_left: u64) ?u32 {
        const total = s.words.total();
        assert(words_left <= total);
        if (total == 0) return null;
        const before = total - words_left;
        const in_percent: u32 = @intCast(before * 100 / total);
        assert(in_percent <= 100);
        return in_percent;
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
        const last = last_para_on(s.pages[index], s.page_end(index), @intCast(s.paragraphs.len));
        assert(first <= last);
        for (s.paragraphs[first .. last + 1]) |p| {
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

    /// The book marked finished, or not (`state.mark`), saved with its place: kept only
    /// when the save lands, as the reader is told it didn't otherwise. Whether it did.
    pub fn save_marked(s: *Session, done: bool, kindle_last: u64) bool {
        var marked = s.saved;
        state.mark(&marked, done, kindle_last);
        if (!state.save(&s.place, marked)) return false;
        s.saved = marked;
        assert(s.saved.finished == done);
        return true;
    }

    /// The book's text as it's laid out: its paragraphs, and their hyphenation.
    pub fn book_text(s: *const Session) paginate.Text {
        return .{ .paragraphs = s.paragraphs, .hyphenator = s.hyphenator };
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
        return slot.hits.find(x, y, style.reading.mark_reach);
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
        var minutes_buffer: stats.Minutes = undefined;
        var line: [64]u8 = undefined;
        // The Back button takes the left side while it's there
        if (left.chapter) |m| if (s.back.place == null) {
            const minutes = stats.format_minutes(&minutes_buffer, m);
            const t = line_of(&line, "{s} left in chapter", .{minutes});
            try a.footer.draw(page, margin, y, t);
        };
        // Like the Kindle, say so while the speed is still being learned rather than guess.
        var t: []const u8 = "Learning reading speed";
        if (left.book) |m| {
            const minutes = stats.format_minutes(&minutes_buffer, m);
            t = line_of(&line, "{s} left in book", .{minutes});
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
        // The App's layout, from the settings, with the book's own: its marks and its
        // hyphenation, which the App never holds
        assert(a.layout.marks.len == 0);
        assert(a.layout.hyphenator == null);
        var layout = a.layout;
        layout.marks = s.notes.marks.items;
        layout.hyphenator = s.hyphenator;
        layout.stop = s.page_end(index);
        _ = try text.render_page(a.body, page, s.paragraphs, s.pages[index], &layout, hits);

        const pages: u32 = @intCast(s.pages.len); // A book's pages fit a u32, as indexes
        const most = std.math.maxInt(u32);
        var label: [std.fmt.count("{d} / {d}", .{ most, most })]u8 = undefined;
        // Left out until the whole book is laid out, rather than a wrong number
        var counter: []const u8 = "";
        if (s.progress == null) {
            counter = line_of(&label, "{d} / {d}", .{ index + 1, pages });
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

    /// Says in the log, on a test run, where the page on screen put its first footnote
    /// mark and its first picture, and the words a test holds, for tests to tap
    /// (screens/placed.zig). The reader's own runs log none of it.
    fn note_placed(s: *const Session, index: u32) void {
        if (!s.app.logs_placed) return;
        const slot = s.app.display.slot_for(index) orelse return;
        assert(slot.page == index); // Just drawn: the page on screen
        placed.shown(index);
        const hits = &slot.hits;
        if (hits.len > 0 and has_room(hits.items[0])) {
            placed.note(.note, middle_of(hits.items[0]));
        }
        if (hits.picture_count > 0 and has_room(hits.pictures[0])) {
            placed.note(.picture, middle_of(hits.pictures[0]));
        }
        note_placed_words(hits.words[0..hits.word_count]);
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
        s.note_placed(index);
        if (touched_us) |t| {
            std.debug.print("turn to {d}: touch to queued {d} us, touch to done {d} ms{s}\n", .{
                index + 1,
                queued -| t,
                (done -| t) / std.time.us_per_ms,
                if (clean) " (clean)" else "",
            });
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < s.pages.len) _ = try s.ensure(index + 1, index);
        if (index > 0) _ = try s.ensure(index - 1, index);
        assert(s.current == index);
    }
};

/// Logs where a page's words a test holds or drags across were drawn (`words_placed`).
fn note_placed_words(words: []const book_model.Word) void {
    const found = words_placed(words);
    if (found.word) |at| placed.note(.word, at);
    if (found.paragraph) |at| placed.note(.paragraph, at);
    if (found.paragraph_end) |at| placed.note(.paragraph_end, at);
}

/// Where a page's words a test holds or drags across are; null for one it hasn't.
const WordsPlaced = struct {
    word: ?style.Point = null,
    paragraph: ?style.Point = null,
    paragraph_end: ?style.Point = null,
};

/// From `words`, as the page's layout put them in reading order: the first a touch
/// reaches as a word, below the top edge's strip, which opens the toolbar, and the first
/// and last of the first line of the next paragraph after it, when there is one. Only
/// words a finger can land on are taken.
fn words_placed(words: []const book_model.Word) WordsPlaced {
    var result: WordsPlaced = .{};
    // Bounded by the page's words
    const first = for (words, 0..) |w, i| {
        if (!touchable(w)) continue;
        if (middle_of_word(w).y >= touch_zones.top_zone) break i;
    } else return result; // None below the strip, or a page of only a picture
    result.word = middle_of_word(words[first]);
    // Bounded by the page's words
    const second = for (words[first..], first..) |w, i| {
        if (touchable(w) and w.para != words[first].para) break i;
    } else return result; // One paragraph only
    const line_y = words[second].y;
    const para = words[second].para;
    var last = second;
    // Bounded by the page's words: the line ends where a word starts lower down, or
    // another paragraph does; the last there is the last a finger can find
    for (words[second + 1 ..], second + 1..) |next, i| {
        if (next.y != line_y or next.para != para) break;
        if (touchable(next)) last = i;
    }
    assert(last >= second);
    assert(touchable(words[last]));
    result.paragraph = middle_of_word(words[second]);
    result.paragraph_end = middle_of_word(words[last]);
    return result;
}

test "the words placed skip what a finger can't land on, and the top edge's strip" {
    const top = touch_zones.top_zone;
    const line = top + 100;
    const words = [_]book_model.Word{
        // In the strip, then a zero-width space starting the first paragraph below it
        .{ .x = 100, .y = 0, .w = 50, .h = 40, .para = 0, .start = 0, .end = 4 },
        .{ .x = 100, .y = top, .w = 0, .h = 40, .para = 0, .start = 5, .end = 8 },
        .{ .x = 160, .y = top, .w = 60, .h = 40, .para = 0, .start = 8, .end = 12 },
        // The next paragraph's first line, ending in a zero-width word
        .{ .x = 100, .y = line, .w = 80, .h = 40, .para = 1, .start = 0, .end = 5 },
        .{ .x = 200, .y = line, .w = 40, .h = 40, .para = 1, .start = 6, .end = 9 },
        .{ .x = 260, .y = line, .w = 0, .h = 40, .para = 1, .start = 9, .end = 12 },
        .{ .x = 100, .y = line + 50, .w = 40, .h = 40, .para = 1, .start = 13, .end = 16 },
    };
    const found = words_placed(&words);
    try std.testing.expectEqual(style.Point{ .x = 190, .y = top + 20 }, found.word.?);
    try std.testing.expectEqual(style.Point{ .x = 140, .y = line + 20 }, found.paragraph.?);
    try std.testing.expectEqual(style.Point{ .x = 220, .y = line + 20 }, found.paragraph_end.?);
    // A page of words no finger can land on places none
    const empty = [_]book_model.Word{words[1]};
    try std.testing.expectEqual(@as(?style.Point, null), words_placed(&empty).word);
}

/// Whether a word takes up room a finger can land on: one drawn narrower than a pixel,
/// like a zero-width space or a soft hyphen, doesn't.
fn touchable(w: book_model.Word) bool {
    return w.w > 0 and w.h > 0;
}

fn middle_of_word(w: book_model.Word) style.Point {
    assert(w.w > 0);
    assert(w.h > 0);
    return .{ .x = w.x + @divTrunc(w.w, 2), .y = w.y + @divTrunc(w.h, 2) };
}

/// Whether a hit takes up room a finger can land on, as `touchable` for a word.
fn has_room(h: text.Hit) bool {
    return h.w > 0 and h.h > 0;
}

/// The middle of what a hit covers.
fn middle_of(h: text.Hit) style.Point {
    assert(h.w > 0);
    assert(h.h > 0);
    return .{ .x = h.x + @divTrunc(h.w, 2), .y = h.y + @divTrunc(h.h, 2) };
}

/// Saves what reading the book has taught: the reading speed and the day's reading.
/// Only on locking and closing, not with every place: each is a write on the user
/// drive, and a page turn would wait for it.
pub fn save_learned(s: *const Session) void {
    assert(s.current < s.pages.len);
    s.app.user.save_speed();
    s.app.user.save_journal();
}

/// Saves the reader's place, `s.anchor`, which stays what they're at even while the
/// pages are being laid out again or failed to be. `percent` is how far in they are,
/// or null when the pages don't say (see `Session.percent`): then it's the words
/// before the place, as the time left saved with it is the words after. Whether the
/// place was saved: not when it was unreadable as the book opened, nor when the drive
/// didn't take it.
pub fn save_progress(progress: *catalog.Progress, s: *Session, percent_read: ?u32) bool {
    assert(s.current < s.pages.len);
    assert(s.anchor.para < s.paragraphs.len);
    s.pause_clock(); // The reader's loop starts it again
    const seconds = s.seconds_read_total();
    const pos = s.anchor;
    if (percent_read) |p| assert(p <= 100);
    const words_left = s.book_words_left(pos);
    const percent = percent_read orelse s.words_percent(words_left) orelse progress.percent;
    const now = unix_time();
    var saved = s.saved;
    saved.para = book_model.text_index(s.paragraphs, pos.para);
    saved.byte = pos.byte;
    saved.percent = percent;
    saved.opened = now;
    saved.seconds = seconds;
    saved.words_left = words_left;
    saved.finished = progress.finished;
    const back = s.back.place;
    saved.back_para = if (back) |b| book_model.text_index(s.paragraphs, b.para) else null;
    saved.back_byte = if (back) |b| b.byte else 0;
    saved.back_turns = s.back.turns_since_jump;
    saved.numbering = state.numbering_now; // The places above are numbered as now
    saved.outside_end = platform.reading_place.end(s.paragraphs);
    const place_saved = state.save(&s.place, saved);
    s.saved = saved; // What the next save changes, whether this one landed or not
    // The library shows what's saved: a place unreadable as the book opened isn't, nor
    // one the drive didn't take
    if (!place_saved) return false;
    progress.percent = percent;
    progress.last = now;
    progress.seconds_read = seconds;
    progress.words_left = words_left;
    return true;
}

/// The last paragraph with any of it on the page from `start` to `end` (the next
/// page's start, or null for the book's last page): one the next page starts at its
/// first byte isn't on this one.
fn last_para_on(start: book_model.Pos, end: ?book_model.Pos, paragraphs: u32) u32 {
    assert(start.para < paragraphs);
    const e = end orelse return paragraphs - 1;
    assert(start.is_before(e)); // Pages only move forward
    const last = if (e.byte == 0) e.para - 1 else e.para;
    assert(last >= start.para);
    assert(last < paragraphs);
    return last;
}

test "a page ends at the paragraph before the next page's, when that one starts it" {
    // The next page starts with paragraph 3 (a picture, say): not on this page
    try std.testing.expectEqual(@as(u32, 2), last_para_on(.{ .para = 1 }, .{ .para = 3 }, 5));
    // The next page starts partway into paragraph 3: some of it is on this one
    const partway: book_model.Pos = .{ .para = 3, .byte = 9 };
    try std.testing.expectEqual(@as(u32, 3), last_para_on(.{ .para = 1 }, partway, 5));
    try std.testing.expectEqual(@as(u32, 4), last_para_on(.{ .para = 1 }, null, 5));
}

/// Where a session's pages point while a layout that failed partway had let go of the
/// old ones: the book's start, a page that always exists.
const pages_fallback = [_]book_model.Pos{.{}};

/// Re-lays out the book after a text setting changed, keeping the reading position.
/// The new pages go in the pages region, emptied first: the pages of the last change,
/// and of a layout still running for it, are no longer wanted, so changing settings
/// again and again takes no more memory. The caller saves the settings once the page
/// is drawn: a save on the user drive can take a while, and the drawing never waits.
pub fn relayout(a: *app.App, s: *Session) !void {
    assert(s.current < s.pages.len);
    assert(a.regions.pages_budget.region.?.kind == .bump);
    a.apply_settings() catch |err| {
        std.debug.print("settings failed: {s}\n", .{@errorName(err)});
        a.user.settings = a.user.saved_settings();
        try a.apply_settings();
        // Said, so the tap isn't taken for one that did nothing; the page is as it was
        app.show_notice(a, "That setting couldn't be used here.");
        return;
    };
    a.display.forget_pages();
    const t0 = now_us();
    const pages_key = page_store.key(a, s.book_bytes, s.book_text());
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
        p.* = (try paginate.Progressive.start(a, alloc, s.book_text(), s.anchor)).?;
        s.progress = p;
        s.pages = p.pages();
        s.current = 0;
    }
    assert(s.pages.len > 0);
    assert(s.current < s.pages.len);
    std.debug.print("relayout {s} in {d} ms\n", .{
        if (stored != null) "from saved pages" else "first pages",
        (now_us() - t0) / std.time.us_per_ms,
    });
    std.debug.print("relayout: page {d} of {d}, anchor {d}:{d}\n", .{
        s.current + 1,
        s.pages.len,
        s.anchor.para,
        s.anchor.byte,
    });
}
