//! The one slider used everywhere.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;

pub const Slider = struct { left: u32, right: u32, y: u32 };

const half_height = style.space.tiny;
const outline = style.stroke;
const knob_outer = style.space.medium;
const knob_inner = knob_outer - 2 * style.border; // A ring as thick as two borders
/// White kept clear around the knob, so the bar never touches its ring.
const knob_gap = style.border;
/// A step's dot, inside the bar.
const tick_radius = style.border;

comptime {
    // The outline leaves the bar a white middle, and the knob a white hole.
    assert(outline < half_height);
    assert(knob_inner < knob_outer);
    // A dot fits inside the bar's white middle
    assert(tick_radius < half_height);
}

/// Knob position for `value` out of `max`.
pub fn knob_at(s: Slider, value: u32, max: u32) u32 {
    assert(s.left < s.right);
    if (max == 0) return s.left;
    const span = s.right - s.left;
    const knob = s.left + @min(value, max) * span / max;
    assert(knob <= s.right);
    return knob;
}

/// Nearest value out of `max` for a finger at `x`.
pub fn value_at(s: Slider, x: i32, max: u32) u32 {
    assert(s.left < s.right);
    const left: i32 = @intCast(s.left);
    const span: i32 = @intCast(s.right - s.left);
    const at: u32 = @intCast(std.math.clamp(x - left, 0, span));
    const span_px: u32 = @intCast(span);
    const value = (at * max + span_px / 2) / span_px;
    assert(value <= max);
    return value;
}

/// Marks each step with a dot inside the bar, for sliders with only a few positions:
/// white on the filled part, before `knob`, and black after it. Call after `draw`.
pub fn draw_ticks(page: Page, s: Slider, max: u32, knob: u32) void {
    assert(knob >= s.left);
    assert(knob <= s.right);
    const y: f32 = @floatFromInt(s.y);
    var i: u32 = 1;
    while (i < max) : (i += 1) {
        const x = knob_at(s, i, max);
        const from_knob = @abs(@as(i32, @intCast(x)) - @as(i32, @intCast(knob)));
        // Under the knob or its gap: a dot there would stick out of it
        if (from_knob < knob_outer + knob_gap + tick_radius) continue;
        const shade: u8 = if (x < knob) 0xff else 0x00;
        page.pill(@floatFromInt(x), @floatFromInt(x), y, tick_radius, shade);
    }
}

/// A rounded bar, filled up to the knob, with a ring for a knob. Smooth edges at rest;
/// the drag frames threshold them back to black and white.
pub fn draw(page: Page, s: Slider, knob: u32) void {
    assert(knob >= s.left);
    assert(knob <= s.right);
    const left: f32 = @floatFromInt(s.left);
    const right: f32 = @floatFromInt(s.right);
    const y: f32 = @floatFromInt(s.y);
    const x: f32 = @floatFromInt(knob);
    const r: f32 = half_height;
    page.pill(left, right, y, r, style.black);
    page.pill(left, right, y, r - outline, style.white);
    // Left of the knob's ring, the bar shows only once there's room for its whole
    // rounded end: shorter, it would peek out as a sliver beside the ring, so it's
    // cleared, and the bar seems to start at the knob
    const ring: f32 = knob_outer + knob_gap;
    const stub = (x - ring) - (left - r);
    if (stub >= 2 * r) {
        page.pill(left, x, y, r, style.black);
    } else if (stub > 0) {
        const stub_left: u32 = @intFromFloat(@floor(left - r));
        const stub_top: u32 = @intFromFloat(@floor(y - r));
        // And the pixel rounding leaves beside the ring
        const stub_px: u32 = @as(u32, @intFromFloat(@ceil(stub))) + 1;
        // Not a size: the row pixel rounding leaves under the bar's floor, as beside it
        page.fill_rect(stub_left, stub_top, stub_px, 2 * half_height + 1, style.white);
    }
    page.pill(x, x, y, knob_outer + knob_gap, style.white);
    page.pill(x, x, y, knob_outer, style.black);
    page.pill(x, x, y, knob_inner, style.white);
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
