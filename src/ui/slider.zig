//! The one slider used everywhere.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;

pub const Slider = struct { left: u32, right: u32, y: u32 };

const half_height = 7;
const outline = 2;
const knob_outer = 27;
const knob_inner = 21;

/// Knob position for `value` out of `max`.
pub fn knob_at(s: Slider, value: u32, max: u32) u32 {
    if (max == 0) return s.left;
    const span = s.right - s.left;
    return s.left + @min(value, max) * span / max;
}

/// Nearest value out of `max` for a finger at `x`.
pub fn value_at(s: Slider, x: i32, max: u32) u32 {
    const left: i32 = @intCast(s.left);
    const span: i32 = @intCast(s.right - s.left);
    const at: u32 = @intCast(std.math.clamp(x - left, 0, span));
    return (at * max + @as(u32, @intCast(span)) / 2) / @as(u32, @intCast(span));
}

/// Marks each step with a dot inside the bar, for sliders with only a few positions:
/// white on the filled part, before `knob`, and black after it. Call after `draw`.
pub fn draw_ticks(page: Page, s: Slider, max: u32, knob: u32) void {
    const y: f32 = @floatFromInt(s.y);
    var i: u32 = 1;
    while (i < max) : (i += 1) {
        const x = knob_at(s, i, max);
        if (@abs(@as(i32, @intCast(x)) - @as(i32, @intCast(knob))) < knob_outer + 6) continue; // Under the knob
        page.pill(@floatFromInt(x), @floatFromInt(x), y, 3, if (x < knob) 0xff else 0x00);
    }
}

/// A rounded bar, filled up to the knob, with a ring for a knob. Smooth edges at rest;
/// the drag frames threshold them back to black and white.
pub fn draw(page: Page, s: Slider, knob: u32) void {
    const left: f32 = @floatFromInt(s.left);
    const right: f32 = @floatFromInt(s.right);
    const y: f32 = @floatFromInt(s.y);
    const x: f32 = @floatFromInt(knob);
    const r: f32 = half_height;
    page.pill(left, right, y, r, 0x00);
    page.pill(left, right, y, r - outline, 0xff);
    if (knob > s.left) page.pill(left, x, y, r, 0x00);
    page.pill(x, x, y, knob_outer + 3, 0xff); // A clear gap around the knob
    page.pill(x, x, y, knob_outer, 0x00);
    page.pill(x, x, y, knob_inner, 0xff);
}

test "value and knob agree" {
    const s = Slider{ .left = 100, .right = 1100, .y = 50 };
    try std.testing.expectEqual(@as(u32, 100), knob_at(s, 0, 24));
    try std.testing.expectEqual(@as(u32, 1100), knob_at(s, 24, 24));
    try std.testing.expectEqual(@as(u32, 600), knob_at(s, 12, 24));
    try std.testing.expectEqual(@as(u32, 0), value_at(s, 0, 24));
    try std.testing.expectEqual(@as(u32, 24), value_at(s, 2000, 24));
    try std.testing.expectEqual(@as(u32, 12), value_at(s, 600, 24));
}

test "small ranges snap to the nearest step" {
    const s = Slider{ .left = 0, .right = 900, .y = 50 };
    try std.testing.expectEqual(@as(u32, 1), value_at(s, 260, 3));
    try std.testing.expectEqual(@as(u32, 2), value_at(s, 500, 3));
}
