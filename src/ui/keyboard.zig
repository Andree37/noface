//! An on-screen keyboard along the bottom of the screen. Letters and digits only:
//! search ignores case and accents, so nothing else is needed.
const std = @import("std");
const assert = std.debug.assert;
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

fn row_left(row: u32) i32 {
    assert(row < rows.len);
    const n: i32 = @intCast(rows[row].len);
    const width = n * (key_width + gap) - gap;
    const left = @divTrunc(style.screen_width - width, 2);
    assert(left > 0);
    return left;
}

/// The special keys: backspace beside the last letter row, then space and Search.
const backspace_width = 180;
const backspace_x = style.screen_width - 16 - backspace_width;
const space_left = 140;
const space_width = 640;
const enter_left = space_left + space_width + gap * 3;
const enter_width = 300;

comptime {
    // Every key is on the screen, below the status strip.
    assert(top > style.status_height);
    assert(top + 5 * row_step <= style.screen_height);
    assert(enter_left + enter_width <= style.screen_width);
    // Backspace sits clear of the last letter row.
    assert(row_left(3) + 7 * (key_width + gap) < backspace_x);
    // A key's face, shadow and all, fits inside its tap area.
    assert(key_height > 2 * inset + 3);
    assert(key_width > 2 * inset);
}

pub fn hit(x: i32, y: i32) ?Key {
    if (y < top) return null;
    const row: u32 = @intCast(@divTrunc(y - top, row_step));
    if (row < rows.len) {
        if (row == 3 and x >= backspace_x) return .backspace;
        const left = row_left(row);
        if (x < left) return null;
        const column: u32 = @intCast(@divTrunc(x - left, key_width + gap));
        if (column >= rows[row].len) return null;
        const char = rows[row][column];
        assert(std.ascii.isLower(char) or std.ascii.isDigit(char));
        return .{ .char = char };
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
    assert(x + inset >= 0);
    assert(w > 2 * inset);
    const left: u32 = @intCast(x + inset);
    const width = w - 2 * inset;
    const height = key_height - 2 * inset;
    page.round_rect(left, y + inset + 3, width, height, corner, shadow);
    page.round_rect(left, y + inset, width, height, corner, face);
}

fn key(fonts: Fonts, page: Page, x: i32, y: u32, w: u32, label: []const u8, face: u8) !void {
    assert(y >= top);
    assert(label.len > 0);
    key_face(page, x, y, w, face);
    const center_x: f32 = @floatFromInt(x + @as(i32, @intCast(w / 2)));
    try draw.centered(fonts.small, page, center_x, @intCast(y + 68), label);
}

/// Backspace: a tag pointing left with a cross in it.
fn backspace_icon(page: Page, cx: f32, cy: f32) void {
    // The tag stays inside its key.
    assert(cx - 30 >= backspace_x);
    assert(cx + 26 <= backspace_x + backspace_width);
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
    assert(page.height > top);
    assert(page.width >= enter_left + enter_width);
    page.fill_rect(0, top - 16, page.width, page.height - (top - 16), tray);
    for (rows, 0..) |r, row_index| {
        const row: u32 = @intCast(row_index);
        const y: u32 = top + row * row_step;
        for (r, 0..) |c, column| {
            const x = row_left(row) + @as(i32, @intCast(column)) * (key_width + gap);
            try key(fonts, page, x, y, key_width, &.{c}, style.white);
        }
    }
    const last: u32 = top + 3 * row_step;
    key_face(page, backspace_x, last, backspace_width, special);
    const backspace_cx = backspace_x + backspace_width / 2;
    backspace_icon(page, backspace_cx, @floatFromInt(last + key_height / 2));
    const bottom: u32 = top + 4 * row_step;
    try key(fonts, page, space_left, bottom, space_width, "space", style.white);
    // The main key: black like a key that's on, shadow and all, its label in white
    key_face(page, enter_left, bottom, enter_width, style.black);
    const Label = struct {
        fonts: Fonts,
        pub fn draw(l: @This(), t: Page, cx: f32, _: f32) !void {
            // Drawn on a tile the size of the key.
            assert(t.width == enter_width);
            assert(t.height == key_height);
            try centered(l.fonts.title, t, cx, 70, "Search"); // Baseline as on the other keys
        }
    };
    const enter_cx = enter_left + enter_width / 2;
    const enter_cy: i32 = @intCast(bottom + key_height / 2);
    const label = Label{ .fonts = fonts };
    try icons.draw_white(page, enter_width, key_height, enter_cx, enter_cy, label);
}

test "keys map to letters, and the special keys answer" {
    try std.testing.expectEqual(Key{ .char = 'q' }, hit(row_left(1) + 10, top + row_step + 10).?);
    const zero_x = row_left(0) + 9 * (key_width + gap) + 10;
    try std.testing.expectEqual(Key{ .char = '0' }, hit(zero_x, top + 10).?);
    const m_x = row_left(3) + 6 * (key_width + gap) + 10;
    try std.testing.expectEqual(Key{ .char = 'm' }, hit(m_x, top + 3 * row_step + 10).?);
    try std.testing.expectEqual(Key.backspace, hit(backspace_x + 20, top + 3 * row_step + 10).?);
    try std.testing.expectEqual(Key.space, hit(space_left + 100, top + 4 * row_step + 10).?);
    try std.testing.expectEqual(Key.enter, hit(enter_left + 100, top + 4 * row_step + 10).?);
    try std.testing.expect(hit(600, top - 50) == null);
}

test "the keyboard fits, with backspace clear of the letters" {
    try std.testing.expect(top + 5 * row_step <= style.screen_height);
    try std.testing.expect(row_left(3) + 7 * (key_width + gap) < backspace_x);
}
