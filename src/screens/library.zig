//! The home screen: browsing the library, searching it, and opening books. The books
//! are loaded in books.zig, and what a book's sheet does is in book_actions.zig.
const std = @import("std");
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

pub fn logged_hit(x: i32, y: i32, index: usize, count: usize, searching: bool) library.Hit {
    const h = library.hit(x, y, index, count, searching);
    std.debug.print("library tap {d},{d}: {s}\n", .{ x, y, @tagName(h) });
    return h;
}

/// After finishing a book of a series: the next one, to read now. Only books on the
/// Kindle can offer it: a series is read from a book's file name, and books in the
/// cloud have none yet.
/// The library takes every touch, even along the bottom edge where the reader ignores
/// a resting thumb (the pager and keyboard are there), and taps act on lift so pressing
/// and holding a book can bring up its actions.
const touches = input_mod.Input.Modes{ .grips = false, .deferred = true, .edge_zones = true };

pub fn log_page(lib: *const Library, index: usize, count: usize) void {
    const range = library.page_range(index, count);
    var i = range.first;
    while (i < range.end) : (i += 1) {
        std.debug.print("cell {d} {d} {s}\n", .{ index, i - range.first, lib.entries[lib.visible[i]].title });
    }
}

/// The books to show: the filter's, without the hero, or while searching every match,
/// the hero too.
const SearchEnd = union(enum) { cancel, search, open: usize };

/// The search sheet, with books matching what's typed listed as it changes. Ends by
/// cancelling (what was searched before stays), searching for what's typed (nothing
/// clears the search), or opening a book from the list, by its entry index.
fn type_search(a: *app.App, lib: *const Library, q: *search.Query) !SearchEnd {
    const kept = q.*;
    var sheet = LibrarySearch{ .a = a, .lib = lib, .q = q };
    const end = try screen.run(a, &sheet);
    // Cancelled, locked or leaving: what was searched before stays
    if (end == null or end.? == .cancel) q.* = kept;
    return end orelse .cancel;
}

/// The search sheet, its matches listed as they're typed.
const LibrarySearch = struct {
    pub const Result = SearchEnd;
    a: *app.App,
    lib: *const Library,
    q: *search.Query,
    matches: [search_sheet.max_rows + 1]usize = undefined,
    shown: usize = 0, // How many of `matches` are listed

    pub fn draw(ls: *LibrarySearch, part: screen.Part) !void {
        const a = ls.a;
        const words = ls.q.words();
        const found = catalog.select(ls.lib.entries, .all, null, words, &ls.matches);
        ls.shown = if (words.len > 0) @min(found, search_sheet.max_rows) else 0;
        try search_sheet.render(a.ui, a.page(a.screen.pixels), words, ls.lib.entries, ls.matches[0..ls.shown], found > search_sheet.max_rows);
        // The keyboard never changes, so after the first time only the part above it does
        const bottom: u32 = if (part == .all) a.screen.height else keyboard.top;
        try a.show_band(search_sheet.top, bottom - search_sheet.top);
    }

    pub fn on_tap(ls: *LibrarySearch, t: screen.Tap) !screen.Step(SearchEnd) {
        switch (typing.key(ls.q, t, typing.anything)) {
            .changed => return .{ .redraw = .changing },
            .enter => return .{ .done = .search },
            .none => {},
        }
        return switch (search_sheet.hit(t.x, t.y, ls.shown)) {
            .cancel => .close,
            .row => |i| .{ .done = if (ls.lib.entries[ls.matches[i]].is_local()) .{ .open = ls.matches[i] } else .search },
            .field, .none => .stay,
        };
    }
};

fn moment(a: *const app.App) library.Moment {
    return .{ .unix = os.unix_time(), .utc_offset = a.utc_offset };
}

/// Shows a library page, and while the screen refreshes, gets the covers of the
/// pages either side ready, so turning to them is quick.
fn show_with_covers(a: *app.App, lib: *Library, buf: []const u8, refresh: hwtcon.Refresh, index: usize, count: usize) !void {
    @memcpy(a.screen.pixels, buf);
    const marker = try a.screen.show(refresh);
    const alloc = lib.arena.allocator();
    library.prepare_covers(alloc, lib.entries, lib.visible[0..count], index + 1);
    if (index > 0) library.prepare_covers(alloc, lib.entries, lib.visible[0..count], index - 1);
    try a.screen.wait_complete(marker);
}

