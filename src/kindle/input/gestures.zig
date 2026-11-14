//! Raw touches into actions: which finger is down where, and when a press becomes a
//! tap, a hold, a drag or a swipe. These are `Input`'s methods (input.zig names each
//! one), kept here as they're their own subject; the state they keep is Input's.
const std = @import("std");
const input = @import("../input.zig");
const evdev = @import("evdev.zig");
const touch_zones = @import("../touch.zig");
const os = @import("../../sys/os.zig");
const Input = input.Input;
const Action = input.Action;
const InputEvent = evdev.InputEvent;
const now_us = os.now_us;
const ev_abs = evdev.ev_abs;
const abs_mt_slot = evdev.abs_mt_slot;
const abs_mt_x = evdev.abs_mt_x;
const abs_mt_y = evdev.abs_mt_y;
const abs_mt_tracking = evdev.abs_mt_tracking;

/// Whether a touch at (x, y) is taken for a resting thumb and ignored.
pub fn ignores(in: *const Input, x: i32, y: i32) bool {
    if (!(in.edge_zones and in.grips and touch_zones.is_grip(x, y, in.width, in.height))) return false;
    if (in.grip_exempt) |r| {
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return false;
    }
    return true;
}

/// A press on a page that stayed put long enough: a hold, followed from here as a drag.
pub fn held_long_enough(in: *Input) ?Action {
    const slot = in.top_slot orelse return null;
    if (!in.deferred or in.top_moved) return null;
    if (now_us() -| in.top_us < touch_zones.hold_ms * 1000) return null;
    in.top_slot = null;
    in.drag_slot = slot;
    return .{ .hold = .{ .x = in.top_x, .y = in.top_y } };
}

/// One raw event from the touch panel, turned into an action when one is complete.
pub fn handle(in: *Input, e: InputEvent) ?Action {
    if (e.kind == ev_abs) return on_axis(in, e);
    // A packet of events ends with a SYN: a new touch's place is known only then
    if (e.kind == 0) return on_packet_end(in);
    return null;
}

pub fn screen_x(in: *const Input, slot: usize) i32 {
    return @divTrunc(in.xs[slot] * in.width, in.x_max);
}

pub fn screen_y(in: *const Input, slot: usize) i32 {
    return @divTrunc(in.ys[slot] * in.height, in.y_max);
}

/// A finger's slot, place, or touching down or lifting.
pub fn on_axis(in: *Input, e: InputEvent) ?Action {
    switch (e.code) {
        abs_mt_slot => in.slot = @min(@as(usize, @intCast(@max(e.value, 0))), 1),
        abs_mt_x => in.xs[in.slot] = e.value,
        abs_mt_y => in.ys[in.slot] = e.value,
        abs_mt_tracking => {
            if (e.value < 0) return finger_up(in);
            in.pending = in.slot; // Down: where is known at the packet's end
            in.down_us = @as(u64, e.sec) * 1_000_000 + e.usec;
        },
        else => {},
    }
    return null;
}

pub fn finger_up(in: *Input) ?Action {
    if (in.drag_slot == in.slot) {
        in.drag_slot = null;
        return .drag_end;
    }
    if (in.top_slot == in.slot) {
        in.top_slot = null;
        return lifted(in);
    }
    return null;
}

/// A finger lifted that nothing was following: a sideways stroke is a swipe, and a
/// finger that stayed put or only rolled a little a tap where it began. A real
/// stroke some other way is neither: turning a page by where an arc began would be
/// a guess, often the wrong way.
pub fn lifted(in: *Input) ?Action {
    const x = screen_x(in, in.slot);
    const y = screen_y(in, in.slot);
    if (in.top_moved) {
        if (touch_zones.swipe_direction(in.top_x, in.top_y, x, y)) |dir| return .{ .swipe = dir };
        if (touch_zones.is_stroke(in.top_x, in.top_y, x, y)) return null;
    }
    return .{ .tap = .{ .x = in.top_x, .y = in.top_y, .us = in.top_us } };
}

/// The end of a packet: a followed finger moved, a pressed one moved or pulled
/// down from the top, or a new touch landed.
pub fn on_packet_end(in: *Input) ?Action {
    if (in.drag_slot) |slot| {
        in.pending = null;
        in.drag_y = screen_y(in, slot);
        return .{ .drag = screen_x(in, slot) };
    }
    if (in.top_slot) |slot| {
        const x = screen_x(in, slot);
        const y = screen_y(in, slot);
        if (touch_zones.moved_off(in.top_x, in.top_y, x, y)) in.top_moved = true;
        if (in.top_y < touch_zones.top_zone and touch_zones.is_pull(in.top_y, y)) {
            in.top_slot = null;
            return .pull;
        }
    }
    const touched = in.pending orelse return null;
    in.pending = null;
    return touched_down(in, touched);
}

/// A new touch: ignored as a resting thumb, a tap at once, or (on a book page, and
/// at the top edge) a press to watch until it lifts, moves or is held.
pub fn touched_down(in: *Input, slot: usize) ?Action {
    in.last_touched = slot;
    const x = screen_x(in, slot);
    const y = screen_y(in, slot);
    if (ignores(in, x, y)) return null;
    const watch = in.deferred or (in.edge_zones and y < touch_zones.top_zone);
    if (!watch) return .{ .tap = .{ .x = x, .y = y, .us = in.down_us } };
    in.top_slot = slot;
    in.top_x = x;
    in.top_y = y;
    in.top_us = in.down_us;
    in.top_moved = false;
    return null;
}

