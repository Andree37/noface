//! Panel icons, drawn as smooth vector shapes.
//!
//! An icon's outline is given in its own units around its middle, as a font's glyphs
//! are: those numbers are its shape. What every icon shares is named here: the weights
//! its lines are drawn at, so icons drawn side by side match.
//!
//! Every icon asserts the point it's drawn around is on the page it's drawn on: one
//! centred off the page is a mistake in a screen's layout, and would draw nothing,
//! or half of itself, without a word.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const quick_model = @import("../model/quick.zig");

const Pen = struct {
    page: Page,
    cx: f32,
    cy: f32,
    scale: f32 = 1,

    fn x(p: Pen, v: f32) f32 {
        assert(p.scale > 0);
        const at = p.cx + v * p.scale;
        assert(std.math.isFinite(at));
        return at;
    }

    fn y(p: Pen, v: f32) f32 {
        assert(p.scale > 0);
        const at = p.cy + v * p.scale;
        assert(std.math.isFinite(at));
        return at;
    }

    fn line(p: Pen, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {
        assert(width > 0);
        assert(p.scale > 0);
        p.page.stroke(p.x(x0), p.y(y0), p.x(x1), p.y(y1), width * p.scale);
    }

    fn arc(p: Pen, ox: f32, oy: f32, radius: f32, from: f32, to: f32, width: f32) void {
        assert(radius > 0);
        assert(width > 0);
        const from_radians = std.math.degreesToRadians(from);
        const to_radians = std.math.degreesToRadians(to);
        const radius_scaled = radius * p.scale;
        p.page.arc(p.x(ox), p.y(oy), radius_scaled, from_radians, to_radians, width * p.scale);
    }
};

const pi: f32 = std.math.pi;

/// The weights icons' lines are drawn at, in pixels.
const stroke = struct {
    /// Small parts: a battery's outline, the sort arrows, a ring.
    const fine = 3;
    /// Most lines: the toolbar's and the panel's icons.
    const regular = 4;
    /// The magnifier's handle and the chapter skip's bar, which want more weight.
    const heavy = 5;
    /// The smile, Wi-Fi's arcs: lines with room to be bold.
    const bold = 6;
};

comptime {
    assert(stroke.fine < stroke.regular);
    assert(stroke.regular < stroke.heavy);
    assert(stroke.heavy < stroke.bold);
}

/// Whether `at` lies within a page's `size` along one side.
fn inside(at: f32, size: u32) bool {
    assert(size > 0);
    assert(!std.math.isNan(at));
    return at >= 0 and at <= @as(f32, @floatFromInt(size));
}

pub fn ring(page: Page, cx: f32, cy: f32, radius: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(radius > 0);
    page.arc(cx, cy, radius, 0, 2 * pi, stroke.fine);
}

pub fn airplane(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const outline = [_][2]f32{
        .{ 0, -36 }, .{ 4, -31 }, .{ 5, -11 },  .{ 33, 7 },  .{ 33, 14 },  .{ 5, 4 },
        .{ 4, 21 },  .{ 13, 29 }, .{ 13, 34 },  .{ 0, 29 },  .{ -13, 34 }, .{ -13, 29 },
        .{ -4, 21 }, .{ -5, 4 },  .{ -33, 14 }, .{ -33, 7 }, .{ -5, -11 }, .{ -4, -31 },
    };
    var points: [outline.len][2]f32 = undefined;
    const c = @cos(pi / 4);
    for (outline, &points) |o, *r| {
        r.* = .{ cx + (o[0] - o[1]) * c, cy + (o[0] + o[1]) * c };
    }
    page.fill_poly(&points);
}

pub fn bluetooth(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.line(0, -32, 0, 32, stroke.regular);
    p.line(0, -32, 17, -16, stroke.regular);
    p.line(17, -16, -17, 16, stroke.regular);
    p.line(-17, -16, 17, 16, stroke.regular);
    p.line(17, 16, 0, 32, stroke.regular);
}

pub fn wifi(page: Page, cx: f32, cy: f32, scale: f32, bars: u32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(scale > 0);
    // Drawn around its own middle, so it can share a line with text.
    const p = Pen{ .page = page, .cx = cx, .cy = cy + 2 * scale, .scale = scale };
    const dot_radius: i32 = @intFromFloat(@max(6 * scale, 2));
    page.disc(@intFromFloat(p.x(0)), @intFromFloat(p.y(24)), dot_radius, 0, 0x00);
    const radii = [_]f32{ 19, 34, 49 };
    for (radii, 0..) |r, i| {
        if (bars > 0 and i >= bars) continue;
        p.arc(0, 24, r, -135, -45, stroke.bold);
    }
}

pub fn sync(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.arc(0, 0, 28, 200, 330, stroke.regular);
    p.arc(0, 0, 28, 20, 150, stroke.regular);
    arrow_head(p, 28, 330);
    arrow_head(p, 28, 150);
}

/// Barbs at the end of a clockwise arc, pointing along it.
fn arrow_head(p: Pen, radius: f32, degrees: f32) void {
    assert(radius > 0);
    assert(degrees >= 0);
    assert(degrees < 360);
    const a = std.math.degreesToRadians(degrees);
    const tip_x = @cos(a) * radius;
    const tip_y = @sin(a) * radius;
    const behind = a - pi / 2;
    for ([_]f32{ -0.6, 0.6 }) |spread| {
        const b = behind + spread;
        p.line(tip_x, tip_y, tip_x + @cos(b) * 14, tip_y + @sin(b) * 14, stroke.regular);
    }
}

/// A smile arrow, for going back to the Kindle's own home screen.
pub fn smile(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    // The smile: the lower part of a circle, a little flatter than a half.
    p.arc(0, -26, 36, 25, 155, stroke.bold);
    // The arrowhead at its right end, pointing up and out along the curve.
    const tip_x = @cos(std.math.degreesToRadians(25.0)) * 36 + 4;
    const tip_y = -26 + @sin(std.math.degreesToRadians(25.0)) * 36 - 4;
    p.line(tip_x, tip_y, tip_x - 15, tip_y - 1, stroke.bold);
    p.line(tip_x, tip_y, tip_x - 3, tip_y + 14, stroke.bold);
}

/// Width of the charge bar. Kept in u32: @min with a literal narrows the type.
pub fn battery_fill(inner: u32, percent: u32) u32 {
    assert(inner > 0);
    // The percent is the Kindle's to report, so anything over a full charge is clamped.
    const level: u32 = @min(percent, 100);
    const fill = inner * level / 100;
    assert(fill <= inner);
    return fill;
}

/// A battery's outline at one size: its body, the terminal at its right, and the
/// charge bar inside, `fill_pad` in from the outline all round.
pub const Battery = struct {
    width: f32,
    height: f32,
    line: f32,
    terminal_gap: f32, // From the body's right side to the terminal's middle
    terminal_inset: f32, // The terminal's ends in from the body's top and bottom
    terminal_line: f32,
    fill_pad: u32,

    /// Its width as the status cluster lays it out: from its left to its terminal's
    /// middle.
    pub fn span(b: Battery) f32 {
        return b.width + b.terminal_gap;
    }
};

/// The quick panel's battery, and the status strips' smaller one.
pub const battery_large: Battery = .{
    .width = 78,
    .height = 36,
    .line = stroke.fine,
    .terminal_gap = 7,
    .terminal_inset = 11,
    .terminal_line = stroke.bold,
    .fill_pad = 5,
};
pub const battery_small: Battery = .{
    .width = 54,
    .height = 26,
    .line = 2,
    .terminal_gap = 5,
    .terminal_inset = 8,
    .terminal_line = stroke.regular,
    .fill_pad = 4,
};

comptime {
    // The charge bar sits inside the outline, and the terminal on the body's side
    for ([_]Battery{ battery_large, battery_small }) |b| {
        assert(2 * b.fill_pad < b.height);
        assert(2 * b.terminal_inset < b.height);
        assert(b.span() > b.width);
    }
}

/// A battery at `size`, its left at `x` and its middle at `cy`, charged to `percent`.
pub fn battery(page: Page, size: Battery, x: f32, cy: f32, percent: u32) void {
    assert(inside(x, page.width));
    assert(inside(cy, page.height));
    const w = size.width;
    const h = size.height;
    const y = cy - h / 2;
    page.stroke(x, y, x + w, y, size.line);
    page.stroke(x, y + h, x + w, y + h, size.line);
    page.stroke(x, y, x, y + h, size.line);
    page.stroke(x + w, y, x + w, y + h, size.line);
    const terminal_x = x + w + size.terminal_gap;
    const inset = size.terminal_inset;
    page.stroke(terminal_x, y + inset, terminal_x, y + h - inset, size.terminal_line);
    const pad: f32 = @floatFromInt(size.fill_pad);
    const inner: u32 = @intFromFloat(w - 2 * pad);
    const fill = battery_fill(inner, percent);
    const fill_height: u32 = @intFromFloat(h - 2 * pad);
    if (fill > 0) {
        page.fill_rect(@intFromFloat(x + pad), @intFromFloat(y + pad), fill, fill_height, 0x00);
    }
}

pub fn back(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    page.stroke(cx - 18, cy, cx + 18, cy, stroke.regular);
    page.stroke(cx - 18, cy, cx - 4, cy - 14, stroke.regular);
    page.stroke(cx - 18, cy, cx - 4, cy + 14, stroke.regular);
}

pub fn lines(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    var i: f32 = -1;
    while (i <= 1) : (i += 1) {
        page.stroke(cx - 22, cy + i * 14, cx - 16, cy + i * 14, stroke.regular);
        page.stroke(cx - 6, cy + i * 14, cx + 24, cy + i * 14, stroke.regular);
    }
}

/// The toolbar's bookmark, filled when the page has one.
/// A filled ribbon with a notch at the bottom, smooth on every edge like the outline.
pub fn bookmark_filled(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const left = cx - 17;
    const top = cy - 24;
    const shape = [_][2]f32{
        .{ left, top },    .{ left + 34, top }, .{ left + 34, top + 48 },
        .{ cx, top + 33 }, .{ left, top + 48 },
    };
    page.fill_poly(&shape);
}

/// The ribbon in a bookmarked page's top-right corner: its middle this far in from the
/// right edge, and down from the top, so it hangs from the page's edge.
const ribbon_inset = 60;
const ribbon_middle_y = 24;

/// The ribbon in a bookmarked page's top-right corner.
pub fn ribbon(page: Page, screen_width: u32) void {
    assert(screen_width > ribbon_inset);
    assert(screen_width <= page.width);
    const middle_x: f32 = @floatFromInt(screen_width - ribbon_inset);
    bookmark_filled(page, middle_x, ribbon_middle_y);
}

pub fn bookmark(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    page.stroke(cx - 15, cy - 22, cx + 15, cy - 22, stroke.regular);
    page.stroke(cx - 15, cy - 22, cx - 15, cy + 22, stroke.regular);
    page.stroke(cx + 15, cy - 22, cx + 15, cy + 22, stroke.regular);
    page.stroke(cx - 15, cy + 22, cx, cy + 9, stroke.regular);
    page.stroke(cx, cy + 9, cx + 15, cy + 22, stroke.regular);
}

pub fn search(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    search_scaled(page, cx, cy, 1);
}

/// The magnifier at another size, centred on (`cx`, `cy`).
pub fn search_scaled(page: Page, cx: f32, cy: f32, scale: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(scale > 0);
    page.arc(cx - 5 * scale, cy - 5 * scale, 17 * scale, 0, 2 * pi, stroke.regular);
    page.stroke(cx + 8 * scale, cy + 8 * scale, cx + 23 * scale, cy + 23 * scale, stroke.heavy);
}

pub fn dots(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const x: i32 = @intFromFloat(cx);
    const y: i32 = @intFromFloat(cy);
    page.disc(x, y - 16, 4, 0, 0x00);
    page.disc(x, y, 4, 0, 0x00);
    page.disc(x, y + 16, 4, 0, 0x00);
}

/// A pager's arrow: a chevron pointing right when `forward`, its tip at its middle.
pub fn pager_arrow(page: Page, cx: f32, cy: f32, forward: bool) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p: Pen = .{ .page = page, .cx = cx, .cy = cy };
    const direction: f32 = if (forward) 1 else -1;
    p.line(-9 * direction, -18, 9 * direction, 0, stroke.regular);
    p.line(9 * direction, 0, -9 * direction, 18, stroke.regular);
}

