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

const Icon = enum { airplane, wifi, bluetooth, sync, kindle };
const Shortcut = struct { icon: Icon, hit: Hit, x: i32, y: i32 };
const icon_radius = 52;
const shortcuts = [_]Shortcut{
    .{ .icon = .airplane, .hit = .airplane, .x = 318, .y = 240 },
    .{ .icon = .wifi, .hit = .settings, .x = 636, .y = 240 }, // Networks live in stock settings
    .{ .icon = .bluetooth, .hit = .bluetooth, .x = 954, .y = 240 },
    .{ .icon = .sync, .hit = .sync, .x = 477, .y = 430 },
    .{ .icon = .kindle, .hit = .kindle, .x = 795, .y = 430 }, // Back to the Kindle's own home
};

fn rowSlider(row: Row) slider.Slider {
    return .{ .left = slider_left, .right = slider_right, .y = row.y };
}

/// Level for a tap at `x` on a row's slider.
pub fn levelAt(row: Row, x: i32) u32 {
    return slider.valueAt(rowSlider(row), x, row.max);
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
    for (shortcuts) |s| {
        if (@abs(x - s.x) < 120 and @abs(y - s.y) < 95) return s.hit;
    }
    return .none;
}

const band_above = 60;
const band_below = 50;

pub fn bandTop(row: Row) u32 {
    return row.y - band_above;
}

pub const band_height = band_above + band_below;

/// One slider row at rest, with the knob on its step.
pub fn drawSlider(fonts: Fonts, page: Page, row: Row, value: u32, mono: bool) !void {
    try drawSliderAt(fonts, page, row, value, slider.knobAt(rowSlider(row), value, row.max), mono);
}

/// Where the knob sits for `value`.
pub fn knobAt(row: Row, value: u32) u32 {
    return slider.knobAt(rowSlider(row), value, row.max);
}

/// Knob position under a finger at `x`, kept on the bar. While dragging, the knob
/// follows the finger rather than jumping from step to step.
pub fn knobUnder(x: i32) u32 {
    return @intCast(std.math.clamp(x, slider_left, slider_right));
}

/// The columns a slider frame changes when its knob moves from `from` to `to`:
/// the knob, its level above it, and the bar between them.
pub fn knobSpan(from: u32, to: u32) struct { left: u32, width: u32 } {
    const reach = 60; // Half the widest level text, and more than the knob
    const left = @min(from, to) -| reach;
    return .{ .left = left, .width = @max(from, to) + reach - left };
}

/// One slider row with the knob at `knob`. `mono` is pure black and white for the
/// fast waveform used while dragging, which breaks up gray.
pub fn drawSliderAt(fonts: Fonts, page: Page, row: Row, value: u32, knob: u32, mono: bool) !void {
    page.fillRect(0, bandTop(row), page.width, band_height, 0xff);
    const bar = rowSlider(row);
    var level: [8]u8 = undefined;
    try draw.centered(fonts.small, page, @floatFromInt(@as(i32, @intCast(knob))), @intCast(row.y - 40), std.fmt.bufPrint(&level, "{d}", .{value}) catch "");
    const y: f32 = @floatFromInt(row.y);
    page.stroke(70, y, 110, y, 4);
    page.stroke(1160, y, 1200, y, 4);
    page.stroke(1180, y - 20, 1180, y + 20, 4);
    slider.draw(page, bar, knob);
    if (mono) page.threshold(bandTop(row), band_height);
}

/// Where a toggle and its label sit, to redraw it alone.
pub const Box = struct { left: u32, top: u32, width: u32, height: u32 };

pub fn shortcutBox(choice: Hit) ?Box {
    for (shortcuts) |s| {
        if (s.hit != choice) continue;
        return .{ .left = @intCast(s.x - 130), .top = @intCast(s.y - icon_radius - 8), .width = 260, .height = icon_radius + 8 + 130 };
    }
    return null;
}

/// Redraws one toggle and its label, after a tap changed it.
pub fn drawShortcut(fonts: Fonts, page: Page, choice: Hit, quick: *const quick_model.Quick) !void {
    const box = shortcutBox(choice) orelse return;
    page.fillRect(box.left, box.top, box.width, box.height, 0xff);
    for (shortcuts) |s| {
        if (s.hit != choice) continue;
        drawIcon(page, s, quick);
        try draw.centered(fonts.small, page, @floatFromInt(s.x), s.y + 92, label(s, quick));
    }
}

fn drawGlyph(page: Page, s: Shortcut, quick: *const quick_model.Quick, x: f32, y: f32) void {
    switch (s.icon) {
        .airplane => icons.airplane(page, x, y),
        .wifi => icons.wifi(page, x, y - 4, 0.8, if (quick.wifi_on) quick.wifi_bars else 0),
        .bluetooth => icons.bluetooth(page, x, y),
        .sync => icons.sync(page, x, y),
        .kindle => icons.smile(page, x, y),
    }
}

const tile = 2 * icon_radius + 8;

