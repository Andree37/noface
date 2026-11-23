//! A card of rows over a dimmed screen, opened over another (`screen.open`): it ends with
//! the row tapped, or closes with a tap above it.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../app.zig");
const display = @import("../display.zig");
const card = @import("../ui/card.zig");
const input_mod = @import("../kindle/input.zig");
const screen = @import("screen.zig");

/// A card of rows over `background`, to open over a screen (`screen.open`): it ends
/// with the row tapped, or closes with a tap above it. Once it has ended, whatever
/// way, `closed` puts back what was under it.
pub fn over(
    a: *app.App,
    background: display.Backdrop,
    title: []const u8,
    subtitle: []const u8,
    rows: []const card.Row,
    book_cover: ?card.Cover,
) Card {
    assert(background.holds(&a.display)); // Put back over the whole screen
    // A card may have no rows: one that only says something, as a book downloading,
    // closed by a tap above it (`card.hit_with` gives `rows`, no row, on it)
    assert(rows.len <= card.rows_longest); // On the screen, under the status strip
    return .{
        .a = a,
        .background = background,
        .title = title,
        .subtitle = subtitle,
        .rows = rows,
        .cover = book_cover,
    };
}

/// What was under a card, back on the whole screen.
pub fn closed(a: *app.App, background: display.Backdrop) !void {
    assert(background.holds(&a.display));
    a.display.put_back(background);
    try a.display.show_band(0, a.display.screen.height);
}

/// A card closed with something else to draw straight after (another card, a screen,
/// the library afresh): what was under it put back, not shown, so the screen refreshes
/// once, for what comes next.
pub fn closed_quietly(a: *app.App, background: display.Backdrop) void {
    assert(background.holds(&a.display));
    a.display.put_back(background);
}

/// A card of rows over a dimmed screen: the row tapped, or closed by a tap above it.
pub const Card = struct {
    a: *app.App,
    background: display.Backdrop,
    title: []const u8,
    subtitle: []const u8,
    rows: []const card.Row,
    cover: ?card.Cover,

    pub const Result = u32;
    pub const touches = input_mod.Input.Modes.sheet;

    pub fn draw(c: *Card, _: screen.Part) !void {
        const a = c.a;
        assert(c.background.holds(&a.display));
        assert(c.rows.len <= card.rows_longest);
        const page = a.display.compose(c.background);
        try card.render_with(a.ui, page, c.title, c.subtitle, c.rows, c.cover);
        a.display.put_composed();
        try a.display.show_band(0, a.display.screen.height); // The whole screen dims behind it
    }

    pub fn on_tap(c: *Card, t: screen.Tap) !screen.Step(Result) {
        const rows: u32 = @intCast(c.rows.len);
        const index = card.hit_with(t.y, rows, c.cover) orelse return .close; // Above it
        return if (index < c.rows.len) .{ .done = index } else .stay; // Its title: nothing
    }
};
