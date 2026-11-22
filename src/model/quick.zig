//! What the quick panel and status bar show: light, warmth, wireless, Bluetooth, battery, time.
const std = @import("std");
const assert = std.debug.assert;

pub const max_brightness = 24;

pub const max_warmth = 24;

/// How far a light's - and + buttons move its level.
pub const level_step = 2;

comptime {
    assert(level_step > 0);
    assert(level_step <= max_brightness);
    assert(level_step <= max_warmth);
    // Stepping up from zero lands on the brightest and the warmest level exactly.
    assert(max_brightness % level_step == 0);
    assert(max_warmth % level_step == 0);
}

pub const Quick = struct {
    brightness: u32 = 0,
    warmth: u32 = 0,
    schedule: bool = false,
    airplane: bool = false,
    /// Airplane mode is noface's own, turned on a while into a book to save the battery
    /// (kindle/wifi_saver.zig): Wi-Fi paused, not the reader's airplane mode.
    wifi_paused: bool = false,
    bluetooth: bool = false,
    syncing: bool = false,
    battery: u32 = 0,
    plugged: bool = false, // On a charger or a computer: the status bar shows a bolt
    wifi_on: bool = false, // Connected
    wifi_bars: u32 = 0, // The signal, 0 to 3: shown only while connected
    /// The name of the network connected to, as long as a Wi-Fi name can be: read
    /// when the panel opens, empty when not connected.
    network: [network_bytes_max]u8 = undefined,
    network_len: u32 = 0,
    clock: [40]u8 = undefined,
    clock_len: u32 = 0,

    pub const network_bytes_max = 32;

    pub fn network_text(q: *const Quick) []const u8 {
        assert(q.network_len <= q.network.len);
        return q.network[0..q.network_len];
    }

    pub fn clock_text(q: *const Quick) []const u8 {
        assert(q.clock_len <= q.clock.len);
        return q.clock[0..q.clock_len];
    }

    /// The Wi-Fi bars drawn: the signal while connected, none otherwise.
    pub fn wifi_shown(q: *const Quick) ?u32 {
        assert(q.wifi_bars <= 3);
        return if (q.wifi_on) q.wifi_bars else null;
    }

    /// Whether two readings would draw the same, so a screen drawn from the first
    /// needs no redraw for the second.
    /// Every field counts, so a new one can't be left out: the clock and the signal
    /// as they're drawn.
    pub fn same(a: *const Quick, b: *const Quick) bool {
        assert(a.clock_len <= a.clock.len);
        assert(b.clock_len <= b.clock.len);
        inline for (@typeInfo(Quick).@"struct".field_names) |name| {
            const as_drawn = comptime std.mem.eql(u8, name, "clock") or
                std.mem.eql(u8, name, "clock_len") or std.mem.eql(u8, name, "wifi_bars") or
                std.mem.eql(u8, name, "network") or std.mem.eql(u8, name, "network_len");
            if (as_drawn) continue;
            if (@field(a, name) != @field(b, name)) return false;
        }
        if (a.wifi_shown() != b.wifi_shown()) return false;
        if (!std.mem.eql(u8, a.network_text(), b.network_text())) return false;
        return std.mem.eql(u8, a.clock_text(), b.clock_text());
    }
};

test "readings compare by what they show" {
    var a = Quick{ .battery = 80 };
    a.clock_len = 5;
    @memcpy(a.clock[0..5], "21:15");
    var b = a;
    try std.testing.expect(a.same(&b));
    b.battery = 79;
    try std.testing.expect(!a.same(&b));
    b = a;
    @memcpy(b.clock[0..5], "21:16");
    try std.testing.expect(!a.same(&b));
    // The signal shows only while connected: off, it changes nothing drawn
    b = a;
    b.wifi_bars = 3;
    try std.testing.expect(a.same(&b));
    a.wifi_on = true;
    b.wifi_on = true;
    try std.testing.expect(!a.same(&b));
}

/// Steps a light's level, brightness or warmth, stopping at 0 and at that light's
/// `max`, so each row's buttons stop where its own slider ends.
pub fn step_level(level: u32, up: bool, max: u32) u32 {
    assert(max >= level_step);
    if (up) {
        const higher = @min(level + level_step, max);
        assert(higher <= max);
        assert(higher >= @min(level, max));
        return higher;
    }
    const lower = level -| level_step;
    assert(lower <= level);
    return lower;
}

test "a light's level stops at both ends, each light at its own" {
    try std.testing.expectEqual(@as(u32, 24), step_level(23, true, max_brightness));
    try std.testing.expectEqual(@as(u32, 0), step_level(1, false, max_brightness));
    try std.testing.expectEqual(@as(u32, 12), step_level(10, true, max_brightness));
    // A light with a shorter range stops at its own top, not brightness's
    try std.testing.expectEqual(@as(u32, 10), step_level(9, true, 10));
    try std.testing.expectEqual(@as(u32, 10), step_level(10, true, 10));
}
