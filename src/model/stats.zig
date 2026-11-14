//! Reading statistics: how fast this reader reads, and so how long is left.
//! Like the Kindle's own reading timer, speed is words per minute learned from page
//! turns, and pages that don't look like reading are left out. Unlike it, speed is
//! total words over total time (an average of per-page speeds reads fast whenever page
//! times vary), and older pages fade, so a slower or harder book is followed.
const std = @import("std");
const assert = std.debug.assert;

/// Longer than this, the reader stepped away: not reading.
pub const max_page_seconds = 300;
const min_page_seconds = 3; // Quicker than this is flicking past
const min_wpm = 40; // Same bounds as the Kindle's
const max_wpm = 900;
const min_page_words = 20; // Fewer words (a title page) says little about speed
const learn_pages = 5; // Before estimates are shown: this many pages...
const learn_seconds = 120; // ...and this much reading
/// Weight left on older pages after each new one: about 35 pages to halve.
const fade = 0.98;
/// A page this many times faster or slower than usual is a fluke...
const fluke_ratio = 3.0;
const flukes_to_believe = 5; // ...unless it keeps happening: then the reader changed

/// Decayed sums can't grow past this many seconds of reading.
const max_seconds: f64 = @as(f64, max_page_seconds) / (1 - fade);

comptime {
    assert(min_page_seconds < max_page_seconds);
    assert(min_wpm < max_wpm);
    assert(fade > 0);
    assert(fade < 1);
    assert(fluke_ratio > 1);
    // Learning can finish: the pages it takes can hold the time it takes.
    assert(learn_seconds <= learn_pages * max_page_seconds);
    assert(learn_seconds < max_seconds);
}

/// This reader's speed, over every book.
pub const Speed = struct {
    pages: u32 = 0, // Pages counted
    words: f64 = 0, // Words read, older pages fading
    seconds: f64 = 0, // Time spent reading them, fading alike
    flukes_in_row: u8 = 0, // Not saved

    pub fn wpm(s: Speed) f64 {
        // `record` and `parse` keep both sums from going negative.
        assert(s.seconds >= 0);
        assert(s.words >= 0);
        return if (s.seconds > 0) s.words * 60 / s.seconds else 0;
    }

    /// Counts one page read forward, unless it doesn't look like reading.
    pub fn record(s: *Speed, words: u64, us: u64) void {
        // A run of flukes long enough to believe is counted, which ends the run.
        assert(s.flukes_in_row < flukes_to_believe);
        const seconds = @as(f64, @floatFromInt(us)) / 1e6;
        if (words < min_page_words) return;
        if (seconds < min_page_seconds or seconds > max_page_seconds) return;
        const page_wpm = @as(f64, @floatFromInt(words)) * 60 / seconds;
        if (page_wpm < min_wpm or page_wpm > max_wpm) return;
        if (s.known()) {
            const ratio = page_wpm / s.wpm();
            if (ratio > fluke_ratio or ratio < 1.0 / fluke_ratio) {
                s.flukes_in_row += 1;
                if (s.flukes_in_row < flukes_to_believe) return;
            }
        }
        s.flukes_in_row = 0;
        s.words = s.words * fade + @as(f64, @floatFromInt(words));
        s.seconds = s.seconds * fade + seconds;
        s.pages +|= 1;
        assert(s.seconds <= max_seconds + 1); // As `parse` allows
    }

    /// Enough reading to give honest estimates.
    pub fn known(s: Speed) bool {
        const enough = s.pages >= learn_pages and s.seconds >= learn_seconds;
        if (enough) assert(s.seconds > 0);
        return enough;
    }

    /// Minutes to read `words` more, rounded up. Null while still learning.
    pub fn minutes_for(s: Speed, words: u64) ?u64 {
        if (!s.known()) return null;
        // Every page counted reads at `min_wpm` or more, so a known speed isn't zero.
        assert(s.wpm() > 0);
        // Less a hair, so 1000 words at 250 a minute is 4 minutes, not 5 by rounding error.
        const minutes = @ceil(@as(f64, @floatFromInt(words)) / s.wpm() - 1e-9);
        const minutes_capped = @min(minutes, 1e9);
        assert(minutes_capped <= 1e9);
        return @intFromFloat(minutes_capped);
    }
};

