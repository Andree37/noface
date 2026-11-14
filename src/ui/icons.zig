//! Panel icons, drawn as smooth vector shapes.
const std = @import("std");
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const text = @import("../layout/text.zig");

const Pen = struct {
    page: Page,
    cx: f32,
    cy: f32,
    scale: f32 = 1,

    fn x(p: Pen, v: f32) f32 {
        return p.cx + v * p.scale;
    }

    fn y(p: Pen, v: f32) f32 {
        return p.cy + v * p.scale;
    }

    fn line(p: Pen, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {
        p.page.stroke(p.x(x0), p.y(y0), p.x(x1), p.y(y1), width * p.scale);
    }

    fn arc(p: Pen, ox: f32, oy: f32, radius: f32, from: f32, to: f32, width: f32) void {
        p.page.arc(p.x(ox), p.y(oy), radius * p.scale, std.math.degreesToRadians(from), std.math.degreesToRadians(to), width * p.scale);
    }
};

const pi: f32 = std.math.pi;

pub fn ring(page: Page, cx: f32, cy: f32, radius: f32) void {
    page.arc(cx, cy, radius, 0, 2 * pi, 3);
}

pub fn airplane(page: Page, cx: f32, cy: f32) void {
    const outline = [_][2]f32{
        .{ 0, -36 },  .{ 4, -31 },  .{ 5, -11 },  .{ 33, 7 },   .{ 33, 14 },  .{ 5, 4 },
        .{ 4, 21 },   .{ 13, 29 },  .{ 13, 34 },  .{ 0, 29 },   .{ -13, 34 }, .{ -13, 29 },
        .{ -4, 21 },  .{ -5, 4 },   .{ -33, 14 }, .{ -33, 7 },  .{ -5, -11 }, .{ -4, -31 },
    };
    var points: [outline.len][2]f32 = undefined;
    const c = @cos(pi / 4);
    for (outline, &points) |o, *r| {
        r.* = .{ cx + (o[0] - o[1]) * c, cy + (o[0] + o[1]) * c };
    }
    page.fillPoly(&points);
}

pub fn bluetooth(page: Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.line(0, -32, 0, 32, 4);
    p.line(0, -32, 17, -16, 4);
    p.line(17, -16, -17, 16, 4);
    p.line(-17, -16, 17, 16, 4);
    p.line(17, 16, 0, 32, 4);
}

pub fn wifi(page: Page, cx: f32, cy: f32, scale: f32, bars: u32) void {
    // Drawn around its own middle, so it can share a line with text.
    const p = Pen{ .page = page, .cx = cx, .cy = cy + 2 * scale, .scale = scale };
    page.disc(@intFromFloat(p.x(0)), @intFromFloat(p.y(24)), @intFromFloat(@max(6 * scale, 2)), 0, 0x00);
    const radii = [_]f32{ 19, 34, 49 };
    for (radii, 0..) |r, i| {
        if (bars > 0 and i >= bars) continue;
        p.arc(0, 24, r, -135, -45, 6);
    }
}

pub fn sync(page: Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.arc(0, 0, 28, 200, 330, 4);
    p.arc(0, 0, 28, 20, 150, 4);
    arrowHead(p, 28, 330);
    arrowHead(p, 28, 150);
}

/// Barbs at the end of a clockwise arc, pointing along it.
fn arrowHead(p: Pen, radius: f32, degrees: f32) void {
    const a = std.math.degreesToRadians(degrees);
    const tip_x = @cos(a) * radius;
    const tip_y = @sin(a) * radius;
    const behind = a - pi / 2;
    for ([_]f32{ -0.6, 0.6 }) |spread| {
        const b = behind + spread;
        p.line(tip_x, tip_y, tip_x + @cos(b) * 14, tip_y + @sin(b) * 14, 4);
    }
}

/// A smile arrow, for going back to the Kindle's own home screen.
pub fn smile(page: Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    // The smile: the lower part of a circle, a little flatter than a half.
    p.arc(0, -26, 36, 25, 155, 6);
    // The arrowhead at its right end, pointing up and out along the curve.
    const tip_x = @cos(std.math.degreesToRadians(25.0)) * 36 + 4;
    const tip_y = -26 + @sin(std.math.degreesToRadians(25.0)) * 36 - 4;
    p.line(tip_x, tip_y, tip_x - 15, tip_y - 1, 6);
    p.line(tip_x, tip_y, tip_x - 3, tip_y + 14, 6);
}

pub fn gear(page: Page, cx: f32, cy: f32) void {
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.arc(0, 0, 25, 0, 360, 5);
    p.arc(0, 0, 11, 0, 360, 4);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) * pi / 4;
        p.line(@cos(a) * 26, @sin(a) * 26, @cos(a) * 36, @sin(a) * 36, 9);
    }
}

