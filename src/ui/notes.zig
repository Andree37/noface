//! Note popup, anchored to the bottom of the page.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const book_model = @import("../model/book.zig");
const Fonts = @import("fonts.zig").Fonts;
const text = @import("../layout/text.zig");

pub const max_parts = 8;
const header = 84;
const margin = 100;
const heights = [_]u32{ 340, 560, 820 };

const layout = text.Layout{
    .margin_x = margin,
    .margin_top = header + 24,
    .margin_bottom = 36,
    .indent = 0,
};

comptime {
    // Panels grow in steps, and even the smallest has room for a line under its header.
    for (heights[1..], heights[0 .. heights.len - 1]) |taller, smaller| assert(taller > smaller);
    assert(layout.margin_top + layout.margin_bottom + 100 < heights[0]);
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
    if (fixed) |h| assert(is_panel_height(h));
    if (fixed) |h| {
        const shape = geometry(width, h, stride);
        const next = try text.layout_page(font, null, shape, parts, start, &layout, null);
        return .{ .height = h, .next = if (next.para >= parts.len) null else next };
    }
    for (heights) |h| {
        const shape = geometry(width, h, stride);
        const next = try text.layout_page(font, null, shape, parts, start, &layout, null);
        if (next.para >= parts.len) return .{ .height = h, .next = null };
    }
    const tallest = heights[heights.len - 1];
    const shape = geometry(width, tallest, stride);
    const next = try text.layout_page(font, null, shape, parts, start, &layout, null);
    return .{ .height = tallest, .next = next };
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
    panel.fill_rect(0, 0, panel.width, 4, 0x00);
    try fonts.title.draw(panel, margin, 62, "Note");
    const right: f32 = @floatFromInt(panel.width - margin);
    try fonts.small.draw(panel, right - 110, 62, if (more) "More >" else "Close");
    panel.fill_rect(margin, header, panel.width - 2 * margin, 2, style.note_rule);
}
