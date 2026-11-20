//! The Aa sheet: reading settings, in four tabs.
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("../model/settings.zig");
const Families = settings_model.Families;
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const draw = @import("draw.zig");
const style = @import("style.zig");
const toolbar = @import("toolbar.zig");
const Fonts = @import("fonts.zig").Fonts;
const slider = @import("slider.zig");
const icons = @import("icons.zig");

/// The sheet hangs under the toolbar: its tabs, then, a gap under them, its controls.
const top = toolbar.top_height;
const tabs_height = style.fingertip;
const tabs_gap = style.space.snug;
/// A tab's label, centred in the tabs' row: the line under the open one, below its
/// baseline, and the others faded, in from each side of their cell.
const tab_label = struct {
    const underline_below = style.space.snug;
    const tint_inset = style.space.tiny;
};
/// Under a tab's last control, before the sheet's edge.
const foot_pad = style.space.roomy;

/// Where the sheet ends on screen: a padding under its tab's last control.
pub fn height_for(tab: Tab) u32 {
    const result = content_foot(tab) + foot_pad;
    assert(result > content_top);
    return result;
}

/// Where a tab's last control ends: its last switch's taps, or below what's under them.
fn content_foot(tab: Tab) u32 {
    const result: u32 = switch (tab) {
        .themes => running_top + running_height,
        .font => size_row.top + row_height,
        .layout, .more => last_switch_foot(tab),
    };
    assert(result > content_top);
    return result;
}

/// The foot of the last switch's taps on `tab`.
fn last_switch_foot(tab: Tab) u32 {
    var foot: u32 = switches_top(tab);
    for (switches, 0..) |sw, i| {
        if (sw.tab == tab) foot = switch_top(@intCast(i)) + toggle_height + toggle_reach;
    }
    assert(foot >= switches_top(tab));
    return foot;
}

/// The tallest any tab's sheet reaches.
pub const max_height = max: {
    var most: u32 = 0;
    for (std.enums.values(Tab)) |tab| most = @max(most, height_for(tab));
    break :max most;
};
const margin = style.margin;
const screen_width = style.screen_width;
const content_top = top + tabs_height + tabs_gap;

pub const Tab = enum { themes, font, layout, more };
const tab_labels = [_][]const u8{ "Themes", "Font", "Layout", "More" };

pub const Hit = union(enum) {
    none,
    tab: Tab,
    theme: u32,
    family: u32, // Which cell of the typefaces' grid, counted from its page's first
    more_families, // The cell that turns the typefaces' grid to its next page
    text_size,
    spacing,
    margins,
    toggle: u32, // Which of `switches`
    running, // Running mode on or off (screens/reader/run.zig)
};

/// What else a switch changes when flipped: the pages, laid out again; the footer
/// drawn into each page; or nothing on the page.
pub const Effect = enum { relayout, footer, nothing };

/// What must be agreed, or ready, before a switch can turn on.
pub const Guard = enum { none, autostart, lock_picture };

/// An on/off setting: its tab, the field of Settings it flips, and what it says.
pub const Switch = struct {
    tab: Tab,
    field: []const u8,
    label: []const u8,
    inverted: bool = false, // On means the field is false ("Justify text" is !left_align)
    effect: Effect,
    guard: Guard = .none,
};

/// Every switch, in the order shown on each tab. Adding one is a line here: the
/// sheet places it under the ones before, and taps and drawing follow.
pub const switches = [_]Switch{
    .{ .tab = .font, .field = "bold", .label = "Bold", .effect = .relayout },
    .{ .tab = .font, .field = "bold_starts", .label = "Bold word starts", .effect = .relayout },
    .{
        .tab = .layout,
        .field = "left_align",
        .label = "Justify text",
        .inverted = true,
        .effect = .relayout,
    },
    .{ .tab = .more, .field = "clock", .label = "Show clock while reading", .effect = .nothing },
    .{
        .tab = .more,
        .field = "refresh",
        .label = std.fmt.comptimePrint(
            "Page refresh every {d} pages",
            .{settings_model.clean_every_pages},
        ),
        .effect = .nothing,
    },
    .{ .tab = .more, .field = "time_left", .label = "Show time left", .effect = .footer },
    .{
        .tab = .more,
        .field = "autostart",
        .label = "Open noface when the Kindle starts",
        .effect = .nothing,
        .guard = .autostart,
    },
    .{
        .tab = .more,
        .field = "lock_picture",
        .label = "Your picture when locked",
        .effect = .nothing,
        .guard = .lock_picture,
    },
};

comptime {
    for (switches) |sw| {
        if (!@hasField(settings_model.Settings, sw.field)) {
            @compileError("aa: no setting named " ++ sw.field);
        }
    }
}

/// Whether switch `i` shows as on for these settings.
pub fn is_on(i: u32, s: settings_model.Settings) bool {
    assert(i < switches.len);
    inline for (switches, 0..) |sw, j| {
        if (i == j) return @field(s, sw.field) != sw.inverted;
    }
    unreachable;
}

/// Flips switch `i`'s setting.
pub fn flip(i: u32, s: *settings_model.Settings) void {
    assert(i < switches.len);
    const was_on = is_on(i, s.*);
    inline for (switches, 0..) |sw, j| {
        if (i == j) @field(s, sw.field) = !@field(s, sw.field);
    }
    assert(is_on(i, s.*) != was_on);
}

