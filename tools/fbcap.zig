//! Writes a horizontal band of the screen to stdout as a PGM image, read as tools/e2e.zig
//! reads the screen: at the driver's stride, from where the shown screen starts.
//! Usage: fbcap <top> <height>
const std = @import("std");
const e2e = @import("e2e.zig");

const stdout_fd = 1;

// Assertions: it checks only outside data (its arguments, the driver's sizes); the band
// it hands on is asserted by `Screen.write_pgm`.
pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;
    const top = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[1], 0), 10);
    const height = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10);
    const screen = try e2e.Screen.open();
    // A band past the screen's foot would read the framebuffer's other screen, or nothing
    if (height > screen.height) return error.OutsideScreen;
    if (top > screen.height - height) return error.OutsideScreen;
    if (!screen.write_pgm(stdout_fd, top, height)) return error.CantWrite;
}