/// How far the backspace tag reaches either side of its middle, for its key to hold it.
pub const backspace_left = 30;
pub const backspace_right = 26;

/// Backspace: a tag pointing left with a cross in it.
pub fn backspace(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p: Pen = .{ .page = page, .cx = cx, .cy = cy };
    const l = -backspace_left;
    const r = backspace_right;
    p.line(l, 0, l + 16, -18, stroke.fine);
    p.line(l, 0, l + 16, 18, stroke.fine);
    p.line(l + 16, -18, r, -18, stroke.fine);
    p.line(l + 16, 18, r, 18, stroke.fine);
    p.line(r, -18, r, 18, stroke.fine);
    p.line(-4, -8, 12, 8, stroke.fine);
    p.line(-4, 8, 12, -8, stroke.fine);
}

/// Chapter skip: a bar and a triangle, pointing right when `forward`.
pub fn skip(page: Page, cx: f32, cy: f32, forward: bool) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const direction: f32 = if (forward) 1 else -1;
    const points = [_][2]f32{
        .{ cx - 14 * direction, cy - 18 },
        .{ cx + 12 * direction, cy },
        .{ cx - 14 * direction, cy + 18 },
    };
    page.fill_poly(&points);
    page.stroke(cx + 15 * direction, cy - 18, cx + 15 * direction, cy + 18, stroke.heavy);
}

