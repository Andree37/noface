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

const screen_width = style.screen_width;

/// The panel, top to bottom: the header, the tiles, a rule, the brightness's name and
/// slider, the warmth's name with the schedule, its slider, and the chevron.
pub const height = warmth_row.y + chevron_band;
const chevron_band = 110; // Under the warmth's bar, holding the chevron
const chevron_above_foot = 26; // The chevron's middle over the panel's foot
const chevron_y = height - chevron_above_foot; // The chevron, which closes the panel
const edge = 4; // The line along the panel's foot

/// The header: the Kindle's name and the clock in from the left, the status cluster in
/// from the right, on the name's line.
const header_inset = 60;
const header_baseline = 70;
const clock_baseline = 120;
const status_centre = 58;

/// The rule between the tiles and the sliders, the toggles' boxes' depth under it.
const rule_inset = 40;
const rule_thick = 2;
const rule_y = last_row_y + tile_box_below;

/// A slider's bar in from each side; its dimmer and brighter marks centred in the room
/// outside it, each half a mark long and stroked this thick; its level over the knob.
const slider_inset = 160;
const slider_left = slider_inset;
const slider_right = screen_width - slider_inset;
const step_mark_middle = slider_inset / 2; // In from the screen's side
const step_mark_half = 20;
const step_mark_thick = 4;
const level_above = 40; // The level's baseline over the bar
/// How high the level's digits reach over their baseline, smooth edges and all.
const level_reach = 24;

pub const Row = struct { label: []const u8, y: u32, max: u32 };
/// The brightness's name sits under the rule, its bar under that; the warmth's a slider
/// step lower.
const brightness_label_below_rule = 46;
const label_above_bar = 74;
const brightness_label_baseline = rule_y + brightness_label_below_rule;
const slider_step = 220;
pub const brightness_row = Row{
    .label = "Brightness",
    .y = brightness_label_baseline + label_above_bar,
    .max = quick_model.max_brightness,
};
pub const warmth_row = Row{
    .label = "Warmth",
    .y = brightness_row.y + slider_step,
    .max = quick_model.max_warmth,
};
const row_reach = 60; // A slider row takes taps this far above and below its bar
/// The warmth's name and the schedule's switch, on one line between the two sliders,
/// higher over its bar than the brightness's, to fit the schedule's taps. The schedule
/// takes taps right of `schedule_left`, in all the room between the sliders' taps: a
/// fingertip tall and more.
const warmth_label_above_bar = 95;
const warmth_label_baseline = warmth_row.y - warmth_label_above_bar;
const schedule_top = brightness_row.y + row_reach;
const schedule_bottom = warmth_row.y - row_reach;
/// The schedule's taps, in from the right: wider than its longest words and arrow.
const schedule_reach = 472;
const schedule_left = screen_width - schedule_reach;
/// "Schedule: On" ends this far in from the right, then its arrow: its left in from the
/// right, its width, and its point over the words' baseline.
const schedule_text_inset = 96;
const schedule_arrow_inset = 80;
const schedule_arrow_width = 14;
const schedule_arrow_rise = 10;
/// How far the line's words reach above and below their baseline.
const words_reach = 30;
const words_below = 10;

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
/// Between tile centres along a row: a row's tiles spread evenly across the screen.
const tile_step_x = screen_width / (tiles_per_row + 1);
const tile_reach_x = 120; // A tile takes taps this far either side of its centre
const tile_reach_y = 95; // And this far above and below it
const tile_label_below = 92; // From a tile's centre to the baseline of its word
const first_row_y = 240; // The first row's middle, under the header
const row_step_y = 190;
const tile_rows = (tiles.len + tiles_per_row - 1) / tiles_per_row;
const last_row_y = first_row_y + (tile_rows - 1) * row_step_y;
const tile_px = 2 * icon_radius + 8;
/// A toggle's box, redrawn alone: its icon's tile above its middle, and this far either
/// side and below, round its word.
const tile_box_half_width = 130;
const tile_box_below = 130;

/// Half the widest level text, and more than the knob: what a knob's move redraws round it.
const knob_reach = 60;
/// A slider's band, redrawn alone as its knob moves: from over its level's digits to under
/// its knob.
const band_above = level_above + level_reach;
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
    assert(last_row_y + tile_reach_y <= brightness_row.y - row_reach);
    // A toggle's box, redrawn alone, reaches no slider's band
    assert(last_row_y + tile_box_below <= brightness_row.y - band_above);
    // Sliders, the schedule and the chevron, top to bottom, inside the panel
    assert(slider_left < slider_right);
    assert(slider_right <= style.screen_width);
    assert(brightness_row.y + band_below <= warmth_row.y - band_above);
    assert(brightness_row.y + row_reach <= schedule_top);
    assert(schedule_bottom <= warmth_row.y - row_reach);
    // The schedule's switch a fingertip tall, its words inside its taps and above the
    // warmth's band, which is redrawn alone as its knob moves
    assert(schedule_bottom - schedule_top >= style.fingertip);
    assert(warmth_label_baseline - words_reach >= schedule_top);
    assert(warmth_label_baseline + words_below <= schedule_bottom);
    assert(warmth_label_baseline + words_below <= warmth_row.y - band_above);
    // The brightness's name is clear of its band too, which would cut it
    assert(brightness_label_baseline + words_below <= brightness_row.y - band_above);
    // The marks sit outside the bar, a fingertip's taps of their own
    assert(step_mark_middle + step_mark_half < slider_left);
    assert(warmth_row.y + row_reach < chevron_y);
    assert(chevron_y < height);
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
    // Doubled to keep the half-step of an even row whole, halved last
    const offset2: i32 = 2 * @as(i32, @intCast(col)) - @as(i32, @intCast(in_row - 1));
    const x = @divTrunc(style.screen_width + offset2 * tile_step_x, 2);
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

