//! How long the battery will last, from how fast it has drained lately. noface notes the
//! level each time it changes; the time between two notes, both unplugged and the level
//! not risen, is real use (reading, and asleep in between). Plain data, no drawing.
const std = @import("std");

pub const Sample = struct { time: u64, level: u32, plugged: bool };

/// Drain from these days back counts: recent enough to follow how it's used now.
pub const window_s: u64 = 14 * 86400;
/// Less than this to go on, and the estimate would be noise.
const min_span_s: u64 = 12 * 3600;
const min_drop = 3;

/// "1793990000 87 u": time, level, plugged ("p") or unplugged ("u").
pub fn parseLine(line: []const u8) ?Sample {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const time = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const level = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const plug = it.next() orelse return null;
    if (level > 100) return null;
    return .{ .time = time, .level = level, .plugged = std.mem.eql(u8, plug, "p") };
}

pub fn formatLine(buf: []u8, s: Sample) []const u8 {
    return std.fmt.bufPrint(buf, "{d} {d} {s}\n", .{ s.time, s.level, if (s.plugged) "p" else "u" }) catch "";
}

/// Seconds the battery has left at `level`, at the drain seen in `log` (oldest first).
/// Null while there isn't enough unplugged use to tell.
pub fn secondsLeft(log: []const Sample, now: u64, level: u32) ?u64 {
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
        drop += a.level - b.level;
        span += b.time - a.time;
    }
    if (span < min_span_s or drop < min_drop) return null;
    return @as(u64, level) * span / drop;
}

/// After 2001 and not in the future: a time the Kindle's clock could really have had.
pub fn plausible(time: u64, now: u64) bool {
    return time >= 1_000_000_000 and time <= now + 86400;
}

/// "About 2 weeks", "About 5 days", "About 20 hours".
pub fn describe(buf: []u8, seconds: u64) []const u8 {
    const hours = seconds / 3600;
    const days = (seconds + 43200) / 86400;
    const weeks = (seconds + 3 * 86400) / (7 * 86400);
    if (hours < 2) return "Less than 2 hours";
    if (hours < 36) return std.fmt.bufPrint(buf, "About {d} hours", .{hours}) catch "";
    if (days < 14) return std.fmt.bufPrint(buf, "About {d} days", .{days}) catch "";
    return std.fmt.bufPrint(buf, "About {d} weeks", .{weeks}) catch "";
}

test "lines read back as written" {
    var buf: [40]u8 = undefined;
    const s = Sample{ .time = 1793990000, .level = 87, .plugged = false };
    const line = formatLine(&buf, s);
    try std.testing.expectEqualStrings("1793990000 87 u\n", line);
    try std.testing.expectEqual(s, parseLine(std.mem.trimEnd(u8, line, "\n")).?);
    try std.testing.expect(parseLine("12 300 u") == null);
    try std.testing.expect(parseLine("junk") == null);
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
    try std.testing.expectEqual(@as(u64, 19 * d), secondsLeft(&log, t + 3 * d, 95).?);
}

test "too little to go on says nothing" {
    const t = 1_790_000_000;
    const log = [_]Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + 3600, .level = 99, .plugged = false },
    };
    try std.testing.expect(secondsLeft(&log, t + 3600, 99) == null);
    try std.testing.expect(secondsLeft(log[0..1], t, 100) == null);
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
    try std.testing.expectEqual(@as(u64, 18 * d), secondsLeft(&log, t + 32 * d, 90).?);
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
    try std.testing.expectEqual(@as(u64, 18 * d), secondsLeft(&gap, t + 61 * d, 90).?);
    // A note from a reset clock (1970), and a damaged huge time: skipped, no overflow
    const reset = [_]Sample{
        .{ .time = 5, .level = 100, .plugged = false },
        .{ .time = t, .level = 95, .plugged = false },
        .{ .time = t + d, .level = 90, .plugged = false },
        .{ .time = std.math.maxInt(u64), .level = 80, .plugged = false },
    };
    try std.testing.expectEqual(@as(u64, 18 * d), secondsLeft(&reset, t + d, 90).?);
}

