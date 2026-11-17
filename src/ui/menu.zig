//! Quick panel: drag down from the top of any screen to open it.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("style.zig");
const Page = @import("../gfx/page.zig").Page;
const Fonts = @import("fonts.zig").Fonts;
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const slider = @import("slider.zig");
const quick_model = @import("../model/quick.zig");

pub const height = 960;

const slider_left = 160;
const slider_right = 1110;

pub const Row = struct { label: []const u8, y: u32, max: u32 };
pub const brightness_row = Row{
    .label = "Brightness",
    .y = 680,
    .max = quick_model.max_brightness,
};
pub const warmth_row = Row{ .label = "Warmth", .y = 850, .max = quick_model.max_warmth };
const schedule_top = 754;
const schedule_bottom = 794;
const schedule_left = 800; // The schedule takes taps right of here
const row_reach = 60; // A slider row takes taps this far above and below its bar

pub const Hit = enum {
    none,
    close,
    dimmer,
    brighter,
    slider,
    cooler,
    warmer,
    warmth,
    schedule,
    airplane,
    bluetooth,
    settings,
    kindle,
    sync,
};

const Quick = quick_model.Quick;

/// The icon on a tile.
const Glyph = enum { airplane, wifi, bluetooth, sync, smile };

/// A round button at the top of the panel: what a tap on it does, its icon, the
/// setting it follows, and the word under it with that setting on and off.
const Tile = struct {
    hit: Hit,
    glyph: Glyph,
    /// The bool of Quick the tile follows, or null for a plain button.
    state: ?[]const u8 = null,
    /// Whether the tile shows as on (filled) while its state is, as a toggle does.
    fills: bool = true,
    label_on: []const u8,
    label_off: []const u8,
};

/// The tiles, in order: three on the first row, the rest centred on the second.
/// Adding one is an entry here (and its Hit); the panel places it.
const tiles = [_]Tile{
    .{
        .hit = .airplane,
        .glyph = .airplane,
        .state = "airplane",
        .label_on = "On",
        .label_off = "Off",
    },
    // Networks live in the Kindle's own settings
    .{
        .hit = .settings,
        .glyph = .wifi,
        .state = "wifi_on",
        .label_on = "Connected",
        .label_off = "Wi-Fi Off",
    },
    .{
        .hit = .bluetooth,
        .glyph = .bluetooth,
        .state = "bluetooth",
        .label_on = "On",
        .label_off = "Off",
    },
    // Says when it's working, but isn't a switch to show as on
    .{
        .hit = .sync,
        .glyph = .sync,
        .state = "syncing",
        .fills = false,
        .label_on = "Syncing",
        .label_off = "Sync",
    },
    // Back to the Kindle's own home
    .{ .hit = .kindle, .glyph = .smile, .label_on = "Kindle", .label_off = "Kindle" },
};

const icon_radius = 52;
const tiles_per_row = 3;
const tile_step_x = 318; // Between tile centres along a row
const tile_reach_x = 120; // A tile takes taps this far either side of its centre
const tile_reach_y = 95; // And this far above and below it
const tile_label_below = 92; // From a tile's centre to the baseline of its word
const first_row_y = 240;
const row_step_y = 190;
const tile_rows = (tiles.len + tiles_per_row - 1) / tiles_per_row;
const tile_px = 2 * icon_radius + 8;

const band_above = 60;
const band_below = 50;
pub const band_height = band_above + band_below;