/// The index of the switch for a setting, for tests and callers that name one.
pub fn switch_for(comptime field: []const u8) u32 {
    inline for (switches, 0..) |sw, i| {
        if (comptime std.mem.eql(u8, sw.field, field)) return i;
    }
    @compileError("aa: no switch for " ++ field);
}

/// Where a tab's switches start: under its other controls.
fn switches_top(tab: Tab) u32 {
    const result: u32 = switch (tab) {
        .themes => content_top, // It has none
        .font => family_top + family_rows * family_height + family_gap, // Under the typefaces
        // Under the two sliders, its taps starting where theirs end
        .layout => margin_row.top + row_height + toggle_reach,
        .more => content_top + more_gap,
    };
    // Each switch ending inside its tab's sheet is checked once, at comptime below
    assert(result >= content_top);
    return result;
}

const switch_step = style.fingertip; // A switch's taps, and so the next one's place
/// Between the typefaces' grid and the switches under it, the first switch's reach so
/// the grid's taps end where the switch's begin; and above More's switches.
const family_gap = toggle_reach;
const more_gap = style.space.tiny;

/// Where switch `i` sits: a step under the switches before it on its tab.
pub fn switch_top(i: u32) u32 {
    assert(i < switches.len);
    var before: u32 = 0;
    for (switches[0..i]) |sw| before += @intFromBool(sw.tab == switches[i].tab);
    const result = switches_top(switches[i].tab) + before * switch_step;
    assert(result >= switches_top(switches[i].tab));
    return result;
}

/// The setting an Aa slider row changes.
pub const Slider = enum { text_size, spacing, margins };

pub const Row = struct { slider: Slider, label: []const u8, top: u32, steps: u32 };
pub const size_row = Row{
    .slider = .text_size,
    .label = "Text size",
    // Under the Font tab's switches, where the last one's taps end
    .top = switch_top(switch_for("bold_starts")) + toggle_height + toggle_reach,
    .steps = settings_model.sizes.len,
};
/// The middle of a slider row's taps, down the screen; along it, a tap is a value.
pub fn row_middle(r: Row) i32 {
    assert(r.top + row_height <= max_height);
    return @intCast(r.top + row_height / 2);
}

pub const spacing_row = Row{
    .slider = .spacing,
    .label = "Line spacing",
    .top = content_top,
    .steps = settings_model.spacings.len,
};
pub const margin_row = Row{
    .slider = .margins,
    .label = "Margins",
    .top = content_top + row_height, // Under the spacing's row
    .steps = settings_model.margins.len,
};
pub const row_height = style.space.tall;

/// The tab a slider row is on.
fn slider_tab(s: Slider) Tab {
    return switch (s) {
        .text_size => .font,
        .spacing, .margins => .layout,
    };
}
const row_baseline = style.space.wide; // From a slider row's top to its label's baseline
const row_bar = style.space.band; // From a slider row's top to its bar

const family_top = content_top;
const family_height = style.fingertip;
/// The first row's taps reach up this far into the gap under the tabs.
const family_reach_above = style.space.small;
/// A typeface's name, centred in its cell in its own typeface, and the line under the
/// chosen one, below its baseline; the room kept right of a name, so long ones stop short
/// of the next cell.
const family_underline_below = style.space.small;
const family_name_gap = style.space.medium;
/// The pager's arrow: in from the end of its label, and how big its two strokes are.
const pager_arrow_gap = style.space.roomy;
const pager_arrow_half = style.space.tiny;
const pager_arrow_stroke = style.space.hair;
const family_rows = 2;
const family_columns_builtin = 2;
const family_columns_with_own = family_columns_builtin + 1;

/// Two columns for the Kindle's four typefaces; three once the reader's own join them.
fn family_columns(families: Families) u32 {
    const own = families.count() > settings_model.builtin_families.len;
    const result: u32 = if (own) family_columns_with_own else family_columns_builtin;
    assert(families.count() >= settings_model.builtin_families.len);
    assert(result * family_rows <= family_cells_max);
    return result;
}

/// The most cells the typefaces' grid has.
pub const family_cells_max = 3 * family_rows;

/// What the Aa sheet keeps from one book to the next, in the App: set as noface starts
/// to the chosen typeface's page (setup.zig), then the reader's controls change the tab
/// and the page turned to and draw from them (screens/reader/controls.zig), and the
/// reader reads the tab open (`Reader.sheet`).
pub const Kept = struct {
    tab: Tab = .font,
    family_first: u32 = 0, // The first typeface on the sheet's page of them
    family_sample_ptrs: [family_cells_max]?*Font = @splat(null),
};

/// Whether there are more typefaces than the grid has cells: then its last cell
/// turns it to the next page of them.
fn families_paged(families: Families) bool {
    const cells = family_columns(families) * family_rows;
    assert(cells <= family_cells_max);
    assert(cells >= settings_model.builtin_families.len);
    return families.count() > cells;
}

/// How many typefaces a page of the grid shows: all, or one fewer than its cells.
pub fn families_per_page(families: Families) u32 {
    const cells = family_columns(families) * family_rows;
    const result = if (families_paged(families)) cells - 1 else cells;
    assert(result > 0);
    assert(result <= family_cells_max);
    return result;
}

/// The first typeface of the page after the one starting at `first`, back to the
/// first page after the last.
pub fn next_family_page(families: Families, first: u32) u32 {
    const per_page = families_per_page(families);
    assert(first % per_page == 0);
    const next = first + per_page;
    const result: u32 = if (next < families.count()) next else 0;
    assert(result < families.count());
    return result;
}

