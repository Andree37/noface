//! A grayscale pixel buffer and the shapes drawn onto it.
const std = @import("std");
const check = @import("../base/check.zig");

pub const Page = struct {
    buf: []u8,
    width: u32,
    height: u32,
    stride: u32,

    /// Fills a rectangle, clipped to the page.
    pub fn fillRect(p: Page, x: u32, y: u32, w: u32, h: u32, value: u8) void {
        if (x >= p.width or y >= p.height) return;
        const width = @min(w, p.width - x);
        var row = y;
        while (row < @min(y +| h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            check.that(start + width <= p.buf.len, "fill stays inside the page buffer");
            @memset(p.buf[start .. start + width], value);
        }
    }

    /// Fades an area toward white, for disabled controls. Clipped to the page.
    pub fn dim(p: Page, x: u32, y: u32, w: u32, h: u32) void {
        if (x >= p.width) return;
        var row = y;
        while (row < @min(y +| h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            for (p.buf[start .. start + @min(w, p.width - x)]) |*px| px.* = 0xc8 + px.* / 5;
        }
    }

    fn darken(p: Page, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0 or x >= p.width or y >= p.height or coverage <= 0) return;
        const at = @as(usize, @intCast(y)) * p.stride + @as(usize, @intCast(x));
        const value: u8 = @intFromFloat(255 * (1 - std.math.clamp(coverage, 0, 1)));
        p.buf[at] = @min(p.buf[at], value);
    }

    /// Fills a rounded bar from `x0` to `x1` at height `cy`, `radius` tall each side,
    /// in any gray, with smooth edges. With `x0 == x1` it is a smooth disc.
    pub fn pill(p: Page, x0: f32, x1: f32, cy: f32, radius: f32, value: u8) void {
        const top: i32 = @intFromFloat(@floor(cy - radius - 1));
        const bottom: i32 = @intFromFloat(@ceil(cy + radius + 1));
        const left: i32 = @intFromFloat(@floor(x0 - radius - 1));
        const right: i32 = @intFromFloat(@ceil(x1 + radius + 1));
        // Pixels whose centres sit between x0 and x1 are the straight part: their
        // distance from the bar's spine is just how far up or down they are, so they
        // need no square root, and where they're fully covered a row is one fill.
        const mid_lo: i32 = @intFromFloat(@ceil(x0 - 0.5));
        const mid_hi: i32 = @intFromFloat(@floor(x1 - 0.5));
        const v: f32 = @floatFromInt(value);
        var y: i32 = @max(top, 0);
        while (y <= bottom and y < p.height) : (y += 1) {
            const ey = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            if (@abs(ey) >= radius + 0.5) continue;
            const row = @as(usize, @intCast(y)) * p.stride;
            const mid_cover = std.math.clamp(radius + 0.5 - @abs(ey), 0, 1);
            var x: i32 = @max(left, 0);
            while (x <= right and x < p.width) : (x += 1) {
                if (x >= mid_lo and x <= mid_hi) {
                    if (mid_cover >= 1) {
                        const end = @min(mid_hi, @as(i32, @intCast(p.width)) - 1);
                        @memset(p.buf[row + @as(usize, @intCast(x)) .. row + @as(usize, @intCast(end)) + 1], value);
                        x = end;
                        continue;
                    }
                    blendAt(p, row + @as(usize, @intCast(x)), v, mid_cover);
                    continue;
                }
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const ex = px - std.math.clamp(px, x0, x1);
                const coverage = std.math.clamp(radius + 0.5 - @sqrt(ex * ex + ey * ey), 0, 1);
                if (coverage <= 0) continue;
                blendAt(p, row + @as(usize, @intCast(x)), v, coverage);
            }
        }
    }

    fn blendAt(p: Page, at: usize, v: f32, coverage: f32) void {
        if (coverage >= 1) {
            p.buf[at] = @intFromFloat(v);
            return;
        }
        const old: f32 = @floatFromInt(p.buf[at]);
        p.buf[at] = @intFromFloat(@round(old + (v - old) * coverage));
    }

    /// How much of the pixel at (`px`, `py`) a rectangle with rounded corners covers.
    fn roundCoverage(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, radius: f32) f32 {
        const dx = @max(@abs(px - (x + w / 2)) - (w / 2 - radius), 0);
        const dy = @max(@abs(py - (y + h / 2)) - (h / 2 - radius), 0);
        if (dx == 0 and dy == 0) return 1;
        return std.math.clamp(radius + 0.5 - @sqrt(dx * dx + dy * dy), 0, 1);
    }

    /// Fills a rectangle with rounded corners, in any gray, with smooth edges.
    pub fn roundRect(p: Page, x: u32, y: u32, w: u32, h: u32, radius: f32, value: u8) void {
        const v: f32 = @floatFromInt(value);
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        // Columns whose centres are within the straight top and bottom edges: on a row
        // inside the straight sides as well, they're fully covered, so one fill.
        const flat_lo: u32 = @intFromFloat(@max(@ceil(fx + radius - 0.5), 0));
        const flat_hi: u32 = @intFromFloat(@max(@floor(fx + fw - radius - 0.5), -1));
        var row = y;
        while (row < @min(y + h, p.height)) : (row += 1) {
            const py = @as(f32, @floatFromInt(row)) + 0.5;
            const inside_rows = @abs(py - (fy + fh / 2)) <= fh / 2 - radius;
            var col = x;
            while (col < @min(x + w, p.width)) : (col += 1) {
                if (inside_rows and col >= flat_lo and col <= flat_hi) {
                    const end = @min(flat_hi, p.width - 1);
                    @memset(p.buf[row * p.stride + col .. row * p.stride + end + 1], value);
                    col = end;
                    continue;
                }
                const c = roundCoverage(@as(f32, @floatFromInt(col)) + 0.5, py, fx, fy, fw, fh, radius);
                if (c <= 0) continue;
                p.blendAt(row * p.stride + col, v, c);
            }
        }
    }

    /// Smooth line with round ends.
    pub fn stroke(p: Page, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {
        const r = width / 2;
        const left: i32 = @intFromFloat(@floor(@min(x0, x1) - r - 1));
        const right: i32 = @intFromFloat(@ceil(@max(x0, x1) + r + 1));
        const top: i32 = @intFromFloat(@floor(@min(y0, y1) - r - 1));
        const bottom: i32 = @intFromFloat(@ceil(@max(y0, y1) + r + 1));
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = @max(dx * dx + dy * dy, 0.0001);
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const t = std.math.clamp(((px - x0) * dx + (py - y0) * dy) / len2, 0, 1);
                const ex = px - (x0 + t * dx);
                const ey = py - (y0 + t * dy);
                p.darken(x, y, r + 0.5 - @sqrt(ex * ex + ey * ey));
            }
        }
    }

    pub fn arc(p: Page, cx: f32, cy: f32, radius: f32, from: f32, to: f32, width: f32) void {
        const steps = 48;
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const a0 = from + (to - from) * @as(f32, @floatFromInt(i)) / steps;
            const a1 = from + (to - from) * @as(f32, @floatFromInt(i + 1)) / steps;
            p.stroke(cx + @cos(a0) * radius, cy + @sin(a0) * radius, cx + @cos(a1) * radius, cy + @sin(a1) * radius, width);
        }
    }

    /// Fills a polygon, sampling each pixel four times for smooth edges.
    pub fn fillPoly(p: Page, points: []const [2]f32) void {
        var min_x: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (points) |pt| {
            min_x = @min(min_x, pt[0]);
            max_x = @max(max_x, pt[0]);
            min_y = @min(min_y, pt[1]);
            max_y = @max(max_y, pt[1]);
        }
        var y: i32 = @intFromFloat(@floor(min_y));
        while (y <= @as(i32, @intFromFloat(@ceil(max_y)))) : (y += 1) {
            var x: i32 = @intFromFloat(@floor(min_x));
            while (x <= @as(i32, @intFromFloat(@ceil(max_x)))) : (x += 1) {
                var hits: u32 = 0;
                for ([_][2]f32{ .{ 0.25, 0.25 }, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, .{ 0.75, 0.75 } }) |s| {
                    const sx = @as(f32, @floatFromInt(x)) + s[0];
                    const sy = @as(f32, @floatFromInt(y)) + s[1];
                    var inside = false;
                    var j = points.len - 1;
                    for (points, 0..) |a, i| {
                        const b = points[j];
                        if ((a[1] > sy) != (b[1] > sy) and sx < (b[0] - a[0]) * (sy - a[1]) / (b[1] - a[1]) + a[0]) inside = !inside;
                        j = i;
                    }
                    if (inside) hits += 1;
                }
                p.darken(x, y, @as(f32, @floatFromInt(hits)) / 4);
            }
        }
    }

    /// White tick for the finished badge.
    pub fn fillPolyWhiteCheck(p: Page, cx: f32, cy: f32) void {
        const pts = [_][4]f32{ .{ -11, 1, -3, 9 }, .{ -3, 9, 12, -8 } };
        for (pts) |l| {
            var t: f32 = 0;
            while (t <= 1) : (t += 0.02) {
                const x = cx + l[0] + (l[2] - l[0]) * t;
                const y = cy + l[1] + (l[3] - l[1]) * t;
                p.disc(@intFromFloat(x), @intFromFloat(y), 2, 0, 0xff);
            }
        }
    }

    /// Lifts black toward `floor`, for secondary text and lines.
    pub fn tint(p: Page, x: u32, y: u32, w: u32, h: u32, floor: u8) void {
        if (x >= p.width) return;
        var row = y;
        while (row < @min(y +| h, p.height)) : (row += 1) {
            const start = row * p.stride + x;
            for (p.buf[start .. start + @min(w, p.width - x)]) |*px| {
                const span: u32 = 255 - @as(u32, floor);
                px.* = @intCast(@as(u32, floor) + @as(u32, px.*) * span / 255);
            }
        }
    }

    /// Forces a band to pure black and white, for waveforms that can't show gray.
    pub fn threshold(p: Page, top: u32, height: u32) void {
        const start = top * p.stride;
        for (p.buf[start .. start + height * p.stride]) |*px| px.* = if (px.* < 128) 0x00 else 0xff;
    }

    /// Filled disc, or a ring when `inner` is above zero.
    /// A disc of radius `outer` centred on pixel (`cx`, `cy`), or a ring when `inner`
    /// is above zero, in any gray, with smooth edges.
    pub fn disc(p: Page, cx: i32, cy: i32, outer: i32, inner: i32, value: u8) void {
        const ro: f32 = @floatFromInt(outer);
        const ri: f32 = @floatFromInt(inner);
        const v: f32 = @floatFromInt(value);
        var y = -outer - 1;
        while (y <= outer + 1) : (y += 1) {
            var x = -outer - 1;
            while (x <= outer + 1) : (x += 1) {
                const px = cx + x;
                const py = cy + y;
                if (px < 0 or py < 0 or px >= p.width or py >= p.height) continue;
                const d = @sqrt(@as(f32, @floatFromInt(x * x + y * y)));
                var c = std.math.clamp(ro + 0.5 - d, 0, 1);
                if (inner > 0) c = @min(c, std.math.clamp(d - ri + 0.5, 0, 1));
                if (c <= 0) continue;
                const at = @as(usize, @intCast(py)) * p.stride + @as(usize, @intCast(px));
                const old: f32 = @floatFromInt(p.buf[at]);
                p.buf[at] = @intFromFloat(@round(old + (v - old) * c));
            }
        }
    }

    /// Lays an icon drawn in black on the white `tile` onto this page in white,
    /// centred on (`cx`, `cy`). Each pixel lightens as far as the icon covers it, so
    /// smooth edges stay smooth over black or over gray. Clipped to the page.
    pub fn stampWhite(p: Page, tile: Page, cx: i32, cy: i32) void {
        const left = cx - @as(i32, @intCast(tile.width / 2));
        const top = cy - @as(i32, @intCast(tile.height / 2));
        for (0..tile.height) |row| {
            const y = top + @as(i32, @intCast(row));
            if (y < 0 or y >= p.height) continue;
            for (0..tile.width) |col| {
                const x = left + @as(i32, @intCast(col));
                if (x < 0 or x >= p.width) continue;
                const at = @as(usize, @intCast(y)) * p.stride + @as(usize, @intCast(x));
                const cover: u32 = 0xff - @as(u32, tile.buf[row * tile.stride + col]);
                const bg: u32 = p.buf[at];
                p.buf[at] = @intCast(bg + (0xff - bg) * cover / 0xff);
            }
        }
    }

    pub fn copyImage(p: Page, x: u32, y: u32, src: []const u8, w: u32, h: u32) void {
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            @memcpy(p.buf[(y + row) * p.stride + x ..][0..w], src[row * w ..][0..w]);
        }
    }
};

