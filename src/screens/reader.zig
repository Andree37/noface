//! Reading a book: page turns, and routing taps to the toolbar, panel, notes and highlights.
const std = @import("std");
const stats = @import("../model/stats.zig");
const epub = @import("../epub/epub.zig");
const memory = @import("../base/memory.zig");
const book_model = @import("../model/book.zig");
const catalog = @import("../model/catalog.zig");
const os = @import("../sys/os.zig");
const file = @import("../sys/file.zig");
const highlights = @import("../model/highlights.zig");
const kfx = @import("../kindle/kfx.zig");
const menu = @import("../ui/menu.zig");
const selection = @import("../ui/selection.zig");
const state = @import("../sys/state.zig");
const annotation_db = @import("../kindle/annotation_db.zig");
const lipc = @import("../kindle/lipc.zig");
const hyphen = @import("../layout/hyphen.zig");
const define = @import("reader/define.zig");
const toolbar = @import("../ui/toolbar.zig");
const touch_zones = @import("../kindle/touch.zig");
const input_mod = @import("../kindle/input.zig");
const now_us = os.now_us;
const unix_time = os.unix_time;
const app = @import("../app.zig");
const goto = @import("reader/goto.zig");
const local_notes = @import("reader/local_notes.zig");
const more = @import("reader/more.zig");
const picture_view = @import("reader/picture.zig");
const wifi_saver = @import("../kindle/wifi_saver.zig");
const page_store = @import("reader/page_store.zig");
const paginate = @import("reader/paginate.zig");
const search = @import("reader/search.zig");
const bookmark = @import("reader/bookmark.zig");
const bookmarks = @import("../model/bookmarks.zig");
const panel = @import("panel.zig");
const lock = @import("lock.zig");
const sess = @import("reader/session.zig");
const hl = @import("reader/highlight.zig");
const note_view = @import("reader/note.zig");
const controls = @import("reader/controls.zig");

pub const save_every = 10;

pub const clock_check_us = 10 * 1000 * 1000;

/// Wi-Fi that couldn't go off yet (a download, Bluetooth) is tried again this often.
const wifi_retry_us = 60 * 1000 * 1000;

pub const Outcome = enum { library, quit };

/// What the reader shows: the page alone, or something over it. The toolbar may have
/// its Aa sheet open below it (`Reader.sheet_open`).
pub const View = enum { page, toolbar, panel, note, highlight };

/// What a view means for the rest of the reader. While `reading`, the page alone is in
/// front of the reader: the reading clock runs, the clock in the corner keeps time,
/// Wi-Fi may go off, and the Back button can be tapped. On the page a press may become
/// a hold, so taps wait for the finger to lift; controls that sit where a thumb rests
/// turn the thumb filter off; a highlight's handles can reach the screen's edges.
/// How each view takes touches.
fn touches_for(view: View) input_mod.Input.Modes {
    return switch (view) {
        // Taps on the lift, so a press can become a hold; a resting thumb is ignored
        .page => .{ .grips = true, .deferred = true, .edge_zones = true },
        .toolbar => input_mod.Input.Modes.sheet,
        // The handles can sit at the screen edges
        .highlight => .{ .grips = true, .deferred = false, .edge_zones = false },
        .note, .panel => .{ .grips = true, .deferred = false, .edge_zones = true },
    };
}

/// Whether an action needs every page laid out first: anything but reading on, as
/// menus, Go To and page numbers count from the start of the book.
fn needs_all_pages(action: input_mod.Action, view: View, sheet: ?@import("../ui/aa.zig").Tab, s: *const sess.Session) bool {
    return switch (action) {
        .tick, .drag, .drag_end => false,
        .tap => |t| switch (view) {
            // The toolbar, going back from the first page, or the Back button: all count pages
            .page => t.y < touch_zones.top_zone or s.on_back(t.x, t.y) or (input_mod.turn_direction(t.x, s.app.input.width) < 0 and s.current == 0),
            // Text settings and closing don't count pages; the toolbar's other buttons do
            .toolbar => switch (toolbar.hit(t.x, t.y, sheet)) {
                .sheet, .close, .stay, .text => false,
                else => true,
            },
            else => true,
        },
        .swipe => |direction| direction < 0 and s.current == 0,
        // Locking, waking and leaving don't count pages, and must not wait for them;
        // nor does holding a word, which looks it up on the page on screen
        .lock, .unlock, .power, .computer, .stop, .hold => false,
        else => true,
    };
}