comptime {
    for (tiles) |t| {
        if (t.state) |field| assert(@FieldType(Quick, field) == bool);
    }
    // Tiles take a fingertip and more, apart from each other, above the sliders
    assert(2 * tile_reach_x <= tile_step_x);
    assert(2 * tile_reach_y <= row_step_y);
    assert(icon_radius < tile_reach_y);
    assert(tile_label_below < tile_reach_y);
    assert(tiles_per_row * tile_step_x <= style.screen_width);
    const last_row_y = first_row_y + (tile_rows - 1) * row_step_y;
    assert(last_row_y + tile_reach_y <= brightness_row.y - row_reach);
    // A toggle's box, redrawn alone, reaches no slider's band
    assert(last_row_y + 130 <= brightness_row.y - band_above);
    // Sliders, the schedule and the chevron, top to bottom, inside the panel
    assert(slider_left < slider_right);
    assert(slider_right <= style.screen_width);
    assert(brightness_row.y + band_below <= warmth_row.y - band_above);
    assert(brightness_row.y + row_reach <= schedule_top);
    assert(schedule_top < schedule_bottom);
    assert(warmth_row.y + row_reach < height);
    assert(height < style.screen_height);
}

/// Whether tile `i` shows as on (filled).
fn tile_on(i: u32, quick: *const Quick) bool {
    assert(i < tiles.len);
    inline for (tiles, 0..) |t, j| {
        if (i == j) {
            const field = t.state orelse return false;
            return t.fills and @field(quick, field);
        }
    }
    unreachable;
}

/// The word under tile `i`, for its setting as it is now.
fn tile_label(i: u32, quick: *const Quick) []const u8 {
    assert(i < tiles.len);
    inline for (tiles, 0..) |t, j| {
        if (i == j) {
            const field = t.state orelse return t.label_on;
            const label = if (@field(quick, field)) t.label_on else t.label_off;
            assert(label.len > 0);
            return label;
        }
    }
    unreachable;
}

fn draw_glyph(page: Page, quick: *const Quick, glyph: Glyph, x: f32, y: f32) void {
    assert(x > 0);
    assert(y > 0);
    switch (glyph) {
        .airplane => icons.airplane(page, x, y),
        .wifi => icons.wifi(page, x, y - 4, 0.8, quick.wifi_shown() orelse 0),
        .bluetooth => icons.bluetooth(page, x, y),
        .sync => icons.sync(page, x, y),
        .smile => icons.smile(page, x, y),
    }
}

/// The centre of tile `i`: rows of three, each row centred on the screen.
fn tile_center(i: u32) struct { x: i32, y: i32 } {
    assert(i < tiles.len);
    const row = i / tiles_per_row;
    const col = i % tiles_per_row;
    const in_row = @min(tiles_per_row, tiles.len - row * tiles_per_row);
    assert(col < in_row);
    // Doubled to keep the half-step of an even row whole
    const offset2: i32 = 2 * @as(i32, @intCast(col)) - @as(i32, @intCast(in_row - 1));
    const x = style.screen_width / 2 + @divExact(offset2 * tile_step_x, 2);
    const y = first_row_y + @as(i32, @intCast(row)) * row_step_y;
    assert(x - tile_reach_x >= 0);
    assert(x + tile_reach_x <= style.screen_width);
    return .{ .x = x, .y = y };
}

fn row_slider(row: Row) slider.Slider {
    assert(row.max > 0);
    assert(row.y + band_below < height);
    return .{ .left = slider_left, .right = slider_right, .y = row.y };
}

/// Level for a tap at `x` on a row's slider.
pub fn level_at(row: Row, x: i32) u32 {
    const level = slider.value_at(row_slider(row), x, row.max);
    assert(level <= row.max);
    return level;
}

pub fn hit(x: i32, y: i32) Hit {
    if (y >= height) return .close;
    if (y >= warmth_row.y + row_reach) return .close; // The chevron
    if (y >= schedule_top and y < schedule_bottom and x >= schedule_left) return .schedule;
    if (y >= warmth_row.y - row_reach) {
        if (x < slider_left) return .cooler;
        if (x > slider_right) return .warmer;
        return .warmth;
    }
    if (y >= brightness_row.y - row_reach and y < brightness_row.y + row_reach) {
        if (x < slider_left) return .dimmer;
        if (x > slider_right) return .brighter;
        return .slider;
    }
    for (0..tiles.len) |i| {
        const c = tile_center(@intCast(i));
        if (@abs(x - c.x) < tile_reach_x and @abs(y - c.y) < tile_reach_y) return tiles[i].hit;
    }
    return .none;
}

