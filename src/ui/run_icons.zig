//! Running's two icons, drawn with smooth edges as the letters beside them are: the
//! text waveform changes so small a gray cleanly. The pause button, a ring with two
//! bars while the phrases go on and a triangle once stopped, and the dial, a thin ring
//! thickening round from twelve o'clock like a clock's hand over a phrase's time, with
//! an arrow in its middle while the pace has just gone up or down. Where they go is
//! running's screen's (screens/reader/run_view.zig).
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const style = @import("style.zig");

/// Sizes in points, turned into the screen's pixels by its density as every other size
/// is (style.zig), so the icons match their words on any Kindle.
pub const dial_radius_px = style.pt(5.25);
const ring_px = style.stroke;
const sweep_px = style.pt(1.75); // How thick the ring is where it has swept
const arrow_half_px = style.pt(1.75); // The arrow's half width, and its height
/// Steps of the sweep, as a clock's hours: each a refresh of the dial alone.
pub const dial_steps = 12;
pub const pause_radius_px = style.pt(5.75);

comptime {
    assert(ring_px < sweep_px);
    assert(sweep_px + arrow_half_px < dial_radius_px);
    assert(dial_radius_px < pause_radius_px); // The button a little larger
}

/// Which way the dial's arrow points: up for a quicker pace, down for a slower.
pub const Arrow = enum { up, down };

/// How finely an icon's pixels are sampled for their smooth edges: this many across
/// and down, as the letters beside them are smoothed.
const samples = 4;

/// Paints the square of `side` pixels from (`left`, `top`) in each pixel's share of
/// `shape`: black where it covers it all, gray where only some, as smooth as the text.
/// `shape.inside(x, y)` takes a point from the square's middle.
fn paint(page: Page, left: u32, top: u32, side: u32, shape: anytype) void {
    assert(side > 0);
    assert(left + side <= page.width);
    assert(top + side <= page.height);
    const half = @as(f32, @floatFromInt(side)) / 2;
    for (0..side) |row| for (0..side) |column| {
        var covered: u32 = 0;
        for (0..samples) |i| for (0..samples) |j| {
            const x = sample_at(column, j) - half;
            const y = sample_at(row, i) - half;
            if (shape.inside(x, y)) covered += 1;
        };
        assert(covered <= samples * samples);
        const value = 255 - covered * 255 / (samples * samples);
        const y: u32 = top + @as(u32, @intCast(row));
        const x: u32 = left + @as(u32, @intCast(column));
        page.buf[y * page.stride + x] = @intCast(value);
    };
}

/// Sample `sample` of pixel `pixel`, across or down: evenly inside it.
fn sample_at(pixel: usize, sample: usize) f32 { // usize: loop counters
    assert(sample < samples);
    const offset = (@as(f32, @floatFromInt(sample)) + 0.5) / samples;
    return @as(f32, @floatFromInt(pixel)) + offset;
}

/// Whether (`x`, `y`) lies in a ring of `outer` and `inner` radii about the middle.
fn in_ring(x: f32, y: f32, outer: f32, inner: f32) bool {
    assert(inner < outer);
    const d2 = x * x + y * y;
    return d2 <= outer * outer and d2 >= inner * inner;
}

/// The pause button: a ring like the dial's, a little larger, with two bars in it while
/// the phrases go on, and a triangle to carry on once stopped.
const PauseShape = struct {
    stopped: bool,

    // Assertions: a pure shape test, asked once for each sample of each pixel
    fn inside(shape: PauseShape, x: f32, y: f32) bool {
        const r: f32 = pause_radius_px;
        if (in_ring(x, y, r, r - ring_px)) return true;
        const icon = r / 2; // The bars' and the triangle's half height
        if (@abs(y) > icon) return false;
        if (shape.stopped) {
            // A triangle pointing right, its middle a little right of the centre
            const from = -icon + 3;
            return x >= from and x - from <= 2 * (icon - @abs(y));
        }
        return @abs(x) >= 3 and @abs(x) <= 3 + 4; // Two bars
    }
};

