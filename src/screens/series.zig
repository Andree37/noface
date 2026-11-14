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

/// One of `rows`, chosen from a page of them under a heading: its index, or null when
/// "Library" along the top is tapped or the Kindle locks.
fn pick(a: *app.App, heading: []const u8, about: []const u8, rows: []const goto_ui.Row) !?u32 {
    assert(rows.len > 0);
    var list = Choices{ .a = a, .heading = heading, .about = about, .rows = rows };
    const picked = try screen.run(a, &list) orelse return null;
    assert(picked < rows.len);
    return picked;
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
        return switch (c.pages.tap(t.x, t.y, c.rows.len)) {
            .none, .tab => .stay,
            .close => .close, // "Library" along the top
            .turned => .{ .redraw = .all },
            .row => |i| {
                assert(i < c.rows.len);
                return .{ .done = @intCast(i) };
            },
        };
    }
};

/// A new series' name, typed. Null if cancelled.
fn type_name(a: *app.App, alloc: std.mem.Allocator) !?[]const u8 {
    var entry = NameEntry{ .a = a };
    const typed = try screen.run(a, &entry) orelse return null;
    // Done only once something besides spaces is typed
    assert(std.mem.trim(u8, typed, " ").len > 0);
    const name = try overrides.title_case(alloc, typed);
    assert(name.len > 0);
    return name;
}

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

/// Sets `e`'s series by hand, and then, in the series picked, any other books'. True
/// when anything changed; what was on screen is the caller's to redraw either way.
pub fn choose(a: *app.App, entries: []const catalog.Entry, e: *const catalog.Entry) !bool {
    // Offered only for books on the Kindle, which have a file to key it by
    assert(e.is_local());
    var arena = std.heap.ArenaAllocator.init(a.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The library's series, once each, by name
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |o| {
        if (o.series.len == 0) continue;
        const seen = for (names.items) |n| {
            if (catalog.same_series(n, o.series)) break true;
        } else false;
        if (!seen) try names.append(alloc, o.series);
    }
    std.mem.sort([]const u8, names.items, {}, by_name);
    var rows: std.ArrayList(goto_ui.Row) = .empty;
    try rows.append(alloc, .{ .label = "New series\u{2026}", .page = 0, .note = "" });
    try rows.append(alloc, .{ .label = "Not in a series", .page = 0, .note = "" });
    for (names.items) |n| {
        const note = if (catalog.same_series(n, e.series)) "Now" else "";
        try rows.append(alloc, .{ .label = n, .page = 0, .note = note });
    }
    assert(rows.items.len == names.items.len + rows_before_series);

    const picked = try pick(a, "Series", e.title, rows.items) orelse return false;
    if (picked == 1) {
        try save(a, alloc, e.path, .{ .series = "", .index = 0 });
        return true;
    }
    if (picked == 0) {
        const typed = try type_name(a, alloc) orelse return false;
        return try manage(a, alloc, entries, typed, e);
    }
    const name = names.items[picked - rows_before_series];
    return try manage(a, alloc, entries, name, e);
}

/// Where each book stands while a series is being put together: what the library
/// said, changed by what's been set here.
const Place = struct { series: []const u8, index: f32 };

/// The books of series `name`, by number, then the rest of the books on the Kindle
/// (`first` at the top of them): tapping one of the rest adds it as the next number,
/// tapping one in the series changes its number or takes it out. Each change is
/// saved as it's made. True when anything changed.
fn manage(
    a: *app.App,
    alloc: std.mem.Allocator,
    entries: []const catalog.Entry,
    name: []const u8,
    first: *const catalog.Entry,
) !bool {
    assert(name.len > 0);
    assert(first.is_local());
    const places = try alloc.alloc(Place, entries.len);
    for (entries, places) |e, *p| p.* = .{ .series = e.series, .index = e.series_index };
    var changed = false;
    var order: std.ArrayList(u32) = .empty;
    var rows: std.ArrayList(goto_ui.Row) = .empty;
    // Unbounded: the reader adds and renumbers books for as long as they like, until
    // they tap "Library" or the Kindle locks
    while (true) {
        const listed = try manage_list(alloc, entries, places, name, first, &order, &rows);
        const about = "Tap a book to add it, or to change its number";
        const tapped = try pick(a, name, about, rows.items) orelse return changed;
        assert(tapped < order.items.len);
        const i = order.items[tapped];
        if (tapped >= listed.in_series) {
            places[i] = .{ .series = name, .index = listed.next };
        } else {
            places[i] = try number_for(a, alloc, entries, places, i, name) orelse continue;
        }
        try save(a, alloc, entries[i].path, places[i]);
        changed = true;
    }
}

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
) !struct { in_series: u32, next: f32 } {
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

/// A new number in `name` for book `i`, with the books already at each place
/// beside them, or out of the series. Null if left as it was.
fn number_for(
    a: *app.App,
    alloc: std.mem.Allocator,
    entries: []const catalog.Entry,
    places: []const Place,
    i: u32,
    name: []const u8,
) !?Place {
    assert(places.len == entries.len);
    assert(i < entries.len);
    var rows: [numbers + 1]goto_ui.Row = undefined;
    rows[0] = .{ .label = "Take out of this series", .page = 0, .note = "" };
    for (rows[1..], 1..) |*r, n| {
        var taken: []const u8 = "";
        for (entries, places, 0..) |o, p, j| {
            if (j == i) continue;
            if (!catalog.same_series(p.series, name)) continue;
            if (p.index == @as(f32, @floatFromInt(n))) taken = o.title;
        }
        const label = try std.fmt.allocPrint(alloc, "#{d}  {s}", .{ n, taken });
        r.* = .{ .label = label, .page = 0, .note = "" };
    }
    const heading = try std.fmt.allocPrint(alloc, "Number in {s}", .{name});
    const n = try pick(a, heading, entries[i].title, &rows) orelse return null;
    assert(n <= numbers);
    if (n == 0) return .{ .series = "", .index = 0 };
    return .{ .series = name, .index = @floatFromInt(n) };
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
