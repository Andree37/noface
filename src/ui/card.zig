//! A sheet that rises from the bottom, where thumbs are, over a dimmed screen: a
//! title, a line under it, and rows to tap. Tapping above it closes it. The
//! library's book actions and the reader's menu are both sheets.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

const header = 176;
const cover_header = 260; // Room for a small cover beside the title
const cover_gap = 32;

/// A book's cover shown small beside the title, already scaled.
pub const Cover = struct { pixels: []const u8, width: u32, height: u32 };

fn header_for(cover: ?Cover) u32 {
    return if (cover != null) cover_header else header;
}
const row_height = 112; // A fingertip and some
const bottom_pad = 40;

/// One row. Info rows are facts rather than actions, set lighter; a danger row
/// (removing something) is set bold, so it isn't mistaken for the others.
pub const Row = struct { label: []const u8, quiet: bool = false, danger: bool = false };

pub fn height(rows: usize) u32 {
    return height_with(rows, null);
}

fn height_with(rows: usize, cover: ?Cover) u32 {
    return header_for(cover) + @as(u32, @intCast(rows)) * row_height + bottom_pad;
}

/// The middle of row `i` of a card of `rows` (one without a cover), for tests to tap.
pub fn row_centre(rows: usize, i: usize) u32 {
    return style.screen_height - bottom_pad - @as(u32, @intCast(rows - i)) * row_height + row_height / 2;
}

pub fn top(rows: usize) u32 {
    return style.screen_height - height(rows);
}

test "a row's middle is a tap on that row" {
    for (1..4) |rows| for (0..rows) |i| {
        const c = row_centre(rows, i);
        try std.testing.expectEqual(@as(?usize, i), hit(600, @intCast(c), rows));
    };
}

/// Which row a tap lands on: `rows` itself for the sheet's header, null above it.
pub fn hit(x: i32, y: i32, rows: usize) ?usize {
    return hit_with(x, y, rows, null);
}

pub fn hit_with(x: i32, y: i32, rows: usize, cover: ?Cover) ?usize {
    _ = x;
    const sheet_top: i32 = @intCast(style.screen_height - height_with(rows, cover));
    if (y < sheet_top) return null;
    const first = sheet_top + @as(i32, @intCast(header_for(cover)));
    if (y < first) return rows;
    const row: usize = @intCast(@divTrunc(y - first, row_height));
    return if (row < rows) row else rows;
}

/// Draws the sheet over `page`, which should hold what's behind it. That gets dimmed,
/// so the sheet is plainly in front.
pub fn render(fonts: Fonts, page: Page, title: []const u8, subtitle: []const u8, rows: []const Row) !void {
    return render_with(fonts, page, title, subtitle, rows, null);
}

/// The sheet with a small cover beside the title, when there is one.
pub fn render_with(fonts: Fonts, page: Page, title: []const u8, subtitle: []const u8, rows: []const Row, cover: ?Cover) !void {
    page.dim(0, 0, page.width, page.height);
    const h = height_with(rows.len, cover);
    const sheet_top = style.screen_height - h;
    draw.sheet(page, sheet_top);
    var x: f32 = style.margin;
    var title_y: u32 = sheet_top + 92;
    if (cover) |c| {
        const cover_top = sheet_top + 52;
        page.copy_image(style.margin, cover_top, c.pixels, c.width, c.height);
        page.fill_rect(style.margin, cover_top + c.height - 1, c.width, 1, style.rule);
        x = @floatFromInt(style.margin + c.width + cover_gap);
        title_y = cover_top + c.height / 2;
    }
    const avail: f32 = @as(f32, @floatFromInt(page.width - style.margin)) - x;
    try draw.clipped(fonts.title, page, x, @intCast(title_y), title, avail);
    try draw.clipped(fonts.caption, page, x, @intCast(title_y + 48), subtitle, avail);
    page.tint(@intFromFloat(x), title_y + 20, @intFromFloat(avail), 44, style.faded);
    const row_x: f32 = style.margin;
    const row_avail: f32 = @floatFromInt(page.width - 2 * style.margin);
    for (rows, 0..) |r, i| {
        const y = sheet_top + header_for(cover) + @as(u32, @intCast(i)) * row_height;
        page.fill_rect(style.margin, y, page.width - 2 * style.margin, 1, style.rule);
        const font = if (r.danger) fonts.title else fonts.small;
        try draw.clipped(font, page, row_x, @intCast(y + 70), r.label, row_avail);
        if (r.quiet) page.tint(style.margin, y + 30, @intFromFloat(row_avail), 54, style.faded);
    }
}

test "taps map to rows, the header, or nothing above the sheet" {
    const y0: i32 = @intCast(top(3) + header);
    try std.testing.expectEqual(@as(usize, 0), hit(600, y0 + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 2), hit(600, y0 + 2 * row_height + 10, 3).?);
    try std.testing.expectEqual(@as(usize, 3), hit(600, y0 - 20, 3).?);
    try std.testing.expectEqual(@as(usize, 3), hit(600, style.screen_height - 5, 3).?); // Bottom padding
    try std.testing.expect(hit(600, 40, 3) == null);
}

test "the sheet fits on screen with the longest menu" {
    try std.testing.expect(height(6) < style.screen_height / 2 + 300);
}
