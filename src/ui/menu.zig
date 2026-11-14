//! Quick panel: drag down from the top of any screen to open it.
const std = @import("std");
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const Fonts = @import("fonts.zig").Fonts;
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const slider = @import("slider.zig");
const quick_model = @import("../model/quick.zig");

pub const height = 960;

const slider_left = 160;
const slider_right = 1110;

pub const Row = struct { label: []const u8, y: u32, max: u32 };
pub const brightness_row = Row{ .label = "Brightness", .y = 680, .max = quick_model.max_brightness };
pub const warmth_row = Row{ .label = "Warmth", .y = 850, .max = quick_model.max_warmth };
const schedule_top = 754;
const schedule_bottom = 794;

pub const Hit = enum { none, close, dimmer, brighter, slider, cooler, warmer, warmth, schedule, airplane, bluetooth, settings, kindle, sync };

const Quick = quick_model.Quick;

/// A round button at the top of the panel: what a tap on it does, its icon, whether
/// it shows as on (filled), and the word under it.
const Tile = struct {
    hit: Hit,
    glyph: *const fn (page: Page, quick: *const Quick, x: f32, y: f32) void,
    on: *const fn (quick: *const Quick) bool = never,
    label: *const fn (quick: *const Quick) []const u8,
};

fn never(_: *const Quick) bool {
    return false;
}

/// The tiles, in order: three on the first row, the rest centred on the second.
/// Adding one is an entry here (and its Hit); the panel places it.
const tiles = [_]Tile{
    .{ .hit = .airplane, .glyph = struct {
        fn g(page: Page, _: *const Quick, x: f32, y: f32) void {
            icons.airplane(page, x, y);
        }
    }.g, .on = struct {
        fn on(q: *const Quick) bool {
            return q.airplane;
        }
    }.on, .label = struct {
        fn l(q: *const Quick) []const u8 {
            return if (q.airplane) "On" else "Off";
        }
    }.l },
    // Networks live in the Kindle's own settings
    .{ .hit = .settings, .glyph = struct {
        fn g(page: Page, q: *const Quick, x: f32, y: f32) void {
            icons.wifi(page, x, y - 4, 0.8, if (q.wifi_on) q.wifi_bars else 0);
        }
    }.g, .on = struct {
        fn on(q: *const Quick) bool {
            return q.wifi_on;
        }
    }.on, .label = struct {
        fn l(q: *const Quick) []const u8 {
            return if (q.wifi_on) "Connected" else "Wi-Fi Off";
        }
    }.l },
    .{ .hit = .bluetooth, .glyph = struct {
        fn g(page: Page, _: *const Quick, x: f32, y: f32) void {
            icons.bluetooth(page, x, y);
        }
    }.g, .on = struct {
        fn on(q: *const Quick) bool {
            return q.bluetooth;
        }
    }.on, .label = struct {
        fn l(q: *const Quick) []const u8 {
            return if (q.bluetooth) "On" else "Off";
        }
    }.l },
    .{ .hit = .sync, .glyph = struct {
        fn g(page: Page, _: *const Quick, x: f32, y: f32) void {
            icons.sync(page, x, y);
        }
    }.g, .label = struct {
        fn l(q: *const Quick) []const u8 {
            return if (q.syncing) "Syncing" else "Sync";
        }
    }.l },
    // Back to the Kindle's own home
    .{ .hit = .kindle, .glyph = struct {
        fn g(page: Page, _: *const Quick, x: f32, y: f32) void {
            icons.smile(page, x, y);
        }
    }.g, .label = struct {
        fn l(_: *const Quick) []const u8 {
            return "Kindle";
        }
    }.l },
};

const icon_radius = 52;
const tiles_per_row = 3;
const tile_step_x = 318; // Between tile centres along a row
const first_row_y = 240;
const row_step_y = 190;

/// The centre of tile `i`: rows of three, each row centred on the screen.
fn tile_center(i: usize) struct { x: i32, y: i32 } {
    const row = i / tiles_per_row;
    const col = i % tiles_per_row;
    const in_row = @min(tiles_per_row, tiles.len - row * tiles_per_row);
    // Doubled to keep the half-step of an even row whole
    const offset2: i32 = 2 * @as(i32, @intCast(col)) - @as(i32, @intCast(in_row - 1));
    return .{ .x = style.screen_width / 2 + @divExact(offset2 * tile_step_x, 2), .y = first_row_y + @as(i32, @intCast(row)) * row_step_y };
}

fn row_slider(row: Row) slider.Slider {
    return .{ .left = slider_left, .right = slider_right, .y = row.y };
}

/// Level for a tap at `x` on a row's slider.
pub fn level_at(row: Row, x: i32) u32 {
    return slider.value_at(row_slider(row), x, row.max);
}

