//! Writes a horizontal band of the framebuffer to stdout as a PGM image.
//! Usage: fbcap <top> <height>
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const linux = std.os.linux;

const fbioget_vscreeninfo: u32 = 0x4600;
/// The kernel's `fb_var_screeninfo`, read whole; only the first fields matter here.
const screen_info_size = 160;
const xres_offset = 0;
const yoffset_offset = 20;
const row_size_max = 2048;
const stdout_fd = 1;

comptime {
    assert(xres_offset + 4 <= screen_info_size);
    assert(yoffset_offset + 4 <= screen_info_size);
    // A row of the panel noface is drawn for, 1272 pixels across, fits.
    assert(row_size_max >= 1272);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;
    const top = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[1], 0), 10);
    const height = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10);
    const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY }, 0);
    if (core.os.failed(rc)) return error.NoFramebuffer;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    var info: [screen_info_size]u8 align(4) = undefined;
    // Unchecked, as before: a failure shows as a nonsense size in the image's header.
    _ = linux.ioctl(fd, fbioget_vscreeninfo, @intFromPtr(&info));
    const width: u32 = std.mem.readInt(u32, info[xres_offset..][0..4], .little);
    const yoffset: u32 = std.mem.readInt(u32, info[yoffset_offset..][0..4], .little);
    var head: [32]u8 = undefined;
    const header = try std.fmt.bufPrint(&head, "P5\n{d} {d}\n255\n", .{ width, height });
    _ = linux.write(stdout_fd, header.ptr, header.len);
    var row: [row_size_max]u8 = undefined;
    if (width > row.len) return error.ScreenTooWide;
    for (0..height) |y| {
        const row_top: u32 = yoffset + top + @as(u32, @intCast(y));
        copy_row(fd, &row, row_top, width);
    }
}

/// Reads one row of `width` pixels, `row_top` rows down the framebuffer, to stdout.
fn copy_row(fd: i32, row: *[row_size_max]u8, row_top: u32, width: u32) void {
    assert(fd >= 0);
    assert(width <= row.len);
    const offset: i64 = @as(i64, row_top) * width;
    _ = linux.pread(fd, row, width, offset);
    _ = linux.write(stdout_fd, row, width);
}
