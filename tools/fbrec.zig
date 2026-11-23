//! Records the framebuffer as a run of small frames, for demo videos and for timing
//! how soon a screen is drawn after a touch. Each frame keeps every `scale`-th pixel
//! of every `scale`-th row, prefixed by when it was taken (monotonic microseconds,
//! the clock touchsim prints). It reads only those rows, so the screen's slow memory
//! isn't read whole, and reads them as tools/e2e.zig does: at the driver's stride.
//! Usage: fbrec <seconds> <frames-per-second> <scale> <out-file>
//! Output: "FBREC <width> <height>\n", then per frame an 8-byte little-endian
//! timestamp and width*height gray bytes. Touches on the screen, from anyone or
//! anything, go to "<out-file>.touches", one "<down|up> <time>" line each, on the
//! same clock: the panel's events are read alongside without taking them from the
//! app on screen.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const e2e = @import("e2e.zig");
const linux = std.os.linux;
const now_us = core.os.now_us;
const Screen = e2e.Screen;
const row_size_max = e2e.row_size_max;

/// Each frame starts with the time it was taken: a little-endian u64.
const frame_header_size = @sizeOf(u64);
const ev_abs = core.evdev.ev_abs;
const abs_mt_tracking_id = core.evdev.abs_mt_tracking;
/// Reads of the touch panel per frame, each of up to `events_per_read` events: far more
/// than fingers can make in a frame, and what's left is read on the next one.
const touch_reads_max = 64;
const events_per_read = 64;

const InputEvent = core.evdev.InputEvent;

comptime {
    assert(@sizeOf(InputEvent) == 16);
}

/// Where frames are read from and written to, and how they're scaled down.
const Recording = struct {
    screen: Screen,
    out: i32,
    /// The touch panel and the log of its touches, or -1 for either that didn't open.
    touch: i32,
    touches_out: i32,
    scale: u32,
    width_out: u32,
    height_out: u32,
    wall_to_monotonic_us: i64,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 5) return error.Usage;
    const seconds = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[1], 0), 10);
    const frames_per_second = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10);
    const scale = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[3], 0), 10);
    if (frames_per_second == 0 or scale == 0) return error.Usage;

    const screen = try Screen.open();
    const width_out = screen.width / scale;
    const height_out = screen.height / scale;

    const rc = linux.open(argv[4], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (core.os.failed(rc)) return error.CantWrite;
    const out: i32 = @intCast(rc);
    // Ignored: whether the frames were written is told as each is
    defer _ = linux.close(out);
    var head: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&head, "FBREC {d} {d}\n", .{ width_out, height_out });
    if (!core.file.write_all(out, header)) return error.CantWrite;

    // The touch panel, read beside whoever has it: events carry their own time
    const touch_flags: linux.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true };
    var touch_path: [32]u8 = undefined;
    const touch_rc = linux.open(core.devices.touch_path(&touch_path), touch_flags, 0);
    const touch: i32 = if (core.os.failed(touch_rc)) -1 else @intCast(touch_rc);
    var touches_path: [512]u8 = undefined;
    const out_path = std.mem.sliceTo(argv[4], 0);
    const touches_path_z =
        try std.fmt.bufPrintSentinel(&touches_path, "{s}.touches", .{out_path}, 0);
    const touches_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const touches_rc = linux.open(touches_path_z, touches_flags, 0o644);
    const touches_out: i32 = if (core.os.failed(touches_rc)) -1 else @intCast(touches_rc);
    defer if (touches_out >= 0) {
        _ = linux.close(touches_out); // Ignored: each line was written whole or stopped the log
    };
    // Event times are wall-clock; the frames use the monotonic clock. The offset
    // between the two, taken once, puts both on one clock.
    var wall: linux.timespec = undefined;
    // Ignored: the wall clock always answers
    _ = linux.clock_gettime(.REALTIME, &wall);
    const wall_us: i64 = @as(i64, wall.sec) * 1_000_000 + @divTrunc(@as(i64, wall.nsec), 1000);
    const recording = Recording{
        .screen = screen,
        .out = out,
        .touch = touch,
        .touches_out = touches_out,
        .scale = scale,
        .width_out = width_out,
        .height_out = height_out,
        .wall_to_monotonic_us = @as(i64, @intCast(now_us())) - wall_us,
    };

    const frame = try std.heap.page_allocator.alloc(u8, frame_header_size + width_out * height_out);
    const frames = record(&recording, frame, seconds, frames_per_second);
    std.debug.print("fbrec: {d} frames of {d}x{d}\n", .{ frames, width_out, height_out });
}

