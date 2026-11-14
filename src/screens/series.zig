//! Setting a book's series by hand, from its actions sheet: pick one of the library's
//! series, or type a new one, or none; then the book's number in it. Saved in the
//! data folder's "series" file, which wins over what file names say.
const std = @import("std");
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

/// The overrides file in the data folder.
pub fn path(buf: []u8, state_dir: []const u8) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/series", .{state_dir}, 0);
}

/// Applies the hand-set series to the library's entries.
pub fn apply(alloc: std.mem.Allocator, state_dir: []const u8, entries: []catalog.Entry) void {
    var path_buf: [320]u8 = undefined;
    const p = path(&path_buf, state_dir) catch return;
    var buf: [64 * 1024]u8 = undefined;
    const list = overrides.parse(alloc, state.readSmall(p, &buf)) catch return;
    for (entries) |*e| {
        const o = overrides.find(list, e.path) orelse continue;
        e.series = alloc.dupe(u8, o.name) catch continue;
        e.series_index = o.index;
    }
}

/// One of `rows`, chosen from a page of them under a heading: its index, or null when
/// "Library" along the top is tapped or the Kindle locks.
fn pick(a: *app.App, heading: []const u8, about: []const u8, rows: []const goto_ui.Row) !?usize {
    var list = Choices{ .a = a, .heading = heading, .about = about, .rows = rows };
    return screen.run(a, &list);
}

const Choices = struct {
    pub const Result = usize;
    a: *app.App,
    heading: []const u8,
    about: []const u8, // The book it's for, under the heading
    rows: []const goto_ui.Row,
    pages: goto_ui.Pages = .{},

    pub fn draw(c: *Choices, _: screen.Part) !void {
        const a = c.a;
        const page = a.page(a.screen.pixels);
        page.fillRect(0, 0, page.width, page.height, style.white);
        // Back to the library along the top, as the stats screen has it
        icons.back(page, style.margin + 18, 70);
        try a.ui.small.draw(page, style.margin + 56, 82, "Library");
        const avail: f32 = @floatFromInt(page.width - 2 * style.margin);
        try draw_ui.clipped(a.ui.hero, page, style.margin, 222, c.heading, avail);
        try draw_ui.clipped(a.ui.caption, page, style.margin, 278, c.about, avail);
        page.tint(style.margin, 250, page.width - 2 * style.margin, 36, style.faded);
        try goto_ui.renderList(a.ui, page, c.rows, null, c.pages.page, "");
        try a.showBand(0, a.screen.height);
    }

    pub fn onTap(c: *Choices, t: screen.Tap) !screen.Step(usize) {
        return switch (c.pages.tap(t.x, t.y, c.rows.len)) {
            .none, .tab => .stay,
            .close => .close, // "Library" along the top
            .turned => .{ .redraw = .all },
            .row => |i| .{ .done = i },
        };
    }
};

/// A new series' name, typed. Null if cancelled.
fn typeName(a: *app.App, alloc: std.mem.Allocator) !?[]const u8 {
    var entry = NameEntry{ .a = a };
    const typed = try screen.run(a, &entry) orelse return null;
    return try overrides.titleCase(alloc, typed);
}

const NameEntry = struct {
    pub const Result = []const u8; // As typed, kept in `name`
    a: *app.App,
    name: search.Query = .{},

    pub fn draw(e: *NameEntry, part: screen.Part) !void {
        const a = e.a;
        const page = a.page(a.screen.pixels);
        if (part == .all) page.fillRect(0, 0, page.width, page.height, style.white); // Not over the list it came from
        try search_sheet.renderBar(a.ui, page, 0, e.name.slice(), "Series name", .none);
        if (part == .all) try keyboard.render(a.ui, page);
        try a.showBand(0, if (part == .all) a.screen.height else keyboard.top);
    }

    pub fn onTap(e: *NameEntry, t: screen.Tap) !screen.Step([]const u8) {
        return switch (typing.key(&e.name, t, typing.anything)) {
            .changed => .{ .redraw = .changing },
            .enter => if (e.name.words().len > 0) .{ .done = e.name.slice() } else .stay,
            .none => if (search_sheet.hit(t.x, t.y, 0) == .cancel) .close else .stay,
        };
    }
};

fn byName(_: void, x: []const u8, y: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(x, y);
}