pub fn read_book(a: *app.App, entry: *catalog.Entry) !Outcome {
    // The open book: parsed text, pages, highlights. All freed together on close.
    var book_budget = memory.Budget{ .name = "book", .child = std.heap.smp_allocator, .limit = 128 << 20 };
    var arena = std.heap.ArenaAllocator.init(book_budget.allocator());
    // What one action needs, like a Go To list or search results. Emptied after each.
    var scratch_budget = memory.Budget{ .name = "scratch", .child = std.heap.smp_allocator, .limit = 32 << 20 };
    var scratch_arena = std.heap.ArenaAllocator.init(scratch_budget.allocator());
    defer {
        a.pictures.clear(a.alloc); // Its keys point into this book's memory
        scratch_arena.deinit();
        arena.deinit();
        book_budget.report();
        scratch_budget.report();
        a.app_budget.report();
        a.stb_budget.report();
    }
    const alloc = arena.allocator();
    const scratch = scratch_arena.allocator();

    const t0 = now_us();
    const data = try file.map(entry.path);
    defer file.unmap(data);
    const book = if (entry.is_epub()) try epub.parse(alloc, data) else try kfx.parse(alloc, data);
    book_model.plain_body(book.paragraphs);
    const lang = hyphen.detect(book.paragraphs);
    a.layout.hyphenator = a.hyphenator_for(lang);
    std.debug.print("language {s}\n", .{if (lang) |l| @tagName(l) else "unknown"});
    const t1 = now_us();

    var path_buf: [320]u8 = undefined;
    const state_path = try a.state_path(&path_buf, entry.path);
    var pages_buf: [320]u8 = undefined;
    const pages_path = try alloc.dupeSentinel(u8, try page_store.path_for(&pages_buf, state_path), 0);
    const pages_key = page_store.key(a, data.len);
    const stored_pages = page_store.load(alloc, pages_path, pages_key, book.paragraphs.len);
    const saved = state.load(state_path);
    const from_kindle = state.prefer_kindle(saved, entry.kindle_last);
    // Without saved breaks, lay out a little from the reader's place and show it at
    // once; the rest follows in idle moments. Stock's place is a percent of the
    // pages, so that one needs them all first.
    var progress: ?paginate.Progressive = null;
    if (stored_pages == null and !from_kindle) {
        var place = book_model.Pos{ .para = book_model.from_text_index(book.paragraphs, saved.para), .byte = saved.byte };
        if (place.para >= book.paragraphs.len or place.byte > book.paragraphs[place.para].text.len) place = .{};
        progress = try paginate.Progressive.start(a, alloc, book.paragraphs, place);
        if (progress.?.pages().len == 0) progress = null; // Nothing from there on: lay it all out
    }
    const pages = if (progress) |*p| p.pages() else stored_pages orelse try paginate.book(a, alloc, book.paragraphs);
    if (pages.len == 0) return error.EmptyBook;
    if (stored_pages == null and progress == null) page_store.save(alloc, pages_path, pages_key, pages);
    std.debug.print("open {s}: {d} pages, parsed in {d} ms, {s} in {d} ms\n", .{
        entry.title, pages.len, (t1 - t0) / 1000, if (stored_pages != null) "saved pages" else if (progress != null) "first pages" else "laid out", (now_us() - t1) / 1000,
    });
    const start = if (progress != null)
        0 // The place itself: the first page laid out
    else if (from_kindle)
        @min(pages.len * entry.kindle_percent / 100, pages.len - 1)
    else
        sess.page_containing(pages, book_model.from_text_index(book.paragraphs, saved.para), saved.byte);

    const stored = try alloc.alloc(u8, 1024 * 1024);
    a.layout.marks = &.{};
    var session = sess.Session{ .app = a, .paragraphs = book.paragraphs, .pages = pages, .current = start, .anchor = pages[start], .chapters = book.chapters, .seconds_read = saved.seconds, .pages_path = pages_path, .book_bytes = data.len };
    if (progress) |*p| session.progress = p;
    const words_before = try alloc.alloc(u64, book.paragraphs.len + 1);
    words_before[0] = 0;
    for (book.paragraphs, 0..) |p, i| words_before[i + 1] = words_before[i] + (if (p.note) 0 else stats.count_words(p.text));
    session.words_before = words_before;
    if (entry.is_epub()) {
        var notes_buf: [320]u8 = undefined;
        session.notes_path = try alloc.dupeSentinel(u8, try state.sibling(&notes_buf, state_path, "notes"), 0);
    }
    const highlight_lines = if (entry.is_epub()) try local_notes.read(alloc, session.notes_path, .highlight) else annotation_db.read_annotations(entry.key, .highlight, stored);
    try session.highlights.appendSlice(alloc, try highlights.parse(alloc, book.paragraphs, highlight_lines));
    const bookmark_lines = if (entry.is_epub()) try local_notes.read(alloc, session.notes_path, .bookmark) else annotation_db.read_annotations(entry.key, .bookmark, stored);
    try session.bookmarks.appendSlice(alloc, try bookmarks.parse(alloc, book.paragraphs, bookmark_lines));
    std.debug.print("{d} bookmarks loaded\n", .{session.bookmarks.items.len});
    std.debug.print("{d} highlights loaded\n", .{session.highlights.items.len});
    try hl.refresh_marks(a, &session, alloc);
    try session.show(start, null, true);
    sess.save_progress(entry, state_path, &session);

    a.wifi_hands_off = false;
    defer wifi_saver.restore(); // Leaving the book, Wi-Fi comes back
    defer sess.save_progress(entry, state_path, &session);
    // The loop sets touches and the tick for each view; put back for the library on leaving
    const was = a.input.enter(a.input.modes(), 0);
    defer a.input.leave(was);
    var reader = Reader{
        .a = a,
        .s = &session,
        .entry = entry,
        .alloc = alloc,
        .scratch = scratch,
        .chapters = book.chapters,
        .lang = lang,
        .state_path = state_path,
        .last_place = session.current,
        .wifi_try_at = now_us() + wifi_saver.after_us,
    };
    return reader.run(&scratch_arena);
}