/// The first typeface of the page that shows typeface `family`.
pub fn family_page_of(families: Families, family: u32) u32 {
    assert(family < families.count());
    const per_page = families_per_page(families);
    const result = family - family % per_page;
    assert(result <= family);
    return result;
}

fn family_width(families: Families) u32 {
    const result = (screen_width - 2 * margin) / family_columns(families);
    assert(result > 0);
    assert(result * family_columns(families) <= screen_width - 2 * margin);
    return result;
}
const toggle_height = style.fingertip - 2 * toggle_reach; // Its taps a fingertip
/// A switch's parts: its pill's middle, down from its top, which its label is centred
/// on; and the pill's size.
const toggle = struct {
    const middle_drop = style.space.small + style.space.medium;
    const width = style.space.band;
    const radius = style.space.medium;
};
/// A switch's taps reach this far above and below its drawn height.
const toggle_reach = style.space.snug;

/// The tiles share the width between the margins, a gap between each two.
const theme_count: comptime_int = themes.len;
const theme_width = (screen_width - 2 * margin - (theme_count - 1) * theme_gap) / theme_count;
const theme_gap = style.space.roomy;
/// A theme's tile, down from its top: the band its sample lines fill, its label's
/// baseline; the tick's middle in from its corner; and its lines' gap, margin and
/// thickness before a step of spacing, margins or size adds to them.
const tile = struct {
    const lines_top = style.space.wide;
    const lines_bottom = 2 * style.space.band;
    const label_drop = theme_height - style.space.roomy;
    const tick_inset = style.space.small + style.space.medium;
    const line_gap = style.space.snug;
    const line_gap_step = style.space.tiny;
    const lines_inset = style.space.medium;
    const lines_inset_step = style.space.snug;
    const line_thick = style.space.hair;
};
const theme_top = content_top + theme_gap_above;
const theme_gap_above = style.space.snug; // Between the tabs and the tiles
const theme_height = 2 * style.space.tall + style.space.roomy;
/// The note under the tiles when none is in use, faded: its baseline, down from the
/// tiles' foot.
const theme_note_drop = style.space.wide;
const theme_note_baseline = theme_top + theme_height + theme_note_drop;
/// The Running button, across the sheet under the tiles and their note.
const running_top = theme_note_baseline + running_gap;
const running_gap = style.space.medium; // Between the note's baseline and the Running button
/// The tiles side by side, from the left margin.
const themes_width = themes.len * theme_width + (themes.len - 1) * theme_gap;
const running_height = style.space.band;
/// A tile's or the Running button's edge when it's what's in use, and the sheet's black
/// edge along its foot.
const chosen_edge = 2 * style.border;
const sheet_edge = style.space.hair;
/// The Running button's label and the line under it: in from its left, and their
/// baselines down from its top.
const running_text_inset = style.space.roomy;
const running_label_drop = style.space.wide;
const running_note_drop = style.space.band;

pub const Theme = struct { label: []const u8, size: u32, spacing: u32, margin: u32 };
pub const themes = [_]Theme{
    .{ .label = "Compact", .size = 1, .spacing = 0, .margin = 0 },
    .{ .label = "Standard", .size = 2, .spacing = 1, .margin = 1 },
    // The steps of the reader's own scales (model/settings.zig)
    .{ .label = "Large", .size = 4, .spacing = 2, .margin = 2 },
};

const margin_names = [_][]const u8{ "Narrow", "Medium", "Wide", "Widest" };

comptime {
    assert(tab_labels.len == std.enums.values(Tab).len);
    assert(row_height >= style.fingertip);
    assert(row_baseline < row_bar);
    assert(row_bar < row_height);
    // A switch takes a fingertip, and the next one starts where its taps end
    assert(toggle_height + 2 * toggle_reach >= style.fingertip);
    assert(toggle_height + 2 * toggle_reach <= switch_step);
    // Every row of controls takes a fingertip's taps
    assert(tabs_height >= style.fingertip);
    assert(family_height >= style.fingertip);
    // The typefaces' first row reaches up into the gap under the tabs, not into them
    assert(family_reach_above <= tabs_gap);
    // Each tab's controls, top to bottom, end above its switches' taps
    assert(family_top + family_rows * family_height <= switches_top(.font) - toggle_reach);
    assert(spacing_row.top + row_height <= margin_row.top);
    assert(margin_row.top + row_height <= switches_top(.layout));
    // And everything ends inside the sheet
    assert(size_row.top + row_height <= height_for(.font));
    assert(theme_note_baseline < height_for(.themes));
    // The Running button is a fingertip and more, under the note, above the sheet's edge
    assert(running_height >= style.fingertip);
    assert(running_top + running_height + 4 <= height_for(.themes));
    for (switches, 0..) |sw, i| {
        assert(switch_top(i) + toggle_height + toggle_reach <= height_for(sw.tab));
        // A slider row and a switch never take the same taps: `hit` asks sliders first
        const taps_top = switch_top(i) - toggle_reach;
        const taps_end = switch_top(i) + toggle_height + toggle_reach;
        for ([_]Row{ size_row, spacing_row, margin_row }) |row| {
            if (sw.tab == slider_tab(row.slider)) {
                assert(taps_end <= row.top or row.top + row_height <= taps_top);
            }
        }
    }
    for (std.enums.values(Tab)) |tab| assert(height_for(tab) <= max_height);
    // The themes side by side between the margins, each a choice the sliders can make
    assert(margin + themes_width <= screen_width - margin);
    for (themes) |t| {
        assert(t.size < settings_model.sizes.len);
        assert(t.spacing < settings_model.spacings.len);
        assert(t.margin < settings_model.margins.len);
    }
    // No two themes alike, so at most one is ever in use
    for (themes[0 .. themes.len - 1], themes[1..]) |a, b| assert(a.size != b.size);
    assert(margin_names.len == settings_model.margins.len);
    // The Kindle's typefaces fill two columns, and a page of three shows one more
    assert(2 * family_rows == settings_model.builtin_families.len);
    assert(family_cells_max - 1 > settings_model.builtin_families.len);
}

