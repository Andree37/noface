//! An on-screen keyboard along the bottom of the screen. Letters and digits only:
//! search ignores case and accents, so nothing else is needed.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;
const icons = @import("icons.zig");
const centered = draw.centered; // Named apart from the label's own draw method

const rows = [_][]const u8{ "1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm" };
const key_width = 116;
const key_height = 112;
const gap = 8;
const row_step = key_height + gap;
pub const top = style.screen_height - 5 * row_step - 16;

pub const Key = union(enum) { char: u8, backspace, space, enter };

fn row_left(row: usize) i32 {
    const n: i32 = @intCast(rows[row].len);
    const width = n * (key_width + gap) - gap;
    return @divTrunc(style.screen_width - width, 2);
}

/// The special keys: backspace beside the last letter row, then space and Search.
const backspace_x = style.screen_width - 16 - 180;
const space_left = 140;
const space_width = 640;
const enter_left = space_left + space_width + gap * 3;
const enter_width = 300;

pub fn hit(x: i32, y: i32) ?Key {
    if (y < top) return null;
    const row: usize = @intCast(@divTrunc(y - top, row_step));
    if (row < rows.len) {
        if (row == 3 and x >= backspace_x) return .backspace;
        const left = row_left(row);
        if (x < left) return null;
        const col: usize = @intCast(@divTrunc(x - left, key_width + gap));
        return if (col < rows[row].len) .{ .char = rows[row][col] } else null;
    }
    if (row == rows.len) {
        if (x >= space_left and x < space_left + space_width) return .space;
        if (x >= enter_left and x < enter_left + enter_width) return .enter;
    }
    return null;
}

// The keys sit on a light gray tray, white with rounded corners and a soft shadow
const tray = 0xe2;
const shadow = 0xa8;
const special = 0xc4; // Delete and space: a step darker than letters
const corner = style.key_corner;
// Drawn a little inside their tap area, so neighbours have a clear gap
const inset = 3;

fn key_face(page: Page, x: i32, y: u32, w: u32, face: u8) void {
    const left: u32 = @intCast(x + inset);
    const width = w - 2 * inset;
    const height = key_height - 2 * inset;
    page.round_rect(left, y + inset + 3, width, height, corner, shadow);
    page.round_rect(left, y + inset, width, height, corner, face);
}

fn key(fonts: Fonts, page: Page, x: i32, y: u32, w: u32, label: []const u8, face: u8) !void {
    key_face(page, x, y, w, face);
    try draw.centered(fonts.small, page, @floatFromInt(x + @as(i32, @intCast(w / 2))), @intCast(y + 68), label);
}

/// Backspace: a tag pointing left with a cross in it.
fn backspace_icon(page: Page, cx: f32, cy: f32) void {
    const l = cx - 30;
    const r = cx + 26;
    page.stroke(l, cy, l + 16, cy - 18, 3);
    page.stroke(l, cy, l + 16, cy + 18, 3);
    page.stroke(l + 16, cy - 18, r, cy - 18, 3);
    page.stroke(l + 16, cy + 18, r, cy + 18, 3);
    page.stroke(r, cy - 18, r, cy + 18, 3);
    page.stroke(cx - 4, cy - 8, cx + 12, cy + 8, 3);
    page.stroke(cx - 4, cy + 8, cx + 12, cy - 8, 3);
}

pub fn render(fonts: Fonts, page: Page) !void {
    page.fill_rect(0, top - 16, page.width, page.height - (top - 16), tray);
    for (rows, 0..) |r, row| {
        const y: u32 = top + @as(u32, @intCast(row)) * row_step;
        for (r, 0..) |c, col| {
            const x = row_left(row) + @as(i32, @intCast(col)) * (key_width + gap);
            try key(fonts, page, x, y, key_width, &.{c}, style.white);
        }
    }
    const last: u32 = top + 3 * row_step;
    key_face(page, backspace_x, last, 180, special);
    backspace_icon(page, backspace_x + 90, @floatFromInt(last + key_height / 2));
    const bottom: u32 = top + 4 * row_step;
    try key(fonts, page, space_left, bottom, space_width, "space", style.white);
    // The main key: black like a key that's on, shadow and all, its label in white
    key_face(page, enter_left, bottom, enter_width, style.black);
    const Label = struct {
        fonts: Fonts,
        pub fn draw(l: @This(), t: Page, cx: f32, _: f32) !void {
            try centered(l.fonts.title, t, cx, 70, "Search"); // Baseline as on the other keys
        }
    };
    try icons.draw_white(page, enter_width, key_height, enter_left + enter_width / 2, @intCast(bottom + key_height / 2), Label{ .fonts = fonts });
}

test "keys map to letters, and the special keys answer" {
    try std.testing.expectEqual(Key{ .char = 'q' }, hit(row_left(1) + 10, top + row_step + 10).?);
    try std.testing.expectEqual(Key{ .char = '0' }, hit(row_left(0) + 9 * (key_width + gap) + 10, top + 10).?);
    try std.testing.expectEqual(Key{ .char = 'm' }, hit(row_left(3) + 6 * (key_width + gap) + 10, top + 3 * row_step + 10).?);
    try std.testing.expectEqual(Key.backspace, hit(backspace_x + 20, top + 3 * row_step + 10).?);
    try std.testing.expectEqual(Key.space, hit(space_left + 100, top + 4 * row_step + 10).?);
    try std.testing.expectEqual(Key.enter, hit(enter_left + 100, top + 4 * row_step + 10).?);
    try std.testing.expect(hit(600, top - 50) == null);
}

test "the keyboard fits, with backspace clear of the letters" {
    try std.testing.expect(top + 5 * row_step <= style.screen_height);
    try std.testing.expect(row_left(3) + 7 * (key_width + gap) < backspace_x);
}
