//! What the quick panel and status bar show: light, warmth, wireless, Bluetooth, battery, time.
const std = @import("std");
const assert = std.debug.assert;

pub const max_brightness = 24;

pub const max_warmth = 24;

pub const brightness_step = 2;

comptime {
    assert(brightness_step > 0);
    assert(brightness_step <= max_brightness);
    // Stepping up from zero lands on the brightest level exactly.
    assert(max_brightness % brightness_step == 0);
}

pub const Quick = struct {
    brightness: u32 = 0,
    warmth: u32 = 0,
    schedule: bool = false,
    airplane: bool = false,
    bluetooth: bool = false,
    syncing: bool = false,
    battery: u32 = 0,
    plugged: bool = false, // On a charger or a computer: the status bar shows a bolt
    wifi_on: bool = false,
    wifi_bars: u32 = 0, // 0 to 3
    clock: [40]u8 = undefined,
    clock_len: u32 = 0,

    pub fn clock_text(q: *const Quick) []const u8 {
        assert(q.clock_len <= q.clock.len);
        const text = q.clock[0..q.clock_len];
        assert(text.len == q.clock_len);
        return text;
    }

    /// Whether two readings would draw the same, so a screen drawn from the first
    /// needs no redraw for the second.
    /// Every field counts, so a new one can't be left out.
    pub fn same(a: *const Quick, b: *const Quick) bool {
        assert(a.clock_len <= a.clock.len);
        assert(b.clock_len <= b.clock.len);
        inline for (@typeInfo(Quick).@"struct".field_names) |name| {
            const is_clock = comptime std.mem.eql(u8, name, "clock") or
                std.mem.eql(u8, name, "clock_len");
            if (is_clock) continue;
            if (@field(a, name) != @field(b, name)) return false;
        }
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
}

/// Steps brightness, stopping at both ends.
pub fn step_brightness(level: u32, up: bool) u32 {
    if (up) {
        const brighter = @min(level + brightness_step, max_brightness);
        assert(brighter <= max_brightness);
        assert(brighter >= @min(level, max_brightness));
        return brighter;
    }
    const dimmer = level -| brightness_step;
    assert(dimmer <= level);
    return dimmer;
}

test "brightness stops at both ends" {
    try std.testing.expectEqual(@as(u32, 24), step_brightness(23, true));
    try std.testing.expectEqual(@as(u32, 0), step_brightness(1, false));
    try std.testing.expectEqual(@as(u32, 12), step_brightness(10, true));
}
