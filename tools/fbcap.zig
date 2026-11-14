//! Writes a horizontal band of the framebuffer to stdout as a PGM image.
//! Usage: fbcap <top> <height>
const std = @import("std");
const core = @import("core");
const linux = std.os.linux;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;
    const top = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[1], 0), 10);
    const height = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10);
    const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY }, 0);
    if (core.os.failed(rc)) return error.NoFramebuffer;
    const fd: i32 = @intCast(rc);
    var v: [160]u8 align(4) = undefined;
    _ = linux.ioctl(fd, 0x4600, @intFromPtr(&v));
    const width: u32 = std.mem.readInt(u32, v[0..4], .little);
    const yoffset: u32 = std.mem.readInt(u32, v[20..24], .little);
    var head: [32]u8 = undefined;
    const h = try std.fmt.bufPrint(&head, "P5\n{d} {d}\n255\n", .{ width, height });
    _ = linux.write(1, h.ptr, h.len);
    var row: [2048]u8 = undefined;
    if (width > row.len) return error.ScreenTooWide;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const off: i64 = @as(i64, yoffset + top + y) * width;
        _ = linux.pread(fd, &row, width, off);
        _ = linux.write(1, &row, width);
    }
}
