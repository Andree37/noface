//! The home screen: the library, a book's actions, and opening books.
const std = @import("std");
const dir = @import("../sys/dir.zig");
const epub = @import("../epub/epub.zig");
const card = @import("../ui/card.zig");
const catalog = @import("../model/catalog.zig");
const os = @import("../sys/os.zig");
const file = @import("../sys/file.zig");
const kfx = @import("../kindle/kfx.zig");
const library = @import("../ui/library.zig");
const book_actions = @import("../ui/sheet.zig");
const state = @import("../sys/state.zig");
const catalog_db = @import("../kindle/catalog.zig");
const lipc = @import("../kindle/lipc.zig");
const store = @import("../kindle/store.zig");
const nowUs = os.nowUs;
const app = @import("../app.zig");
const hwtcon = @import("../kindle/hwtcon.zig");
const battery_screen = @import("battery.zig");
const series_screen = @import("series.zig");
const cover_image = @import("../gfx/image.zig");
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

pub const download_poll_us = 5 * 1000 * 1000;

/// After leaving a book, how long and how often the status is read again, for Wi-Fi
/// coming back from airplane mode.
const status_watch_us = 40 * 1000 * 1000;
const status_poll_us = 10 * 1000 * 1000;
/// The library's tick while nothing else is going on: its clock and battery.
const idle_tick_us = 60 * 1_000_000;
pub const download_watch_us = 3 * 60 * 1000 * 1000;

pub fn loggedHit(x: i32, y: i32, index: usize, count: usize, searching: bool) library.Hit {
    const h = library.hit(x, y, index, count, searching);
    std.debug.print("library tap {d},{d}: {s}\n", .{ x, y, @tagName(h) });
    return h;
}

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    data: []const u8,
    entries: []catalog.Entry,
    visible: []usize,

    fn deinit(l: *Library) void {
        l.arena.deinit();
        file.unmap(l.data);
    }

    fn localCount(l: *const Library) usize {
        var n: usize = 0;
        for (l.entries) |e| {
            if (e.isLocal()) n += 1;
        }
        return n;
    }
};


/// EPUBs copied over the cable. The Kindle's catalog doesn't list them, so noface finds
/// them itself, reading title and author from each book, and its cover once into a file
/// beside the book's state.
fn addEpubs(a: *app.App, alloc: std.mem.Allocator, catalog_entries: []catalog.Entry) ![]catalog.Entry {
    const paths = dir.findFiles(alloc, a.documents, ".epub") catch return catalog_entries;
    if (paths.len == 0) return catalog_entries;
    var out: std.ArrayList(catalog.Entry) = .empty;
    try out.appendSlice(alloc, catalog_entries);
    var path_buf: [320]u8 = undefined;
    var cover_buf: [320]u8 = undefined;
    next: for (paths) |path| {
        for (catalog_entries) |e| {
            if (std.mem.eql(u8, e.path, path)) continue :next;
        }
        const data = file.map(path) catch continue;
        defer file.unmap(data);
        const state_path = try a.statePath(&path_buf, path);
        const cover_path = try state.sibling(&cover_buf, state_path, "cover");
        const have_cover = if (file.map(cover_path)) |c| blk: {
            file.unmap(c);
            break :blk true;
        } else |_| false;
        const about = epub.info(alloc, data, !have_cover) catch continue;
        if (about.cover) |bytes| state.writeSmall(cover_path, bytes);
        const saved = state.load(state_path);
        try out.append(alloc, .{
            .path = path,
            .title = if (about.title.len > 0) about.title else std.fs.path.stem(path),
            .author = about.author,
            .percent = @min(saved.percent orelse 0, 100),
            .finished = saved.finished,
            .last = saved.opened,
            .seconds_read = saved.seconds,
            .thumbnail = if (have_cover or about.cover != null) try alloc.dupeSentinel(u8, cover_path, 0) else "",
            .kind = "EPUB",
            // The book's own metadata first, else its file name, as for Kindle books
            .series = if (about.series.len > 0) about.series else if (catalog.seriesFromFileName(path)) |f| f.name else "",
            .series_index = if (about.series.len > 0) about.series_index else if (catalog.seriesFromFileName(path)) |f| f.index else 0,
        });
    }
    return out.items;
}