/// Left third goes back a page, the rest forward.
pub fn turn_direction(x: i32, width: i32) i32 {
    return if (x < @divTrunc(width, 3)) -1 else 1;
}

pub fn test_input() Input {
    return .{ .touch = -1, .power = -1, .width = 1272, .height = 1696, .x_max = 1272, .y_max = 1696 };
}

pub fn ev(kind: u16, code: u16, value: i32) InputEvent {
    return .{ .sec = 0, .usec = 0, .kind = kind, .code = code, .value = value };
}

/// Feeds one finger's down (or move) packet, returning what it produced.
pub fn press(in: *Input, slot: i32, x: i32, y: i32, new: bool) ?Action {
    _ = handle(in, ev(ev_abs, abs_mt_slot, slot));
    if (new) _ = handle(in, ev(ev_abs, abs_mt_tracking, 7));
    _ = handle(in, ev(ev_abs, abs_mt_x, x));
    _ = handle(in, ev(ev_abs, abs_mt_y, y));
    return handle(in, ev(0, 0, 0));
}

pub fn lift(in: *Input, slot: i32) ?Action {
    _ = handle(in, ev(ev_abs, abs_mt_slot, slot));
    const up = handle(in, ev(ev_abs, abs_mt_tracking, -1));
    const synced = handle(in, ev(0, 0, 0));
    return up orelse synced;
}

test "a touch in the middle taps at once" {
    var in = test_input();
    const a = press(&in, 0, 900, 900, true).?;
    try std.testing.expectEqual(@as(i32, 900), a.tap.x);
    try std.testing.expect(lift(&in, 0) == null);
}

test "on book pages a tap waits for the finger to lift" {
    var in = test_input();
    in.deferred = true;
    try std.testing.expect(press(&in, 0, 900, 900, true) == null);
    try std.testing.expectEqual(@as(i32, 900), lift(&in, 0).?.tap.y);
}

test "the top edge taps on lift, unless edge zones are off" {
    var in = test_input();
    try std.testing.expect(press(&in, 0, 500, 100, true) == null);
    try std.testing.expectEqual(@as(i32, 100), lift(&in, 0).?.tap.y);
    in.edge_zones = false;
    try std.testing.expectEqual(@as(i32, 100), press(&in, 0, 500, 100, true).?.tap.y);
}

test "a resting thumb is ignored, unless edge zones are off" {
    var in = test_input();
    try std.testing.expect(press(&in, 1, 150, 1600, true) == null);
    try std.testing.expect(lift(&in, 1) == null);
    in.edge_zones = false;
    try std.testing.expect(press(&in, 1, 150, 1600, true) != null);
}

test "dragging down from the top pulls the panel" {
    var in = test_input();
    try std.testing.expect(press(&in, 0, 600, 40, true) == null);
    try std.testing.expect(press(&in, 0, 600, 200, false).? == .pull);
}

test "a followed finger drags, then ends on lift" {
    var in = test_input();
    _ = press(&in, 0, 300, 900, true);
    in.begin_drag();
    try std.testing.expectEqual(@as(i32, 420), press(&in, 0, 420, 910, false).?.drag);
    try std.testing.expectEqual(@as(i32, 910), in.drag_y);
    try std.testing.expect(lift(&in, 0).? == .drag_end);
}

test "on waiting pages a sideways stroke swipes instead of tapping" {
    var in = test_input();
    in.deferred = true;
    try std.testing.expect(press(&in, 0, 900, 800, true) == null);
    _ = press(&in, 0, 600, 810, false);
    try std.testing.expectEqual(@as(i32, 1), lift(&in, 0).?.swipe);
    try std.testing.expect(press(&in, 0, 900, 800, true) == null);
    _ = press(&in, 0, 920, 805, false); // A wobble
    try std.testing.expectEqual(@as(i32, 900), lift(&in, 0).?.tap.x);
    // A thumb's arc, as far down as across, still swipes
    try std.testing.expect(press(&in, 0, 900, 700, true) == null);
    _ = press(&in, 0, 780, 760, false);
    _ = press(&in, 0, 650, 860, false);
    try std.testing.expectEqual(@as(i32, 1), lift(&in, 0).?.swipe);
    // Moved, but mostly up or down: nothing, not a tap where it began
    try std.testing.expect(press(&in, 0, 600, 600, true) == null);
    _ = press(&in, 0, 620, 900, false);
    try std.testing.expect(lift(&in, 0) == null);
    // A finger that rolls 40 px is still a tap
    try std.testing.expect(press(&in, 0, 400, 1140, true) == null);
    _ = press(&in, 0, 440, 1140, false);
    try std.testing.expectEqual(@as(i32, 400), lift(&in, 0).?.tap.x);
}

test "a second finger taps while a thumb rests" {
    var in = test_input();
    _ = press(&in, 0, 150, 1600, true); // Thumb, ignored
    try std.testing.expectEqual(@as(i32, 800), press(&in, 1, 800, 800, true).?.tap.x);
}
