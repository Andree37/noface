//! The home screen: browsing the library, searching it, and opening books. The books
//! are loaded in books.zig, and what a book's sheet does is in book_actions.zig.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const os = @import("../sys/os.zig");
const file = @import("../sys/file.zig");
const library = @import("../ui/library.zig");
const book_actions = @import("../ui/book_actions.zig");
const catalog_db = @import("../kindle/catalog.zig");
const lipc = @import("../kindle/lipc.zig");
const now_us = os.now_us;
const app = @import("../app.zig");
const hwtcon = @import("../kindle/hwtcon.zig");
const battery_screen = @import("battery.zig");
const panel = @import("panel.zig");
const lock = @import("lock.zig");
const input_mod = @import("../kindle/input.zig");
const screen = @import("screen.zig");
const typing = @import("typing.zig");
const reader = @import("reader.zig");
const keyboard = @import("../ui/keyboard.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const stats_screen = @import("stats.zig");
const search = @import("../model/search.zig");
const books = @import("books.zig");
const actions = @import("book_actions.zig");
const Library = books.Library;
const load_library = books.load_library;

pub const download_poll_us = 5 * 1000 * 1000;

/// After leaving a book, how long and how often the status is read again, for Wi-Fi
/// coming back from airplane mode.
const status_watch_us = 40 * 1000 * 1000;
const status_poll_us = 10 * 1000 * 1000;
/// The library's tick while nothing else is going on: its clock and battery.
const idle_tick_us = 60 * 1_000_000;
pub const download_watch_us = 3 * 60 * 1000 * 1000;

comptime {
    // A watch reads more than once before it runs out, and more often than when idle
    assert(download_poll_us < download_watch_us);
    assert(status_poll_us < status_watch_us);
    assert(download_poll_us < idle_tick_us);
    assert(status_poll_us < idle_tick_us);
    // The search sheet lists its matches above the keyboard
    assert(search_sheet.top < keyboard.top);
}

pub fn logged_hit(x: i32, y: i32, page_index: u32, count: u32, searching: bool) library.Hit {
    assert(page_index < library.page_count(count));
    const h = library.hit(x, y, page_index, count, searching);
    std.debug.print("library tap {d},{d}: {s}\n", .{ x, y, @tagName(h) });
    // A book tapped is one of those shown
    if (h == .book) assert(h.book < count);
    return h;
}

/// After finishing a book of a series: the next one, to read now. Only books on the
/// Kindle can offer it: a series is read from a book's file name, and books in the
/// cloud have none yet.
/// The library takes every touch, even along the bottom edge where the reader ignores
/// a resting thumb (the pager and keyboard are there), and taps act on lift so pressing
/// and holding a book can bring up its actions.
const touches = input_mod.Input.Modes{ .grips = false, .deferred = true, .edge_zones = true };

pub fn log_page(lib: *const Library, page_index: u32, count: u32) void {
    assert(count <= lib.visible.len);
    const range = library.page_range(page_index, count);
    assert(range.first <= range.end);
    assert(range.end <= count);
    for (range.first..range.end) |i| {
        const title = lib.entries[lib.visible[i]].title;
        std.debug.print("cell {d} {d} {s}\n", .{ page_index, i - range.first, title });
    }
}

/// The books to show: the filter's, without the hero, or while searching every match,
/// the hero too.
const SearchEnd = union(enum) { cancel, search, open: u32 };

/// The search sheet, with books matching what's typed listed as it changes. Ends by
/// cancelling (what was searched before stays), searching for what's typed (nothing
/// clears the search), or opening a book from the list, by its entry index.
fn type_search(a: *app.App, lib: *const Library, q: *search.Query) !SearchEnd {
    assert(q.len <= q.buf.len);
    const kept = q.*;
    var sheet = LibrarySearch{ .a = a, .lib = lib, .q = q };
    const end = try screen.run(a, &sheet);
    // Cancelled, locked or leaving: what was searched before stays
    if (end == null or end.? == .cancel) q.* = kept;
    const result = end orelse .cancel;
    // Only a book on the Kindle opens from the list
    if (result == .open) assert(lib.entries[result.open].is_local());
    return result;
}

/// The search sheet, its matches listed as they're typed.
const LibrarySearch = struct {
    pub const Result = SearchEnd;
    a: *app.App,
    lib: *const Library,
    q: *search.Query,
    /// One more than the rows, to tell whether there are more matches than shown.
    matches: [search_sheet.max_rows + 1]u32 = undefined,
    shown: u32 = 0, // How many of `matches` are listed

    pub fn draw(ls: *LibrarySearch, part: screen.Part) !void {
        const a = ls.a;
        const words = ls.q.words();
        const found = catalog.select(ls.lib.entries, .all, null, words, &ls.matches);
        assert(found <= ls.matches.len);
        ls.shown = if (words.len > 0) @min(found, search_sheet.max_rows) else 0;
        assert(ls.shown <= search_sheet.max_rows);
        const listed = ls.matches[0..ls.shown];
        const more = found > search_sheet.max_rows;
        const page = a.page(a.screen.pixels);
        try search_sheet.render(a.ui, page, words, ls.lib.entries, listed, more);
        // The keyboard never changes, so after the first time only the part above it does
        const bottom: u32 = if (part == .all) a.screen.height else keyboard.top;
        try a.show_band(search_sheet.top, bottom - search_sheet.top);
    }

    pub fn on_tap(ls: *LibrarySearch, t: screen.Tap) !screen.Step(SearchEnd) {
        assert(ls.shown <= search_sheet.max_rows);
        switch (typing.key(ls.q, t, typing.anything)) {
            .changed => return .{ .redraw = .changing },
            .enter => return .{ .done = .search },
            .none => {},
        }
        return switch (search_sheet.hit(t.x, t.y, ls.shown)) {
            .cancel => .close,
            .row => |i| {
                // A row tapped is one of those listed
                assert(i < ls.shown);
                const entry_index = ls.matches[i];
                if (!ls.lib.entries[entry_index].is_local()) return .{ .done = .search };
                return .{ .done = .{ .open = entry_index } };
            },
            .field, .none => .stay,
        };
    }
};

fn moment(a: *const app.App) library.Moment {
    return .{ .unix = os.unix_time(), .utc_offset = a.utc_offset };
}

/// Shows a library page, and while the screen refreshes, gets the covers of the
/// pages either side ready, so turning to them is quick.
fn show_with_covers(
    a: *app.App,
    lib: *Library,
    buffer: []const u8,
    refresh: hwtcon.Refresh,
    page_index: u32,
    count: u32,
) !void {
    assert(buffer.len == a.screen.pixels.len);
    assert(count <= lib.visible.len);
    @memcpy(a.screen.pixels, buffer);
    const marker = try a.screen.show(refresh);
    const alloc = lib.arena.allocator();
    const visible = lib.visible[0..count];
    library.prepare_covers(alloc, lib.entries, visible, page_index + 1);
    if (page_index > 0) library.prepare_covers(alloc, lib.entries, visible, page_index - 1);
    try a.screen.wait_complete(marker);
}

/// What the library does after an action: nothing, draw the page again (a new filter,
/// a page turn, a notice), draw everything again with a flash (back from a book, a
/// reloaded library), leave noface, or open a screen over it.
const Next = union(enum) { nothing, page, everything, leave, open: screen.Frame };

pub fn run_library(a: *app.App) !void {
    var b = Browser{ .a = a, .lib = try load_library(a), .buf = a.slots[0].buf };
    defer b.lib.deinit();
    assert(b.lib.visible.len == b.lib.entries.len);
    assert(b.buf.len == a.screen.pixels.len);
    a.slots[0].page = -1;
    // Started while the Kindle is locked: the "going to lock" event has passed, so
    // show the lock screen now, as if it had just arrived. Otherwise the library
    // would sit under a locked Kindle with touch switched off.
    if (lipc.in_screen_saver() == true) a.input.hold_back(.lock);
    a.quick = lipc.read(a.quick); // Once up front, so the first screen never shows blanks
    const ending = try screen.run_root(a, &b);
    // Only leaving ends it: a lock or a stop goes to it, never past it
    assert(ending == .done);
}

/// The library on screen: which books, in what order, which page of them, and what
/// it's keeping an eye on (a download, the status after a book). The screen at the
/// root of the stack (screen.zig): each handler says what to draw next.
const Browser = struct {
    a: *app.App,
    lib: Library,
    buf: []u8, // The library as last drawn
    filter: catalog.Filter = .all,
    order: catalog.Order = .recent,
    query: search.Query = .{},
    index: u32 = 0, // The page of books shown
    hero: ?u32 = null, // The book to continue, at the top
    count: u32 = 0, // How many books the filter and search let through
    notice: []const u8 = "", // A line for the next drawing only
    /// Set only for a download started here: the library is reloaded every few seconds
    /// until then. Catalog flags can stay stuck, so they never drive this.
    watch_until: u64 = 0,
    /// After a book, Wi-Fi takes a while to come back: the status is read again until then.
    status_until: u64 = 0,
    /// The screen open over the library, if one is, and how it ended once it has.
    over: Over = .none,
    over_ending: ?screen.Ending(void) = null,
    stats: stats_screen.Stats = undefined, // While `over` is .stats
    bubble: battery_screen.Bubble = undefined, // While `over` is .battery
    lock: lock.Lock = undefined, // While `over` is .lock

    /// The screens the library opens over itself.
    const Over = enum { none, stats, battery, lock };

    pub const Result = void;
    /// The home screen: under every other, it takes the lock and leaving.
    pub const takes = screen.Takes{ .lock = true, .leave = true };

    /// Everything drawn again with a flash (first, and back from a book or a reload),
    /// or the page alone (a new filter, a page turn, a notice).
    pub fn draw(b: *Browser, part: screen.Part) !void {
        switch (part) {
            .all => try b.show_everything(),
            .changing => try b.show_page(),
        }
        // Whatever was drawn, the page shown is one there is, of the books let through
        assert(b.count <= b.lib.visible.len);
        assert(b.index < library.page_count(b.count));
    }

    /// The library's `touches`, set each time round as a book changes them. It ticks
    /// often while watching a download or the status, else once a minute for the clock
    /// and the battery.
    pub fn setting(b: *const Browser) input_mod.Input.Scope {
        const now = now_us();
        var tick_us: u64 = idle_tick_us;
        if (now < b.watch_until) {
            tick_us = download_poll_us;
        } else if (now < b.status_until) {
            tick_us = status_poll_us;
        }
        assert(tick_us >= download_poll_us);
        assert(tick_us <= idle_tick_us);
        return .{ .modes = touches, .tick_us = tick_us };
    }

    pub fn on_tap(b: *Browser, t: screen.Tap) !screen.Step(void) {
        assert(b.count <= b.lib.visible.len);
        assert(b.index < library.page_count(b.count));
        return step(try b.on_tap_at(t.x, t.y));
    }

    pub fn on_tick(b: *Browser) !screen.Step(void) {
        assert(b.count <= b.lib.visible.len);
        assert(b.index < library.page_count(b.count));
        return step(try b.on_tick_next());
    }

    pub fn on_action(b: *Browser, action: input_mod.Action) !screen.Step(void) {
        assert(b.buf.len == b.a.screen.pixels.len);
        assert(b.count <= b.lib.visible.len);
        const next: Next = switch (action) {
            .tap, .tick => unreachable, // `on_tap` and `on_tick` take those
            .hold => |h| try b.on_hold(h.x, h.y),
            .swipe => |direction| b.turn(direction),
            .pull => if (try panel.library_menu(b.a, b.buf)) .leave else .nothing,
            .lock => b.on_lock(),
            .power, .computer, .stop => .leave,
            .drag, .drag_end, .unlock => .nothing,
        };
        return step(next);
    }

    /// What `Next` asks of the screen.
    fn step(next: Next) screen.Step(void) {
        return switch (next) {
            .nothing => .stay,
            .page => .{ .redraw = .changing },
            .everything => .{ .redraw = .all },
            .leave => .{ .done = {} },
            .open => |f| .{ .push = f },
        };
    }

    /// Back in front, the screen over it ended: whatever way, what it covered comes back.
    pub fn on_resume(b: *Browser) !screen.Step(void) {
        // Only a screen the library opened ends back to it
        assert(b.over != .none);
        assert(b.over_ending != null);
        const over = b.over;
        b.over = .none;
        switch (over) {
            .none => unreachable,
            .stats => return .{ .redraw = .changing },
            .battery => {
                try battery_screen.put_back(b.a);
                return .stay;
            },
            .lock => return step(b.on_woken(b.over_ending.?)),
        }
    }

    /// Opens `over` over the library.
    fn open_over(b: *Browser, over: Over) Next {
        assert(over != .none);
        assert(b.over == .none);
        b.over = over;
        return .{ .open = switch (over) {
            .none => unreachable,
            .stats => screen.open(&b.stats, &b.over_ending),
            .battery => screen.open(&b.bubble, &b.over_ending),
            .lock => screen.open(&b.lock, &b.over_ending),
        } };
    }

    // Drawing

    /// The books in order, the one to continue, and those the filter and search let
    /// through, with the page kept in range.
    fn arrange(b: *Browser) void {
        assert(b.lib.visible.len == b.lib.entries.len);
        catalog.sort(b.lib.entries, b.order);
        const hero = catalog.pick_hero(b.lib.entries);
        b.hero = hero;
        // While searching, every match is listed, the hero too
        const left_out = if (b.query.words().len > 0) null else hero;
        const words = b.query.words();
        b.count = catalog.select(b.lib.entries, b.filter, left_out, words, b.lib.visible);
        b.index = @min(b.index, library.page_count(b.count) - 1);
        assert(b.count <= b.lib.visible.len);
        assert(b.index < library.page_count(b.count));
        if (b.hero) |h| assert(b.lib.entries[h].is_local());
    }

    fn render(b: *Browser) !void {
        const a = b.a;
        assert(b.count <= b.lib.visible.len);
        assert(b.buf.len == a.screen.pixels.len);
        try library.render(
            b.lib.arena.allocator(),
            a.ui,
            a.page(b.buf),
            b.lib.entries,
            b.hero,
            b.lib.visible[0..b.count],
            b.index,
            b.filter,
            b.order,
            b.query.words(),
            b.notice,
            &a.quick,
            moment(a),
        );
    }

    /// Back from a book or a reload: everything drawn again with a flash, then the
    /// status read (it may be minutes old) and redrawn without one if it moved on.
    fn show_everything(b: *Browser) !void {
        const a = b.a;
        b.arrange();
        assert(b.index < library.page_count(b.count));
        // A book still coming down keeps Wi-Fi on, even once a book is open
        for (b.lib.entries) |e| {
            if (e.availability == .downloading) {
                a.downloads_until = @max(a.downloads_until, now_us() + download_watch_us);
            }
        }
        const t0 = now_us();
        try b.render();
        std.debug.print("library render {d} ms\n", .{(now_us() - t0) / 1000});
        try b.present(.flash);
        b.notice = "";
        a.note_battery();
        try b.refresh_status(.screen);
        // A notice is for one drawing only
        assert(b.notice.len == 0);
    }

    fn show_page(b: *Browser) !void {
        b.arrange();
        assert(b.index < library.page_count(b.count));
        try b.render();
        try b.present(.screen);
        b.notice = "";
        // A notice is for one drawing only
        assert(b.notice.len == 0);
    }

    fn present(b: *Browser, refresh: hwtcon.Refresh) !void {
        assert(b.count <= b.lib.visible.len);
        assert(b.index < library.page_count(b.count));
        try show_with_covers(b.a, &b.lib, b.buf, refresh, b.index, b.count);
        log_page(&b.lib, b.index, b.count);
    }

    /// Reads the clock, battery, charger and Wi-Fi again, and if anything moved on,
    /// redraws them: the whole screen, or only the status strip along the top (no
    /// flash, and a notice on the page stays).
    fn refresh_status(b: *Browser, area: enum { screen, strip }) !void {
        const a = b.a;
        const fresh = lipc.read(a.quick);
        if (fresh.same(&a.quick)) return;
        a.quick = fresh;
        try b.render();
        switch (area) {
            .screen => try a.present(b.buf, .screen),
            .strip => {
                const band = library.status_height * a.screen.stride;
                assert(library.status_height <= a.screen.height);
                assert(band <= b.buf.len);
                @memcpy(a.screen.pixels[0..band], b.buf[0..band]);
                const strip_height = library.status_height;
                const marker = try a.screen.show_region(0, 0, a.screen.width, strip_height, .clock);
                try a.screen.wait_complete(marker);
            },
        }
    }

    /// The library read again from the Kindle's catalog (after `export`, which has the
    /// Kindle write it out afresh) and the EPUBs, in place of what was shown.
    fn reload(b: *Browser, how: enum { export_first, as_is }) bool {
        if (how == .export_first) catalog_db.export_library();
        const fresh = load_library(b.a) catch return false;
        assert(fresh.visible.len == fresh.entries.len);
        b.lib.deinit();
        b.lib = fresh;
        return true;
    }

    // Actions

    fn on_tap_at(b: *Browser, x: i32, y: i32) !Next {
        const a = b.a;
        switch (logged_hit(x, y, b.index, b.count, b.query.words().len > 0)) {
            .none => return .nothing,
            .next => return b.turn(1),
            .prev => return b.turn(-1),
            .search => return b.search_books(),
            .clear_search => {
                b.query = .{};
                b.index = 0;
                return .page;
            },
            .tab => |f| {
                b.filter = f;
                b.index = 0;
                return .page;
            },
            .sort => {
                b.order = b.order.next();
                b.index = 0;
                return .page;
            },
            .stats => {
                b.stats = stats_screen.make(a, b.lib.entries);
                return b.open_over(.stats);
            },
            .menu => return if (try panel.library_menu(a, b.buf)) .leave else .nothing,
            .battery => {
                battery_screen.open(a, &b.bubble);
                return b.open_over(.battery);
            },
            .hero => {
                const h = b.hero orelse return .nothing;
                assert(h < b.lib.entries.len);
                a.flash(library.hero_rect(a.screen.width));
                return b.open_book(&b.lib.entries[h]);
            },
            .hero_dots => return b.act_on(&b.lib.entries[b.hero orelse return .nothing]),
            .book => |i| {
                assert(i < b.count);
                const entry = &b.lib.entries[b.lib.visible[i]];
                if (entry.is_local()) {
                    a.flash(library.book_rect(i, b.index));
                    return b.open_book(entry);
                }
                if (entry.availability == .downloading) {
                    b.notice = "Still downloading. It will open once it's finished.";
                } else {
                    b.notice = "Not on this Kindle yet. Use the three dots to download it.";
                }
                return .page;
            },
        }
    }

    /// Holding a book brings up its actions.
    fn on_hold(b: *Browser, x: i32, y: i32) !Next {
        return switch (logged_hit(x, y, b.index, b.count, b.query.words().len > 0)) {
            .book => |i| {
                assert(i < b.count);
                return b.act_on(&b.lib.entries[b.lib.visible[i]]);
            },
            .hero, .hero_dots => b.act_on(&b.lib.entries[b.hero orelse return .nothing]),
            else => .nothing,
        };
    }

    /// A page of books on (1) or back (-1), if there is one.
    fn turn(b: *Browser, direction: i32) Next {
        assert(direction == 1 or direction == -1);
        assert(b.index < library.page_count(b.count));
        if (direction > 0 and b.index + 1 < library.page_count(b.count)) {
            b.index += 1;
            return .page;
        }
        if (direction < 0 and b.index > 0) {
            b.index -= 1;
            return .page;
        }
        return .nothing;
    }

    fn search_books(b: *Browser) !Next {
        assert(b.query.len <= b.query.buf.len);
        switch (try type_search(b.a, &b.lib, &b.query)) {
            .cancel => {
                try b.a.present(b.buf, .screen); // What was there before the sheet
                return .nothing;
            },
            .search => {
                b.index = 0;
                return .page;
            },
            .open => |e| {
                assert(b.lib.entries[e].is_local());
                b.query = .{};
                b.index = 0;
                return b.open_book(&b.lib.entries[e]);
            },
        }
    }

    /// Reads a book, and on finishing one of a series offers the next, maybe going
    /// straight on with it.
    fn open_book(b: *Browser, first: *catalog.Entry) !Next {
        const a = b.a;
        // Only books on the Kindle are opened: the hero, a book on it, or a match
        assert(first.is_local());
        assert(b.lib.entries.len > 0);
        var entry = first;
        // Each next book is further on in its series, so none comes round twice
        for (0..b.lib.entries.len) |_| {
            const was_read = entry.is_read();
            const outcome = reader.read_book(a, entry) catch |err| blk: {
                std.debug.print("could not open book: {s}\n", .{@errorName(err)});
                b.notice = "This book can't be opened here.";
                break :blk reader.Outcome.library;
            };
            if (outcome == .quit) return .leave;
            a.slots[0].page = -1;
            b.status_until = now_us() + status_watch_us; // Wi-Fi coming back, and the like
            if (was_read or !entry.is_read()) break;
            const next_index = catalog.next_in_series(b.lib.entries, entry) orelse break;
            const next = &b.lib.entries[next_index];
            // The next is one not read yet, so never the book just finished
            assert(!next.is_read());
            assert(next != entry);
            if (!try actions.up_next(a, next, b.buf)) break;
            entry = next;
        }
        return .everything;
    }

    /// A book's actions sheet, and the library read again if they changed it.
    fn act_on(b: *Browser, entry: *catalog.Entry) !Next {
        assert(b.buf.len == b.a.screen.pixels.len);
        switch (try actions.book_sheet(b.a, entry, b.lib.entries, b.buf)) {
            .none => return .nothing,
            .redraw => return .everything,
            .reload => _ = b.reload(.as_is),
            .other => _ = b.reload(.export_first),
            .downloading => {
                // Only a download finishes later, so only it is watched
                b.watch_until = now_us() + download_watch_us;
                b.a.downloads_until = b.watch_until; // Wi-Fi stays on for it while reading
                assert(b.watch_until > 0);
                _ = b.reload(.export_first);
            },
        }
        return .everything;
    }

    fn on_tick_next(b: *Browser) !Next {
        const now = now_us();
        // The status: the whole screen while it's settling after a book; else just the
        // strip, once a minute or at once when a charger comes or goes
        const charger = b.a.input.charger_changed;
        b.a.input.charger_changed = false;
        if (now < b.status_until) {
            try b.refresh_status(.screen);
        } else if (charger or now >= b.watch_until) {
            try b.refresh_status(.strip);
        }
        // A download being watched: the library again, in case it's finished. When the
        // watch runs out, one last look, for one that finished since the last
        if (b.watch_until == 0) return .nothing;
        if (now >= b.watch_until) b.watch_until = 0;
        // Still watching, or the watch just ended
        if (b.watch_until != 0) assert(now < b.watch_until);
        return b.reload_if_downloaded();
    }

    /// The library read again, kept only if a book has arrived: a swap without a
    /// redraw would leave the screen showing books by places that moved.
    fn reload_if_downloaded(b: *Browser) Next {
        catalog_db.export_library();
        var fresh = load_library(b.a) catch return .nothing;
        assert(fresh.visible.len == fresh.entries.len);
        if (fresh.local_count() == b.lib.local_count()) {
            fresh.deinit();
            return .nothing;
        }
        b.lib.deinit();
        b.lib = fresh;
        b.watch_until = 0;
        return .everything;
    }

    fn on_lock(b: *Browser) Next {
        var hero: ?*const catalog.Entry = null;
        if (b.hero) |h| {
            assert(h < b.lib.entries.len);
            hero = &b.lib.entries[h];
        }
        // Not put back on waking: it's all drawn again, fresh
        b.lock = lock.make(b.a, hero, .{ .restore = false });
        return b.open_over(.lock);
    }

    /// Woken, or the lock screen ended as noface leaves (which goes on to leave).
    fn on_woken(b: *Browser, ending: screen.Ending(void)) Next {
        const a = b.a;
        if (ending != .done) return .nothing;
        assert(!a.input.locked); // Awake, back in front
        a.note_battery(); // What sleeping (or charging) did
        a.quick = lipc.read(a.quick); // The clock and battery may be hours old
        // A download may have finished while the Kindle slept
        for (b.lib.entries) |e| {
            if (e.availability == .downloading) {
                _ = b.reload(.export_first);
                break;
            }
        }
        return .everything;
    }
};
