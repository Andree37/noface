//! Notes the battery level whenever it changes, for how long it will last. Read from
//! sysfs, so it costs a file read, not a program. The log keeps its newest part only.
const std = @import("std");
const battery = @import("../model/battery.zig");
const state = @import("../sys/state.zig");
const os = @import("../sys/os.zig");
const devices = @import("devices.zig");
const linux = @import("../sys/calls.zig");

/// Past this the log is cut to its newest half: weeks of changes either way.
const max_bytes = 48 * 1024;

/// The battery now, or null off a Kindle.
pub fn now() ?battery.Sample {
    const p = devices.power() orelse return null;
    return .{ .time = os.unix_time(), .level = p.level, .plugged = p.plugged };
}

/// Adds the battery to the log at `path` if it changed since `last`, which it updates.
pub fn note(path: [*:0]const u8, last: *?battery.Sample) void {
    const s = now() orelse return;
    if (last.*) |l| {
        if (l.level == s.level and l.plugged == s.plugged) return;
    }
    last.* = s;
    var line_buf: [40]u8 = undefined;
    const line = battery.format_line(&line_buf, s);
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (os.failed(rc)) return;
    const fd: i32 = @intCast(rc);
    _ = linux.write(fd, line.ptr, line.len);
    var size: linux.off_t = 0;
    const big = !os.failed(linux.llseek(fd, 0, &size, linux.SEEK.END)) and size > max_bytes;
    _ = linux.close(fd);
    if (big) trim(path);
}

/// Keeps the newest half of the log, from a line start.
fn trim(path: [*:0]const u8) void {
    var buf: [max_bytes + 4096]u8 = undefined;
    const all = state.read_small(path, &buf);
    const cut = all.len / 2;
    const start = (std.mem.indexOfScalarPos(u8, all, cut, '\n') orelse return) + 1;
    state.write_small(path, all[start..]);
}

/// The samples in the log, oldest first, as many as `out` holds (the newest).
pub fn load(path: [*:0]const u8, out: []battery.Sample) []battery.Sample {
    var buf: [max_bytes + 4096]u8 = undefined;
    const all = state.read_small(path, &buf);
    // Kept in a ring, so a long log costs one pass, then put in order
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, all, '\n');
    while (lines.next()) |line| {
        const s = battery.parse_line(line) orelse continue;
        out[n % out.len] = s;
        n += 1;
    }
    if (n <= out.len) return out[0..n];
    std.mem.rotate(battery.Sample, out, n % out.len);
    return out;
}

/// `noface battery-report`: how the battery has done on days off the charger, from the
/// battery log and the reading journal in `data_dir`, written to `fd`.
pub fn report(fd: i32, data_dir: []const u8) void {
    const journal = @import("../model/journal.zig");
    const clock = @import("../sys/clock.zig");
    const out = struct {
        fn line(f: i32, comptime fmt: []const u8, args: anytype) void {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
            _ = linux.write(f, s.ptr, s.len);
        }
    }.line;

    var path_buf: [320]u8 = undefined;
    var samples: [4096]battery.Sample = undefined;
    const log_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/battery", .{data_dir}, 0) catch return;
    // Only times the Kindle's clock could really have had, in order: a torn line or
    // one from a clock reset after a flat battery would point the report at 1970
    const now_s = @import("../sys/os.zig").unix_time();
    var kept: usize = 0;
    for (load(log_path, &samples)) |sm| {
        if (!battery.plausible(sm.time, now_s)) continue;
        if (kept > 0 and sm.time < samples[kept - 1].time) continue;
        samples[kept] = sm;
        kept += 1;
    }
    const log = samples[0..kept];
    var journal_buf: [journal.max_format_bytes]u8 = undefined;
    const journal_path = std.fmt.bufPrintSentinel(&path_buf, "{s}/journal", .{data_dir}, 0) catch return;
    const j = journal.parse(state.read_small(journal_path, &journal_buf));

    out(fd, "noface battery report", .{});
    if (log.len < 2) {
        out(fd, "Not enough noted yet: read off the charger for a few days, then run this again.", .{});
        return;
    }
    // Seconds read on each day the log covers
    const offset = clock.utc_offset();
    const first = journal.day_of(log[0].time, offset);
    const last = journal.day_of(log[log.len - 1].time, offset);
    var read: [400]u32 = @splat(0);
    const span: usize = @intCast(@min(@max(last - first + 1, 0), read.len));
    for (read[0..span], 0..) |*r, i| r.* = j.get(first + @as(i32, @intCast(i))).seconds;

    const u = battery.usage(log, first, read[0..span], offset) orelse {
        out(fd, "No whole day off the charger yet: leave it unplugged for a day or more, then run this again.", .{});
        return;
    };
    out(fd, "days measured: {d} (unplugged all day)", .{u.days});
    out(fd, "reading:       {d:.1} hours a day on average", .{u.hours_read});
    out(fd, "drain:         {d:.1}% a day", .{u.per_day});
    if (u.per_hour_reading) |h| {
        out(fd, "  reading:     {d:.1}% an hour", .{h});
        out(fd, "  standby:     {d:.1}% a day", .{u.per_day_idle.?});
    } else out(fd, "  (read different amounts on different days to split reading from standby)", .{});
    if (u.per_day > 0.05) out(fd, "a full charge: about {d:.0} days at this rate", .{100 / u.per_day});
}
