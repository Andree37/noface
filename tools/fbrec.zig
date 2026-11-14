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
const core = @import("core");
const linux = std.os.linux;
const now_us = core.os.now_us;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 5) return error.Usage;
    const seconds = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[1], 0), 10);
    const fps = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10);
    const scale = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[3], 0), 10);
    if (fps == 0 or scale == 0) return error.Usage;

    const fb: i32 = @intCast(linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY }, 0));
    var v: [160]u8 align(4) = undefined;
    _ = linux.ioctl(fb, 0x4600, @intFromPtr(&v)); // FBIOGET_VSCREENINFO
    const width: u32 = std.mem.readInt(u32, v[0..4], .little);
    const height: u32 = std.mem.readInt(u32, v[4..8], .little);
    const yoffset: u32 = std.mem.readInt(u32, v[20..24], .little);
    const out_w = width / scale;
    const out_h = height / scale;

    const rc = linux.open(argv[4], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (core.os.failed(rc)) return error.CantWrite;
    const out: i32 = @intCast(rc);
    defer _ = linux.close(out);
    var head: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&head, "FBREC {d} {d}\n", .{ out_w, out_h });
    _ = linux.write(out, h.ptr, h.len);

    // The touch panel, read beside whoever has it: events carry their own time
    const touch_rc = linux.open("/dev/input/event1", .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    const touch: i32 = if (core.os.failed(touch_rc)) -1 else @intCast(touch_rc);
    var touches_path: [512]u8 = undefined;
    const tp = try std.fmt.bufPrintSentinel(&touches_path, "{s}.touches", .{std.mem.sliceTo(argv[4], 0)}, 0);
    const trc = linux.open(tp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    const touches_out: i32 = if (core.os.failed(trc)) -1 else @intCast(trc);
    defer if (touches_out >= 0) {
        _ = linux.close(touches_out);
    };
    // Event times are wall-clock; the frames use the monotonic clock. The offset
    // between the two, taken once, puts both on one clock.
    var wall: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &wall);
    const wall_us: i64 = @as(i64, wall.sec) * 1_000_000 + @divTrunc(@as(i64, wall.nsec), 1000);
    const wall_to_mono: i64 = @as(i64, @intCast(now_us())) - wall_us;

    const frame = try std.heap.page_allocator.alloc(u8, 8 + out_w * out_h);
    var row: [4096]u8 = undefined;
    const step_us: u64 = 1_000_000 / fps;
    const end = now_us() + @as(u64, seconds) * 1_000_000;
    var next = now_us();
    var frames: u32 = 0;
    while (now_us() < end) {
        const t = now_us();
        std.mem.writeInt(u64, frame[0..8], t, .little);
        for (0..out_h) |y| {
            const off: i64 = @as(i64, yoffset + @as(u32, @intCast(y)) * scale) * width;
            _ = linux.pread(fb, &row, width, off);
            const dst = frame[8 + y * out_w ..][0..out_w];
            for (dst, 0..) |*d, x| d.* = row[x * scale];
        }
        _ = linux.write(out, frame.ptr, frame.len);
        frames += 1;
        if (touch >= 0 and touches_out >= 0) log_touches(touch, touches_out, wall_to_mono);
        next += step_us;
        const now = now_us();
        if (next > now) core.os.sleep_ms((next - now) / 1000);
    }
    std.debug.print("fbrec: {d} frames of {d}x{d}\n", .{ frames, out_w, out_h });
}

const InputEvent = extern struct { sec: u32, usec: u32, kind: u16, code: u16, value: i32 };

/// Writes a line for each finger landing or lifting since last time.
fn log_touches(touch: i32, out: i32, wall_to_mono: i64) void {
    var events: [64]InputEvent = undefined;
    while (true) {
        const n = linux.read(touch, @ptrCast(&events), @sizeOf(@TypeOf(events)));
        if (core.os.failed(n) or n < @sizeOf(InputEvent)) return;
        for (events[0 .. n / @sizeOf(InputEvent)]) |e| {
            if (e.kind != 3 or e.code != 0x39) continue; // ABS_MT_TRACKING_ID
            const t = @as(i64, e.sec) * 1_000_000 + e.usec + wall_to_mono;
            var line: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{s} {d}\n", .{ if (e.value >= 0) "down" else "up", t }) catch continue;
            _ = linux.write(out, text.ptr, text.len);
        }
    }
}