pub fn menu(page: Page, x: f32, y: f32) void {
    assert(inside(x, page.width));
    assert(inside(y, page.height));
    page.stroke(x, y, x + 44, y, stroke.regular);
    page.stroke(x, y + 14, x + 44, y + 14, stroke.regular);
    page.stroke(x, y + 28, x + 44, y + 28, stroke.regular);
}

/// The status cluster's spacing, large on the quick panel and small on the status
/// strips: the gap between its parts, and the bolt's height while charging.
const Cluster = struct { battery: Battery, gap: f32, bolt: f32 };
const cluster_large: Cluster = .{ .battery = battery_large, .gap = 20, .bolt = 30 };
const cluster_small: Cluster = .{ .battery = battery_small, .gap = 16, .bolt = 24 };
/// The bolt's gap from the percent, Wi-Fi's size against its own drawing, and its
/// middle's distance left of where its gap ends.
const bolt_gap = 6;
const wifi_scale = 0.42;
const wifi_half_width = 22;

/// Wi-Fi, percent and battery on one centre line, right-aligned to `right`.
pub fn status_cluster(
    page: Page,
    font: *Font,
    right: f32,
    cy: f32,
    baseline: i32,
    quick: *const quick_model.Quick,
    large: bool,
) !void {
    assert(inside(right, page.width));
    assert(inside(cy, page.height));
    const c = if (large) cluster_large else cluster_small;
    const gap = c.gap;
    const battery_x = right - c.battery.span();
    battery(page, c.battery, battery_x, cy, quick.battery);
    var label: [8]u8 = undefined;
    const percent = std.fmt.bufPrint(&label, "{d}%", .{quick.battery}) catch "";
    const percent_x = battery_x - gap - try font.measure(percent);
    try font.draw(page, percent_x, baseline, percent);
    var left = percent_x;
    if (quick.plugged) {
        left -= c.bolt / 2 + bolt_gap;
        bolt(page, left, cy, c.bolt);
        left -= c.bolt / 2;
    }
    if (quick.wifi_shown()) |bars| wifi(page, left - gap - wifi_half_width, cy, wifi_scale, bars);
}