/// The dial: a thin ring, thick where it has swept, with an arrow up or down in it.
const DialShape = struct {
    swept: f32, // How far round, from twelve o'clock, in radians
    arrow: ?Arrow,

    // Assertions: a pure shape test, asked once for each sample of each pixel
    fn inside(shape: DialShape, x: f32, y: f32) bool {
        const r: f32 = dial_radius_px;
        if (in_ring(x, y, r, r - ring_px)) return true;
        if (shape.swept > 0 and in_ring(x, y, r, r - sweep_px)) {
            // Clockwise from twelve o'clock
            var angle = std.math.atan2(x, -y);
            if (angle < 0) angle += std.math.tau;
            if (angle < shape.swept) return true;
        }
        const way = shape.arrow orelse return false;
        // A triangle, its point up for a quicker pace, down for a slower
        const h: f32 = arrow_half_px;
        const from_point = switch (way) {
            .up => y + h / 2,
            .down => h / 2 - y,
        };
        return from_point >= 0 and from_point <= h and @abs(x) <= from_point;
    }
};

/// The pause button centred on (`cx`, `cy`) on `page`, with bars while the phrases go
/// on and a triangle once `stopped`.
pub fn pause_button(page: Page, cx: i32, cy: i32, stopped: bool) void {
    const r = pause_radius_px;
    assert(cx - r >= 0);
    assert(cy + r < page.height);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    paint(page, left, top, 2 * r + 1, PauseShape{ .stopped = stopped });
}

/// The dial centred on (`cx`, `cy`) on `page`, swept `step` of `dial_steps` of the way
/// round, with `arrow` in its middle, up or down, when there is one.
pub fn dial(page: Page, cx: i32, cy: i32, step: u32, arrow: ?Arrow) void {
    assert(step < dial_steps);
    const r = dial_radius_px;
    assert(cx - r >= 0);
    assert(cy + r < page.height);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    const swept = @as(f32, @floatFromInt(step)) / dial_steps * std.math.tau;
    const shape: DialShape = .{ .swept = swept, .arrow = arrow };
    paint(page, left, top, 2 * r + 1, shape);
}

/// The ink in a square of `side` from (`left`, `top`): how dark it is, all told.
fn ink(page: Page, left: u32, top: u32, side: u32) u64 {
    var total: u64 = 0;
    for (top..top + side) |row| {
        for (page.buf[row * page.stride + left ..][0..side]) |pixel| total += 255 - pixel;
    }
    return total;
}

test "the dial darkens as it sweeps, and its arrow and the button's stop show" {
    const side = 2 * pause_radius_px + 1;
    var pixels: [side * side]u8 = undefined;
    const page: Page = .{ .buf = &pixels, .width = side, .height = side, .stride = side };
    const middle = pause_radius_px;
    const corner = pause_radius_px - dial_radius_px;
    const dial_side = 2 * dial_radius_px + 1;
    var last: u64 = 0;
    for (0..dial_steps) |step| {
        @memset(&pixels, 0xff);
        dial(page, middle, middle, @intCast(step), null);
        const now = ink(page, corner, corner, dial_side);
        try std.testing.expect(now > last or step == 0); // Thicker with each step
        last = now;
    }
    @memset(&pixels, 0xff);
    dial(page, middle, middle, 0, null);
    const plain = ink(page, corner, corner, dial_side);
    @memset(&pixels, 0xff);
    dial(page, middle, middle, 0, .up);
    try std.testing.expect(ink(page, corner, corner, dial_side) > plain);
    // Bars and a triangle differ, and both are inside the ring
    @memset(&pixels, 0xff);
    pause_button(page, middle, middle, false);
    const bars = ink(page, 0, 0, side);
    @memset(&pixels, 0xff);
    pause_button(page, middle, middle, true);
    try std.testing.expect(ink(page, 0, 0, side) != bars);
}
