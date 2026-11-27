//! The quick panel: light, warmth, airplane mode, Bluetooth, sync and the place's sync,
//! over a book or the library.
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
    var fresh = lipc.read(a.quick);
    fresh.wifi_paused = paused_by_noface(fresh.airplane);
    // Asked only while connected: off, or with wifid not answering (its state read
    // timed out), there's no name, and no second wait for one
    fresh.network_len = 0;
    if (fresh.wifi_on and !fresh.airplane) {
        fresh.network_len = @intCast(lipc.network_name(&fresh.network).len);
    }
    if (fresh.wifi_paused) assert(fresh.airplane); // A pause is airplane mode, noface's
    if (fresh.same(&a.quick)) return;
    a.quick = fresh;
    try draw_menu(a, background, null);
    assert(fresh.same(&a.quick));
}

/// Draws the quick panel over `background` and shows it, `notice` in its header if
/// there's one.
fn draw_menu(a: *app.App, background: display.Backdrop, notice: ?[]const u8) !void {
    assert(background.holds(&a.display));
    assert(menu.height <= a.display.screen.height);
    try menu.render(a.ui, a.display.compose(background), &a.quick, notice);
    a.display.put_composed();
    try a.display.show_band(0, menu.height);
}

fn close_menu(a: *app.App, background: display.Backdrop) !void {
    assert(menu.height <= a.display.screen.height);
    a.display.put_back(background);
    try a.display.show_band(0, menu.height);
}

fn row_value(a: *app.App, row: menu.Row) u32 {
    const value = switch (row.light) {
        .warmth => a.quick.warmth,
        .brightness => a.quick.brightness,
    };
    assert(value <= row.max); // Read and set as one of its steps
    return value;
}

fn set_row_value(a: *app.App, row: menu.Row, level: u32) void {
    assert(level <= row.max);
    switch (row.light) {
        .warmth => {
            a.quick.warmth = level;
            lipc.set_warmth(level, a.quick.schedule);
        },
        .brightness => {
            a.quick.brightness = level;
            lipc.set_brightness(level);
        },
    }
    assert(row_value(a, row) == level);
}

/// Shows a slider row at rest after a step, without a flash.
fn show_row(a: *app.App, row: menu.Row, level: u32) !void {
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
    assert(row.max > 0); // A slider has steps
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
    assert(sd.ending != null); // Called once the drag has ended
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
        .airplane, .wifi, .bluetooth, .sync, .place => try panel_control_shortcut(a, choice),
        .schedule => {
            a.quick.schedule = !a.quick.schedule;
            try draw_menu(a, background, null);
            lipc.set_schedule(a.quick.schedule);
        },
        // Not a control: closing and leaving are the caller's. Every Hit is named, so
        // a new tile doesn't compile until it's handled here or there
        .none, .close, .kindle => return .not_one,
    }
    return .ran;
}