/// A lightning bolt `size` tall, centred on (`cx`, `cy`): plugged in.
pub fn bolt(page: Page, cx: f32, cy: f32, size: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(size > 0);
    const s = size / 26;
    const shape = [_][2]f32{
        .{ 3, -13 }, .{ -7, 2 }, .{ -1, 2 }, .{ -3, 13 }, .{ 7, -2 }, .{ 1, -2 },
    };
    var points: [shape.len][2]f32 = undefined;
    for (shape, &points) |p, *q| q.* = .{ cx + p[0] * s, cy + p[1] * s };
    page.fill_poly(&points);
}

/// Badge for a book that isn't on the device.
pub fn cloud(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const x: i32 = @intFromFloat(cx);
    const y: i32 = @intFromFloat(cy);
    // Ringed as the tick's badge is, a little larger for the cloud cut out of it
    page.disc(x, y, cloud_badge_radius + badge_ring, 0, 0xff);
    page.disc(x, y, cloud_badge_radius, 0, 0x00);
    page.disc(x - 11, y + 3, 9, 0, 0xff);
    page.disc(x + 11, y + 3, 9, 0, 0xff);
    page.disc(x + 1, y - 4, 12, 0, 0xff);
    page.fill_rect(@intCast(x - 11), @intCast(y + 3), 22, 9, 0xff);
}

