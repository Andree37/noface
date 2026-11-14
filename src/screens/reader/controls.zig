//! The reading toolbar and its Aa sheet.
const std = @import("std");
const assert = std.debug.assert;
const autostart = @import("../../kindle/autostart.zig");
const card = @import("../../ui/card.zig");
const aa = @import("../../ui/aa.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const lock = @import("../lock.zig");

comptime {
    // The toolbar's top bar, or the tallest sheet, ends above its bottom bar, and the
    // page scrubber sits inside that bottom bar
    assert(toolbar.top_height < toolbar.bottom_top);
    assert(aa.max_height < toolbar.bottom_top);
    assert(toolbar.scrub_top > toolbar.bottom_top);
}

/// How the toolbar is drawn: with its Aa sheet open or not, and whether the whole
/// page is shown again or only the bars.
pub const Drawn = struct { sheet_open: bool, whole_page: bool };

/// Draws the toolbar over the current page.
pub fn draw_toolbar(a: *app.App, s: *sess.Session, title: []const u8, drawn: Drawn) !void {
    assert(s.current < s.pages.len);
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    const total = if (s.layout_pending()) 0 else s.pages.len; // No page count until it's known
    assert(total == 0 or total > s.current);
    var fonts = a.ui;
    if (drawn.sheet_open and a.tab == .font) fonts.families = a.load_family_samples();
    try toolbar.render(
        fonts,
        a.page(a.overlay),
        title,
        s.current,
        total,
        &a.quick,
        if (drawn.sheet_open) a.tab else null,
        a.settings,
        s.is_bookmarked(s.current),
    );
    @memcpy(a.screen.pixels, a.overlay);
    if (drawn.whole_page) {
        try a.show_band(0, a.screen.height);
        return;
    }
    try show_bars(a, drawn.sheet_open);
}

pub fn close_toolbar(a: *app.App, s: *sess.Session, sheet_open: bool) !void {
    assert(s.current < s.pages.len);
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    // The page under the bars is all that changed
    assert(a.screen.pixels.len > 0);
    try show_bars(a, sheet_open);
}

/// Shows the screen where the toolbar's bars are, or were: the top bar (or the
/// tallest sheet's reach, as switching from More to a shorter tab uncovers the
/// page) and the bottom bar.
fn show_bars(a: *app.App, sheet_open: bool) !void {
    const top: u32 = if (sheet_open) aa.max_height else toolbar.top_height;
    assert(top < a.screen.height);
    assert(toolbar.bottom_top < a.screen.height);
    const first = try a.screen.show_region(0, 0, a.screen.width, top, .page);
    try a.show_band(toolbar.bottom_top, a.screen.height - toolbar.bottom_top);
    try a.screen.wait_complete(first);
}

/// Follows a finger along the page scrubber, then jumps there.
pub fn drag_scrub(
    a: *app.App,
    s: *sess.Session,
    title: []const u8,
    sheet_open: bool,
    first_x: i32,
) !void {
    assert(s.pages.len > 0);
    a.input.begin_drag();
    const band = a.screen.height - toolbar.scrub_top;
    const page_count: u32 = @intCast(s.pages.len);
    const Follow = struct {
        a: *app.App,
        page_count: u32,
        band: u32,
        target: *u32,
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            assert(f.target.* < f.page_count);
            const next: u32 = @intCast(toolbar.page_at(x, f.page_count));
            assert(next < f.page_count);
            if (next == f.target.*) return null;
            f.target.* = next;
            const pixels = f.a.page(f.a.screen.pixels);
            try toolbar.draw_scrub(f.a.ui, pixels, next, f.page_count, true);
            const width = f.a.screen.width;
            return try f.a.screen.show_region(0, toolbar.scrub_top, width, f.band, .quick);
        }
    };
    var target: u32 = @intCast(toolbar.page_at(first_x, page_count));
    assert(target < page_count);
    try toolbar.draw_scrub(a.ui, a.page(a.screen.pixels), target, page_count, true);
    const first = try a.screen.show_region(0, toolbar.scrub_top, a.screen.width, band, .quick);
    const follow = Follow{ .a = a, .page_count = page_count, .band = band, .target = &target };
    _ = try app.follow_drag(a, first, follow);
    s.set_page(target);
    assert(s.current == target);
    try draw_toolbar(a, s, title, .{ .sheet_open = sheet_open, .whole_page = true });
    try app.clean_band(a, toolbar.scrub_top, band);
}

/// The setting an Aa slider row changes.
fn row_value(a: *const app.App, row: aa.Row) u32 {
    assert(row.steps > 0);
    const value = switch (row.hit) {
        .text_size => a.settings.size,
        .spacing => a.settings.spacing,
        else => a.settings.margin,
    };
    // Settings are brought inside their steps as they're read
    assert(value < row.steps);
    return @intCast(value);
}

fn row_value_set(a: *app.App, row: aa.Row, value: u32) void {
    assert(row.steps > 0);
    assert(value < row.steps);
    switch (row.hit) {
        .text_size => a.settings.size = value,
        .spacing => a.settings.spacing = value,
        else => a.settings.margin = value,
    }
    assert(row_value(a, row) == value);
}