/// A round shortcut at the top of the panel: airplane mode, Wi-Fi (airplane mode's
/// other side), Bluetooth, sync or the place's sync. Its tile is redrawn first, and the
/// Kindle told while the screen shows it.
fn panel_control_shortcut(a: *app.App, choice: menu.Hit) !void {
    assert(menu.tile_of(choice) != null); // One of the round tiles
    a.quick = tapped(a.quick, choice);
    const box = menu.shortcut_box(choice).?;
    assert(box.y + box.h <= menu.height);
    try menu.draw_shortcut(a.ui, a.display.on_screen(), choice, &a.quick);
    const marker = try a.display.screen.show_region(box.x, box.y, box.w, box.h, .page);
    switch (choice) {
        .airplane, .wifi => {
            // The reader's choice now: noface neither undoes nor redoes it
            wifi_saver.forget();
            a.wifi_pause.reader_took_charge();
            lipc.set_airplane(a.quick.airplane);
        },
        .bluetooth => lipc.set_bluetooth(a.quick.bluetooth),
        .sync => {
            // Paused while reading: syncing needs it, for the rest of the book
            wifi_saver.restore();
            a.wifi_pause.reader_took_charge();
            lipc.sync_now();
        },
        .place => {
            // A setting of noface's own: kept with the rest, read as the next book opens
            a.user.settings.sync_place = a.quick.place_sync;
            a.user.save_settings();
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
        => unreachable, // Not a shortcut: `panel_control` runs those
    }
    try a.display.screen.wait_complete(marker);
    // Airplane mode and Wi-Fi are one switch shown on two tiles: the other follows
    if (choice == .airplane) try redraw_tile(a, .wifi);
    if (choice == .wifi) try redraw_tile(a, .airplane);
    if (is_radio(choice)) {
        // Airplane mode can take Bluetooth with it: shown as the Kindle has it now
        const bluetooth = lipc.bluetooth_on() orelse a.quick.bluetooth;
        if (bluetooth != a.quick.bluetooth) {
            a.quick.bluetooth = bluetooth;
            try redraw_tile(a, .bluetooth);
        }
    }
    if (choice == .sync and a.quick.airplane and wifi_saver.airplane() == .off) {
        // The tiles said airplane mode on, or Wi-Fi paused: show it on now
        a.quick.airplane = false;
        a.quick.wifi_paused = false;
        try redraw_tile(a, .airplane);
        try redraw_tile(a, .wifi);
    }
}

/// The header without the warning, drawn and shown alone.
fn put_warning_away(a: *app.App) !void {
    const box = menu.header_box;
    try menu.draw_header(a.ui, a.display.on_screen(), &a.quick, null);
    try a.display.show_rect(box.x, box.y, box.w, box.h);
}

/// What the header says when the radio is to go off with Bluetooth on.
const bluetooth_warning = "Bluetooth goes off too. Tap again to confirm.";

/// Whether tapping `choice` would turn the radio off (Wi-Fi off, airplane mode on)
/// while Bluetooth is on, which airplane mode cuts too: warned of first.
fn warns_first(quick: *const quick_model.Quick, choice: menu.Hit) bool {
    if (!is_radio(choice)) return false;
    if (!quick.bluetooth) return false;
    const after = tapped(quick.*, choice);
    return after.airplane and !quick.airplane;
}

/// What the panel shows once shortcut `choice` is tapped, from `quick` before it.
fn tapped(quick: quick_model.Quick, choice: menu.Hit) quick_model.Quick {
    var next = quick;
    switch (choice) {
        // Paused by noface, airplane mode showed off: on now, as the reader's own
        .airplane => if (quick.wifi_paused) {
            next.wifi_paused = false;
        } else {
            next.airplane = !quick.airplane;
        },
        .wifi => {
            next.wifi_paused = false; // Paused or not, the reader's choice from now
            next.airplane = !quick.airplane;
        },
        .bluetooth => next.bluetooth = !quick.bluetooth,
        .sync => next.syncing = true,
        .place => next.place_sync = !quick.place_sync,
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
    // The radio switched: connected to nothing yet, whatever was read before
    if (is_radio(choice)) {
        next.wifi_on = false;
        next.network_len = 0;
    }
    // Airplane mode is noface's pause only until the reader touches either tile
    if (is_radio(choice)) assert(!next.wifi_paused);
    if (next.wifi_paused) assert(quick.wifi_paused); // A tap never starts a pause
    return next;
}

/// Draws a shortcut's tile again as `a.quick` has it now, and shows it.
fn redraw_tile(a: *app.App, tile: menu.Hit) !void {
    assert(tile != .none);
    const box = menu.shortcut_box(tile).?; // A shortcut, which has a tile
    assert(box.y + box.h <= menu.height);
    try menu.draw_shortcut(a.ui, a.display.on_screen(), tile, &a.quick);
    try a.display.show_rect(box.x, box.y, box.w, box.h);
}

/// The quick panel, to open over the library or a book drawn in `background`.
pub fn open(a: *app.App, background: display.Backdrop) Panel {
    assert(background.holds(&a.display));
    a.quick.wifi_paused = paused_by_noface(a.quick.airplane);
    a.quick.place_sync = a.user.settings.sync_place; // The setting, as the tile shows it
    return .{ .a = a, .background = background };
}

/// Whether airplane mode, `on` as last read, is noface's own pause while reading: its
/// note says so (kindle/wifi_saver.zig).
fn paused_by_noface(on: bool) bool {
    return on and wifi_saver.marked();
}

/// Whether `choice` is one of the radio's two tiles: Wi-Fi, or airplane mode, its other
/// side, both showing airplane mode's state, as the tiles' table says.
fn is_radio(choice: menu.Hit) bool {
    const tile = menu.tile_of(choice) orelse return false;
    return tile.state == .airplane;
}

/// Once the panel has ended: true to go to the Kindle's own screens.
pub fn ended(
    a: *app.App,
    background: display.Backdrop,
    ending: screen.Ending(void),
) !bool {
    // "Syncing" answers the tap for as long as the panel's open: the Kindle says
    // nothing of when the sync is over, so the next panel offers it again
    a.quick.syncing = false;
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
    /// The radio tile (Wi-Fi or airplane mode) tapped to turn the radio off while
    /// Bluetooth is on: warned of in the header, it goes ahead only when tapped again.
    confirming: ?menu.Hit = null,

    /// Touches as a sheet takes them, and one tick at once, to read the status.
    pub fn setting(p: *const Panel) input_mod.Input.Scope {
        const tick_us: ?u64 = if (p.status_read) null else screen.after_shown_us;
        return .{ .modes = input_mod.Input.Modes.sheet, .tick_us = tick_us };
    }

    pub fn draw(p: *Panel, _: screen.Part) !void {
        const notice: ?[]const u8 = if (p.confirming != null) bluetooth_warning else null;
        try draw_menu(p.a, p.background, notice);
    }

    pub fn on_tick(p: *Panel) !screen.Step(void) {
        assert(!p.status_read); // Only one tick is asked for
        p.status_read = true;
        try refresh_status(p.a, p.background);
        return .stay;
    }

    pub fn on_tap(p: *Panel, t: screen.Tap) !screen.Step(void) {
        assert(p.background.holds(&p.a.display)); // What the panel is drawn over
        const choice = menu.hit(t.x, t.y);
        // The radio off cuts Bluetooth too: said first, done on a second tap
        const warned = p.confirming;
        p.confirming = null;
        if (warned != choice and warns_first(&p.a.quick, choice)) {
            p.confirming = choice;
            try draw_menu(p.a, p.background, bluetooth_warning);
            return .stay;
        }
        // Any tap puts the warning away: only the header drawn again, as the control
        // draws its own part, and a tap that closes the panel needs neither
        if (warned != null and choice != .close and choice != .kindle) try put_warning_away(p.a);
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
            .place,
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

test "a tap on either radio tile ends noface's pause, and only Wi-Fi's turns the radio on" {
    const paused = quick_model.Quick{ .airplane = true, .wifi_paused = true };
    const wifi = tapped(paused, .wifi);
    try std.testing.expect(!wifi.airplane);
    try std.testing.expect(!wifi.wifi_paused);
    const plane = tapped(paused, .airplane);
    try std.testing.expect(plane.airplane); // Kept off, now the reader's airplane mode
    try std.testing.expect(!plane.wifi_paused);
    // Not paused: each is the switch it shows
    const on = quick_model.Quick{};
    try std.testing.expect(tapped(on, .airplane).airplane);
    try std.testing.expect(tapped(on, .wifi).airplane);
    try std.testing.expect(!tapped(tapped(on, .wifi), .wifi).airplane);
}

test "turning the radio off with Bluetooth on warns first; on, or without Bluetooth, it doesn't" {
    const listening = quick_model.Quick{ .bluetooth = true };
    try std.testing.expect(warns_first(&listening, .wifi)); // Wi-Fi off
    try std.testing.expect(warns_first(&listening, .airplane)); // Airplane mode on
    const flying = quick_model.Quick{ .bluetooth = true, .airplane = true };
    try std.testing.expect(!warns_first(&flying, .wifi)); // Wi-Fi back on
    try std.testing.expect(!warns_first(&quick_model.Quick{}, .wifi)); // No Bluetooth
    try std.testing.expect(!warns_first(&listening, .bluetooth));
}

test "the place's tile switches the place's sync, and touches nothing else" {
    const synced = quick_model.Quick{ .place_sync = true };
    const off = tapped(synced, .place);
    try std.testing.expect(!off.place_sync);
    try std.testing.expect(tapped(off, .place).place_sync);
    try std.testing.expect(off.airplane == synced.airplane);
    try std.testing.expect(off.bluetooth == synced.bluetooth);
}
