//! The reading journal: how long was read each day, how many pages, and how many
//! books were finished, for the stats screen. Days are local calendar days, counted
//! from 1970. Only the last `kept` days are kept, about a year and a month.
const std = @import("std");

pub const kept = 400;

pub const Day = struct { day: i32, seconds: u32 = 0, pages: u32 = 0, finished: u16 = 0 };

/// A day counts toward a streak once this much was read in it.
pub const streak_seconds = 60;

pub const Journal = struct {
    days: [kept]Day = undefined,
    len: usize = 0, // Oldest first

    fn find(j: *Journal, day: i32) *Day {
        if (j.len > 0 and j.days[j.len - 1].day == day) return &j.days[j.len - 1];
        // A new day, or the clock went back: start a new entry, dropping the oldest
        // when full. An older day than the last is treated as the last, so totals
        // never go back in time.
        if (j.len > 0 and day < j.days[j.len - 1].day) return &j.days[j.len - 1];
        if (j.len == kept) {
            std.mem.copyForwards(Day, j.days[0 .. kept - 1], j.days[1..kept]);
            j.len -= 1;
        }
        j.days[j.len] = .{ .day = day };
        j.len += 1;
        return &j.days[j.len - 1];
    }

    /// Time and pages read, counted on `day`.
    pub fn add(j: *Journal, day: i32, seconds: u32, pages: u32) void {
        if (seconds == 0 and pages == 0) return;
        const d = j.find(day);
        d.seconds +|= seconds;
        d.pages +|= pages;
    }

    /// A book finished on `day`.
    pub fn finish(j: *Journal, day: i32) void {
        const d = j.find(day);
        d.finished +|= 1;
    }

    pub fn get(j: *const Journal, day: i32) Day {
        var i = j.len;
        while (i > 0) {
            i -= 1;
            if (j.days[i].day == day) return j.days[i];
            if (j.days[i].day < day) break;
        }
        return .{ .day = day };
    }

    /// Seconds read over the `n` days ending with `day`.
    pub fn seconds_over(j: *const Journal, day: i32, n: i32) u64 {
        var total: u64 = 0;
        for (j.days[0..j.len]) |d| {
            if (d.day > day - n and d.day <= day) total += d.seconds;
        }
        return total;
    }

    /// Days in a row with some reading, ending today, or yesterday when nothing has
    /// been read yet today (the streak isn't lost until the day is over).
    pub fn streak(j: *const Journal, day: i32) u32 {
        var at = day;
        if (j.get(day).seconds < streak_seconds) at -= 1;
        var n: u32 = 0;
        while (j.get(at).seconds >= streak_seconds) : (at -= 1) n += 1;
        return n;
    }

    /// Books finished and seconds read from `first` to `day`, as for a year so far.
    pub fn since(j: *const Journal, first: i32, day: i32) struct { finished: u32, seconds: u64 } {
        var finished: u32 = 0;
        var seconds: u64 = 0;
        for (j.days[0..j.len]) |d| {
            if (d.day < first or d.day > day) continue;
            finished += d.finished;
            seconds += d.seconds;
        }
        return .{ .finished = finished, .seconds = seconds };
    }
};

/// The local calendar day of a Unix time, `utc_offset` seconds east of UTC.
pub fn day_of(unix: u64, utc_offset: i64) i32 {
    return @intCast(@divFloor(@as(i64, @intCast(unix)) + utc_offset, 86400));
}

/// The first day of the year `day` falls in.
pub fn year_start(day: i32) i32 {
    const es = std.time.epoch.EpochDay{ .day = @intCast(day) };
    const year = es.calculateYearDay().year;
    var start: i32 = 0;
    var y: std.time.epoch.Year = 1970;
    while (y < year) : (y += 1) start += std.time.epoch.getDaysInYear(y);
    return start;
}

/// Weekday of a day, 0 for Monday.
pub fn weekday(day: i32) u32 {
    // 1 January 1970 was a Thursday
    return @intCast(@mod(day + 3, 7));
}

const format_tag = "journal 1";

