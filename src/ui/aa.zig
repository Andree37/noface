//! The Aa sheet: reading settings, in four tabs.
const std = @import("std");
const settings_model = @import("../model/settings.zig");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;
const slider = @import("slider.zig");
const icons = @import("icons.zig");
const text = @import("../layout/text.zig");

const top = 228; // Under the toolbar
const tabs_height = 92;
/// Where the sheet ends on screen: lower on More, which has a row more.
pub fn height_for(tab: Tab) u32 {
    return if (tab == .more or tab == .font) max_height else 760;
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
    theme: usize,
    family: usize,
    text_size,
    spacing,
    margins,
    toggle: usize, // Which of `switches`
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
    .{ .tab = .layout, .field = "left_align", .label = "Justify text", .inverted = true, .effect = .relayout },
    .{ .tab = .more, .field = "clock", .label = "Show clock while reading", .effect = .nothing },
    .{ .tab = .more, .field = "refresh", .label = "Page refresh every 20 pages", .effect = .nothing },
    .{ .tab = .more, .field = "time_left", .label = "Show time left", .effect = .footer },
    .{ .tab = .more, .field = "autostart", .label = "Open noface when the Kindle starts", .effect = .nothing, .guard = .autostart },
    .{ .tab = .more, .field = "lock_picture", .label = "Your picture when locked", .effect = .nothing, .guard = .lock_picture },
};

comptime {
    for (switches) |sw| {
        if (!@hasField(settings_model.Settings, sw.field)) @compileError("aa: no setting named " ++ sw.field);
    }
}

/// Whether switch `i` shows as on for these settings.
pub fn is_on(i: usize, s: settings_model.Settings) bool {
    inline for (switches, 0..) |sw, j| {
        if (i == j) return @field(s, sw.field) != sw.inverted;
    }
    unreachable;
}

/// Flips switch `i`'s setting.
pub fn flip(i: usize, s: *settings_model.Settings) void {
    inline for (switches, 0..) |sw, j| {
        if (i == j) @field(s, sw.field) = !@field(s, sw.field);
    }
}

/// The index of the switch for a setting, for tests and callers that name one.
pub fn switch_for(comptime field: []const u8) usize {
    inline for (switches, 0..) |sw, i| {
        if (comptime std.mem.eql(u8, sw.field, field)) return i;
    }
    @compileError("aa: no switch for " ++ field);
}

/// Where a tab's switches start: under its other controls.
fn switches_top(tab: Tab) u32 {
    return switch (tab) {
        .themes => content_top, // It has none
        .font => content_top + 186, // Under the typefaces
        .layout => content_top + 292, // Under the two sliders
        .more => content_top + 8,
    };
}

const switch_step = 100;

/// Where switch `i` sits: a step under the switches before it on its tab.
pub fn switch_top(i: usize) u32 {
    var before: u32 = 0;
    for (switches[0..i]) |sw| before += @intFromBool(sw.tab == switches[i].tab);
    return switches_top(switches[i].tab) + before * switch_step;
}

pub const Row = struct { hit: Hit, label: []const u8, top: u32, steps: usize };
pub const size_row = Row{ .hit = .text_size, .label = "Text size", .top = content_top + 356, .steps = settings_model.sizes.len };
pub const spacing_row = Row{ .hit = .spacing, .label = "Line spacing", .top = content_top, .steps = settings_model.spacings.len };
pub const margin_row = Row{ .hit = .margins, .label = "Margins", .top = content_top + 146, .steps = settings_model.margins.len };
pub const row_height = 146;

const family_top = content_top;
const family_height = 88;

/// Two columns for the Kindle's four typefaces; three once the reader's own join them.
fn family_columns() u32 {
    return if (settings_model.families.len > 4) 3 else 2;
}

fn family_width() u32 {
    return (screen_width - 2 * margin) / family_columns();
}
const toggle_height = 76;

const theme_width = 340;
const theme_gap = 34;
const theme_top = content_top + 20;
const theme_height = 300;

pub const Theme = struct { label: []const u8, size: usize, spacing: usize, margin: usize };
pub const themes = [_]Theme{
    .{ .label = "Compact", .size = 1, .spacing = 0, .margin = 0 },
    .{ .label = "Standard", .size = 2, .spacing = 1, .margin = 1 },
    .{ .label = "Large", .size = 4, .spacing = 2, .margin = 2 },
};

fn row_slider(r: Row) slider.Slider {
    return .{ .left = 110, .right = 1162, .y = r.top + 92 };
}

/// Step for a finger at `x` on a row's slider.
pub fn step_at(r: Row, x: i32) usize {
    return slider.value_at(row_slider(r), x, @intCast(r.steps - 1));
}

fn within(y: i32, from: i32, size: i32) bool {
    return y >= from and y < from + size;
}

/// A switch row's taps: its 76 px drawn height grown to a fingertip (100 px), half
/// above and half below.
fn on_toggle(y: i32, toggle_top: i32) bool {
    return within(y, toggle_top - 12, toggle_height + 24);
}

