//! Sends fake touches to the panel's input device, for testing on the Kindle.
//! Usage: touchsim tap <x> <y>
//!        touchsim drag <x0> <y0> <x1> <y1> <steps> <delay-ms> [hold-ms]
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const sleep_ms = core.os.sleep_ms;
const linux = std.os.linux;

/// The kernel's `input_event` on 32-bit ARM.
const InputEvent = extern struct { sec: u32 = 0, usec: u32 = 0, kind: u16, code: u16, value: i32 };

const ev_syn = 0;
const ev_key = 1;
const ev_abs = 3;
const btn_touch = 0x14a; // "A finger is down": the stock UI waits for it, noface doesn't need it
const abs_mt_touch_major = 0x30;
const abs_mt_slot = 0x2f;
const abs_mt_position_x = 0x35;
const abs_mt_position_y = 0x36;
const abs_mt_tracking_id = 0x39;
/// A fingertip's contact size, as the panel sends.
const touch_major_fingertip = 8;
/// The first finger's id: far from the panel's own, so the app sees a new finger.
const tracking_id_first = 9000;
/// How long a tap's finger stays down: a finger's, longer than running mode takes
/// for a drop of sweat (model/running.zig).
pub const tap_ms = 80;

comptime {
    assert(@sizeOf(InputEvent) == 16);
    assert(abs_mt_position_y == abs_mt_position_x + 1);
    // A finger's id is never negative while it's down: -1 lifts it.
    assert(tracking_id_first > 0);
}

/// The panel's input device, open for writing, and the finger we press on it. Also
/// pressed by tools/e2e.zig.
pub const Panel = struct {
    fd: i32,
    tracking_id_next: i32 = tracking_id_first,
    finger_down: bool = false,

    /// The Kindle's touch panel, for pressing.
    pub fn open() !Panel {
        const rc = linux.open("/dev/input/event1", .{ .ACCMODE = .WRONLY }, 0);
        if (core.os.failed(rc)) return error.NoTouchPanel;
        const panel = Panel{ .fd = @intCast(rc) };
        assert(panel.fd >= 0);
        assert(!panel.finger_down);
        return panel;
    }

    fn send(panel: *const Panel, kind: u16, code: u16, value: i32) void {
        assert(panel.fd >= 0);
        assert(kind == ev_syn or kind == ev_key or kind == ev_abs);
        var event = InputEvent{ .kind = kind, .code = code, .value = value };
        _ = linux.write(panel.fd, @ptrCast(&event), @sizeOf(InputEvent));
    }

    pub fn down(panel: *Panel, x: i32, y: i32) void {
        assert(!panel.finger_down);
        assert(panel.tracking_id_next >= tracking_id_first);
        panel.send(ev_abs, abs_mt_slot, 0);
        panel.send(ev_abs, abs_mt_tracking_id, panel.tracking_id_next);
        panel.tracking_id_next += 1;
        panel.send(ev_abs, abs_mt_position_x, x);
        panel.send(ev_abs, abs_mt_position_y, y);
        panel.send(ev_abs, abs_mt_touch_major, touch_major_fingertip);
        panel.send(ev_key, btn_touch, 1);
        panel.send(ev_syn, 0, 0);
        panel.finger_down = true;
        assert(panel.tracking_id_next > tracking_id_first);
    }

    pub fn move(panel: *const Panel, x: i32, y: i32) void {
        assert(panel.finger_down);
        panel.send(ev_abs, abs_mt_position_x, x);
        panel.send(ev_abs, abs_mt_position_y, y);
        panel.send(ev_syn, 0, 0);
    }

    pub fn up(panel: *Panel) void {
        assert(panel.finger_down);
        assert(panel.tracking_id_next > tracking_id_first);
        panel.send(ev_abs, abs_mt_tracking_id, -1);
        panel.send(ev_key, btn_touch, 0);
        panel.send(ev_syn, 0, 0);
        panel.finger_down = false;
    }
};

/// What the command line asks for, read whole before a finger lands: a word that isn't a
/// number is a mistake, never a place to touch.
const Gesture = union(enum) {
    tap: struct { x: u16, y: u16 },
    drag: Drag,
};

const Drag = struct {
    x0: u16,
    y0: u16,
    x1: u16,
    y1: u16,
    steps: u16,
    delay_ms: u32,
    hold_ms: u32, // Held still first, to start a hold: 0 for none
};

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len < 2) return error.Usage;
    const gesture = try parse(argv[1..]);
    var panel = try Panel.open();
    switch (gesture) {
        .tap => |at| {
            const down_us = core.os.now_us();
            panel.down(at.x, at.y);
            sleep_ms(tap_ms);
            panel.up();
            // When it touched and lifted, on fbrec's clock, for timing what follows
            std.debug.print("touch {d} {d}\n", .{ down_us, core.os.now_us() });
        },
        .drag => |drag_asked| {
            drag(&panel, drag_asked);
            std.debug.print("lift {d}\n", .{core.os.now_us()});
        },
    }
    assert(!panel.finger_down);
}

