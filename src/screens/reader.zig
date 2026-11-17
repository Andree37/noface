//! Reading a book: page turns, and routing taps to the toolbar, panel, notes and highlights.
const std = @import("std");
const assert = std.debug.assert;
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
const lipc = @import("../kindle/lipc.zig");
const hyphen = @import("../layout/hyphen.zig");
const define = @import("reader/define.zig");
const aa = @import("../ui/aa.zig");
const toolbar = @import("../ui/toolbar.zig");
const touch_zones = @import("../kindle/touch.zig");
const input_mod = @import("../kindle/input.zig");
const now_us = os.now_us;
const unix_time = os.unix_time;
const app = @import("../app.zig");
const goto = @import("reader/goto.zig");
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
const screen = @import("screen.zig");
const sess = @import("reader/session.zig");
const hl = @import("reader/highlight.zig");
const note_view = @import("reader/note.zig");
const controls = @import("reader/controls.zig");

pub const save_every = 10;

pub const clock_check_us = 10 * 1000 * 1000;

/// Wi-Fi that couldn't go off yet (a download, Bluetooth) is tried again this often.
const wifi_retry_us = 60 * 1000 * 1000;

/// While a first open is laid out in idle moments, the loop ticks this often.
const layout_tick_us = 1000;

comptime {
    assert(save_every > 1);
    // Laying out ticks far more often than the clock, so the book is ready soon
    assert(layout_tick_us < clock_check_us);
    assert(clock_check_us < wifi_retry_us);
}

/// How reading a book ended: back to the library, leaving noface, or the book
/// couldn't be read (the library says so).
pub const Outcome = enum { library, quit, failed };

/// What the reader shows: the page alone, or something over it, with what that one
/// holds: the toolbar whether its Aa sheet is open below it, the highlight view which
/// highlight is selected.
pub const View = union(enum) {
    page,
    toolbar: struct { sheet_open: bool = false },
    note,
    highlight: struct {
        id: []const u8,
        delete_top: ?u32 = null, // Where its Delete bubble is, when there is one
    },

    /// The Aa sheet's tab, while it's open.
    fn sheet(v: View, kept: aa.Tab) ?aa.Tab {
        return switch (v) {
            .toolbar => |t| if (t.sheet_open) kept else null,
            else => null,
        };
    }
};

/// What a view means for the rest of the reader. While `reading`, the page alone is in
/// front of the reader: the reading clock runs, the clock in the corner keeps time,
/// Wi-Fi may go off, and the Back button can be tapped. On the page a press may become
/// a hold, so taps wait for the finger to lift; controls that sit where a thumb rests
/// turn the thumb filter off; a highlight's handles can reach the screen's edges.
/// How each view takes touches.
// Assertions: a table, which the switch keeps complete.
fn touches_for(view: View) input_mod.Input.Modes {
    const modes: input_mod.Input.Modes = switch (view) {
        // Taps on the lift, so a press can become a hold; a resting thumb is ignored
        .page => .{ .grips = true, .deferred = true, .edge_zones = true },
        .toolbar => input_mod.Input.Modes.sheet,
        // The handles can sit at the screen edges
        .highlight => .{ .grips = true, .deferred = false, .edge_zones = false },
        .note => .{ .grips = true, .deferred = false, .edge_zones = true },
    };
    // Only the page waits for a lift, as only there a press may become a hold
    assert(modes.deferred == (view == .page));
    return modes;
}

/// Whether an action needs every page laid out first: anything but reading on, as
/// menus, Go To and page numbers count from the start of the book.
fn needs_all_pages(
    action: input_mod.Action,
    view: View,
    sheet: ?aa.Tab,
    s: *const sess.Session,
) bool {
    assert(s.layout_pending());
    assert(s.current < s.pages.len);
    return switch (action) {
        .tick, .drag, .drag_end => false,
        .tap => |t| switch (view) {
            // The toolbar, going back from the first page, or the Back button: all count pages
            .page => t.y < touch_zones.top_zone or s.on_back(t.x, t.y) or
                (input_mod.turn_direction(t.x, s.app.input.width) < 0 and s.current == 0),
            // Text settings and closing don't count pages; the toolbar's other buttons do
            .toolbar => switch (toolbar.hit(t.x, t.y, sheet)) {
                .sheet, .close, .stay, .text => false,
                .home, .goto, .bookmark, .search, .more => true,
                .chapter_prev, .chapter_next, .scrub => true,
            },
            // A note's panel and a highlight's handles act on the page on screen
            .note, .highlight => false,
        },
        .swipe => |swipe| swipe.direction < 0 and s.current == 0,
        // Locking, waking and leaving don't count pages, and must not wait for them;
        // nor does holding a word, which looks it up on the page on screen, the
        // charger's bolt, or the quick panel, which only covers the page
        .lock, .unlock, .power, .computer, .stop, .hold, .charger, .pull => false,
    };
}

/// Reads `entry` on its own, as the root of the stack of screens: for the scenario
/// tests, which start in a book. noface opens books from the library (`open`).
pub fn read_book(a: *app.App, entry: *catalog.Entry) !Outcome {
    var r: Reader = undefined;
    try open(&r, a, entry);
    const ending = try screen.run_root(a, &r);
    // A book takes the lock and leaving, so it only ever ends itself
    assert(ending == .done);
    assert(a.book_region.empty()); // Closing, it let go of its memory
    if (ending.done == .failed) return error.BookFailed;
    return ending.done;
}