pub fn hit(x: i32, y: i32) Hit {
    if (y >= height) return .close;
    if (y >= warmth_row.y + 60) return .close; // The chevron
    if (y >= schedule_top and y < schedule_bottom and x >= 800) return .schedule;
    if (y >= warmth_row.y - 60) {
        if (x < slider_left) return .cooler;
        if (x > slider_right) return .warmer;
        return .warmth;
    }
    if (y >= brightness_row.y - 60 and y < brightness_row.y + 60) {
        if (x < slider_left) return .dimmer;
        if (x > slider_right) return .brighter;
        return .slider;
    }
    for (0..tiles.len) |i| {
        const c = tile_center(i);
        if (@abs(x - c.x) < 120 and @abs(y - c.y) < 95) return tiles[i].hit;
    }
    return .none;
}

const band_above = 60;
const band_below = 50;

pub fn band_top(row: Row) u32 {
    return row.y - band_above;
}

pub const band_height = band_above + band_below;

/// One slider row at rest, with the knob on its step.
pub fn draw_slider(fonts: Fonts, page: Page, row: Row, value: u32, mono: bool) !void {
    const knob = slider.knob_at(row_slider(row), value, row.max);
    try draw_slider_at(fonts, page, row, value, knob, mono);
}

/// Where the knob sits for `value`.
pub fn knob_at(row: Row, value: u32) u32 {
    return slider.knob_at(row_slider(row), value, row.max);
}

/// Knob position under a finger at `x`, kept on the bar. While dragging, the knob
/// follows the finger rather than jumping from step to step.
pub fn knob_under(x: i32) u32 {
    return @intCast(std.math.clamp(x, slider_left, slider_right));
}

/// The columns a slider frame changes when its knob moves from `from` to `to`:
/// the knob, its level above it, and the bar between them.
pub fn knob_span(from: u32, to: u32) struct { left: u32, width: u32 } {
    const reach = 60; // Half the widest level text, and more than the knob
    const left = @min(from, to) -| reach;
    return .{ .left = left, .width = @max(from, to) + reach - left };
}

/// One slider row with the knob at `knob`. `mono` is pure black and white for the
/// fast waveform used while dragging, which breaks up gray.
pub fn draw_slider_at(fonts: Fonts, page: Page, row: Row, value: u32, knob: u32, mono: bool) !void {
    page.fill_rect(0, band_top(row), page.width, band_height, 0xff);
    const bar = row_slider(row);
    var level: [8]u8 = undefined;
    try draw.centered(fonts.small, page, @floatFromInt(@as(i32, @intCast(knob))), @intCast(row.y - 40), std.fmt.bufPrint(&level, "{d}", .{value}) catch "");
    const y: f32 = @floatFromInt(row.y);
    page.stroke(70, y, 110, y, 4);
    page.stroke(1160, y, 1200, y, 4);
    page.stroke(1180, y - 20, 1180, y + 20, 4);
    slider.draw(page, bar, knob);
    if (mono) page.threshold(band_top(row), band_height);
}

/// Where a toggle and its label sit, to redraw it alone.
pub const Box = struct { left: u32, top: u32, width: u32, height: u32 };

pub fn shortcut_box(choice: Hit) ?Box {
    for (0..tiles.len) |i| {
        if (tiles[i].hit != choice) continue;
        const c = tile_center(i);
        return .{ .left = @intCast(c.x - 130), .top = @intCast(c.y - icon_radius - 8), .width = 260, .height = icon_radius + 8 + 130 };
    }
    return null;
}

/// Redraws one toggle and its label, after a tap changed it.
pub fn draw_shortcut(fonts: Fonts, page: Page, choice: Hit, quick: *const Quick) !void {
    const box = shortcut_box(choice) orelse return;
    page.fill_rect(box.left, box.top, box.width, box.height, 0xff);
    for (0..tiles.len) |i| {
        if (tiles[i].hit == choice) try draw_tile(fonts, page, i, quick);
    }
}

const tile_px = 2 * icon_radius + 8;

/// A tile and the word under it. Off: a ring with the icon in black. On, like the
/// stock panel: a smooth black disc with the icon in white.
fn draw_tile(fonts: Fonts, page: Page, i: usize, quick: *const Quick) !void {
    const t = tiles[i];
    const c = tile_center(i);
    const x: f32 = @floatFromInt(c.x);
    const y: f32 = @floatFromInt(c.y);
    if (!t.on(quick)) {
        icons.ring(page, x, y, icon_radius);
        t.glyph(page, quick, x, y);
    } else {
        page.pill(x, x, y, icon_radius + 1.5, 0x00);
        const Glyph = struct {
            t: Tile,
            quick: *const Quick,
            pub fn draw(g: @This(), p: Page, cx: f32, cy: f32) !void {
                g.t.glyph(p, g.quick, cx, cy);
            }
        };
        const glyph = Glyph{ .t = t, .quick = quick };
        icons.draw_white(page, tile_px, tile_px, c.x, c.y, glyph) catch {};
    }
    try draw.centered(fonts.small, page, x, c.y + 92, t.label(quick));
}

