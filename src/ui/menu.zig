//! Quick panel: drag down from the top of any screen to open it.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../text/line.zig").of;
const device = @import("../model/device.zig");
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
const chevron_band = style.space.band; // Under the warmth's bar, holding the chevron
const chevron_above_foot = style.space.medium; // The chevron's middle over the panel's foot
const chevron_y = height - chevron_above_foot; // The chevron, which closes the panel
const edge = style.space.hair; // The line along the panel's foot

/// The header: the Kindle's name and the clock in from the left, the status cluster in
/// from the right, on the name's line.
const header_inset = style.space.wider;
const header_baseline = style.space.wider;
const clock_baseline = style.space.tall;
const status_centre = style.space.tiny + style.space.wide;

/// The rule between the tiles and the sliders, the toggles' boxes' depth under it.
const rule_inset = style.space.tiny + style.space.roomy;
const rule_thick = style.stroke;
const rule_y = last_row_y + tile_box_below;

/// A slider's bar in from each side; its dimmer and brighter marks centred in the room
/// outside it, each half a mark long and stroked this thick; its level over the knob.
const slider_inset = style.space.medium + style.space.tall;
const slider_left = slider_inset;
const slider_right = screen_width - slider_inset;
const step_mark_middle = slider_inset / 2; // In from the screen's side
const step_mark_half = style.space.snug;
const step_mark_thick = style.space.hair;
const level_above = style.space.tiny + style.space.roomy; // The level's baseline over the bar
/// How high the level's digits reach over their baseline, smooth edges and all.
const level_reach = style.space.medium;

/// A slider row: which light it sets, its name, where, and its steps.
pub const Row = struct { light: Light, label: []const u8, y: u32, max: u32 };
pub const Light = enum { brightness, warmth };
/// The brightness's name sits under the rule, its bar under that; the warmth's a slider
/// step lower.
const brightness_label_below_rule = style.space.wide;
/// The label's words end just over what a slider's move redraws.
const label_above_bar = band_above + words_below;
const brightness_label_baseline = rule_y + brightness_label_below_rule;
const slider_step = style.space.band + style.space.tall;
pub const brightness_row = Row{
    .light = .brightness,
    .label = "Brightness",
    .y = brightness_label_baseline + label_above_bar,
    .max = quick_model.max_brightness,
};
pub const warmth_row = Row{
    .light = .warmth,
    .label = "Warmth",
    .y = brightness_row.y + slider_step,
    .max = quick_model.max_warmth,
};
const row_reach = style.fingertip / 2; // A slider row takes a fingertip's taps round its bar
/// The warmth's name and the schedule's switch, on one line between the two sliders,
/// higher over its bar than the brightness's, to fit the schedule's taps. The schedule
/// takes taps right of `schedule_left`, in all the room between the sliders' taps: a
/// fingertip tall and more.
const warmth_label_above_bar = style.space.band;
const warmth_label_baseline = warmth_row.y - warmth_label_above_bar;
const schedule_top = brightness_row.y + row_reach;
const schedule_bottom = warmth_row.y - row_reach;
/// The schedule's taps, in from the right: wider than its longest words and arrow.
const schedule_reach = screen_width / 2 - style.space.wider;
const schedule_left = screen_width - schedule_reach;
/// "Schedule: On" ends this far in from the right, then its arrow: its left in from the
/// right, its width, and its point over the words' baseline.
const schedule_text_inset = style.space.band;
const schedule_arrow_inset = style.space.small + style.space.wider;
const schedule_arrow_width = style.space.small;
const schedule_arrow_rise = style.space.tiny;
/// How far the line's words reach above and below their baseline.
const words_reach = style.space.roomy;
const words_below = style.space.tiny;

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
    wifi,
    kindle,
    sync,
};

const Quick = quick_model.Quick;

/// The icon on a tile.
const Glyph = enum { airplane, wifi, bluetooth, sync, smile };

/// A field of Quick, by name: each a tile reads is a bool (checked below).
const QuickBool = std.meta.FieldEnum(Quick);

/// Whether `field` of `quick` is on.
fn on_in(quick: *const Quick, comptime field: QuickBool) bool {
    return @field(quick, @tagName(field));
}