pub fn band_top(row: Row) u32 {
    assert(row.y >= band_above);
    const top = row.y - band_above;
    assert(top + band_height <= height);
    return top;
}

/// One slider row at rest, with the knob on its step.
pub fn draw_slider(fonts: Fonts, page: Page, row: Row, value: u32, mono: bool) !void {
    const knob = knob_at(row, value);
    try draw_slider_at(fonts, page, row, value, knob, mono);
}

/// Where the knob sits for `value`.
pub fn knob_at(row: Row, value: u32) u32 {
    const knob = slider.knob_at(row_slider(row), value, row.max);
    assert(knob >= slider_left);
    assert(knob <= slider_right);
    return knob;
}

/// Knob position under a finger at `x`, kept on the bar. While dragging, the knob
/// follows the finger rather than jumping from step to step.
pub fn knob_under(x: i32) u32 {
    const knob: u32 = @intCast(std.math.clamp(x, slider_left, slider_right));
    assert(knob >= slider_left);
    assert(knob <= slider_right);
    return knob;
}

/// The columns a slider frame changes when its knob moves from `from` to `to`:
/// the knob, its level above it, and the bar between them.
pub fn knob_span(from: u32, to: u32) struct { left: u32, width: u32 } {
    const reach = 60; // Half the widest level text, and more than the knob
    const left = @min(from, to) -| reach;
    const width = @max(from, to) + reach - left;
    assert(left <= @min(from, to));
    assert(left + width >= @max(from, to) + reach);
    return .{ .left = left, .width = width };
}

/// One slider row with the knob at `knob`. `mono` is pure black and white for the
/// fast waveform used while dragging, which breaks up gray.
pub fn draw_slider_at(
    fonts: Fonts,
    page: Page,
    row: Row,
    value: u32,
    knob: u32,
    mono: bool,
) !void {
    // Placed by knob_at or knob_under, on the bar
    assert(knob >= slider_left);
    assert(knob <= slider_right);
    page.fill_rect(0, band_top(row), page.width, band_height, 0xff);
    const bar = row_slider(row);
    var level: [8]u8 = undefined;
    const shown = std.fmt.bufPrint(&level, "{d}", .{value}) catch "";
    const knob_x: f32 = @floatFromInt(knob);
    try draw.centered(fonts.small, page, knob_x, @intCast(row.y - 40), shown);
    const y: f32 = @floatFromInt(row.y);
    page.stroke(70, y, 110, y, 4);
    page.stroke(1160, y, 1200, y, 4);
    page.stroke(1180, y - 20, 1180, y + 20, 4);
    slider.draw(page, bar, knob);
    if (mono) page.threshold(band_top(row), band_height);
}

/// Where a toggle and its label sit, to redraw it alone.
pub fn shortcut_box(choice: Hit) ?style.Rect {
    for (0..tiles.len) |i| {
        if (tiles[i].hit != choice) continue;
        const c = tile_center(@intCast(i));
        const box = style.Rect{
            .x = @intCast(c.x - 130),
            .y = @intCast(c.y - icon_radius - 8),
            .w = 260,
            .h = icon_radius + 8 + 130,
        };
        assert(box.x + box.w <= style.screen_width);
        assert(box.y + box.h <= height);
        return box;
    }
    return null;
}

/// Redraws one toggle and its label, after a tap changed it.
pub fn draw_shortcut(fonts: Fonts, page: Page, choice: Hit, quick: *const Quick) !void {
    const box = shortcut_box(choice) orelse return;
    page.fill_rect(box.x, box.y, box.w, box.h, 0xff);
    for (0..tiles.len) |i| {
        if (tiles[i].hit == choice) try draw_tile(fonts, page, @intCast(i), quick);
    }
}