/// The saved journal. A file that doesn't read cleanly gives an empty journal: it
/// sits on the USB drive and must never stop noface.
pub fn parse(content: []const u8) Journal {
    var j = Journal{};
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return j, format_tag)) return j;
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const day = std.fmt.parseInt(i32, f.next() orelse return .{}, 10) catch return .{};
        const seconds = std.fmt.parseInt(u32, f.next() orelse return .{}, 10) catch return .{};
        const pages = std.fmt.parseInt(u32, f.next() orelse return .{}, 10) catch return .{};
        const finished = std.fmt.parseInt(u16, f.next() orelse return .{}, 10) catch return .{};
        if (j.len > 0 and day <= j.days[j.len - 1].day) return .{}; // Out of order: not ours
        if (j.len == kept) return .{};
        j.days[j.len] = .{ .day = day, .seconds = seconds, .pages = pages, .finished = finished };
        j.len += 1;
    }
    return j;
}

/// Writes the journal into `buf` (one line per day, under 40 bytes each).
pub fn format(buf: []u8, j: *const Journal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}\n", .{format_tag}) catch return "";
    for (j.days[0..j.len]) |d| w.print("{d} {d} {d} {d}\n", .{ d.day, d.seconds, d.pages, d.finished }) catch return "";
    return w.buffered();
}

pub const max_format_bytes = 16 + kept * 40;

test "days add up and a new day starts its own entry" {
    var j = Journal{};
    j.add(100, 300, 2);
    j.add(100, 60, 1);
    j.add(101, 120, 1);
    try std.testing.expectEqual(@as(u32, 360), j.get(100).seconds);
    try std.testing.expectEqual(@as(u32, 3), j.get(100).pages);
    try std.testing.expectEqual(@as(u32, 0), j.get(99).seconds);
    try std.testing.expectEqual(@as(u64, 480), j.seconds_over(101, 7));
    try std.testing.expectEqual(@as(u64, 120), j.seconds_over(101, 1));
}

test "a clock set back adds to the latest day rather than rewriting history" {
    var j = Journal{};
    j.add(200, 60, 1);
    j.add(150, 60, 1);
    try std.testing.expectEqual(@as(usize, 1), j.len);
    try std.testing.expectEqual(@as(u32, 120), j.get(200).seconds);
}

test "streaks run back from today, or yesterday until today has reading" {
    var j = Journal{};
    j.add(10, 600, 1);
    j.add(11, 600, 1);
    j.add(12, 30, 1); // Under a minute: not a reading day
    j.add(13, 600, 1);
    j.add(14, 600, 1);
    try std.testing.expectEqual(@as(u32, 2), j.streak(14));
    try std.testing.expectEqual(@as(u32, 2), j.streak(15)); // Nothing yet today
    try std.testing.expectEqual(@as(u32, 0), j.streak(16)); // Yesterday missed
}

test "the oldest days drop off when full" {
    var j = Journal{};
    var d: i32 = 0;
    while (d < kept + 5) : (d += 1) j.add(d, 60, 1);
    try std.testing.expectEqual(@as(usize, kept), j.len);
    try std.testing.expectEqual(@as(i32, 5), j.days[0].day);
}

test "a year so far counts finished books and time" {
    var j = Journal{};
    j.add(19_700, 600, 3);
    j.finish(19_700);
    j.add(19_800, 900, 4);
    j.finish(19_800);
    const y = j.since(19_750, 19_900);
    try std.testing.expectEqual(@as(u32, 1), y.finished);
    try std.testing.expectEqual(@as(u64, 900), y.seconds);
}

test "journal survives saving, and a damaged file starts over" {
    var j = Journal{};
    j.add(20_000, 600, 3);
    j.finish(20_001);
    var buf: [max_format_bytes]u8 = undefined;
    const back = parse(format(&buf, &j));
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(@as(u32, 600), back.get(20_000).seconds);
    try std.testing.expectEqual(@as(u16, 1), back.get(20_001).finished);
    try std.testing.expectEqual(@as(usize, 0), parse("journal 1\n5 x 1 0\n").len);
    try std.testing.expectEqual(@as(usize, 0), parse("journal 1\n5 1 1 0\n4 1 1 0\n").len);
    try std.testing.expectEqual(@as(usize, 0), parse("something else\n").len);
}

test "calendar helpers" {
    try std.testing.expectEqual(@as(i32, 0), day_of(3600, 0));
    try std.testing.expectEqual(@as(i32, 1), day_of(86400 - 1800, 3600)); // Past midnight an hour east
    try std.testing.expectEqual(@as(u32, 3), weekday(0)); // Thursday
    // 2026-11-10 is day 20767, a Tuesday; 2026 began on day 20454
    try std.testing.expectEqual(@as(i32, 20454), year_start(20767));
    try std.testing.expectEqual(@as(i32, 20454), year_start(20454));
    try std.testing.expectEqual(@as(u32, 1), weekday(20767));
}
