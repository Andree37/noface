//! The reading journal: how long was read each day, how many pages, and how many
//! books were finished, for the stats screen. Days are local calendar days, counted
//! from 1970. Every day is kept in the file, for good; memory holds the last `kept`
//! (about a year and a month, all the stats look at day by day) and, for a streak
//! longer than that, how many reading days in a row came just before them.
const std = @import("std");
const assert = std.debug.assert;

pub const kept = 400;

pub const Day = struct { day: i32, seconds: u32 = 0, pages: u32 = 0, finished: u16 = 0 };

/// A day counts toward a streak once this much was read in it.
pub const streak_seconds = 60;

pub const Journal = struct {
    days: [kept]Day = undefined,
    len: u32 = 0, // Oldest first
    /// Reading days in a row, in the file, ending the day before `days[0]`: what a
    /// streak reaching back past the days in memory adds.
    run_before: u32 = 0,

    fn find(j: *Journal, day: i32) *Day {
        assert(j.len <= kept);
        if (j.len > 0 and j.days[j.len - 1].day == day) return &j.days[j.len - 1];
        // A new day, or the clock went back: start a new entry, dropping the oldest
        // when full. An older day than the last is treated as the last, so totals
        // never go back in time.
        if (j.len > 0 and day < j.days[j.len - 1].day) return &j.days[j.len - 1];
        if (j.len == kept) {
            // The oldest leaves memory, not the file: a streak through it carries on
            j.run_before = run_after(j.run_before, j.days[0], j.days[1].day);
            std.mem.copyForwards(Day, j.days[0 .. kept - 1], j.days[1..kept]);
            j.len -= 1;
        }
        assert(j.len < kept);
        if (j.len > 0) assert(j.days[j.len - 1].day < day); // Days stay in order
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
        assert(d.seconds >= seconds);
        assert(d.pages >= pages);
    }

    /// A book finished on `day`.
    pub fn finish(j: *Journal, day: i32) void {
        const d = j.find(day);
        d.finished +|= 1;
        assert(d.finished > 0);
        assert(j.len > 0);
    }

    pub fn get(j: *const Journal, day: i32) Day {
        assert(j.len <= kept);
        var i = j.len;
        while (i > 0) {
            i -= 1;
            if (j.days[i].day == day) return j.days[i];
            if (j.days[i].day < day) break;
        }
        const missing: Day = .{ .day = day };
        assert(missing.seconds == 0);
        return missing;
    }

    /// Seconds read over the `n` days ending with `day`.
    pub fn seconds_over(j: *const Journal, day: i32, n: i32) u64 {
        assert(n > 0);
        assert(j.len <= kept);
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
        // Bounded: a day missing from the journal ends the streak, so it runs at most
        // one step for each day kept.
        while (j.get(at).seconds >= streak_seconds) : (at -= 1) n += 1;
        assert(n <= j.len);
        assert(at < day);
        // Every day back to the first in memory read: the run before it goes on
        if (j.len > 0 and at == j.days[0].day - 1) n += j.run_before;
        return n;
    }

    /// Books finished and seconds read from `first` to `day`, as for a year so far.
    pub fn since(
        j: *const Journal,
        first: i32,
        day: i32,
    ) struct { finished: u32, seconds: u64 } {
        assert(first <= day);
        assert(j.len <= kept);
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

/// Reading days in a row ending the day before `next_day`, given `day` and the run
/// that ended the day before it.
fn run_after(run_before_day: u32, day: Day, next_day: i32) u32 {
    assert(next_day > day.day); // Days stay in order
    const read = day.seconds >= streak_seconds;
    const run: u32 = if (read) run_before_day + 1 else 0;
    if (!read) assert(run == 0);
    return if (next_day == day.day + 1) run else 0;
}

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
    assert(start <= day);
    assert(day - start < 366);
    return start;
}

/// Weekday of a day, 0 for Monday.
pub fn weekday(day: i32) u32 {
    // 1 January 1970 was a Thursday
    const result: u32 = @intCast(@mod(day + 3, 7));
    assert(result < 7);
    return result;
}

const format_tag = "journal 1";

/// The longest line a day can take: an i32, two u32s and a u16, three spaces, a newline.
const day_line_size_max = 11 + 10 + 10 + 5 + 3 + 1;

comptime {
    assert(kept > 366); // Over a year, so a year so far always fits
    assert(day_line_size_max <= 40);
    assert(format_tag.len + 1 <= 16);
}

/// The saved journal: its last `kept` days, and the reading run before them. A file
/// that doesn't read cleanly gives an empty journal: it sits on the USB drive and must
/// never stop noface.
pub fn parse(content: []const u8) Journal {
    const days = count_days(content) orelse return .{};
    var j = Journal{};
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    _ = lines.next(); // The tag, which `count_days` read
    // The days older than memory holds: only the run of reading days they end with
    var previous: ?Day = null;
    for (0..days -| kept) |_| {
        const d = parse_day(lines.next().?).?; // Read once by `count_days`
        if (previous) |p| j.run_before = run_after(j.run_before, p, d.day);
        previous = d;
    }
    while (lines.next()) |line| {
        const d = parse_day(line).?;
        if (previous) |p| {
            if (j.len == 0) j.run_before = run_after(j.run_before, p, d.day);
        }
        j.days[j.len] = d;
        j.len += 1;
    }
    assert(j.len == @min(days, kept));
    if (days <= kept) assert(j.run_before == 0);
    return j;
}

/// How many days the journal file holds, or null when it isn't one, whole: its tag,
/// then days in order, each with its four numbers.
fn count_days(content: []const u8) ?u32 {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return null, format_tag)) return null;
    var count: u32 = 0;
    var last: ?i32 = null;
    while (lines.next()) |line| {
        const d = parse_day(line) orelse return null;
        if (last) |l| {
            if (d.day <= l) return null; // Out of order: not ours
        }
        last = d.day;
        count += 1;
    }
    assert(count <= content.len);
    if (count == 0) assert(last == null);
    return count;
}