pub fn render(fonts: Fonts, page: Page, quick: *const quick_model.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    page.fill_rect(0, 0, page.width, height, 0xff);
    page.fill_rect(0, height - 4, page.width, 4, 0x00);

    try fonts.title.draw(page, 60, 70, "Kindle Paperwhite");
    try fonts.small.draw(page, 60, 120, quick.clock_text());
    try icons.status_cluster(page, fonts.small, w - 60, 58, 70, quick, true);

    for (0..tiles.len) |i| try draw_tile(fonts, page, i, quick);

    page.fill_rect(40, 560, page.width - 80, 2, style.panel_rule);
    try fonts.small.draw(page, 60, 606, brightness_row.label);
    try draw_slider(fonts, page, brightness_row, quick.brightness, false);
    try fonts.small.draw(page, 60, 776, warmth_row.label);
    const schedule = if (quick.schedule) "Schedule: On" else "Schedule: Off";
    const schedule_w = try fonts.small.measure(schedule);
    try fonts.small.draw(page, w - 96 - schedule_w, 776, schedule);
    page.stroke(w - 80, 752, w - 66, 766, 4);
    page.stroke(w - 66, 766, w - 80, 780, 4);
    try draw_slider(fonts, page, warmth_row, quick.warmth, false);
    icons.chevron(page, w / 2, 934);
}

test "panel maps taps like the stock layout" {
    try std.testing.expectEqual(Hit.airplane, hit(318, 240));
    try std.testing.expectEqual(Hit.settings, hit(636, 240)); // Wi-Fi
    try std.testing.expectEqual(Hit.bluetooth, hit(954, 240));
    try std.testing.expectEqual(Hit.sync, hit(477, 430));
    try std.testing.expectEqual(Hit.kindle, hit(795, 430));
    try std.testing.expectEqual(Hit.none, hit(954, 430));
    try std.testing.expectEqual(Hit.dimmer, hit(90, 680));
    try std.testing.expectEqual(Hit.brighter, hit(1180, 680));
    try std.testing.expectEqual(Hit.slider, hit(600, 680));
    try std.testing.expectEqual(Hit.cooler, hit(90, 850));
    try std.testing.expectEqual(Hit.warmer, hit(1180, 850));
    try std.testing.expectEqual(Hit.warmth, hit(600, 850));
    try std.testing.expectEqual(Hit.schedule, hit(1000, 775));
    try std.testing.expectEqual(Hit.close, hit(636, 930));
    try std.testing.expectEqual(Hit.close, hit(600, 1100));
}

test "knob follows the finger but stays on the bar" {
    try std.testing.expectEqual(@as(u32, 160), knob_under(20));
    try std.testing.expectEqual(@as(u32, 500), knob_under(500));
    try std.testing.expectEqual(@as(u32, 1110), knob_under(1250));
}

test "a knob move redraws only around old and new knob" {
    const span = knob_span(700, 400);
    try std.testing.expectEqual(@as(u32, 340), span.left);
    try std.testing.expectEqual(@as(u32, 420), span.width);
    try std.testing.expectEqual(@as(u32, 0), knob_span(20, 30).left);
}

test "toggle boxes stay apart and on screen" {
    const a = shortcut_box(.airplane).?;
    const b = shortcut_box(.bluetooth).?;
    try std.testing.expect(a.left + a.width <= shortcut_box(.settings).?.left);
    try std.testing.expect(b.left + b.width <= 1272);
    try std.testing.expect(shortcut_box(.close) == null);
}

test "sliders map position to level" {
    try std.testing.expectEqual(@as(u32, 0), level_at(brightness_row, 160));
    try std.testing.expectEqual(@as(u32, 24), level_at(brightness_row, 1110));
    try std.testing.expectEqual(@as(u32, 12), level_at(warmth_row, 635));
    try std.testing.expectEqual(@as(u32, 24), level_at(warmth_row, 1200));
}

test "toggles report their state" {
    const on = quick_model.Quick{ .airplane = true, .wifi_on = true };
    const off = quick_model.Quick{};
    try std.testing.expect(tiles[0].on(&on));
    try std.testing.expect(!tiles[0].on(&off));
    try std.testing.expect(tiles[1].on(&on));
    try std.testing.expect(!tiles[2].on(&on));
}

test "bluetooth toggle shows its state" {
    const on = quick_model.Quick{ .bluetooth = true };
    const off = quick_model.Quick{};
    try std.testing.expect(tiles[2].on(&on));
    try std.testing.expect(!tiles[2].on(&off));
    try std.testing.expectEqualStrings("On", tiles[2].label(&on));
    try std.testing.expectEqualStrings("Off", tiles[2].label(&off));
}

test "tiles sit where they always have" {
    const want = [_][2]i32{ .{ 318, 240 }, .{ 636, 240 }, .{ 954, 240 }, .{ 477, 430 }, .{ 795, 430 } };
    for (want, 0..) |w, i| {
        const c = tile_center(i);
        try std.testing.expectEqual(w[0], c.x);
        try std.testing.expectEqual(w[1], c.y);
    }
}
