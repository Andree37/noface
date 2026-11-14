//! `noface doctor`: what noface finds on this Kindle, and whether it can run here.
//! Someone with a Kindle noface hasn't been tried on runs it and pastes the report
//! into an issue; noface also writes it to its log when it refuses to start.
const std = @import("std");
const devices = @import("devices.zig");
const lipc = @import("lipc.zig");
const state = @import("../sys/state.zig");
const linux = @import("../sys/calls.zig");

/// The display drivers noface can drive: MediaTek's hwtcon, in every Kindle since 2021.
pub fn supported_driver(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "hwtcon");
}

fn read_trim(path: [*:0]const u8, buf: []u8) []const u8 {
    return std.mem.trim(u8, state.read_small(path, buf), " \n\x00");
}

/// Writes the report to `fd`. Returns whether noface should be able to run here.
pub fn report(fd: i32) bool {
    var line_buf: [256]u8 = undefined;
    const out = struct {
        fn line(f: i32, buf: []u8, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(buf, fmt ++ "\n", args) catch return;
            _ = linux.write(f, s.ptr, s.len);
        }
    }.line;

    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    out(fd, &line_buf, "noface doctor", .{});
    const usid = read_trim("/proc/usid", &a);
    out(fd, &line_buf, "model code:   {s}", .{if (usid.len >= 6) usid[0..6] else "unknown"});
    out(fd, &line_buf, "firmware:     {s}", .{read_trim("/etc/prettyversion.txt", &b)});

    // The screen, from the framebuffer
    var driver_buf: [64]u8 = undefined;
    const driver = read_trim("/sys/class/graphics/fb0/name", &driver_buf);
    var geometry: [2][32]u8 = undefined;
    out(fd, &line_buf, "screen:       {s} (virtual size), {s} bits per pixel, rotation {s}", .{
        read_trim("/sys/class/graphics/fb0/virtual_size", &geometry[0]),
        read_trim("/sys/class/graphics/fb0/bits_per_pixel", &geometry[1]),
        read_trim("/sys/class/graphics/fb0/rotate", &b),
    });
    const driver_ok = supported_driver(driver);
    out(fd, &line_buf, "display:      {s} ({s})", .{ if (driver.len > 0) driver else "unknown", if (driver_ok) "supported" else "not supported yet" });

    const found = devices.find_inputs();
    var name_buf: [96]u8 = undefined;
    if (found.touch) |n| {
        const path = std.fmt.bufPrintSentinel(&a, "/sys/class/input/event{d}/device/name", .{n}, 0) catch "";
        out(fd, &line_buf, "touch:        /dev/input/event{d} ({s})", .{ n, read_trim(path, &name_buf) });
    } else out(fd, &line_buf, "touch:        not found", .{});
    if (found.power) |n| {
        const path = std.fmt.bufPrintSentinel(&a, "/sys/class/input/event{d}/device/name", .{n}, 0) catch "";
        out(fd, &line_buf, "power button: /dev/input/event{d} ({s})", .{ n, read_trim(path, &name_buf) });
    } else out(fd, &line_buf, "power button: not found", .{});

    if (devices.power()) |p| {
        out(fd, &line_buf, "battery:      {d}%, {s}", .{ p.level, if (p.plugged) "plugged in" else "not plugged in" });
    } else out(fd, &line_buf, "battery:      not found", .{});

    const airplane = lipc.airplane_on();
    out(fd, &line_buf, "system:       {s}", .{if (airplane != null) "Kindle services answer (lipc)" else "Kindle services don't answer (lipc)"});
    out(fd, &line_buf, "bluetooth:    {s}", .{if (lipc.bluetooth_on() != null) "yes" else "no"});

    const ok = driver_ok and found.touch != null;
    out(fd, &line_buf, "", .{});
    if (ok) {
        out(fd, &line_buf, "noface should run on this Kindle.", .{});
    } else {
        out(fd, &line_buf, "noface can't run on this Kindle yet. Please paste this report into an issue at", .{});
        out(fd, &line_buf, "https://github.com/Andree37/noface/issues so support can be added.", .{});
    }
    return ok;
}

test "only MediaTek's display driver is supported" {
    try std.testing.expect(supported_driver("hwtcon_v2"));
    try std.testing.expect(!supported_driver("mxc_epdc_fb"));
    try std.testing.expect(!supported_driver(""));
}
