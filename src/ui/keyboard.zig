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
/// The widest row of keys fills the screen's width inside the tray's edge, so the keys
/// grow with the screen; each takes a fingertip's height.
const widest_row: comptime_int = rows[0].len;
const key_width = (style.screen_width - 2 * tray_pad - (widest_row - 1) * gap) / widest_row;
const key_height = style.fingertip;
const gap = style.space.tiny;
const row_step = key_height + gap;
/// The letter rows, then a row with space and Search.
const row_count: u32 = rows.len + 1;
/// The tray's edge round the keys: over the first row, under the last, and right of
/// backspace.
const tray_pad = style.space.snug;
/// The keys' first row, and the keyboard's top: its tray's edge over them. Everything
/// from `top` down is the keyboard's to draw.
const keys_top = style.screen_height - row_count * row_step - tray_pad;
pub const top = keys_top - tray_pad;

pub const Key = union(enum) { char: u8, backspace, space, enter };

fn row_left(row: u32) i32 {
    assert(row < rows.len);
    const n: i32 = @intCast(rows[row].len);
    const width = n * (key_width + gap) - gap;
    const left = @divTrunc(style.screen_width - width, 2);
    assert(left > 0);
    return left;
}

/// The special keys: backspace beside the last letter row, then space and Search,
/// centred like the rows above, a wider gap between them.
const backspace_width = key_width + key_width / 2; // A key and a half
const backspace_x = style.screen_width - tray_pad - backspace_width;
const space_width = style.screen_width / 2;
const enter_width = 2 * key_width + gap; // Two keys wide
const enter_gap = style.space.medium;
const space_left = (style.screen_width - space_width - enter_gap - enter_width) / 2;
const enter_left = space_left + space_width + enter_gap;
const last_letters: u32 = rows.len - 1;

comptime {
    // Every key is on the screen, below the status strip.
    assert(keys_top > style.status_height);
    assert(keys_top + row_count * row_step <= style.screen_height);
    assert(enter_left + enter_width <= style.screen_width);
    // Backspace sits clear of the last letter row.
    assert(row_left(last_letters) + rows[last_letters].len * (key_width + gap) < backspace_x);
    // A key's face, shadow and all, fits inside its tap area.
    assert(key_height > 2 * inset + shadow_drop);
    assert(key_width > 2 * inset);
}

