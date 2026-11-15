//! A card of rows over a dimmed screen, opened over another (`screen.open`): it ends with
//! the row tapped, or closes with a tap above it.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../app.zig");
const card = @import("../ui/card.zig");
const input_mod = @import("../kindle/input.zig");
const screen = @import("screen.zig");

/// A card of rows over `background`, to open over a screen (`screen.open`): it ends
/// with the row tapped, or closes with a tap above it. Once it has ended, whatever
/// way, `closed` puts back what was under it.
pub fn over(
    a: *app.App,
    background: []const u8,
    title: []const u8,
    subtitle: []const u8,
    rows: []const card.Row,
    book_cover: ?card.Cover,
) Card {
    assert(background.len == a.screen.pixels.len); // Put back over the whole screen
    assert(a.overlay.len == a.screen.pixels.len); // The card is drawn there first
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
pub fn closed(a: *app.App, background: []const u8) !void {
    assert(background.len == a.screen.pixels.len);
    assert(background.ptr != a.screen.pixels.ptr); // Kept apart from what's shown
    @memcpy(a.screen.pixels, background);
    try a.show_band(0, a.screen.height);
}

/// A card of rows over a dimmed screen: the row tapped, or closed by a tap above it.
pub const Card = struct {
    a: *app.App,
    background: []const u8,
    title: []const u8,
    subtitle: []const u8,
    rows: []const card.Row,
    cover: ?card.Cover,

    pub const Result = u32;
    pub const touches = input_mod.Input.Modes.sheet;

    pub fn draw(c: *Card, _: screen.Part) !void {
        const a = c.a;
        assert(a.overlay.len == a.screen.pixels.len);
        assert(c.background.len == a.overlay.len); // Both a whole screen
        @memcpy(a.overlay, c.background);
        try card.render_with(a.ui, a.page(a.overlay), c.title, c.subtitle, c.rows, c.cover);
        @memcpy(a.screen.pixels, a.overlay);
        try a.show_band(0, a.screen.height); // The whole screen dims behind it
    }

    pub fn on_tap(c: *Card, t: screen.Tap) !screen.Step(Result) {
        const rows: u32 = @intCast(c.rows.len);
        const index = card.hit_with(t.x, t.y, rows, c.cover) orelse return .close; // Above it
        return if (index < c.rows.len) .{ .done = index } else .stay; // Its title: nothing
    }
};
