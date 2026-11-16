//! Raw touches into actions: which finger is down where, and when a press becomes a
//! tap, a hold, a drag or a swipe. These are `Input`'s methods (input.zig names each
//! one), kept here as they're their own subject; the state they keep is Input's.
const std = @import("std");
const assert = std.debug.assert;
const input = @import("../input.zig");
const evdev = @import("evdev.zig");
const touch_zones = @import("../touch.zig");
const os = @import("../../sys/os.zig");
const Input = input.Input;
const Action = input.Action;
const Press = input.Press;
const InputEvent = evdev.InputEvent;
const now_us = os.now_us;
const ev_abs = evdev.ev_abs;
const abs_mt_slot = evdev.abs_mt_slot;
const abs_mt_x = evdev.abs_mt_x;
const abs_mt_y = evdev.abs_mt_y;
const abs_mt_tracking = evdev.abs_mt_tracking;
const slots_count = Input.slots_count;

comptime {
    // A slot number from the panel is clamped to the last slot: there must be one
    assert(slots_count >= 1);
    // The kind of event that ends a packet (EV_SYN) is none of the others handled
    assert(ev_abs != 0);
    assert(evdev.ev_key != 0);
}

/// Whether a touch at (x, y) is taken for a resting thumb and ignored.
pub fn ignores(in: *const Input, x: i32, y: i32) bool {
    const grip = in.edge_zones and in.grips and touch_zones.is_grip(x, y, in.width, in.height);
    if (!grip) return false;
    if (in.grip_exempt) |zone| {
        assert(zone.w >= 0);
        assert(zone.h >= 0);
        const inside_x = x >= zone.x and x < zone.x + zone.w;
        const inside_y = y >= zone.y and y < zone.y + zone.h;
        if (inside_x and inside_y) return false;
    }
    return true;
}

/// A press on a page that stayed put long enough: a hold, followed from here as a drag.
pub fn held_long_enough(in: *Input) ?Action {
    const down = in.top orelse return null;
    assert(down.slot < slots_count);
    if (!in.deferred or down.moved) return null;
    if (now_us() -| down.us < touch_zones.hold_ms * 1000) return null;
    in.top = null;
    in.drag_slot = down.slot;
    in.invariants();
    return .{ .hold = .{ .x = down.x, .y = down.y } };
}

/// One raw event from the touch panel, turned into an action when one is complete.
pub fn handle(in: *Input, event: InputEvent) ?Action {
    in.invariants();
    defer in.invariants();
    if (event.kind == ev_abs) return on_axis(in, event);
    // A packet of events ends with a SYN: a new touch's place is known only then
    if (event.kind == 0) return on_packet_end(in);
    return null;
}

/// A place on the screen, in screen pixels.
const Point = struct { x: i32, y: i32 };

/// Where the finger in `slot` is, from the panel's range to the screen's.
pub fn screen_point(in: *const Input, slot: u32) Point {
    assert(slot < slots_count);
    assert(in.x_max >= 1);
    assert(in.y_max >= 1);
    return .{
        .x = @divTrunc(in.xs[slot] * in.width, in.x_max),
        .y = @divTrunc(in.ys[slot] * in.height, in.y_max),
    };
}

/// A finger's slot, place, or touching down or lifting.
pub fn on_axis(in: *Input, event: InputEvent) ?Action {
    assert(event.kind == ev_abs);
    switch (event.code) {
        abs_mt_slot => {
            // The panel's slot, clamped to the ones there are
            const slot_reported: u32 = @intCast(@max(event.value, 0));
            in.slot = @min(slot_reported, slots_count - 1);
        },
        abs_mt_x => in.xs[in.slot] = event.value,
        abs_mt_y => in.ys[in.slot] = event.value,
        abs_mt_tracking => {
            if (event.value < 0) return finger_up(in);
            in.pending = in.slot; // Down: where is known at the packet's end
            in.down_us = @as(u64, event.sec) * 1_000_000 + event.usec;
        },
        else => {},
    }
    assert(in.slot < slots_count);
    return null;
}

pub fn finger_up(in: *Input) ?Action {
    assert(in.slot < slots_count);
    if (in.drag_slot == in.slot) {
        in.drag_slot = null;
        return .drag_end;
    }
    const down = in.top orelse return null;
    if (down.slot != in.slot) return null; // Another finger, not watched
    in.top = null;
    return lifted(in, down);
}