/// Width of the charge bar. Kept in u32: @min with a literal narrows the type.
pub fn batteryFill(inner: u32, percent: u32) u32 {
    const level: u32 = @min(percent, 100);
    return inner * level / 100;
}

pub const battery_width = 85; // Including the terminal

/// `cy` is the vertical centre.
pub fn battery(page: Page, x: f32, cy: f32, percent: u32) void {
    const w = 78;
    const h = 36;
    const y = cy - h / 2;
    page.stroke(x, y, x + w, y, 3);
    page.stroke(x, y + h, x + w, y + h, 3);
    page.stroke(x, y, x, y + h, 3);
    page.stroke(x + w, y, x + w, y + h, 3);
    page.stroke(x + w + 7, y + 11, x + w + 7, y + h - 11, 6);
    const fill = batteryFill(w - 10, percent);
    if (fill > 0) page.fillRect(@intFromFloat(x + 5), @intFromFloat(y + 5), fill, h - 10, 0x00);
}

pub fn back(page: Page, cx: f32, cy: f32) void {
    page.stroke(cx - 18, cy, cx + 18, cy, 4);
    page.stroke(cx - 18, cy, cx - 4, cy - 14, 4);
    page.stroke(cx - 18, cy, cx - 4, cy + 14, 4);
}

pub fn lines(page: Page, cx: f32, cy: f32) void {
    var i: f32 = -1;
    while (i <= 1) : (i += 1) {
        page.stroke(cx - 22, cy + i * 14, cx - 16, cy + i * 14, 4);
        page.stroke(cx - 6, cy + i * 14, cx + 24, cy + i * 14, 4);
    }
}

/// The toolbar's bookmark, filled when the page has one.
/// A filled ribbon with a notch at the bottom, smooth on every edge like the outline.
pub fn bookmarkFilled(page: Page, cx: f32, cy: f32) void {
    const left = cx - 17;
    const top = cy - 24;
    const shape = [_][2]f32{
        .{ left, top },      .{ left + 34, top }, .{ left + 34, top + 48 },
        .{ cx, top + 33 },   .{ left, top + 48 },
    };
    page.fillPoly(&shape);
}

/// The ribbon in a bookmarked page's top-right corner.
pub fn ribbon(page: Page, screen_width: u32) void {
    const right: f32 = @floatFromInt(screen_width - 60);
    bookmarkFilled(page, right, 24);
}

pub fn bookmark(page: Page, cx: f32, cy: f32) void {
    page.stroke(cx - 15, cy - 22, cx + 15, cy - 22, 4);
    page.stroke(cx - 15, cy - 22, cx - 15, cy + 22, 4);
    page.stroke(cx + 15, cy - 22, cx + 15, cy + 22, 4);
    page.stroke(cx - 15, cy + 22, cx, cy + 9, 4);
    page.stroke(cx, cy + 9, cx + 15, cy + 22, 4);
}

pub fn search(page: Page, cx: f32, cy: f32) void {
    searchScaled(page, cx, cy, 1);
}

/// The magnifier at another size, centred on (`cx`, `cy`).
pub fn searchScaled(page: Page, cx: f32, cy: f32, scale: f32) void {
    page.arc(cx - 5 * scale, cy - 5 * scale, 17 * scale, 0, 2 * pi, 4);
    page.stroke(cx + 8 * scale, cy + 8 * scale, cx + 23 * scale, cy + 23 * scale, 5);
}

pub fn dots(page: Page, cx: f32, cy: f32) void {
    const x: i32 = @intFromFloat(cx);
    const y: i32 = @intFromFloat(cy);
    page.disc(x, y - 16, 4, 0, 0x00);
    page.disc(x, y, 4, 0, 0x00);
    page.disc(x, y + 16, 4, 0, 0x00);
}

/// Chapter skip: a bar and a triangle, pointing right when `forward`.
pub fn skip(page: Page, cx: f32, cy: f32, forward: bool) void {
    const dir: f32 = if (forward) 1 else -1;
    const pts = [_][2]f32{ .{ cx - 14 * dir, cy - 18 }, .{ cx + 12 * dir, cy }, .{ cx - 14 * dir, cy + 18 } };
    page.fillPoly(&pts);
    page.stroke(cx + 15 * dir, cy - 18, cx + 15 * dir, cy + 18, 5);
}