/// Follows a finger along an Aa slider, and applies it when lifted.
fn drag_setting(
    a: *app.App,
    alloc: std.mem.Allocator,
    s: *sess.Session,
    title: []const u8,
    row: aa.Row,
    first_x: i32,
) !void {
    var value: u32 = @intCast(aa.step_at(row, first_x));
    assert(value < row.steps);
    const started = row_value(a, row);
    a.input.begin_drag();
    try aa.draw_row(a.ui, a.page(a.screen.pixels), row, value, true);
    const first = try a.screen.show_region(0, row.top, a.screen.width, aa.row_height, .quick);
    const Follow = struct {
        a: *app.App,
        row: aa.Row,
        value: *u32,
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            assert(f.value.* < f.row.steps);
            const next: u32 = @intCast(aa.step_at(f.row, x));
            assert(next < f.row.steps);
            if (next == f.value.*) return null;
            f.value.* = next;
            try aa.draw_row(f.a.ui, f.a.page(f.a.screen.pixels), f.row, next, true);
            const width = f.a.screen.width;
            return try f.a.screen.show_region(0, f.row.top, width, aa.row_height, .quick);
        }
    };
    _ = try app.follow_drag(a, first, Follow{ .a = a, .row = row, .value = &value });
    if (value != started) {
        row_value_set(a, row, value);
        try sess.relayout(a, alloc, s);
    }
    try draw_toolbar(a, s, title, .{ .sheet_open = true, .whole_page = true });
    try app.clean_band(a, row.top, aa.row_height);
}

/// Whether a switch with this guard may turn on: asks, or says what's missing, first.
/// False when it may not; the sheet is drawn again either way.
fn ready(a: *app.App, s: *sess.Session, title: []const u8, guard: aa.Guard) !bool {
    assert(s.current < s.pages.len);
    const sheet_only: Drawn = .{ .sheet_open = true, .whole_page = false };
    switch (guard) {
        .none => return true,
        .autostart => {
            // Turning it on needs the startup file in the system folder: ask first
            if (autostart.installed()) return true;
            const page = try s.ensure(s.current, s.current);
            const rows = [_]card.Row{.{ .label = "Turn on" }};
            const chosen = try app.choose_from_card(
                a,
                page,
                "Open noface when the Kindle starts",
                "This adds one small startup file to the Kindle's system.",
                &rows,
            );
            if (chosen == null) {
                try draw_toolbar(a, s, title, sheet_only);
                return false;
            }
            if (autostart.install()) return true;
            try draw_toolbar(a, s, title, sheet_only);
            try app.show_notice(a, "Couldn't set up starting with the Kindle.");
            return false;
        },
        .lock_picture => {
            // Turning it on needs a picture to show
            if (lock.has_picture(a)) return true;
            const page = try s.ensure(s.current, s.current);
            const rows = [_]card.Row{.{ .label = "OK" }};
            _ = try app.choose_from_card(
                a,
                page,
                "Add your picture first",
                "Name it lockscreen.jpg or lockscreen.png, and put it in the noface-data folder.",
                &rows,
            );
            try draw_toolbar(a, s, title, sheet_only);
            return false;
        },
    }
}

/// Handles a tap inside the Aa sheet.
pub fn tap_sheet(
    a: *app.App,
    alloc: std.mem.Allocator,
    s: *sess.Session,
    title: []const u8,
    x: i32,
    y: i32,
) !void {
    assert(s.current < s.pages.len);
    const sheet_only: Drawn = .{ .sheet_open = true, .whole_page = false };
    switch (aa.hit(a.tab, x, y)) {
        .none => return,
        .tab => |tab| {
            a.tab = tab;
            return draw_toolbar(a, s, title, sheet_only);
        },
        .text_size => return drag_setting(a, alloc, s, title, aa.size_row, x),
        .spacing => return drag_setting(a, alloc, s, title, aa.spacing_row, x),
        .margins => return drag_setting(a, alloc, s, title, aa.margin_row, x),
        .theme => |index| {
            assert(index < aa.themes.len);
            const theme = aa.themes[index];
            a.settings.size = theme.size;
            a.settings.spacing = theme.spacing;
            a.settings.margin = theme.margin;
        },
        .family => |index| a.settings.font = index,
        .toggle => |index| {
            assert(index < aa.switches.len);
            const switch_hit = aa.switches[index];
            const turning_on = !aa.is_on(index, a.settings);
            if (turning_on and !try ready(a, s, title, switch_hit.guard)) return;
            aa.flip(index, &a.settings);
            assert(aa.is_on(index, a.settings) == turning_on);
            switch (switch_hit.effect) {
                .relayout => {}, // Below
                .footer, .nothing => {
                    app.save_settings(a.settings_path, a.settings);
                    // The footer is drawn into each page
                    if (switch_hit.effect == .footer) a.forget_pages();
                    return draw_toolbar(a, s, title, sheet_only);
                },
            }
        },
    }
    try sess.relayout(a, alloc, s);
    try draw_toolbar(a, s, title, .{ .sheet_open = true, .whole_page = true });
}
