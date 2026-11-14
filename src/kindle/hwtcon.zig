//! Direct access to the Kindle Paperwhite 12th gen e-ink driver (MediaTek hwtcon_v2).
//! Struct layout and ioctl numbers are the driver's userspace interface, from the
//! hwtcon_v2 headers in the Linux kernel source Amazon publishes for this Kindle.
const std = @import("std");
const check = @import("../base/check.zig");
const linux = @import("../sys/calls.zig");
const state = @import("../sys/state.zig");

pub const Waveform = enum(u32) {
    du = 1,
    gc16 = 2,
    gl16 = 3,
    reagl = 4,
    a2 = 6,
    du4 = 7,
};

pub const UpdateMode = enum(u32) { partial = 0, full = 1 };

/// What a screen asks the panel for. Which waveform does it is the panel's business:
/// this table is MediaTek's, on the Paperwhite 12; another panel maps them its way.
pub const Refresh = enum {
    page, // A new page of text: sharp, quick, no flash
    screen, // A whole new screen in all its grays, like the library or a cover
    flash, // The same, with the flash that clears any ghost of what was there
    quick, // Following a finger: fast, and only black and white settle cleanly
    clock, // Small text such as the clock, without a flash
    clean, // Settling an area after a drag, its smooth edges back

    pub fn on_this_panel(r: Refresh) struct { waveform: Waveform, mode: UpdateMode } {
        return switch (r) {
            .page, .clean => .{ .waveform = .reagl, .mode = .partial },
            .screen => .{ .waveform = .gc16, .mode = .partial },
            .flash => .{ .waveform = .gc16, .mode = .full },
            // DU is a little slower than A2 but leaves no ghost of where things were
            .quick => .{ .waveform = .du, .mode = .partial },
            .clock => .{ .waveform = .gl16, .mode = .partial },
        };
    }
};

const Rect = extern struct { top: u32, left: u32, width: u32, height: u32 };

const AltBuffer = extern struct {
    phys_addr: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    region: Rect = .{ .top = 0, .left = 0, .width = 0, .height = 0 },
};

const UpdateData = extern struct {
    region: Rect,
    waveform: u32,
    update_mode: u32,
    marker: u32,
    temp: i32 = temp_use_ambient,
    flags: u32 = 0,
    dither_mode: i32 = 0,
    quant_bit: i32 = 0,
    alt: AltBuffer = .{},
    swipe_direction: u32 = 0,
    swipe_steps: u32 = 0,
    hist_bw_waveform: u32 = 0,
    hist_gray_waveform: u32 = 0,
    ts_pxp: u32 = 0,
    ts_epdc: u32 = 0,
};

const MarkerData = extern struct { marker: u32, collision_test: u32 = 0 };

comptime {
    std.debug.assert(@sizeOf(UpdateData) == 96);
}

const temp_use_ambient = 0x1000;
const send_update: u32 = 0x4060462E; // _IOW('F', 0x2E, 96 bytes)
const ioctl_wait_complete: u32 = 0xC008462F; // _IOWR('F', 0x2F, 8 bytes)
const fbioget_vscreeninfo: u32 = 0x4600;
const fbioget_fscreeninfo: u32 = 0x4602;