/// Opens `entry` in `r`, where it stays while it's read (`screen.open`): parses it,
/// finds its pages and the place to open at, and reads its notes. Its first page is
/// shown as it opens; it ends when the reader leaves the book, or noface leaves.
pub fn open(r: *Reader, a: *app.App, entry: *catalog.Entry) !void {
    // Only one book is open at a time, so its regions start empty
    assert(a.book_region.empty());
    assert(a.scratch_region.empty());
    r.* = .{
        .a = a,
        .entry = entry,
        // The open book: parsed text, pages, highlights. An arena, as its region hands
        // out one block after another: all emptied together on close.
        .book_budget = .{
            .name = "book",
            .region = a.book_region,
            .limit = a.book_region.bytes.len,
        },
        // What one action needs, like a Go To list or search results. Emptied after each.
        .scratch_budget = .{
            .name = "scratch",
            .region = a.scratch_region,
            .limit = a.scratch_region.bytes.len,
        },
    };
    r.alloc = r.book_budget.allocator();
    r.scratch = r.scratch_budget.allocator();
    errdefer r.release();
    // The page under a selection: memory only once a word is first held
    const pixels: u32 = @intCast(a.screen.pixels.len);
    r.selecting.clean = try r.book_budget.untouched(u8, pixels);
    try open_book(r);
    assert(r.start < r.s.pages.len);
}

/// Opens the book in its memory: parses it, finds its pages and the place to open at.
fn open_book(r: *Reader) !void {
    const a = r.a;
    const entry = r.entry;
    const t0 = now_us();
    r.data = try file.map(entry.path);
    const parsed = try read_book_parse(a, r.alloc, entry, r.data);
    const book = parsed.book;
    const t1 = now_us();
    const state_path = try a.state_path(&r.path_buffer, entry.path);
    r.state_path = state_path;
    // Kept in the reader, as the session points to it while it lays out
    r.progress = null;
    const opened = try read_book_pages(a, r.alloc, entry, book.paragraphs, .{
        .book_bytes = r.data.len,
        .state_path = state_path,
        .progress = &r.progress,
    });
    std.debug.print("open {s}: {d} pages, parsed in {d} ms, {s} in {d} ms\n", .{
        entry.title,
        opened.pages.len,
        (t1 - t0) / 1000,
        @tagName(opened.source),
        (now_us() - t1) / 1000,
    });
    assert(opened.start < opened.pages.len);
    a.layout.marks = &.{};
    r.session = .{
        .app = a,
        .paragraphs = book.paragraphs,
        .pages = opened.pages,
        .current = opened.start,
        .anchor = opened.pages[opened.start],
        .chapters = book.chapters,
        .seconds_read = opened.seconds_read,
        .pages_path = opened.pages_path,
        .book_bytes = r.data.len,
        .back = opened.back,
        .turns_since_jump = opened.back_turns,
    };
    if (r.progress) |*p| r.session.progress = p;
    r.s = &r.session;
    try read_book_notes(a, r.alloc, entry, state_path, r.s);
    r.chapters = book.chapters;
    r.lang = parsed.lang;
    r.start = opened.start;
    r.last_place = opened.start;
    assert(r.s.current == r.start);
}
/// The book's text and contents, from its file, and its language, whose hyphenation
/// layout is set to.
fn read_book_parse(
    a: *app.App,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    data: []const u8,
) !struct { book: book_model.Book, lang: ?hyphen.Lang } {
    const book = if (entry.is_epub())
        try epub.parse(alloc, a.scratch_region, data)
    else
        try kfx.parse(alloc, data);
    // Positions are u32: a book's paragraphs fit its memory budget, far below that
    assert(book.paragraphs.len <= std.math.maxInt(u32));
    // Both parsers point the contents inside the book, as Go To relies on
    for (book.chapters) |chapter| assert(chapter.para < book.paragraphs.len);
    book_model.plain_body(book.paragraphs);
    const lang = hyphen.detect(book.paragraphs);
    a.layout.hyphenator = a.hyphenator_for(lang);
    std.debug.print("language {s}\n", .{if (lang) |l| @tagName(l) else "unknown"});
    return .{ .book = book, .lang = lang };
}

/// Where a book's pages came from as it opened.
const PagesSource = enum { @"saved pages", @"first pages", @"laid out" };

/// A book's pages as it opens, and the page to open it at.
const Opened = struct {
    pages: []const book_model.Pos,
    pages_path: [:0]const u8,
    start: u32,
    seconds_read: u64,
    source: PagesSource,
    back: ?book_model.Pos, // The Back button's place, as the book was closed
    back_turns: u32,
};