/// A round button at the top of the panel: what a tap on it does, its icon, the
/// setting it follows, and the word under it with that setting on and off.
const Tile = struct {
    hit: Hit,
    glyph: Glyph,
    /// The bool of Quick the tile follows, or null for a plain button.
    state: ?QuickBool = null,
    /// Whether the tile shows as on (filled) while its state is, as a toggle does.
    fills: bool = true,
    /// On while its state is off: the other side of the same switch.
    inverse: bool = false,
    /// Whether, while on, the word under it is the network connected to, if one is.
    names_network: bool = false,
    /// A bool of Quick while which the tile shows off, with `label_quiet` under it.
    quiet_while: ?QuickBool = null,
    label_quiet: []const u8 = "",
    label_on: []const u8,
    label_off: []const u8,
};

/// The tiles, in order: three on the first row, the rest centred on the second.
/// Adding one is an entry here (and its Hit); the panel places it.
const tiles = [_]Tile{
    .{
        .hit = .airplane,
        .glyph = .airplane,
        .state = .airplane,
        .label_on = "On",
        .label_off = "Off",
        // A pause of noface's own while reading isn't the reader's airplane mode
        .quiet_while = .wifi_paused,
        .label_quiet = "Off",
    },
    // Wi-Fi is the Kindle's one wireless switch, airplane mode's other side: on here is
    // airplane mode off. Its icon's arcs say how good the connection is
    .{
        .hit = .wifi,
        .glyph = .wifi,
        .state = .airplane,
        .inverse = true,
        .names_network = true,
        .label_on = "On",
        .label_off = "Off",
        // Off while reading by noface, to save the battery: a tap turns it back on
        .quiet_while = .wifi_paused,
        .label_quiet = "Paused",
    },
    .{
        .hit = .bluetooth,
        .glyph = .bluetooth,
        .state = .bluetooth,
        .label_on = "On",
        .label_off = "Off",
    },
    // Says when it's working, but isn't a switch to show as on
    .{
        .hit = .sync,
        .glyph = .sync,
        .state = .syncing,
        .fills = false,
        .label_on = "Syncing",
        .label_off = "Sync",
    },
    // Back to the Kindle's own home
    .{ .hit = .kindle, .glyph = .smile, .label_on = "Kindle", .label_off = "Kindle" },
};

const icon_radius = style.space.wide;
/// The Wi-Fi glyph, drawn smaller than the others and raised to sit as high as they do.
const wifi_scale = 0.8;
const wifi_rise = style.space.hair;
const tiles_per_row = 3;
/// Between tile centres along a row: a row's tiles spread evenly across the screen.
const tile_step_x = screen_width / (tiles_per_row + 1);
/// A tile takes taps halfway to the next either side of its centre, and above and below
/// it; its word's baseline sits under its icon.
const tile_reach_x = tile_step_x / 2;
const tile_reach_y = row_step_y / 2;
const tile_label_below = icon_radius + style.space.roomy;
/// The widest a word under a tile is: its box, which is redrawn when the tile changes.
const tile_label_width: f32 = @floatFromInt(2 * tile_box_half_width);
const first_row_y = style.space.band + style.space.tall; // The first row's middle, under the header
const row_step_y = style.space.wide + style.space.tall;
const tile_rows = (tiles.len + tiles_per_row - 1) / tiles_per_row;
const last_row_y = first_row_y + (tile_rows - 1) * row_step_y;
const tile_px = 2 * icon_radius + style.space.tiny;
/// A toggle's box, redrawn alone: its icon's tile above its middle, and either side its
/// share of the row less a gap from the next one's, round its word, so the longest
/// word under it (a network's name) is cleared and drawn whole.
const tile_box_half_width = (tile_step_x - style.space.wide) / 2;
const tile_box_below = style.space.tall;

/// Half the widest level text, and more than the knob: what a knob's move redraws round it.
const knob_reach = style.space.wider;
/// A slider's band, redrawn alone as its knob moves: from over its level's digits to under
/// its knob.
const band_above = level_above + level_reach;
const band_below = style.space.wide;
pub const band_height = band_above + band_below;