/// Words in some text: runs of anything but spaces, tabs and newlines. Whole books
/// are counted when opened, so this goes 32 bytes at a time.
pub fn count_words(text: []const u8) u64 {
    const lanes = 32;
    const Bytes = @Vector(lanes, u8);
    // A paragraph's text, on a 32-bit Kindle: its length fits.
    assert(text.len <= std.math.maxInt(u32));
    var n: u64 = 0;
    var prev_space = true;
    var i: u32 = 0;
    while (i + lanes <= text.len) : (i += lanes) {
        const chunk: Bytes = text[i..][0..lanes].*;
        const sp: u32 = @as(u32, @bitCast(chunk == @as(Bytes, @splat(' ')))) |
            @as(u32, @bitCast(chunk == @as(Bytes, @splat('\n')))) |
            @as(u32, @bitCast(chunk == @as(Bytes, @splat('\t'))));
        // A word starts on a non-space whose previous byte is a space.
        const prev: u32 = (sp << 1) | @intFromBool(prev_space);
        n += @popCount(~sp & prev);
        prev_space = sp >> (lanes - 1) == 1;
    }
    for (text[i..]) |c| {
        const space = c == ' ' or c == '\n' or c == '\t';
        if (!space and prev_space) n += 1;
        prev_space = space;
    }
    assert(n <= text.len); // A word takes a byte at least
    return n;
}

/// Time counted toward a book: the time on a page, unless it was left open.
pub fn counted_seconds(seconds: u64) u64 {
    const counted = if (seconds > max_page_seconds) 0 else seconds;
    assert(counted <= max_page_seconds);
    return counted;
}

/// "12 min", "1 h 5 min", "3 h".
pub fn format_minutes(buf: []u8, minutes: u64) []const u8 {
    if (minutes < 60) return std.fmt.bufPrint(buf, "{d} min", .{@max(minutes, 1)}) catch "";
    const h = minutes / 60;
    const m = minutes % 60;
    assert(h > 0);
    assert(m < 60);
    if (m == 0) return std.fmt.bufPrint(buf, "{d} h", .{h}) catch "";
    return std.fmt.bufPrint(buf, "{d} h {d} min", .{ h, m }) catch "";
}

/// How long a book has been read, for a line about it: "3 h 12 min", or null under a
/// minute, when there's nothing worth saying. Callers add their own words around it.
pub fn reading_time(buf: []u8, seconds: u64) ?[]const u8 {
    if (seconds < 60) return null;
    const minutes = seconds / 60;
    assert(minutes >= 1); // So "1 min" is never a rounded-up zero
    return format_minutes(buf, minutes);
}

/// Timestamps before this (2001) can't be a real reading: a clock reset to 1970, or
/// a placeholder like 1.
const earliest_plausible = 1_000_000_000;

const Unit = struct { days: i64, name: []const u8, most: i64 };
// Largest first. A unit is used from two of it up, so no "1 weeks"; months stop at
// 23 so they never read as "24 months" before turning into "2 years".
const units = [_]Unit{
    .{ .days = 365, .name = "years", .most = std.math.maxInt(i64) },
    .{ .days = 30, .name = "months", .most = 23 },
    .{ .days = 7, .name = "weeks", .most = std.math.maxInt(i64) },
    .{ .days = 1, .name = "days", .most = std.math.maxInt(i64) },
};

/// When `then` was, in words: "today", "yesterday", "3 days ago". Days are calendar
/// days in local time (`utc_offset` seconds east of UTC), so last night is
/// "yesterday" by morning. Null for a time that can't be right: before 2001, or more
/// than a day ahead of `now`, as after the clock is set back.
pub fn ago(buf: []u8, then: u64, now: u64, utc_offset: i64) ?[]const u8 {
    if (then < earliest_plausible or then > now + 86400) return null;
    const day_then = @divFloor(@as(i64, @intCast(then)) + utc_offset, 86400);
    const day_now = @divFloor(@as(i64, @intCast(now)) + utc_offset, 86400);
    // At most a day ahead, so at most a calendar day ahead.
    assert(day_then <= day_now + 1);
    const days = @max(day_now - day_then, 0);
    if (days == 0) return "today";
    if (days == 1) return "yesterday";
    assert(days >= 2);
    for (units) |u| {
        if (days >= 2 * u.days) {
            const count = @min(@divFloor(days, u.days), u.most);
            return std.fmt.bufPrint(buf, "{d} {s} ago", .{ count, u.name }) catch null;
        }
    }
    unreachable; // Two days or more always meets the last unit
}

test "time since counts calendar days in local time" {
    var buf: [24]u8 = undefined;
    const midnight: u64 = 1_800_000_000 - (1_800_000_000 % 86400); // A UTC midnight
    const morning = midnight + 7 * 3600;
    // Read at 23:30, looked at 07:00 next day: yesterday, though under 24 hours
    try std.testing.expectEqualStrings("yesterday", ago(&buf, midnight - 1800, morning, 0).?);
    const evening = midnight + 20 * 3600;
    try std.testing.expectEqualStrings("today", ago(&buf, midnight + 3600, evening, 0).?);
    // An hour east of UTC moves midnight: 23:30 UTC is already the next day there
    try std.testing.expectEqualStrings("today", ago(&buf, midnight - 1800, morning, 3600).?);
    // Slight skew
    try std.testing.expectEqualStrings("today", ago(&buf, midnight + 50, midnight, 0).?);
}