test "rounded rectangles fill square in the middle and leave the corners" {
    var buf: [20 * 20]u8 = @splat(0xff);
    const p = Page{ .buf = &buf, .width = 20, .height = 20, .stride = 20 };
    p.roundRect(0, 0, 20, 20, 6, 0x00);
    try std.testing.expectEqual(@as(u8, 0x00), buf[10 * 20 + 10]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0 * 20 + 10]); // Straight edge
    try std.testing.expectEqual(@as(u8, 0xff), buf[0]); // Corner stays out
}

test "stamped icons lighten by how much they cover, over any gray" {
    // An 8x8 page inside a 10-wide buffer, half black and half mid gray
    var under: [10 * 8]u8 = @splat(0x00);
    for (0..8) |row| @memset(under[row * 10 + 4 .. row * 10 + 8], 0x40);
    const page = Page{ .buf = &under, .width = 8, .height = 8, .stride = 10 };
    // A 4x2 icon inside a 6-wide buffer: full cover, half cover, none
    var tile_buf: [6 * 2]u8 = @splat(0xff);
    tile_buf[0] = 0x00;
    tile_buf[1] = 0x80;
    tile_buf[2] = 0x00;
    tile_buf[3] = 0x80;
    const tile = Page{ .buf = &tile_buf, .width = 4, .height = 2, .stride = 6 };
    page.stampWhite(tile, 4, 4); // Covers columns 2..5, rows 3..4
    try std.testing.expectEqual(@as(u8, 0xff), under[3 * 10 + 2]); // Full, over black
    try std.testing.expectEqual(@as(u8, 0x7f), under[3 * 10 + 3]); // Half, over black
    try std.testing.expectEqual(@as(u8, 0xff), under[3 * 10 + 4]); // Full, over gray
    try std.testing.expectEqual(@as(u8, 0x9f), under[3 * 10 + 5]); // Half, over gray
    try std.testing.expectEqual(@as(u8, 0x00), under[4 * 10 + 2]); // Uncovered stays
    try std.testing.expectEqual(@as(u8, 0x40), under[3 * 10 + 6]); // Beside it stays
    try std.testing.expectEqual(@as(u8, 0x00), under[3 * 10 + 8]); // Past the page width
    page.stampWhite(tile, -1, 7); // Mostly off the page: no crash, nothing outside
    page.stampWhite(tile, 100, 100);
}

