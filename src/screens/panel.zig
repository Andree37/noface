//! The quick panel: light, warmth, airplane mode, Bluetooth and sync, over a book or the library.
const std = @import("std");
const assert = std.debug.assert;
const library = @import("../ui/library.zig");
const menu = @import("../ui/menu.zig");
const wifi_saver = @import("../kindle/wifi_saver.zig");
const lipc = @import("../kindle/lipc.zig");
const quick_model = @import("../model/quick.zig");
const app = @import("../app.zig");
const screen = @import("screen.zig");
const input_mod = @import("../kindle/input.zig");

comptime {
    // A row is told apart from the other by its place alone
    assert(menu.warmth_row.y != menu.brightness_row.y);
    // Each slider's band, redrawn on its own, is inside the panel
    assert(menu.brightness_row.y + menu.band_height <= menu.height);
    assert(menu.warmth_row.y + menu.band_height <= menu.height);
}

/// Shows the panel at once with the last status read, then reads it again (about a
/// quarter second of lipc calls) and redraws only if something changed.
pub fn draw_fresh(a: *app.App, background: []const u8) !void {
    assert(background.len == a.screen.pixels.len);
    try draw_menu(a, background);
    const fresh = lipc.read(a.quick);
    if (fresh.same(&a.quick)) return;
    a.quick = fresh;
    try draw_menu(a, background);
    assert(fresh.same(&a.quick));
}

/// Draws the quick panel over `background` and shows it.
pub fn draw_menu(a: *app.App, background: []const u8) !void {
    assert(a.overlay.len == background.len);
    assert(menu.height <= a.screen.height);
    @memcpy(a.overlay, background);
    try menu.render(a.ui, a.page(a.overlay), &a.quick);
    @memcpy(a.screen.pixels, a.overlay);
    try a.show_band(0, menu.height);
}

pub fn close_menu(a: *app.App, background: []const u8) !void {
    assert(background.len == a.screen.pixels.len);
    assert(menu.height <= a.screen.height);
    @memcpy(a.screen.pixels, background);
    try a.show_band(0, menu.height);
}

pub fn row_value(a: *app.App, row: menu.Row) u32 {
    assert(row.y == menu.warmth_row.y or row.y == menu.brightness_row.y);
    if (row.y == menu.warmth_row.y) {
        assert(row.max == menu.warmth_row.max);
        return a.quick.warmth;
    }
    assert(row.max == menu.brightness_row.max);
    return a.quick.brightness;
}

pub fn set_row_value(a: *app.App, row: menu.Row, level: u32) void {
    assert(row.y == menu.warmth_row.y or row.y == menu.brightness_row.y);
    if (row.y == menu.warmth_row.y) {
        a.quick.warmth = level;
        lipc.set_warmth(level, a.quick.schedule);
    } else {
        a.quick.brightness = level;
        lipc.set_brightness(level);
    }
    assert(row_value(a, row) == level);
}

/// Shows a slider row at rest after a step, without a flash.
fn show_row(a: *app.App, row: menu.Row, level: u32) !void {
    assert(row.y == menu.warmth_row.y or row.y == menu.brightness_row.y);
    assert(menu.band_top(row) + menu.band_height <= menu.height);
    try menu.draw_slider(a.ui, a.page(a.screen.pixels), row, level, false);
    try a.show_band(menu.band_top(row), menu.band_height);
}

/// Follows a finger along a panel slider from where it landed until it lifts.
/// The knob slides under the finger; the light changes a step at a time, after each
/// frame is on its way, so the lipc call never holds the knob back.
pub fn drag_row(a: *app.App, row: menu.Row, first_x: i32) !void {
    assert(row.y == menu.warmth_row.y or row.y == menu.brightness_row.y);
    a.input.begin_drag();
    const Follow = struct {
        a: *app.App,
        row: menu.Row,
        knob: *u32,
        path: *[2]u32, // Leftmost and rightmost knob positions shown
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            assert(f.path[0] <= f.path[1]);
            const knob = menu.knob_under(x);
            if (knob == f.knob.*) return null;
            const level = menu.level_at(f.row, x);
            assert(level <= f.row.max);
            const page = f.a.page(f.a.screen.pixels);
            try menu.draw_slider_at(f.a.ui, page, f.row, level, knob, true);
            const span = menu.knob_span(f.knob.*, knob);
            f.knob.* = knob;
            f.path.* = .{ @min(f.path[0], knob), @max(f.path[1], knob) };
            assert(f.path[0] <= knob);
            assert(knob <= f.path[1]);
            const top = menu.band_top(f.row);
            const marker = try f.a.screen.show_region(
                span.left,
                top,
                span.width,
                menu.band_height,
                .quick,
            );
            if (level != row_value(f.a, f.row)) set_row_value(f.a, f.row, level);
            return marker;
        }
    };
    var knob = menu.knob_at(row, row_value(a, row));
    var path = [2]u32{ knob, knob };
    const follow = Follow{ .a = a, .row = row, .knob = &knob, .path = &path };
    const first = try follow.moved(first_x, 0);
    _ = try app.follow_drag(a, first, follow);
    // Settles the stretch the knob crossed back to smooth edges
    assert(path[0] <= path[1]);
    try menu.draw_slider(a.ui, a.page(a.screen.pixels), row, row_value(a, row), false);
    const crossed = menu.knob_span(path[0], path[1]);
    try app.clean_rect(a, crossed.left, menu.band_top(row), crossed.width, menu.band_height);
}

