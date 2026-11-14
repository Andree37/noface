//! Tells a holding thumb from a tap by where it lands.
const std = @import("std");
const assert = std.debug.assert;

const bottom_strip = 120; // Full width, along the bottom edge
const corner_width = 300; // Bottom corners, where thumbs sit higher
const corner_height = 250;

pub const PowerEvent = enum { lock, unlock };

/// The newest power event in what was read, so a quick lock and unlock settles
/// on where the Kindle ended up.
pub fn last_power_event(line: []const u8) ?PowerEvent {
    const lock = std.mem.lastIndexOf(u8, line, "goingToScreenSaver");
    const unlock = std.mem.lastIndexOf(u8, line, "outOfScreenSaver");
    if (unlock) |unlock_at| {
        assert(unlock_at < line.len);
        // The two names can't overlap, so they never start at the same place
        if (lock) |lock_at| assert(lock_at != unlock_at);
        if (lock == null or unlock_at > lock.?) return .unlock;
    }
    return if (lock != null) .lock else null;
}

/// Whether powerd said a charger came or went: "charging" or "notCharging".
pub fn charger_changed(line: []const u8) bool {
    const charging = std.mem.indexOf(u8, line, "charging") != null;
    const not_charging = std.mem.indexOf(u8, line, "Charging") != null;
    return charging or not_charging;
}

pub const top_zone = 200; // Top edge: opens the toolbar, or the panel when dragged
pub const hold_ms = 450; // Press this long to start selecting text
const hold_slop = 36; // Movement that still counts as holding still
const pull_distance = 80;

/// True once a touch that began at the top has dragged far enough down.
pub fn is_pull(start_y: i32, y: i32) bool {
    return y - start_y >= pull_distance;
}

const swipe_distance = 100; // Sideways travel that makes a stroke a swipe

const stroke_distance = 90; // Travel past which a touch is a stroke, not a rolled tap

comptime {
    // A finger that holds still has made no stroke, and every swipe is one
    assert(hold_slop < stroke_distance);
    assert(stroke_distance <= swipe_distance);
    // A pull is told from a press held still at the top
    assert(hold_slop < pull_distance);
    // The bottom corners reach higher than the strip along the edge, and on the
    // narrowest screen noface runs on (1072 px across) leave the middle free
    assert(bottom_strip < corner_height);
    assert(corner_width * 2 < 1072);
}

/// Whether a finger travelled far enough to mean a movement, not a tap that rolled.
pub fn is_stroke(from_x: i32, from_y: i32, to_x: i32, to_y: i32) bool {
    const travel = @max(@abs(to_x - from_x), @abs(to_y - from_y));
    const stroke = travel >= stroke_distance;
    // Anything that's a stroke has moved off a hold, too
    if (stroke) assert(moved_off(from_x, from_y, to_x, to_y));
    return stroke;
}

/// A finger that went from (from_x, from_y) to (to_x, to_y) and lifted: -1 swiped
/// right (back), 1 swiped left (on), null for anything else. At least as far across
/// as up or down: a thumb swipes in an arc, not a straight line.
pub fn swipe_direction(from_x: i32, from_y: i32, to_x: i32, to_y: i32) ?i32 {
    const across = to_x - from_x;
    const down = to_y - from_y;
    if (@abs(across) < swipe_distance or @abs(across) < @abs(down)) return null;
    assert(across != 0);
    // Every swipe travelled far enough to be a stroke, so it's never taken for a tap
    assert(is_stroke(from_x, from_y, to_x, to_y));
    return if (across < 0) 1 else -1;
}

test "a sideways stroke swipes, at most as steep as it is wide" {
    try std.testing.expectEqual(@as(?i32, 1), swipe_direction(900, 800, 600, 830));
    try std.testing.expectEqual(@as(?i32, -1), swipe_direction(300, 800, 700, 760));
    try std.testing.expect(swipe_direction(300, 800, 380, 800) == null); // Too short
    try std.testing.expectEqual(@as(?i32, -1), swipe_direction(300, 800, 500, 950)); // An arc
    try std.testing.expect(swipe_direction(300, 800, 450, 1000) == null); // Mostly down
}

/// True when a finger has wandered too far to count as a hold.
pub fn moved_off(from_x: i32, from_y: i32, to_x: i32, to_y: i32) bool {
    return @abs(to_x - from_x) > hold_slop or @abs(to_y - from_y) > hold_slop;
}

pub fn is_grip(x: i32, y: i32, width: i32, height: i32) bool {
    assert(width >= 0);
    assert(height >= 0);
    if (y >= height - bottom_strip) return true;
    if (y < height - corner_height) return false;
    return x < corner_width or x >= width - corner_width;
}

test "measured thumb positions are grips" {
    try std.testing.expect(is_grip(153, 1531, 1272, 1696));
    try std.testing.expect(is_grip(1119, 1586, 1272, 1696));
    try std.testing.expect(is_grip(683, 1630, 1272, 1696));
    try std.testing.expect(is_grip(278, 1695, 1272, 1696));
}

test "measured taps still turn pages" {
    try std.testing.expect(!is_grip(456, 970, 1272, 1696));
    try std.testing.expect(!is_grip(1106, 1179, 1272, 1696));
    try std.testing.expect(!is_grip(636, 1500, 1272, 1696));
}

test "dragging down from the top counts as a pull" {
    try std.testing.expect(!is_pull(40, 100));
    try std.testing.expect(is_pull(40, 120));
    try std.testing.expect(!is_pull(100, 60));
}

test "small wobble still counts as holding" {
    try std.testing.expect(!moved_off(100, 100, 120, 90));
    try std.testing.expect(moved_off(100, 100, 200, 100));
}

test "the newest power event wins" {
    const lock = "goingToScreenSaver\n";
    const both = "goingToScreenSaver\noutOfScreenSaver\n";
    const both_reversed = "outOfScreenSaver\ngoingToScreenSaver\n";
    try std.testing.expectEqual(PowerEvent.lock, last_power_event(lock).?);
    try std.testing.expectEqual(PowerEvent.unlock, last_power_event(both).?);
    try std.testing.expectEqual(PowerEvent.lock, last_power_event(both_reversed).?);
    try std.testing.expect(last_power_event("something else\n") == null);
}

test "a rolled tap isn't a stroke, a real movement is" {
    try std.testing.expect(!is_stroke(400, 1140, 440, 1140));
    try std.testing.expect(is_stroke(600, 600, 620, 900));
}