/// An open book and what's on screen over it. `run` takes each action: what's the
/// same in every view (locking, the clock's tick, leaving) here, and touches by the
/// view they land on, each in a handler of its own.
const Reader = struct {
    a: *app.App,
    s: *sess.Session,
    entry: *catalog.Entry,
    alloc: std.mem.Allocator, // The book's, kept while it's open
    scratch: std.mem.Allocator, // One action's, emptied after it
    chapters: []const book_model.Chapter,
    lang: ?hyphen.Lang,
    state_path: [*:0]const u8,
    view: View = .page,
    sheet_open: bool = false, // The toolbar's Aa sheet, in the toolbar view
    active: ?[]const u8 = null, // The highlight being changed, in the highlight view
    delete_top: ?usize = null, // Where its Delete bubble is, when there is one
    since_save: u32 = 0,
    last_place: usize = 0,
    wifi_try_at: ?u64 = null, // When to turn Wi-Fi off; null once that's settled
    battery_minute: u64 = 0, // The battery is noted once a minute at most

    fn run(r: *Reader, scratch_arena: *std.heap.ArenaAllocator) !Outcome {
        while (true) {
            _ = scratch_arena.reset(.retain_capacity); // Nothing from the last action is still needed
            r.save_after_jump();
            if (r.reading()) r.s.resume_clock() else r.s.pause_clock();
            r.set_input();
            const action = r.a.input.next();
            if (r.s.layout_pending() and needs_all_pages(action, r.view, r.sheet(), r.s)) {
                try r.s.finish_layout();
                // The page's footer gains its count; anything else is about to be redrawn
                if (r.reading()) try r.s.show_footer();
            }
            switch (action) {
                .lock => try r.on_lock(),
                .tick => try r.on_tick(),
                .power, .computer, .stop => return .quit,
                .unlock, .drag, .drag_end => {},
                .tap, .hold, .swipe, .pull => if (try r.on_touch(action)) |outcome| return outcome,
            }
        }
    }

    /// The page alone is up: the reading clock runs, and the page's own corners count.
    fn reading(r: *const Reader) bool {
        return r.view == .page;
    }

    /// The Aa sheet's tab, while it's open.
    fn sheet(r: *const Reader) ?@import("../ui/aa.zig").Tab {
        return if (r.sheet_open) r.a.tab else null;
    }

    /// The input modes for the view on screen, and how often to tick: often while a
    /// first open is still laid out in idle moments, else for the clock.
    fn set_input(r: *Reader) void {
        const in = r.a.input;
        in.take(touches_for(r.view));
        in.grip_exempt = if (r.reading()) r.s.back_zone() else null; // The Back button counts
        in.tick_us = if (r.s.layout_pending()) 1000 else clock_check_us;
    }

    /// A jump (Go To, search, a chapter, the slider) is saved at once: turning page by
    /// page saves every few turns, but a jump may cross half the book.
    fn save_after_jump(r: *Reader) void {
        const now = r.s.current;
        const moved = if (now > r.last_place) now - r.last_place else r.last_place - now;
        if (moved > 1 and !r.s.layout_pending()) r.save();
        r.last_place = now;
    }

    fn save(r: *Reader) void {
        sess.save_progress(r.entry, r.state_path, r.s);
        r.since_save = 0;
    }

    fn on_touch(r: *Reader, action: input_mod.Action) !?Outcome {
        return switch (r.view) {
            .page => r.on_page(action),
            .toolbar => r.on_toolbar(action),
            .highlight => r.on_highlight(action),
            .note => r.on_note(action),
            .panel => r.on_panel(action),
        };
    }

    // What's on screen, drawn again

    /// After the clock, battery or charger changed: wherever they show.
    fn show_status(r: *Reader) !void {
        switch (r.view) {
            .page => try r.a.update_clock(),
            .toolbar => try r.draw_toolbar(false),
            .panel, .note, .highlight => {},
        }
    }

    /// After the whole book is laid out: the page count, where it shows.
    fn show_page_count(r: *Reader) !void {
        switch (r.view) {
            .page => try r.s.show_footer(),
            .toolbar => try r.draw_toolbar(false),
            .panel, .note, .highlight => {},
        }
    }

    fn draw_toolbar(r: *Reader, whole_page: bool) !void {
        try controls.draw_toolbar(r.a, r.s, r.entry.title, r.sheet_open, whole_page);
    }

    /// Back to the page alone, at `target`, from whatever was over it.
    fn to_page(r: *Reader, target: usize) !void {
        r.view = .page;
        r.sheet_open = false;
        try r.s.show(target, null, true);
    }

    // Actions in every view

    fn on_lock(r: *Reader) !void {
        r.s.pause_clock(); // Asleep isn't reading
        r.save(); // A lock is a natural stop, and anything after it may end noface
        if (lock.lock_screen(r.a, r.entry, .{}) == .leaving) return;
        r.a.note_battery(); // What sleeping cost
        r.a.quick = lipc.read(r.a.quick); // Hours may have passed
        try r.show_status();
    }

    fn on_tick(r: *Reader) !void {
        const a = r.a;
        if (a.input.charger_changed) { // A charger came or went: the bolt follows
            a.input.charger_changed = false;
            a.quick = lipc.read(a.quick);
            try r.show_status();
        }
        if (r.s.layout_pending()) { // A first open laid out a little more
            if (try r.s.layout_step()) try r.show_page_count();
            return;
        }
        if (unix_time() / 60 != r.battery_minute) { // In every view
            r.battery_minute = unix_time() / 60;
            a.note_battery();
        }
        if (!r.reading()) return; // The rest only while the page alone is up
        r.pause_wifi();
        if (unix_time() / 60 != a.clock_minute) try a.update_clock();
    }

    /// A couple of minutes into the book, Wi-Fi goes off (wifi_saver.zig).
    fn pause_wifi(r: *Reader) void {
        const at = r.wifi_try_at orelse return;
        if (now_us() < at) return;
        if (r.a.wifi_hands_off) {
            r.wifi_try_at = null;
            return;
        }
        r.wifi_try_at = switch (wifi_saver.pause(now_us() < r.a.downloads_until)) {
            .paused, .never => null,
            .later => now_us() + wifi_retry_us,
        };
    }

    // The page alone

    fn on_page(r: *Reader, action: input_mod.Action) !?Outcome {
        switch (action) {
            .tap => |t| try r.tap_page(t.x, t.y, t.us),
            .hold => |h| try r.hold_page(h.x, h.y),
            .swipe => |direction| try r.turn_by(direction + r.a.input.take_turns(), null),
            .pull => {
                r.view = .panel;
                try panel.draw_fresh(r.a, try r.s.ensure(r.s.current, r.s.current));
            },
            else => {},
        }
        return null;
    }

    fn tap_page(r: *Reader, x: i32, y: i32, us: u64) !void {
        const a = r.a;
        if (r.s.on_back(x, y)) {
            if (r.s.back_page()) |back| try r.s.show(back, us, false);
            return;
        }
        if (r.highlight_at(x, y)) |id| return r.select_highlight(id);
        if (r.s.reference_at(x, y)) |target| {
            r.view = .note;
            return note_view.open_note(a, r.s, target);
        }
        if (y < touch_zones.top_zone) return r.open_toolbar();
        try r.turn_by(input_mod.turn_direction(x, a.input.width) + a.input.take_turns(), us);
    }

    /// Holding a picture shows it whole; holding a highlight selects it; holding a word
    /// looks it up; holding and dragging highlights.
    fn hold_page(r: *Reader, x: i32, y: i32) !void {
        const a = r.a;
        if (try r.s.picture_at(x, y)) |img| {
            a.input.drag_slot = null;
            r.s.pause_clock();
            return picture_view.show(a, img);
        }
        if (r.highlight_at(x, y)) |id| {
            a.input.drag_slot = null;
            return r.select_highlight(id);
        }
        const held = try hl.select_from_hold(a, r.s, x, y) orelse return;
        if (held.head == held.fixed) { // Held without moving: look it up, highlight only if asked
            const word = hl.page_words(a, r.s)[held.fixed];
            if (try define.run(a, r.s, word, r.lang) == .close) {
                _ = try hl.show_page(a, r.s, null); // Takes the underline off
                return;
            }
        }
        if (try hl.new_highlight(a, r.s, r.alloc, r.entry, held.fixed, held.head)) |id| try r.select_highlight(id);
    }

    fn highlight_at(r: *Reader, x: i32, y: i32) ?[]const u8 {
        const word = selection.word_under(hl.page_words(r.a, r.s), x, y) orelse return null;
        return highlights.at_word(r.s.highlights.items, word);
    }

    /// Turns `delta` pages, stopping at either end, and saves the place every few turns.
    fn turn_by(r: *Reader, delta: i64, touched_us: ?u64) !void {
        const s = r.s;
        // On a first open, pages ahead may not be laid out yet
        if (delta > 0) try s.layout_until(s.current + @as(usize, @intCast(delta)) + 1);
        const last: i64 = @intCast(s.pages.len - 1);
        const target = std.math.clamp(@as(i64, @intCast(s.current)) + delta, 0, last);
        if (target == s.current) return;
        s.turning = true; // Reading on, not a jump
        try s.show(@intCast(target), touched_us, false);
        r.since_save += 1;
        if (r.since_save >= save_every) r.save();
    }

    // The toolbar, and its Aa sheet

    /// Drawn with the last status at once, then again if it has changed since.
    fn open_toolbar(r: *Reader) !void {
        r.view = .toolbar;
        r.sheet_open = false;
        r.set_input(); // Its controls reach the bottom edge before the next touch arrives
        try r.draw_toolbar(false);
        const fresh = lipc.read(r.a.quick);
        if (fresh.same(&r.a.quick)) return;
        r.a.quick = fresh;
        try r.draw_toolbar(false);
    }

    fn on_toolbar(r: *Reader, action: input_mod.Action) !?Outcome {
        const t = switch (action) {
            .tap => |t| t,
            else => return null,
        };
        const a = r.a;
        const s = r.s;
        switch (toolbar.hit(t.x, t.y, r.sheet())) {
            .stay => {},
            .home => return .library,
            .close => {
                try controls.close_toolbar(a, s, r.sheet_open);
                r.view = .page;
                r.sheet_open = false;
                try a.update_clock();
            },
            .text => {
                r.sheet_open = !r.sheet_open;
                try r.draw_toolbar(!r.sheet_open); // Closing it needs the page back under where it was
            },
            .more => switch (try more.run(a, s, r.entry)) {
                .stay => try r.draw_toolbar(true),
                .page => |target| try r.to_page(target),
                .refresh => try r.to_page(s.current),
            },
            .search => if (try search.run(a, s, r.scratch)) |target| try r.to_page(target) else try r.draw_toolbar(true),
            .goto => if (try goto.run(a, s, r.scratch, r.chapters)) |target| try r.to_page(target) else try r.draw_toolbar(true),
            .bookmark => {
                try bookmark.toggle(a, s, r.alloc, r.entry);
                try r.draw_toolbar(true);
            },
            .chapter_prev, .chapter_next => |direction| {
                const sections = try r.scratch.alloc(u32, s.pages.len);
                for (s.pages, sections) |p, *out| out.* = s.paragraphs[p.para].section;
                s.set_page(toolbar.chapter_target(sections, s.current, direction == .chapter_next));
                try r.draw_toolbar(true);
            },
            .scrub => try controls.drag_scrub(a, s, r.entry.title, r.sheet_open, t.x),
            .sheet => try controls.tap_sheet(a, r.alloc, s, r.entry.title, t.x, t.y),
        }
        return null;
    }

    // A highlight, selected to change or delete

    fn select_highlight(r: *Reader, id: []const u8) !void {
        r.view = .highlight;
        r.active = id;
        r.delete_top = try hl.show_page(r.a, r.s, id);
    }

    fn unselect_highlight(r: *Reader) !void {
        r.view = .page;
        r.active = null;
        r.delete_top = try hl.show_page(r.a, r.s, null);
    }

    /// Delete in its bubble, or a handle dragged to change it; any other tap lets go.
    fn on_highlight(r: *Reader, action: input_mod.Action) !?Outcome {
        const t = switch (action) {
            .tap => |t| t,
            else => return null,
        };
        const a = r.a;
        const id = r.active.?;
        if (r.delete_top) |top| if (hl.in_delete_bubble(a, top, t.x, t.y)) {
            try hl.remove_highlight(a, r.s, r.alloc, r.entry, id);
            try r.unselect_highlight();
            return null;
        };
        const words = hl.page_words(a, r.s);
        if (highlights.word_range(words, r.s.highlights.items, id)) |range| {
            const chosen = words[range.lo .. range.hi + 1];
            const grab_start = selection.near_handle(selection.start_handle(chosen), t.x, t.y);
            if (grab_start or selection.near_handle(selection.end_handle(chosen), t.x, t.y)) {
                try hl.extend_highlight(a, r.s, r.alloc, r.entry, id, grab_start);
                r.delete_top = try hl.show_page(a, r.s, id);
                return null;
            }
        }
        try r.unselect_highlight();
        return null;
    }

    // A note, in a panel over the page

    /// A tap on the panel shows the note's next part, if it has one; anywhere else closes it.
    fn on_note(r: *Reader, action: input_mod.Action) !?Outcome {
        const t = switch (action) {
            .tap => |t| t,
            else => return null,
        };
        const s = r.s;
        if (t.y >= s.note_top) if (s.note_next) |next| {
            try note_view.show_note(r.a, s, next, r.a.screen.height - s.note_top);
            return null;
        };
        r.view = .page;
        try note_view.close_note(r.a, s);
        return null;
    }

    // The light and wireless panel, pulled down from the top

    fn on_panel(r: *Reader, action: input_mod.Action) !?Outcome {
        const t = switch (action) {
            .tap => |t| t,
            else => return null,
        };
        const a = r.a;
        const choice = menu.hit(t.x, t.y);
        const page = try r.s.ensure(r.s.current, r.s.current);
        if (try panel.panel_control(a, page, choice, t.x)) return null;
        switch (choice) {
            .settings => {
                lipc.open_settings();
                return .quit;
            },
            .kindle => return .quit, // noface.sh brings back the Kindle's home
            .close => {
                r.view = .page;
                try panel.close_menu(a, page);
                try a.update_clock();
            },
            else => {},
        }
        return null;
    }
};