/// Takes frames for `seconds`, `frames_per_second` of them a second, and returns how many.
fn record(recording: *const Recording, frame: []u8, seconds: u32, frames_per_second: u32) u32 {
    assert(frames_per_second > 0);
    assert(frame.len == frame_header_size + recording.width_out * recording.height_out);
    var row: [row_size_max]u8 = undefined;
    const step_us: u64 = 1_000_000 / frames_per_second;
    const end_us = now_us() + @as(u64, seconds) * 1_000_000;
    var next_us = now_us();
    var frames: u32 = 0;
    var touches_logged = true; // Until a line of them can't be written
    while (now_us() < end_us) {
        if (!record_frame(recording, frame, &row, now_us())) {
            std.debug.print("fbrec: stopped, the screen couldn't be read\n", .{});
            break;
        }
        // A frame not written whole (a full drive): the recording ends with the last one
        if (!core.file.write_all(recording.out, frame)) {
            std.debug.print("fbrec: stopped, the frame wasn't written\n", .{});
            break;
        }
        frames += 1;
        if (touches_logged and recording.touch >= 0 and recording.touches_out >= 0) {
            const wall = recording.wall_to_monotonic_us;
            touches_logged = log_touches(recording.touch, recording.touches_out, wall);
            if (!touches_logged) std.debug.print("fbrec: touches no longer logged\n", .{});
        }
        next_us += step_us;
        const now = now_us();
        if (next_us > now) core.os.sleep_ms((next_us - now) / 1000);
    }
    return frames;
}

/// Fills `frame` with the time and every `scale`-th pixel of every `scale`-th row.
fn record_frame(
    recording: *const Recording,
    frame: []u8,
    row: *[row_size_max]u8,
    time_us: u64,
) bool {
    const screen = &recording.screen;
    assert(recording.scale > 0);
    assert(recording.width_out * recording.scale <= screen.width);
    assert(recording.height_out * recording.scale <= screen.height);
    const width_out = recording.width_out;
    std.mem.writeInt(u64, frame[0..frame_header_size], time_us, .little);
    // Where the shown screen starts, once a frame: it may flip between two
    const first = screen.top();
    for (0..recording.height_out) |y| {
        if (!screen.read_row(row, first, @as(u32, @intCast(y)) * recording.scale)) return false;
        const target = frame[frame_header_size + y * width_out ..][0..width_out];
        for (target, 0..) |*pixel, x| pixel.* = row[x * recording.scale];
    }
    return true;
}

/// Writes a line for each finger landing or lifting since last time: false when one
/// couldn't be written.
fn log_touches(touch: i32, out: i32, wall_to_monotonic_us: i64) bool {
    assert(touch >= 0);
    assert(out >= 0);
    var events: [events_per_read]InputEvent = undefined;
    for (0..touch_reads_max) |_| {
        const n = linux.read(touch, @ptrCast(&events), @sizeOf(@TypeOf(events)));
        if (core.os.failed(n) or n < @sizeOf(InputEvent)) return true; // Nothing more yet
        for (events[0 .. n / @sizeOf(InputEvent)]) |event| {
            if (event.kind != ev_abs or event.code != abs_mt_tracking_id) continue;
            const time_us = @as(i64, event.sec) * 1_000_000 + event.usec + wall_to_monotonic_us;
            const finger = if (event.value >= 0) "down" else "up";
            var line: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s} {d}\n", .{ finger, time_us }) catch continue;
            if (!core.file.write_all(out, text)) return false;
        }
    }
    return true;
}