/// What the library does after an action: nothing, draw the page again (a new filter,
/// a page turn, a notice), draw everything again with a flash (back from a book, a
/// reloaded library), or leave noface.
const Next = enum { nothing, page, everything, leave };

pub fn run_library(a: *app.App) !void {
    var b = Browser{ .a = a, .lib = try load_library(a), .buf = a.slots[0].buf };
    defer b.lib.deinit();
    a.slots[0].page = -1;
    // Started while the Kindle is locked: the "going to lock" event has passed, so
    // show the lock screen now, as if it had just arrived. Otherwise the library
    // would sit under a locked Kindle with touch switched off.
    if (lipc.in_screen_saver() == true) a.input.hold_back(.lock);
    a.quick = lipc.read(a.quick); // Once up front, so the first screen never shows blanks
    try b.run();
}

/// The library on screen: which books, in what order, which page of them, and what
/// it's keeping an eye on (a download, the status after a book). `run` draws what the
/// last action asked for, then hands the next action to its handler.
const Browser = struct {
    a: *app.App,
    lib: Library,
    buf: []u8, // The library as last drawn
    filter: catalog.Filter = .all,
    order: catalog.Order = .recent,
    query: search.Query = .{},
    index: usize = 0, // The page of books shown
    hero: ?usize = null, // The book to continue, at the top
    count: usize = 0, // How many books the filter and search let through
    notice: []const u8 = "", // A line for the next drawing only
    /// Set only for a download started here: the library is reloaded every few seconds
    /// until then. Catalog flags can stay stuck, so they never drive this.
    watch_until: u64 = 0,
    /// After a book, Wi-Fi takes a while to come back: the status is read again until then.
    status_until: u64 = 0,

    fn run(b: *Browser) !void {
        var next: Next = .everything;
        while (true) {
            switch (next) {
                .nothing => {},
                .page => try b.show_page(),
                .everything => try b.show_everything(),
                .leave => return,
            }
            b.set_input();
            next = try b.on_action(b.a.input.next());
        }
    }

    /// The library's `touches`, set each time round as a book changes them. It ticks
    /// often while watching a download or the status, else once a minute for the clock
    /// and the battery.
    fn set_input(b: *Browser) void {
        const in = b.a.input;
        in.take(touches);
        const now = now_us();
        in.tick_us = if (now < b.watch_until) download_poll_us else if (now < b.status_until) status_poll_us else idle_tick_us;
    }

    fn on_action(b: *Browser, action: input_mod.Action) !Next {
        return switch (action) {
            .tap => |t| b.on_tap(t.x, t.y),
            .hold => |h| b.on_hold(h.x, h.y),
            .swipe => |direction| b.turn(direction),
            .pull => if (try panel.library_menu(b.a, b.buf)) .leave else .nothing,
            .tick => b.on_tick(),
            .lock => b.on_lock(),
            .power, .computer, .stop => .leave,
            .drag, .drag_end, .unlock => .nothing,
        };
    }

    // Drawing

    /// The books in order, the one to continue, and those the filter and search let
    /// through, with the page kept in range.
    fn arrange(b: *Browser) void {
        catalog.sort(b.lib.entries, b.order);
        b.hero = catalog.pick_hero(b.lib.entries);
        b.count = catalog.select(b.lib.entries, b.filter, if (b.query.words().len > 0) null else b.hero, b.query.words(), b.lib.visible);
        b.index = @min(b.index, library.page_count(b.count) - 1);
    }

    fn render(b: *Browser) !void {
        const a = b.a;
        try library.render(b.lib.arena.allocator(), a.ui, a.page(b.buf), b.lib.entries, b.hero, b.lib.visible[0..b.count], b.index, b.filter, b.order, b.query.words(), b.notice, &a.quick, moment(a));
    }

    /// Back from a book or a reload: everything drawn again with a flash, then the
    /// status read (it may be minutes old) and redrawn without one if it moved on.
    fn show_everything(b: *Browser) !void {
        const a = b.a;
        b.arrange();
        // A book still coming down keeps Wi-Fi on, even once a book is open
        for (b.lib.entries) |e| {
            if (e.availability == .downloading) a.downloads_until = @max(a.downloads_until, now_us() + download_watch_us);
        }
        const t0 = now_us();
        try b.render();
        std.debug.print("library render {d} ms\n", .{(now_us() - t0) / 1000});
        try b.present(.flash);
        b.notice = "";
        a.note_battery();
        try b.refresh_status(.screen);
    }

    fn show_page(b: *Browser) !void {
        b.arrange();
        try b.render();
        try b.present(.screen);
        b.notice = "";
    }

    fn present(b: *Browser, refresh: hwtcon.Refresh) !void {
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
                @memcpy(a.screen.pixels[0..band], b.buf[0..band]);
                try a.screen.wait_complete(try a.screen.show_region(0, 0, a.screen.width, library.status_height, .clock));
            },
        }
    }

    /// The library read again from the Kindle's catalog (after `export`, which has the
    /// Kindle write it out afresh) and the EPUBs, in place of what was shown.
    fn reload(b: *Browser, how: enum { export_first, as_is }) bool {
        if (how == .export_first) catalog_db.export_library();
        const fresh = load_library(b.a) catch return false;
        b.lib.deinit();
        b.lib = fresh;
        return true;
    }

    // Actions

    fn on_tap(b: *Browser, x: i32, y: i32) !Next {
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
                try stats_screen.run(a, b.lib.entries);
                return .page;
            },
            .menu => return if (try panel.library_menu(a, b.buf)) .leave else .nothing,
            .battery => {
                try battery_screen.show(a);
                return .nothing;
            },
            .hero => {
                const h = b.hero orelse return .nothing;
                a.flash(library.hero_rect(a.screen.width));
                return b.open_book(&b.lib.entries[h]);
            },
            .hero_dots => return b.act_on(&b.lib.entries[b.hero orelse return .nothing]),
            .book => |i| {
                const entry = &b.lib.entries[b.lib.visible[i]];
                if (entry.is_local()) {
                    a.flash(library.book_rect(i, b.index));
                    return b.open_book(entry);
                }
                b.notice = if (entry.availability == .downloading)
                    "Still downloading. It will open once it's finished."
                else
                    "Not on this Kindle yet. Use the three dots to download it.";
                return .page;
            },
        }
    }

    /// Holding a book brings up its actions.
    fn on_hold(b: *Browser, x: i32, y: i32) !Next {
        return switch (logged_hit(x, y, b.index, b.count, b.query.words().len > 0)) {
            .book => |i| b.act_on(&b.lib.entries[b.lib.visible[i]]),
            .hero, .hero_dots => b.act_on(&b.lib.entries[b.hero orelse return .nothing]),
            else => .nothing,
        };
    }

    /// A page of books on (1) or back (-1), if there is one.
    fn turn(b: *Browser, direction: i32) Next {
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
        var entry = first;
        while (true) {
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
            const next = &b.lib.entries[catalog.next_in_series(b.lib.entries, entry) orelse break];
            if (!try actions.up_next(a, next, b.buf)) break;
            entry = next;
        }
        return .everything;
    }

    /// A book's actions sheet, and the library read again if they changed it.
    fn act_on(b: *Browser, entry: *catalog.Entry) !Next {
        switch (try actions.book_sheet(b.a, entry, b.lib.entries, b.buf)) {
            .none => return .nothing,
            .redraw => return .everything,
            .reload => _ = b.reload(.as_is),
            .other => _ = b.reload(.export_first),
            .downloading => {
                // Only a download finishes later, so only it is watched
                b.watch_until = now_us() + download_watch_us;
                b.a.downloads_until = b.watch_until; // Wi-Fi stays on for it while reading
                _ = b.reload(.export_first);
            },
        }
        return .everything;
    }

    fn on_tick(b: *Browser) !Next {
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
        return b.reload_if_downloaded();
    }

    /// The library read again, kept only if a book has arrived: a swap without a
    /// redraw would leave the screen showing books by places that moved.
    fn reload_if_downloaded(b: *Browser) Next {
        catalog_db.export_library();
        var fresh = load_library(b.a) catch return .nothing;
        if (fresh.local_count() == b.lib.local_count()) {
            fresh.deinit();
            return .nothing;
        }
        b.lib.deinit();
        b.lib = fresh;
        b.watch_until = 0;
        return .everything;
    }

    fn on_lock(b: *Browser) !Next {
        const a = b.a;
        const hero: ?*const catalog.Entry = if (b.hero) |h| &b.lib.entries[h] else null;
        // Not put back on waking: it's all drawn again, fresh
        if (lock.lock_screen(a, hero, .{ .restore = false }) == .leaving) return .nothing;
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