fn row_slider(r: Row) slider.Slider {
    assert(r.steps >= 2);
    assert(r.top >= content_top);
    const inset = style.slider_inset;
    return .{ .left = inset, .right = screen_width - inset, .y = r.top + row_bar };
}

/// Where a tap sets a row's slider to `step`: on its tick, down the row's middle.
pub fn step_place(r: Row, step: u32) style.Point {
    assert(step < r.steps);
    const x = slider.knob_at(row_slider(r), step, r.steps - 1);
    const point: style.Point = .{ .x = @intCast(x), .y = row_middle(r) };
    assert(step_at(r, point.x) == step);
    assert(std.meta.eql(hit(slider_tab(r.slider), .{}, point.x, point.y), slider_hit(r.slider)));
    return point;
}

fn slider_hit(s: Slider) Hit {
    return switch (s) {
        .text_size => .text_size,
        .spacing => .spacing,
        .margins => .margins,
    };
}

/// The middle of the typefaces' grid's cell `cell`, counted from its page's first, on
/// the Font tab: with `families` that page, the cell after a page's last typeface turns
/// the grid to its next page.
pub fn family_place(families: Families, cell: u32) style.Point {
    const cols = family_columns(families);
    assert(cell < cols * family_rows);
    const width: i32 = @intCast(family_width(families));
    const col: i32 = @intCast(cell % cols);
    const row: i32 = @intCast(cell / cols);
    const point: style.Point = .{
        .x = margin + col * width + @divTrunc(width, 2),
        .y = family_top + row * family_height + family_height / 2,
    };
    const expected: Hit = if (families_paged(families) and cell == families_per_page(families))
        .more_families
    else
        .{ .family = cell };
    assert(std.meta.eql(hit(.font, families, point.x, point.y), expected));
    return point;
}

/// Step for a finger at `x` on a row's slider.
pub fn step_at(r: Row, x: i32) u32 {
    const step = slider.value_at(row_slider(r), x, r.steps - 1);
    assert(step < r.steps);
    return step;
}

fn within(y: i32, from: i32, size: i32) bool {
    assert(size > 0);
    return y >= from and y < from + size;
}

/// A switch row's taps: its drawn height grown to a fingertip, half
/// above and half below.
fn on_toggle(y: i32, toggle_top: i32) bool {
    assert(toggle_top >= content_top);
    return within(y, toggle_top - toggle_reach, toggle_height + 2 * toggle_reach);
}

/// The middle of a control's taps on tab `tab` of the sheet: its tabs, on any of them,
/// the themes and the Running button, on Themes, and a switch, on its own tab.
pub fn place(tab: Tab, h: Hit) style.Point {
    const point: style.Point = switch (h) {
        .tab => |t| tab: {
            const cell: i32 = screen_width / tab_labels.len;
            const index: i32 = @intCast(@backingInt(t));
            break :tab .{ .x = index * cell + @divTrunc(cell, 2), .y = top + tabs_height / 2 };
        },
        .running => running: {
            assert(tab == .themes); // Only that tab has it
            const y = running_top + running_height / 2;
            break :running .{ .x = margin + themes_width / 2, .y = y };
        },
        .theme => |i| theme: {
            assert(tab == .themes); // Only that tab has them
            assert(i < themes.len);
            const left: i32 = margin + @as(i32, @intCast(i)) * (theme_width + theme_gap);
            break :theme .{ .x = left + theme_width / 2, .y = theme_top + theme_height / 2 };
        },
        .toggle => |i| toggle_place: {
            assert(i < switches.len);
            assert(switches[i].tab == tab); // On the tab it's on
            const y: i32 = @intCast(switch_top(@intCast(i)) + toggle_height / 2);
            break :toggle_place .{ .x = screen_width / 2, .y = y };
        },
        // Placed by tests of their own, where they're laid out for typefaces and sizes
        .none, .family, .more_families, .text_size, .spacing, .margins => unreachable,
    };
    assert(std.meta.eql(hit(tab, .{}, point.x, point.y), h));
    return point;
}