pub fn hit(x: i32, y: i32) ?Key {
    if (y < keys_top) return null;
    const row: u32 = @intCast(@divTrunc(y - keys_top, row_step));
    if (row < rows.len) {
        if (row == last_letters and x >= backspace_x) return .backspace;
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

/// The middle of a key's taps.
pub fn place(target: Key) style.Point {
    const middle_down = key_height / 2;
    const first_y: i32 = keys_top + middle_down; // The first row's middle
    const last_row_y: i32 = first_y + @as(i32, rows.len) * row_step;
    const point: style.Point = switch (target) {
        .char => |char| char: for (rows, 0..) |row, r| {
            const column = std.mem.indexOfScalar(u8, row, char) orelse continue;
            const left = row_left(@intCast(r)) + @as(i32, @intCast(column)) * (key_width + gap);
            const y = first_y + @as(i32, @intCast(r)) * row_step;
            break :char .{ .x = left + key_width / 2, .y = y };
        } else unreachable, // A key the keyboard has
        .backspace => .{
            .x = backspace_x + backspace_width / 2,
            .y = first_y + @as(i32, last_letters) * row_step,
        },
        .space => .{ .x = space_left + space_width / 2, .y = last_row_y },
        .enter => .{ .x = enter_left + enter_width / 2, .y = last_row_y },
    };
    assert(point.y < style.screen_height);
    assert(std.meta.eql(hit(point.x, point.y), target));
    return point;
}

test "every key's place is a tap on it" {
    for (rows) |row| for (row) |char| {
        const p = place(.{ .char = char });
        try std.testing.expectEqual(Key{ .char = char }, hit(p.x, p.y).?);
    };
    for ([_]Key{ .backspace, .space, .enter }) |special_key| {
        const p = place(special_key);
        try std.testing.expectEqual(special_key, hit(p.x, p.y).?);
    }
}

// The keys sit on a light gray tray, white with rounded corners and a soft shadow
const tray = 0xe2;
const shadow = 0xa8;
const special = 0xc4; // Delete and space: a step darker than letters
const corner = style.key_corner;
// Drawn a little inside their tap area, so neighbours have a clear gap
const inset = style.space.hair;
/// How far a key's shadow shows under its face.
const shadow_drop = style.space.hair;

comptime {
    // The backspace tag stays inside its key
    const backspace_cx = backspace_x + backspace_width / 2;
    assert(backspace_cx - icons.backspace_left >= backspace_x);
    assert(backspace_cx + icons.backspace_right <= backspace_x + backspace_width);
}

fn key_face(page: Page, x: i32, y: u32, w: u32, face: u8) void {
    assert(x + inset >= 0);
    assert(w > 2 * inset);
    const left: u32 = @intCast(x + inset);
    const width = w - 2 * inset;
    const height = key_height - 2 * inset;
    page.round_rect(left, y + inset + shadow_drop, width, height, corner, shadow);
    page.round_rect(left, y + inset, width, height, corner, face);
}

fn key(fonts: Fonts, page: Page, x: i32, y: u32, w: u32, label: []const u8, face: u8) !void {
    assert(y >= keys_top);
    assert(label.len > 0);
    key_face(page, x, y, w, face);
    const center_x: f32 = @floatFromInt(x + @as(i32, @intCast(w / 2)));
    const baseline = fonts.small.centred_baseline(@intCast(y), key_height);
    try draw.centered(fonts.small, page, center_x, baseline, label);
}

pub fn render(fonts: Fonts, page: Page) !void {
    assert(page.height > keys_top);
    assert(page.width >= enter_left + enter_width);
    page.fill_rect(0, top, page.width, page.height - top, tray);
    for (rows, 0..) |r, row_index| {
        const row: u32 = @intCast(row_index);
        const y: u32 = keys_top + row * row_step;
        for (r, 0..) |c, column| {
            const x = row_left(row) + @as(i32, @intCast(column)) * (key_width + gap);
            try key(fonts, page, x, y, key_width, &.{c}, style.white);
        }
    }
    const last: u32 = keys_top + last_letters * row_step;
    key_face(page, backspace_x, last, backspace_width, special);
    const backspace_cx = backspace_x + backspace_width / 2;
    icons.backspace(page, backspace_cx, @floatFromInt(last + key_height / 2));
    const bottom: u32 = keys_top + rows.len * row_step;
    try key(fonts, page, space_left, bottom, space_width, "space", style.white);
    // The main key: black like a key that's on, shadow and all, its label in white
    key_face(page, enter_left, bottom, enter_width, style.black);
    const Label = struct {
        fonts: Fonts,
        pub fn draw(l: @This(), t: Page, cx: f32, _: f32) !void {
            // Drawn on a tile the size of the key.
            assert(t.width == enter_width);
            assert(t.height == key_height);
            // Centred in the key, as the other keys' labels are
            const baseline = l.fonts.title.centred_baseline(0, key_height);
            try centered(l.fonts.title, t, cx, baseline, "Search");
        }
    };
    const enter_cx = enter_left + enter_width / 2;
    const enter_cy: i32 = @intCast(bottom + key_height / 2);
    const label = Label{ .fonts = fonts };
    try icons.draw_white(page, enter_width, key_height, enter_cx, enter_cy, label);
}

/// The middle of key `column` on letter row `row`.
fn test_key(row: u32, column: u32) [2]i32 {
    const x = row_left(row) + @as(i32, @intCast(column)) * (key_width + gap) + key_width / 2;
    const y: i32 = @intCast(keys_top + row * row_step + key_height / 2);
    return .{ x, y };
}

test "keys map to letters, and the special keys answer" {
    for (rows, 0..) |r, row| {
        for (r, 0..) |c, column| {
            const at = test_key(@intCast(row), @intCast(column));
            try std.testing.expectEqual(Key{ .char = c }, hit(at[0], at[1]).?);
        }
    }
    const last_y = test_key(last_letters, 0)[1];
    const backspace_mid = backspace_x + backspace_width / 2;
    try std.testing.expectEqual(Key.backspace, hit(backspace_mid, last_y).?);
    const bottom_y: i32 = @intCast(keys_top + rows.len * row_step + key_height / 2);
    try std.testing.expectEqual(Key.space, hit(space_left + space_width / 2, bottom_y).?);
    try std.testing.expectEqual(Key.enter, hit(enter_left + enter_width / 2, bottom_y).?);
    try std.testing.expect(hit(style.screen_width / 2, keys_top - 1) == null);
}

test "the bottom row is centred, as the letters are" {
    const left_room = space_left;
    const right_room = style.screen_width - (enter_left + enter_width);
    try std.testing.expect(@abs(@as(i32, left_room) - @as(i32, right_room)) <= 1);
}
