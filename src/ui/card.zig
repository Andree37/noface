//! A sheet that rises from the bottom, where thumbs are, over a dimmed screen: a
//! title, a line under it, and rows to tap. Tapping above it closes it. The
//! library's book actions and the reader's menu are both sheets.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

const header = style.space.wide + style.space.tall;
const cover_header = 2 * style.space.tall; // Room for a small cover beside the title
const cover_gap = style.space.roomy;
const cover_top = style.space.wide; // From the sheet's top to a cover's
const title_baseline = style.space.band; // From the sheet's top, without a cover
const subtitle_gap = style.space.wide; // From the title's baseline to the subtitle's
const row_height = style.space.band; // A fingertip and some
const bottom_pad = style.space.tiny + style.space.roomy;
/// The most rows a sheet is laid out for.
pub const rows_longest = 6;

comptime {
    assert(row_height >= style.fingertip);
    assert(header < cover_header);
    assert(title_baseline + subtitle_gap < header);
    assert(cover_top < title_baseline);
    assert(bottom_pad < row_height);
    // The longest sheet, with a cover, covers less than the screen
    assert(cover_header + rows_longest * row_height + bottom_pad < style.screen_height);
}

/// A book's cover shown small beside the title, already scaled.
pub const Cover = struct { pixels: []const u8, width: u32, height: u32 };

fn header_for(cover: ?Cover) u32 {
    const result: u32 = if (cover != null) cover_header else header;
    assert(result >= header);
    assert(result <= cover_header);
    return result;
}

/// One row. Info rows are facts rather than actions, set lighter; a danger row
/// (removing something) is set bold, so it isn't mistaken for the others.
pub const Row = struct { label: []const u8, quiet: bool = false, danger: bool = false };

pub fn height(rows: u32) u32 {
    const result = height_with(rows, null);
    assert(result > rows * row_height); // The header and padding besides
    return result;
}

fn height_with(rows: u32, cover: ?Cover) u32 {
    const result = header_for(cover) + rows * row_height + bottom_pad;
    // A sheet taller than the screen would start above it
    assert(result <= style.screen_height);
    assert(result >= header + bottom_pad);
    return result;
}

/// The middle of row `i` of a card of `rows` (one without a cover), for tests to tap.
pub fn row_centre(rows: u32, i: u32) u32 {
    assert(i < rows);
    assert(rows * row_height < style.screen_height); // A sheet fits the screen
    const below = rows - i; // Rows from this one to the bottom
    const centre = style.screen_height - bottom_pad - below * row_height + row_height / 2;
    assert(centre > top(rows));
    assert(centre < style.screen_height - bottom_pad);
    return centre;
}

/// The middle of row `i` of a card of `rows` (one without a cover), for a script to tap.
pub fn place(rows: u32, i: u32) style.Point {
    return .{ .x = style.screen_width / 2, .y = @intCast(row_centre(rows, i)) };
}

/// A tap above every card, which closes whichever is open: just under the status strip,
/// over the tallest card, with a cover.
pub fn place_above() style.Point {
    const y = style.status_height + style.fingertip / 2;
    comptime assert(y < style.screen_height - height_with(rows_longest, cover_sized));
    return .{ .x = style.screen_width / 2, .y = y };
}
/// A cover's place, for sizing the tallest card: only its having one counts.
const cover_sized: ?Cover = .{ .pixels = &.{}, .width = 0, .height = 0 };

pub fn top(rows: u32) u32 {
    const result = style.screen_height - height(rows);
    assert(result < style.screen_height);
    return result;
}

test "a row's middle is a tap on that row" {
    for (1..4) |rows| for (0..rows) |i| {
        const c = row_centre(@intCast(rows), @intCast(i));
        try std.testing.expectEqual(@as(?u32, @intCast(i)), hit(@intCast(c), @intCast(rows)));
    };
}

/// Which row a tap at height `y` lands on: `rows` itself for on the sheet but on no row
/// (its header, or the room below its last), null above it. Every row spans the sheet,
/// so where across doesn't matter.
pub fn hit(y: i32, rows: u32) ?u32 {
    const result = hit_with(y, rows, null);
    if (result) |row| assert(row <= rows);
    return result;
}