pub fn hit(tab: Tab, families: Families, x: i32, y: i32) Hit {
    if (y < top + tabs_height) {
        const cell: i32 = screen_width / tab_labels.len;
        const at = @divTrunc(std.math.clamp(x, @as(i32, 0), screen_width - 1), cell);
        assert(at >= 0);
        assert(at < tab_labels.len);
        return .{ .tab = @fromBackingInt(@intCast(at)) };
    }
    switch (tab) {
        .themes => {
            if (within(y, running_top, running_height)) {
                if (x >= margin and x < margin + themes_width) return .running;
                return .none;
            }
            if (!within(y, theme_top, theme_height)) return .none;
            for (0..themes.len) |i| {
                const left: i32 = margin + @as(i32, @intCast(i)) * (theme_width + theme_gap);
                if (x >= left and x < left + theme_width) return .{ .theme = @intCast(i) };
            }
        },
        .font => {
            // The first row reaches up to the tabs, so both rows take a full fingertip
            const reach = family_reach_above;
            if (within(y, family_top - reach, family_rows * family_height + reach)) {
                return hit_family(families, x, y);
            }
            if (within(y, size_row.top, row_height)) return .text_size;
        },
        .layout => {
            if (within(y, spacing_row.top, row_height)) return .spacing;
            if (within(y, margin_row.top, row_height)) return .margins;
        },
        .more => {},
    }
    for (switches, 0..) |sw, i| {
        if (sw.tab == tab and on_toggle(y, @intCast(switch_top(@intCast(i))))) {
            return .{ .toggle = @intCast(i) };
        }
    }
    return .none;
}

/// Which cell of the typefaces' grid a tap is on, if one of them is there, or the cell
/// that turns it to the next page.
fn hit_family(families: Families, x: i32, y: i32) Hit {
    const below_top: i32 = @max(y - family_top, 0);
    const row_reached: u32 = @intCast(@divTrunc(below_top, family_height));
    const row = @min(row_reached, family_rows - 1);
    const cols = family_columns(families);
    const in_from_margin: i32 = @max(x - margin, 0);
    const col = @min(@as(u32, @intCast(in_from_margin)) / family_width(families), cols - 1);
    assert(row < family_rows);
    assert(col < cols);
    const i = row * cols + col;
    if (families_paged(families) and i == families_per_page(families)) return .more_families;
    // A cell past the last typeface on the last page is checked by the caller, which
    // knows the page
    const shown = @min(families_per_page(families), families.count());
    return if (i < shown) .{ .family = i } else .none;
}

fn draw_toggle(fonts: Fonts, page: Page, y: u32, label: []const u8, on: bool) !void {
    assert(y >= content_top);
    assert(y + toggle_height <= max_height);
    const baseline = fonts.small.centred_on(@intCast(y + toggle.middle_drop));
    try fonts.small.draw(page, margin, baseline, label);
    // A rounded switch: filled with a white knob on the right when on, outlined with a
    // black knob on the left when off
    const w: f32 = toggle.width;
    const r: f32 = toggle.radius;
    const right: f32 = @floatFromInt(page.width - margin);
    const ends = [2]f32{ right - w + r, right - r };
    const cy: f32 = @floatFromInt(y + toggle.middle_drop);
    // Cleared first: a knob's smooth edge outside the pill, and some slack each side
    const slack = style.stroke;
    const clear_top = y + toggle.middle_drop - @as(u32, @intFromFloat(r)) - slack;
    const clear_height: u32 = @intFromFloat(2 * r + 2 * slack);
    const clear_left: u32 = @intFromFloat(ends[0] - r - slack);
    page.fill_rect(clear_left, clear_top, @intFromFloat(w + 2 * slack), clear_height, style.white);
    page.pill(ends[0], ends[1], cy, r, style.black);
    // On: a white knob inside the black pill. Off: an outlined pill, its knob black
    const outline: f32 = style.border;
    const knob_gap: f32 = 2 * style.border;
    if (on) {
        page.pill(ends[1], ends[1], cy, r - knob_gap, style.white);
    } else {
        page.pill(ends[0], ends[1], cy, r - outline, style.white);
        page.pill(ends[0], ends[0], cy, r - outline - knob_gap, style.black);
    }
}

/// What a slider is set to, in words or numbers a reader knows.
pub fn value_label(buf: []u8, r: Row, value: u32) []const u8 {
    assert(r.steps >= 2);
    assert(buf.len >= "99 of 99".len);
    return switch (r.slider) {
        .text_size => std.fmt.bufPrint(buf, "{d} of {d}", .{ value + 1, r.steps }) catch "",
        .spacing => std.fmt.bufPrint(buf, "{d:.2}", .{settings_model.spacings[value]}) catch "",
        .margins => margin_names[@min(value, margin_names.len - 1)],
    };
}

/// One slider row, redrawn alone while dragging.
pub fn draw_row(fonts: Fonts, page: Page, r: Row, value: u32, mono: bool) !void {
    assert(r.top >= content_top);
    assert(r.top + row_height <= max_height);
    page.fill_rect(0, r.top, page.width, row_height, 0xff);
    try fonts.small.draw(page, margin, @intCast(r.top + row_baseline), r.label);
    var buf: [24]u8 = undefined;
    const shown = value_label(&buf, r, value);
    const right: f32 = @floatFromInt(page.width - margin);
    const shown_left = right - try fonts.small.measure(shown);
    try fonts.small.draw(page, shown_left, @intCast(r.top + row_baseline), shown);
    const bar = row_slider(r);
    const max: u32 = r.steps - 1;
    const knob = slider.knob_at(bar, value, max);
    slider.draw(page, bar, knob);
    slider.draw_ticks(page, bar, max, knob);
    if (mono) page.threshold(r.top, row_height);
}

