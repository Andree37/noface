//! Tells a holding thumb from a tap by where it lands.
const std = @import("std");

const bottom_strip = 120; // Full width, along the bottom edge
const corner_width = 300; // Bottom corners, where thumbs sit higher
const corner_height = 250;

pub const PowerEvent = enum { lock, unlock };

/// The newest power event in what was read, so a quick lock and unlock settles
/// on where the Kindle ended up.
pub fn lastPowerEvent(line: []const u8) ?PowerEvent {
    const lock = std.mem.lastIndexOf(u8, line, "goingToScreenSaver");
    const unlock = std.mem.lastIndexOf(u8, line, "outOfScreenSaver");
    if (unlock) |u| {
        if (lock == null or u > lock.?) return .unlock;
    }
    return if (lock != null) .lock else null;
}

/// Whether powerd said a charger came or went: "charging" or "notCharging".
pub fn chargerChanged(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "charging") != null or std.mem.indexOf(u8, line, "Charging") != null;
}

pub const top_zone = 200; // Top edge: opens the toolbar, or the panel when dragged
pub const hold_ms = 450; // Press this long to start selecting text
const hold_slop = 36; // Movement that still counts as holding still
const pull_distance = 80;

/// True once a touch that began at the top has dragged far enough down.
pub fn isPull(start_y: i32, y: i32) bool {
    return y - start_y >= pull_distance;
}

const swipe_distance = 100; // Sideways travel that makes a stroke a swipe

const stroke_distance = 90; // Travel past which a touch is a stroke, not a rolled tap

/// Whether a finger travelled far enough to mean a movement, not a tap that rolled.
pub fn isStroke(x0: i32, y0: i32, x: i32, y: i32) bool {
    return @max(@abs(x - x0), @abs(y - y0)) >= stroke_distance;
}

/// A finger that went from (x0, y0) to (x, y) and lifted: -1 swiped right (back),
/// 1 swiped left (on), null for anything else. At least as far across as up or
/// down: a thumb swipes in an arc, not a straight line.
pub fn swipeDirection(x0: i32, y0: i32, x: i32, y: i32) ?i32 {
    const dx = x - x0;
    const dy = y - y0;
    if (@abs(dx) < swipe_distance or @abs(dx) < @abs(dy)) return null;
    return if (dx < 0) 1 else -1;
}

test "a sideways stroke swipes, at most as steep as it is wide" {
    try std.testing.expectEqual(@as(?i32, 1), swipeDirection(900, 800, 600, 830));
    try std.testing.expectEqual(@as(?i32, -1), swipeDirection(300, 800, 700, 760));
    try std.testing.expect(swipeDirection(300, 800, 380, 800) == null); // Too short
    try std.testing.expectEqual(@as(?i32, -1), swipeDirection(300, 800, 500, 950)); // An arc
    try std.testing.expect(swipeDirection(300, 800, 450, 1000) == null); // Mostly down
}

/// True when a finger has wandered too far to count as a hold.
pub fn movedOff(x0: i32, y0: i32, x: i32, y: i32) bool {
    return @abs(x - x0) > hold_slop or @abs(y - y0) > hold_slop;
}

pub fn isGrip(x: i32, y: i32, width: i32, height: i32) bool {
    if (y >= height - bottom_strip) return true;
    if (y < height - corner_height) return false;
    return x < corner_width or x >= width - corner_width;
}

test "measured thumb positions are grips" {
    try std.testing.expect(isGrip(153, 1531, 1272, 1696));
    try std.testing.expect(isGrip(1119, 1586, 1272, 1696));
    try std.testing.expect(isGrip(683, 1630, 1272, 1696));
    try std.testing.expect(isGrip(278, 1695, 1272, 1696));
}

test "measured taps still turn pages" {
    try std.testing.expect(!isGrip(456, 970, 1272, 1696));
    try std.testing.expect(!isGrip(1106, 1179, 1272, 1696));
    try std.testing.expect(!isGrip(636, 1500, 1272, 1696));
}

test "dragging down from the top counts as a pull" {
    try std.testing.expect(!isPull(40, 100));
    try std.testing.expect(isPull(40, 120));
    try std.testing.expect(!isPull(100, 60));
}

test "small wobble still counts as holding" {
    try std.testing.expect(!movedOff(100, 100, 120, 90));
    try std.testing.expect(movedOff(100, 100, 200, 100));
}

test "the newest power event wins" {
    try std.testing.expectEqual(PowerEvent.lock, lastPowerEvent("goingToScreenSaver\n").?);
    try std.testing.expectEqual(PowerEvent.unlock, lastPowerEvent("goingToScreenSaver\noutOfScreenSaver\n").?);
    try std.testing.expectEqual(PowerEvent.lock, lastPowerEvent("outOfScreenSaver\ngoingToScreenSaver\n").?);
    try std.testing.expect(lastPowerEvent("something else\n") == null);
}

test "a rolled tap isn't a stroke, a real movement is" {
    try std.testing.expect(!isStroke(400, 1140, 440, 1140));
    try std.testing.expect(isStroke(600, 600, 620, 900));
}