/// A tile's icon, for drawing in white on a black disc.
const WhiteGlyph = struct {
    glyph: Glyph,
    quick: *const Quick,

    pub fn draw(white: WhiteGlyph, tile: Page, cx: f32, cy: f32) !void {
        // Centred in the tile it's drawn on
        assert(cx * 2 == @as(f32, @floatFromInt(tile.width)));
        assert(cy * 2 == @as(f32, @floatFromInt(tile.height)));
        draw_glyph(tile, white.quick, white.glyph, cx, cy);
    }
};

/// A tile and the word under it. Off: a ring with the icon in black. On, like the
/// stock panel: a smooth black disc with the icon in white.
fn draw_tile(fonts: Fonts, page: Page, i: u32, quick: *const Quick) !void {
    assert(i < tiles.len);
    const t = tiles[i];
    const c = tile_center(i);
    const x: f32 = @floatFromInt(c.x);
    const y: f32 = @floatFromInt(c.y);
    if (!tile_on(i, quick)) {
        icons.ring(page, x, y, icon_radius);
        draw_glyph(page, quick, t.glyph, x, y);
    } else {
        page.pill(x, x, y, icon_radius + 1.5, 0x00);
        const white = WhiteGlyph{ .glyph = t.glyph, .quick = quick };
        try icons.draw_white(page, tile_px, tile_px, c.x, c.y, white);
    }
    try draw.centered(fonts.small, page, x, c.y + tile_label_below, tile_label(i, quick));
}

pub fn render(fonts: Fonts, page: Page, quick: *const quick_model.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    page.fill_rect(0, 0, page.width, height, 0xff);
    page.fill_rect(0, height - 4, page.width, 4, 0x00);

    try fonts.title.draw(page, 60, 70, "Kindle Paperwhite");
    try fonts.small.draw(page, 60, 120, quick.clock_text());
    try icons.status_cluster(page, fonts.small, w - 60, 58, 70, quick, true);

    for (0..tiles.len) |i| try draw_tile(fonts, page, @intCast(i), quick);

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
    try std.testing.expect(a.x + a.w <= shortcut_box(.settings).?.x);
    try std.testing.expect(b.x + b.w <= 1272);
    try std.testing.expect(shortcut_box(.close) == null);
}

test "sliders map position to level" {
    try std.testing.expectEqual(@as(u32, 0), level_at(brightness_row, 160));
    try std.testing.expectEqual(@as(u32, 24), level_at(brightness_row, 1110));
    try std.testing.expectEqual(@as(u32, 12), level_at(warmth_row, 635));
    try std.testing.expectEqual(@as(u32, 24), level_at(warmth_row, 1200));
}

test "sync and the Kindle button never show as on" {
    const busy = quick_model.Quick{ .syncing = true };
    try std.testing.expect(!tile_on(3, &busy));
    try std.testing.expectEqualStrings("Syncing", tile_label(3, &busy));
    try std.testing.expect(!tile_on(4, &busy));
    try std.testing.expectEqualStrings("Kindle", tile_label(4, &busy));
}

test "toggles report their state" {
    const on = quick_model.Quick{ .airplane = true, .wifi_on = true };
    const off = quick_model.Quick{};
    try std.testing.expect(tile_on(0, &on));
    try std.testing.expect(!tile_on(0, &off));
    try std.testing.expect(tile_on(1, &on));
    try std.testing.expect(!tile_on(2, &on));
}

test "bluetooth toggle shows its state" {
    const on = quick_model.Quick{ .bluetooth = true };
    const off = quick_model.Quick{};
    try std.testing.expect(tile_on(2, &on));
    try std.testing.expect(!tile_on(2, &off));
    try std.testing.expectEqualStrings("On", tile_label(2, &on));
    try std.testing.expectEqualStrings("Off", tile_label(2, &off));
}

test "tiles sit where they always have" {
    const want = [_][2]i32{
        .{ 318, 240 },
        .{ 636, 240 },
        .{ 954, 240 },
        .{ 477, 430 },
        .{ 795, 430 },
    };
    for (want, 0..) |w, i| {
        const c = tile_center(@intCast(i));
        try std.testing.expectEqual(w[0], c.x);
        try std.testing.expectEqual(w[1], c.y);
    }
}
