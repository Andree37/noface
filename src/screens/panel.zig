//! The quick panel: light, warmth, airplane mode, Bluetooth and sync, over a book or the library.
const std = @import("std");
const assert = std.debug.assert;
const drag = @import("drag.zig");
const menu = @import("../ui/menu.zig");
const wifi_saver = @import("../kindle/wifi_saver.zig");
const lipc = @import("../kindle/lipc.zig");
const quick_model = @import("../model/quick.zig");
const app = @import("../app.zig");
const display = @import("../display.zig");
const screen = @import("screen.zig");
const input_mod = @import("../kindle/input.zig");

/// How soon after it opens the panel reads the status: at once, once it's shown.
const status_read_after_us = 1000;

comptime {
    // A row is told apart from the other by its place alone
    assert(menu.warmth_row.y != menu.brightness_row.y);
    // Each slider's band, redrawn on its own, is inside the panel
    assert(menu.band_top(menu.brightness_row) + menu.band_height <= menu.height);
    assert(menu.band_top(menu.warmth_row) + menu.band_height <= menu.height);
}

/// Reads the status again (about a quarter second of lipc calls), and redraws the
/// panel only if something changed.
fn refresh_status(a: *app.App, background: display.Backdrop) !void {
    const fresh = lipc.read(a.quick);
    if (fresh.same(&a.quick)) return;
    a.quick = fresh;
    try draw_menu(a, background);
    assert(fresh.same(&a.quick));
}

/// Draws the quick panel over `background` and shows it.
fn draw_menu(a: *app.App, background: display.Backdrop) !void {
    assert(background.holds(&a.display));
    assert(menu.height <= a.display.screen.height);
    try menu.render(a.ui, a.display.compose(background), &a.quick);
    a.display.put_composed();
    try a.display.show_band(0, menu.height);
}

fn close_menu(a: *app.App, background: display.Backdrop) !void {
    assert(menu.height <= a.display.screen.height);
    a.display.put_back(background);
    try a.display.show_band(0, menu.height);
}

fn row_value(a: *app.App, row: menu.Row) u32 {
    assert(row.y == menu.warmth_row.y or row.y == menu.brightness_row.y);
    if (row.y == menu.warmth_row.y) {
        assert(row.max == menu.warmth_row.max);
        return a.quick.warmth;
    }
    assert(row.max == menu.brightness_row.max);
    return a.quick.brightness;
}

fn set_row_value(a: *app.App, row: menu.Row, level: u32) void {
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
    try menu.draw_slider(a.ui, a.display.on_screen(), row, level, false);
    try a.display.show_band(menu.band_top(row), menu.band_height);
}

/// Following a finger along a panel slider from where it landed until it lifts, kept
/// while it's open over the panel. The knob slides under the finger; the light
/// changes a step at a time, after each frame is on its way, so the lipc call never
/// holds the knob back.
const SliderDrag = struct {
    row: menu.Row = undefined,
    knob: u32 = 0,
    path: [2]u32 = .{ 0, 0 }, // Leftmost and rightmost knob positions shown
    drag: drag.Drag(SliderFollow) = undefined,
    ending: ?screen.Ending(void) = null,
};

