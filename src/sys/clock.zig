//! Local time for the clocks noface draws.
const std = @import("std");
const process = @import("process.zig");

/// Turns date's "+0100" into seconds.
pub fn parse_offset(zone: []const u8) i64 {
    if (zone.len < 5) return 0;
    const hours = std.fmt.parseInt(i64, zone[1..3], 10) catch return 0;
    const minutes = std.fmt.parseInt(i64, zone[3..5], 10) catch return 0;
    const seconds = hours * 3600 + minutes * 60;
    return if (zone[0] == '-') -seconds else seconds;
}

/// The device's offset from UTC, so the clock needs no process per minute.
pub fn utc_offset() i64 {
    const argv = [_:null]?[*:0]const u8{ "/bin/date", "+%z" };
    var buf: [16]u8 = undefined;
    const n = process.run(&argv, &buf) orelse return 0;
    return parse_offset(std.mem.trim(u8, buf[0..n], " \n"));
}

/// "HH:MM" for a Unix time.
pub fn format_clock(buf: []u8, unix: i64, offset: i64) []const u8 {
    const minutes: u32 = @intCast(@divFloor(@mod(unix + offset, 86400), 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes / 60, minutes % 60 }) catch "";
}

test "clock formats local time" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("00:00", format_clock(&buf, 0, 0));
    try std.testing.expectEqualStrings("01:05", format_clock(&buf, 300, 3600));
    try std.testing.expectEqualStrings("23:30", format_clock(&buf, 0, -1800));
}

test "zone offsets parse" {
    try std.testing.expectEqual(@as(i64, 3600), parse_offset("+0100"));
    try std.testing.expectEqual(@as(i64, -19800), parse_offset("-0530"));
    try std.testing.expectEqual(@as(i64, 0), parse_offset(""));
}
