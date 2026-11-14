//! Note popup, anchored to the bottom of the page.
const std = @import("std");
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

fn layout() text.Layout {
    return .{ .margin_x = margin, .margin_top = header + 24, .margin_bottom = 36, .indent = 0 };
}

fn geometry(width: u32, height: u32, stride: u32) Page {
    return .{ .buf = &.{}, .width = width, .height = height, .stride = stride };
}

pub const Fit = struct { height: u32, next: ?book_model.Pos };

/// Picks the smallest panel that holds the text from `start`.
/// A fixed `height` keeps the panel steady while paging through a long note.
pub fn fit(font: *Font, parts: []const book_model.Paragraph, start: book_model.Pos, width: u32, stride: u32, fixed: ?u32) !Fit {
    if (fixed) |h| {
        const next = try text.layoutPage(font, null, geometry(width, h, stride), parts, start, layout(), null);
        return .{ .height = h, .next = if (next.para >= parts.len) null else next };
    }
    for (heights) |h| {
        const next = try text.layoutPage(font, null, geometry(width, h, stride), parts, start, layout(), null);
        if (next.para >= parts.len) return .{ .height = h, .next = null };
    }
    const tallest = heights[heights.len - 1];
    const next = try text.layoutPage(font, null, geometry(width, tallest, stride), parts, start, layout(), null);
    return .{ .height = tallest, .next = next };
}

/// Draws into `panel`, whose buffer starts at the panel's top row.
pub fn render(font: *Font, fonts: Fonts, panel: Page, parts: []const book_model.Paragraph, start: book_model.Pos, more: bool) !void {
    _ = try text.renderPage(font, panel, parts, start, layout(), null);
    panel.fillRect(0, 0, panel.width, 4, 0x00);
    try fonts.title.draw(panel, margin, 62, "Note");
    const right: f32 = @floatFromInt(panel.width - margin);
    try fonts.small.draw(panel, right - 110, 62, if (more) "More >" else "Close");
    panel.fillRect(margin, header, panel.width - 2 * margin, 2, style.note_rule);
}