pub fn hit(tab: Tab, x: i32, y: i32) Hit {
    if (y < top + tabs_height) {
        const cell: i32 = screen_width / tab_labels.len;
        const at = @divTrunc(std.math.clamp(x, @as(i32, 0), screen_width - 1), cell);
        return .{ .tab = @fromBackingInt(@intCast(at)) };
    }
    switch (tab) {
        .themes => {
            if (!within(y, theme_top, theme_height)) return .none;
            for (0..themes.len) |i| {
                const left: i32 = margin + @as(i32, @intCast(i)) * (theme_width + theme_gap);
                if (x >= left and x < left + theme_width) return .{ .theme = i };
            }
        },
        .font => {
            // The first row reaches up to the tabs, so both rows take a full fingertip
            if (within(y, family_top - 12, 2 * family_height + 12)) {
                const row: usize = @intCast(@min(@divTrunc(@max(y - family_top, 0), family_height), 1));
                const cols = family_columns();
                const col: usize = @min(@as(u32, @intCast(@max(x - margin, 0))) / family_width(), cols - 1);
                const i = row * cols + col;
                return if (i < settings_model.families.len) .{ .family = i } else .none;
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
        if (sw.tab == tab and on_toggle(y, @intCast(switch_top(i)))) return .{ .toggle = i };
    }
    return .none;
}

fn draw_toggle(fonts: Fonts, page: Page, y: u32, label: []const u8, on: bool) !void {
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

const margin_names = [_][]const u8{ "Narrow", "Medium", "Wide", "Widest" };

/// What a slider is set to, in words or numbers a reader knows.
pub fn value_label(buf: []u8, r: Row, value: usize) []const u8 {
    return switch (r.hit) {
        .spacing => std.fmt.bufPrint(buf, "{d:.2}", .{settings_model.spacings[value]}) catch "",
        .margins => margin_names[@min(value, margin_names.len - 1)],
        else => std.fmt.bufPrint(buf, "{d} of {d}", .{ value + 1, r.steps }) catch "",
    };
}

/// One slider row, redrawn alone while dragging.
pub fn draw_row(fonts: Fonts, page: Page, r: Row, value: usize, mono: bool) !void {
    page.fill_rect(0, r.top, page.width, row_height, 0xff);
    try fonts.small.draw(page, margin, @intCast(r.top + 48), r.label);
    var buf: [24]u8 = undefined;
    const shown = value_label(&buf, r, value);
    try fonts.small.draw(page, @as(f32, @floatFromInt(page.width - margin)) - try fonts.small.measure(shown), @intCast(r.top + 48), shown);
    const bar = row_slider(r);
    const max: u32 = @intCast(r.steps - 1);
    const knob = slider.knob_at(bar, @intCast(value), max);
    slider.draw(page, bar, knob);
    slider.draw_ticks(page, bar, max, knob);
    if (mono) page.threshold(r.top, row_height);
}

fn draw_tabs(fonts: Fonts, page: Page, tab: Tab) !void {
    const cell: u32 = page.width / @as(u32, tab_labels.len);
    for (tab_labels, 0..) |label, i| {
        const left: u32 = @as(u32, @intCast(i)) * cell;
        const active = i == @backingInt(tab);
        try draw.choice(fonts, page, @floatFromInt(left + cell / 2), .center, top + 60, label, active, top + 78);
        if (!active) page.tint(left + 8, top + 20, cell - 16, 54, style.faded);
    }
    page.fill_rect(0, top + tabs_height - 2, page.width, 1, style.rule);
}

fn draw_themes(fonts: Fonts, page: Page, chosen: settings_model.Settings) !void {
    var any = false;
    for (themes, 0..) |t, i| {
        const left: u32 = margin + @as(u32, @intCast(i)) * (theme_width + theme_gap);
        const active = chosen.size == t.size and chosen.spacing == t.spacing and chosen.margin == t.margin;
        any = any or active;
        // Rounded tiles; the one in use has a thick edge and a tick in its corner
        const edge: u32 = if (active) 6 else 2;
        draw.box_with(page, left, theme_top, theme_width, theme_height, edge, style.button_corner);
        if (active) icons.check(page, @floatFromInt(left + theme_width - 38), theme_top + 38);
        // Text lines drawn to scale, so the choice shows rather than tells.
        const gap: u32 = 16 + @as(u32, @intCast(t.spacing)) * 8;
        const inset: u32 = 28 + @as(u32, @intCast(t.margin)) * 16;
        const thick: u32 = 5 + @as(u32, @intCast(t.size));
        var y: u32 = theme_top + 44;
        while (y < theme_top + 204) : (y += gap + thick) {
            page.fill_rect(left + inset, y, theme_width - 2 * inset, thick, style.quiet);
        }
        try draw.centered(fonts.small, page, @floatFromInt(left + theme_width / 2), theme_top + 264, t.label);
    }
    // Sizes changed by hand match none of them; say so, so no tile seems forgotten
    if (!any) {
        try fonts.caption.draw(page, margin, theme_top + theme_height + 52, "Using your own settings. Pick a theme to switch to it.");
        page.tint(margin, theme_top + theme_height + 22, page.width - 2 * margin, 40, style.faded);
    }
}

fn draw_font(fonts: Fonts, page: Page, chosen: settings_model.Settings) !void {
    for (settings_model.families, 0..) |family, i| {
        const cols = family_columns();
        const row: u32 = @as(u32, @intCast(i)) / cols;
        const left: u32 = margin + @as(u32, @intCast(i)) % cols * family_width();
        const y = family_top + row * family_height;
        // The name in its own typeface, when it's loaded; underlined when chosen
        const own = if (i < fonts.families.len) fonts.families[i] else null;
        if (own) |font| {
            try draw.clipped(font, page, @floatFromInt(left), @intCast(y + 56), family, @floatFromInt(family_width() - 24));
            if (i == chosen.font) page.fill_rect(left, y + 70, @intFromFloat(@min(try font.measure(family), @as(f32, @floatFromInt(family_width() - 24)))), style.underline, style.black);
        } else try draw.choice(fonts, page, @floatFromInt(left), .left, @intCast(y + 56), family, i == chosen.font, y + 70);
    }
    try draw_row(fonts, page, size_row, chosen.size, false);
}

pub fn render(fonts: Fonts, page: Page, tab: Tab, chosen: settings_model.Settings) !void {
    const height = height_for(tab);
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
        if (sw.tab == tab) try draw_toggle(fonts, page, switch_top(i), sw.label, is_on(i, chosen));
    }
}

test "with the reader's own typefaces, three to a row" {
    defer settings_model.reset_families();
    try std.testing.expect(settings_model.add_family("Literata"));
    try std.testing.expectEqual(Hit{ .family = 2 }, hit(.font, 1100, family_top + 20));
    try std.testing.expectEqual(Hit{ .family = 4 }, hit(.font, 600, family_top + family_height + 20));
    try std.testing.expectEqual(Hit.none, hit(.font, 1100, family_top + family_height + 20)); // No sixth
}

test "tabs split the top row evenly" {
    try std.testing.expectEqual(Hit{ .tab = .themes }, hit(.font, 100, 260));
    try std.testing.expectEqual(Hit{ .tab = .more }, hit(.font, 1200, 260));
}

test "each tab maps its own controls" {
    try std.testing.expectEqual(Hit{ .theme = 1 }, hit(.themes, 620, 500));
    try std.testing.expectEqual(Hit{ .family = 0 }, hit(.font, 200, family_top + 20));
    try std.testing.expectEqual(Hit{ .family = 3 }, hit(.font, 900, family_top + family_height + 20));
    try std.testing.expectEqual(Hit.text_size, hit(.font, 600, size_row.top + 90));
    try std.testing.expectEqual(Hit.spacing, hit(.layout, 600, spacing_row.top + 90));
    try std.testing.expectEqual(Hit.margins, hit(.layout, 600, margin_row.top + 90));
    // Every switch answers on its own tab, where it's drawn
    for (switches, 0..) |sw, i| try std.testing.expectEqual(Hit{ .toggle = i }, hit(sw.tab, 600, @intCast(switch_top(i) + 20)));
}

test "the sheet stays inside itself" {
    try std.testing.expect(size_row.top + row_height <= height_for(.font));
    // A switch added to a full tab shows here before it's drawn past the sheet
    for (switches, 0..) |sw, i| try std.testing.expect(switch_top(i) + toggle_height + 12 <= height_for(sw.tab));
    try std.testing.expect(theme_top + theme_height <= height_for(.themes));
}

test "switches and fonts take a fingertip of height" {
    const bold = switch_for("bold");
    try std.testing.expectEqual(Hit{ .toggle = bold }, hit(.font, 600, @intCast(switch_top(bold) - 10)));
    try std.testing.expectEqual(Hit{ .toggle = bold }, hit(.font, 600, @intCast(switch_top(bold) + toggle_height + 10)));
    const clock = switch_for("clock");
    try std.testing.expectEqual(Hit{ .toggle = clock }, hit(.more, 600, @intCast(switch_top(clock) - 10)));
    try std.testing.expectEqual(Hit{ .family = 0 }, hit(.font, 200, family_top - 10));
}

test "sliders say what they're set to" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1.35", value_label(&buf, spacing_row, 1));
    try std.testing.expectEqualStrings("Narrow", value_label(&buf, margin_row, 0));
    try std.testing.expectEqualStrings("3 of 6", value_label(&buf, size_row, 2));
}

test "switches sit where they always have" {
    try std.testing.expectEqual(@as(u32, content_top + 186), switch_top(switch_for("bold")));
    try std.testing.expectEqual(@as(u32, content_top + 286), switch_top(switch_for("bold_starts")));
    try std.testing.expectEqual(@as(u32, content_top + 292), switch_top(switch_for("left_align")));
    const lock_picture = switch_for("lock_picture");
    try std.testing.expectEqual(@as(u32, content_top + 408), switch_top(lock_picture));
}
