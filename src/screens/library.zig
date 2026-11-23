//! The home screen: browsing the library, searching it, and opening books. The books
//! are loaded in books.zig, and what a book's sheet does is in book_actions.zig.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const os = @import("../sys/os.zig");
const library = @import("../ui/library.zig");
const catalog_db = @import("../kindle/catalog.zig");
const lipc = @import("../kindle/lipc.zig");
const now_us = os.now_us;
const app = @import("../app.zig");
const user_data = @import("../user_data.zig");
const display = @import("../display.zig");
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

const download_poll_us = 5 * std.time.us_per_s;

/// After leaving a book, how long and how often the status is read again, for Wi-Fi
/// coming back from airplane mode.
const status_watch_us = 40 * std.time.us_per_s;
const status_poll_us = 10 * std.time.us_per_s;
/// The library's tick while nothing else is going on: its clock and battery.
const idle_tick_us = 60 * std.time.us_per_s;
const download_watch_us = 3 * std.time.us_per_min;

comptime {
    // A watch reads more than once before it runs out, and more often than when idle
    assert(download_poll_us < download_watch_us);
    assert(status_poll_us < status_watch_us);
    assert(download_poll_us < idle_tick_us);
    assert(status_poll_us < idle_tick_us);
    // The search sheet lists its matches above the keyboard
    assert(search_sheet.top < keyboard.top);
}

fn logged_hit(x: i32, y: i32, page_index: u32, count: u32, searching: bool) library.Hit {
    assert(page_index < library.page_count(count));
    const h = library.hit(x, y, page_index, count, searching);
    std.debug.print("library tap {s} at {d},{d}\n", .{ @tagName(h), x, y });
    // A book tapped is one of those shown
    if (h == .book) assert(h.book < count);
    return h;
}

/// The library takes every touch, even along the bottom edge where the reader ignores
/// a resting thumb (the pager and keyboard are there), and taps act on lift so pressing
/// and holding a book can bring up its actions.
const touches = input_mod.Input.Modes{ .grips = false, .deferred = true, .edge_zones = true };

fn log_page(shown: []const catalog.Entry, page_index: u32) void {
    assert(shown.len <= library.page_books_max);
    assert(page_index < books.books_max);
    for (shown, 0..) |e, i| std.debug.print("cell {d} {d} {s}\n", .{ page_index, i, e.title });
}

/// How the search sheet ended: cancelled, searching for what was typed, or a book
/// opened from its list.
const SearchEnd = union(enum) { cancel, search, open: *catalog.Entry };