test "discs have smooth edges" {
    var buf: [21 * 21]u8 = @splat(0xff);
    const page = Page{ .buf = &buf, .width = 21, .height = 21, .stride = 21 };
    page.disc(10, 10, 6, 0, 0x00);
    try std.testing.expectEqual(@as(u8, 0x00), buf[10 * 21 + 10]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[0]);
    var grays: usize = 0;
    for (buf) |v| {
        if (v != 0x00 and v != 0xff) grays += 1;
    }
    try std.testing.expect(grays > 8);
    page.disc(-30, 0, 4, 0, 0x00); // Off the page: nothing happens
}

test "dim and tint clip to the page" {
    var buf: [4 * 4]u8 = @splat(0x00);
    const page = Page{ .buf = &buf, .width = 4, .height = 4, .stride = 4 };
    page.dim(5, 0, 2, 2);
    page.tint(0, 1, 2, std.math.maxInt(u32), 0x50);
    page.dim(0, 0, 10, 10);
    try std.testing.expect(buf[0] != 0x00);
}

fn pillReference(p: Page, x0: f32, x1: f32, cy: f32, radius: f32, value: u8) void {
    const top: i32 = @intFromFloat(@floor(cy - radius - 1));
    const bottom: i32 = @intFromFloat(@ceil(cy + radius + 1));
    const left: i32 = @intFromFloat(@floor(x0 - radius - 1));
    const right: i32 = @intFromFloat(@ceil(x1 + radius + 1));
    var y = @max(top, 0);
    while (y <= bottom and y < p.height) : (y += 1) {
        var x = @max(left, 0);
        while (x <= right and x < p.width) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const ex = px - std.math.clamp(px, x0, x1);
            const ey = py - cy;
            const coverage = std.math.clamp(radius + 0.5 - @sqrt(ex * ex + ey * ey), 0, 1);
            if (coverage <= 0) continue;
            const at = @as(usize, @intCast(y)) * p.stride + @as(usize, @intCast(x));
            const old: f32 = @floatFromInt(p.buf[at]);
            p.buf[at] = @intFromFloat(@round(old + (@as(f32, @floatFromInt(value)) - old) * coverage));
        }
    }
}

