//! Every control a script taps, by name: "toolbar.bookmark", "key.s", "card.3.0". Each
//! point comes from the place its screen publishes (`place` in each of ui/), worked out
//! from the same layout its taps are, so a script tapping a name follows the control
//! wherever layout moves it, and never taps where it isn't. The scenarios tap these
//! points, and the device tests' scripts (tools/e2e.zig) their names.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("../ui/style.zig");
const aa = @import("../ui/aa.zig");
const card = @import("../ui/card.zig");
const definition = @import("../ui/definition.zig");
const goto = @import("../ui/goto.zig");
const keyboard = @import("../ui/keyboard.zig");
const library = @import("../ui/library.zig");
const menu = @import("../ui/menu.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const toolbar = @import("../ui/toolbar.zig");
const catalog = @import("../model/catalog.zig");
const settings_model = @import("../model/settings.zig");
const running = @import("../model/running.zig");
const touch = @import("../kindle/touch.zig");
const gestures = @import("../kindle/input/gestures.zig");
const run = @import("reader/run.zig");
const run_view = @import("reader/run_view.zig");
const back_button = @import("reader/back_button.zig");
const more = @import("reader/more.zig");
const picture = @import("reader/picture.zig");

pub const Point = style.Point;
pub const Place = struct { name: []const u8, point: Point };

const width = style.screen_width;
const height = style.screen_height;

/// Taps on a page of the book: turning on and back, a third of the width either side,
/// the top, which opens the toolbar, and the middle, which closes what's over the page.
/// Each halfway down, clear of the thumbs' strip along the bottom.
pub const page = struct {
    pub const forward: Point = .{ .x = width - width / 6, .y = height / 2 };
    pub const back: Point = .{ .x = width / 6, .y = height / 2 };
    pub const top: Point = .{ .x = width / 2, .y = touch.top_zone / 2 };
    pub const middle: Point = .{ .x = width / 2, .y = height / 2 };
};

/// Taps while running mode is on: its top band, which pauses with the card, and its
/// three columns, back, pause or resume, and on (model/running.zig).
pub const running_mode = struct {
    pub const top: Point = .{ .x = width / 2, .y = run.pause_band_px / 2 };
    pub const back: Point = .{ .x = width / 6, .y = height / 2 };
    pub const middle: Point = .{ .x = width / 2, .y = height / 2 };
    pub const next: Point = .{ .x = width - width / 6, .y = height / 2 };
};

/// Every place by name, worked out as noface is built.
pub const all = places: {
    @setEvalBranchQuota(200_000);
    var list: []const Place = &.{
        .{ .name = "page.forward", .point = page.forward },
        .{ .name = "page.back", .point = page.back },
        .{ .name = "page.top", .point = page.top },
        .{ .name = "page.middle", .point = page.middle },
        // A tap anywhere, as on the stats, which any tap closes
        .{ .name = "screen.middle", .point = .{ .x = width / 2, .y = height / 2 } },
        .{ .name = "running.top", .point = running_mode.top },
        .{ .name = "running.back", .point = running_mode.back },
        .{ .name = "running.middle", .point = running_mode.middle },
        .{ .name = "running.next", .point = running_mode.next },
        .{ .name = "running.pause", .point = run_view.pause_place(height) },
        .{ .name = "reader.back", .point = back_button.place(height) },
        .{ .name = "picture.close", .point = picture.close_place() },
        .{ .name = "card.above", .point = card.place_above() },
        .{ .name = "define.highlight", .point = definition.place(.highlight) },
        .{ .name = "define.get_dictionary", .point = definition.place(.get_dictionary) },
        .{ .name = "define.close", .point = definition.place(.close) },
        .{ .name = "aa.running", .point = aa.place(.themes, .running) },
        .{ .name = "aa.close", .point = toolbar.close_under_sheet() },
        .{ .name = "goto.close", .point = goto.place(.close) },
        .{ .name = "goto.prev", .point = goto.place(.prev) },
        .{ .name = "goto.next", .point = goto.place(.next) },
        .{ .name = "key.backspace", .point = keyboard.place(.backspace) },
        .{ .name = "key.space", .point = keyboard.place(.space) },
        .{ .name = "key.search", .point = keyboard.place(.enter) },
    };
    for ([_]toolbar.Hit{
        .home, .text,  .goto,         .bookmark,     .search,
        .more, .close, .chapter_prev, .chapter_next, .scrub,
    }) |h| {
        list = list ++ .{Place{ .name = "toolbar." ++ @tagName(h), .point = toolbar.place(h) }};
    }
    for ([_]library.Hit{
        .menu, .battery, .hero, .hero_dots, .search, .stats, .sort, .prev, .next, .clear_search,
    }) |h| {
        list = list ++ .{Place{ .name = "library." ++ @tagName(h), .point = library.place(h) }};
    }
    for (std.enums.values(catalog.Filter)) |f| {
        const point = library.place(.{ .tab = f });
        list = list ++ .{Place{ .name = "library.tab." ++ @tagName(f), .point = point }};
    }
    // The grid's first book on the first page, under the hero
    list = list ++ .{Place{ .name = "library.book.first", .point = library.place(.{ .book = 0 }) }};
    for (std.enums.values(aa.Tab)) |t| {
        const point = aa.place(.themes, .{ .tab = t });
        list = list ++ .{Place{ .name = "aa.tab." ++ @tagName(t), .point = point }};
    }
    for (0..aa.themes.len) |i| {
        const name = std.fmt.comptimePrint("aa.theme.{d}", .{i});
        list = list ++ .{Place{ .name = name, .point = aa.place(.themes, .{ .theme = i }) }};
    }
    // Each switch by the setting it flips: "aa.switch.bold"
    for (aa.switches, 0..) |sw, i| {
        const point = aa.place(sw.tab, .{ .toggle = i });
        list = list ++ .{Place{ .name = "aa.switch." ++ @tagName(sw.field), .point = point }};
    }
    // Each of the Kindle's typefaces by its name, "aa.family.bookerly": where the grid
    // puts them with no typefaces of the reader's own, as the tests' Kindles have none
    for (settings_model.builtin_families, 0..) |family, i| {
        const name = "aa.family." ++ lower(family);
        list = list ++ .{Place{ .name = name, .point = aa.family_place(.{}, i) }};
    }
    // Each step of each slider, from the first: "aa.size.0", "aa.margins.3"
    for ([_]struct { []const u8, aa.Row }{
        .{ "size", aa.size_row },
        .{ "spacing", aa.spacing_row },
        .{ "margins", aa.margin_row },
    }) |named| for (0..named[1].steps) |step| {
        const name = std.fmt.comptimePrint("aa.{s}.{d}", .{ named[0], step });
        list = list ++ .{Place{ .name = name, .point = aa.step_place(named[1], step) }};
    };
    for (std.enums.values(more.Option)) |o| {
        if (o == .cancel) continue; // Not on the menu: a tap above the card is
        if (o == .unread) continue; // Where Finished is, for a finished book
        list = list ++ .{Place{ .name = "more." ++ @tagName(o), .point = more.place(o) }};
    }
    for ([_]menu.Hit{
        .close, .schedule, .airplane, .bluetooth, .wifi,   .kindle,
        .sync,  .dimmer,   .brighter, .cooler,    .warmer,
    }) |h| {
        list = list ++ .{Place{ .name = "panel." ++ @tagName(h), .point = menu.place(h) }};
    }
    for (std.enums.values(goto.Tab)) |t| {
        const point = goto.place(.{ .tab = t });
        list = list ++ .{Place{ .name = "goto.tab." ++ @tagName(t), .point = point }};
    }
    for (0..goto.rows) |r| {
        const name = std.fmt.comptimePrint("goto.row.{d}", .{r});
        list = list ++ .{Place{ .name = name, .point = goto.place(.{ .row = r }) }};
    }
    // The books the library's search lists as it's typed into
    for (0..search_sheet.max_rows) |r| {
        const name = std.fmt.comptimePrint("library.found.{d}", .{r});
        list = list ++ .{Place{ .name = name, .point = search_sheet.place_row(r) }};
    }
    // The letters as the keyboard shows them first; the digits on its 123 keys
    // ("key.123" to show them, "key.abc" back), as Go to page shows them first
    for ("qwertyuiopasdfghjklzxcvbnm") |char| {
        const point = keyboard.place(.{ .char = char });
        list = list ++ .{Place{ .name = "key." ++ .{char}, .point = point }};
    }
    for ("1234567890") |char| {
        const point = keyboard.place(.{ .char = char });
        list = list ++ .{Place{ .name = "key.123." ++ .{char}, .point = point }};
    }
    list = list ++ .{
        Place{ .name = "key.123", .point = keyboard.place(.{ .layer = .symbols }) },
        Place{ .name = "key.abc", .point = keyboard.place(.{ .layer = .letters }) },
        Place{ .name = "key.shift", .point = keyboard.place(.shift) },
    };
    // A card's rows, for cards of every length: "card.<rows>.<row>"
    for (1..card.rows_longest + 1) |rows| for (0..rows) |i| {
        const name = std.fmt.comptimePrint("card.{d}.{d}", .{ rows, i });
        list = list ++ .{Place{ .name = name, .point = card.place(rows, i) }};
    };
    var placed: [list.len]Place = undefined;
    @memcpy(&placed, list);
    break :places placed;
};

comptime {
    @setEvalBranchQuota(200_000);
    // Each name once, so a name taps one place, and every place on the screen
    for (all, 0..) |p, i| {
        for (all[i + 1 ..]) |other| assert(!std.mem.eql(u8, p.name, other.name));
        assert(p.point.x >= 0);
        assert(p.point.x < width);
        assert(p.point.y >= 0);
        assert(p.point.y < height);
    }
}

/// `name` in lower case, as names are: "Bookerly" is "bookerly".
fn lower(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        _ = std.ascii.lowerString(&buf, name);
        const result = buf;
        return &result;
    }
}

