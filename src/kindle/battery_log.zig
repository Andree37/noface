//! Notes the battery level whenever it changes, for how long it will last. Read from
//! sysfs, so it costs a file read, not a program. The log keeps its newest part only.
const std = @import("std");
const assert = std.debug.assert;
const battery = @import("../model/battery.zig");
const state = @import("../sys/state.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");
const devices = @import("devices.zig");
const linux = @import("../sys/calls.zig");

/// Past this the log is cut to its newest half: weeks of changes either way.
const log_bytes_max = 48 * 1024;
/// One line of the log: a time, a level and whether it was plugged in, as
/// `battery.format_line` writes it.
const line_bytes_max = 40;
/// The most days the report spreads reading over: more than a year.
const report_days_max = 400;

comptime {
    // The longest line: a u64 time, a u32 level, a one-letter state, two spaces and a
    // newline. It always fits, so formatting one never comes back empty.
    assert(20 + 1 + 10 + 1 + 1 + 1 <= line_bytes_max);
    // Reading the log back always has room for the half that trimming keeps
    assert(log_bytes_max / 2 + line_bytes_max < log_bytes_max);
    assert(report_days_max > 366);
}

/// The battery now, or null off a Kindle.
pub fn now() ?battery.Sample {
    const power = devices.power() orelse return null;
    const sample: battery.Sample = .{
        .time = os.unix_time(),
        .level = power.level,
        .plugged = power.plugged,
    };
    assert(sample.level == power.level);
    assert(sample.plugged == power.plugged);
    return sample;
}

/// Adds the battery to the log at `path` if it changed since `last`, which it updates.
pub fn note(path: [*:0]const u8, last: *?battery.Sample) void {
    const sample = now() orelse return;
    if (last.*) |previous| {
        if (previous.level == sample.level and previous.plugged == sample.plugged) return;
    }
    last.* = sample;
    assert(last.* != null);
    var line_buffer: [line_bytes_max]u8 = undefined;
    const line = battery.format_line(&line_buffer, sample);
    assert(line.len > 0);
    assert(line[line.len - 1] == '\n');
    const rc = linux.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o644);
    if (os.failed(rc)) return;
    const fd: i32 = @intCast(rc);
    // A note that doesn't get written is one sample fewer: the next change notes again
    _ = linux.write(fd, line.ptr, line.len);
    var size: linux.off_t = 0;
    const sought = !os.failed(linux.llseek(fd, 0, &size, linux.SEEK.END));
    const big = sought and size > log_bytes_max;
    _ = linux.close(fd);
    if (big) note_trim(path);
}

/// Keeps the newest half of the log, from a line start.
fn note_trim(path: [*:0]const u8) void {
    var buffer: [log_bytes_max + 4096]u8 = undefined;
    const all = state.read_small(path, &buffer);
    assert(all.len <= buffer.len);
    const cut = all.len / 2;
    const start = (std.mem.indexOfScalarPos(u8, all, cut, '\n') orelse return) + 1;
    assert(start > cut);
    assert(start <= all.len);
    state.write_small(path, all[start..]);
}

/// The samples in the log, oldest first, as many as `out` holds (the newest).
pub fn load(path: [*:0]const u8, out: []battery.Sample) []battery.Sample {
    assert(out.len > 0);
    assert(out.len <= std.math.maxInt(u32));
    var buffer: [log_bytes_max + 4096]u8 = undefined;
    const all = state.read_small(path, &buffer);
    assert(all.len <= buffer.len);
    // Kept in a ring, so a long log costs one pass, then put in order. No more lines
    // than bytes, so the count fits a u32.
    const out_count: u32 = @intCast(out.len);
    var count: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, all, '\n');
    while (lines.next()) |line| {
        const sample = battery.parse_line(line) orelse continue;
        out[count % out_count] = sample;
        count += 1;
    }
    assert(count <= all.len);
    if (count <= out_count) return out[0..count];
    std.mem.rotate(battery.Sample, out, count % out_count);
    return out;
}

