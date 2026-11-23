//! Notes the battery level whenever it changes, for how long it will last. Read from
//! sysfs, so it costs a file read, not a program. The log keeps its newest part only.
const std = @import("std");
const assert = std.debug.assert;
const battery = @import("../model/battery.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");
const devices = @import("devices.zig");
const linux = @import("../sys/calls.zig");

/// Past this the log is cut to its newest half: weeks of changes either way.
const log_bytes_max = 48 * 1024;
/// One line of the log: a time, a level and whether it was plugged in, as
/// `battery.format_line` writes it.
const line_bytes_max = 40;

comptime {
    // The longest line: a u64 time, a u32 level, a one-letter state, two spaces and a
    // newline. It always fits, so formatting one never comes back empty.
    assert(@sizeOf(battery.Line) <= line_bytes_max); // A line as the model writes it
    // Reading the log back always has room for the half that trimming keeps
    assert(log_bytes_max / 2 + line_bytes_max < log_bytes_max);
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
    var line_buffer: battery.Line = undefined;
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
    // Ignored: A note that doesn't get written is one sample fewer: the next change notes again
    _ = linux.write(fd, line.ptr, line.len);
    var size: linux.off_t = 0;
    const sought = !os.failed(linux.llseek(fd, 0, &size, linux.SEEK.END));
    const big = sought and size > log_bytes_max;
    // Ignored: the line above was written or not; its close adds nothing
    _ = linux.close(fd);
    if (big) note_trim(path);
}

/// Keeps the newest half of the log, from a line start.
fn note_trim(path: [*:0]const u8) void {
    var buffer: [log_bytes_max + 4096]u8 = undefined;
    const all = file.read_small(path, &buffer);
    assert(all.len <= buffer.len);
    const cut = all.len / 2;
    const start = (std.mem.indexOfScalarPos(u8, all, cut, '\n') orelse return) + 1;
    assert(start > cut);
    assert(start <= all.len);
    file.write_small(path, all[start..]);
}

/// The samples in the log, oldest first, as many as `out` holds (the newest).
pub fn load(path: [*:0]const u8, out: []battery.Sample) []battery.Sample {
    assert(out.len > 0);
    assert(out.len <= std.math.maxInt(u32));
    var buffer: [log_bytes_max + 4096]u8 = undefined;
    const all = file.read_small(path, &buffer);
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