/// The pages: saved ones, or a first few laid out from the reader's place (the rest
/// follow in idle moments), or all of them at once.
fn read_book_pages(
    a: *app.App,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    paragraphs: []const book_model.Paragraph,
    options: struct {
        book_bytes: u64,
        state_path: [:0]const u8,
        progress: *?paginate.Progressive,
    },
) !Opened {
    assert(options.progress.* == null);
    assert(paragraphs.len > 0); // Parsing refuses a book without any
    var pages_buffer: [320]u8 = undefined;
    const pages_name = try page_store.path_for(&pages_buffer, options.state_path);
    const pages_path = try alloc.dupeSentinel(u8, pages_name, 0);
    const pages_key = page_store.key(a, options.book_bytes);
    const stored_pages = page_store.load(alloc, pages_path, pages_key, paragraphs);
    const saved = state.load(options.state_path);
    const from_kindle = state.prefer_kindle(saved, entry.kindle_last);
    // Without saved breaks, lay out a little from the reader's place and show it at
    // once; the rest follows in idle moments. Stock's place is a percent of the
    // pages, so that one needs them all first.
    if (stored_pages == null and !from_kindle) {
        options.progress.* = try read_book_progressive(a, alloc, paragraphs, saved);
    }
    var pages: []const book_model.Pos = &.{};
    var source: PagesSource = .@"laid out";
    if (options.progress.*) |*p| {
        pages = p.pages();
        source = .@"first pages";
    } else if (stored_pages) |stored| {
        pages = stored;
        source = .@"saved pages";
    } else {
        pages = try paginate.book(a, alloc, paragraphs);
    }
    // Saved pages are never none, and a book with paragraphs lays out a page at least
    assert(pages.len > 0);
    if (source == .@"laid out") page_store.save(alloc, pages_path, pages_key, pages);
    // A first open is laid out only from the reader's own place, never stock's
    const from: StartFrom = if (source == .@"first pages")
        .first_laid_out
    else if (from_kindle) .kindle_percent else .saved_place;
    const start = read_book_start(pages, paragraphs, entry, &saved, from);
    assert(start < pages.len);
    // Stock's reader on the book since: its place is elsewhere, and so is Back's
    var back: ?book_model.Pos = null;
    if (saved.back_para) |para| {
        if (!from_kindle) back = place_in(paragraphs, para, saved.back_byte);
    }
    return .{
        .pages = pages,
        .pages_path = pages_path,
        .start = start,
        .seconds_read = saved.seconds,
        .source = source,
        .back = back,
        .back_turns = saved.back_turns,
    };
}

/// A first open's layout, from the reader's saved place, or null when nothing is
/// laid out from there and the whole book is to be laid out instead.
fn read_book_progressive(
    a: *app.App,
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    saved: state.State,
) !?paginate.Progressive {
    // One outside the book starts it from the beginning
    const place = place_in(paragraphs, saved.para, saved.byte) orelse book_model.Pos{};
    assert(place.para <= paragraphs.len);
    // Nothing from there on: null, and it's all laid out instead
    const progress = try paginate.Progressive.start(a, alloc, paragraphs, place) orelse return null;
    assert(std.meta.eql(progress.pages()[0], place));
    return progress;
}

/// A place saved in a file, by its paragraph's text index, in the book: null for one
/// outside it, as the file may be from another edition or damaged.
fn place_in(paragraphs: []const book_model.Paragraph, text_para: u32, byte: u32) ?book_model.Pos {
    const para = book_model.from_text_index(paragraphs, text_para);
    if (para >= paragraphs.len) return null;
    if (byte > paragraphs[para].text.len) return null;
    return .{ .para = para, .byte = byte };
}

/// Where the page a book opens at comes from: the first page laid out on a first open
/// (laid out from the reader's place), stock's percent when the Kindle's own reader
/// was on the book last, else the saved place.
const StartFrom = enum { first_laid_out, kindle_percent, saved_place };

/// The page to open at, from `from`.
fn read_book_start(
    pages: []const book_model.Pos,
    paragraphs: []const book_model.Paragraph,
    entry: *const catalog.Entry,
    saved: *const state.State,
    from: StartFrom,
) u32 {
    assert(pages.len > 0);
    assert(entry.kindle_percent <= 100);
    return switch (from) {
        .first_laid_out => 0,
        .kindle_percent => @intCast(@min(pages.len * entry.kindle_percent / 100, pages.len - 1)),
        .saved_place => @intCast(sess.page_containing(
            pages,
            book_model.from_text_index(paragraphs, saved.para),
            saved.byte,
        )),
    };
}

/// What the reader counts and keeps with the book: words before each paragraph, for
/// time left, and the highlights and bookmarks, from the Kindle's database or, for
/// a book Amazon doesn't sync, from noface's own notes.
fn read_book_notes(
    a: *app.App,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    state_path: [:0]const u8,
    session: *sess.Session,
) !void {
    const paragraphs = session.paragraphs;
    assert(paragraphs.len > 0); // Parsing refuses a book without any
    const words_before = try alloc.alloc(u64, paragraphs.len + 1);
    words_before[0] = 0;
    for (paragraphs, 0..) |p, i| {
        words_before[i + 1] = words_before[i] + (if (p.note) 0 else stats.count_words(p.text));
    }
    session.words_before = words_before;
    assert(session.words_before.len == paragraphs.len + 1);
    session.notes = try .choose(alloc, entry, state_path);
    // The database's answer for each kind, read into this before it's parsed
    const stored = try alloc.alloc(u8, 1024 * 1024);
    const highlight_notes = try session.notes.read(alloc, .highlight, stored);
    const highlights_read = try highlights.parse(alloc, paragraphs, highlight_notes);
    try session.highlights.appendSlice(alloc, highlights_read);
    const bookmark_notes = try session.notes.read(alloc, .bookmark, stored);
    const bookmarks_read = try bookmarks.parse(alloc, paragraphs, bookmark_notes);
    try session.bookmarks.appendSlice(alloc, bookmarks_read);
    std.debug.print("{d} bookmarks loaded\n", .{session.bookmarks.items.len});
    std.debug.print("{d} highlights loaded\n", .{session.highlights.items.len});
    try hl.refresh_marks(a, session, alloc);
}