fn draw_tabs(fonts: Fonts, page: Page, tab: Tab) !void {
    assert(@backingInt(tab) < tab_labels.len);
    const cell: u32 = page.width / @as(u32, tab_labels.len);
    assert(cell * tab_labels.len <= page.width);
    for (tab_labels, 0..) |label, i| {
        const left: u32 = @as(u32, @intCast(i)) * cell;
        const active = i == @backingInt(tab);
        const centre: f32 = @floatFromInt(left + cell / 2);
        const baseline = fonts.small.centred_baseline(top, tabs_height);
        const underline: u32 = @intCast(baseline + tab_label.underline_below);
        try draw.choice(fonts, page, centre, .center, baseline, label, active, underline);
        const inset = tab_label.tint_inset;
        if (!active) fonts.small.fade(page, left + inset, baseline, cell - 2 * inset, style.faded);
    }
    page.fill_rect(0, top + tabs_height - 2, page.width, 1, style.rule);
}

fn draw_themes(fonts: Fonts, page: Page, chosen: settings_model.Settings) !void {
    var active_count: u32 = 0;
    for (themes, 0..) |t, i| {
        const left: u32 = margin + @as(u32, @intCast(i)) * (theme_width + theme_gap);
        const active = chosen.size == t.size and
            chosen.spacing == t.spacing and
            chosen.margin == t.margin;
        active_count += @intFromBool(active);
        try draw_themes_tile(fonts, page, t, left, active);
    }
    // No two themes are the same, so at most one is in use
    assert(active_count <= 1);
    // Sizes changed by hand match none of them; say so, so no tile seems forgotten
    if (active_count == 0) {
        const note = "Using your own settings. Pick a theme to switch to it.";
        try fonts.caption.draw(page, margin, theme_note_baseline, note);
        // Its letters, and so its faded band, end above the Running button
        assert(theme_note_baseline + fonts.caption.descent <= running_top);
        fonts.caption.fade(page, margin, theme_note_baseline, page.width - 2 * margin, style.faded);
    }
}

/// The Running button: running mode on, or, while it's on, off again.
fn draw_running(fonts: Fonts, page: Page, running: bool) !void {
    const width = themes_width; // Lined up with the tiles above
    const edge: u32 = if (running) chosen_edge else style.stroke;
    draw.box_with(page, margin, running_top, width, running_height, edge, style.button_corner);
    const label = if (running) "Stop running" else "Running";
    const note = if (running)
        "Back to the page"
    else
        "A sentence at a time, large and still, at your pace, for a treadmill";
    const text_left = margin + running_text_inset;
    try fonts.title.draw(page, text_left, running_top + running_label_drop, label);
    try fonts.caption.draw(page, text_left, running_top + running_note_drop, note);
}

/// One theme's tile: rounded, with a thick edge and a tick in its corner when in use.
fn draw_themes_tile(fonts: Fonts, page: Page, t: Theme, left: u32, active: bool) !void {
    assert(left >= margin);
    assert(left + theme_width <= screen_width - margin);
    const edge: u32 = if (active) chosen_edge else style.stroke;
    draw.box_with(page, left, theme_top, theme_width, theme_height, edge, style.button_corner);
    const tick = tile.tick_inset;
    if (active) icons.check(page, @floatFromInt(left + theme_width - tick), theme_top + tick);
    // Text lines drawn to scale, so the choice shows rather than tells: a step of the
    // setting is this much more of each
    const gap: u32 = tile.line_gap + t.spacing * tile.line_gap_step;
    const inset: u32 = tile.lines_inset + t.margin * tile.lines_inset_step;
    const thick: u32 = tile.line_thick + t.size;
    var y: u32 = theme_top + tile.lines_top;
    while (y < theme_top + tile.lines_bottom) : (y += gap + thick) {
        page.fill_rect(left + inset, y, theme_width - 2 * inset, thick, style.quiet);
    }
    const centre: f32 = @floatFromInt(left + theme_width / 2);
    try draw.centered(fonts.small, page, centre, theme_top + tile.label_drop, t.label);
}

/// The typefaces' grid, the page of it from `fonts.family_first`, and the size row.
/// With more typefaces than cells, the last cell turns the grid to its next page.
fn draw_font(fonts: Fonts, page: Page, chosen: settings_model.Settings) !void {
    const families = fonts.family_names;
    const first = fonts.family_first;
    const per_page = families_per_page(families);
    assert(first % per_page == 0);
    assert(first < families.count());
    const shown = @min(per_page, families.count() - first);
    for (0..shown) |cell| {
        const index: u32 = first + @as(u32, @intCast(cell));
        // The name in its own typeface, when it's loaded
        const own = if (cell < fonts.families.len) fonts.families[cell] else null;
        const name = families.names[index];
        const is_chosen = index == chosen.family_index(families);
        try draw_family(fonts, page, @intCast(cell), name, own, is_chosen);
    }
    if (families_paged(families)) try draw_family_pager(fonts, page, first);
    try draw_row(fonts, page, size_row, chosen.size, false);
}

/// The grid's last cell, when it turns the page: "2 of 3" and an arrow, as every list
/// shown a page at a time has.
fn draw_family_pager(fonts: Fonts, page: Page, first: u32) !void {
    const families = fonts.family_names;
    const per_page = families_per_page(families);
    assert(families_paged(families));
    assert(first % per_page == 0);
    const count: u32 = @intCast(families.count());
    const pages = (count + per_page - 1) / per_page; // Rounded up: the last may be short
    assert(pages > 1);
    var buffer: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ first / per_page + 1, pages });
    try draw_family(fonts, page, per_page, label, null, false);
    const cols = family_columns(families);
    const left: f32 = @floatFromInt(margin + per_page % cols * family_width(families));
    // The arrow's middle on the label's capitals' middle, which is the cell's
    const cell_top = family_top + per_page / cols * family_height;
    const mid: f32 = @floatFromInt(cell_top + family_height / 2);
    const x = left + try fonts.small.measure(label) + pager_arrow_gap;
    const h = pager_arrow_half;
    page.stroke(x - h, mid - 2 * h, x + h, mid, pager_arrow_stroke);
    page.stroke(x + h, mid, x - h, mid + 2 * h, pager_arrow_stroke);
}