/// Runs a panel control. False means the tap wasn't on one. Each control redraws only
/// its own part of the panel, before telling the Kindle, so the tap answers at once.
pub fn panel_control(a: *app.App, background: []const u8, choice: menu.Hit, x: i32) !bool {
    assert(background.len == a.screen.pixels.len);
    switch (choice) {
        .slider => try drag_row(a, menu.brightness_row, x),
        .warmth => try drag_row(a, menu.warmth_row, x),
        .dimmer, .brighter, .cooler, .warmer => {
            const brightness = choice == .dimmer or choice == .brighter;
            const row = if (brightness) menu.brightness_row else menu.warmth_row;
            const up = choice == .brighter or choice == .warmer;
            const level = quick_model.step_brightness(row_value(a, row), up);
            try show_row(a, row, level);
            set_row_value(a, row, level);
        },
        .airplane, .bluetooth, .sync => try panel_control_shortcut(a, choice),
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            try draw_menu(a, background);
            lipc.set_schedule(a.quick.schedule);
        },
        // Not a control: closing and leaving are the caller's. Every Hit is named, so
        // a new tile doesn't compile until it's handled here or there
        .none, .close, .settings, .kindle => return false,
    }
    return true;
}

/// A round shortcut at the top of the panel: airplane mode, Bluetooth or sync. Its
/// tile is redrawn first, and the Kindle told while the screen shows it.
fn panel_control_shortcut(a: *app.App, choice: menu.Hit) !void {
    assert(choice == .airplane or choice == .bluetooth or choice == .sync);
    switch (choice) {
        .airplane => a.quick.airplane = !a.quick.airplane,
        .bluetooth => a.quick.bluetooth = !a.quick.bluetooth,
        else => a.quick.syncing = true,
    }
    const box = menu.shortcut_box(choice).?;
    assert(box.top + box.height <= menu.height);
    try menu.draw_shortcut(a.ui, a.page(a.screen.pixels), choice, &a.quick);
    const marker = try a.screen.show_region(
        box.left,
        box.top,
        box.width,
        box.height,
        .page,
    );
    switch (choice) {
        .airplane => {
            // The reader's choice now: noface neither undoes nor redoes it
            wifi_saver.forget();
            a.wifi_hands_off = true;
            lipc.set_airplane(a.quick.airplane);
        },
        .bluetooth => lipc.set_bluetooth(a.quick.bluetooth),
        else => {
            // Paused while reading: syncing needs it, for the rest of the book
            wifi_saver.restore();
            a.wifi_hands_off = true;
            lipc.sync_now();
        },
    }
    try a.screen.wait_complete(marker);
    if (choice == .sync and a.quick.airplane and lipc.airplane_on() == false) {
        // The airplane tile said on: show it off now
        a.quick.airplane = false;
        const plane = menu.shortcut_box(.airplane).?;
        try menu.draw_shortcut(a.ui, a.page(a.screen.pixels), .airplane, &a.quick);
        try a.show_rect(plane.left, plane.top, plane.width, plane.height);
    }
}

/// The quick panel over the library. Returns true to quit to the stock UI.
pub fn library_menu(a: *app.App, background: []const u8) !bool {
    assert(background.len == a.screen.pixels.len);
    var panel = LibraryPanel{ .a = a, .background = background };
    switch (try screen.run_to_end(a, &panel)) {
        .done => return true,
        // Closed, or the Kindle locking: the library comes back from under it
        .closed => try close_menu(a, background),
        .interrupted => |action| {
            // Leaving noface: it needn't
            if (action == .lock) try close_menu(a, background);
        },
    }
    return false;
}

/// Touches as they land, as in the reader: a slider follows the finger from there, and
/// a tap that only arrived on the lift would leave it waiting for a drag. Done when
/// noface should go to the Kindle's own screens.
const LibraryPanel = struct {
    pub const Result = void;
    pub const touches = input_mod.Input.Modes.sheet;
    a: *app.App,
    background: []const u8,

    pub fn draw(p: *LibraryPanel, _: screen.Part) !void {
        assert(p.background.len == p.a.screen.pixels.len);
        try draw_fresh(p.a, p.background);
    }

    pub fn on_tap(p: *LibraryPanel, t: screen.Tap) !screen.Step(void) {
        const choice = menu.hit(t.x, t.y);
        if (try panel_control(p.a, p.background, choice, t.x)) return .stay; // Drew itself
        // Every control drew itself above: what's left closes the panel or leaves noface
        assert(choice != .slider);
        assert(choice != .sync);
        return switch (choice) {
            .settings => {
                lipc.open_settings();
                return .{ .done = {} };
            },
            .kindle => .{ .done = {} }, // The Kindle's home comes back by noface.sh
            .close => .close,
            else => .stay,
        };
    }
};