/// The catalog's downloading flag can stay set long after a download ended, so
/// the file decides: a partial book points past its own end.
pub fn isCompleteBook(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    const data = file.map(path) catch return false;
    defer file.unmap(data);
    return kfx.isComplete(data);
}

pub fn loadLibrary(a: *app.App) !Library {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const data = try file.map(a.library_path);
    const entries = try catalog_db.parse(alloc, data);
    var path_buf: [320]u8 = undefined;
    for (entries) |*e| {
        if (e.availability == .downloading and isCompleteBook(e.path)) e.availability = .local;
        if (!e.isLocal()) continue;
        const saved = state.load(try a.statePath(&path_buf, e.path));
        e.seconds_read = saved.seconds;
        if (state.preferKindle(saved, e.kindle_last)) continue;
        if (saved.percent) |p| e.percent = @min(p, 100);
        e.last = @max(e.last, saved.opened);
    }
    const all = try addEpubs(a, alloc, entries);
    series_screen.apply(alloc, a.state_dir, all); // Series set by hand win
    // Allocated before the arena is copied into the result: a block it adds after
    // would be known only to this copy, and never freed
    const visible = try alloc.alloc(usize, all.len);
    return .{ .arena = arena, .data = data, .entries = all, .visible = visible };
}

/// Saves the book as unread, so the reload that follows doesn't bring back 100%.
/// Dated just after the last time it was opened anywhere: newer than stock's
/// percent, so it wins, without moving the book up in recent order.
pub fn forgetFinished(a: *app.App, e: *const catalog.Entry) !void {
    var path_buf: [320]u8 = undefined;
    const path = try a.statePath(&path_buf, e.path);
    var saved = state.load(path);
    saved.percent = 0;
    saved.opened = @max(saved.opened, e.kindle_last) + 1;
    state.save(path, saved);
}

/// What a book's actions changed, which decides what the library does next.
/// What a book's sheet changed: `reload` re-reads the library (a series set by hand),
/// `redraw` only repaints it (a screen of its own was shown and nothing changed).
pub const Change = enum { none, downloading, other, reload, redraw };

/// Shows a book's actions.
pub fn bookSheet(a: *app.App, e: *catalog.Entry, entries: []const catalog.Entry, background: []const u8) !Change {
    std.debug.print("sheet: {s}\n", .{e.title});
    var confirming = false;
    while (true) {
        var list_buf: [4]book_actions.Option = undefined;
        var row_buf: [4]card.Row = undefined;
        var subtitle_buf: [320]u8 = undefined;
        const list = book_actions.options(e, confirming, &list_buf);
        const subtitle = book_actions.subtitle(&subtitle_buf, e, confirming);
        const picked = try app.chooseFromCard(a, background, e.title, subtitle, book_actions.rows(list, &row_buf)) orelse return .none;
        switch (list[picked]) {
            .cancel => return .none,
            .remove => confirming = true,
            .series => return if (try series_screen.choose(a, entries, e)) .reload else .redraw,
            .confirm_remove => {
                store.removeDownload(e.key, e.kind);
                std.debug.print("removed download: {s}\n", .{e.title});
                return .other;
            },
            .download => {
                store.downloadBook(e.key, e.kind);
                std.debug.print("download requested: {s}\n", .{e.title});
                return .downloading;
            },
            .mark_read, .mark_unread => |choice| {
                const done = choice == .mark_read;
                store.markRead(e.key, e.kind, done);
                e.finished = done;
                // The Kindle keeps this for its own books; an EPUB's is kept with its place
                if (e.isEpub()) {
                    var path_buf: [320]u8 = undefined;
                    if (a.statePath(&path_buf, e.path)) |p| {
                        var saved = state.load(p);
                        saved.finished = done;
                        state.save(p, saved);
                    } else |_| {}
                }
                if (done) {
                    a.journal.finish(a.today());
                    app.saveJournal(a);
                }
                if (!done and e.isLocal()) forgetFinished(a, e) catch {};
                return .other;
            },
        }
    }
}

