//! Running mode's arithmetic: the reader's running pace, how it learns from their taps,
//! and where a tap lands. Reading on a treadmill is slower than reading in the hand,
//! and taps are rare, so the pace is its own, learned only from the reader going on
//! early (faster) or going back (slower). How long each phrase stays is
//! model/phrases.zig's.
const std = @import("std");
const assert = std.debug.assert;
const stats = @import("stats.zig");

/// The first pace: this share of the reader's speed in the hand, when it's known...
const first_share = 0.75;
/// ...else this, a slow reader's pace.
const first_wpm_unknown = 150;
/// How far one tap moves the pace: a few taps one way settle it.
const step_share = 0.08;
pub const pace_wpm_min = 60;
pub const pace_wpm_max = 600;
/// A touch shorter than this is a drop of sweat or a brush, not a finger's tap, which
/// stays on the glass a tenth of a second or so.
pub const contact_us_min = 60 * std.time.us_per_ms;
/// A second touch this soon after one that acted is a bump or a drip, not a choice.
pub const touch_gap_us = 700 * std.time.us_per_ms;

comptime {
    assert(pace_wpm_min < first_wpm_unknown);
    assert(first_wpm_unknown < pace_wpm_max);
    assert(first_share > 0);
    assert(first_share < 1); // Slower than in the hand
    assert(step_share > 0);
    assert(step_share < 0.5);
}

/// The pace running starts at: a share of the reader's speed in the hand.
pub fn first_pace(speed: stats.Speed) f64 {
    const wpm: f64 = if (speed.known()) speed.wpm() * first_share else first_wpm_unknown;
    return clamp_pace(wpm);
}

fn clamp_pace(wpm: f64) f64 {
    // Speeds come from `stats`, which keeps them numbers above zero
    assert(std.math.isFinite(wpm));
    assert(wpm > 0);
    return std.math.clamp(wpm, pace_wpm_min, pace_wpm_max);
}

/// The reader went on before the phrase's time was up: they read faster than the pace.
pub fn faster(wpm: f64) f64 {
    const next = clamp_pace(wpm * (1 + step_share));
    assert(next >= wpm or wpm > pace_wpm_max);
    return next;
}

/// The reader went back: the phrase moved on before they'd read it.
pub fn slower(wpm: f64) f64 {
    const next = clamp_pace(wpm * (1 - step_share));
    assert(next <= wpm or wpm < pace_wpm_min);
    return next;
}

/// Minutes to read `words` at `wpm`, rounded up, for the footer's time left.
pub fn minutes_for(wpm: f64, words: u64) u64 {
    assert(wpm >= pace_wpm_min);
    // Less a hair, as stats.Speed rounds: 300 words at 150 a minute is 2, not 3
    const minutes = @ceil(@as(f64, @floatFromInt(words)) / wpm - 1e-9);
    return @intFromFloat(@max(minutes, 0));
}

/// Where a tap lands while running: the top band pauses, the left third goes back a
/// phrase, and the rest, most of the screen, goes on. Big, so a hand mid-stride finds it.
pub const Zone = enum { pause, back, next };

pub fn zone(x: i32, y: i32, width: u32, top_band: u32) Zone {
    assert(width > 0);
    assert(top_band > 0);
    if (y < top_band) return .pause;
    if (x * 3 < @as(i32, @intCast(width))) return .back;
    return .next;
}

/// The running pace's line in the speed file, after the reader's speed's.
const pace_tag = "running";

/// The saved running pace, from the speed file; null when there's none, or it isn't
/// one the pace could be (the file sits on the USB drive).
pub fn parse_pace(content: []const u8) ?f64 {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = words.next() orelse continue;
        if (!std.mem.eql(u8, tag, pace_tag)) continue;
        const wpm = std.fmt.parseFloat(f64, words.next() orelse return null) catch return null;
        // Each test is also false for NaN
        if (!(wpm >= pace_wpm_min and wpm <= pace_wpm_max)) return null;
        return wpm;
    }
    return null;
}

pub fn format_pace(buf: []u8, wpm: f64) []const u8 {
    assert(wpm >= pace_wpm_min);
    assert(wpm <= pace_wpm_max);
    return std.fmt.bufPrint(buf, pace_tag ++ " {d:.1}\n", .{wpm}) catch "";
}

test "minutes left are the words at the pace, rounded up" {
    try std.testing.expectEqual(@as(u64, 1), minutes_for(150, 150));
    try std.testing.expectEqual(@as(u64, 2), minutes_for(150, 300));
    try std.testing.expectEqual(@as(u64, 0), minutes_for(150, 0));
}

test "the first pace is slower than in the hand, and taps move it each way within bounds" {
    try std.testing.expectEqual(@as(f64, first_wpm_unknown), first_pace(.{}));
    var known: stats.Speed = .{ .pages = 10, .words = 3000, .seconds = 600 };
    try std.testing.expect(known.known());
    try std.testing.expectApproxEqAbs(@as(f64, 300 * first_share), first_pace(known), 1e-6);
    known.words = 30_000; // 3000 a minute, past any pace
    try std.testing.expectEqual(@as(f64, pace_wpm_max), first_pace(known));
    const pace: f64 = 200;
    try std.testing.expect(faster(pace) > pace);
    try std.testing.expect(slower(pace) < pace);
    var low: f64 = pace;
    for (0..100) |_| low = slower(low);
    try std.testing.expectEqual(@as(f64, pace_wpm_min), low);
    var high: f64 = pace;
    for (0..100) |_| high = faster(high);
    try std.testing.expectEqual(@as(f64, pace_wpm_max), high);
}

test "taps land in the pause band, the back third, or the rest" {
    try std.testing.expectEqual(Zone.pause, zone(900, 50, 1272, 200));
    try std.testing.expectEqual(Zone.back, zone(100, 900, 1272, 200));
    try std.testing.expectEqual(Zone.back, zone(423, 900, 1272, 200));
    try std.testing.expectEqual(Zone.next, zone(424, 900, 1272, 200));
    try std.testing.expectEqual(Zone.next, zone(1271, 1695, 1272, 200));
}

test "the running pace is saved after the reader's speed, which reads as before" {
    var buf: [64]u8 = undefined;
    var speed_buf: [64]u8 = undefined;
    const speed: stats.Speed = .{ .pages = 10, .words = 3000, .seconds = 600 };
    const line = stats.format(&speed_buf, speed);
    const pace = format_pace(&buf, 187.5);
    var both: [128]u8 = undefined;
    const content = try std.fmt.bufPrint(&both, "{s}{s}", .{ line, pace });
    try std.testing.expectEqual(@as(?f64, 187.5), parse_pace(content));
    try std.testing.expectEqual(speed.pages, stats.parse(content).pages);
    try std.testing.expectEqual(@as(?f64, null), parse_pace(line));
    try std.testing.expectEqual(@as(?f64, null), parse_pace("running 9000\n"));
    try std.testing.expectEqual(@as(?f64, null), parse_pace("running nan\n"));
}
