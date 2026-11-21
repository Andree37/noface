//! Tells a holding thumb from a tap by where it lands, and a tap from a stroke by how
//! far it goes. Every distance is a length on the glass, in points (a 72nd of an
//! inch), as this Kindle's pixels: a thumb is the same size on any screen.
const std = @import("std");
const assert = std.debug.assert;
const device = @import("../model/device.zig");

const screen = device.screen(device.target);
/// Its size, signed, as touches are.
const screen_width: i32 = @intCast(screen.width_px);
const screen_height: i32 = @intCast(screen.height_px);

/// `points` as this screen's pixels.
fn pt(comptime points: comptime_float) i32 {
    return comptime @intCast(screen.px_from_pt(points));
}

const bottom_strip = pt(28.8); // Full width, along the bottom edge
const corner_width = pt(72); // Bottom corners, where thumbs sit higher
const corner_height = pt(60);

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

pub const top_zone = pt(48); // Top edge: opens the toolbar, or the panel when dragged
pub const hold_ms = 450; // Press this long to start selecting text
const hold_slop = pt(8.64); // Movement that still counts as holding still
const pull_distance = pt(19.2);

/// True once a touch that began at the top has dragged far enough down.
pub fn is_pull(start_y: i32, y: i32) bool {
    return y - start_y >= pull_distance;
}

const swipe_distance = pt(24); // Sideways travel that makes a stroke a swipe

const stroke_distance = pt(21.6); // Travel past which a touch is a stroke, not a rolled tap

comptime {
    // A finger that holds still has made no stroke, and every swipe is one
    assert(hold_slop < stroke_distance);
    assert(stroke_distance <= swipe_distance);
    // A pull is told from a press held still at the top
    assert(hold_slop < pull_distance);
    // The bottom corners reach higher than the strip along the edge, and leave the
    // middle free, where a page turns
    assert(bottom_strip < corner_height);
    assert(corner_width * 2 < screen.width_px);
    // The top edge's strip and the bottom's thumb zones leave the page between them
    assert(top_zone + corner_height < screen.height_px);
}

/// Whether a finger travelled far enough to mean a movement, not a tap that rolled.
pub fn is_stroke(from_x: i32, from_y: i32, to_x: i32, to_y: i32) bool {
    const travel = @max(@abs(to_x - from_x), @abs(to_y - from_y));
    const stroke = travel >= stroke_distance;
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
    const x = @divTrunc(screen_width, 2);
    const y = @divTrunc(screen_height, 2);
    const far = swipe_distance + hold_slop;
    try std.testing.expectEqual(@as(?i32, 1), swipe_direction(x, y, x - far, y + hold_slop));
    try std.testing.expectEqual(@as(?i32, -1), swipe_direction(x, y, x + far, y - hold_slop));
    const short = swipe_distance - 1;
    try std.testing.expect(swipe_direction(x, y, x + short, y) == null);
    // An arc, as a thumb makes it, dropping less than it goes across
    try std.testing.expectEqual(@as(?i32, -1), swipe_direction(x, y, x + far, y + far - 1));
    try std.testing.expect(swipe_direction(x, y, x + far, y + far + 1) == null); // Mostly down
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

test "a thumb along the bottom edge, or in a bottom corner, is a grip" {
    const w = screen_width;
    const h = screen_height;
    try std.testing.expect(is_grip(@divTrunc(w, 2), h - 1, w, h)); // The middle of the edge
    try std.testing.expect(is_grip(@divTrunc(w, 2), h - bottom_strip, w, h));
    try std.testing.expect(is_grip(0, h - corner_height, w, h)); // Corners, at their top
    try std.testing.expect(is_grip(corner_width - 1, h - corner_height, w, h));
    try std.testing.expect(is_grip(w - corner_width, h - corner_height, w, h));
    try std.testing.expect(is_grip(w - 1, h - 1, w, h));
}

test "a tap on the page, above the corners or between them, still turns it" {
    const w = screen_width;
    const h = screen_height;
    try std.testing.expect(!is_grip(0, h - corner_height - 1, w, h)); // Above a corner
    try std.testing.expect(!is_grip(w - 1, h - corner_height - 1, w, h));
    try std.testing.expect(!is_grip(corner_width, h - bottom_strip - 1, w, h)); // Between
    try std.testing.expect(!is_grip(w - corner_width - 1, h - bottom_strip - 1, w, h));
    try std.testing.expect(!is_grip(@divTrunc(w, 2), top_zone, w, h));
}

test "dragging down from the top counts as a pull" {
    try std.testing.expect(!is_pull(0, pull_distance - 1));
    try std.testing.expect(is_pull(0, pull_distance));
    try std.testing.expect(!is_pull(pull_distance, 0)); // Up
}

test "small wobble still counts as holding" {
    try std.testing.expect(!moved_off(100, 100, 100 + hold_slop, 100 - hold_slop));
    try std.testing.expect(moved_off(100, 100, 100 + hold_slop + 1, 100));
    try std.testing.expect(moved_off(100, 100, 100, 100 - hold_slop - 1));
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
    try std.testing.expect(!is_stroke(100, 100, 100 + stroke_distance - 1, 100));
    try std.testing.expect(is_stroke(100, 100, 100 + hold_slop, 100 + stroke_distance));
}