/// The middle of a tile's taps, and for closing, of the page under the panel.
pub fn place(h: Hit) style.Point {
    const point: style.Point = switch (h) {
        .close => .{ .x = style.screen_width / 2, .y = (height + style.screen_height) / 2 },
        // The sliders and their ends take a level, by where along them: not a place
        .none, .dimmer, .brighter, .slider, .cooler, .warmer, .warmth => unreachable,
        .schedule => .{
            .x = @divTrunc(schedule_left + style.screen_width, 2),
            .y = @divTrunc(schedule_top + schedule_bottom, 2),
        },
        .airplane, .bluetooth, .settings, .kindle, .sync => tile: for (tiles, 0..) |t, i| {
            if (t.hit != h) continue;
            const c = tile_center(@intCast(i));
            break :tile .{ .x = c.x, .y = c.y };
        } else unreachable, // Each is a tile
    };
    assert(hit(point.x, point.y) == h);
    return point;
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
    const reach = knob_reach;
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
    try draw.centered(fonts.small, page, knob_x, @intCast(row.y - level_above), shown);
    const y: f32 = @floatFromInt(row.y);
    const half: f32 = step_mark_half;
    const minus: f32 = step_mark_middle;
    const plus: f32 = screen_width - step_mark_middle;
    page.stroke(minus - half, y, minus + half, y, step_mark_thick);
    page.stroke(plus - half, y, plus + half, y, step_mark_thick);
    page.stroke(plus, y - half, plus, y + half, step_mark_thick);
    slider.draw(page, bar, knob);
    if (mono) page.threshold(band_top(row), band_height);
}

