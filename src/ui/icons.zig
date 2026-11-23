//! Panel icons, drawn as smooth vector shapes.
//!
//! An icon's outline is given in its own units around its middle, as a font's glyphs
//! are: those numbers are its shape. A unit is a 300th of an inch, the grid the icons
//! were drawn on, and the pen turns units into the screen's pixels by its density, so
//! an icon is the same size on every Kindle. What every icon shares is named here: the
//! weights its lines are drawn at, so icons drawn side by side match.
//!
//! Every icon asserts the point it's drawn around is on the page it's drawn on: one
//! centred off the page is a mistake in a screen's layout, and would draw nothing,
//! or half of itself, without a word.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../text/line.zig").of;
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const quick_model = @import("../model/quick.zig");

/// The icons' grid: units to the inch.
const grid_dpi = 300;
/// One unit, in the screen's pixels.
const unit: f32 = @as(f32, @floatFromInt(style.screen.dpi)) / grid_dpi;

/// `units` of the icons' grid in the screen's whole pixels, for a size another file
/// lays out round an icon.
fn px(comptime units: comptime_float) comptime_int {
    return @intFromFloat(@round(units * unit));
}

/// Draws in an icon's units round its middle (`cx`, `cy`), in the screen's pixels.
const Pen = struct {
    page: Page,
    cx: f32,
    cy: f32,
    scale: f32 = unit,

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

    fn size(p: Pen, v: f32) f32 {
        assert(v >= 0);
        return v * p.scale;
    }

    fn disc(p: Pen, ox: f32, oy: f32, radius: f32, value: u8) void {
        assert(radius > 0);
        const r: i32 = @intFromFloat(@max(@round(p.size(radius)), 1));
        p.page.disc(@intFromFloat(p.x(ox)), @intFromFloat(p.y(oy)), r, 0, value);
    }

    fn pill(p: Pen, x0: f32, x1: f32, oy: f32, radius: f32, value: u8) void {
        assert(x0 <= x1);
        p.page.pill(p.x(x0), p.x(x1), p.y(oy), p.size(radius), value);
    }

    fn rect(p: Pen, ox: f32, oy: f32, w: f32, h: f32, value: u8) void {
        assert(w > 0);
        assert(h > 0);
        const w_px: u32 = @intFromFloat(@max(@round(p.size(w)), 1));
        const h_px: u32 = @intFromFloat(@max(@round(p.size(h)), 1));
        const left: u32 = @intFromFloat(@round(p.x(ox)));
        const top: u32 = @intFromFloat(@round(p.y(oy)));
        p.page.fill_rect(left, top, w_px, h_px, value);
    }

    /// A filled shape through `shape`'s points, in units.
    fn poly(p: Pen, comptime n: u32, shape: [n][2]f32) void {
        var points: [n][2]f32 = undefined;
        for (shape, &points) |o, *q| q.* = .{ p.x(o[0]), p.y(o[1]) };
        p.page.fill_poly(&points);
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

/// A ring `radius` pixels round (`cx`, `cy`), its line an icon's fine weight.
pub fn ring(page: Page, cx: f32, cy: f32, radius: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(radius > 0);
    page.arc(cx, cy, radius, 0, 2 * pi, stroke.fine * unit);
}

pub fn airplane(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const outline = [_][2]f32{
        .{ 0, -36 }, .{ 4, -31 }, .{ 5, -11 },  .{ 33, 7 },  .{ 33, 14 },  .{ 5, 4 },
        .{ 4, 21 },  .{ 13, 29 }, .{ 13, 34 },  .{ 0, 29 },  .{ -13, 34 }, .{ -13, 29 },
        .{ -4, 21 }, .{ -5, 4 },  .{ -33, 14 }, .{ -33, 7 }, .{ -5, -11 }, .{ -4, -31 },
    };
    // Drawn nose up, then turned to point up and right
    var turned: [outline.len][2]f32 = undefined;
    const c = @cos(pi / 4);
    for (outline, &turned) |o, *r| r.* = .{ (o[0] - o[1]) * c, (o[0] + o[1]) * c };
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.poly(outline.len, turned);
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

/// The Wi-Fi fan: `bars` of its three arcs, none for no signal, or all three for an
/// icon that shows no signal (null: the panel's tile).
pub fn wifi(page: Page, cx: f32, cy: f32, scale: f32, bars: ?u32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(scale > 0);
    // Drawn around its own middle, so it can share a line with text.
    const p = Pen{ .page = page, .cx = cx, .cy = cy + 2 * scale * unit, .scale = scale * unit };
    p.disc(0, 24, 6, 0x00);
    const radii = [_]f32{ 19, 34, 49 };
    if (bars) |b| assert(b <= radii.len);
    for (radii, 0..) |r, i| {
        if (bars) |b| if (i >= b) continue;
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
/// A whole battery, in percent: what the Kindle reports (outside data) is held to it.
const battery_full = 100;

pub fn battery_fill(inner: u32, percent: u32) u32 {
    assert(inner > 0);
    // The percent is the Kindle's to report, so anything over a full charge is clamped.
    const level: u32 = @min(percent, battery_full);
    const fill = inner * level / battery_full;
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
        return (b.width + b.terminal_gap) * unit;
    }
};

/// The quick panel's battery, and the status strips' smaller one.
/// Sizes in the icons' units; `span` is in pixels, as the status cluster lays it out.
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
        assert(b.width + b.terminal_gap > b.width);
    }
}

/// A battery at `size`, its left at `x` and its middle at `cy`, charged to `percent`.
pub fn battery(page: Page, size: Battery, x: f32, cy: f32, percent: u32) void {
    assert(inside(x, page.width));
    assert(inside(cy, page.height));
    // Drawn from its left, along its middle
    const p = Pen{ .page = page, .cx = x, .cy = cy };
    const w = size.width;
    const h = size.height;
    const y = -h / 2;
    p.line(0, y, w, y, size.line);
    p.line(0, y + h, w, y + h, size.line);
    p.line(0, y, 0, y + h, size.line);
    p.line(w, y, w, y + h, size.line);
    const terminal_x = w + size.terminal_gap;
    const inset = size.terminal_inset;
    p.line(terminal_x, y + inset, terminal_x, y + h - inset, size.terminal_line);
    const pad: f32 = @floatFromInt(size.fill_pad);
    const inner: u32 = @intFromFloat(@round(p.size(w - 2 * pad)));
    const fill = battery_fill(inner, percent);
    if (fill > 0) {
        const fill_units = @as(f32, @floatFromInt(fill)) / p.scale;
        p.rect(pad, y + pad, fill_units, h - 2 * pad, 0x00);
    }
}

pub fn back(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.line(-18, 0, 18, 0, stroke.regular);
    p.line(-18, 0, -4, -14, stroke.regular);
    p.line(-18, 0, -4, 14, stroke.regular);
}

pub fn lines(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    for ([_]f32{ -14, 0, 14 }) |row| {
        p.line(-22, row, -16, row, stroke.regular);
        p.line(-6, row, 24, row, stroke.regular);
    }
}

/// The toolbar's bookmark, filled when the page has one.
/// A filled ribbon with a notch at the bottom, smooth on every edge like the outline.
pub fn bookmark_filled(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const shape = [_][2]f32{ .{ -17, -24 }, .{ 17, -24 }, .{ 17, 24 }, .{ 0, 9 }, .{ -17, 24 } };
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.poly(shape.len, shape);
}

/// The ribbon in a bookmarked page's top-right corner: its middle this far in from the
/// right edge, and down from the top, so it hangs from the page's edge.
const ribbon_inset = px(60);
const ribbon_middle_y = px(24);

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
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.line(-15, -22, 15, -22, stroke.regular);
    p.line(-15, -22, -15, 22, stroke.regular);
    p.line(15, -22, 15, 22, stroke.regular);
    p.line(-15, 22, 0, 9, stroke.regular);
    p.line(0, 9, 15, 22, stroke.regular);
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
    const p = Pen{ .page = page, .cx = cx, .cy = cy, .scale = scale * unit };
    // Its lines keep their weight at any size: the scale draws the shape
    p.page.arc(p.x(-5), p.y(-5), p.size(17), 0, 2 * pi, stroke.regular * unit);
    p.page.stroke(p.x(8), p.y(8), p.x(23), p.y(23), stroke.heavy * unit);
}

pub fn dots(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    for ([_]f32{ -16, 0, 16 }) |dy| p.disc(0, dy, 4, 0x00);
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
pub const backspace_left = px(30);
pub const backspace_right = px(26);

/// Shift: an arrow pointing up, outlined, with a bar under it while capitals are locked.
pub fn shift(page: Page, cx: f32, cy: f32, locked: bool) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p: Pen = .{ .page = page, .cx = cx, .cy = cy };
    const tip = -20;
    const wing = 18;
    const stem = 8;
    const shoulder = 0;
    const foot = 14;
    p.line(0, tip, -wing, shoulder, stroke.fine);
    p.line(0, tip, wing, shoulder, stroke.fine);
    p.line(-wing, shoulder, -stem, shoulder, stroke.fine);
    p.line(wing, shoulder, stem, shoulder, stroke.fine);
    p.line(-stem, shoulder, -stem, foot, stroke.fine);
    p.line(stem, shoulder, stem, foot, stroke.fine);
    p.line(-stem, foot, stem, foot, stroke.fine);
    const bar = 22;
    if (locked) p.line(-stem, bar, stem, bar, stroke.fine);
}

/// Backspace: a tag pointing left with a cross in it.
pub fn backspace(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p: Pen = .{ .page = page, .cx = cx, .cy = cy };
    const l = -30;
    const r = 26;
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
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    const triangle = [_][2]f32{
        .{ -14 * direction, -18 }, .{ 12 * direction, 0 }, .{ -14 * direction, 18 },
    };
    p.poly(triangle.len, triangle);
    p.line(15 * direction, -18, 15 * direction, 18, stroke.heavy);
}

pub fn menu(page: Page, x: f32, y: f32) void {
    assert(inside(x, page.width));
    assert(inside(y, page.height));
    // Drawn from its top left
    const p = Pen{ .page = page, .cx = x, .cy = y };
    for ([_]f32{ 0, 14, 28 }) |row| p.line(0, row, 44, row, stroke.regular);
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
    const gap = c.gap * unit;
    const battery_x = right - c.battery.span();
    battery(page, c.battery, battery_x, cy, quick.battery);
    // As the bar shows it: the Kindle's level (outside data) held to a whole battery
    const level: u8 = @intCast(@min(quick.battery, battery_full));
    var label: [std.fmt.count("{d}%", .{std.math.maxInt(u8)})]u8 = undefined;
    const percent = line_of(&label, "{d}%", .{level});
    const percent_x = battery_x - gap - try font.measure(percent);
    try font.draw(page, percent_x, baseline, percent);
    var left = percent_x;
    if (quick.plugged) {
        const bolt_px = c.bolt * unit;
        left -= bolt_px / 2 + bolt_gap * unit;
        bolt(page, left, cy, bolt_px);
        left -= bolt_px / 2;
    }
    const wifi_x = left - gap - wifi_half_width * unit;
    if (quick.wifi_shown()) |bars| wifi(page, wifi_x, cy, wifi_scale, bars);
}

/// A lightning bolt `size` tall, centred on (`cx`, `cy`): plugged in.
pub fn bolt(page: Page, cx: f32, cy: f32, size: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    assert(size > 0);
    // Drawn 26 units tall, scaled to `size` pixels
    const shape = [_][2]f32{
        .{ 3, -13 }, .{ -7, 2 }, .{ -1, 2 }, .{ -3, 13 }, .{ 7, -2 }, .{ 1, -2 },
    };
    const p = Pen{ .page = page, .cx = cx, .cy = cy, .scale = size / 26 };
    p.poly(shape.len, shape);
}

/// Badge for a book that isn't on the device.
pub fn cloud(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    // Ringed as the tick's badge is, a little larger for the cloud cut out of it
    p.disc(0, 0, cloud_badge_radius + badge_ring, 0xff);
    p.disc(0, 0, cloud_badge_radius, 0x00);
    p.disc(-11, 3, 9, 0xff);
    p.disc(11, 3, 9, 0xff);
    p.disc(1, -4, 12, 0xff);
    p.rect(-11, 3, 22, 9, 0xff);
}

/// Highlight: a marker pen at a slant over the gray stroke it leaves.
pub fn highlighter(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.pill(-16, 16, 16, 6, style.rule); // The stroke
    // The pen: a slanted body with a chisel tip touching the stroke
    const body = [_][2]f32{ .{ -8, 6 }, .{ 10, -14 }, .{ 18, -7 }, .{ 0, 13 } };
    p.poly(body.len, body);
    const tip = [_][2]f32{ .{ -8, 6 }, .{ 0, 13 }, .{ -11, 14 } };
    p.poly(tip.len, tip);
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
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    const heights = [_]f32{ 14, 30, 22 };
    for (heights, 0..) |h, i| {
        const x = -14 + @as(f32, @floatFromInt(i)) * 14;
        const top = 14 - h + 3;
        p.pill(x, x, top, 3, 0x00);
        p.rect(x - 3, top, 6, h - 3, 0x00);
    }
    p.rect(-21, 14, 42, 3, 0x00);
}

/// Filter: a funnel.
pub fn funnel(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const shape = [_][2]f32{
        .{ -15, -12 }, .{ 15, -12 }, .{ 4, 1 }, .{ 4, 13 }, .{ -4, 9 }, .{ -4, 1 },
    };
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.poly(shape.len, shape);
}

/// Sort: an arrow up beside an arrow down.
pub fn sort_arrows(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    const l = -7;
    const r = 7;
    p.line(l, 13, l, -12, stroke.fine);
    p.line(l, -13, l - 6, -6, stroke.fine);
    p.line(l, -13, l + 6, -6, stroke.fine);
    p.line(r, -13, r, 12, stroke.fine);
    p.line(r, 13, r - 6, 6, stroke.fine);
    p.line(r, 13, r + 6, 6, stroke.fine);
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
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.disc(0, 0, badge_radius + badge_ring, 0xff);
    p.disc(0, 0, badge_radius, 0x00);
    // The tick, white: two strokes that meet, each traced with small discs
    const strokes = [_][4]f32{ .{ -11, 1, -3, 9 }, .{ -3, 9, 12, -8 } };
    comptime assert(strokes[0][2] == strokes[1][0]);
    comptime assert(strokes[0][3] == strokes[1][1]);
    const steps = 50;
    for (strokes) |l| {
        for (0..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / steps;
            p.disc(l[0] + (l[2] - l[0]) * t, l[1] + (l[3] - l[1]) * t, 2, 0xff);
        }
    }
}

pub fn chevron(page: Page, cx: f32, cy: f32) void {
    assert(inside(cx, page.width));
    assert(inside(cy, page.height));
    const p = Pen{ .page = page, .cx = cx, .cy = cy };
    p.line(-42, 13, 0, -7, stroke.regular);
    p.line(0, -7, 42, 13, stroke.regular);
}

test "battery bar fills with charge" {
    try std.testing.expectEqual(@as(u32, 68), battery_fill(68, 100));
    try std.testing.expectEqual(@as(u32, 34), battery_fill(68, 50));
    try std.testing.expectEqual(@as(u32, 0), battery_fill(68, 0));
    try std.testing.expectEqual(@as(u32, 68), battery_fill(68, 250));
}