test "time since steps through units at their edges" {
    var buf: [24]u8 = undefined;
    const now: u64 = 1_800_000_000 - (1_800_000_000 % 86400) + 43200; // Midday
    const day: u64 = 86400;
    const cases = [_]struct { days: u64, want: []const u8 }{
        .{ .days = 1, .want = "yesterday" },       .{ .days = 2, .want = "2 days ago" },
        .{ .days = 13, .want = "13 days ago" },    .{ .days = 14, .want = "2 weeks ago" },
        .{ .days = 59, .want = "8 weeks ago" },    .{ .days = 60, .want = "2 months ago" },
        .{ .days = 700, .want = "23 months ago" }, .{ .days = 729, .want = "23 months ago" },
        .{ .days = 730, .want = "2 years ago" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, ago(&buf, now - c.days * day, now, 0).?);
    }
}

test "impossible times say nothing" {
    var buf: [24]u8 = undefined;
    try std.testing.expect(ago(&buf, 1, 1_800_000_000, 0) == null);
    try std.testing.expect(ago(&buf, 1_800_000_000 + 3 * 86400, 1_800_000_000, 0) == null);
}

test "reading time is only worth saying past a minute" {
    var buf: [24]u8 = undefined;
    try std.testing.expect(reading_time(&buf, 59) == null);
    const time = reading_time(&buf, 3 * 3600 + 12 * 60).?;
    try std.testing.expectEqualStrings("3 h 12 min", time);
}

const format_tag = "speed";

/// The saved speed. It sits on the USB drive, so anything that couldn't come from
/// record() means start over; it must never stop the reader.
pub fn parse(content: []const u8) Speed {
    var it = std.mem.tokenizeAny(u8, content, " \n");
    // Older files start over
    if (!std.mem.eql(u8, it.next() orelse return .{}, format_tag)) return .{};
    const pages = std.fmt.parseInt(u32, it.next() orelse return .{}, 10) catch return .{};
    const words = std.fmt.parseFloat(f64, it.next() orelse return .{}) catch return .{};
    const seconds = std.fmt.parseFloat(f64, it.next() orelse return .{}) catch return .{};
    // Each test is also false for NaN.
    if (!(seconds >= 0 and seconds <= max_seconds + 1 and words >= 0)) return .{};
    if (seconds > 0) {
        const w = words * 60 / seconds;
        if (!(w >= min_wpm * 0.99 and w <= max_wpm * 1.01)) return .{};
    } else if (words != 0) return .{};
    const speed: Speed = .{ .pages = pages, .words = words, .seconds = seconds };
    assert(speed.seconds >= 0);
    assert(speed.words >= 0);
    return speed;
}

pub fn format(buf: []u8, s: Speed) []const u8 {
    assert(s.seconds >= 0);
    assert(s.words >= 0);
    const fields = .{ format_tag, s.pages, s.words, s.seconds };
    return std.fmt.bufPrint(buf, "{s} {d} {d:.2} {d:.2}\n", fields) catch "";
}

fn page(s: *Speed, words: u64, seconds: f64) void {
    s.record(words, @intFromFloat(seconds * 1e6));
}

fn learned(wpm: u64) Speed {
    var s = Speed{};
    for (0..10) |_| page(&s, wpm, 60);
    return s;
}

test "speed is learned from a few minutes of real reading" {
    var s = Speed{};
    for (0..4) |_| page(&s, 250, 60);
    try std.testing.expect(!s.known());
    try std.testing.expect(s.minutes_for(1000) == null);
    page(&s, 250, 60);
    try std.testing.expect(s.known());
    // 250 words a minute: 1000 more words is 4 minutes, 1001 rounds up to 5.
    try std.testing.expectEqual(@as(u64, 4), s.minutes_for(1000).?);
    try std.testing.expectEqual(@as(u64, 5), s.minutes_for(1001).?);
}

test "five quick pages aren't enough to learn from" {
    var s = Speed{};
    for (0..5) |_| page(&s, 60, 5); // 720 wpm, 25 s in all
    try std.testing.expect(!s.known());
}