fn roundRectReference(p: Page, x: u32, y: u32, w: u32, h: u32, radius: f32, value: u8) void {
    const v: f32 = @floatFromInt(value);
    var row = y;
    while (row < @min(y + h, p.height)) : (row += 1) {
        var col = x;
        while (col < @min(x + w, p.width)) : (col += 1) {
            const c = Page.roundCoverage(@as(f32, @floatFromInt(col)) + 0.5, @as(f32, @floatFromInt(row)) + 0.5, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), radius);
            if (c <= 0) continue;
            const at = row * p.stride + col;
            const old: f32 = @floatFromInt(p.buf[at]);
            p.buf[at] = @intFromFloat(@round(old + (v - old) * c));
        }
    }
}

test "the fast rounded rectangle draws exactly what the plain one did" {
    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    var a: [64 * 48]u8 = undefined;
    var b: [64 * 48]u8 = undefined;
    for (0..400) |_| {
        for (&a, &b) |*pa, *pb| {
            const g = rand.int(u8);
            pa.* = g;
            pb.* = g;
        }
        const pa = Page{ .buf = &a, .width = 60, .height = 48, .stride = 64 };
        const pb = Page{ .buf = &b, .width = 60, .height = 48, .stride = 64 };
        const x = rand.uintLessThan(u32, 70);
        const y = rand.uintLessThan(u32, 56);
        const w = rand.uintLessThan(u32, 50) + 1;
        const h = rand.uintLessThan(u32, 40) + 1;
        const r = rand.float(f32) * @as(f32, @floatFromInt(@min(w, h))) / 2;
        const value = rand.int(u8);
        pa.roundRect(x, y, w, h, r, value);
        roundRectReference(pb, x, y, w, h, r, value);
        try std.testing.expectEqualSlices(u8, &b, &a);
    }
}

