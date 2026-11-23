//! How long the battery will last, from how fast it has drained lately. noface notes the
//! level each time it changes; the time between two notes, both unplugged and the level
//! not risen, is real use (reading, and asleep in between). Plain data, no drawing.
const std = @import("std");
const stats_model = @import("stats.zig");
const assert = std.debug.assert;
const line_of = @import("../text/line.zig").of;

pub const Sample = struct { time: u64, level: u32, plugged: bool };

/// Drain from these days back counts: recent enough to follow how it's used now.
pub const window_s: u64 = 14 * std.time.s_per_day;
/// Less than this to go on, and the estimate would be noise.
const min_span_s: u64 = 12 * 3600;
const min_drop = 3;
const level_max = 100;
/// The longest line `format_line` writes: a u64 time, a u32 level, a flag, two spaces and
/// a newline.
const line_size_max = 20 + 1 + 10 + 1 + 1 + 1;
/// The longest text `describe` writes: "About " and " weeks" around a u64.
const describe_size_max = "About ".len + 20 + " weeks".len;

comptime {
    assert(min_span_s < window_s);
    assert(min_drop > 0);
    assert(min_drop < level_max);
    assert(line_size_max <= 40); // The buffer kindle/battery_log.zig writes a line into
    assert(describe_size_max <= 32); // The buffer screens/battery.zig describes into
}

/// "1793990000 87 u": time, level, plugged ("p") or unplugged ("u").
pub fn parse_line(line: []const u8) ?Sample {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const time = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const level = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const plug = it.next() orelse return null;
    if (level > level_max) return null;
    const sample: Sample = .{ .time = time, .level = level, .plugged = std.mem.eql(u8, plug, "p") };
    assert(sample.level <= level_max);
    assert(sample.time == time);
    return sample;
}

/// Room for a line of the log.
pub const Line = [line_size_max]u8;

pub fn format_line(buf: *Line, s: Sample) []const u8 {
    const plug = if (s.plugged) "p" else "u";
    const line = line_of(buf, "{d} {d} {s}\n", .{ s.time, s.level, plug });
    // The buffer holds the longest line, so the line is always written whole.
    assert(line.len > 0);
    assert(line[line.len - 1] == '\n');
    return line;
}

/// Seconds the battery has left at `level`, at the drain seen in `log` (oldest first).
/// Null while there isn't enough unplugged use to tell.
pub fn seconds_left(log: []const Sample, now: u64, level: u32) ?u64 {
    var drop: u64 = 0;
    var span: u64 = 0;
    if (log.len < 2) return null;
    const since = now -| window_s;
    for (log[0 .. log.len - 1], log[1..]) |a, b| {
        // Both ends in the window, so one long-ago note can't stretch a span over
        // weeks; and times a clock reset or a damaged line could give are skipped
        if (!plausible(a.time, now) or !plausible(b.time, now)) continue;
        if (a.time < since or b.time <= a.time) continue;
        if (a.plugged or b.plugged or b.level > a.level) continue; // Charged in between
        assert(b.time > a.time);
        assert(b.level <= a.level);
        drop += a.level - b.level;
        span += b.time - a.time;
    }
    if (span < min_span_s or drop < min_drop) return null;
    assert(drop >= min_drop);
    assert(span >= min_span_s);
    return @as(u64, level) * span / drop;
}

pub const plausible = stats_model.plausible;

/// "About 2 weeks", "About 5 days", "About 20 hours".
/// Room for how long a charge lasts, in words.
pub const Description = [describe_size_max]u8;

pub fn describe(buf: *Description, seconds: u64) []const u8 {
    const hours = seconds / 3600;
    const day = std.time.s_per_day;
    // Days to the nearest; a week from three days into it
    const days = (seconds + day / 2) / day;
    const weeks = (seconds + 3 * day) / (7 * day);
    assert(days >= hours / 24);
    if (hours < 2) return "Less than 2 hours";
    if (hours < 36) return line_of(buf, "About {d} hours", .{hours});
    if (days < 14) return line_of(buf, "About {d} days", .{days});
    return line_of(buf, "About {d} weeks", .{weeks});
}

test "lines read back as written" {
    var buf: Line = undefined;
    const s = Sample{ .time = 1793990000, .level = 87, .plugged = false };
    const line = format_line(&buf, s);
    try std.testing.expectEqualStrings("1793990000 87 u\n", line);
    try std.testing.expectEqual(s, parse_line(std.mem.trimEnd(u8, line, "\n")).?);
    try std.testing.expect(parse_line("12 300 u") == null);
    try std.testing.expect(parse_line("junk") == null);
}

test "drain counts only unplugged time, and charging breaks it" {
    const t = 1_790_000_000;
    const d = 86400;
    const log = [_]Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + d, .level = 95, .plugged = false }, // 5% a day
        .{ .time = t + d + 3600, .level = 96, .plugged = true }, // Plugged: not counted
        .{ .time = t + 2 * d, .level = 100, .plugged = false },
        .{ .time = t + 3 * d, .level = 95, .plugged = false }, // 5% a day again
    };
    // 10% over 2 days: at 95%, 19 days left
    try std.testing.expectEqual(@as(u64, 19 * d), seconds_left(&log, t + 3 * d, 95).?);
}

test "too little to go on says nothing" {
    const t = 1_790_000_000;
    const log = [_]Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + 3600, .level = 99, .plugged = false },
    };
    try std.testing.expect(seconds_left(&log, t + 3600, 99) == null);
    try std.testing.expect(seconds_left(log[0..1], t, 100) == null);
}

test "old drain falls out of the window" {
    const t = 1_790_000_000;
    const d = 86400;
    const log = [_]Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + d, .level = 50, .plugged = false }, // A bad day, a month ago
        .{ .time = t + 30 * d, .level = 100, .plugged = false },
        .{ .time = t + 32 * d, .level = 90, .plugged = false },
    };
    try std.testing.expectEqual(@as(u64, 18 * d), seconds_left(&log, t + 32 * d, 90).?);
}

test "times read naturally" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("About 20 hours", describe(&buf, 20 * 3600));
    try std.testing.expectEqualStrings("Less than 2 hours", describe(&buf, 3000));
    try std.testing.expectEqualStrings("About 5 days", describe(&buf, 5 * 86400));
    try std.testing.expectEqualStrings("About 3 weeks", describe(&buf, 21 * 86400));
}

test "a long gap or a clock reset doesn't run the estimate" {
    const t = 1_790_000_000;
    const d = 86400;
    // The first note two months back: only the last day counts, at 5% a day
    const gap = [_]Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + 60 * d, .level = 95, .plugged = false },
        .{ .time = t + 61 * d, .level = 90, .plugged = false },
    };
    try std.testing.expectEqual(@as(u64, 18 * d), seconds_left(&gap, t + 61 * d, 90).?);
    // A note from a reset clock (1970), and a damaged huge time: skipped, no overflow
    const reset = [_]Sample{
        .{ .time = 5, .level = 100, .plugged = false },
        .{ .time = t, .level = 95, .plugged = false },
        .{ .time = t + d, .level = 90, .plugged = false },
        .{ .time = std.math.maxInt(u64), .level = 80, .plugged = false },
    };
    try std.testing.expectEqual(@as(u64, 18 * d), seconds_left(&reset, t + d, 90).?);
}