pub fn hit_with(y: i32, rows: u32, cover: ?Cover) ?u32 {
    assert(rows * row_height < style.screen_height); // A sheet fits the screen
    const sheet_top: i32 = @intCast(style.screen_height - height_with(rows, cover));
    assert(sheet_top >= 0);
    if (y < sheet_top) return null;
    const first = sheet_top + @as(i32, @intCast(header_for(cover)));
    assert(first > sheet_top);
    if (y < first) return rows;
    const row: u32 = @intCast(@divTrunc(y - first, row_height));
    return if (row < rows) row else rows;
}

/// Draws the sheet over `page`, which should hold what's behind it. That gets dimmed,
/// so the sheet is plainly in front.
pub fn render(
    fonts: Fonts,
    page: Page,
    title: []const u8,
    subtitle: []const u8,
    rows: []const Row,
) !void {
    return render_with(fonts, page, title, subtitle, rows, null);
}

/// The sheet with a small cover beside the title, when there is one.
pub fn render_with(
    fonts: Fonts,
    page: Page,
    title: []const u8,
    subtitle: []const u8,
    rows: []const Row,
    cover: ?Cover,
) !void {
    page.dim(0, 0, page.width, page.height);
    const h = height_with(@intCast(rows.len), cover);
    const sheet_top = style.screen_height - h;
    draw.sheet(page, sheet_top);
    var x: f32 = style.margin;
    var title_y: u32 = sheet_top + title_baseline;
    if (cover) |c| {
        // Scaled by us to fit the header, beside the title
        assert(c.pixels.len == c.width * c.height);
        assert(cover_top + c.height <= cover_header);
        const cover_y = sheet_top + cover_top;
        page.copy_image(style.margin, cover_y, c.pixels, c.width, c.height);
        const cover_foot = cover_y + c.height - style.fine_line;
        page.fill_rect(style.margin, cover_foot, c.width, style.fine_line, style.rule);
        x = @floatFromInt(style.margin + c.width + cover_gap);
        title_y = cover_y + c.height / 2;
    }
    const avail: f32 = @as(f32, @floatFromInt(page.width - style.margin)) - x;
    try draw.clipped(fonts.title, page, x, @intCast(title_y), title, avail);
    try draw.clipped(fonts.caption, page, x, @intCast(title_y + subtitle_gap), subtitle, avail);
    const subtitle_y: i32 = @intCast(title_y + subtitle_gap);
    fonts.caption.fade(page, @intFromFloat(x), subtitle_y, @intFromFloat(avail), style.faded);
    const row_x: f32 = style.margin;
    const row_avail: f32 = @floatFromInt(page.width - 2 * style.margin);
    for (rows, 0..) |r, i| {
        const y = sheet_top + header_for(cover) + @as(u32, @intCast(i)) * row_height;
        draw.rule(page, y);
        const font = if (r.danger) fonts.title else fonts.small;
        const baseline = font.centred_baseline(@intCast(y), row_height);
        try draw.clipped(font, page, row_x, baseline, r.label, row_avail);
        if (r.quiet) {
            font.fade(page, style.margin, baseline, @intFromFloat(row_avail), style.faded);
        }
    }
}

test "taps map to rows, the header, or nothing above the sheet" {
    const first: i32 = @intCast(top(3) + header);
    const middle = row_height / 2;
    try std.testing.expectEqual(@as(u32, 0), hit(first + middle, 3).?);
    try std.testing.expectEqual(@as(u32, 2), hit(first + 2 * row_height + middle, 3).?);
    try std.testing.expectEqual(@as(u32, 3), hit(first - 1, 3).?); // The header
    // The bottom padding
    try std.testing.expectEqual(@as(u32, 3), hit(style.screen_height - 1, 3).?);
    try std.testing.expect(hit(@as(i32, @intCast(top(3))) - 1, 3) == null);
}

test "the longest sheet leaves the top of the screen to tap away" {
    try std.testing.expect(top(rows_longest) >= style.fingertip);
}