pub fn menu(page: Page, x: f32, y: f32) void {
    page.stroke(x, y, x + 44, y, 4);
    page.stroke(x, y + 14, x + 44, y + 14, 4);
    page.stroke(x, y + 28, x + 44, y + 28, 4);
}

/// Wi-Fi, percent and battery on one centre line, right-aligned to `right`.
pub fn statusCluster(page: Page, font: *Font, right: f32, cy: f32, baseline: i32, quick: anytype, large: bool) !void {
    const battery_w: f32 = if (large) battery_width else battery_small_width;
    const gap: f32 = if (large) 20 else 16;
    const battery_x = right - battery_w;
    if (large) battery(page, battery_x, cy, quick.battery) else batterySmall(page, battery_x, cy, quick.battery);
    var label: [8]u8 = undefined;
    const pct = std.fmt.bufPrint(&label, "{d}%", .{quick.battery}) catch "";
    const pct_x = battery_x - gap - try font.measure(pct);
    try font.draw(page, pct_x, baseline, pct);
    var left = pct_x;
    if (quick.plugged) {
        const size: f32 = if (large) 30 else 24;
        left -= size * 0.5 + 6;
        bolt(page, left, cy, size);
        left -= size * 0.5;
    }
    if (quick.wifi_on) wifi(page, left - gap - 22, cy, 0.42, quick.wifi_bars);
}

/// A lightning bolt `size` tall, centred on (`cx`, `cy`): plugged in.
pub fn bolt(page: Page, cx: f32, cy: f32, size: f32) void {
    const s = size / 26;
    const shape = [_][2]f32{ .{ 3, -13 }, .{ -7, 2 }, .{ -1, 2 }, .{ -3, 13 }, .{ 7, -2 }, .{ 1, -2 } };
    var points: [shape.len][2]f32 = undefined;
    for (shape, &points) |p, *q| q.* = .{ cx + p[0] * s, cy + p[1] * s };
    page.fillPoly(&points);
}

/// Badge for a book that isn't on the device.
pub fn cloud(page: Page, cx: f32, cy: f32) void {
    const x: i32 = @intFromFloat(cx);
    const y: i32 = @intFromFloat(cy);
    page.disc(x, y, 30, 0, 0xff);
    page.disc(x, y, 27, 0, 0x00);
    page.disc(x - 11, y + 3, 9, 0, 0xff);
    page.disc(x + 11, y + 3, 9, 0, 0xff);
    page.disc(x + 1, y - 4, 12, 0, 0xff);
    page.fillRect(@intCast(x - 11), @intCast(y + 3), 22, 9, 0xff);
}

/// Highlight: a marker pen at a slant over the gray stroke it leaves.
pub fn highlighter(page: Page, cx: f32, cy: f32) void {
    page.pill(cx - 16, cx + 16, cy + 16, 6, style.rule); // The stroke
    // The pen: a slanted body with a chisel tip touching the stroke
    const body = [_][2]f32{
        .{ cx - 8, cy + 6 }, .{ cx + 10, cy - 14 }, .{ cx + 18, cy - 7 }, .{ cx, cy + 13 },
    };
    page.fillPoly(&body);
    const tip = [_][2]f32{ .{ cx - 8, cy + 6 }, .{ cx, cy + 13 }, .{ cx - 11, cy + 14 } };
    page.fillPoly(&tip);
}

/// Draws `glyph` in white, centred on (`cx`, `cy`), over a control that's filled
/// black because it's on. It's drawn black on a white `w` by `h` tile, then stamped
/// in white, so its smooth edges stay smooth. Flipping pixels in place can't do that
/// once the flipped area cuts through another shape's soft edge, as a disc's does.
/// `glyph` has `draw(self, tile: Page, cx: f32, cy: f32) !void`.
pub fn drawWhite(page: Page, comptime w: u32, comptime h: u32, cx: i32, cy: i32, glyph: anytype) !void {
    var buf: [w * h]u8 = @splat(0xff);
    const tile = Page{ .buf = &buf, .width = w, .height = h, .stride = w };
    try glyph.draw(tile, @as(f32, w) / 2, @as(f32, h) / 2);
    page.stampWhite(tile, cx, cy);
}

