//! When noface has done all its touches asked: every action it read is handled, each
//! screen it opened drawn and its panel refresh done, and it's back waiting for the
//! next touch. In a test run noface says so in its log ("idle: lifted at 81234567"),
//! with when the last finger it read lifted, by the panel's clock (CLOCK_MONOTONIC,
//! as `os.now_us`). The device tests (tools/e2e.zig) wait for it before their next
//! touch: one made earlier may land before the screen it's meant for is shown, and
//! noface drops it as meant for the one before (screens/screen.zig `route`).
const std = @import("std");
const assert = std.debug.assert;
/// Lines for noface's log, which the tests keep quiet (main.zig's `std_options`).
const log = std.log.scoped(.idle);

const prefix = "idle: lifted at ";

/// Says in the log that noface is waiting, everything before handled, the last finger
/// it read having lifted at `lifted_us` (0 when none has yet).
pub fn say(lifted_us: u64) void {
    log.info(prefix ++ "{d}", .{lifted_us});
}

/// Whether a log's text says noface went idle after reading a finger that lifted at
/// `lifted_us_min` or later: it had then read that lift, and done all it asked.
pub fn since(log_text: []const u8, lifted_us_min: u64) bool {
    comptime assert(std.mem.endsWith(u8, prefix, " ")); // The number follows it, alone
    var lines = std.mem.splitScalar(u8, log_text, '\n');
    // Bounded by the log's lines
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, prefix) orelse continue;
        assert(start + prefix.len <= line.len);
        const rest = std.mem.trimEnd(u8, line[start + prefix.len ..], "\r");
        // A line cut short as the log is written is read again on the next look
        const lifted_us = std.fmt.parseInt(u64, rest, 10) catch continue;
        if (lifted_us >= lifted_us_min) return true;
    }
    return false;
}

test "idle is found only once noface has read a lift at or after the one asked for" {
    const text =
        \\screen: Reader opened
        \\idle: lifted at 1000
        \\tap 10,20
        \\idle: lifted at 2000
        \\idle: lifted at 30
    ;
    try std.testing.expect(since(text, 0));
    try std.testing.expect(since(text, 2000));
    try std.testing.expect(!since(text, 2001));
    try std.testing.expect(!since("idle: lifted at 99", 100));
    try std.testing.expect(!since("idle: lifted at ", 0)); // Cut short as it was written
    try std.testing.expect(!since("", 0));
}

test "a line said is one found" {
    var buffer: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, prefix ++ "{d}", .{@as(u64, 4242)});
    try std.testing.expect(since(line, 4242));
    try std.testing.expect(!since(line, 4243));
}