/// After finishing a book of a series: the next one, to read now. Only books on the
/// Kindle can offer it: a series is read from a book's file name, and books in the
/// cloud have none yet.
fn upNext(a: *app.App, next: *const catalog.Entry, background: []u8) !bool {
    if (next.availability != .local) return false;
    var label_buf: [160]u8 = undefined;
    var subtitle_buf: [200]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&subtitle_buf, "Up next in {s}", .{catalog.seriesLabel(&label_buf, next.*)}) catch "Up next";
    std.debug.print("up next: {s}\n", .{next.title});
    // Straight from the reader: its resting-thumb zones would swallow the card's row,
    // which sits along the bottom edge, so take the library's modes now
    a.input.grips = false;
    a.input.deferred = true;
    // Over the page just left, not whatever the reader last kept in this buffer
    @memcpy(background, a.screen.pixels);
    // Its cover beside the title, half the grid's size, when it has one
    const w = cover_image.width / 2;
    const h = cover_image.height / 2;
    const small = if (next.thumbnail.len > 0) cover_image.load(a.alloc, next.thumbnail, w, h) else null;
    defer if (small) |px| a.alloc.free(px);
    const book_cover: ?card.Cover = if (small) |px| .{ .pixels = px, .width = w, .height = h } else null;
    return try app.chooseFromCardWith(a, background, next.title, subtitle, &.{.{ .label = "Read it now" }}, book_cover) != null;
}

pub fn logPage(lib: *const Library, index: usize, count: usize) void {
    const range = library.pageRange(index, count);
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
fn typeSearch(a: *app.App, lib: *const Library, q: *search.Query) !SearchEnd {
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
        try a.showBand(search_sheet.top, bottom - search_sheet.top);
    }

    pub fn onTap(ls: *LibrarySearch, t: screen.Tap) !screen.Step(SearchEnd) {
        switch (typing.key(ls.q, t, typing.anything)) {
            .changed => return .{ .redraw = .changing },
            .enter => return .{ .done = .search },
            .none => {},
        }
        return switch (search_sheet.hit(t.x, t.y, ls.shown)) {
            .cancel => .close,
            .row => |i| .{ .done = if (ls.lib.entries[ls.matches[i]].isLocal()) .{ .open = ls.matches[i] } else .search },
            .field, .none => .stay,
        };
    }
};

fn moment(a: *const app.App) library.Moment {
    return .{ .unix = os.unixTime(), .utc_offset = a.utc_offset };
}

/// Shows a library page, and while the screen refreshes, gets the covers of the
/// pages either side ready, so turning to them is quick.
fn showWithCovers(a: *app.App, lib: *Library, buf: []const u8, refresh: hwtcon.Refresh, index: usize, count: usize) !void {
    @memcpy(a.screen.pixels, buf);
    const marker = try a.screen.show(refresh);
    const alloc = lib.arena.allocator();
    library.prepareCovers(alloc, lib.entries, lib.visible[0..count], index + 1);
    if (index > 0) library.prepareCovers(alloc, lib.entries, lib.visible[0..count], index - 1);
    try a.screen.waitComplete(marker);
}

/// What the library does after an action: nothing, draw the page again (a new filter,
/// a page turn, a notice), draw everything again with a flash (back from a book, a
/// reloaded library), or leave noface.
const Next = enum { nothing, page, everything, leave };