test "the fast pill draws exactly what the plain one did" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var a: [64 * 48]u8 = undefined;
    var b: [64 * 48]u8 = undefined;
    for (0..400) |_| {
        for (&a, &b) |*pa, *pb| {
            const g = rand.int(u8);
            pa.* = g;
            pb.* = g;
        }
        const pa = Page{ .buf = &a, .width = 60, .height = 48, .stride = 64 };
        const pb = Page{ .buf = &b, .width = 60, .height = 48, .stride = 64 };
        const x0 = rand.float(f32) * 80 - 10;
        const x1 = x0 + rand.float(f32) * 40;
        const cy = rand.float(f32) * 60 - 6;
        const r = rand.float(f32) * 20 + 0.5;
        const value = rand.int(u8);
        pa.pill(x0, x1, cy, r, value);
        pillReference(pb, x0, x1, cy, r, value);
        try std.testing.expectEqualSlices(u8, &b, &a);
    }
}

test "pills fill their middle and blend their edge" {
    var buf: [20 * 10]u8 = @splat(0xff);
    const p = Page{ .buf = &buf, .width = 20, .height = 10, .stride = 20 };
    p.pill(5, 14, 5, 4, 0x00);
    try std.testing.expectEqual(@as(u8, 0x00), buf[5 * 20 + 10]); // Middle
    try std.testing.expectEqual(@as(u8, 0xff), buf[0 * 20 + 0]); // Outside
    const edge = buf[5 * 20 + 1]; // Half covered at the rounded end
    try std.testing.expect(edge > 0x00 and edge < 0xff);
    p.pill(-50, 50, -50, 2, 0x00); // Off the page: nothing happens
}

test "fills clip to the page, even when they start off it" {
    var buf: [16]u8 = @splat(0xff);
    const p = Page{ .buf = &buf, .width = 4, .height = 4, .stride = 4 };
    p.fillRect(3, 3, 10, 10, 0);
    try std.testing.expectEqual(@as(u8, 0), buf[15]);
    try std.testing.expectEqual(@as(u8, 0xff), buf[14]);
    p.fillRect(9, 0, 2, 2, 0); // Starts past the right edge: draws nothing
    p.fillRect(0, 9, 2, 2, 0);
    try std.testing.expectEqual(@as(u8, 0xff), buf[0]);
}
