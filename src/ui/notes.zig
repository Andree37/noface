//! Note popup, anchored to the bottom of the page.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const book_model = @import("../model/book.zig");
const Fonts = @import("fonts.zig").Fonts;
const settings_model = @import("../model/settings.zig");
const text = @import("../layout/text.zig");

pub const max_parts = 8;
/// The panel's header: its height, "Note" and Close's baseline in it, the rule under it,
/// and the black edge along the panel's top.
const header = style.space.snug + style.space.wider;
const header_baseline = style.space.wider;
const header_rule = style.stroke;
const edge = style.space.hair;
const margin = style.space.band;
/// The panel's heights, smallest first, from the screen's; the smallest has room for a
/// line of the largest text under its header, whatever the screen.
const heights = [_]u32{
    @max(style.screen_height / 5, least_height),
    style.screen_height / 3,
    style.screen_height / 2,
};
const least_height: u32 = layout.margin_top + layout.margin_bottom +
    @as(u32, @intFromFloat(line_most)) + 1;
const line_most = settings_model.sizes[settings_model.sizes.len - 1] *
    settings_model.spacings[settings_model.spacings.len - 1];
/// The note's text: under the header, and over the panel's foot.
const text_gap = style.space.medium;
const text_room_below = style.space.roomy;

const layout = text.Layout{
    .margin_x = margin,
    .margin_top = header + text_gap,
    .margin_bottom = text_room_below,
    .indent = 0,
    .underline = .{
        .thick_px = style.reading.underline_thick,
        .above_foot_px = style.reading.underline_above_foot,
    },
};

comptime {
    // Panels grow in steps, and even the smallest has room for a line under its header.
    for (heights[1..], heights[0 .. heights.len - 1]) |taller, smaller| assert(taller > smaller);
    assert(layout.margin_top + layout.margin_bottom + line_most < heights[0]);
    assert(heights[heights.len - 1] < style.screen_height);
    assert(2 * margin < style.screen_width);
}

/// Whether `height` is one of the panel's sizes.
fn is_panel_height(height: u32) bool {
    return std.mem.indexOfScalar(u32, &heights, height) != null;
}

fn geometry(width: u32, height: u32, stride: u32) Page {
    assert(width <= stride);
    assert(is_panel_height(height));
    return .{ .buf = &.{}, .width = width, .height = height, .stride = stride };
}

pub const Fit = struct { height: u32, next: ?book_model.Pos };

/// Picks the smallest panel that holds the text from `start`.
/// A fixed `height` keeps the panel steady while paging through a long note.
pub fn fit(
    font: *Font,
    parts: []const book_model.Paragraph,
    start: book_model.Pos,
    width: u32,
    stride: u32,
    fixed: ?u32,
) !Fit {
    assert(width > 2 * margin);
    // A fixed height is the one the note's first part was given.
    if (fixed) |h| {
        assert(is_panel_height(h));
        return fit_in(font, parts, start, geometry(width, h, stride), h);
    }
    // The shortest panel the note fits in whole, laid out once each; the tallest, with
    // the rest of the note to follow, if none holds it
    const shorter = heights[0 .. heights.len - 1];
    for (shorter) |h| {
        const fitted = try fit_in(font, parts, start, geometry(width, h, stride), h);
        if (fitted.next == null) return fitted;
    }
    const tallest = heights[heights.len - 1];
    return fit_in(font, parts, start, geometry(width, tallest, stride), tallest);
}

/// The note from `start` laid out in a panel `height` tall: where the rest goes on,
/// if it doesn't all fit.
fn fit_in(
    font: *Font,
    parts: []const book_model.Paragraph,
    start: book_model.Pos,
    shape: Page,
    height: u32,
) !Fit {
    assert(shape.height == height);
    assert(is_panel_height(height));
    const next = try text.layout_page(font, null, shape, parts, start, &layout, null);
    return .{ .height = height, .next = if (next.para >= parts.len) null else next };
}

/// Draws into `panel`, whose buffer starts at the panel's top row.
pub fn render(
    font: *Font,
    fonts: Fonts,
    panel: Page,
    parts: []const book_model.Paragraph,
    start: book_model.Pos,
    more: bool,
) !void {
    assert(panel.width > 2 * margin);
    assert(is_panel_height(panel.height)); // As `fit` chose
    _ = try text.render_page(font, panel, parts, start, &layout, null);
    panel.fill_rect(0, 0, panel.width, edge, style.black);
    try fonts.title.draw(panel, margin, header_baseline, "Note");
    // Ending at the margin, whichever it says
    const right: f32 = @floatFromInt(panel.width - margin);
    const action = if (more) "More >" else "Close";
    const action_x = right - try fonts.small.measure(action);
    try fonts.small.draw(panel, action_x, header_baseline, action);
    panel.fill_rect(margin, header, panel.width - 2 * margin, header_rule, style.note_rule);
}