/// A typeface's name in cell `cell` of the grid, in `own` when it's loaded, else in the
/// interface's; underlined when chosen.
fn draw_family(
    fonts: Fonts,
    page: Page,
    cell: u32,
    name: []const u8,
    own: ?*Font,
    chosen: bool,
) !void {
    const families = fonts.family_names;
    const cols = family_columns(families);
    const row: u32 = cell / cols;
    const left: u32 = margin + cell % cols * family_width(families);
    const y = family_top + row * family_height;
    assert(row < family_rows);
    assert(name.len > 0);
    if (own) |font| {
        const avail: f32 = @floatFromInt(family_width(families) - family_name_gap);
        const baseline = font.centred_baseline(@intCast(y), family_height);
        try draw.clipped(font, page, @floatFromInt(left), baseline, name, avail);
        if (chosen) {
            const width: u32 = @intFromFloat(@min(try font.measure(name), avail));
            const underline: u32 = @intCast(baseline + family_underline_below);
            page.fill_rect(left, underline, width, style.underline, style.black);
        }
    } else {
        const x: f32 = @floatFromInt(left);
        const baseline = fonts.small.centred_baseline(@intCast(y), family_height);
        const underline: u32 = @intCast(baseline + family_underline_below);
        try draw.choice(fonts, page, x, .left, baseline, name, chosen, underline);
    }
}

pub fn render(
    fonts: Fonts,
    page: Page,
    tab: Tab,
    chosen: settings_model.Settings,
    running: bool,
) !void {
    const height = height_for(tab);
    assert(height > top);
    page.fill_rect(0, top, page.width, height - top, 0xff);
    page.fill_rect(0, height - sheet_edge, page.width, sheet_edge, style.black);
    try draw_tabs(fonts, page, tab);
    switch (tab) {
        .themes => {
            try draw_themes(fonts, page, chosen);
            try draw_running(fonts, page, running);
        },
        .font => try draw_font(fonts, page, chosen),
        .layout => {
            try draw_row(fonts, page, spacing_row, chosen.spacing, false);
            try draw_row(fonts, page, margin_row, chosen.margin, false);
        },
        .more => {},
    }
    for (switches, 0..) |sw, i| {
        if (sw.tab != tab) continue;
        const on = is_on(@intCast(i), chosen);
        try draw_toggle(fonts, page, switch_top(@intCast(i)), sw.label, on);
    }
}

/// The middle of switch `i`.
fn test_switch_middle(i: u32) i32 {
    return @intCast(switch_top(i) + toggle_height / 2);
}

const test_x = screen_width / 2; // Across the sheet, clear of anything at its sides

test "with the reader's own typefaces, three to a row" {
    const families = Families.offer(&(settings_model.builtin_families ++ .{"Literata"}));
    for (0..5) |cell| {
        const at = family_place(families, @intCast(cell));
        try std.testing.expectEqual(
            Hit{ .family = @intCast(cell) },
            hit(.font, families, at.x, at.y),
        );
    }
    // No sixth
    // The second row's third cell: the first row's third, down to the second row
    const sixth_x = family_place(families, 2).x;
    const sixth_y = family_place(families, 3).y;
    try std.testing.expectEqual(Hit.none, hit(.font, families, sixth_x, sixth_y));
    try std.testing.expectEqual(@as(u32, 6), families_per_page(families));
}