/// A magnifier, for drawWhite.
pub const Magnifier = struct {
    scale: f32,
    pub fn draw(m: Magnifier, page: Page, cx: f32, cy: f32) !void {
        searchScaled(page, cx, cy, m.scale);
    }
};

test "a white glyph lands centred, and only where it was drawn" {
    var under: [40 * 40]u8 = @splat(0x00);
    const page = Page{ .buf = &under, .width = 40, .height = 40, .stride = 40 };
    const Dot = struct {
        pub fn draw(_: @This(), t: Page, cx: f32, cy: f32) !void {
            t.fillRect(@intFromFloat(cx - 1), @intFromFloat(cy - 1), 2, 2, 0x00);
        }
    };
    try drawWhite(page, 10, 10, 20, 20, Dot{});
    try std.testing.expectEqual(@as(u8, 0xff), under[19 * 40 + 19]);
    try std.testing.expectEqual(@as(u8, 0xff), under[20 * 40 + 20]);
    try std.testing.expectEqual(@as(u8, 0x00), under[16 * 40 + 16]); // Rest of the tile
}

/// Stats: three rounded bars of different heights on a baseline.
pub fn barChart(page: Page, cx: f32, cy: f32) void {
    const heights = [_]f32{ 14, 30, 22 };
    for (heights, 0..) |h, i| {
        const x = cx - 14 + @as(f32, @floatFromInt(i)) * 14;
        page.pill(x, x, cy + 14 - h + 3, 3, 0x00);
        page.fillRect(@intFromFloat(x - 3), @intFromFloat(cy + 14 - h + 3), 6, @intFromFloat(h - 3), 0x00);
    }
    page.fillRect(@intFromFloat(cx - 21), @intFromFloat(cy + 14), 42, 3, 0x00);
}

/// Filter: a funnel.
pub fn funnel(page: Page, cx: f32, cy: f32) void {
    const pts = [_][2]f32{
        .{ cx - 15, cy - 12 }, .{ cx + 15, cy - 12 }, .{ cx + 4, cy + 1 },
        .{ cx + 4, cy + 13 },  .{ cx - 4, cy + 9 },   .{ cx - 4, cy + 1 },
    };
    page.fillPoly(&pts);
}

/// Sort: an arrow up beside an arrow down.
pub fn sortArrows(page: Page, cx: f32, cy: f32) void {
    const l = cx - 7;
    const r = cx + 7;
    page.stroke(l, cy + 13, l, cy - 12, 3);
    page.stroke(l, cy - 13, l - 6, cy - 6, 3);
    page.stroke(l, cy - 13, l + 6, cy - 6, 3);
    page.stroke(r, cy - 13, r, cy + 12, 3);
    page.stroke(r, cy + 13, r - 6, cy + 6, 3);
    page.stroke(r, cy + 13, r + 6, cy + 6, 3);
}

pub fn check(page: Page, cx: f32, cy: f32) void {
    page.disc(@intFromFloat(cx), @intFromFloat(cy), 25, 0, 0xff);
    page.disc(@intFromFloat(cx), @intFromFloat(cy), 22, 0, 0x00);
    page.fillPolyWhiteCheck(cx, cy);
}

pub const battery_small_width = 59; // Including the terminal

/// `cy` is the vertical centre.
pub fn batterySmall(page: Page, x: f32, cy: f32, percent: u32) void {
    const w = 54;
    const h = 26;
    const y = cy - h / 2;
    page.stroke(x, y, x + w, y, 2);
    page.stroke(x, y + h, x + w, y + h, 2);
    page.stroke(x, y, x, y + h, 2);
    page.stroke(x + w, y, x + w, y + h, 2);
    page.stroke(x + w + 5, y + 8, x + w + 5, y + h - 8, 4);
    const fill = batteryFill(w - 8, percent);
    if (fill > 0) page.fillRect(@intFromFloat(x + 4), @intFromFloat(y + 4), fill, h - 8, 0x00);
}

pub fn chevron(page: Page, cx: f32, cy: f32) void {
    page.stroke(cx - 42, cy + 13, cx, cy - 7, 4);
    page.stroke(cx, cy - 7, cx + 42, cy + 13, 4);
}

test "battery bar fills with charge" {
    try std.testing.expectEqual(@as(u32, 68), batteryFill(68, 100));
    try std.testing.expectEqual(@as(u32, 34), batteryFill(68, 50));
    try std.testing.expectEqual(@as(u32, 0), batteryFill(68, 0));
    try std.testing.expectEqual(@as(u32, 68), batteryFill(68, 250));
}
