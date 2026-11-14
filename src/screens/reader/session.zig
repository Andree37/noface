//! An open book: its pages, where the reader is, and its highlights.
const std = @import("std");
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
const state = @import("../../sys/state.zig");
const text = @import("../../layout/text.zig");
const nowUs = os.nowUs;
const unixTime = os.unixTime;
const failed = os.failed;
const app = @import("../../app.zig");
const draw = @import("../../ui/draw.zig");

pub const Query = @import("../../model/search.zig").Query;

/// Turns from a jump after which the Back button goes: the reader is reading there.
const back_turns = 10;
const back_width = 330;

pub const Session = struct {
    app: *app.App,
    paragraphs: []const book_model.Paragraph,
    pages: []const book_model.Pos,
    current: usize,
    anchor: book_model.Pos, // What the reader is at. Settings changes keep to this, not the page edge
    note_parts: [note_rules.max_note_parts]book_model.Paragraph = undefined,
    note_len: usize = 0,
    note_top: u32 = 0,
    note_next: ?book_model.Pos = null,
    highlights: std.ArrayList(highlights.Highlight) = .empty,
    bookmarks: std.ArrayList(bookmarks.Bookmark) = .empty,
    marks: std.ArrayList(book_model.Mark) = .empty, // What layout shades, rebuilt from highlights
    pages_path: [:0]const u8 = "", // Where this book's page breaks are saved
    notes_path: [:0]const u8 = "", // Where highlights and bookmarks are kept, for books Amazon doesn't sync
    book_bytes: usize = 0, // The book file's size, part of the saved breaks' key
    // A first open still being laid out: pages count from the reader's place until done
    progress: ?*paginate.Progressive = null,
    query: Query = .{}, // The last search, kept while the book is open
    chapters: []const book_model.Chapter = &.{},
    words_before: []const u64 = &.{}, // Words before each paragraph, for time left
    shown_us: u64 = 0, // When the clock last started on this page; 0 while paused
    /// Where the reader was before jumping elsewhere (Go To, search, a chapter, the
    /// slider, a link): a Back button on the page returns there. The first place is
    /// kept through several jumps, and let go after `back_turns` turns from the jump.
    back: ?book_model.Pos = null,
    turns_since_jump: u32 = 0,
    turning: bool = false, // Set by a normal page turn, so `show` can tell it from a jump
    page_us: u64 = 0, // Time on the current page before that
    seconds_read: u64 = 0, // Time spent in this book, saved with the position

    pub fn layoutPending(s: *const Session) bool {
        return s.progress != null;
    }

    /// One step of a layout running in the background, for an idle moment. Once the
    /// whole book is laid out, it takes over: page numbers count from the start and
    /// the breaks are saved. True when that just happened, so whatever is on screen
    /// can show the page count it was missing.
    pub fn layoutStep(s: *Session) !bool {
        const p = s.progress orelse return false;
        try p.step(s.app);
        s.pages = p.pages();
        if (!p.done()) return false;
        const whole = try p.joined();
        s.pages = whole.pages;
        s.current += whole.before;
        s.progress = null;
        page_store.save(p.alloc, s.pages_path, page_store.key(s.app, s.book_bytes), s.pages);
        std.debug.print("laid out in the background: {d} pages, {d} before the reader's place\n", .{ s.pages.len, whole.before });
        s.app.forgetPages(); // Indexes moved, so pages drawn so far are stale
        return true;
    }

    /// Puts the page number on the page on screen once it's known: only the footer
    /// changes, so only it repaints.
    pub fn showFooter(s: *Session) !void {
        @memcpy(s.app.screen.pixels, try s.ensure(s.current, s.current));
        const footer_top = s.app.screen.height - 110;
        try s.app.showBand(footer_top, s.app.screen.height - footer_top);
    }

    /// Lays out until page `index` exists, or the book ends, for turning on.
    pub fn layoutUntil(s: *Session, index: usize) !void {
        while (s.progress) |p| {
            if (index < s.pages.len or p.next_forward == null) return;
            _ = try s.layoutStep();
        }
    }

    /// Finishes a first open's layout now, before anything that needs every page.
    /// Finishing forgets the pages drawn so far, so the one on screen is drawn again
    /// at once: what comes next hit-tests its words, links and highlights.
    pub fn finishLayout(s: *Session) !void {
        while (s.progress != null) _ = try s.layoutStep();
        _ = try s.ensure(s.current, s.current);
    }

    /// Words from the start of the book to a position.
    pub fn wordsAt(s: *const Session, p: book_model.Pos) u64 {
        check.that(p.para < s.paragraphs.len and p.para + 1 < s.words_before.len, "position inside the book");
        const para = s.paragraphs[p.para];
        if (para.note) return s.words_before[p.para];
        return s.words_before[p.para] + stats.countWords(para.text[0..@min(p.byte, para.text.len)]);
    }

    fn wordsOnPage(s: *const Session, index: usize) u64 {
        const end = if (s.pageEnd(index)) |e| s.wordsAt(e) else s.words_before[s.words_before.len - 1];
        return end -| s.wordsAt(s.pages[index]);
    }

    /// Minutes left in the chapter and in the book from a page, once speed is known.
    pub fn timeLeft(s: *const Session, index: usize) struct { chapter: ?u64, book: ?u64 } {
        const here = s.wordsAt(s.pages[index]);
        const total = s.words_before[s.words_before.len - 1];
        var chapter_end: ?u64 = null;
        for (s.chapters) |c| {
            const at = s.words_before[c.para];
            if (at > here and (chapter_end == null or at < chapter_end.?)) chapter_end = at;
        }
        const speed = s.app.speed;
        return .{
            .chapter = if (chapter_end) |end| speed.minutesFor(end - here) else if (s.chapters.len > 0) speed.minutesFor(total -| here) else null,
            .book = speed.minutesFor(total -| here),
        };
    }

    /// Adds the time since the clock last started to the current page's reading time.
    fn tick(s: *Session) void {
        if (s.shown_us == 0) return;
        const now = nowUs();
        s.page_us += now -| s.shown_us;
        s.shown_us = now;
    }

    /// The page being left: its time goes to the book, and a page read forward teaches
    /// the reading speed. Time on it adds up across footnotes, menus and sleep, so a
    /// page read in two sittings counts as one page read in the time of both.
    fn leavePage(s: *Session, to: usize) void {
        s.tick();
        const us = s.page_us;
        s.page_us = 0;
        const counted = stats.countedSeconds(us / 1_000_000);
        s.seconds_read += counted;
        // The day's journal: the time, and the page when it was read on to the next
        const read_on = to == s.current + 1 and counted > 0;
        s.app.journal.add(s.app.today(), @intCast(@min(counted, std.math.maxInt(u32))), if (read_on) 1 else 0);
        if (to != s.current + 1 or us == 0) return;
        if (s.pageHasPicture(s.current)) return; // Time on a picture isn't reading speed
        const speed = &s.app.speed;
        const was_known = speed.known();
        speed.record(s.wordsOnPage(s.current), us);
        // Pages already drawn have no time left on them yet.
        if (!was_known and speed.known()) s.app.forgetPages();
    }

    fn pageHasPicture(s: *const Session, index: usize) bool {
        const first = s.pages[index].para;
        const last = if (s.pageEnd(index)) |e| e.para else s.paragraphs.len - 1;
        for (s.paragraphs[first .. @min(last, s.paragraphs.len - 1) + 1]) |p| {
            if (p.image != null) return true;
        }
        return false;
    }

    /// Reading time so far, with the page in front of the reader.
    pub fn secondsRead(s: *Session) u64 {
        s.tick();
        return s.seconds_read + stats.countedSeconds(s.page_us / 1_000_000);
    }

    /// Stops the reading clock while something covers the page, or the Kindle sleeps.
    pub fn pauseClock(s: *Session) void {
        s.tick();
        s.shown_us = 0;
    }

    /// Starts the clock again when the page is back in front of the reader.
    pub fn resumeClock(s: *Session) void {
        if (s.shown_us == 0) s.shown_us = nowUs();
    }

    /// Where a page ends: the next page's start, or null on the last page.
    pub fn pageEnd(s: *const Session, index: usize) ?book_model.Pos {
        return if (index + 1 < s.pages.len) s.pages[index + 1] else null;
    }

    pub fn isBookmarked(s: *const Session, index: usize) bool {
        return bookmarks.anyOnPage(s.bookmarks.items, s.pages[index], s.pageEnd(index));
    }

    /// Every move to another page comes through here, so reading time stays right.
    pub fn setPage(s: *Session, index: usize) void {
        check.thatf(index < s.pages.len, "page {d} of {d}", .{ index, s.pages.len });
        s.noteJump(index);
        s.leavePage(index);
        s.current = index;
        s.anchor = s.pages[index];
        if (s.shown_us != 0) s.shown_us = nowUs();
    }

    /// The picture at a point on the page on screen, if any. The page is drawn again
    /// first if its drawing was dropped (a finished layout forgets them all).
    pub fn pictureAt(s: *Session, x: i32, y: i32) !?book_model.Image {
        _ = try s.ensure(s.current, s.current);
        const slot = s.app.slotFor(s.current) orelse return null;
        const para = slot.hits.pictureAt(x, y) orelse return null;
        return s.paragraphs[para].image;
    }

    pub fn referenceAt(s: *Session, x: i32, y: i32) ?u32 {
        const slot = s.app.slotFor(s.current) orelse return null;
        return slot.hits.find(x, y);
    }

    /// Keeps the Back button's place up to date for a move to page `index`: a jump
    /// remembers where the reader was (unless an earlier jump's place is still kept),
    /// arriving back there lets go of it, and so does reading on a while.
    fn noteJump(s: *Session, index: usize) void {
        const turning = s.turning;
        s.turning = false;
        if (s.pages.len == 0) return;
        const before = s.back;
        // Page numbers are only final once the whole book is laid out: until then an
        // earlier place would look like page 0, so nothing is let go of
        const settled = s.progress == null;
        if (s.back) |b| {
            if (settled and pageContaining(s.pages, b.para, b.byte) == index) {
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
        if ((before == null) != (s.back == null)) s.app.forgetPages();
    }

    /// The Back button's place on the page: the bottom left, over the footer.
    pub fn backRect(s: *const Session) struct { x: u32, y: u32, w: u32, h: u32 } {
        return .{ .x = 40, .y = s.app.screen.height - 112, .w = back_width, .h = 84 };
    }

    /// Where touches count as the Back button although the thumb filter is on there:
    /// its rectangle and a fingertip around it. Null with no button.
    pub fn backZone(s: *const Session) ?@import("../../kindle/input.zig").Zone {
        if (s.back == null) return null;
        const r = s.backRect();
        return .{ .x = @as(i32, @intCast(r.x)) - 12, .y = @as(i32, @intCast(r.y)) - 12, .w = @intCast(r.w + 24), .h = @intCast(r.h + 24) };
    }

    pub fn onBack(s: *const Session, x: i32, y: i32) bool {
        if (s.back == null) return false;
        const r = s.backRect();
        // A fingertip's margin around it
        return x >= @as(i32, @intCast(r.x)) - 12 and x < @as(i32, @intCast(r.x + r.w)) + 12 and
            y >= @as(i32, @intCast(r.y)) - 12 and y < @as(i32, @intCast(r.y + r.h)) + 12;
    }

    /// The page the Back button returns to.
    pub fn backPage(s: *const Session) ?usize {
        const b = s.back orelse return null;
        return pageContaining(s.pages, b.para, b.byte);
    }

    fn drawBack(s: *const Session, page: Page) !void {
        const a = s.app;
        const r = s.backRect();
        page.fillRect(0, r.y - 8, r.x + r.w + 24, a.screen.height - (r.y - 8), 0xff); // Over the footer's text there
        draw.box(page, r.x, r.y, r.w, r.h);
        var buf: [32]u8 = undefined;
        // The page number only once the whole book is laid out
        const label = if (s.progress != null) "Back" else std.fmt.bufPrint(&buf, "Back to p. {d}", .{(s.backPage() orelse 0) + 1}) catch "Back";
        const cy: f32 = @floatFromInt(r.y + r.h / 2);
        icons.back(page, @floatFromInt(r.x + 44), cy);
        try a.ui.small.draw(page, @floatFromInt(r.x + 80), @intFromFloat(cy + 12), label);
    }

    /// "12 min left in chapter" on the left of the footer, the book's on the right.
    fn drawTimeLeft(s: *const Session, page: Page, index: usize) !void {
        const a = s.app;
        const left = s.timeLeft(index);
        const y: i32 = @intCast(a.screen.height - 60);
        const margin: f32 = @floatFromInt(a.layout.margin_x);
        var buf: [48]u8 = undefined;
        var line: [64]u8 = undefined;
        // The Back button takes the left side while it's there
        if (left.chapter) |m| if (s.back == null) {
            const t = std.fmt.bufPrint(&line, "{s} left in chapter", .{stats.formatMinutes(&buf, m)}) catch "";
            try a.footer.draw(page, margin, y, t);
        };
        // Like the Kindle, say so while the speed is still being learned rather than guess.
        const t = if (left.book) |m| std.fmt.bufPrint(&line, "{s} left in book", .{stats.formatMinutes(&buf, m)}) catch "" else "Learning reading speed";
        try a.footer.draw(page, @as(f32, @floatFromInt(a.screen.width)) - margin - try a.footer.measure(t), y, t);
    }

    /// Get a rendered page, reusing a cached one when possible.
    pub fn ensure(s: *Session, index: usize, center: usize) ![]const u8 {
        check.thatf(index < s.pages.len and center < s.pages.len, "page {d} of {d}", .{ index, s.pages.len });
        const a = s.app;
        if (a.slotFor(index)) |slot| return slot.buf;
        var cached: [3]i64 = undefined;
        for (&a.slots, &cached) |*slot, *c| c.* = slot.page;
        const victim = cache.victim(cached, @intCast(center));
        const buf = a.slots[victim].buf;
        const page = a.page(buf);
        a.slots[victim].hits.clear();
        _ = try text.renderPage(a.body, page, s.paragraphs, s.pages[index], a.layout, &a.slots[victim].hits);

        var label: [32]u8 = undefined;
        // Left out until the whole book is laid out, rather than a wrong number
        const counter = if (s.progress != null) "" else std.fmt.bufPrint(&label, "{d} / {d}", .{ index + 1, s.pages.len }) catch "";
        const x = @as(f32, @floatFromInt(a.screen.width)) / 2 - 50;
        try a.footer.draw(page, x, @intCast(a.screen.height - 60), counter);
        if (s.isBookmarked(index)) icons.ribbon(page, a.screen.width);
        if (a.settings.time_left) try s.drawTimeLeft(page, index);
        if (s.back != null) try s.drawBack(page);

        a.slots[victim].page = @intCast(index);
        return buf;
    }

    pub fn show(s: *Session, index: usize, touched_us: ?u64, force_clean: bool) !void {
        const a = s.app;
        s.setPage(index);
        const buf = try s.ensure(index, index);
        @memcpy(a.screen.pixels, buf);
        a.stampClock();
        a.turns += 1;
        const clean = force_clean or (a.settings.refresh and a.turns % 20 == 0);
        const marker = if (clean)
            try a.screen.show(.flash)
        else
            try a.screen.show(.page);
        const queued = nowUs();
        try a.screen.waitComplete(marker);
        const done = nowUs();
        if (touched_us) |t| {
            std.debug.print("turn to {d}: touch to queued {d} us, touch to done {d} ms{s}\n", .{
                index + 1, queued -| t, (done -| t) / 1000, if (clean) " (clean)" else "",
            });
        }
        for (&a.slots) |*slot| {
            if (slot.page != @as(i64, @intCast(index))) continue;
            for (slot.hits.items[0..slot.hits.len]) |h| {
                std.debug.print("ref page {d} at {d},{d} size {d}x{d} target {d}\n", .{ index + 1, h.x, h.y, h.w, h.h, h.target });
            }
        }
        // Prepare both neighbours now, so the next turn is only a copy.
        if (index + 1 < s.pages.len) _ = try s.ensure(index + 1, index);
        if (index > 0) _ = try s.ensure(index - 1, index);
    }
};

pub fn saveProgress(entry: *catalog.Entry, path: [*:0]const u8, s: *Session) void {
    s.pauseClock(); // The reader's loop starts it again
    const seconds = s.secondsRead();
    const pos = s.pages[s.current];
    // While a first open is laid out, the page count isn't known: keep the last percent
    const percent: u32 = if (s.progress != null) entry.percent else @intCast((s.current + 1) * 100 / s.pages.len);
    const now = unixTime();
    // Changed in place, so anything else kept with the place is kept too
    var saved = state.load(path);
    saved.para = book_model.textIndex(s.paragraphs, pos.para);
    saved.byte = pos.byte;
    saved.percent = percent;
    saved.opened = now;
    saved.seconds = seconds;
    saved.finished = entry.finished;
    state.save(path, saved);
    app.saveSpeed(s.app);
    app.saveJournal(s.app);
    entry.percent = percent;
    entry.last = now;
    entry.seconds_read = seconds;
}

pub fn pageContaining(pages: []const book_model.Pos, para: usize, byte: usize) usize {
    var found: usize = 0;
    for (pages, 0..) |p, i| {
        if (p.para < para or (p.para == para and p.byte <= byte)) found = i;
    }
    return found;
}

/// Re-lays out the book after a text setting changed, keeping the reading position.
pub fn relayout(a: *app.App, alloc: std.mem.Allocator, s: *Session) !void {
    a.applySettings() catch |err| {
        std.debug.print("settings failed: {s}\n", .{@errorName(err)});
        a.settings = app.loadSettings(a.settings_path);
        return a.applySettings();
    };
    app.saveSettings(a.settings_path, a.settings);
    a.forgetPages();
    const t0 = nowUs();
    const pages_key = page_store.key(a, s.book_bytes);
    const stored = page_store.load(alloc, s.pages_path, pages_key, s.paragraphs.len);
    s.progress = null; // A layout still running was for the old settings
    if (stored) |pages| {
        s.pages = pages;
        s.current = pageContaining(s.pages, s.anchor.para, s.anchor.byte);
    } else {
        // The reader's page at once, laid out from its first word with the new
        // settings; the rest follows in idle moments, as on a first open
        const p = try alloc.create(paginate.Progressive);
        p.* = try paginate.Progressive.start(a, alloc, s.paragraphs, s.anchor);
        s.progress = p;
        s.pages = p.pages();
        s.current = 0;
    }
    std.debug.print("relayout {s} in {d} ms\n", .{ if (stored != null) "from saved pages" else "first pages", (nowUs() - t0) / 1000 });
    std.debug.print("relayout: page {d} of {d}, anchor {d}:{d}\n", .{ s.current + 1, s.pages.len, s.anchor.para, s.anchor.byte });
}