comptime {
    for (tiles) |t| {
        if (t.state) |field| assert(@FieldType(Quick, @tagName(field)) == bool);
        if (t.quiet_while) |field| assert(@FieldType(Quick, @tagName(field)) == bool);
    }
    // Tiles take a fingertip and more, apart from each other, above the sliders
    assert(2 * tile_reach_x <= tile_step_x);
    assert(2 * tile_reach_y <= row_step_y);
    assert(icon_radius < tile_reach_y);
    assert(tile_label_below < tile_reach_y);
    assert(tiles_per_row * tile_step_x <= style.screen_width);
    assert(last_row_y + tile_reach_y <= brightness_row.y - row_reach);
    // A toggle's box, redrawn alone, reaches no slider's band, holds its icon, and is
    // apart from its neighbours' boxes
    assert(last_row_y + tile_box_below <= brightness_row.y - band_above);
    assert(tile_px <= 2 * tile_box_half_width);
    assert(2 * tile_box_half_width < tile_step_x);
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
            if (t.quiet_while) |quiet| if (on_in(quick, quiet)) return false;
            const field = t.state orelse return false;
            return t.fills and on_in(quick, field) != t.inverse;
        }
    }
    unreachable;
}

/// The word under tile `i`, for its setting as it is now.
fn tile_label(i: u32, quick: *const Quick) []const u8 {
    assert(i < tiles.len);
    inline for (tiles, 0..) |t, j| {
        if (i == j) {
            if (t.quiet_while) |quiet| if (on_in(quick, quiet)) return t.label_quiet;
            const field = t.state orelse return t.label_on;
            const on = on_in(quick, field) != t.inverse;
            if (on and t.names_network and quick.network_len > 0) return quick.network_text();
            const label = if (on) t.label_on else t.label_off;
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
        // Its arcs the signal while on; off, the fan whole, as the switch it is
        .wifi => icons.wifi(page, x, y - wifi_rise, wifi_scale, quick.wifi_shown()),
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
    // Each half rounded towards the middle, so a row is mirrored about it exactly
    const x = @divTrunc(style.screen_width, 2) + @divTrunc(offset2 * tile_step_x, 2);
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
/// Where a finger sets a slider row to `level`: on its bar, at that level's place.
pub fn level_place(row: Row, level: u32) style.Point {
    assert(level <= row.max);
    const x = slider.knob_at(row_slider(row), level, row.max);
    const point: style.Point = .{ .x = @intCast(x), .y = @intCast(row.y) };
    assert(level_at(row, point.x) == level);
    assert(hit(point.x, point.y) == if (row.y == brightness_row.y) Hit.slider else Hit.warmth);
    return point;
}

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

/// The middle of a tile's or a slider end's taps, and for closing, of the page under the
/// panel.
pub fn place(h: Hit) style.Point {
    const point: style.Point = switch (h) {
        .close => .{ .x = style.screen_width / 2, .y = (height + style.screen_height) / 2 },
        // Each slider's ends step it down and up, either side of its bar
        .dimmer => .{ .x = slider_left / 2, .y = brightness_row.y },
        .brighter => .{ .x = (slider_right + style.screen_width) / 2, .y = brightness_row.y },
        .cooler => .{ .x = slider_left / 2, .y = warmth_row.y },
        .warmer => .{ .x = (slider_right + style.screen_width) / 2, .y = warmth_row.y },
        // The sliders take a level, by where along them: not a place
        .none, .slider, .warmth => unreachable,
        .schedule => .{
            .x = @divTrunc(schedule_left + style.screen_width, 2),
            .y = @divTrunc(schedule_top + schedule_bottom, 2),
        },
        .airplane, .bluetooth, .wifi, .kindle, .sync => tile: for (tiles, 0..) |t, i| {
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
    page.fill_rect(0, band_top(row), page.width, band_height, style.white);
    const bar = row_slider(row);
    var level: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
    const shown = line_of(&level, "{d}", .{value});
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
    page.fill_rect(box.x, box.y, box.w, box.h, style.white);
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
        // A disc over just where the ring was, so the tile keeps its size switched on
        page.pill(x, x, y, icons.ring_outer(icon_radius), style.black);
        const white = WhiteGlyph{ .glyph = t.glyph, .quick = quick };
        try icons.draw_white(page, tile_px, tile_px, c.x, c.y, white);
    }
    // Cut to the tile's own width, a network's name being as long as it likes
    const label = tile_label(i, quick);
    const width = @min(try fonts.small.measure(label), tile_label_width);
    try draw.clipped(fonts.small, page, x - width / 2, c.y + tile_label_below, label, width);
}

/// The header, drawn alone over the panel (a warning shown or put away): the Kindle's
/// name, the clock or `notice` under it, and the status, in `header_box`.
pub fn draw_header(
    fonts: Fonts,
    page: Page,
    quick: *const quick_model.Quick,
    notice: ?[]const u8,
) !void {
    const box = header_box(fonts);
    page.fill_rect(box.x, box.y, box.w, box.h, style.white);
    try fonts.title.draw(page, header_inset, header_baseline, device.short_name(device.target));
    const header_width: f32 = @floatFromInt(page.width - 2 * header_inset);
    const line = notice orelse quick.clock_text();
    try draw.clipped(fonts.small, page, header_inset, clock_baseline, line, header_width);
    const status_right: f32 = @floatFromInt(page.width - header_inset);
    const centre = status_centre;
    const baseline = header_baseline;
    try icons.status_cluster(
        page,
        fonts.small,
        status_right,
        centre,
        baseline,
        quick,
        icons.cluster_large,
    );
}

/// The header's box: the panel's top, down to the clock line's lowest descent, clear of
/// the first row of tiles.
pub fn header_box(fonts: Fonts) style.Rect {
    assert(fonts.small.descent >= 0);
    const bottom: u32 = @intCast(clock_baseline + fonts.small.descent);
    assert(bottom <= first_row_y - tile_reach_y); // Over the tiles, never into them
    return .{ .x = 0, .y = 0, .w = style.screen_width, .h = bottom };
}

/// The panel, its header's second line `notice` in place of the clock when there's one
/// (a warning a tap waits on).
pub fn render(
    fonts: Fonts,
    page: Page,
    quick: *const quick_model.Quick,
    notice: ?[]const u8,
) !void {
    const w: f32 = @floatFromInt(page.width);
    page.fill_rect(0, 0, page.width, height, style.white);
    page.fill_rect(0, height - edge, page.width, edge, style.black);
    try draw_header(fonts, page, quick, notice);

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
    const middle = @divTrunc(schedule_top + schedule_bottom, 2);
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
    try std.testing.expect(a.x + a.w <= shortcut_box(.wifi).?.x);
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
    try std.testing.expect(!tile_on(2, &on));
}

test "the Wi-Fi tile is airplane mode's other side, one switch shown twice" {
    const flying = quick_model.Quick{ .airplane = true };
    const radio_on = quick_model.Quick{ .wifi_on = true };
    try std.testing.expect(!tile_on(1, &flying));
    try std.testing.expectEqualStrings("Off", tile_label(1, &flying));
    try std.testing.expect(tile_on(1, &radio_on));
    try std.testing.expectEqualStrings("On", tile_label(1, &radio_on));
    // Never both on, never both off
    for ([_]quick_model.Quick{ flying, radio_on }) |q| {
        try std.testing.expect(tile_on(0, &q) != tile_on(1, &q));
    }
}

test "Wi-Fi noface paused while reading shows as paused, not as the reader's airplane mode" {
    const paused = quick_model.Quick{ .airplane = true, .wifi_paused = true };
    try std.testing.expect(!tile_on(0, &paused)); // Airplane mode: not the reader's
    try std.testing.expectEqualStrings("Off", tile_label(0, &paused));
    try std.testing.expect(!tile_on(1, &paused));
    try std.testing.expectEqualStrings("Paused", tile_label(1, &paused));
}

test "Wi-Fi on says the network it's connected to, if it is" {
    var named = quick_model.Quick{ .wifi_on = true };
    @memcpy(named.network[0..4], "Casa");
    named.network_len = 4;
    try std.testing.expectEqualStrings("Casa", tile_label(1, &named));
    named.airplane = true; // Off: no network, whatever was read before
    try std.testing.expectEqualStrings("Off", tile_label(1, &named));
    try std.testing.expectEqualStrings("On", tile_label(1, &quick_model.Quick{}));
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
