//! Small helpers over raw Linux syscalls, shared across the app.
const std = @import("std");
const linux = @import("calls.zig");

/// Raw syscalls return errors as values in the top 4096 of the range.
pub fn failed(rc: usize) bool {
    return rc > std.math.maxInt(usize) - 4096;
}

/// Set, the clock tests run on: scenario tests move it forward themselves, so a wait
/// of minutes (the Wi-Fi pause, a hold, a double tap) takes no time at all.
pub var fake_us: ?u64 = null;

/// Microseconds on the monotonic clock, which stops while the Kindle sleeps.
pub fn now_us() u64 {
    if (fake_us) |t| return t;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// Seconds since 1970, for dates people see and that survive a restart.
pub fn unix_time() u64 {
    // On the test clock, a fixed day (14 Nov 2026) moving with it, so dates are the same every run
    if (fake_us) |t| return 1_794_700_800 + t / 1_000_000;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn sleep_ms(ms: u64) void {
    if (fake_us) |*t| {
        t.* += ms * 1000;
        return;
    }
    const wait = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&wait, null);
}

test "error codes are told from results" {
    try std.testing.expect(failed(@bitCast(@as(isize, -2))));
    try std.testing.expect(!failed(3));
}