/// The gesture the words after the program's name ask for: `tap <x> <y>`, or
/// `drag <x0> <y0> <x1> <y1> <steps> <delay-ms> [hold-ms]`.
fn parse(words: []const [*:0]const u8) error{Usage}!Gesture {
    if (words.len == 0) return error.Usage;
    const verb = std.mem.sliceTo(words[0], 0);
    if (std.mem.eql(u8, verb, "tap")) {
        if (words.len != 3) return error.Usage;
        return .{ .tap = .{ .x = try number(u16, words[1]), .y = try number(u16, words[2]) } };
    }
    if (!std.mem.eql(u8, verb, "drag")) return error.Usage;
    if (words.len < 7) return error.Usage;
    if (words.len > 8) return error.Usage;
    return .{ .drag = .{
        .x0 = try number(u16, words[1]),
        .y0 = try number(u16, words[2]),
        .x1 = try number(u16, words[3]),
        .y1 = try number(u16, words[4]),
        .steps = try number(u16, words[5]),
        .delay_ms = try number(u32, words[6]),
        .hold_ms = if (words.len == 8) try number(u32, words[7]) else 0,
    } };
}

/// A word as a number of type `T`: a place on the screen in its pixels (no screen is
/// wider or taller than a u16), or a count or time, which is never negative.
fn number(comptime T: type, word: [*:0]const u8) error{Usage}!T {
    return std.fmt.parseInt(T, std.mem.sliceTo(word, 0), 10) catch error.Usage;
}

/// A finger pressed at the start, moved in `steps` even steps, and lifted at the end.
fn drag(panel: *Panel, asked: Drag) void {
    assert(!panel.finger_down);
    panel.down(asked.x0, asked.y0);
    // Press before moving, to start a hold
    sleep_ms(asked.hold_ms);
    var x: i32 = asked.x0;
    var y: i32 = asked.y0;
    var step: u32 = 1;
    while (step <= asked.steps) : (step += 1) {
        sleep_ms(asked.delay_ms);
        x = along(asked.x0, asked.x1, step, asked.steps);
        y = along(asked.y0, asked.y1, step, asked.steps);
        panel.move(x, y);
    }
    // The last step lands where the drag ends.
    if (asked.steps > 0) assert(x == asked.x1);
    if (asked.steps > 0) assert(y == asked.y1);
    sleep_ms(asked.delay_ms);
    panel.up();
}

/// Step `step` of `steps` on the way from `from` to `to`. In 64 bits: a whole screen's
/// distance times a u16's steps overflows 32.
fn along(from: u16, to: u16, step: u32, steps: u16) i32 {
    assert(steps > 0);
    assert(step <= steps);
    const moved = @divTrunc((@as(i64, to) - from) * step, steps);
    return @intCast(from + moved);
}

test "touchsim reads every number before touching, and a bad one is a mistake" {
    const Words = []const [*:0]const u8;
    const tap = try parse(&[_][*:0]const u8{ "tap", "600", "700" });
    try std.testing.expectEqual(@as(u16, 600), tap.tap.x);
    try std.testing.expectEqual(@as(u16, 700), tap.tap.y);
    const drag_words: Words = &.{ "drag", "100", "200", "300", "400", "10", "5", "500" };
    const dragged = (try parse(drag_words)).drag;
    try std.testing.expectEqual(@as(u16, 400), dragged.y1);
    try std.testing.expectEqual(@as(u32, 500), dragged.hold_ms);
    const no_hold: Words = &.{ "drag", "100", "200", "300", "400", "10", "5" };
    try std.testing.expectEqual(@as(u32, 0), (try parse(no_hold)).drag.hold_ms);
    // A typo, a negative hold, a place past any screen, a word too few or too many
    const mistakes = [_]Words{
        &.{ "tap", "600", "7OO" },
        &.{ "tap", "600" },
        &.{ "tap", "600", "700", "800" },
        &.{ "tap", "-1", "700" },
        &.{ "tap", "70000", "700" },
        &.{ "drag", "100", "200", "300", "400", "10", "5", "-500" },
        &.{ "drag", "100", "200", "300", "400", "10", "-5" },
        &.{ "drag", "100", "200", "300", "400", "10" },
        &.{ "drag", "100", "200", "300", "400", "10", "5", "500", "1" },
        &.{ "press", "600", "700" },
        &.{},
    };
    for (mistakes) |words| try std.testing.expectError(error.Usage, parse(words));
}

test "a drag's steps land evenly and the last where it ends" {
    try std.testing.expectEqual(@as(i32, 0), along(0, 65535, 0, 65535));
    try std.testing.expectEqual(@as(i32, 65535), along(0, 65535, 65535, 65535));
    try std.testing.expectEqual(@as(i32, 150), along(100, 200, 1, 2));
    try std.testing.expectEqual(@as(i32, 50), along(100, 0, 1, 2));
}
