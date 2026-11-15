//! The Aa sheet: reading settings, in four tabs.
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("../model/settings.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;
const slider = @import("slider.zig");
const icons = @import("icons.zig");

const top = 228; // Under the toolbar
const tabs_height = 92;
/// Where the sheet ends on screen: lower on More, which has a row more.
pub fn height_for(tab: Tab) u32 {
    const result: u32 = if (tab == .more or tab == .font) max_height else 760;
    assert(result > content_top);
    assert(result <= max_height);
    return result;
}
pub const max_height = 860;
const margin = style.margin;
const screen_width = style.screen_width;
const content_top = top + tabs_height + 16;

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
        .label = "Page refresh every 20 pages",
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
        .font => content_top + 186, // Under the typefaces
        .layout => content_top + 292, // Under the two sliders
        .more => content_top + 8,
    };
    assert(result >= content_top);
    assert(result < height_for(tab));
    return result;
}

const switch_step = 100;

/// Where switch `i` sits: a step under the switches before it on its tab.
pub fn switch_top(i: u32) u32 {
    assert(i < switches.len);
    var before: u32 = 0;
    for (switches[0..i]) |sw| before += @intFromBool(sw.tab == switches[i].tab);
    const result = switches_top(switches[i].tab) + before * switch_step;
    assert(result >= switches_top(switches[i].tab));
    return result;
}

pub const Row = struct { hit: Hit, label: []const u8, top: u32, steps: u32 };
pub const size_row = Row{
    .hit = .text_size,
    .label = "Text size",
    .top = content_top + 356,
    .steps = settings_model.sizes.len,
};
pub const spacing_row = Row{
    .hit = .spacing,
    .label = "Line spacing",
    .top = content_top,
    .steps = settings_model.spacings.len,
};
pub const margin_row = Row{
    .hit = .margins,
    .label = "Margins",
    .top = content_top + 146,
    .steps = settings_model.margins.len,
};
pub const row_height = 146;
const row_baseline = 48; // From a slider row's top to its label's baseline
const row_bar = 92; // From a slider row's top to its bar

const family_top = content_top;
const family_height = 88;
const family_rows = 2;

/// Two columns for the Kindle's four typefaces; three once the reader's own join them.
fn family_columns() u32 {
    const result: u32 = if (settings_model.families.len > 4) 3 else 2;
    assert(settings_model.families.len >= settings_model.builtin_families.len);
    assert(result * family_rows <= family_cells_max);
    return result;
}

/// The most cells the typefaces' grid has.
pub const family_cells_max = 3 * family_rows;

/// Whether there are more typefaces than the grid has cells: then its last cell
/// turns it to the next page of them.
fn families_paged() bool {
    const cells = family_columns() * family_rows;
    assert(cells <= family_cells_max);
    assert(cells >= settings_model.builtin_families.len);
    return settings_model.families.len > cells;
}

/// How many typefaces a page of the grid shows: all, or one fewer than its cells.
pub fn families_per_page() u32 {
    const cells = family_columns() * family_rows;
    const result = if (families_paged()) cells - 1 else cells;
    assert(result > 0);
    assert(result <= family_cells_max);
    return result;
}

/// The first typeface of the page after the one starting at `first`, back to the
/// first page after the last.
pub fn next_family_page(first: u32) u32 {
    const per_page = families_per_page();
    assert(first % per_page == 0);
    const next = first + per_page;
    const result: u32 = if (next < settings_model.families.len) next else 0;
    assert(result < settings_model.families.len);
    return result;
}

/// The first typeface of the page that shows typeface `family`.
pub fn family_page_of(family: u32) u32 {
    assert(family < settings_model.families.len);
    const per_page = families_per_page();
    const result = family - family % per_page;
    assert(result <= family);
    return result;
}

fn family_width() u32 {
    const result = (screen_width - 2 * margin) / family_columns();
    assert(result > 0);
    assert(result * family_columns() <= screen_width - 2 * margin);
    return result;
}
const toggle_height = 76;
const toggle_reach = 12; // Taps reach this far above and below a switch's drawn height

const theme_width = 340;
const theme_gap = 34;
const theme_top = content_top + 20;
const theme_height = 300;
const theme_note_baseline = theme_top + theme_height + 52; // Under them, when none is in use

pub const Theme = struct { label: []const u8, size: u32, spacing: u32, margin: u32 };
pub const themes = [_]Theme{
    .{ .label = "Compact", .size = 1, .spacing = 0, .margin = 0 },
    .{ .label = "Standard", .size = 2, .spacing = 1, .margin = 1 },
    .{ .label = "Large", .size = 4, .spacing = 2, .margin = 2 },
};

const margin_names = [_][]const u8{ "Narrow", "Medium", "Wide", "Widest" };

