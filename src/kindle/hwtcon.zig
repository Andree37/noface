//! Direct access to the Kindle Paperwhite 12th gen e-ink driver (MediaTek hwtcon_v2).
//! Struct layout and ioctl numbers are the driver's userspace interface, from the
//! hwtcon_v2 headers in the Linux kernel source Amazon publishes for this Kindle.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("../sys/file.zig");
const check = @import("../base/check.zig");
const linux = @import("../sys/calls.zig");

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
    /// A page of text with gray on it, or that had some (a highlight's band): no flash,
    /// where the text waveform blinks a gray area black as it changes
    shaded_page,
    screen, // A whole new screen in all its grays, like the library or a cover
    flash, // The same, with the flash that clears any ghost of what was there
    quick, // Following a finger: fast, and only black and white settle cleanly
    clock, // Small text such as the clock, without a flash
    clean, // Settling an area after a drag, its smooth edges back

    /// How this panel does a refresh.
    pub const How = struct { waveform: Waveform, mode: UpdateMode };

    pub fn on_this_panel(r: Refresh) How {
        const how: How = switch (r) {
            .page, .clean => .{ .waveform = .reagl, .mode = .partial },
            .shaded_page => .{ .waveform = .gl16, .mode = .partial },
            .screen => .{ .waveform = .gc16, .mode = .partial },
            .flash => .{ .waveform = .gc16, .mode = .full },
            // DU is a little slower than A2 but leaves no ghost of where things were
            .quick => .{ .waveform = .du, .mode = .partial },
            .clock => .{ .waveform = .gl16, .mode = .partial },
        };
        // Only a flash is asked to flash: every other refresh must not
        assert((how.mode == .full) == (r == .flash));
        // Following a finger needs the fastest waveform there is that leaves no ghost
        if (r == .quick) assert(how.waveform == .du);
        return how;
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

const temp_use_ambient = 0x1000;
const send_update: u32 = 0x4060462E; // _IOW('F', 0x2E, 96 bytes)
const ioctl_wait_complete: u32 = 0xC008462F; // _IOWR('F', 0x2F, 8 bytes)
const fbioget_vscreeninfo: u32 = 0x4600;
const fbioget_fscreeninfo: u32 = 0x4602;
/// The first marker sent: any number the driver isn't using itself.
const marker_first = 0x7000;

/// The one screen noface's interface is laid out for: the Paperwhite 12th gen's panel,
/// in portrait. Every screen's controls sit at fixed places on it (ui/style.zig's
/// `screen_width` and `screen_height`), so on another size they'd fall off the edge or
/// out of reach: noface refuses to start there, and `noface doctor` says why.
pub const width_px = 1272;
pub const height_px = 1696;

/// Whether noface's interface is laid out for a screen this size.
pub fn supported_size(width: u32, height: u32) bool {
    return width == width_px and height == height_px;
}

/// A screen's visible size, as its driver reports it.
pub const Size = struct { width: u32, height: u32 };

/// The visible size of the screen behind /dev/fb0, or null when it can't be read.
// Assertions: it only reads the framebuffer's size, outside data, for the doctor.
pub fn read_size() ?Size {
    const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Only read from: a close that fails loses nothing
    var variable: [160]u8 align(4) = undefined;
    if (failed(linux.ioctl(fd, fbioget_vscreeninfo, @intFromPtr(&variable)))) return null;
    return .{
        .width = std.mem.readInt(u32, variable[0..4], .little),
        .height = std.mem.readInt(u32, variable[4..8], .little),
    };
}

/// The size an ioctl request number carries, in bits 16 to 29.
fn ioctl_size(request: u32) u32 {
    return (request >> 16) & 0x3fff;
}

comptime {
    // The driver's structs, to the byte, as its ioctl numbers say
    assert(@sizeOf(Rect) == 16);
    assert(@sizeOf(UpdateData) == 96);
    assert(ioctl_size(send_update) == @sizeOf(UpdateData));
    assert(ioctl_size(ioctl_wait_complete) == @sizeOf(MarkerData));
}

pub const Screen = struct {
    fd: ?i32, // The display's device; null for a screen in memory only
    map: []align(4096) u8,
    pixels: []u8, // The visible page only
    width: u32,
    height: u32,
    stride: u32,
    next_marker: u32 = marker_first,
    updates: u32 = 0, // Updates sent: a scenario test checks what was redrawn

    /// A screen in memory only, for scenario tests: updates are counted, not shown.
    pub fn fake(alloc: std.mem.Allocator, width: u32, height: u32) !Screen {
        assert(width > 0);
        assert(height > 0);
        // As a real screen of that size: one the interface isn't laid out for is refused
        if (!supported_size(width, height)) return error.UnsupportedScreenSize;
        const map = try alloc.alignedAlloc(u8, .fromByteUnits(4096), width * height);
        @memset(map, 0xff);
        const screen: Screen = .{
            .fd = null,
            .map = map,
            .pixels = map,
            .width = width,
            .height = height,
            .stride = width,
        };
        assert(screen.pixels.len == screen.height * screen.stride);
        return screen;
    }

    pub fn open() !Screen {
        // Only MediaTek's driver understands the updates sent below
        var name_buffer: [64]u8 = undefined;
        const name_read = file.read_small("/sys/class/graphics/fb0/name", &name_buffer);
        const name = std.mem.trim(u8, name_read, " \n");
        if (!std.mem.startsWith(u8, name, "hwtcon")) return error.UnsupportedDisplay;
        const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (failed(rc)) return error.OpenFailed;
        const fd: i32 = @intCast(rc);
        assert(fd >= 0);

        var variable: [160]u8 align(4) = undefined;
        var fixed: [68]u8 align(4) = undefined;
        const variable_rc = linux.ioctl(fd, fbioget_vscreeninfo, @intFromPtr(&variable));
        if (failed(variable_rc)) return error.VScreenInfo;
        const fixed_rc = linux.ioctl(fd, fbioget_fscreeninfo, @intFromPtr(&fixed));
        if (failed(fixed_rc)) return error.FScreenInfo;

        const width = std.mem.readInt(u32, variable[0..4], .little);
        const height = std.mem.readInt(u32, variable[4..8], .little);
        const yoffset = std.mem.readInt(u32, variable[20..24], .little);
        const bpp = std.mem.readInt(u32, variable[24..28], .little);
        const smem_len = std.mem.readInt(u32, fixed[20..24], .little);
        const stride = std.mem.readInt(u32, fixed[44..48], .little);
        if (bpp != 8) return error.UnexpectedDepth;
        if (!supported_size(width, height)) return error.UnsupportedScreenSize;
        // The visible page, as the driver says where it is, lies in the memory it maps
        if (stride < width) return error.UnexpectedStride;
        if ((@as(u64, yoffset) + height) * stride > smem_len) return error.ScreenOutsideMemory;

        const address = linux.mmap(
            null,
            smem_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        if (failed(address)) return error.MmapFailed;
        const map = @as([*]align(4096) u8, @ptrFromInt(address))[0..smem_len];

        // The same arithmetic in u32 as the Kindle's 32-bit usize, which slicing uses
        const start = yoffset * stride;
        const screen: Screen = .{
            .fd = fd,
            .map = map,
            .pixels = map[start..][0 .. height * stride],
            .width = width,
            .height = height,
            .stride = stride,
        };
        assert(screen.pixels.len == screen.height * screen.stride);
        return screen;
    }

    /// Queue a whole-screen refresh of the kind asked for, and return its marker.
    pub fn show(s: *Screen, r: Refresh) !u32 {
        return s.show_region(0, 0, s.width, s.height, r);
    }

    /// Queue a refresh of part of the screen, and return its marker.
    pub fn show_region(
        s: *Screen,
        left: u32,
        top: u32,
        width: u32,
        height: u32,
        r: Refresh,
    ) !u32 {
        const how = r.on_this_panel();
        return s.update_region(left, top, width, height, how.waveform, how.mode);
    }

    /// Queue a whole-screen update with a waveform named, and return its marker. For
    /// tools that measure the waveforms themselves; screens ask with `show`.
    pub fn update(s: *Screen, waveform: Waveform, mode: UpdateMode) !u32 {
        return s.update_region(0, 0, s.width, s.height, waveform, mode);
    }

    /// Queue an update for part of the screen and return its marker.
    pub fn update_region(
        s: *Screen,
        left: u32,
        top: u32,
        width: u32,
        height: u32,
        waveform: Waveform,
        mode: UpdateMode,
    ) !u32 {
        const region = "screen update {d},{d} {d}x{d}";
        const where = .{ left, top, width, height };
        check.thatf(width > 0, region ++ " has a width", where);
        check.thatf(height > 0, region ++ " has a height", where);
        check.thatf(left + width <= s.width, region ++ " inside the screen's width", where);
        check.thatf(top + height <= s.height, region ++ " inside the screen's height", where);
        const marker = s.next_marker;
        s.next_marker += 1;
        assert(marker >= marker_first);
        var data = UpdateData{
            .region = .{ .top = top, .left = left, .width = width, .height = height },
            .waveform = @backingInt(waveform),
            .update_mode = @backingInt(mode),
            .marker = marker,
        };
        s.updates += 1;
        const fd = s.fd orelse return marker; // In memory: nothing to send
        if (failed(linux.ioctl(fd, send_update, @intFromPtr(&data)))) return error.SendUpdate;
        return marker;
    }

    pub fn wait_complete(s: *Screen, marker: u32) !void {
        // Only a marker of an update already sent can complete
        assert(marker >= marker_first);
        assert(marker < s.next_marker);
        const fd = s.fd orelse return; // In memory: nothing to wait for
        var data = MarkerData{ .marker = marker };
        const rc = linux.ioctl(fd, ioctl_wait_complete, @intFromPtr(&data));
        if (failed(rc)) return error.WaitComplete;
    }
};

const failed = @import("../sys/os.zig").failed;