/// A finger lifted that nothing was following: a sideways stroke is a swipe, and a
/// finger that stayed put or only rolled a little a tap where it began. A real
/// stroke some other way is neither: turning a page by where an arc began would be
/// a guess, often the wrong way.
pub fn lifted(in: *Input, down: Press) ?Action {
    assert(down.slot == in.slot); // The finger that lifted
    const point = screen_point(in, in.slot);
    if (down.moved) {
        const swipe = touch_zones.swipe_direction(down.x, down.y, point.x, point.y);
        if (swipe) |direction| {
            assert(direction == 1 or direction == -1);
            return .{ .swipe = direction };
        }
        if (touch_zones.is_stroke(down.x, down.y, point.x, point.y)) return null;
    }
    return .{ .tap = .{ .x = down.x, .y = down.y, .us = down.us } };
}

/// The end of a packet: a followed finger moved, a pressed one moved or pulled
/// down from the top, or a new touch landed.
pub fn on_packet_end(in: *Input) ?Action {
    if (in.drag_slot) |slot| {
        assert(slot < slots_count); // One of the panel's, as `begin_drag` took it
        in.pending = null;
        const point = screen_point(in, slot);
        return .{ .drag = .{ .x = point.x, .y = point.y } };
    }
    if (in.top) |*down| {
        assert(down.slot < slots_count); // One of the panel's, as `touched_down` took it
        const point = screen_point(in, down.slot);
        if (touch_zones.moved_off(down.x, down.y, point.x, point.y)) down.moved = true;
        if (down.y < touch_zones.top_zone and touch_zones.is_pull(down.y, point.y)) {
            in.top = null;
            return .pull;
        }
    }
    const touched = in.pending orelse return null;
    in.pending = null;
    return touched_down(in, touched);
}

/// A new touch: ignored as a resting thumb, a tap at once, or (on a book page, and
/// at the top edge) a press to watch until it lifts, moves or is held.
pub fn touched_down(in: *Input, slot: u32) ?Action {
    assert(slot < slots_count);
    // Taken from `pending`, which is let go of first so it lands once
    assert(in.pending == null);
    in.last_touched = slot;
    const point = screen_point(in, slot);
    const x = point.x;
    const y = point.y;
    if (ignores(in, x, y)) return null;
    const watch = in.deferred or (in.edge_zones and y < touch_zones.top_zone);
    if (!watch) return .{ .tap = .{ .x = x, .y = y, .us = in.down_us } };
    in.top = .{ .slot = slot, .x = x, .y = y, .us = in.down_us };
    return null;
}

/// Left third goes back a page, the rest forward.
pub fn turn_direction(x: i32, width: i32) i32 {
    assert(width >= 0);
    const direction: i32 = if (x < @divTrunc(width, 3)) -1 else 1;
    assert(direction == 1 or direction == -1);
    return direction;
}

/// A screen-sized panel with no device behind it, for the tests below and watchers'.
pub fn test_input() Input {
    const in: Input = .{
        .touch = -1,
        .power = -1,
        .width = 1272,
        .height = 1696,
        .x_max = 1272,
        .y_max = 1696,
    };
    in.invariants();
    assert(in.script == null);
    return in;
}

pub fn ev(kind: u16, code: u16, value: i32) InputEvent {
    // The kinds the tests feed: a packet's end (0), an axis, or a key
    assert(kind == 0 or kind == ev_abs or kind == evdev.ev_key);
    if (kind == 0) assert(code == 0);
    return .{ .sec = 0, .usec = 0, .kind = kind, .code = code, .value = value };
}

/// Feeds one finger's down (or move) packet, returning what it produced.
pub fn press(in: *Input, slot: i32, x: i32, y: i32, new: bool) ?Action {
    assert(slot >= 0);
    assert(slot < slots_count);
    _ = handle(in, ev(ev_abs, abs_mt_slot, slot)); // Only a packet's end gives an action
    if (new) _ = handle(in, ev(ev_abs, abs_mt_tracking, 7));
    _ = handle(in, ev(ev_abs, abs_mt_x, x));
    _ = handle(in, ev(ev_abs, abs_mt_y, y));
    return handle(in, ev(0, 0, 0));
}

pub fn lift(in: *Input, slot: i32) ?Action {
    assert(slot >= 0);
    assert(slot < slots_count);
    _ = handle(in, ev(ev_abs, abs_mt_slot, slot)); // Choosing a slot gives no action
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
    const at = press(&in, 0, 420, 910, false).?.drag;
    try std.testing.expectEqual(@as(i32, 420), at.x);
    try std.testing.expectEqual(@as(i32, 910), at.y);
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