/// Highlight: a marker pen at a slant over the gray stroke it leaves.
pub fn highlighter(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    page.pill(cx - 16, cx + 16, cy + 16, 6, style.rule); // The stroke
    // The pen: a slanted body with a chisel tip touching the stroke
    const body = [_][2]f32{
        .{ cx - 8, cy + 6 }, .{ cx + 10, cy - 14 }, .{ cx + 18, cy - 7 }, .{ cx, cy + 13 },
    };
    page.fill_poly(&body);
    const tip = [_][2]f32{ .{ cx - 8, cy + 6 }, .{ cx, cy + 13 }, .{ cx - 11, cy + 14 } };
    page.fill_poly(&tip);
}

/// Draws `glyph` in white, centred on (`cx`, `cy`), over a control that's filled
/// black because it's on. It's drawn black on a white `w` by `h` tile, then stamped
/// in white, so its smooth edges stay smooth. Flipping pixels in place can't do that
/// once the flipped area cuts through another shape's soft edge, as a disc's does.
/// `glyph` has `draw(self, tile: Page, cx: f32, cy: f32) !void`.
pub fn draw_white(
    page: Page,
    comptime w: u32,
    comptime h: u32,
    cx: i32,
    cy: i32,
    glyph: anytype,
) !void {
    comptime assert(w > 0);
    comptime assert(h > 0);
    comptime assert(w * h <= 64 * 1024); // The tile is on the stack: a glyph's size
    var buffer: [w * h]u8 = @splat(0xff);
    const tile = Page{ .buf = &buffer, .width = w, .height = h, .stride = w };
    try glyph.draw(tile, @as(f32, w) / 2, @as(f32, h) / 2);
    page.stamp_white(tile, cx, cy);
}

/// A magnifier, for draw_white.
pub const Magnifier = struct {
    scale: f32,
    pub fn draw(m: Magnifier, page: Page, cx: f32, cy: f32) !void {
        assert(m.scale > 0);
        assert(inside(cx, page.width));
        search_scaled(page, cx, cy, m.scale);
    }
};