/// Sets `e`'s series by hand, and then, in the series picked, any other books'. True
/// when anything changed; what was on screen is the caller's to redraw either way.
pub fn choose(a: *app.App, entries: []const catalog.Entry, e: *const catalog.Entry) !bool {
    var arena = std.heap.ArenaAllocator.init(a.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The library's series, once each, by name
    var names: std.ArrayList([]const u8) = .empty;
    for (entries) |o| {
        if (o.series.len == 0) continue;
        const seen = for (names.items) |n| {
            if (catalog.sameSeries(n, o.series)) break true;
        } else false;
        if (!seen) try names.append(alloc, o.series);
    }
    std.mem.sort([]const u8, names.items, {}, byName);
    var rows: std.ArrayList(goto_ui.Row) = .empty;
    try rows.append(alloc, .{ .label = "New series\u{2026}", .page = 0, .note = "" });
    try rows.append(alloc, .{ .label = "Not in a series", .page = 0, .note = "" });
    for (names.items) |n| try rows.append(alloc, .{ .label = n, .page = 0, .note = if (catalog.sameSeries(n, e.series)) "Now" else "" });

    const picked = try pick(a, "Series", e.title, rows.items) orelse return false;
    if (picked == 1) {
        try save(a, alloc, e.path, "", 0);
        return true;
    }
    const name = if (picked == 0) try typeName(a, alloc) orelse return false else names.items[picked - 2];
    return try manage(a, alloc, entries, name, e);
}

/// Where each book stands while a series is being put together: what the library
/// said, changed by what's been set here.
const Place = struct { series: []const u8, index: f32 };

/// The books of series `name`, by number, then the rest of the books on the Kindle
/// (`first` at the top of them): tapping one of the rest adds it as the next number,
/// tapping one in the series changes its number or takes it out. Each change is
/// saved as it's made. True when anything changed.
fn manage(a: *app.App, alloc: std.mem.Allocator, entries: []const catalog.Entry, name: []const u8, first: *const catalog.Entry) !bool {
    const places = try alloc.alloc(Place, entries.len);
    for (entries, places) |e, *p| p.* = .{ .series = e.series, .index = e.series_index };
    var changed = false;
    var order: std.ArrayList(usize) = .empty;
    var rows: std.ArrayList(goto_ui.Row) = .empty;
    while (true) {
        // In the series, by number; then the rest, the book this started from first
        order.clearRetainingCapacity();
        rows.clearRetainingCapacity();
        for (entries, 0..) |e, i| {
            if (e.isLocal() and catalog.sameSeries(places[i].series, name)) try order.append(alloc, i);
        }
        std.mem.sort(usize, order.items, places, struct {
            fn less(ps: []const Place, x: usize, y: usize) bool {
                return ps[x].index < ps[y].index;
            }
        }.less);
        const in_series = order.items.len;
        for (entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.path, first.path) and !catalog.sameSeries(places[i].series, name)) try order.append(alloc, i);
        }
        for (entries, 0..) |e, i| {
            if (!e.isLocal() or catalog.sameSeries(places[i].series, name) or std.mem.eql(u8, e.path, first.path)) continue;
            try order.append(alloc, i);
        }
        var next: f32 = 1;
        for (order.items[0..in_series]) |i| {
            next = @min(@max(next, @floor(places[i].index) + 1), catalog.max_index); // Beyond it, a number isn't kept
            try rows.append(alloc, .{ .label = try std.fmt.allocPrint(alloc, "#{d}  {s}", .{ places[i].index, entries[i].title }), .page = 0, .note = "" });
        }
        for (order.items[in_series..]) |i| try rows.append(alloc, .{ .label = entries[i].title, .page = 0, .note = "Add" });

        const about = "Tap a book to add it, or to change its number";
        const tapped = try pick(a, name, about, rows.items) orelse return changed;
        const i = order.items[tapped];
        if (tapped >= in_series) {
            places[i] = .{ .series = name, .index = next };
        } else {
            places[i] = try numberFor(a, alloc, entries, places, i, name) orelse continue;
        }
        try save(a, alloc, entries[i].path, places[i].series, places[i].index);
        changed = true;
    }
}

/// A new number in `name` for book `i`, with the books already at each place
/// beside them, or out of the series. Null if left as it was.
fn numberFor(a: *app.App, alloc: std.mem.Allocator, entries: []const catalog.Entry, places: []const Place, i: usize, name: []const u8) !?Place {
    var rows: [numbers + 1]goto_ui.Row = undefined;
    rows[0] = .{ .label = "Take out of this series", .page = 0, .note = "" };
    for (rows[1..], 1..) |*r, n| {
        var taken: []const u8 = "";
        for (entries, places, 0..) |o, p, j| {
            if (j != i and catalog.sameSeries(p.series, name) and p.index == @as(f32, @floatFromInt(n))) taken = o.title;
        }
        r.* = .{ .label = try std.fmt.allocPrint(alloc, "#{d}  {s}", .{ n, taken }), .page = 0, .note = "" };
    }
    const heading = try std.fmt.allocPrint(alloc, "Number in {s}", .{name});
    const n = try pick(a, heading, entries[i].title, &rows) orelse return null;
    if (n == 0) return .{ .series = "", .index = 0 };
    return .{ .series = name, .index = @floatFromInt(n) };
}

/// Saves one book's series in the overrides file.
fn save(a: *app.App, alloc: std.mem.Allocator, book: []const u8, name: []const u8, index: f32) !void {
    var path_buf: [320]u8 = undefined;
    const p = try path(&path_buf, a.state_dir);
    var buf: [64 * 1024]u8 = undefined;
    const list = try overrides.parse(alloc, state.readSmall(p, &buf));
    state.writeSmall(p, try overrides.format(alloc, list, book, name, index));
    std.debug.print("series set: {s} #{d}\n", .{ if (name.len > 0) name else "(none)", index });
}