/// One line of the battery report, written to `fd`. A line too long for the buffer is
/// left out rather than cut short.
fn report_line(fd: i32, comptime format: []const u8, arguments: anytype) void {
    assert(fd >= 0);
    comptime assert(format.len > 0);
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format ++ "\n", arguments) catch return;
    assert(text.len <= buffer.len);
    // The report goes to a terminal: a line it won't take can't be told about anyway
    _ = linux.write(fd, text.ptr, text.len);
}

/// Loads the log at `log_path` into `samples`, keeping only times the Kindle's clock
/// could really have had, in order: a torn line or one from a clock reset after a flat
/// battery would point the report at 1970.
fn report_samples(log_path: [*:0]const u8, samples: []battery.Sample) []battery.Sample {
    assert(samples.len > 0);
    const now_s = os.unix_time();
    var kept: u32 = 0;
    for (load(log_path, samples)) |sample| {
        if (!battery.plausible(sample.time, now_s)) continue;
        if (kept > 0 and sample.time < samples[kept - 1].time) continue;
        samples[kept] = sample;
        kept += 1;
    }
    assert(kept <= samples.len);
    for (samples[0..kept]) |sample| assert(battery.plausible(sample.time, now_s));
    return samples[0..kept];
}

/// `noface battery-report`: how the battery has done on days off the charger, from the
/// battery log and the reading journal in `data_dir`, written to `fd`.
pub fn report(fd: i32, data_dir: []const u8) void {
    assert(fd >= 0);
    const journal = @import("../model/journal.zig");
    const clock = @import("../sys/clock.zig");

    var path_buffer: [320]u8 = undefined;
    var samples: [4096]battery.Sample = undefined;
    const log_path =
        std.fmt.bufPrintSentinel(&path_buffer, "{s}/battery", .{data_dir}, 0) catch return;
    const log = report_samples(log_path, &samples);
    const journal_path =
        std.fmt.bufPrintSentinel(&path_buffer, "{s}/journal", .{data_dir}, 0) catch return;
    // Mapped: the file keeps every day, however many years
    const journal_text = file.map(journal_path) catch "";
    defer if (journal_text.len > 0) file.unmap(journal_text);
    const reading = journal.parse(journal_text);

    report_line(fd, "noface battery report", .{});
    if (log.len < 2) {
        report_line(fd, "Not enough noted yet: read off the charger for a few days, " ++
            "then run this again.", .{});
        return;
    }
    // Seconds read on each day the log covers
    const offset = clock.utc_offset();
    const first = journal.day_of(log[0].time, offset);
    const last = journal.day_of(log[log.len - 1].time, offset);
    assert(first <= last);
    var read: [report_days_max]u32 = @splat(0);
    const span: u32 = @intCast(@min(@max(last - first + 1, 0), read.len));
    for (read[0..span], 0..) |*seconds, index| {
        seconds.* = reading.get(first + @as(i32, @intCast(index))).seconds;
    }

    const usage = battery.usage(log, first, read[0..span], offset) orelse {
        report_line(fd, "No whole day off the charger yet: leave it unplugged for a day " ++
            "or more, then run this again.", .{});
        return;
    };
    report_line(fd, "days measured: {d} (unplugged all day)", .{usage.days});
    report_line(fd, "reading:       {d:.1} hours a day on average", .{usage.hours_read});
    report_line(fd, "drain:         {d:.1}% a day", .{usage.per_day});
    if (usage.per_hour_reading) |per_hour| {
        // `battery.usage` sets the two parts of the split together
        assert(usage.per_day_idle != null);
        report_line(fd, "  reading:     {d:.1}% an hour", .{per_hour});
        report_line(fd, "  standby:     {d:.1}% a day", .{usage.per_day_idle.?});
    } else {
        report_line(fd, "  (read different amounts on different days to split reading " ++
            "from standby)", .{});
    }
    if (usage.per_day > 0.05) {
        report_line(fd, "a full charge: about {d:.0} days at this rate", .{100 / usage.per_day});
    }
}