/// What the battery spent on whole days off the charger, split between reading and
/// the rest (asleep, mostly): fitted over the days, as drain = per_hour * hours read +
/// per_day. Days with a charge in them, or not covered by the log, don't count.
pub const Usage = struct {
    days: u32, // Whole days measured
    per_day: f64, // Average drop a day, in percent
    hours_read: f64, // Average reading a day
    per_hour_reading: ?f64, // Null when every day had the same reading, so it can't be told apart
    per_day_idle: ?f64,
};

/// The level at `t`, from the samples either side of it, if both are off the charger
/// and it didn't rise between them.
fn levelAt(log: []const Sample, t: u64) ?f64 {
    for (log[0..log.len -| 1], log[1..]) |a, b| {
        if (a.time > t or b.time < t) continue;
        if (a.plugged or b.plugged or b.level > a.level or b.time <= a.time) return null;
        const f = @as(f64, @floatFromInt(t - a.time)) / @as(f64, @floatFromInt(b.time - a.time));
        return @as(f64, @floatFromInt(a.level)) - f * @as(f64, @floatFromInt(a.level - b.level));
    }
    return null;
}

/// Unplugged the whole of [from, to]: no sample in it says plugged.
fn offChargerThrough(log: []const Sample, from: u64, to: u64) bool {
    for (log) |s| {
        if (s.time >= from and s.time <= to and s.plugged) return false;
    }
    return true;
}

/// `read` is seconds read for each local day from `first_day` on (missing days read 0).
pub fn usage(log: []const Sample, first_day: i32, read: []const u32, utc_offset: i64) ?Usage {
    var n: u32 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (read, 0..) |seconds, i| {
        const day = first_day + @as(i32, @intCast(i));
        const start_signed = @as(i64, day) * 86400 - utc_offset;
        if (start_signed < 0) continue;
        const start: u64 = @intCast(start_signed);
        const end = start + 86400;
        if (!offChargerThrough(log, start, end)) continue;
        const from = levelAt(log, start) orelse continue;
        const to = levelAt(log, end) orelse continue;
        const x = @as(f64, @floatFromInt(seconds)) / 3600;
        const y = from - to;
        n += 1;
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
    }
    if (n == 0) return null;
    const nf: f64 = @floatFromInt(n);
    const spread = nf * sxx - sx * sx;
    var out = Usage{ .days = n, .per_day = sy / nf, .hours_read = sx / nf, .per_hour_reading = null, .per_day_idle = null };
    if (n >= 3 and spread > 1e-6) {
        const slope = (nf * sxy - sx * sy) / spread;
        out.per_hour_reading = slope;
        out.per_day_idle = (sy - slope * sx) / nf;
    }
    return out;
}

test "a week off the charger splits into reading and standby" {
    // 2% a day asleep, plus 3% for each hour read; 0, 1, 2 and 3 hours on days 1-4
    const day0: i32 = 20000;
    const t0: u64 = @as(u64, @intCast(day0)) * 86400;
    var log: [6]Sample = undefined;
    const drops = [_]u32{ 2, 5, 8, 11 };
    var level: u32 = 90;
    log[0] = .{ .time = t0 - 3600, .level = level, .plugged = false };
    log[1] = .{ .time = t0, .level = level, .plugged = false };
    for (drops, 0..) |d, i| {
        level -= d;
        log[i + 2] = .{ .time = t0 + (i + 1) * 86400, .level = level, .plugged = false };
    }
    const read = [_]u32{ 0, 3600, 7200, 10800 };
    const u = usage(&log, day0, &read, 0).?;
    try std.testing.expectEqual(@as(u32, 4), u.days);
    try std.testing.expectApproxEqAbs(@as(f64, 3), u.per_hour_reading.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 2), u.per_day_idle.?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), u.per_day, 0.01);
}

test "days with a charge in them don't count" {
    const t0: u64 = 20000 * 86400;
    const log = [_]Sample{
        .{ .time = t0, .level = 80, .plugged = false },
        .{ .time = t0 + 40000, .level = 75, .plugged = true },
        .{ .time = t0 + 86400, .level = 95, .plugged = false },
    };
    try std.testing.expect(usage(&log, 20000, &.{3600}, 0) == null);
}