/// An open book and what's on screen over it, a screen on the stack (screen.zig).
pub const Reader = struct {
    pub const Result = Outcome;
    /// Under what's opened over it, a book takes the lock and leaving itself.
    pub const takes = screen.Takes{ .lock = true, .leave = true };
    a: *app.App,
    entry: *catalog.Entry,
    book_budget: memory.Budget,
    scratch_budget: memory.Budget,
    alloc: std.mem.Allocator = undefined, // The book's, kept while it's open
    scratch: std.mem.Allocator = undefined, // One action's, emptied after it
    data: []const u8 = &.{}, // The book's file, mapped
    path_buffer: [320]u8 = undefined,
    state_path: [:0]const u8 = "", // In `path_buffer`
    progress: ?paginate.Progressive = null, // A first open's layout, laid out in idle moments
    session: sess.Session = undefined,
    s: *sess.Session = undefined, // The session above
    chapters: []const book_model.Chapter = &.{},
    lang: ?hyphen.Lang = null,
    start: u32 = 0, // The page it opens at
    reading_started: bool = false, // The first page shown, so its place is saved on leaving
    failed: ?anyerror = null, // The first page couldn't be shown
    view: View = .page,
    since_save: u32 = 0,
    last_place: u32 = 0,
    battery_minute: u64 = 0, // The battery is noted once a minute at most
    /// What's open over the book, if anything, with how it ended once it has; those
    /// that keep their state across openings (a picture, words being selected, Aa's
    /// controls) keep it in their own fields. `opening` is one a handler has just made,
    /// to open.
    over: Over = .none,
    opening: ?screen.Frame = null,
    held: hl.Held = undefined, // The words held, looked up while the definition is open
    pending: controls.Pending = .{}, // The scrubber, an Aa slider, or a card from Aa
    selecting: hl.Selecting = .{}, // Words being selected, or a highlight's end dragged
    picture: picture_view.Viewer = undefined, // A picture held, shown whole

    /// The screens a book opens over itself.
    const Over = union(enum) {
        none,
        lock: screen.Child(lock.Lock),
        menu: screen.Child(more.More),
        searching: screen.Child(search.Search),
        going: screen.Child(goto.GoTo),
        define: screen.Child(define.Define),
        panel: screen.Child(panel.Panel),
        controls,
        selecting,
        extending,
        picture,
    };

    /// The page the book opens at, its place saved as it opens.
    pub fn draw(r: *Reader, part: screen.Part) !void {
        assert(part == .all); // Its views draw themselves as they change
        assert(!r.reading_started);
        r.show_first() catch |err| {
            r.failed = err;
        };
    }

    fn show_first(r: *Reader) !void {
        assert(r.start < r.s.pages.len);
        try r.s.show(r.start, .jump, null, true);
        sess.save_progress(r.entry, r.state_path, r.s, r.s.percent());
        assert(r.s.current == r.start);
        r.reading_started = true;
        r.a.wifi_hands_off = false;
        r.a.wifi_off_at = now_us() + wifi_saver.after_us;
    }

    pub fn on_open(r: *Reader) !screen.Step(Outcome) {
        if (r.failed) |err| return r.fail(err);
        assert(r.reading_started);
        assert(r.view == .page);
        return r.ready();
    }

    /// The input modes for the view on screen, and how often to tick: often while a
    /// first open is still laid out in idle moments, else for the clock.
    pub fn setting(r: *const Reader) input_mod.Input.Scope {
        const tick_us: u64 = if (r.s.layout_pending()) layout_tick_us else clock_check_us;
        // The Back button counts, where a resting thumb otherwise wouldn't
        const exempt = if (r.reading()) r.s.back_zone() else null;
        assert(tick_us > 0);
        return .{ .modes = touches_for(r.view), .tick_us = tick_us, .grip_exempt = exempt };
    }

    pub fn on_tap(r: *Reader, t: screen.Tap) !screen.Step(Outcome) {
        assert(r.over == .none); // In front, nothing over it
        assert(r.opening == null);
        return r.on_act(.{ .tap = t }) catch |err| r.fail(err);
    }

    pub fn on_tick(r: *Reader) !screen.Step(Outcome) {
        assert(r.over == .none); // In front, nothing over it
        assert(r.opening == null);
        return r.on_act(.tick) catch |err| r.fail(err);
    }

    pub fn on_action(r: *Reader, action: input_mod.Action) !screen.Step(Outcome) {
        assert(r.over == .none); // In front, nothing over it
        assert(r.opening == null);
        return r.on_act(action) catch |err| r.fail(err);
    }

    /// Back in front, the screen over it ended.
    pub fn on_resume(r: *Reader) !screen.Step(Outcome) {
        assert(r.over != .none);
        assert(r.reading_started);
        const over = r.over;
        r.over = .none;
        return r.resumed(over) catch |err| r.fail(err);
    }

    /// What follows the screen `over` that has just ended.
    fn resumed(r: *Reader, over: Over) !screen.Step(Outcome) {
        const s = r.s;
        assert(r.over == .none); // Back in front
        assert(r.opening == null);
        switch (over) {
            .none => unreachable,
            // Leaving: what comes next takes the stop
            .lock => |c| if (c.ended() == .done) try r.woken(),
            .menu => |c| switch (c.ended()) {
                .done => |result| switch (result) {
                    .stay => try r.draw_toolbar(true),
                    .page => |target| try r.to_page(target),
                    .refresh => try r.to_page(@intCast(s.current)),
                },
                .closed, .interrupted => try r.draw_toolbar(true),
            },
            .define => |c| try r.defined(c.ended()),
            .panel => |c| {
                // Leaving noface from it: the book closes as every other way out does
                if (try panel.ended(r.a, c.screen.background, c.ended())) return r.finish(.quit);
                try r.a.update_clock();
            },
            .selecting => try r.held_ended(),
            .picture => try picture_view.ended(&r.picture),
            .extending => {
                try hl.extend_ended(&r.selecting, r.a, s, r.alloc);
                try r.show_highlight_page();
            },
            .controls => {
                const title = r.entry.title;
                try controls.resumed(&r.pending, r.a, s, title, r.sheet() != null);
            },
            .searching => |c| try r.paged(c.ended()),
            .going => |c| try r.paged(c.ended()),
        }
        return r.after();
    }

    /// After search or Go To: the page chosen, or the toolbar back.
    fn paged(r: *Reader, ending: screen.Ending(u32)) !void {
        r.invariants();
        assert(r.view == .toolbar); // Search and Go To open from the toolbar
        switch (ending) {
            .done => |target| {
                assert(target < r.s.pages.len);
                try r.to_page(target);
            },
            .closed, .interrupted => try r.draw_toolbar(true),
        }
    }

    /// Opens `child`, kept in `over`, over the book as the handler ends.
    fn open_child(r: *Reader, over: Over) void {
        assert(over != .none);
        assert(r.over == .none);
        r.over = over;
        r.open_placed();
    }

    /// Opens the child already in `over`, made there in place, as the handler ends.
    fn open_placed(r: *Reader) void {
        assert(r.over != .none);
        assert(r.opening == null);
        r.opening = switch (r.over) {
            // Every child's frame, from where it's kept; the rest keep their own
            inline else => |*c| if (@TypeOf(c.*) == void) unreachable else c.frame(),
        };
    }

    /// Opens `f`, the screen `over`, over the book, as the handler ends.
    fn open_over(r: *Reader, over: Over, f: screen.Frame) void {
        assert(over != .none);
        assert(r.over == .none);
        assert(r.opening == null);
        r.over = over;
        r.opening = f;
    }

    /// After a handler: a screen it made opens over the book, else the book waits for
    /// the next action.
    fn after(r: *Reader) screen.Step(Outcome) {
        if (r.opening) |f| {
            assert(r.over != .none);
            r.opening = null;
            return .{ .push = f };
        }
        assert(r.over == .none);
        return r.ready();
    }

    fn woken(r: *Reader) !void {
        assert(!r.a.input.locked);
        r.a.note_battery(); // What sleeping cost
        r.a.quick = lipc.read(r.a.quick); // Hours may have passed
        try r.show_status();
        assert(r.since_save == 0);
    }

    /// An action: what's the same in every view (locking, the clock's tick, leaving)
    /// here, and touches by the view they land on, each in a handler of its own.
    fn on_act(r: *Reader, action: input_mod.Action) !screen.Step(Outcome) {
        assert(r.s.current < r.s.pages.len);
        assert(r.reading_started);
        if (r.s.layout_pending() and needs_all_pages(action, r.view, r.sheet(), r.s)) {
            try r.s.finish_layout();
            // The page's footer gains its count; anything else is about to be redrawn
            if (r.reading()) try r.s.show_footer();
        }
        switch (action) {
            .lock => return r.on_lock(),
            .tick => try r.on_tick_any(),
            .charger => {
                r.a.quick = lipc.read(r.a.quick);
                try r.show_status();
            },
            .power, .computer, .stop => return r.finish(.quit),
            .unlock, .drag, .drag_end => {},
            .tap, .hold, .swipe, .pull => {
                if (try r.on_touch(action)) |outcome| return r.finish(outcome);
            },
        }
        return r.after();
    }

    /// Ready for the next action, the book still in front: what the last one left in
    /// scratch let go of, a jump saved, and the reading clock running only while the
    /// page alone is up.
    fn ready(r: *Reader) screen.Step(Outcome) {
        r.scratch_budget.reset(.keep);
        assert(r.s.current < r.s.pages.len);
        r.save_after_jump();
        if (r.reading()) r.s.resume_clock() else r.s.pause_clock();
        return .stay;
    }

    /// Something went wrong reading the book: it closes, and the library says so.
    fn fail(r: *Reader, err: anyerror) screen.Step(Outcome) {
        std.debug.print("could not open book: {s}\n", .{@errorName(err)});
        // Still open: its file mapped and pages found, until `finish` lets go of them
        assert(r.data.len > 0);
        assert(r.s.pages.len > 0);
        r.failed = err;
        // Whatever a handler meant to open, it won't now
        r.opening = null;
        r.over = .none;
        return r.finish(.failed);
    }

    /// The book closes: its place saved, Wi-Fi back, and its memory let go of.
    fn finish(r: *Reader, outcome: Outcome) screen.Step(Outcome) {
        assert(r.data.len > 0); // Its file mapped until `release` lets go of it
        if (r.reading_started) {
            const percent: ?u32 = switch (outcome) {
                .library, .quit => r.s.percent(),
                // Its pages may be gone (a layout after a settings change failed partway),
                // so how far in it is stays as last saved
                .failed => null,
            };
            sess.save_progress(r.entry, r.state_path, r.s, percent);
            wifi_saver.restore(); // Leaving the book, Wi-Fi comes back
        }
        r.release();
        assert(r.a.book_region.empty());
        return .{ .done = outcome };
    }

    /// Lets go of what the book holds: its file, its pictures and its memory.
    fn release(r: *Reader) void {
        const a = r.a;
        if (r.data.len > 0) file.unmap(r.data);
        r.data = &.{};
        a.pictures.clear(a.alloc); // Its keys point into this book's memory
        // Emptied for the next book, the pages touched handed back
        r.scratch_budget.reset(.give_back);
        r.book_budget.reset(.give_back);
        a.pages_budget.reset(.give_back); // The pages of layouts after settings changes
        assert(a.book_region.empty());
        assert(a.scratch_region.empty());
        r.book_budget.report();
        a.pages_budget.report();
        r.scratch_budget.report();
        a.library_budget.report();
        a.app_budget.report();
        a.decoders_budget.report();
    }

    /// What holds of an open book between actions: its first page shown, and the page
    /// up one of its pages, from its file, still mapped.
    fn invariants(r: *const Reader) void {
        assert(r.reading_started);
        assert(r.s.current < r.s.pages.len);
        assert(r.data.len > 0);
    }

    /// The page alone is up: the reading clock runs, and the page's own corners count.
    fn reading(r: *const Reader) bool {
        return r.view == .page;
    }

    /// The Aa sheet's tab, while it's open.
    fn sheet(r: *const Reader) ?aa.Tab {
        return r.view.sheet(r.a.aa_kept.tab);
    }

    /// A jump (Go To, search, a chapter, the slider) is saved at once: turning page by
    /// page saves every few turns, but a jump may cross half the book.
    fn save_after_jump(r: *Reader) void {
        assert(r.s.current < r.s.pages.len);
        const now: u32 = @intCast(r.s.current);
        const moved = if (now > r.last_place) now - r.last_place else r.last_place - now;
        if (moved > 1 and !r.s.layout_pending()) r.save();
        r.last_place = now;
        assert(r.last_place == r.s.current);
    }

    fn save(r: *Reader) void {
        assert(r.s.current < r.s.pages.len);
        sess.save_progress(r.entry, r.state_path, r.s, r.s.percent());
        r.since_save = 0;
        assert(r.s.shown_us == null); // Saving stops the reading clock; the loop starts it
    }

    fn on_touch(r: *Reader, action: input_mod.Action) !?Outcome {
        // Only touches come here; the rest is the same in every view
        assert(action != .tick);
        assert(action != .lock);
        return switch (r.view) {
            .page => r.on_page(action),
            .toolbar => r.on_toolbar(action),
            .highlight => r.on_highlight(action),
            .note => r.on_note(action),
        };
    }

    // What's on screen, drawn again

    /// After the clock, battery or charger changed: wherever they show.
    fn show_status(r: *Reader) !void {
        r.invariants();
        switch (r.view) {
            .page => try r.a.update_clock(),
            .toolbar => try r.draw_toolbar(false),
            .note, .highlight => {},
        }
    }

    /// After the whole book is laid out: the page count, where it shows.
    fn show_page_count(r: *Reader) !void {
        // Called once the layout is done, with the count known
        assert(r.s.progress == null);
        assert(r.s.current < r.s.pages.len);
        switch (r.view) {
            .page => try r.s.show_footer(),
            .toolbar => try r.draw_toolbar(false),
            .note, .highlight => {},
        }
    }

    fn draw_toolbar(r: *Reader, whole_page: bool) !void {
        assert(r.view == .toolbar);
        assert(r.s.current < r.s.pages.len);
        const sheet_open = r.sheet() != null;
        const drawn: controls.Drawn = .{ .sheet_open = sheet_open, .whole_page = whole_page };
        try controls.draw_toolbar(r.a, r.s, r.entry.title, drawn);
    }

    /// Back to the page alone, at `target`, from whatever was over it.
    fn to_page(r: *Reader, target: u32) !void {
        assert(target < r.s.pages.len);
        r.view = .page;
        try r.s.show(target, .jump, null, true);
        assert(r.s.current == target);
        assert(r.reading());
    }

    // Actions in every view

    /// The lock screen over the book, the place saved first.
    fn on_lock(r: *Reader) screen.Step(Outcome) {
        r.s.pause_clock(); // Asleep isn't reading
        r.save(); // A lock is a natural stop, and anything after it may end noface
        assert(r.since_save == 0);
        r.open_child(.{ .lock = .{ .screen = lock.make(r.a, r.entry, .{}) } });
        return r.after();
    }

    fn on_tick_any(r: *Reader) !void {
        r.invariants();
        const a = r.a;
        if (r.s.layout_pending()) { // A first open laid out a little more
            if (try r.s.layout_step()) try r.show_page_count();
            return;
        }
        const minute = unix_time() / 60;
        if (minute != r.battery_minute) { // In every view
            r.battery_minute = minute;
            a.note_battery();
        }
        assert(r.battery_minute == minute);
        if (!r.reading()) return; // The rest only while the page alone is up
        r.pause_wifi();
        if (unix_time() / 60 != a.clock_minute) try a.update_clock();
    }

    /// A couple of minutes into the book, and again after a dictionary's download,
    /// Wi-Fi goes off (wifi_saver.zig).
    fn pause_wifi(r: *Reader) void {
        // Wi-Fi goes off only while the page alone is up
        assert(r.reading());
        const a = r.a;
        const at = a.wifi_off_at orelse return;
        if (now_us() < at) return;
        if (a.wifi_hands_off) {
            a.wifi_off_at = null;
            return;
        }
        a.wifi_off_at = switch (wifi_saver.pause(now_us() < a.downloads_until)) {
            .paused, .never => null,
            .later => now_us() + wifi_retry_us,
        };
        if (a.wifi_off_at) |next| assert(next > at);
    }

    // The page alone

    fn on_page(r: *Reader, action: input_mod.Action) !?Outcome {
        r.invariants();
        assert(r.view == .page);
        switch (action) {
            .tap => |t| try r.tap_page(t.x, t.y, t.us),
            .hold => |h| try r.hold_page(h.x, h.y),
            .swipe => |swipe| try r.turn_by(swipe.direction + r.a.input.take_turns(), swipe.us),
            .pull => {
                const page = try r.s.ensure(r.s.current, r.s.current);
                r.open_child(.{ .panel = .{ .screen = panel.open(r.a, page) } });
            },
            else => {},
        }
        return null;
    }

    fn tap_page(r: *Reader, x: i32, y: i32, us: u64) !void {
        r.invariants();
        assert(r.view == .page);
        const a = r.a;
        if (r.s.on_back(x, y)) {
            if (r.s.back_page()) |back| try r.s.show(back, .jump, us, false);
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
        r.invariants();
        assert(r.view == .page);
        const a = r.a;
        if (try r.s.picture_at(x, y)) |img| {
            a.input.drag_slot = null;
            r.s.pause_clock();
            const f = try picture_view.begin(&r.picture, a, img) orelse return;
            return r.open_over(.picture, f);
        }
        if (r.highlight_at(x, y)) |id| {
            a.input.drag_slot = null;
            return r.select_highlight(id);
        }
        const f = try hl.select_from_hold(&r.selecting, a, r.s, x, y) orelse return;
        r.open_over(.selecting, f);
    }

    /// The hold lifted: a word held still is looked up, words dragged over highlighted.
    fn held_ended(r: *Reader) !void {
        assert(r.view == .page);
        const a = r.a;
        const held = try hl.hold_ended(&r.selecting, a, r.s) orelse return;
        r.held = held;
        if (held.head == held.fixed) { // Held without moving: look it up, highlight only if asked
            const words = hl.page_words(a, r.s);
            assert(held.fixed < words.len);
            // Made in place: it points into itself
            r.over = .{ .define = .{ .screen = undefined } };
            try define.begin(&r.over.define.screen, a, r.s, words[held.fixed], r.lang);
            return r.open_placed();
        }
        try r.highlight_held();
    }

    /// The words held, highlighted, and the highlight selected.
    fn highlight_held(r: *Reader) !void {
        const held = r.held;
        assert(held.fixed < hl.page_words(r.a, r.s).len);
        assert(r.view == .page);
        const id = try hl.new_highlight(r.a, r.s, r.alloc, held.fixed, held.head);
        if (id) |selected| try r.select_highlight(selected);
    }

    /// The definition closed: the underline off, or Highlight pressed.
    fn defined(r: *Reader, ending: screen.Ending(define.Choice)) !void {
        assert(r.view == .page); // A word on the page was held
        const choice: define.Choice = switch (ending) {
            .done => |choice| choice,
            .closed, .interrupted => .close,
        };
        // Only Highlight goes on to highlight the word
        if (choice == .highlight) return r.highlight_held();
        _ = try hl.show_page(r.a, r.s, null); // Takes the underline off
        assert(choice == .close);
    }

    fn highlight_at(r: *Reader, x: i32, y: i32) ?[]const u8 {
        assert(r.view == .page);
        assert(r.s.current < r.s.pages.len);
        const word = selection.word_under(hl.page_words(r.a, r.s), x, y) orelse return null;
        return highlights.at_word(r.s.highlights.items, word);
    }

    /// Turns `delta` pages, stopping at either end, and saves the place every few turns.
    fn turn_by(r: *Reader, delta: i64, touched_us: ?u64) !void {
        assert(r.view == .page);
        const s = r.s;
        const current: i64 = @intCast(s.current);
        // On a first open, pages ahead may not be laid out yet
        if (delta > 0) try s.layout_until(@intCast(current + delta + 1));
        const last: i64 = @intCast(s.pages.len - 1);
        const target = std.math.clamp(current + delta, 0, last);
        if (target == current) return;
        try s.show(@intCast(target), .turn, touched_us, false);
        r.since_save += 1;
        if (r.since_save >= save_every) r.save();
        assert(r.since_save < save_every);
    }

    // The toolbar, and its Aa sheet

    /// Drawn with the last status at once, then again if it has changed since.
    fn open_toolbar(r: *Reader) !void {
        r.invariants();
        assert(r.view == .page); // From a tap at the top of the page
        r.view = .{ .toolbar = .{} };
        // Its controls reach the bottom edge before the next touch arrives
        r.a.input.apply(r.setting(), false);
        try r.draw_toolbar(false);
        const fresh = lipc.read(r.a.quick);
        if (fresh.same(&r.a.quick)) return;
        r.a.quick = fresh;
        try r.draw_toolbar(false);
    }

    fn on_toolbar(r: *Reader, action: input_mod.Action) !?Outcome {
        r.invariants();
        assert(r.view == .toolbar);
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
                try controls.close_toolbar(a, s, r.sheet() != null);
                r.view = .page;
                try a.update_clock();
            },
            .text => {
                const opening = r.sheet() == null;
                r.view = .{ .toolbar = .{ .sheet_open = opening } };
                // Closing it needs the page back under where it was
                try r.draw_toolbar(!opening);
            },
            .more => {
                // Made in place: it points into itself
                r.over = .{ .menu = .{ .screen = undefined } };
                try more.begin(&r.over.menu.screen, a, s, r.entry);
                r.open_placed();
            },
            .search => {
                r.open_child(.{ .searching = .{ .screen = search.make(a, s, r.scratch) } });
            },
            .goto => {
                const going = try goto.make(a, s, r.scratch, r.chapters);
                r.open_child(.{ .going = .{ .screen = going } });
            },
            .bookmark => {
                try bookmark.toggle(a, s, r.alloc);
                try r.draw_toolbar(true);
            },
            .chapter_prev, .chapter_next => |direction| {
                const sections = try r.scratch.alloc(u32, s.pages.len);
                for (s.pages, sections) |p, *out| out.* = s.paragraphs[p.para].section;
                const forward = direction == .chapter_next;
                s.set_page(toolbar.chapter_target(sections, s.current, forward), .jump);
                try r.draw_toolbar(true);
            },
            .scrub => r.open_over(.controls, try controls.drag_scrub(&r.pending, a, s, t.x)),
            .sheet => {
                const title = r.entry.title;
                const f = try controls.tap_sheet(&r.pending, a, s, title, t.x, t.y);
                if (f) |opened| r.open_over(.controls, opened);
            },
        }
        return null;
    }

    // A highlight, selected to change or delete

    fn select_highlight(r: *Reader, id: []const u8) !void {
        assert(r.view == .page);
        r.view = .{ .highlight = .{ .id = id } };
        try r.show_highlight_page();
    }

    fn unselect_highlight(r: *Reader) !void {
        assert(r.view == .highlight);
        r.view = .page;
        try r.show_highlight_page();
    }

    /// The page, with the highlight view's highlight selected, and where its Delete
    /// bubble went.
    fn show_highlight_page(r: *Reader) !void {
        r.invariants();
        switch (r.view) {
            .highlight => |*h| h.delete_top = try hl.show_page(r.a, r.s, h.id),
            else => _ = try hl.show_page(r.a, r.s, null),
        }
    }

    /// Delete in its bubble, or a handle dragged to change it; any other tap lets go.
    fn on_highlight(r: *Reader, action: input_mod.Action) !?Outcome {
        assert(r.view == .highlight);
        const t = switch (action) {
            .tap => |t| t,
            else => return null,
        };
        const a = r.a;
        const id = r.view.highlight.id;
        if (r.view.highlight.delete_top) |top| {
            if (hl.in_delete_bubble(a, top, t.x, t.y)) {
                try hl.remove_highlight(a, r.s, r.alloc, id);
                try r.unselect_highlight();
                return null;
            }
        }
        const words = hl.page_words(a, r.s);
        if (highlights.word_range(words, r.s.highlights.items, id)) |range| {
            assert(range.lo <= range.hi);
            const chosen = words[range.lo .. range.hi + 1];
            const grab_start = selection.near_handle(selection.start_handle(chosen), t.x, t.y);
            const grab_end = selection.near_handle(selection.end_handle(chosen), t.x, t.y);
            if (grab_start or grab_end) {
                const f = try hl.extend_highlight(&r.selecting, a, r.s, id, grab_start);
                if (f) |opened| {
                    r.open_over(.extending, opened);
                    return null;
                }
                try r.show_highlight_page();
                return null;
            }
        }
        try r.unselect_highlight();
        return null;
    }

    // A note, in a panel over the page

    /// A tap on the panel shows the note's next part, if it has one; anywhere else closes it.
    fn on_note(r: *Reader, action: input_mod.Action) !?Outcome {
        assert(r.view == .note);
        const t = switch (action) {
            .tap => |t| t,
            else => return null,
        };
        const s = r.s;
        if (t.y >= s.note_top) {
            if (s.note_next) |next| {
                try note_view.show_note(r.a, s, next, r.a.screen.height - s.note_top);
                return null;
            }
        }
        r.view = .page;
        try note_view.close_note(r.a, s);
        assert(r.reading());
        return null;
    }
};