test "with more typefaces than cells, the last cell turns the page, round to the first" {
    const own = .{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K" };
    const families = Families.offer(&(settings_model.builtin_families ++ own));
    const last = family_place(families, 5);
    try std.testing.expectEqual(Hit.more_families, hit(.font, families, last.x, last.y));
    const fifth = family_place(families, 4);
    try std.testing.expectEqual(Hit{ .family = 4 }, hit(.font, families, fifth.x, fifth.y));
    try std.testing.expectEqual(@as(u32, 5), families_per_page(families));
    // Fifteen typefaces, five a page
    try std.testing.expectEqual(@as(u32, 5), next_family_page(families, 0));
    try std.testing.expectEqual(@as(u32, 10), next_family_page(families, 5));
    try std.testing.expectEqual(@as(u32, 0), next_family_page(families, 10));
    try std.testing.expectEqual(@as(u32, 10), family_page_of(families, 14));
    try std.testing.expectEqual(@as(u32, 5), family_page_of(families, 5));
}

test "the tabs' and the Running button's places are taps on them" {
    for (std.enums.values(Tab)) |open| {
        for (std.enums.values(Tab)) |t| {
            const p = place(open, .{ .tab = t });
            try std.testing.expectEqual(Hit{ .tab = t }, hit(open, .{}, p.x, p.y));
        }
    }
    const run = place(.themes, .running);
    try std.testing.expectEqual(Hit.running, hit(.themes, .{}, run.x, run.y));
}

test "tabs split the top row evenly" {
    const families: Families = .{}; // The Kindle's typefaces alone
    const cell = screen_width / tab_labels.len;
    const y = top + tabs_height / 2;
    for (std.enums.values(Tab), 0..) |t, i| {
        const x: i32 = @intCast(i * cell + cell / 2);
        try std.testing.expectEqual(Hit{ .tab = t }, hit(.font, families, x, y));
    }
}

test "each tab maps its own controls" {
    const families: Families = .{}; // The Kindle's typefaces alone
    for (0..themes.len) |i| {
        const x: i32 = @intCast(margin + i * (theme_width + theme_gap) + theme_width / 2);
        const y = theme_top + theme_height / 2;
        try std.testing.expectEqual(Hit{ .theme = @intCast(i) }, hit(.themes, families, x, y));
    }
    for (0..4) |cell| {
        const at = family_place(families, @intCast(cell));
        try std.testing.expectEqual(
            Hit{ .family = @intCast(cell) },
            hit(.font, families, at.x, at.y),
        );
    }
    try std.testing.expectEqual(
        Hit.text_size,
        hit(.font, families, test_x, row_middle(size_row)),
    );
    try std.testing.expectEqual(
        Hit.spacing,
        hit(.layout, families, test_x, row_middle(spacing_row)),
    );
    try std.testing.expectEqual(
        Hit.margins,
        hit(.layout, families, test_x, row_middle(margin_row)),
    );
    // Every switch answers on its own tab, where it's drawn
    for (switches, 0..) |sw, i| {
        const y = test_switch_middle(@intCast(i));
        try std.testing.expectEqual(Hit{ .toggle = @intCast(i) }, hit(sw.tab, families, test_x, y));
    }
    const running_y = running_top + running_height / 2;
    try std.testing.expectEqual(Hit.running, hit(.themes, families, test_x, running_y));
}

test "the sheet stays inside itself" {
    try std.testing.expect(size_row.top + row_height <= height_for(.font));
    // A switch added to a full tab shows here before it's drawn past the sheet
    for (switches, 0..) |sw, i| {
        const bottom = switch_top(@intCast(i)) + toggle_height + toggle_reach;
        try std.testing.expect(bottom <= height_for(sw.tab));
    }
    try std.testing.expect(theme_top + theme_height <= height_for(.themes));
}

test "switches and fonts take a fingertip of height" {
    const families: Families = .{}; // The Kindle's typefaces alone
    // Inside a switch's reach above and below what's drawn of it, and above the grid
    const bold = switch_for("bold");
    const bold_top: i32 = @intCast(switch_top(bold));
    const reach: i32 = toggle_reach;
    // The first switch on Font reaches up to the typefaces' grid, its gap's worth
    const up_to_grid = bold_top - family_gap;
    try std.testing.expectEqual(Hit{ .toggle = bold }, hit(.font, families, test_x, up_to_grid));
    const bold_foot = bold_top + toggle_height + reach - 1;
    try std.testing.expectEqual(Hit{ .toggle = bold }, hit(.font, families, test_x, bold_foot));
    const clock = switch_for("clock");
    const clock_top: i32 = @intCast(switch_top(clock));
    const clock_reach = clock_top - reach + 1;
    try std.testing.expectEqual(Hit{ .toggle = clock }, hit(.more, families, test_x, clock_reach));
    const first = family_place(families, 0);
    const above: i32 = family_top - family_reach_above + 1;
    try std.testing.expectEqual(Hit{ .family = 0 }, hit(.font, families, first.x, above));
}

test "sliders say what they're set to" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1.35", value_label(&buf, spacing_row, 1));
    try std.testing.expectEqualStrings("Narrow", value_label(&buf, margin_row, 0));
    try std.testing.expectEqualStrings("3 of 6", value_label(&buf, size_row, 2));
}

test "every control on every tab takes a fingertip of taps, top to bottom" {
    const families: Families = .{}; // The Kindle's typefaces alone
    // Down the first column, where every row of every tab has a control, each run of
    // taps landing on one control is a fingertip tall at least
    const x: i32 = @intCast(margin + family_width(families) / 2);
    for (std.enums.values(Tab)) |tab| {
        var run_start: i32 = 0;
        var run_hit: Hit = .none;
        const foot: i32 = @intCast(height_for(tab));
        var y: i32 = 0;
        while (y <= foot) : (y += 1) {
            const h = if (y < foot) hit(tab, families, x, y) else Hit.none;
            if (std.meta.eql(h, run_hit)) continue;
            if (run_hit != .none) {
                try std.testing.expect(y - run_start >= style.fingertip);
            }
            run_start = y;
            run_hit = h;
        }
    }
}

test "a switch keeps a fingertip's taps where a slider row is next to it" {
    const families: Families = .{}; // The Kindle's typefaces alone
    // Sliders are asked first, so a row running into a switch's reach took its taps
    const bold_starts = switch_for("bold_starts");
    const bold_starts_end: i32 = @intCast(switch_top(bold_starts) + toggle_height + toggle_reach);
    const last_tap = bold_starts_end - 1;
    try std.testing.expectEqual(
        Hit{ .toggle = bold_starts },
        hit(.font, families, test_x, last_tap),
    );
    try std.testing.expectEqual(Hit.text_size, hit(.font, families, test_x, bold_starts_end));
    const left_align = switch_for("left_align");
    const left_align_top: i32 = @intCast(switch_top(left_align) - toggle_reach);
    try std.testing.expectEqual(
        Hit{ .toggle = left_align },
        hit(.layout, families, test_x, left_align_top),
    );
    try std.testing.expectEqual(Hit.margins, hit(.layout, families, test_x, left_align_top - 1));
}