/// Off: a ring with the icon in black. On: a smooth black disc with the icon in white.
fn drawIcon(page: Page, s: Shortcut, quick: *const quick_model.Quick) void {
    const x: f32 = @floatFromInt(s.x);
    const y: f32 = @floatFromInt(s.y);
    if (!isOn(s, quick)) {
        icons.ring(page, x, y, icon_radius);
        drawGlyph(page, s, quick, x, y);
        return;
    }
    page.pill(x, x, y, icon_radius + 1.5, 0x00);
    const Glyph = struct {
        s: Shortcut,
        quick: *const quick_model.Quick,
        pub fn draw(g: @This(), t: Page, cx: f32, cy: f32) !void {
            drawGlyph(t, g.s, g.quick, cx, cy);
        }
    };
    icons.drawWhite(page, tile, tile, s.x, s.y, Glyph{ .s = s, .quick = quick }) catch {};
}

/// Toggles fill when on, like the stock panel.
pub fn isOn(s: Shortcut, quick: *const quick_model.Quick) bool {
    return switch (s.icon) {
        .airplane => quick.airplane,
        .wifi => quick.wifi_on,
        .bluetooth => quick.bluetooth,
        else => false,
    };
}

fn label(s: Shortcut, quick: *const quick_model.Quick) []const u8 {
    return switch (s.icon) {
        .airplane => if (quick.airplane) "On" else "Off",
        .wifi => if (quick.wifi_on) "Connected" else "Wi-Fi Off",
        .bluetooth => if (quick.bluetooth) "On" else "Off",
        .sync => if (quick.syncing) "Syncing" else "Sync",
        .kindle => "Kindle",
    };
}

pub fn render(fonts: Fonts, page: Page, quick: *const quick_model.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    page.fillRect(0, 0, page.width, height, 0xff);
    page.fillRect(0, height - 4, page.width, 4, 0x00);

    try fonts.title.draw(page, 60, 70, "Kindle Paperwhite");
    try fonts.small.draw(page, 60, 120, quick.clockText());
    try icons.statusCluster(page, fonts.small, w - 60, 58, 70, quick, true);

    for (shortcuts) |s| {
        drawIcon(page, s, quick);
        try draw.centered(fonts.small, page, @floatFromInt(s.x), s.y + 92, label(s, quick));
    }

    page.fillRect(40, 560, page.width - 80, 2, style.panel_rule);
    try fonts.small.draw(page, 60, 606, brightness_row.label);
    try drawSlider(fonts, page, brightness_row, quick.brightness, false);
    try fonts.small.draw(page, 60, 776, warmth_row.label);
    const schedule = if (quick.schedule) "Schedule: On" else "Schedule: Off";
    const schedule_w = try fonts.small.measure(schedule);
    try fonts.small.draw(page, w - 96 - schedule_w, 776, schedule);
    page.stroke(w - 80, 752, w - 66, 766, 4);
    page.stroke(w - 66, 766, w - 80, 780, 4);
    try drawSlider(fonts, page, warmth_row, quick.warmth, false);
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
    try std.testing.expectEqual(@as(u32, 160), knobUnder(20));
    try std.testing.expectEqual(@as(u32, 500), knobUnder(500));
    try std.testing.expectEqual(@as(u32, 1110), knobUnder(1250));
}

test "a knob move redraws only around old and new knob" {
    const span = knobSpan(700, 400);
    try std.testing.expectEqual(@as(u32, 340), span.left);
    try std.testing.expectEqual(@as(u32, 420), span.width);
    try std.testing.expectEqual(@as(u32, 0), knobSpan(20, 30).left);
}

test "toggle boxes stay apart and on screen" {
    const a = shortcutBox(.airplane).?;
    const b = shortcutBox(.bluetooth).?;
    try std.testing.expect(a.left + a.width <= shortcutBox(.settings).?.left);
    try std.testing.expect(b.left + b.width <= 1272);
    try std.testing.expect(shortcutBox(.close) == null);
}

test "sliders map position to level" {
    try std.testing.expectEqual(@as(u32, 0), levelAt(brightness_row, 160));
    try std.testing.expectEqual(@as(u32, 24), levelAt(brightness_row, 1110));
    try std.testing.expectEqual(@as(u32, 12), levelAt(warmth_row, 635));
    try std.testing.expectEqual(@as(u32, 24), levelAt(warmth_row, 1200));
}

test "toggles report their state" {
    const on = quick_model.Quick{ .airplane = true, .wifi_on = true };
    const off = quick_model.Quick{};
    try std.testing.expect(isOn(shortcuts[0], &on));
    try std.testing.expect(!isOn(shortcuts[0], &off));
    try std.testing.expect(isOn(shortcuts[1], &on));
    try std.testing.expect(!isOn(shortcuts[2], &on));
}

test "bluetooth toggle shows its state" {
    const on = quick_model.Quick{ .bluetooth = true };
    const off = quick_model.Quick{};
    try std.testing.expect(isOn(shortcuts[2], &on));
    try std.testing.expect(!isOn(shortcuts[2], &off));
    try std.testing.expectEqualStrings("On", label(shortcuts[2], &on));
    try std.testing.expectEqualStrings("Off", label(shortcuts[2], &off));
}
