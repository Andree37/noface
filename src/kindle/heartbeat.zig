//! The heartbeat: noface writes the time to a file in RAM while its loop turns, and the
//! launcher's watchdog (supervisor.zig) reads it, ending a noface whose beat has gone
//! stale with the Kindle awake. Both sides' timing and the stamp's format are here, so
//! a change to one side can't end a healthy noface mid-book.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");
const calls = @import("../sys/calls.zig");
const paths = @import("paths.zig");

/// Where the beat is written: in RAM, as a write every beat to the user drive would wear
/// it for nothing.
pub const path = paths.heartbeat;
/// How often noface beats. The stamp is whole seconds, so the timing is too.
pub const every_s = 30;
/// A beat older than this, with the Kindle awake, means noface is stuck.
pub const stale_s = 120;

comptime {
    // A few beats can be late (a long layout) before noface is called stuck
    assert(stale_s >= 4 * every_s);
    assert(std.mem.startsWith(u8, path, "/tmp/"));
}

/// Writes the beat at `at` (the watchdog's, but for the tests): the time now, by the
/// wall clock the watchdog reads it with. Needs no loop, so noface beats as it starts,
/// and work that runs long before the loop first turns (a library build) beats.
pub fn beat_to(at: [*:0]const u8) void {
    // Room for any u64 and its newline, so the stamp is never the fallback's zero
    var stamp: [24]u8 = undefined;
    comptime assert(stamp.len >= 20 + 1);
    const text = std.fmt.bufPrint(&stamp, "{d}\n", .{os.unix_time()}) catch "0\n";
    assert(text.len > 1);
    // Unwritten, the beat is missed, which is what the watchdog watches for: it decides
    _ = file.write_small(at, text);
}

/// Beats at `at` if the last beat, at `last_us` on the monotonic clock, was a beat's
/// interval ago: the loop's cadence, and a long job's, which keeps its own `last_us`.
pub fn beat_when_due(at: [*:0]const u8, last_us: *u64) void {
    const now = os.now_us();
    if (now <= last_us.* + every_s * std.time.us_per_s) return;
    last_us.* = now;
    beat_to(at);
}

/// One look by the watchdog: whether the beat at `at` is stale.
pub fn stale_at(at: [*:0]const u8) bool {
    assert(at[0] == '/');
    var beat_buffer: [32]u8 = undefined;
    const beat = file.read_system(at, &beat_buffer);
    assert(beat.len <= beat_buffer.len);
    return stuck(os.unix_time(), beat);
}

/// Whether noface's last beat (seconds since 1970, as text; none reads as 0) is over
/// `stale_s` before `now`.
pub fn stuck(now: u64, beat_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, beat_text, " \n");
    const beat = std.fmt.parseInt(u64, trimmed, 10) catch 0;
    if (beat >= now) return false; // A clock set back: no sign of being stuck
    assert(now > beat);
    return now - beat > stale_s;
}

test "noface is stuck only once its beat is past stale" {
    try std.testing.expect(!stuck(1000, "900\n"));
    try std.testing.expect(!stuck(1000, std.fmt.comptimePrint("{d}\n", .{1000 - stale_s})));
    try std.testing.expect(stuck(1000, std.fmt.comptimePrint("{d}\n", .{1000 - stale_s - 1})));
    try std.testing.expect(stuck(1000, ""));
    try std.testing.expect(!stuck(1000, "2000\n"));
}

test "a long job beats once a beat's interval has passed, and not while the clock stands" {
    var path_buffer: [64]u8 = undefined;
    const at = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/noface-beat-{d}", .{
        calls.getpid(),
    }, 0);
    _ = calls.unlink(at); // Ignored: none there is as good
    defer _ = calls.unlink(at); // Ignored: only /tmp is left fuller
    const clock_was = os.fake_us;
    defer os.fake_us = clock_was;
    os.fake_us = 1000;
    var last_us: u64 = 1000; // The job's clock, started as it starts
    beat_when_due(at, &last_us);
    try std.testing.expect(!file.exists(at)); // Not a beat's interval yet
    os.fake_us.? += every_s * std.time.us_per_s + 1;
    beat_when_due(at, &last_us);
    try std.testing.expect(file.exists(at));
    try std.testing.expectEqual(os.fake_us.?, last_us);
    var stamp_buffer: [24]u8 = undefined;
    const stamp = file.read_system(at, &stamp_buffer);
    const beat_s = try std.fmt.parseInt(u64, stamp[0 .. stamp.len - 1], 10);
    try std.testing.expectEqual(os.unix_time(), beat_s);
    _ = calls.unlink(at); // Ignored: checked just below
    beat_when_due(at, &last_us);
    try std.testing.expect(!file.exists(at)); // Beat just now
}