pub fn runLibrary(a: *app.App) !void {
    var b = Browser{ .a = a, .lib = try loadLibrary(a), .buf = a.slots[0].buf };
    defer b.lib.deinit();
    defer a.input.tick_us = 0;
    a.slots[0].page = -1;
    // Started while the Kindle is locked: the "going to lock" event has passed, so
    // show the lock screen now, as if it had just arrived. Otherwise the library
    // would sit under a locked Kindle with touch switched off.
    if (lipc.inScreenSaver() == true) a.input.stashed = .lock;
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
                .page => try b.showPage(),
                .everything => try b.showEverything(),
                .leave => return,
            }
            b.setInput();
            next = try b.onAction(b.a.input.next());
        }
    }

    /// The library takes every touch, even along the bottom edge where the reader
    /// ignores a resting thumb (the pager and keyboard are there), and taps act on lift
    /// so pressing and holding a book can bring up its actions. Set each time round, as
    /// reading a book changes them. It ticks often while watching a download or the
    /// status, else once a minute for the clock and the battery.
    fn setInput(b: *Browser) void {
        const in = b.a.input;
        in.grips = false;
        in.deferred = true;
        const now = nowUs();
        in.tick_us = if (now < b.watch_until) download_poll_us else if (now < b.status_until) status_poll_us else idle_tick_us;
    }

    fn onAction(b: *Browser, action: input_mod.Action) !Next {
        return switch (action) {
            .tap => |t| b.onTap(t.x, t.y),
            .hold => |h| b.onHold(h.x, h.y),
            .swipe => |direction| b.turn(direction),
            .pull => if (try panel.libraryMenu(b.a, b.buf)) .leave else .nothing,
            .tick => b.onTick(),
            .lock => b.onLock(),
            .power, .computer, .stop => .leave,
            .drag, .drag_end, .unlock => .nothing,
        };
    }

    // Drawing

    /// The books in order, the one to continue, and those the filter and search let
    /// through, with the page kept in range.
    fn arrange(b: *Browser) void {
        catalog.sort(b.lib.entries, b.order);
        b.hero = catalog.pickHero(b.lib.entries);
        b.count = catalog.select(b.lib.entries, b.filter, if (b.query.words().len > 0) null else b.hero, b.query.words(), b.lib.visible);
        b.index = @min(b.index, library.pageCount(b.count) - 1);
    }

    fn render(b: *Browser) !void {
        const a = b.a;
        try library.render(b.lib.arena.allocator(), a.ui, a.page(b.buf), b.lib.entries, b.hero, b.lib.visible[0..b.count], b.index, b.filter, b.order, b.query.words(), b.notice, &a.quick, moment(a));
    }

    /// Back from a book or a reload: everything drawn again with a flash, then the
    /// status read (it may be minutes old) and redrawn without one if it moved on.
    fn showEverything(b: *Browser) !void {
        const a = b.a;
        b.arrange();
        // A book still coming down keeps Wi-Fi on, even once a book is open
        for (b.lib.entries) |e| {
            if (e.availability == .downloading) a.downloads_until = @max(a.downloads_until, nowUs() + download_watch_us);
        }
        const t0 = nowUs();
        try b.render();
        std.debug.print("library render {d} ms\n", .{(nowUs() - t0) / 1000});
        try b.present(.flash);
        b.notice = "";
        a.noteBattery();
        try b.refreshStatus(.screen);
    }

    fn showPage(b: *Browser) !void {
        b.arrange();
        try b.render();
        try b.present(.screen);
        b.notice = "";
    }

    fn present(b: *Browser, refresh: hwtcon.Refresh) !void {
        try showWithCovers(b.a, &b.lib, b.buf, refresh, b.index, b.count);
        logPage(&b.lib, b.index, b.count);
    }

    /// Reads the clock, battery, charger and Wi-Fi again, and if anything moved on,
    /// redraws them: the whole screen, or only the status strip along the top (no
    /// flash, and a notice on the page stays).
    fn refreshStatus(b: *Browser, area: enum { screen, strip }) !void {
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
                try a.screen.waitComplete(try a.screen.showRegion(0, 0, a.screen.width, library.status_height, .clock));
            },
        }
    }

    /// The library read again from the Kindle's catalog (after `export`, which has the
    /// Kindle write it out afresh) and the EPUBs, in place of what was shown.
    fn reload(b: *Browser, how: enum { export_first, as_is }) bool {
        if (how == .export_first) catalog_db.exportLibrary();
        const fresh = loadLibrary(b.a) catch return false;
        b.lib.deinit();
        b.lib = fresh;
        return true;
    }

    // Actions

    fn onTap(b: *Browser, x: i32, y: i32) !Next {
        const a = b.a;
        switch (loggedHit(x, y, b.index, b.count, b.query.words().len > 0)) {
            .none => return .nothing,
            .next => return b.turn(1),
            .prev => return b.turn(-1),
            .search => return b.searchBooks(),
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
            .menu => return if (try panel.libraryMenu(a, b.buf)) .leave else .nothing,
            .battery => {
                try battery_screen.show(a);
                return .nothing;
            },
            .hero => {
                const h = b.hero orelse return .nothing;
                a.flash(library.heroRect(a.screen.width));
                return b.openBook(&b.lib.entries[h]);
            },
            .hero_dots => return b.actOn(&b.lib.entries[b.hero orelse return .nothing]),
            .book => |i| {
                const entry = &b.lib.entries[b.lib.visible[i]];
                if (entry.isLocal()) {
                    a.flash(library.bookRect(i, b.index));
                    return b.openBook(entry);
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
    fn onHold(b: *Browser, x: i32, y: i32) !Next {
        return switch (loggedHit(x, y, b.index, b.count, b.query.words().len > 0)) {
            .book => |i| b.actOn(&b.lib.entries[b.lib.visible[i]]),
            .hero, .hero_dots => b.actOn(&b.lib.entries[b.hero orelse return .nothing]),
            else => .nothing,
        };
    }

    /// A page of books on (1) or back (-1), if there is one.
    fn turn(b: *Browser, direction: i32) Next {
        if (direction > 0 and b.index + 1 < library.pageCount(b.count)) {
            b.index += 1;
            return .page;
        }
        if (direction < 0 and b.index > 0) {
            b.index -= 1;
            return .page;
        }
        return .nothing;
    }

    fn searchBooks(b: *Browser) !Next {
        switch (try typeSearch(b.a, &b.lib, &b.query)) {
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
                return b.openBook(&b.lib.entries[e]);
            },
        }
    }

    /// Reads a book, and on finishing one of a series offers the next, maybe going
    /// straight on with it.
    fn openBook(b: *Browser, first: *catalog.Entry) !Next {
        const a = b.a;
        a.input.tick_us = 0;
        var entry = first;
        while (true) {
            const was_read = entry.isRead();
            const outcome = reader.readBook(a, entry) catch |err| blk: {
                std.debug.print("could not open book: {s}\n", .{@errorName(err)});
                b.notice = "This book can't be opened here.";
                break :blk reader.Outcome.library;
            };
            if (outcome == .quit) return .leave;
            a.slots[0].page = -1;
            b.status_until = nowUs() + status_watch_us; // Wi-Fi coming back, and the like
            if (was_read or !entry.isRead()) break;
            const next = &b.lib.entries[catalog.nextInSeries(b.lib.entries, entry) orelse break];
            if (!try upNext(a, next, b.buf)) break;
            entry = next;
        }
        return .everything;
    }

    /// A book's actions sheet, and the library read again if they changed it.
    fn actOn(b: *Browser, entry: *catalog.Entry) !Next {
        switch (try bookSheet(b.a, entry, b.lib.entries, b.buf)) {
            .none => return .nothing,
            .redraw => return .everything,
            .reload => _ = b.reload(.as_is),
            .other => _ = b.reload(.export_first),
            .downloading => {
                // Only a download finishes later, so only it is watched
                b.watch_until = nowUs() + download_watch_us;
                b.a.downloads_until = b.watch_until; // Wi-Fi stays on for it while reading
                _ = b.reload(.export_first);
            },
        }
        return .everything;
    }

    fn onTick(b: *Browser) !Next {
        const now = nowUs();
        // The status: the whole screen while it's settling after a book; else just the
        // strip, once a minute or at once when a charger comes or goes
        const charger = b.a.input.charger_changed;
        b.a.input.charger_changed = false;
        if (now < b.status_until) {
            try b.refreshStatus(.screen);
        } else if (charger or now >= b.watch_until) {
            try b.refreshStatus(.strip);
        }
        // A download being watched: the library again, in case it's finished. When the
        // watch runs out, one last look, for one that finished since the last
        if (b.watch_until == 0) return .nothing;
        if (now >= b.watch_until) b.watch_until = 0;
        return b.reloadIfDownloaded();
    }

    /// The library read again, kept only if a book has arrived: a swap without a
    /// redraw would leave the screen showing books by places that moved.
    fn reloadIfDownloaded(b: *Browser) Next {
        catalog_db.exportLibrary();
        var fresh = loadLibrary(b.a) catch return .nothing;
        if (fresh.localCount() == b.lib.localCount()) {
            fresh.deinit();
            return .nothing;
        }
        b.lib.deinit();
        b.lib = fresh;
        b.watch_until = 0;
        return .everything;
    }

    fn onLock(b: *Browser) !Next {
        const a = b.a;
        const hero: ?*const catalog.Entry = if (b.hero) |h| &b.lib.entries[h] else null;
        // Not put back on waking: it's all drawn again, fresh
        if (lock.lockScreen(a, hero, .{ .restore = false }) == .leaving) return .nothing;
        a.noteBattery(); // What sleeping (or charging) did
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