comptime {
    assert(tab_labels.len == std.enums.values(Tab).len);
    assert(row_height >= 100); // A fingertip
    assert(row_baseline < row_bar);
    assert(row_bar < row_height);
    // A switch takes a fingertip, and the next one starts where its taps end
    assert(toggle_height + 2 * toggle_reach >= 100);
    assert(toggle_height + 2 * toggle_reach <= switch_step);
    // Each tab's controls, top to bottom, end above its switches
    assert(family_top + family_rows * family_height <= switches_top(.font));
    assert(spacing_row.top + row_height <= margin_row.top);
    assert(margin_row.top + row_height <= switches_top(.layout));
    // And everything ends inside the sheet
    assert(size_row.top + row_height <= height_for(.font));
    assert(theme_note_baseline < height_for(.themes));
    for (switches, 0..) |sw, i| {
        assert(switch_top(i) + toggle_height + toggle_reach <= height_for(sw.tab));
    }
    for (std.enums.values(Tab)) |tab| assert(height_for(tab) <= max_height);
    // The themes side by side between the margins, each a choice the sliders can make
    const themes_width = themes.len * theme_width + (themes.len - 1) * theme_gap;
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
    return .{ .left = 110, .right = 1162, .y = r.top + row_bar };
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

/// A switch row's taps: its 76 px drawn height grown to a fingertip (100 px), half
/// above and half below.
fn on_toggle(y: i32, toggle_top: i32) bool {
    assert(toggle_top >= content_top);
    return within(y, toggle_top - toggle_reach, toggle_height + 2 * toggle_reach);
}

pub fn hit(tab: Tab, x: i32, y: i32) Hit {
    if (y < top + tabs_height) {
        const cell: i32 = screen_width / tab_labels.len;
        const at = @divTrunc(std.math.clamp(x, @as(i32, 0), screen_width - 1), cell);
        assert(at >= 0);
        assert(at < tab_labels.len);
        return .{ .tab = @fromBackingInt(@intCast(at)) };
    }
    switch (tab) {
        .themes => {
            if (!within(y, theme_top, theme_height)) return .none;
            for (0..themes.len) |i| {
                const left: i32 = margin + @as(i32, @intCast(i)) * (theme_width + theme_gap);
                if (x >= left and x < left + theme_width) return .{ .theme = @intCast(i) };
            }
        },
        .font => {
            // The first row reaches up to the tabs, so both rows take a full fingertip
            if (within(y, family_top - 12, family_rows * family_height + 12)) {
                return hit_family(x, y);
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
fn hit_family(x: i32, y: i32) Hit {
    const row_reached: u32 = @intCast(@divTrunc(@max(y - family_top, 0), family_height));
    const row = @min(row_reached, family_rows - 1);
    const cols = family_columns();
    const col = @min(@as(u32, @intCast(@max(x - margin, 0))) / family_width(), cols - 1);
    assert(row < family_rows);
    assert(col < cols);
    const i = row * cols + col;
    if (families_paged() and i == families_per_page()) return .more_families;
    // A cell past the last typeface on the last page is checked by the caller, which
    // knows the page
    const shown = @min(families_per_page(), settings_model.families.len);
    return if (i < shown) .{ .family = i } else .none;
}

fn draw_toggle(fonts: Fonts, page: Page, y: u32, label: []const u8, on: bool) !void {
    assert(y >= content_top);
    assert(y + toggle_height <= max_height);
    try fonts.small.draw(page, margin, @intCast(y + 50), label);
    // A rounded switch: filled with a white knob on the right when on, outlined with a
    // black knob on the left when off
    const w: f32 = 104;
    const r: f32 = 26;
    const right: f32 = @floatFromInt(page.width - margin);
    const ends = [2]f32{ right - w + r, right - r };
    const cy: f32 = @floatFromInt(y + 38);
    page.fill_rect(@intFromFloat(ends[0] - r - 2), y + 10, @intFromFloat(w + 4), 56, 0xff);
    page.pill(ends[0], ends[1], cy, r, 0x00);
    if (on) {
        page.pill(ends[1], ends[1], cy, r - 6, 0xff);
    } else {
        page.pill(ends[0], ends[1], cy, r - 3, 0xff);
        page.pill(ends[0], ends[0], cy, r - 9, 0x00);
    }
}

/// What a slider is set to, in words or numbers a reader knows.
pub fn value_label(buf: []u8, r: Row, value: u32) []const u8 {
    assert(r.steps >= 2);
    assert(buf.len >= "99 of 99".len);
    return switch (r.hit) {
        .spacing => std.fmt.bufPrint(buf, "{d:.2}", .{settings_model.spacings[value]}) catch "",
        .margins => margin_names[@min(value, margin_names.len - 1)],
        else => std.fmt.bufPrint(buf, "{d} of {d}", .{ value + 1, r.steps }) catch "",
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
        try draw.choice(fonts, page, centre, .center, top + 60, label, active, top + 78);
        if (!active) page.tint(left + 8, top + 20, cell - 16, 54, style.faded);
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
        const note_top = theme_top + theme_height + 22;
        page.tint(margin, note_top, page.width - 2 * margin, 40, style.faded);
    }
}

/// One theme's tile: rounded, with a thick edge and a tick in its corner when in use.
fn draw_themes_tile(fonts: Fonts, page: Page, t: Theme, left: u32, active: bool) !void {
    assert(left >= margin);
    assert(left + theme_width <= screen_width - margin);
    const edge: u32 = if (active) 6 else 2;
    draw.box_with(page, left, theme_top, theme_width, theme_height, edge, style.button_corner);
    if (active) icons.check(page, @floatFromInt(left + theme_width - 38), theme_top + 38);
    // Text lines drawn to scale, so the choice shows rather than tells.
    const gap: u32 = 16 + t.spacing * 8;
    const inset: u32 = 28 + t.margin * 16;
    const thick: u32 = 5 + t.size;
    var y: u32 = theme_top + 44;
    while (y < theme_top + 204) : (y += gap + thick) {
        page.fill_rect(left + inset, y, theme_width - 2 * inset, thick, style.quiet);
    }
    const centre: f32 = @floatFromInt(left + theme_width / 2);
    try draw.centered(fonts.small, page, centre, theme_top + 264, t.label);
}

/// The typefaces' grid, the page of it from `fonts.family_first`, and the size row.
/// With more typefaces than cells, the last cell turns the grid to its next page.
fn draw_font(fonts: Fonts, page: Page, chosen: settings_model.Settings) !void {
    const first = fonts.family_first;
    const per_page = families_per_page();
    assert(first % per_page == 0);
    assert(first < settings_model.families.len);
    const shown = @min(per_page, settings_model.families.len - first);
    for (0..shown) |cell| {
        const index: u32 = first + @as(u32, @intCast(cell));
        // The name in its own typeface, when it's loaded
        const own = if (cell < fonts.families.len) fonts.families[cell] else null;
        const name = settings_model.families[index];
        try draw_family(fonts, page, @intCast(cell), name, own, index == chosen.font);
    }
    if (families_paged()) try draw_family_pager(fonts, page, first);
    try draw_row(fonts, page, size_row, chosen.size, false);
}

/// The grid's last cell, when it turns the page: "2 of 3" and an arrow, as every list
/// shown a page at a time has.
fn draw_family_pager(fonts: Fonts, page: Page, first: u32) !void {
    const per_page = families_per_page();
    assert(families_paged());
    assert(first % per_page == 0);
    const count: u32 = @intCast(settings_model.families.len);
    const pages = (count + per_page - 1) / per_page; // Rounded up: the last may be short
    assert(pages > 1);
    var buffer: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&buffer, "{d} of {d}", .{ first / per_page + 1, pages });
    try draw_family(fonts, page, per_page, label, null, false);
    const cols = family_columns();
    const left: f32 = @floatFromInt(margin + per_page % cols * family_width());
    const mid: f32 = @floatFromInt(family_top + per_page / cols * family_height + 56 - 11);
    const x = left + try fonts.small.measure(label) + 36;
    page.stroke(x - 9, mid - 18, x + 9, mid, 4);
    page.stroke(x + 9, mid, x - 9, mid + 18, 4);
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
    const cols = family_columns();
    const row: u32 = cell / cols;
    const left: u32 = margin + cell % cols * family_width();
    const y = family_top + row * family_height;
    assert(row < family_rows);
    assert(name.len > 0);
    if (own) |font| {
        const avail: f32 = @floatFromInt(family_width() - 24);
        try draw.clipped(font, page, @floatFromInt(left), @intCast(y + 56), name, avail);
        if (chosen) {
            const width: u32 = @intFromFloat(@min(try font.measure(name), avail));
            page.fill_rect(left, y + 70, width, style.underline, style.black);
        }
    } else {
        const x: f32 = @floatFromInt(left);
        try draw.choice(fonts, page, x, .left, @intCast(y + 56), name, chosen, y + 70);
    }
}

pub fn render(fonts: Fonts, page: Page, tab: Tab, chosen: settings_model.Settings) !void {
    const height = height_for(tab);
    assert(height > top);
    page.fill_rect(0, top, page.width, height - top, 0xff);
    page.fill_rect(0, height - 4, page.width, 4, 0x00);
    try draw_tabs(fonts, page, tab);
    switch (tab) {
        .themes => try draw_themes(fonts, page, chosen),
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

test "with the reader's own typefaces, three to a row" {
    defer settings_model.reset_families();
    settings_model.offer_families(&(settings_model.builtin_families ++ .{"Literata"}));
    try std.testing.expectEqual(Hit{ .family = 2 }, hit(.font, 1100, family_top + 20));
    const second_row = family_top + family_height + 20;
    try std.testing.expectEqual(Hit{ .family = 4 }, hit(.font, 600, second_row));
    // No sixth
    try std.testing.expectEqual(Hit.none, hit(.font, 1100, family_top + family_height + 20));
    try std.testing.expectEqual(@as(u32, 6), families_per_page());
}

test "with more typefaces than cells, the last cell turns the page, round to the first" {
    defer settings_model.reset_families();
    const own = .{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K" };
    settings_model.offer_families(&(settings_model.builtin_families ++ own));
    const second_row = family_top + family_height + 20;
    try std.testing.expectEqual(Hit.more_families, hit(.font, 1100, second_row));
    try std.testing.expectEqual(Hit{ .family = 4 }, hit(.font, 600, second_row));
    try std.testing.expectEqual(@as(u32, 5), families_per_page());
    // Fifteen typefaces, five a page
    try std.testing.expectEqual(@as(u32, 5), next_family_page(0));
    try std.testing.expectEqual(@as(u32, 10), next_family_page(5));
    try std.testing.expectEqual(@as(u32, 0), next_family_page(10));
    try std.testing.expectEqual(@as(u32, 10), family_page_of(14));
    try std.testing.expectEqual(@as(u32, 5), family_page_of(5));
}

test "tabs split the top row evenly" {
    try std.testing.expectEqual(Hit{ .tab = .themes }, hit(.font, 100, 260));
    try std.testing.expectEqual(Hit{ .tab = .more }, hit(.font, 1200, 260));
}

test "each tab maps its own controls" {
    try std.testing.expectEqual(Hit{ .theme = 1 }, hit(.themes, 620, 500));
    try std.testing.expectEqual(Hit{ .family = 0 }, hit(.font, 200, family_top + 20));
    const second_row = family_top + family_height + 20;
    try std.testing.expectEqual(Hit{ .family = 3 }, hit(.font, 900, second_row));
    try std.testing.expectEqual(Hit.text_size, hit(.font, 600, size_row.top + 90));
    try std.testing.expectEqual(Hit.spacing, hit(.layout, 600, spacing_row.top + 90));
    try std.testing.expectEqual(Hit.margins, hit(.layout, 600, margin_row.top + 90));
    // Every switch answers on its own tab, where it's drawn
    for (switches, 0..) |sw, i| {
        const y: i32 = @intCast(switch_top(@intCast(i)) + 20);
        try std.testing.expectEqual(Hit{ .toggle = @intCast(i) }, hit(sw.tab, 600, y));
    }
}

test "the sheet stays inside itself" {
    try std.testing.expect(size_row.top + row_height <= height_for(.font));
    // A switch added to a full tab shows here before it's drawn past the sheet
    for (switches, 0..) |sw, i| {
        const bottom = switch_top(@intCast(i)) + toggle_height + 12;
        try std.testing.expect(bottom <= height_for(sw.tab));
    }
    try std.testing.expect(theme_top + theme_height <= height_for(.themes));
}

test "switches and fonts take a fingertip of height" {
    const bold = switch_for("bold");
    const bold_top: i32 = @intCast(switch_top(bold));
    try std.testing.expectEqual(Hit{ .toggle = bold }, hit(.font, 600, bold_top - 10));
    const bold_below = bold_top + toggle_height + 10;
    try std.testing.expectEqual(Hit{ .toggle = bold }, hit(.font, 600, bold_below));
    const clock = switch_for("clock");
    const clock_top: i32 = @intCast(switch_top(clock));
    try std.testing.expectEqual(Hit{ .toggle = clock }, hit(.more, 600, clock_top - 10));
    try std.testing.expectEqual(Hit{ .family = 0 }, hit(.font, 200, family_top - 10));
}

test "sliders say what they're set to" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1.35", value_label(&buf, spacing_row, 1));
    try std.testing.expectEqualStrings("Narrow", value_label(&buf, margin_row, 0));
    try std.testing.expectEqualStrings("3 of 6", value_label(&buf, size_row, 2));
}

test "switches sit where they always have" {
    const bold_starts = switch_for("bold_starts");
    try std.testing.expectEqual(@as(u32, content_top + 186), switch_top(switch_for("bold")));
    try std.testing.expectEqual(@as(u32, content_top + 286), switch_top(bold_starts));
    const left_align = switch_for("left_align");
    try std.testing.expectEqual(@as(u32, content_top + 292), switch_top(left_align));
    const lock_picture = switch_for("lock_picture");
    try std.testing.expectEqual(@as(u32, content_top + 408), switch_top(lock_picture));
}