/// Where a toggle and its label sit, to redraw it alone.
pub fn shortcut_box(choice: Hit) ?style.Rect {
    for (0..tiles.len) |i| {
        if (tiles[i].hit != choice) continue;
        const c = tile_center(@intCast(i));
        const box = style.Rect{
            .x = @intCast(c.x - tile_box_half_width),
            .y = @intCast(c.y - tile_px / 2),
            .w = 2 * tile_box_half_width,
            .h = tile_px / 2 + tile_box_below,
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
    page.fill_rect(0, height - edge, page.width, edge, 0x00);

    try fonts.title.draw(page, header_inset, header_baseline, "Kindle Paperwhite");
    try fonts.small.draw(page, header_inset, clock_baseline, quick.clock_text());
    const status_right = w - header_inset;
    const centre = status_centre;
    const baseline = header_baseline;
    try icons.status_cluster(page, fonts.small, status_right, centre, baseline, quick, true);

    for (0..tiles.len) |i| try draw_tile(fonts, page, @intCast(i), quick);

    page.fill_rect(rule_inset, rule_y, page.width - 2 * rule_inset, rule_thick, style.panel_rule);
    try fonts.small.draw(page, header_inset, brightness_label_baseline, brightness_row.label);
    try draw_slider(fonts, page, brightness_row, quick.brightness, false);
    try fonts.small.draw(page, header_inset, warmth_label_baseline, warmth_row.label);
    const schedule = if (quick.schedule) "Schedule: On" else "Schedule: Off";
    const schedule_w = try fonts.small.measure(schedule);
    const schedule_x = w - schedule_text_inset - schedule_w;
    try fonts.small.draw(page, schedule_x, warmth_label_baseline, schedule);
    // A small arrow after it, centred on its letters
    const arrow_y: f32 = warmth_label_baseline - schedule_arrow_rise;
    const arrow_left = w - schedule_arrow_inset;
    const arrow_w: f32 = schedule_arrow_width;
    page.stroke(arrow_left, arrow_y - arrow_w, arrow_left + arrow_w, arrow_y, step_mark_thick);
    page.stroke(arrow_left + arrow_w, arrow_y, arrow_left, arrow_y + arrow_w, step_mark_thick);
    try draw_slider(fonts, page, warmth_row, quick.warmth, false);
    icons.chevron(page, w / 2, chevron_y);
}

/// Where tests tap: inside a slider row left and right of its bar and on it, and on the
/// schedule's line.
const test_minus_x = step_mark_middle;
const test_plus_x = screen_width - step_mark_middle;
const test_bar_x = screen_width / 2;
const test_schedule_x = schedule_left + schedule_reach / 2;

test "every tile's place, and closing's, is a tap on it" {
    for (tiles) |t| {
        const p = place(t.hit);
        try std.testing.expectEqual(t.hit, hit(p.x, p.y));
    }
    for ([_]Hit{ .close, .schedule }) |h| {
        const p = place(h);
        try std.testing.expectEqual(h, hit(p.x, p.y));
    }
}

test "panel maps taps where it draws them" {
    for (tiles, 0..) |t, i| {
        const c = tile_center(@intCast(i));
        try std.testing.expectEqual(t.hit, hit(c.x, c.y));
    }
    // The empty place after the last tile on its row
    const last = tile_center(tiles.len - 1);
    try std.testing.expectEqual(Hit.none, hit(last.x + tile_step_x, last.y));
    const bright: i32 = brightness_row.y;
    try std.testing.expectEqual(Hit.dimmer, hit(test_minus_x, bright));
    try std.testing.expectEqual(Hit.brighter, hit(test_plus_x, bright));
    try std.testing.expectEqual(Hit.slider, hit(test_bar_x, bright));
    const warm: i32 = warmth_row.y;
    try std.testing.expectEqual(Hit.cooler, hit(test_minus_x, warm));
    try std.testing.expectEqual(Hit.warmer, hit(test_plus_x, warm));
    try std.testing.expectEqual(Hit.warmth, hit(test_bar_x, warm));
    try std.testing.expectEqual(Hit.schedule, hit(test_schedule_x, warmth_label_baseline));
    try std.testing.expectEqual(Hit.close, hit(screen_width / 2, chevron_y));
    try std.testing.expectEqual(Hit.close, hit(test_bar_x, height));
}

test "the schedule takes a fingertip's taps, and the sliders none of them" {
    const middle = @divExact(schedule_top + schedule_bottom, 2);
    const x = test_schedule_x;
    try std.testing.expectEqual(Hit.schedule, hit(x, middle));
    try std.testing.expectEqual(Hit.schedule, hit(x, schedule_top));
    try std.testing.expectEqual(Hit.schedule, hit(x, schedule_bottom - 1));
    // Just under its words, where a tap once changed the warmth
    try std.testing.expectEqual(Hit.schedule, hit(x, warmth_label_baseline + words_below));
    try std.testing.expectEqual(Hit.brighter, hit(test_plus_x, schedule_top - 1));
    try std.testing.expectEqual(Hit.warmer, hit(test_plus_x, schedule_bottom));
    // Left of it, under the warmth's name, a tap does nothing
    try std.testing.expectEqual(Hit.none, hit(schedule_left - 1, middle));
}

test "knob follows the finger but stays on the bar" {
    try std.testing.expectEqual(@as(u32, slider_left), knob_under(0));
    try std.testing.expectEqual(@as(u32, test_bar_x), knob_under(test_bar_x));
    try std.testing.expectEqual(@as(u32, slider_right), knob_under(screen_width));
}

test "a knob move redraws only around old and new knob" {
    const span = knob_span(700, 400);
    try std.testing.expectEqual(@as(u32, 400 - knob_reach), span.left);
    try std.testing.expectEqual(@as(u32, 300 + 2 * knob_reach), span.width);
    try std.testing.expectEqual(@as(u32, 0), knob_span(knob_reach / 2, knob_reach).left);
}

test "toggle boxes stay apart and on screen" {
    const a = shortcut_box(.airplane).?;
    const b = shortcut_box(.bluetooth).?;
    try std.testing.expect(a.x + a.w <= shortcut_box(.settings).?.x);
    try std.testing.expect(b.x + b.w <= screen_width);
    try std.testing.expect(shortcut_box(.close) == null);
}

test "sliders map position to level" {
    const middle = (slider_left + slider_right) / 2;
    try std.testing.expectEqual(@as(u32, 0), level_at(brightness_row, slider_left));
    const brightest = level_at(brightness_row, slider_right);
    try std.testing.expectEqual(@as(u32, brightness_row.max), brightest);
    try std.testing.expectEqual(@as(u32, warmth_row.max / 2), level_at(warmth_row, middle));
    try std.testing.expectEqual(@as(u32, warmth_row.max), level_at(warmth_row, screen_width));
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

test "a row of tiles is spread evenly, and a short row centred" {
    const first = tile_center(0);
    const second = tile_center(1);
    try std.testing.expectEqual(@as(i32, tile_step_x), first.x);
    try std.testing.expectEqual(@as(i32, tile_step_x), second.x - first.x);
    const fourth = tile_center(3);
    const fifth = tile_center(4);
    try std.testing.expectEqual(@as(i32, screen_width), fourth.x + fifth.x);
    try std.testing.expectEqual(@as(i32, first_row_y + row_step_y), fourth.y);
}
