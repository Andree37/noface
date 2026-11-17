//! Small helpers over raw Linux syscalls, shared across the app.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("calls.zig");

/// Raw syscalls return errors as values in the top 4096 of the range.
pub fn failed(rc: usize) bool { // usize: Linux's syscall ABI
    return rc > std.math.maxInt(usize) - 4096; // usize: Linux's syscall ABI
}

/// Whether a failed call says there's nothing at the path (ENOENT), which is "nothing
/// saved yet", unlike a file that's there but can't be read: one that would be lost if
/// taken for none and written over.
pub fn not_found(rc: usize) bool { // usize: Linux's syscall ABI
    return rc == not_found_rc;
}

/// ENOENT as a call reports it, negated: the system's own number, which calls_portable
/// reports the same way, so it holds on Linux and on a Mac running the tests alike.
// usize: Linux's syscall ABI
const not_found_rc: usize = @bitCast(-@as(isize, @backingInt(std.posix.E.NOENT)));

/// Set, the clock tests run on: scenario tests move it forward themselves, so a wait
/// of minutes (the Wi-Fi pause, a hold, a double tap) takes no time at all.
pub var fake_us: ?u64 = null;

/// The day the test clock starts on, 15 Nov 2026 at 00:00 UTC, in seconds since 1970.
const fake_day_unix = 1_794_700_800;

comptime {
    assert(fake_day_unix % std.time.s_per_day == 0); // Its midnight, so clocks read 00:00
    // A call's success (0, a count, a descriptor) never reads as a failure, and -1
    // (EPERM, the first error) does
    assert(!failed(0));
    assert(failed(@bitCast(@as(isize, -1))));
    assert(failed(not_found_rc)); // Not there is a failure, of its own kind
}

/// Microseconds on the monotonic clock, which stops while the Kindle sleeps.
pub fn now_us() u64 {
    if (fake_us) |t| return t;
    var time: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &time);
    assert(!failed(rc)); // Every Linux has this clock, and `time` is ours to fill
    assert(time.nsec < std.time.ns_per_s);
    return @as(u64, @intCast(time.sec)) * std.time.us_per_s +
        @as(u64, @intCast(time.nsec)) / std.time.ns_per_us;
}

/// Seconds since 1970, for dates people see and that survive a restart.
pub fn unix_time() u64 {
    // On the test clock, a fixed day moving with it, so dates are the same every run
    if (fake_us) |t| {
        const fake_unix = fake_day_unix + t / std.time.us_per_s;
        assert(fake_unix >= fake_day_unix);
        return fake_unix;
    }
    var time: linux.timespec = undefined;
    const rc = linux.clock_gettime(.REALTIME, &time);
    assert(!failed(rc)); // Every Linux has this clock, and `time` is ours to fill
    return @intCast(time.sec);
}

pub fn sleep_ms(duration_ms: u64) void {
    if (fake_us) |*t| {
        t.* += duration_ms * std.time.us_per_ms;
        return;
    }
    const wait = linux.timespec{
        .sec = @intCast(duration_ms / std.time.ms_per_s),
        .nsec = @intCast((duration_ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    assert(wait.nsec >= 0);
    assert(wait.nsec < std.time.ns_per_s);
    _ = linux.nanosleep(&wait, null); // Woken early by a signal: the caller's loop goes on
}

test "error codes are told from results" {
    try std.testing.expect(failed(@bitCast(@as(isize, -2))));
    try std.testing.expect(!failed(3));
    const loop: usize = @bitCast(-@as(isize, @backingInt(std.posix.E.LOOP)));
    try std.testing.expect(failed(loop));
    try std.testing.expect(!not_found(loop)); // There, but can't be read
    try std.testing.expect(!not_found(3));
}

test "the test clock starts at midnight on 15 Nov 2026" {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = fake_day_unix };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    try std.testing.expectEqual(@as(u16, 2026), year_day.year);
    try std.testing.expectEqual(@as(u4, 11), month_day.month.numeric());
    try std.testing.expectEqual(@as(u5, 15), month_day.day_index + 1);
    try std.testing.expectEqual(@as(u64, 0), epoch.getDaySeconds().secs);
}