/// The search sheet, its matches listed as they're typed. Ends by cancelling (what was
/// searched before stays), searching for what's typed (nothing clears the search), or
/// opening a book from the list.
const LibrarySearch = struct {
    pub const Result = SearchEnd;
    pub const touches = typing.touches;
    a: *app.App,
    lib: *Library,
    q: *search.Query,
    typist: typing.Typist = .{},
    matches: []catalog.Entry = &.{}, // Those listed, read back by the library

    /// The rows listed, each the match of its place.
    const rows: [search_sheet.max_rows]u32 = std.simd.iota(u32, search_sheet.max_rows);

    pub fn draw(ls: *LibrarySearch, part: screen.Part) !void {
        const a = ls.a;
        assert(ls.q.len <= ls.q.buf.len);
        const words = ls.q.words();
        var more = false;
        ls.matches = &.{};
        if (words.len > 0) {
            const found = ls.lib.matches(words);
            ls.matches = found.entries;
            more = found.more;
        }
        assert(ls.matches.len <= search_sheet.max_rows);
        const page = a.display.on_screen();
        const listed = rows[0..ls.matches.len];
        // What's typed in the field, a space at its end too, so the key shows
        const keys_due = ls.typist.redraw_keys(part == .all);
        const keys: ?keyboard.State = if (keys_due) ls.typist.keys else null;
        try search_sheet.render(a.ui, page, ls.q.slice(), ls.matches, listed, more, keys);
        // The keyboard only when its keys changed: otherwise the part above it
        const bottom: u32 = if (keys_due) a.display.screen.height else keyboard.top;
        try a.display.show_band(search_sheet.top, bottom - search_sheet.top);
    }

    pub fn on_tap(ls: *LibrarySearch, t: screen.Tap) !screen.Step(SearchEnd) {
        assert(ls.matches.len <= search_sheet.max_rows);
        // Cancel and the books listed act at once, a letter's accents showing or not
        if (t.y < keyboard.top) {
            switch (search_sheet.hit(search_sheet.top, t.x, t.y, @intCast(ls.matches.len))) {
                .cancel => return .close,
                .row => |i| {
                    // A row tapped is one of those listed
                    assert(i < ls.matches.len);
                    const entry = &ls.matches[i];
                    if (!entry.is_local()) return .{ .done = .search };
                    return .{ .done = .{ .open = entry } };
                },
                .field, .none => {}, // To the keyboard: a tap here puts accents away
            }
        }
        const edit = ls.typist.tap(ls.q, t.x, t.y, typing.anything);
        if (edit.enter) return .{ .done = .search };
        return if (edit.any()) .{ .redraw = .changing } else .stay;
    }

    /// A key held shows its letter's accents; held anywhere else, it's a tap there.
    pub fn on_action(ls: *LibrarySearch, action: input_mod.Action) !screen.Step(SearchEnd) {
        assert(ls.matches.len <= search_sheet.max_rows);
        assert(ls.q.len <= ls.q.buf.len);
        // A finger followed after a hold, and the like, does nothing here
        if (action != .hold) return .stay;
        const h = action.hold;
        if (h.y >= keyboard.top) {
            const edit = ls.typist.hold(ls.q, h.x, h.y, typing.anything);
            if (edit.enter) return .{ .done = .search };
            return if (edit.any()) .{ .redraw = .changing } else .stay;
        }
        return ls.on_tap(.{ .x = h.x, .y = h.y, .us = 0 });
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
) !void {
    assert(buffer.len == a.display.screen.pixels.len);
    assert(page_index < library.page_count(lib.count()));
    @memcpy(a.display.screen.pixels, buffer);
    const marker = try a.display.screen.show(refresh);
    lib.prepare_covers(&a.regions.covers, page_index + 1);
    if (page_index > 0) lib.prepare_covers(&a.regions.covers, page_index - 1);
    try a.display.screen.wait_complete(marker);
}

/// What the library does after an action: nothing, draw the page again (a new filter,
/// a page turn, a notice), draw everything again with a flash (back from a book, a
/// reloaded library), leave noface, or open a screen over it.
const Next = union(enum) { nothing, page, everything, leave, open: screen.Frame };

pub fn run_library(a: *app.App) !void {
    // The library as last drawn, its own: memory once it's first drawn
    const pixels: u32 = @intCast(a.display.screen.pixels.len);
    const buf = try a.regions.library_budget.untouched(u8, pixels);
    defer a.regions.library_budget.allocator().free(buf);
    var b = Browser{ .a = a, .lib = try load_library(a), .buf = buf };
    defer b.lib.deinit();
    assert(b.buf.len == a.display.screen.pixels.len);
    // Started while the Kindle is locked: the "going to lock" event has passed, so
    // show the lock screen now, as if it had just arrived. Otherwise the library
    // would sit under a locked Kindle with touch switched off.
    // No answer, or a state powerd passes through: taken as awake, the library shown,
    // as the stock screens are
    if (lipc.power_state()) |state| switch (state) {
        .asleep => a.input.hold_back(.lock),
        .awake => {},
    };
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
    buf: []u8, // The library as last drawn: what a sheet over it is drawn over
    filter: catalog.Filter = .all,
    order: catalog.Order = .recent,
    query: search.Query = .{},
    index: u32 = 0, // The page of books shown
    notice: []const u8 = "", // A line for the next drawing only
    /// Set only for a download started here: the library is reloaded every few seconds
    /// until then, and once more as it runs out. Catalog flags can stay stuck, so they
    /// never drive this.
    watch_until: ?u64 = null,
    /// After a book, Wi-Fi takes a while to come back: the status is read again until then.
    status_until: u64 = 0,
    /// The screen open over the library, if one is, with how it ended once it has.
    over: Over = .none,
    /// The minute (since 1970) the status was last read in: the strip along the top is
    /// read again once a new one has begun, however often the library ticks.
    status_minute: u64 = 0,

    /// The screens the library opens over itself, each kept with its ending.
    const Over = union(enum) {
        none,
        stats: screen.Child(stats_screen.Stats),
        battery: screen.Child(battery_screen.Bubble),
        lock: screen.Child(lock.Lock),
        panel: screen.Child(panel.Panel),
        /// The search sheet, and the search before it, kept if it's cancelled.
        search: struct { child: screen.Child(LibrarySearch), kept: search.Query },
        sheet: screen.Child(actions.Sheet),
        /// The card offering `next`, the next of a series just finished.
        up_next: struct { offer: actions.UpNext, next: *catalog.Entry },
        /// A book open, and whether it was read before it was opened.
        book: struct { child: screen.Child(reader.Reader), was_read: bool },
    };

    pub const Result = void;
    /// The home screen: under every other, it takes the lock and leaving.
    pub const takes = screen.Takes{ .lock = true, .leave = true };

    /// The library as last drawn, for a sheet over it: its own, kept still while the
    /// sheet is open.
    fn under(b: *const Browser) display.Backdrop {
        assert(b.buf.len == b.a.display.screen.pixels.len);
        return .{ .pixels = b.buf };
    }

    /// Everything drawn again with a flash (first, and back from a book or a reload),
    /// or the page alone (a new filter, a page turn, a notice).
    pub fn draw(b: *Browser, part: screen.Part) !void {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        switch (part) {
            .all => try b.show_everything(),
            .changing => try b.show_page(),
        }
        // Whatever was drawn, the page shown is one there is, of the books let through
        assert(b.index < library.page_count(b.lib.count()));
    }

    /// Whether a download is being watched at `now`.
    fn watching(b: *const Browser, now: u64) bool {
        const until = b.watch_until orelse return false;
        return now < until;
    }

    /// The library's `touches`, set each time round as a book changes them. It ticks
    /// often while watching a download or the status, else once a minute for the clock
    /// and the battery.
    pub fn setting(b: *const Browser) input_mod.Input.Scope {
        const now = now_us();
        var tick_us: u64 = idle_tick_us;
        if (b.watching(now)) {
            tick_us = download_poll_us;
        } else if (now < b.status_until) {
            tick_us = status_poll_us;
        }
        assert(tick_us >= download_poll_us);
        assert(tick_us <= idle_tick_us);
        return .{ .modes = touches, .tick_us = tick_us };
    }

    pub fn on_tap(b: *Browser, t: screen.Tap) !screen.Step(void) {
        assert(b.index < library.page_count(b.lib.count()));
        return step(try b.on_tap_at(t.x, t.y));
    }

    pub fn on_tick(b: *Browser) !screen.Step(void) {
        assert(b.index < library.page_count(b.lib.count()));
        return step(try b.on_tick_next());
    }

    pub fn on_action(b: *Browser, action: input_mod.Action) !screen.Step(void) {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        assert(b.buf.len == b.a.display.screen.pixels.len);
        const next: Next = switch (action) {
            .tap, .tick => unreachable, // `on_tap` and `on_tick` take those
            .hold => |h| try b.on_hold(h.x, h.y),
            .swipe => |swipe| b.turn(swipe.direction),
            .pull => b.open_panel(),
            .lock => b.on_lock(),
            .charger => blk: {
                try b.refresh_status(.strip);
                break :blk .nothing;
            },
            .power, .computer, .stop => .leave,
            .drag, .drag_end, .unlock => .nothing,
        };
        return step(next);
    }

    /// What `Next` asks of the screen.
    fn step(next: Next) screen.Step(void) {
        const result: screen.Step(void) = switch (next) {
            .nothing => .stay,
            .page => .{ .redraw = .changing },
            .everything => .{ .redraw = .all },
            .leave => .{ .done = {} },
            .open => |f| .{ .push = f },
        };
        // Only leaving ends the library, and only a screen opened goes over it
        assert((result == .done) == (next == .leave));
        assert((result == .push) == (next == .open));
        return result;
    }

    /// Back in front, the screen over it ended: whatever way, what it covered comes back.
    /// What's needed of it is taken before it's let go of, as the handler may open
    /// another in its place.
    pub fn on_resume(b: *Browser) !screen.Step(void) {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        // Only a screen the library opened ends back to it
        assert(b.over != .none);
        switch (b.over) {
            .none => unreachable,
            .stats => {
                b.over = .none;
                return .{ .redraw = .changing };
            },
            .battery => {
                b.over = .none;
                try battery_screen.put_back(b.a, b.under());
                return .stay;
            },
            .lock => |c| {
                b.over = .none;
                return step(b.on_woken(c.ended()));
            },
            .panel => |c| {
                b.over = .none;
                const leave = try panel.ended(b.a, b.under(), c.ended());
                return step(if (leave) .leave else .nothing);
            },
            .search => |c| {
                b.over = .none;
                return step(try b.searched(c.child.ended(), &c.kept));
            },
            .sheet => |c| {
                b.over = .none;
                const change: actions.Change = switch (c.ended()) {
                    .done => |change| change,
                    .closed, .interrupted => .none,
                };
                return step(b.acted(change));
            },
            .up_next => return step(try b.offer_ended()),
            .book => |*open| {
                // A book takes the lock and leaving, so it only ever ends itself
                const outcome = open.child.ended().done;
                const entry = open.child.screen.entry;
                const was_read = open.was_read;
                b.over = .none;
                return step(try b.book_closed(entry, outcome, was_read));
            },
        }
    }

    /// The quick panel, pulled down or from the menu button.
    fn open_panel(b: *Browser) Next {
        assert(b.over == .none);
        assert(b.buf.len == b.a.display.screen.pixels.len);
        b.over = .{ .panel = .{ .screen = panel.open(b.a, b.under()) } };
        return .{ .open = b.over.panel.frame() };
    }

    // Drawing

    /// The books in order, the one to continue, and those the filter and search let
    /// through, with the page kept in range.
    fn arrange(b: *Browser) void {
        // While searching, every match is listed, the hero too
        b.lib.arrange(b.order, b.filter, b.query.words());
        b.index = @min(b.index, library.page_count(b.lib.count()) - 1);
        assert(b.index < library.page_count(b.lib.count()));
        if (b.lib.hero()) |h| assert(h.is_local());
    }

    /// The hero's time left, unless the reader turned time left off (Aa, More).
    fn hero_minutes_left(hero: ?*catalog.Entry, user: *const user_data.UserData) ?u64 {
        if (!user.settings.time_left) return null;
        const h = hero orelse return null;
        return h.minutes_left(user.speed);
    }

    fn render(b: *Browser) !void {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        const a = b.a;
        assert(b.buf.len == a.display.screen.pixels.len);
        const books_shown: library.Books = .{
            .shown = b.lib.page(b.index),
            .hero = b.lib.hero(),
            .count = b.lib.count(),
            .hero_minutes_left = hero_minutes_left(b.lib.hero(), &a.user),
        };
        try library.render(
            &a.regions.covers,
            a.ui,
            a.display.page(b.buf),
            books_shown,
            .{
                .index = b.index,
                .filter = b.filter,
                .query = b.query.words(),
                .notice = b.notice,
                .now = moment(a),
            },
            &a.quick,
        );
    }

    /// Back from a book or a reload: everything drawn again with a flash, then the
    /// status read (it may be minutes old) and redrawn without one if it moved on.
    fn show_everything(b: *Browser) !void {
        const a = b.a;
        b.arrange();
        assert(b.index < library.page_count(b.lib.count()));
        // A book still coming down keeps Wi-Fi on, even once a book is open
        if (b.lib.downloading_count() > 0) {
            a.downloads_until = @max(a.downloads_until, now_us() + download_watch_us);
        }
        const t0 = now_us();
        try b.render();
        std.debug.print("library render {d} ms\n", .{(now_us() - t0) / std.time.us_per_ms});
        try b.present(.flash);
        b.notice = "";
        a.note_battery();
        try b.refresh_status(.screen);
        // A notice is for one drawing only
        assert(b.notice.len == 0);
    }

    fn show_page(b: *Browser) !void {
        b.arrange();
        assert(b.index < library.page_count(b.lib.count()));
        try b.render();
        try b.present(.screen);
        b.notice = ""; // A notice is for one drawing only
    }

    fn present(b: *Browser, refresh: hwtcon.Refresh) !void {
        assert(b.index < library.page_count(b.lib.count()));
        try show_with_covers(b.a, &b.lib, b.buf, refresh, b.index);
        log_page(b.lib.page_shown(), b.index);
    }

    /// Reads the clock, battery, charger and Wi-Fi again, and if anything moved on,
    /// redraws them: the whole screen, or only the status strip along the top (no
    /// flash, and a notice on the page stays).
    fn refresh_status(b: *Browser, area: enum { screen, strip }) !void {
        const a = b.a;
        const fresh = lipc.read(a.quick);
        b.status_minute = os.unix_time() / std.time.s_per_min;
        if (fresh.same(&a.quick)) return;
        a.quick = fresh;
        try b.render();
        switch (area) {
            .screen => try a.display.present(b.buf, .screen),
            .strip => {
                const band = library.status_height * a.display.screen.stride;
                assert(library.status_height <= a.display.screen.height);
                assert(band <= b.buf.len);
                @memcpy(a.display.screen.pixels[0..band], b.buf[0..band]);
                const strip_height = library.status_height;
                const eink = a.display.screen;
                const marker = try eink.show_region(0, 0, eink.width, strip_height, .clock);
                try a.display.screen.wait_complete(marker);
            },
        }
    }

    /// The library read again from the Kindle's catalog (after `export`, which has the
    /// Kindle write it out afresh) and the EPUBs, in place of what was shown.
    fn reload(b: *Browser, how: enum { export_first, as_is }) void {
        assert(b.buf.len == b.a.display.screen.pixels.len);
        if (how == .export_first) catalog_db.export_library();
        b.lib.reload();
        // Fewer books may be let through now: the page kept one there is
        b.arrange();
    }

    // Actions

    fn on_tap_at(b: *Browser, x: i32, y: i32) !Next {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        const a = b.a;
        switch (logged_hit(x, y, b.index, b.lib.count(), b.query.words().len > 0)) {
            .none => return .nothing,
            .next => return b.turn(1),
            .prev => return b.turn(-1),
            .search => {
                assert(b.query.len <= b.query.buf.len);
                const sheet = LibrarySearch{ .a = a, .lib = &b.lib, .q = &b.query };
                b.over = .{ .search = .{ .child = .{ .screen = sheet }, .kept = b.query } };
                return .{ .open = b.over.search.child.frame() };
            },
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
                // The button shows arrows alone: the order is named as it changes
                b.notice = sorted_notice(b.order);
                return .page;
            },
            .stats => {
                b.over = .{ .stats = .{ .screen = stats_screen.make(a, &b.lib) } };
                return .{ .open = b.over.stats.frame() };
            },
            .menu => return b.open_panel(),
            .battery => {
                b.over = .{ .battery = .{ .screen = undefined } };
                battery_screen.open(a, &b.over.battery.screen);
                return .{ .open = b.over.battery.frame() };
            },
            .hero => {
                const h = b.lib.hero() orelse return .nothing;
                a.display.flash(library.hero_rect(a.display.screen.width));
                return b.open_book(h);
            },
            .hero_dots => return b.act_on(b.lib.hero() orelse return .nothing),
            .book => |i| {
                const entry = b.lib.book(i - library.page_range(b.index, b.lib.count()).first);
                if (entry.is_local()) {
                    a.display.flash(library.book_rect(i, b.index));
                    return b.open_book(entry);
                }
                if (entry.availability == .downloading) {
                    b.notice = "Still downloading. It will open once it's finished.";
                } else {
                    // Grid books have no dots: their actions come from holding them
                    b.notice = "Not on this Kindle yet. Hold it to download it.";
                }
                return .page;
            },
        }
    }

    /// Holding a book brings up its actions.
    fn on_hold(b: *Browser, x: i32, y: i32) !Next {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        assert(b.over == .none); // In front, taking touches
        return switch (logged_hit(x, y, b.index, b.lib.count(), b.query.words().len > 0)) {
            .book => |i| b.act_on(b.lib.book(i - library.page_range(b.index, b.lib.count()).first)),
            .hero, .hero_dots => b.act_on(b.lib.hero() orelse return .nothing),
            // Only a book has actions to hold for
            .none,
            .prev,
            .next,
            .sort,
            .menu,
            .battery,
            .search,
            .stats,
            .clear_search,
            .tab,
            => .nothing,
        };
    }

    /// A page of books on (1) or back (-1), if there is one.
    fn turn(b: *Browser, direction: i32) Next {
        assert(direction == 1 or direction == -1);
        assert(b.index < library.page_count(b.lib.count()));
        if (direction > 0 and b.index + 1 < library.page_count(b.lib.count())) {
            b.index += 1;
            return .page;
        }
        if (direction < 0 and b.index > 0) {
            b.index -= 1;
            return .page;
        }
        return .nothing;
    }

    /// The search sheet ended: cancelled, locked or leaving, what was searched before
    /// (`kept`) stays.
    fn searched(b: *Browser, ending: screen.Ending(SearchEnd), kept: *const search.Query) !Next {
        assert(b.query.len <= b.query.buf.len);
        assert(kept.len <= kept.buf.len);
        const end: SearchEnd = switch (ending) {
            .done => |end| end,
            .closed, .interrupted => .cancel,
        };
        switch (end) {
            .cancel => {
                b.query = kept.*;
                try b.a.display.present(b.buf, .screen); // What was there before the sheet
                return .nothing;
            },
            .search => {
                b.index = 0;
                return .page;
            },
            .open => |e| {
                b.query = .{};
                b.index = 0;
                return b.open_book(e);
            },
        }
    }

    /// Reads a book, and on finishing one of a series offers the next, to go straight
    /// on with. Each next book is further on in its series, so none comes round twice.
    fn open_book(b: *Browser, entry: *catalog.Entry) !Next {
        // Only books on the Kindle are opened: the hero, a book on it, a match, or the
        // next of a series
        assert(entry.is_local());
        assert(b.lib.local_count() > 0);
        const was_read = entry.is_read();
        b.over = .{ .book = .{ .child = .{ .screen = undefined }, .was_read = was_read } };
        reader.open(&b.over.book.child.screen, b.a, entry) catch |err| {
            std.debug.print("could not open book: {s}\n", .{@errorName(err)});
            b.over = .none;
            return b.book_closed(entry, .failed, was_read);
        };
        return .{ .open = b.over.book.child.frame() };
    }

    /// The book ended, `outcome` saying how: noface leaves, or the library is back,
    /// offering the next of a series just finished, to read now. Only books on the
    /// Kindle can offer it: a series is read from a book's file name, and books in the
    /// cloud have none yet.
    fn book_closed(
        b: *Browser,
        entry: *catalog.Entry,
        outcome: reader.Outcome,
        was_read: bool, // Read before it was opened: finishing it now offers no next
    ) !Next {
        const a = b.a;
        assert(entry.is_local());
        assert(b.over == .none);
        switch (outcome) {
            .failed => b.notice = "This book can't be opened here.",
            .stopped => b.notice = "This book stopped. Your place is saved.",
            .library, .quit => {},
        }
        b.lib.save(entry); // Its place and time read, in the library's index
        if (outcome == .quit) return .leave;
        b.status_until = now_us() + status_watch_us; // Wi-Fi coming back, and the like
        if (was_read or !entry.is_read()) return .everything;
        const next = b.lib.next_in_series(entry) orelse return .everything;
        // The next is one not read yet, so never the book just finished
        assert(!next.is_read());
        assert(next != entry);
        b.over = .{ .up_next = .{ .offer = .{}, .next = next } };
        const offer = actions.up_next(a, next, &b.over.up_next.offer) orelse {
            b.over = .none;
            return .everything;
        };
        return .{ .open = offer };
    }

    /// The up-next card ended: the next book now, or the library back.
    fn offer_ended(b: *Browser) !Next {
        const next = b.over.up_next.next;
        assert(b.over.up_next.offer.ending != null);
        assert(next.is_local());
        const chosen = actions.up_next_closed(b.a, &b.over.up_next.offer);
        b.over = .none;
        if (!chosen) return .everything;
        return b.open_book(next);
    }

    /// A book's actions sheet, and the library read again if they changed it.
    fn act_on(b: *Browser, entry: *catalog.Entry) Next {
        assert(b.buf.len == b.a.display.screen.pixels.len);
        assert(b.over == .none);
        b.over = .{ .sheet = .{ .screen = undefined } };
        actions.begin_sheet(&b.over.sheet.screen, b.a, entry, &b.lib, b.under());
        return .{ .open = b.over.sheet.frame() };
    }

    /// The book's actions ended, having changed `change`.
    fn acted(b: *Browser, change: actions.Change) Next {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        assert(b.buf.len == b.a.display.screen.pixels.len);
        switch (change) {
            .none => return .nothing,
            .redraw => return .everything,
            .reload => b.reload(.as_is),
            .other => b.reload(.export_first),
            .downloading => {
                // Only a download finishes later, so only it is watched
                const until = now_us() + download_watch_us;
                b.watch_until = until;
                b.a.downloads_until = until; // Wi-Fi stays on for it while reading
                b.reload(.export_first);
            },
        }
        return .everything;
    }

    fn on_tick_next(b: *Browser) !Next {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        assert(b.over == .none); // In front, ticking
        const now = now_us();
        // The status: the whole screen while it's settling after a book; else just the
        // strip, once a new minute has begun, the clock showing minutes, even while a
        // download is watched (a charger coming or going is an action of its own)
        if (now < b.status_until) {
            try b.refresh_status(.screen);
        } else if (os.unix_time() / std.time.s_per_min != b.status_minute) {
            try b.refresh_status(.strip);
        }
        // A download being watched: the library again, in case it's finished. When the
        // watch runs out, one last look, for one that finished since the last
        const until = b.watch_until orelse return .nothing;
        if (now >= until) b.watch_until = null;
        return b.reload_if_downloaded();
    }

    /// The library read again, kept if a book has arrived or the index was built again
    /// (the old one's files are then gone): a swap without a redraw would leave the
    /// screen showing books by places that moved.
    fn reload_if_downloaded(b: *Browser) Next {
        assert(b.index < library.page_count(b.lib.count())); // A page of the books shown
        // Only what's downloading is looked at, until it says the catalog moved on
        if (b.lib.watch_download() == .waiting) return .nothing;
        const before = b.lib.shelf();
        const shown_before = b.lib.count();
        b.reload(.export_first);
        // The books shown change with the shelf, or with a place merged in again (one a
        // filter now lets through, or doesn't)
        const same = std.meta.eql(before, b.lib.shelf()) and shown_before == b.lib.count();
        if (same) return .nothing; // Nothing to show for it
        if (before.local != b.lib.local_count()) b.watch_until = null;
        return .everything;
    }

    fn on_lock(b: *Browser) Next {
        const hero: ?*const catalog.Entry = b.lib.hero();
        // Not put back on waking: it's all drawn again, fresh
        assert(b.over == .none);
        b.over = .{ .lock = .{ .screen = lock.make(b.a, hero, .{ .restore = false }) } };
        return .{ .open = b.over.lock.frame() };
    }

    /// Woken, or the lock screen ended as noface leaves (which goes on to leave).
    fn on_woken(b: *Browser, ending: screen.Ending(void)) Next {
        const a = b.a;
        assert(ending != .closed); // It wakes, or noface leaves: it's never closed
        if (ending != .done) return .nothing;
        assert(!a.input.locked); // Awake, back in front
        a.note_battery(); // What sleeping (or charging) did
        a.quick = lipc.read(a.quick); // The clock and battery may be hours old
        // A download may have finished while the Kindle slept
        if (b.lib.downloading_count() > 0) b.reload(.export_first);
        return .everything;
    }
};

/// What the library says, once, as the books are put in `order`.
fn sorted_notice(order: catalog.Order) []const u8 {
    const result = switch (order) {
        inline else => |o| "Sorted: " ++ comptime o.label(),
    };
    assert(result.len > 0);
    return result;
}