/// The point named `name`, or null for a name no place has.
pub fn find(name: []const u8) ?Point {
    assert(name.len > 0);
    for (all) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.point;
    }
    return null;
}

test "the page's places turn, open the toolbar and close, clear of the thumbs" {
    try std.testing.expectEqual(@as(i32, 1), gestures.turn_direction(page.forward.x, width));
    try std.testing.expectEqual(@as(i32, -1), gestures.turn_direction(page.back.x, width));
    try std.testing.expect(page.top.y < touch.top_zone);
    for ([_]Point{ page.forward, page.back, page.middle }) |p| {
        try std.testing.expect(p.y >= touch.top_zone);
        try std.testing.expect(!touch.is_grip(p.x, p.y, width, height));
    }
}

test "running's places are its zones" {
    const zone = struct {
        fn of(p: Point) running.Zone {
            return running.zone(p.x, p.y, width, run.pause_band_px);
        }
    }.of;
    try std.testing.expectEqual(running.Zone.card, zone(running_mode.top));
    try std.testing.expectEqual(running.Zone.back, zone(running_mode.back));
    try std.testing.expectEqual(running.Zone.toggle, zone(running_mode.middle));
    try std.testing.expectEqual(running.Zone.next, zone(running_mode.next));
    for ([_]Point{ running_mode.back, running_mode.middle, running_mode.next }) |p| {
        try std.testing.expect(!touch.is_grip(p.x, p.y, width, height));
    }
}

test "names find their places, and no other name finds one" {
    try std.testing.expectEqual(toolbar.place(.bookmark), find("toolbar.bookmark").?);
    try std.testing.expectEqual(card.place(3, 0), find("card.3.0").?);
    try std.testing.expectEqual(keyboard.place(.{ .char = 's' }), find("key.s").?);
    try std.testing.expectEqual(aa.family_place(.{}, 1), find("aa.family.bookerly").?);
    try std.testing.expectEqual(aa.step_place(aa.margin_row, 3), find("aa.margins.3").?);
    try std.testing.expectEqual(@as(?Point, null), find("toolbar.nothing"));
}