// Assertions: it reads a line of the journal file, which sits on the USB drive: outside data.
fn parse_day(line: []const u8) ?Day {
    var f = std.mem.tokenizeScalar(u8, line, ' ');
    const day = std.fmt.parseInt(i32, f.next() orelse return null, 10) catch return null;
    const seconds = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null;
    const pages = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null;
    const finished = std.fmt.parseInt(u16, f.next() orelse return null, 10) catch return null;
    return .{ .day = day, .seconds = seconds, .pages = pages, .finished = finished };
}

/// The lines of the journal file `content` for days before `first_day`, which memory
/// no longer holds, to be written again ahead of those it does. Empty for a file
/// that isn't a journal.
pub fn older_lines(content: []const u8, first_day: i32) []const u8 {
    if (count_days(content) == null) return "";
    const start = format_tag.len + 1; // Past the tag's line
    if (content.len <= start) return "";
    var end: u32 = start;
    var lines = std.mem.splitScalar(u8, content[start..], '\n');
    while (lines.next()) |line| {
        const d = parse_day(line) orelse break; // The end: an empty last part
        if (d.day >= first_day) break;
        end += @intCast(line.len + 1);
    }
    assert(end <= content.len);
    assert(end >= start);
    return content[start..end];
}

/// The journal's tag line, which `format` starts with, so older lines can follow it.
pub const tag_line_bytes: u32 = format_tag.len + 1;

/// Writes the journal into `buf` (one line per day, under 40 bytes each).
pub fn format(buf: []u8, j: *const Journal) []const u8 {
    assert(buf.len >= max_format_bytes);
    assert(j.len <= kept);
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}\n", .{format_tag}) catch return "";
    for (j.days[0..j.len]) |d| {
        const fields = .{ d.day, d.seconds, d.pages, d.finished };
        w.print("{d} {d} {d} {d}\n", fields) catch return "";
    }
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

test "the oldest days leave memory when full, and a streak through them goes on" {
    var j = Journal{};
    var d: i32 = 0;
    while (d < kept + 5) : (d += 1) j.add(d, 60, 1);
    try std.testing.expectEqual(@as(usize, kept), j.len);
    try std.testing.expectEqual(@as(i32, 5), j.days[0].day);
    try std.testing.expectEqual(@as(u32, kept + 5), j.streak(d - 1));
}

test "every day stays in the file, and a streak over years is counted whole" {
    const days = 3 * 365;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, format_tag ++ "\n");
    for (0..days) |i| {
        // One day without reading, early on: the streak starts after it
        const seconds: u32 = if (i == 10) 0 else 600;
        try text.print(std.testing.allocator, "{d} {d} 1 0\n", .{ 1000 + i, seconds });
    }
    const j = parse(text.items);
    try std.testing.expectEqual(@as(u32, kept), j.len);
    try std.testing.expectEqual(@as(u32, days - 11), j.streak(1000 + days - 1));
    // Saving writes back the days memory no longer holds, then those it does
    const older = older_lines(text.items, j.days[0].day);
    try std.testing.expectEqual(@as(usize, days - kept), std.mem.count(u8, older, "\n"));
    var buf: [max_format_bytes]u8 = undefined;
    const window = format(&buf, &j);
    var saved: std.ArrayList(u8) = .empty;
    defer saved.deinit(std.testing.allocator);
    try saved.appendSlice(std.testing.allocator, window[0..tag_line_bytes]);
    try saved.appendSlice(std.testing.allocator, older);
    try saved.appendSlice(std.testing.allocator, window[tag_line_bytes..]);
    try std.testing.expectEqualStrings(text.items, saved.items);
    try std.testing.expectEqualStrings("", older_lines("not a journal\n1 2 3 4\n", 5));
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
    // Past midnight an hour east
    try std.testing.expectEqual(@as(i32, 1), day_of(86400 - 1800, 3600));
    try std.testing.expectEqual(@as(u32, 3), weekday(0)); // Thursday
    // 2026-11-10 is day 20767, a Tuesday; 2026 began on day 20454
    try std.testing.expectEqual(@as(i32, 20454), year_start(20767));
    try std.testing.expectEqual(@as(i32, 20454), year_start(20454));
    try std.testing.expectEqual(@as(u32, 1), weekday(20767));
}
