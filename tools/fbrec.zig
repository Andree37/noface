//! Records the framebuffer as a run of small frames, for demo videos and for timing
//! how soon a screen is drawn after a touch. Each frame keeps every `scale`-th pixel
//! of every `scale`-th row, prefixed by when it was taken (monotonic microseconds,
//! the clock touchsim prints). It reads only those rows, so the screen's slow memory
//! isn't read whole.
//! Usage: fbrec <seconds> <frames-per-second> <scale> <out-file>
//! Output: "FBREC <width> <height>\n", then per frame an 8-byte little-endian
//! timestamp and width*height gray bytes. Touches on the screen, from anyone or
//! anything, go to "<out-file>.touches", one "<down|up> <time>" line each, on the
//! same clock: the panel's events are read alongside without taking them from the
//! app on screen.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const linux = std.os.linux;
const now_us = core.os.now_us;

const fbioget_vscreeninfo: u32 = 0x4600;
/// The kernel's `fb_var_screeninfo`, read whole; only the first fields matter here.
const screen_info_size = 160;
const xres_offset = 0;
const yres_offset = 4;
const yoffset_offset = 20;
const row_size_max = 4096;
/// Each frame starts with the time it was taken: a little-endian u64.
const frame_header_size = @sizeOf(u64);
const ev_abs = 3;
const abs_mt_tracking_id = 0x39;
/// Reads of the touch panel per frame, each of up to `events_per_read` events: far more
/// than fingers can make in a frame, and what's left is read on the next one.
const touch_reads_max = 64;
const events_per_read = 64;

/// The kernel's `input_event` on 32-bit ARM.
const InputEvent = extern struct { sec: u32, usec: u32, kind: u16, code: u16, value: i32 };

comptime {
    assert(@sizeOf(InputEvent) == 16);
    assert(xres_offset + 4 <= yres_offset);
    assert(yoffset_offset + 4 <= screen_info_size);
    // A row of the panel noface is drawn for, 1272 pixels across, fits.
    assert(row_size_max >= 1272);
}

/// Where frames are read from and written to, and how they're scaled down.
const Recording = struct {
    framebuffer: i32,
    out: i32,
    /// The touch panel and the log of its touches, or -1 for either that didn't open.
    touch: i32,
    touches_out: i32,
    width: u32,
    yoffset: u32,
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

    const framebuffer_rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY }, 0);
    if (core.os.failed(framebuffer_rc)) return error.NoFramebuffer;
    const framebuffer: i32 = @intCast(framebuffer_rc);
    var info: [screen_info_size]u8 align(4) = undefined;
    _ = linux.ioctl(framebuffer, fbioget_vscreeninfo, @intFromPtr(&info));
    const width: u32 = std.mem.readInt(u32, info[xres_offset..][0..4], .little);
    const height: u32 = std.mem.readInt(u32, info[yres_offset..][0..4], .little);
    const yoffset: u32 = std.mem.readInt(u32, info[yoffset_offset..][0..4], .little);
    const width_out = width / scale;
    const height_out = height / scale;

    const rc = linux.open(argv[4], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (core.os.failed(rc)) return error.CantWrite;
    const out: i32 = @intCast(rc);
    defer _ = linux.close(out);
    var head: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&head, "FBREC {d} {d}\n", .{ width_out, height_out });
    _ = linux.write(out, header.ptr, header.len);

    // The touch panel, read beside whoever has it: events carry their own time
    const touch_flags: linux.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true };
    const touch_rc = linux.open("/dev/input/event1", touch_flags, 0);
    const touch: i32 = if (core.os.failed(touch_rc)) -1 else @intCast(touch_rc);
    var touches_path: [512]u8 = undefined;
    const out_path = std.mem.sliceTo(argv[4], 0);
    const touches_path_z =
        try std.fmt.bufPrintSentinel(&touches_path, "{s}.touches", .{out_path}, 0);
    const touches_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const touches_rc = linux.open(touches_path_z, touches_flags, 0o644);
    const touches_out: i32 = if (core.os.failed(touches_rc)) -1 else @intCast(touches_rc);
    defer if (touches_out >= 0) {
        _ = linux.close(touches_out);
    };
    // Event times are wall-clock; the frames use the monotonic clock. The offset
    // between the two, taken once, puts both on one clock.
    var wall: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &wall);
    const wall_us: i64 = @as(i64, wall.sec) * 1_000_000 + @divTrunc(@as(i64, wall.nsec), 1000);
    const recording = Recording{
        .framebuffer = framebuffer,
        .out = out,
        .touch = touch,
        .touches_out = touches_out,
        .width = width,
        .yoffset = yoffset,
        .scale = scale,
        .width_out = width_out,
        .height_out = height_out,
        .wall_to_monotonic_us = @as(i64, @intCast(now_us())) - wall_us,
    };

    const frame = try std.heap.page_allocator.alloc(u8, frame_header_size + width_out * height_out);
    if (width > row_size_max) return error.ScreenTooWide;
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
    while (now_us() < end_us) {
        record_frame(recording, frame, &row, now_us());
        _ = linux.write(recording.out, frame.ptr, frame.len);
        frames += 1;
        if (recording.touch >= 0 and recording.touches_out >= 0) {
            log_touches(recording.touch, recording.touches_out, recording.wall_to_monotonic_us);
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
) void {
    assert(recording.scale > 0);
    assert(recording.width <= row.len);
    assert(recording.width_out * recording.scale <= recording.width);
    const width_out = recording.width_out;
    std.mem.writeInt(u64, frame[0..frame_header_size], time_us, .little);
    for (0..recording.height_out) |y| {
        const row_top: u32 = recording.yoffset + @as(u32, @intCast(y)) * recording.scale;
        const offset: i64 = @as(i64, row_top) * recording.width;
        _ = linux.pread(recording.framebuffer, row, recording.width, offset);
        const target = frame[frame_header_size + y * width_out ..][0..width_out];
        for (target, 0..) |*pixel, x| pixel.* = row[x * recording.scale];
    }
}

/// Writes a line for each finger landing or lifting since last time.
fn log_touches(touch: i32, out: i32, wall_to_monotonic_us: i64) void {
    assert(touch >= 0);
    assert(out >= 0);
    var events: [events_per_read]InputEvent = undefined;
    for (0..touch_reads_max) |_| {
        const n = linux.read(touch, @ptrCast(&events), @sizeOf(@TypeOf(events)));
        if (core.os.failed(n) or n < @sizeOf(InputEvent)) return;
        for (events[0 .. n / @sizeOf(InputEvent)]) |event| {
            if (event.kind != ev_abs or event.code != abs_mt_tracking_id) continue;
            const time_us = @as(i64, event.sec) * 1_000_000 + event.usec + wall_to_monotonic_us;
            const finger = if (event.value >= 0) "down" else "up";
            var line: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s} {d}\n", .{ finger, time_us }) catch continue;
            _ = linux.write(out, text.ptr, text.len);
        }
    }
}
