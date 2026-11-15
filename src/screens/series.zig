//! Setting a book's series by hand, from its actions sheet: pick one of the library's
//! series, or type a new one, or none; then the book's number in it. Saved in the
//! data folder's "series" file, which wins over what file names say.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const overrides = @import("../model/series_override.zig");
const search = @import("../model/search.zig");
const goto_ui = @import("../ui/goto.zig");
const keyboard = @import("../ui/keyboard.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const draw_ui = @import("../ui/draw.zig");
const icons = @import("../ui/icons.zig");
const style = @import("../ui/style.zig");
const state = @import("../sys/state.zig");
const app = @import("../app.zig");
const screen = @import("screen.zig");
const typing = @import("typing.zig");

const numbers = 30; // Places offered in a series: 1 to 30
/// The rows above the library's series in the first list: a new one, and none.
const rows_before_series = 2;

comptime {
    assert(numbers > 0);
    // Every number offered is one the overrides file keeps
    assert(numbers <= catalog.max_index);
    // The name being typed shows above the keyboard
    assert(keyboard.top < style.screen_height);
}

/// The overrides file in the data folder.
pub fn path(buffer: []u8, state_dir: []const u8) ![:0]u8 {
    const p = try std.fmt.bufPrintSentinel(buffer, "{s}/series", .{state_dir}, 0);
    assert(p.len > state_dir.len);
    assert(std.mem.endsWith(u8, p, "/series"));
    return p;
}

/// Applies the hand-set series to the library's entries.
pub fn apply(alloc: std.mem.Allocator, state_dir: []const u8, entries: []catalog.Entry) void {
    var path_buffer: [320]u8 = undefined;
    const p = path(&path_buffer, state_dir) catch return;
    assert(std.mem.endsWith(u8, p, "/series"));
    var buffer: [64 * 1024]u8 = undefined;
    const list = overrides.parse(alloc, state.read_small(p, &buffer)) catch return;
    for (entries) |*e| {
        const o = overrides.find(list, e.path) orelse continue;
        e.series = alloc.dupe(u8, o.name) catch continue;
        e.series_index = o.index;
    }
}

const Choices = struct {
    pub const Result = u32;
    a: *app.App,
    heading: []const u8,
    about: []const u8, // The book it's for, under the heading
    rows: []const goto_ui.Row,
    pages: goto_ui.Pages = .{},

    pub fn draw(c: *Choices, _: screen.Part) !void {
        assert(c.heading.len > 0);
        assert(c.rows.len > 0);
        const a = c.a;
        const page = a.page(a.screen.pixels);
        page.fill_rect(0, 0, page.width, page.height, style.white);
        // Back to the library along the top, as the stats screen has it
        icons.back(page, style.margin + 18, 70);
        try a.ui.small.draw(page, style.margin + 56, 82, "Library");
        const width_available: f32 = @floatFromInt(page.width - 2 * style.margin);
        try draw_ui.clipped(a.ui.hero, page, style.margin, 222, c.heading, width_available);
        try draw_ui.clipped(a.ui.caption, page, style.margin, 278, c.about, width_available);
        page.tint(style.margin, 250, page.width - 2 * style.margin, 36, style.faded);
        try goto_ui.render_list(a.ui, page, c.rows, null, c.pages.page, "");
        try a.show_band(0, a.screen.height);
    }

    pub fn on_tap(c: *Choices, t: screen.Tap) !screen.Step(u32) {
        assert(c.rows.len > 0);
        return switch (c.pages.tap(t.x, t.y, @intCast(c.rows.len))) {
            .none, .tab => .stay,
            .close => .close, // "Library" along the top
            .turned => .{ .redraw = .all },
            .row => |i| {
                assert(i < c.rows.len);
                return .{ .done = i };
            },
        };
    }
};

const NameEntry = struct {
    pub const Result = []const u8; // As typed, kept in `name`
    a: *app.App,
    name: search.Query = .{},

    pub fn draw(e: *NameEntry, part: screen.Part) !void {
        assert(e.name.len <= e.name.buf.len);
        const a = e.a;
        const page = a.page(a.screen.pixels);
        if (part == .all) {
            // Not over the list it came from
            page.fill_rect(0, 0, page.width, page.height, style.white);
        }
        try search_sheet.render_bar(a.ui, page, 0, e.name.slice(), "Series name", .none);
        if (part == .all) try keyboard.render(a.ui, page);
        try a.show_band(0, if (part == .all) a.screen.height else keyboard.top);
    }

    pub fn on_tap(e: *NameEntry, t: screen.Tap) !screen.Step([]const u8) {
        assert(e.name.len <= e.name.buf.len);
        return switch (typing.key(&e.name, t, typing.anything)) {
            .changed => .{ .redraw = .changing },
            .enter => if (e.name.words().len > 0) .{ .done = e.name.slice() } else .stay,
            .none => if (search_sheet.hit(t.x, t.y, 0) == .cancel) .close else .stay,
        };
    }
};

fn by_name(_: void, x: []const u8, y: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(x, y);
}

/// Starts setting `e`'s series by hand, and then, in the series picked, any other
/// books', in `s`, where it stays while it's open (`screen.open`). It leads only to
/// lists and the keyboard, and ends with true when anything changed; what was on
/// screen is the caller's to redraw either way.
pub fn begin(
    s: *Series,
    a: *app.App,
    entries: []const catalog.Entry,
    e: *const catalog.Entry,
) void {
    // Offered only for books on the Kindle, which have a file to key it by
    assert(e.is_local());
    s.* = .{ .a = a, .entries = entries, .e = e, .arena = .init(a.alloc) };
    assert(s.phase == .choosing);
    assert(!s.changed);
}

pub const Series = struct {
    pub const Result = bool; // Whether anything changed
    a: *app.App,
    entries: []const catalog.Entry,
    e: *const catalog.Entry,
    arena: std.heap.ArenaAllocator, // Emptied as it ends
    phase: Phase = .choosing,
    /// The library's series, once each, by name, and the first list's rows.
    names: std.ArrayList([]const u8) = .empty,
    rows: std.ArrayList(goto_ui.Row) = .empty,
    /// The series being put together, and where each book stands in it.
    name: []const u8 = "",
    places: []Place = &.{},
    changed: bool = false,
    /// The books listed, and which of them is being numbered.
    order: std.ArrayList(u32) = .empty,
    listed: Listed = .{ .in_series = 0, .next = 1 },
    numbering: u32 = 0,
    number_rows: [numbers + 1]goto_ui.Row = undefined,
    /// The list or keyboard open over it, and how it ended.
    choices: Choices = undefined,
    choices_ending: ?screen.Ending(u32) = null,
    naming: NameEntry = undefined,
    naming_ending: ?screen.Ending([]const u8) = null,

    /// What's open over it: the first list (a series, a new one or none), the keyboard
    /// for a new one's name, the series' books, or the numbers for one of them.
    const Phase = enum { choosing, naming, listing, numbering };

    /// Never shown itself: what it opens is.
    pub fn draw(s: *Series, part: screen.Part) !void {
        assert(part == .all);
        assert(s.phase == .choosing);
    }

    pub fn on_tap(s: *Series, _: screen.Tap) !screen.Step(bool) {
        assert(s.phase == .choosing);
        unreachable; // Never in front: a list or the keyboard always is
    }

    /// The first list: the library's series, a new one, or none.
    pub fn on_open(s: *Series) !screen.Step(bool) {
        assert(s.phase == .choosing);
        const alloc = s.arena.allocator();
        for (s.entries) |o| {
            if (o.series.len == 0) continue;
            const seen = for (s.names.items) |n| {
                if (catalog.same_series(n, o.series)) break true;
            } else false;
            if (!seen) try s.names.append(alloc, o.series);
        }
        std.mem.sort([]const u8, s.names.items, {}, by_name);
        try s.rows.append(alloc, .{ .label = "New series\u{2026}", .page = 0, .note = "" });
        try s.rows.append(alloc, .{ .label = "Not in a series", .page = 0, .note = "" });
        for (s.names.items) |n| {
            const note = if (catalog.same_series(n, s.e.series)) "Now" else "";
            try s.rows.append(alloc, .{ .label = n, .page = 0, .note = note });
        }
        assert(s.rows.items.len == s.names.items.len + rows_before_series);
        return s.pick("Series", s.e.title, s.rows.items);
    }

    pub fn on_resume(s: *Series) !screen.Step(bool) {
        // Set as a series is chosen to put together, for every book in the library
        if (s.phase == .listing) assert(s.places.len == s.entries.len);
        if (s.phase == .numbering) assert(s.numbering < s.entries.len);
        return switch (s.phase) {
            .choosing => s.chosen(),
            .naming => {
                const typed = switch (s.naming_ending.?) {
                    .done => |typed| typed,
                    .closed, .interrupted => return s.finish(),
                };
                // Done only once something besides spaces is typed
                assert(std.mem.trim(u8, typed, " ").len > 0);
                return s.manage(try overrides.title_case(s.arena.allocator(), typed));
            },
            .listing => s.tapped(),
            .numbering => s.numbered(),
        };
    }

    /// A series picked in the first list, a new one or none.
    fn chosen(s: *Series) !screen.Step(bool) {
        assert(s.phase == .choosing);
        const picked = s.row_picked() orelse return s.finish();
        if (picked == 1) {
            try save(s.a, s.arena.allocator(), s.e.path, .{ .series = "", .index = 0 });
            s.changed = true;
            return s.finish();
        }
        if (picked == 0) {
            s.phase = .naming;
            s.naming = .{ .a = s.a };
            return .{ .push = screen.open(&s.naming, &s.naming_ending) };
        }
        assert(picked >= rows_before_series);
        return s.manage(s.names.items[picked - rows_before_series]);
    }

    /// The books of series `name`, by number, then the rest of the books on the Kindle
    /// (the book this started from at the top of them): tapping one of the rest adds
    /// it as the next number, tapping one in the series changes its number or takes it
    /// out. Each change is saved as it's made, until "Library" or a lock.
    fn manage(s: *Series, name: []const u8) !screen.Step(bool) {
        assert(name.len > 0);
        assert(s.e.is_local());
        s.name = name;
        s.places = try s.arena.allocator().alloc(Place, s.entries.len);
        for (s.entries, s.places) |e, *p| p.* = .{ .series = e.series, .index = e.series_index };
        return s.list();
    }

    fn list(s: *Series) !screen.Step(bool) {
        assert(s.name.len > 0);
        assert(s.places.len == s.entries.len);
        s.phase = .listing;
        s.listed = try manage_list(
            s.arena.allocator(),
            s.entries,
            s.places,
            s.name,
            s.e,
            &s.order,
            &s.rows,
        );
        const about = "Tap a book to add it, or to change its number";
        return s.pick(s.name, about, s.rows.items);
    }

    /// A book tapped in the series' list: one of the rest is added as the next number,
    /// one in the series is given a number to choose.
    fn tapped(s: *Series) !screen.Step(bool) {
        assert(s.phase == .listing);
        const tapped_index = s.row_picked() orelse return s.finish();
        assert(tapped_index < s.order.items.len);
        const i = s.order.items[tapped_index];
        if (tapped_index >= s.listed.in_series) {
            s.places[i] = .{ .series = s.name, .index = s.listed.next };
            try save(s.a, s.arena.allocator(), s.entries[i].path, s.places[i]);
            s.changed = true;
            return s.list();
        }
        s.phase = .numbering;
        s.numbering = i;
        return s.number_for(i);
    }

    /// A new number for the book being numbered, or out of the series; nothing
    /// changes when the list is left.
    fn numbered(s: *Series) !screen.Step(bool) {
        assert(s.phase == .numbering);
        const i = s.numbering;
        const n = s.row_picked() orelse return s.list();
        assert(n <= numbers);
        s.places[i] = if (n == 0) .{ .series = "", .index = 0 } else .{
            .series = s.name,
            .index = @floatFromInt(n),
        };
        try save(s.a, s.arena.allocator(), s.entries[i].path, s.places[i]);
        s.changed = true;
        return s.list();
    }

    /// Opens a page of `rows` under a heading.
    fn pick(
        s: *Series,
        heading: []const u8,
        about: []const u8,
        rows: []const goto_ui.Row,
    ) screen.Step(bool) {
        assert(rows.len > 0);
        assert(heading.len > 0);
        s.choices = .{ .a = s.a, .heading = heading, .about = about, .rows = rows };
        return .{ .push = screen.open(&s.choices, &s.choices_ending) };
    }

    /// The row picked in the list just closed, or null when "Library" along the top
    /// was tapped or the Kindle locked.
    fn row_picked(s: *const Series) ?u32 {
        assert(s.phase != .naming); // The keyboard picks no row
        const index = switch (s.choices_ending.?) {
            .done => |index| index,
            .closed, .interrupted => return null,
        };
        assert(index < s.choices.rows.len);
        return index;
    }

    /// The numbers offered for book `i` in the series, with the books already at each
    /// place beside them, or out of the series.
    fn number_for(s: *Series, i: u32) !screen.Step(bool) {
        assert(i < s.entries.len);
        assert(s.places.len == s.entries.len);
        const alloc = s.arena.allocator();
        s.number_rows[0] = .{ .label = "Take out of this series", .page = 0, .note = "" };
        for (s.number_rows[1..], 1..) |*r, n| {
            var taken: []const u8 = "";
            for (s.entries, s.places, 0..) |o, p, j| {
                if (j == i) continue;
                if (!catalog.same_series(p.series, s.name)) continue;
                if (p.index == @as(f32, @floatFromInt(n))) taken = o.title;
            }
            const label = try std.fmt.allocPrint(alloc, "#{d}  {s}", .{ n, taken });
            r.* = .{ .label = label, .page = 0, .note = "" };
        }
        const heading = try std.fmt.allocPrint(alloc, "Number in {s}", .{s.name});
        return s.pick(heading, s.entries[i].title, &s.number_rows);
    }

    /// Done: what it kept is let go of, and whether anything changed said.
    fn finish(s: *Series) screen.Step(bool) {
        // Something it opened has ended, which is what ends it
        assert(s.choices_ending != null or s.naming_ending != null);
        // Nothing is saved before a series is chosen to put together
        if (s.changed) assert(s.phase != .naming);
        const changed = s.changed;
        s.arena.deinit();
        return .{ .done = changed };
    }
};

/// Where each book stands while a series is being put together: what the library
/// said, changed by what's been set here.
const Place = struct { series: []const u8, index: f32 };

/// The books `manage` lists: how many of them are in the series, and the number the
/// next one added would take.
const Listed = struct { in_series: u32, next: f32 };

/// The books `manage` lists, in `order` (indexes into `entries`) with a row for each:
/// how many of them are in the series, and the number the next one added would take.
fn manage_list(
    alloc: std.mem.Allocator,
    entries: []const catalog.Entry,
    places: []const Place,
    name: []const u8,
    first: *const catalog.Entry,
    order: *std.ArrayList(u32),
    rows: *std.ArrayList(goto_ui.Row),
) !Listed {
    assert(places.len == entries.len);
    // In the series, by number; then the rest, the book this started from first
    order.clearRetainingCapacity();
    rows.clearRetainingCapacity();
    for (entries, 0..) |e, i| {
        if (e.is_local() and catalog.same_series(places[i].series, name)) {
            try order.append(alloc, @intCast(i));
        }
    }
    std.mem.sort(u32, order.items, places, manage_list_less);
    const in_series: u32 = @intCast(order.items.len);
    for (entries, 0..) |e, i| {
        const is_first = std.mem.eql(u8, e.path, first.path);
        if (is_first and !catalog.same_series(places[i].series, name)) {
            try order.append(alloc, @intCast(i));
        }
    }
    for (entries, 0..) |e, i| {
        if (!e.is_local()) continue;
        if (catalog.same_series(places[i].series, name)) continue;
        if (std.mem.eql(u8, e.path, first.path)) continue;
        try order.append(alloc, @intCast(i));
    }
    var next: f32 = 1;
    for (order.items[0..in_series]) |i| {
        // Beyond it, a number isn't kept
        next = @min(@max(next, @floor(places[i].index) + 1), catalog.max_index);
        const label = try std.fmt.allocPrint(
            alloc,
            "#{d}  {s}",
            .{ places[i].index, entries[i].title },
        );
        try rows.append(alloc, .{ .label = label, .page = 0, .note = "" });
    }
    for (order.items[in_series..]) |i| {
        try rows.append(alloc, .{ .label = entries[i].title, .page = 0, .note = "Add" });
    }
    assert(rows.items.len == order.items.len);
    assert(in_series <= order.items.len);
    assert(next >= 1);
    assert(next <= catalog.max_index);
    return .{ .in_series = in_series, .next = next };
}

/// Books in a series, by their number in it.
fn manage_list_less(places: []const Place, x: u32, y: u32) bool {
    assert(x < places.len);
    assert(y < places.len);
    return places[x].index < places[y].index;
}

/// Saves one book's series and number in the overrides file.
fn save(a: *app.App, alloc: std.mem.Allocator, book: []const u8, place: Place) !void {
    // Out of a series, a book has no number in one
    if (place.series.len == 0) assert(place.index == 0);
    assert(place.index >= 0);
    var path_buffer: [320]u8 = undefined;
    const p = try path(&path_buffer, a.state_dir);
    var buffer: [64 * 1024]u8 = undefined;
    const list = try overrides.parse(alloc, state.read_small(p, &buffer));
    state.write_small(p, try overrides.format(alloc, list, book, place.series, place.index));
    const said = if (place.series.len > 0) place.series else "(none)";
    std.debug.print("series set: {s} #{d}\n", .{ said, place.index });
}