test "a white glyph lands centred, and only where it was drawn" {
    var under: [40 * 40]u8 = @splat(0x00);
    const page = Page{ .buf = &under, .width = 40, .height = 40, .stride = 40 };
    const Dot = struct {
        pub fn draw(_: @This(), t: Page, cx: f32, cy: f32) !void {
            t.fill_rect(@intFromFloat(cx - 1), @intFromFloat(cy - 1), 2, 2, 0x00);
        }
    };
    try draw_white(page, 10, 10, 20, 20, Dot{});
    try std.testing.expectEqual(@as(u8, 0xff), under[19 * 40 + 19]);
    try std.testing.expectEqual(@as(u8, 0xff), under[20 * 40 + 20]);
    try std.testing.expectEqual(@as(u8, 0x00), under[16 * 40 + 16]); // Rest of the tile
}

/// Stats: three rounded bars of different heights on a baseline.
pub fn bar_chart(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const heights = [_]f32{ 14, 30, 22 };
    for (heights, 0..) |h, i| {
        const x = cx - 14 + @as(f32, @floatFromInt(i)) * 14;
        const top = cy + 14 - h + 3;
        page.pill(x, x, top, 3, 0x00);
        page.fill_rect(@intFromFloat(x - 3), @intFromFloat(top), 6, @intFromFloat(h - 3), 0x00);
    }
    page.fill_rect(@intFromFloat(cx - 21), @intFromFloat(cy + 14), 42, 3, 0x00);
}

/// Filter: a funnel.
pub fn funnel(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const points = [_][2]f32{
        .{ cx - 15, cy - 12 }, .{ cx + 15, cy - 12 }, .{ cx + 4, cy + 1 },
        .{ cx + 4, cy + 13 },  .{ cx - 4, cy + 9 },   .{ cx - 4, cy + 1 },
    };
    page.fill_poly(&points);
}

/// Sort: an arrow up beside an arrow down.
pub fn sort_arrows(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const l = cx - 7;
    const r = cx + 7;
    page.stroke(l, cy + 13, l, cy - 12, stroke.fine);
    page.stroke(l, cy - 13, l - 6, cy - 6, stroke.fine);
    page.stroke(l, cy - 13, l + 6, cy - 6, stroke.fine);
    page.stroke(r, cy - 13, r, cy + 12, stroke.fine);
    page.stroke(r, cy + 13, r - 6, cy + 6, stroke.fine);
    page.stroke(r, cy + 13, r + 6, cy + 6, stroke.fine);
}

/// A badge's disc over a cover, and the white ring round it that keeps it clear of
/// whatever the cover has there.
const badge_radius = 22;
const badge_ring = stroke.fine;
const cloud_badge_radius = 27;

comptime {
    assert(cloud_badge_radius > badge_radius);
}

/// The tick badge on a finished book's cover, or a theme in use.
pub fn check(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    page.disc(@intFromFloat(cx), @intFromFloat(cy), badge_radius + badge_ring, 0, 0xff);
    page.disc(@intFromFloat(cx), @intFromFloat(cy), badge_radius, 0, 0x00);
    page.fill_poly_white_check(cx, cy);
}

pub fn chevron(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    page.stroke(cx - 42, cy + 13, cx, cy - 7, stroke.regular);
    page.stroke(cx, cy - 7, cx + 42, cy + 13, stroke.regular);
}

test "battery bar fills with charge" {
    try std.testing.expectEqual(@as(u32, 68), battery_fill(68, 100));
    try std.testing.expectEqual(@as(u32, 34), battery_fill(68, 50));
    try std.testing.expectEqual(@as(u32, 0), battery_fill(68, 0));
    try std.testing.expectEqual(@as(u32, 68), battery_fill(68, 250));
}