pub const Screen = struct {
    fd: i32,
    map: []align(4096) u8,
    pixels: []u8, // visible page only
    width: u32,
    height: u32,
    stride: u32,
    next_marker: u32 = 0x7000,
    updates: u32 = 0, // Updates sent: a scenario test checks what was redrawn

    /// A screen in memory only, for scenario tests: updates are counted, not shown.
    pub fn fake(alloc: std.mem.Allocator, width: u32, height: u32) !Screen {
        const map = try alloc.alignedAlloc(u8, .fromByteUnits(4096), @as(usize, width) * height);
        @memset(map, 0xff);
        return .{ .fd = -1, .map = map, .pixels = map, .width = width, .height = height, .stride = width };
    }

    pub fn open() !Screen {
        // Only MediaTek's driver understands the updates sent below
        var name_buf: [64]u8 = undefined;
        const name = std.mem.trim(u8, state.read_small("/sys/class/graphics/fb0/name", &name_buf), " \n");
        if (!std.mem.startsWith(u8, name, "hwtcon")) return error.UnsupportedDisplay;
        const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (failed(rc)) return error.OpenFailed;
        const fd: i32 = @intCast(rc);

        var v: [160]u8 align(4) = undefined;
        var f: [68]u8 align(4) = undefined;
        if (failed(linux.ioctl(fd, fbioget_vscreeninfo, @intFromPtr(&v)))) return error.VScreenInfo;
        if (failed(linux.ioctl(fd, fbioget_fscreeninfo, @intFromPtr(&f)))) return error.FScreenInfo;

        const width = std.mem.readInt(u32, v[0..4], .little);
        const height = std.mem.readInt(u32, v[4..8], .little);
        const yoffset = std.mem.readInt(u32, v[20..24], .little);
        const bpp = std.mem.readInt(u32, v[24..28], .little);
        const smem_len = std.mem.readInt(u32, f[20..24], .little);
        const stride = std.mem.readInt(u32, f[44..48], .little);
        if (bpp != 8) return error.UnexpectedDepth;

        const addr = linux.mmap(null, smem_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (failed(addr)) return error.MmapFailed;
        const map = @as([*]align(4096) u8, @ptrFromInt(addr))[0..smem_len];

        const start = @as(usize, yoffset) * stride;
        return .{
            .fd = fd,
            .map = map,
            .pixels = map[start..][0 .. @as(usize, height) * stride],
            .width = width,
            .height = height,
            .stride = stride,
        };
    }

    /// Queue a whole-screen refresh of the kind asked for, and return its marker.
    pub fn show(s: *Screen, r: Refresh) !u32 {
        return s.show_region(0, 0, s.width, s.height, r);
    }

    /// Queue a refresh of part of the screen, and return its marker.
    pub fn show_region(s: *Screen, left: u32, top: u32, width: u32, height: u32, r: Refresh) !u32 {
        const how = r.on_this_panel();
        return s.update_region(left, top, width, height, how.waveform, how.mode);
    }

    /// Queue a whole-screen update with a waveform named, and return its marker. For
    /// tools that measure the waveforms themselves; screens ask with `show`.
    pub fn update(s: *Screen, waveform: Waveform, mode: UpdateMode) !u32 {
        return s.update_region(0, 0, s.width, s.height, waveform, mode);
    }

    /// Queue an update for part of the screen and return its marker.
    pub fn update_region(s: *Screen, left: u32, top: u32, width: u32, height: u32, waveform: Waveform, mode: UpdateMode) !u32 {
        check.thatf(left + width <= s.width and top + height <= s.height and width > 0 and height > 0, "screen update {d},{d} {d}x{d} inside the screen", .{ left, top, width, height });
        const marker = s.next_marker;
        s.next_marker += 1;
        var data = UpdateData{
            .region = .{ .top = top, .left = left, .width = width, .height = height },
            .waveform = @backingInt(waveform),
            .update_mode = @backingInt(mode),
            .marker = marker,
        };
        s.updates += 1;
        if (s.fd < 0) return marker; // In memory: nothing to send
        if (failed(linux.ioctl(s.fd, send_update, @intFromPtr(&data)))) return error.SendUpdate;
        return marker;
    }

    pub fn wait_complete(s: *Screen, marker: u32) !void {
        if (s.fd < 0) return;
        var data = MarkerData{ .marker = marker };
        const rc = linux.ioctl(s.fd, ioctl_wait_complete, @intFromPtr(&data));
        if (failed(rc)) return error.WaitComplete;
    }
};

const failed = @import("../sys/os.zig").failed;