test "each filter alone keeps a page out" {
    const cases = [_]struct { words: u64, seconds: f64 }{
        .{ .words = 10, .seconds = 2 }, // Too few words (300 wpm otherwise)
        .{ .words = 30, .seconds = 2.5 }, // Too quick (720 wpm otherwise)
        .{ .words = 2000, .seconds = 301 }, // Stepped away (399 wpm otherwise)
        .{ .words = 1000, .seconds = 60 }, // Faster than anyone reads
        .{ .words = 30, .seconds = 60 }, // Slower than reading
    };
    for (cases) |c| {
        var s = Speed{};
        page(&s, c.words, c.seconds);
        try std.testing.expectEqual(@as(u32, 0), s.pages);
    }
}

test "a page far from the usual speed is a fluke" {
    var s = learned(250);
    const before = s;
    page(&s, 900, 60); // 3.6 times faster
    page(&s, 40, 60); // 6 times slower
    try std.testing.expectEqual(before.words, s.words);
    page(&s, 600, 60); // 2.4 times: a lighter book, counted
    try std.testing.expectEqual(before.pages + 1, s.pages);
}

test "flukes that keep coming mean the reader changed" {
    var s = learned(250);
    for (0..flukes_to_believe) |_| page(&s, 800, 60);
    try std.testing.expect(s.wpm() > 250);
}

test "a slower book is followed, not ignored" {
    var s = learned(300);
    for (0..100) |_| page(&s, 150, 60);
    try std.testing.expectApproxEqAbs(@as(f64, 150), s.wpm(), 10);
}

test "uneven pages don't make the estimate short" {
    var s = Speed{};
    for (0..20) |i| page(&s, 250, if (i % 2 == 0) 30 else 90);
    // 250 words a minute over the time actually spent: 240 minutes, give or take the
    // fading (an average of page speeds would say 180).
    const minutes = s.minutes_for(60000).?;
    try std.testing.expect(minutes >= 238 and minutes <= 246);
}

test "words are runs of non-spaces" {
    try std.testing.expectEqual(@as(u64, 0), count_words("  "));
    try std.testing.expectEqual(@as(u64, 4), count_words("Café — done, really"));
    try std.testing.expectEqual(@as(u64, 2), count_words(" two\nwords "));
}

test "counting 32 bytes at a time matches counting one by one" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var buf: [300]u8 = undefined;
    for (0..200) |_| {
        const len = r.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = switch (r.uintLessThan(u8, 5)) {
            0 => ' ',
            1 => '\n',
            else => 'a' + r.uintLessThan(u8, 3),
        };
        var slow: u64 = 0;
        var prev_space = true;
        for (buf[0..len]) |c| {
            const space = c == ' ' or c == '\n' or c == '\t';
            if (!space and prev_space) slow += 1;
            prev_space = space;
        }
        try std.testing.expectEqual(slow, count_words(buf[0..len]));
    }
}

test "time on a page left open isn't counted" {
    try std.testing.expectEqual(@as(u64, 0), counted_seconds(9999));
    try std.testing.expectEqual(@as(u64, 40), counted_seconds(40));
}

test "durations read naturally" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12 min", format_minutes(&buf, 12));
    try std.testing.expectEqualStrings("1 min", format_minutes(&buf, 0));
    try std.testing.expectEqualStrings("1 h 5 min", format_minutes(&buf, 65));
    try std.testing.expectEqualStrings("3 h", format_minutes(&buf, 180));
}

test "speed survives a save" {
    var buf: [80]u8 = undefined;
    const s = learned(260);
    const back = parse(format(&buf, s));
    try std.testing.expectEqual(s.pages, back.pages);
    try std.testing.expectApproxEqAbs(s.words, back.words, 0.01);
    try std.testing.expectApproxEqAbs(s.seconds, back.seconds, 0.01);
}

test "a damaged speed file starts over instead of stopping the reader" {
    const bad = [_][]const u8{
        "garbage",
        "13203 57\n", // The first, byte-based file
        "wpm 5 250 0\n", // The short-lived per-page average
        "speed 5 1e-300 0\n",
        "speed 5 100 1e-300\n", // Absurdly fast
        "speed 7 1e50 1e50\n",
        "speed 5 nan 600\n",
        "speed 5 10 600\n", // 1 wpm
        "speed 4294967296 2500 600\n",
    };
    for (bad) |content| try std.testing.expectEqual(Speed{}, parse(content));
    // The largest real file still fits the save buffer.
    var buf: [80]u8 = undefined;
    const most = Speed{
        .pages = std.math.maxInt(u32),
        .words = max_seconds * max_wpm / 60,
        .seconds = max_seconds,
    };
    try std.testing.expect(format(&buf, most).len > 0);
    try std.testing.expectEqual(most.pages, parse(format(&buf, most)).pages);
}
