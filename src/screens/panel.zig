//! The quick panel: light, warmth, airplane mode, Bluetooth and sync, over a book or the library.
const std = @import("std");
const library = @import("../ui/library.zig");
const menu = @import("../ui/menu.zig");
const wifi_saver = @import("../kindle/wifi_saver.zig");
const lipc = @import("../kindle/lipc.zig");
const quick_model = @import("../model/quick.zig");
const app = @import("../app.zig");
const screen = @import("screen.zig");
const input_mod = @import("../kindle/input.zig");

/// Shows the panel at once with the last status read, then reads it again (about a
/// quarter second of lipc calls) and redraws only if something changed.
pub fn drawFresh(a: *app.App, background: []const u8) !void {
    try drawMenu(a, background);
    const fresh = lipc.read(a.quick);
    if (fresh.same(&a.quick)) return;
    a.quick = fresh;
    try drawMenu(a, background);
}

/// Draws the quick panel over `background` and shows it.
pub fn drawMenu(a: *app.App, background: []const u8) !void {
    @memcpy(a.overlay, background);
    try menu.render(a.ui, a.page(a.overlay), &a.quick);
    @memcpy(a.screen.pixels, a.overlay);
    try a.showBand(0, menu.height);
}

pub fn closeMenu(a: *app.App, background: []const u8) !void {
    @memcpy(a.screen.pixels, background);
    try a.showBand(0, menu.height);
}

pub fn rowValue(a: *app.App, row: menu.Row) u32 {
    return if (row.y == menu.warmth_row.y) a.quick.warmth else a.quick.brightness;
}

pub fn setRowValue(a: *app.App, row: menu.Row, level: u32) void {
    if (row.y == menu.warmth_row.y) {
        a.quick.warmth = level;
        lipc.setWarmth(level, a.quick.schedule);
    } else {
        a.quick.brightness = level;
        lipc.setBrightness(level);
    }
}

/// Shows a slider row at rest after a step, without a flash.
fn showRow(a: *app.App, row: menu.Row, level: u32) !void {
    try menu.drawSlider(a.ui, a.page(a.screen.pixels), row, level, false);
    try a.showBand(menu.bandTop(row), menu.band_height);
}

/// Follows a finger along a panel slider from where it landed until it lifts.
/// The knob slides under the finger; the light changes a step at a time, after each
/// frame is on its way, so the lipc call never holds the knob back.
pub fn dragRow(a: *app.App, row: menu.Row, first_x: i32) !void {
    a.input.beginDrag();
    const Follow = struct {
        a: *app.App,
        row: menu.Row,
        knob: *u32,
        path: *[2]u32, // Leftmost and rightmost knob positions shown
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            const knob = menu.knobUnder(x);
            if (knob == f.knob.*) return null;
            const level = menu.levelAt(f.row, x);
            try menu.drawSliderAt(f.a.ui, f.a.page(f.a.screen.pixels), f.row, level, knob, true);
            const span = menu.knobSpan(f.knob.*, knob);
            f.knob.* = knob;
            f.path.* = .{ @min(f.path[0], knob), @max(f.path[1], knob) };
            const marker = try f.a.screen.showRegion(span.left, menu.bandTop(f.row), span.width, menu.band_height, .quick);
            if (level != rowValue(f.a, f.row)) setRowValue(f.a, f.row, level);
            return marker;
        }
    };
    var knob = menu.knobAt(row, rowValue(a, row));
    var path = [2]u32{ knob, knob };
    const follow = Follow{ .a = a, .row = row, .knob = &knob, .path = &path };
    const first = try follow.moved(first_x, 0);
    _ = try app.followDrag(a, first, follow);
    // Settles the stretch the knob crossed back to smooth edges
    try menu.drawSlider(a.ui, a.page(a.screen.pixels), row, rowValue(a, row), false);
    const crossed = menu.knobSpan(path[0], path[1]);
    try app.cleanRect(a, crossed.left, menu.bandTop(row), crossed.width, menu.band_height);
}

/// Runs a panel control. False means the tap wasn't on one. Each control redraws only
/// its own part of the panel, before telling the Kindle, so the tap answers at once.
pub fn panelControl(a: *app.App, background: []const u8, choice: menu.Hit, x: i32) !bool {
    switch (choice) {
        .slider => try dragRow(a, menu.brightness_row, x),
        .warmth => try dragRow(a, menu.warmth_row, x),
        .dimmer, .brighter, .cooler, .warmer => {
            const row = if (choice == .dimmer or choice == .brighter) menu.brightness_row else menu.warmth_row;
            const level = quick_model.stepBrightness(rowValue(a, row), choice == .brighter or choice == .warmer);
            try showRow(a, row, level);
            setRowValue(a, row, level);
        },
        .airplane, .bluetooth, .sync => {
            switch (choice) {
                .airplane => a.quick.airplane = !a.quick.airplane,
                .bluetooth => a.quick.bluetooth = !a.quick.bluetooth,
                else => a.quick.syncing = true,
            }
            const box = menu.shortcutBox(choice).?;
            try menu.drawShortcut(a.ui, a.page(a.screen.pixels), choice, &a.quick);
            const marker = try a.screen.showRegion(box.left, box.top, box.width, box.height, .page);
            switch (choice) {
                .airplane => {
                    // The reader's choice now: noface neither undoes nor redoes it
                    wifi_saver.forget();
                    a.wifi_hands_off = true;
                    lipc.setAirplane(a.quick.airplane);
                },
                .bluetooth => lipc.setBluetooth(a.quick.bluetooth),
                else => {
                    // Paused while reading: syncing needs it, for the rest of the book
                    wifi_saver.restore();
                    a.wifi_hands_off = true;
                    lipc.syncNow();
                },
            }
            try a.screen.waitComplete(marker);
            if (choice == .sync and a.quick.airplane and lipc.airplaneOn() == false) {
                // The airplane tile said on: show it off now
                a.quick.airplane = false;
                const plane = menu.shortcutBox(.airplane).?;
                try menu.drawShortcut(a.ui, a.page(a.screen.pixels), .airplane, &a.quick);
                try a.showRect(plane.left, plane.top, plane.width, plane.height);
            }
        },
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            try drawMenu(a, background);
            lipc.setSchedule(a.quick.schedule);
        },
        else => return false,
    }
    return true;
}

/// The quick panel over the library. Returns true to quit to the stock UI.
pub fn libraryMenu(a: *app.App, background: []const u8) !bool {
    var panel = LibraryPanel{ .a = a, .background = background };
    if (try screen.run(a, &panel)) |_| return true;
    // Closed, or the Kindle locking: the library comes back from under it. Leaving
    // noface, it doesn't need to.
    const leaving = if (a.input.stashed) |act| act != .lock else false;
    if (!leaving) try closeMenu(a, background);
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
        try drawFresh(p.a, p.background);
    }

    pub fn onTap(p: *LibraryPanel, t: screen.Tap) !screen.Step(void) {
        const choice = menu.hit(t.x, t.y);
        if (try panelControl(p.a, p.background, choice, t.x)) return .stay; // Drew itself
        return switch (choice) {
            .settings => {
                lipc.openSettings();
                return .{ .done = {} };
            },
            .kindle => .{ .done = {} }, // noface.sh brings back the Kindle's home
            .close => .close,
            else => .stay,
        };
    }
};