const SliderFollow = struct {
    a: *app.App,
    row: menu.Row,
    knob: *u32,
    path: *[2]u32,

    pub fn moved(f: SliderFollow, x: i32, _: i32) !?u32 {
        assert(f.path[0] <= f.path[1]);
        const knob = menu.knob_under(x);
        if (knob == f.knob.*) return null;
        const level = menu.level_at(f.row, x);
        assert(level <= f.row.max);
        const page = f.a.display.on_screen();
        try menu.draw_slider_at(f.a.ui, page, f.row, level, knob, true);
        const span = menu.knob_span(f.knob.*, knob);
        f.knob.* = knob;
        f.path.* = .{ @min(f.path[0], knob), @max(f.path[1], knob) };
        assert(f.path[0] <= knob);
        assert(knob <= f.path[1]);
        const top = menu.band_top(f.row);
        const marker = try f.a.display.screen.show_region(
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

/// Starts following a finger along slider `row`, from where it landed: the screen to
/// open over the panel.
fn drag_row(a: *app.App, sd: *SliderDrag, row: menu.Row, first_x: i32) !screen.Frame {
    assert(row.y == menu.warmth_row.y or row.y == menu.brightness_row.y);
    sd.row = row;
    sd.knob = menu.knob_at(row, row_value(a, row));
    sd.path = .{ sd.knob, sd.knob };
    const follow = SliderFollow{ .a = a, .row = row, .knob = &sd.knob, .path = &sd.path };
    const first = try follow.moved(first_x, 0);
    sd.drag = .{ .a = a, .follow = follow, .marker = first };
    assert(sd.path[0] <= sd.path[1]);
    return screen.open(&sd.drag, &sd.ending);
}

/// The finger lifted from a slider (or the Kindle locked): settles the stretch the
/// knob crossed back to smooth edges.
fn slider_ended(a: *app.App, sd: *SliderDrag) !void {
    _ = try drag.ended(&sd.drag, sd.ending.?);
    const row = sd.row;
    assert(sd.path[0] <= sd.path[1]);
    try menu.draw_slider(a.ui, a.display.on_screen(), row, row_value(a, row), false);
    const crossed = menu.knob_span(sd.path[0], sd.path[1]);
    try a.display.clean_rect(crossed.left, menu.band_top(row), crossed.width, menu.band_height);
}

/// What a tap on the panel did: nothing (it wasn't on a control), ran a control, or
/// began a slider's drag, to open over the panel.
const Control = union(enum) { not_one, ran, drag: screen.Frame };

/// Runs a panel control. Each control redraws only its own part of the panel, before
/// telling the Kindle, so the tap answers at once. A slider follows the finger in
/// `slider`, opened over the panel.
fn panel_control(
    a: *app.App,
    background: display.Backdrop,
    choice: menu.Hit,
    x: i32,
    slider: *SliderDrag,
) !Control {
    switch (choice) {
        .slider => return .{ .drag = try drag_row(a, slider, menu.brightness_row, x) },
        .warmth => return .{ .drag = try drag_row(a, slider, menu.warmth_row, x) },
        .dimmer, .brighter, .cooler, .warmer => {
            const brightness = choice == .dimmer or choice == .brighter;
            const row = if (brightness) menu.brightness_row else menu.warmth_row;
            const up = choice == .brighter or choice == .warmer;
            const level = quick_model.step_level(row_value(a, row), up, row.max);
            try show_row(a, row, level);
            set_row_value(a, row, level);
        },
        .airplane, .wifi, .bluetooth, .sync => try panel_control_shortcut(a, choice),
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            try draw_menu(a, background);
            lipc.set_schedule(a.quick.schedule);
        },
        // Not a control: closing and leaving are the caller's. Every Hit is named, so
        // a new tile doesn't compile until it's handled here or there
        .none, .close, .kindle => return .not_one,
    }
    return .ran;
}

/// A round shortcut at the top of the panel: airplane mode, Wi-Fi (airplane mode's
/// other side), Bluetooth or sync. Its tile is redrawn first, and the Kindle told
/// while the screen shows it.
fn panel_control_shortcut(a: *app.App, choice: menu.Hit) !void {
    assert(choice == .airplane or choice == .wifi or choice == .bluetooth or choice == .sync);
    switch (choice) {
        .airplane, .wifi => a.quick.airplane = !a.quick.airplane,
        .bluetooth => a.quick.bluetooth = !a.quick.bluetooth,
        .sync => a.quick.syncing = true,
        .none,
        .close,
        .dimmer,
        .brighter,
        .slider,
        .cooler,
        .warmer,
        .warmth,
        .schedule,
        .kindle,
        => unreachable, // Not a shortcut: `panel_control` runs those
    }
    const box = menu.shortcut_box(choice).?;
    assert(box.y + box.h <= menu.height);
    try menu.draw_shortcut(a.ui, a.display.on_screen(), choice, &a.quick);
    const marker = try a.display.screen.show_region(
        box.x,
        box.y,
        box.w,
        box.h,
        .page,
    );
    switch (choice) {
        .airplane, .wifi => {
            // The reader's choice now: noface neither undoes nor redoes it
            wifi_saver.forget();
            a.wifi_hands_off = true;
            lipc.set_airplane(a.quick.airplane);
        },
        .bluetooth => lipc.set_bluetooth(a.quick.bluetooth),
        .sync => {
            // Paused while reading: syncing needs it, for the rest of the book
            wifi_saver.restore();
            a.wifi_hands_off = true;
            lipc.sync_now();
        },
        .none,
        .close,
        .dimmer,
        .brighter,
        .slider,
        .cooler,
        .warmer,
        .warmth,
        .schedule,
        .kindle,
        => unreachable, // Not a shortcut, as above
    }
    try a.display.screen.wait_complete(marker);
    // Airplane mode and Wi-Fi are one switch shown on two tiles: the other follows
    if (choice == .airplane) try redraw_tile(a, .wifi);
    if (choice == .wifi) try redraw_tile(a, .airplane);
    if (choice == .sync and a.quick.airplane and wifi_saver.airplane() == .off) {
        // The tiles said airplane mode on: show it off now
        a.quick.airplane = false;
        try redraw_tile(a, .airplane);
        try redraw_tile(a, .wifi);
    }
}

/// Draws a shortcut's tile again as `a.quick` has it now, and shows it.
fn redraw_tile(a: *app.App, tile: menu.Hit) !void {
    const box = menu.shortcut_box(tile).?; // A shortcut, which has a tile
    assert(box.y + box.h <= menu.height);
    try menu.draw_shortcut(a.ui, a.display.on_screen(), tile, &a.quick);
    try a.display.show_rect(box.x, box.y, box.w, box.h);
}

/// The quick panel, to open over the library or a book drawn in `background`.
pub fn open(a: *app.App, background: display.Backdrop) Panel {
    assert(background.holds(&a.display));
    return .{ .a = a, .background = background };
}

/// Once the panel has ended: true to go to the Kindle's own screens.
pub fn ended(
    a: *app.App,
    background: display.Backdrop,
    ending: screen.Ending(void),
) !bool {
    switch (ending) {
        .done => return true,
        // Closed, or the Kindle locking: what was under it comes back
        .closed => try close_menu(a, background),
        .interrupted => |action| {
            // Leaving noface: it needn't
            if (action == .lock) try close_menu(a, background);
        },
    }
    assert(ending != .done);
    return false;
}

/// Touches as they land, as in the reader: a slider follows the finger from there, and
/// a tap that only arrived on the lift would leave it waiting for a drag. Done when
/// noface should go to the Kindle's own screens.
pub const Panel = struct {
    pub const Result = void;
    a: *app.App,
    background: display.Backdrop,
    slider: SliderDrag = .{}, // A slider followed, over it
    /// The status read again since it opened. It's drawn at once with the last one
    /// read, and read on its first tick: a screen counts as shown once it's drawn, and
    /// a tap touched before that is dropped, so a read while drawing lost the taps of
    /// a reader who saw the panel and went on.
    status_read: bool = false,

    /// Touches as a sheet takes them, and one tick at once, to read the status.
    pub fn setting(p: *const Panel) input_mod.Input.Scope {
        const tick_us: ?u64 = if (p.status_read) null else status_read_after_us;
        return .{ .modes = input_mod.Input.Modes.sheet, .tick_us = tick_us };
    }

    pub fn draw(p: *Panel, _: screen.Part) !void {
        try draw_menu(p.a, p.background);
    }

    pub fn on_tick(p: *Panel) !screen.Step(void) {
        assert(!p.status_read); // Only one tick is asked for
        p.status_read = true;
        try refresh_status(p.a, p.background);
        return .stay;
    }

    pub fn on_tap(p: *Panel, t: screen.Tap) !screen.Step(void) {
        const choice = menu.hit(t.x, t.y);
        switch (try panel_control(p.a, p.background, choice, t.x, &p.slider)) {
            .not_one => {},
            .ran => return .stay, // Drew itself
            .drag => |f| return .{ .push = f },
        }
        // Every control drew itself above: what's left closes the panel or leaves noface
        return switch (choice) {
            // The one way out of noface from the panel, said on its tile: the Kindle's
            // home comes back by the launcher
            .kindle => .{ .done = {} },
            .close => .close,
            .none => .stay,
            // Each ran above, as a control that draws itself
            .dimmer,
            .brighter,
            .slider,
            .cooler,
            .warmer,
            .warmth,
            .schedule,
            .airplane,
            .wifi,
            .bluetooth,
            .sync,
            => unreachable,
        };
    }

    /// The slider's drag ended.
    pub fn on_resume(p: *Panel) !screen.Step(void) {
        assert(p.slider.ending != null);
        try slider_ended(p.a, &p.slider);
        return .stay;
    }
};
