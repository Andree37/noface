//! `noface doctor`: what noface finds on this Kindle, and whether it can run here.
//! Someone with a Kindle noface hasn't been tried on runs it and pastes the report
//! into an issue; noface also writes it to its log when it refuses to start.
const std = @import("std");
const assert = std.debug.assert;
const devices = @import("devices.zig");
const lipc = @import("lipc.zig");
const state = @import("../sys/state.zig");
const linux = @import("../sys/calls.zig");

/// The start of the name of every display driver noface can drive: MediaTek's hwtcon.
const driver_prefix = "hwtcon";

comptime {
    assert(driver_prefix.len > 0);
}

/// The display drivers noface can drive: MediaTek's hwtcon, in every Kindle since 2021.
// Assertions: it reads the display driver's name, which is outside data.
pub fn supported_driver(name: []const u8) bool {
    const supported = std.mem.startsWith(u8, name, driver_prefix);
    if (supported) assert(name.len >= driver_prefix.len);
    return supported;
}

fn read_trim(path: [*:0]const u8, buffer: []u8) []const u8 {
    assert(buffer.len > 0);
    const text = std.mem.trim(u8, state.read_small(path, buffer), " \n\x00");
    assert(text.len <= buffer.len);
    return text;
}

/// One line of the report, written to `fd`. A line too long for `buffer` is left out
/// rather than cut short.
fn report_line(fd: i32, buffer: []u8, comptime format: []const u8, arguments: anytype) void {
    assert(fd >= 0);
    assert(buffer.len > 0);
    const text = std.fmt.bufPrint(buffer, format ++ "\n", arguments) catch return;
    // A report that can't be written has nowhere to say so either
    _ = linux.write(fd, text.ptr, text.len);
}

/// The line for one input device: its event number and the name it gives, or that
/// none was found.
fn report_input(fd: i32, line_buffer: []u8, comptime label: []const u8, number: ?u8) void {
    // Padded to line up with the longest label, "power button:", and a space
    comptime assert(label.len <= "power button:".len);
    const padding: [("power button: ".len - label.len)]u8 = @splat(' ');
    const found = number orelse {
        report_line(fd, line_buffer, label ++ padding ++ "not found", .{});
        return;
    };
    var path_buffer: [64]u8 = undefined;
    var name_buffer: [96]u8 = undefined;
    const format = "/sys/class/input/event{d}/device/name";
    // Room for any u8's three digits, so the path is never empty
    comptime assert(path_buffer.len > format.len + 3);
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{found}, 0) catch "";
    const name = read_trim(path, &name_buffer);
    report_line(fd, line_buffer, label ++ padding ++ "/dev/input/event{d} ({s})", .{
        found,
        name,
    });
}

/// Writes the report to `fd`. Returns whether noface should be able to run here.
pub fn report(fd: i32) bool {
    assert(fd >= 0);
    var line_buffer: [256]u8 = undefined;
    var usid_buffer: [128]u8 = undefined;
    var value_buffer: [128]u8 = undefined;
    report_line(fd, &line_buffer, "noface doctor", .{});
    const usid = read_trim("/proc/usid", &usid_buffer);
    const model = if (usid.len >= 6) usid[0..6] else "unknown";
    report_line(fd, &line_buffer, "model code:   {s}", .{model});
    const firmware = read_trim("/etc/prettyversion.txt", &value_buffer);
    report_line(fd, &line_buffer, "firmware:     {s}", .{firmware});

    // The screen, from the framebuffer
    var driver_buffer: [64]u8 = undefined;
    const driver = read_trim("/sys/class/graphics/fb0/name", &driver_buffer);
    var geometry: [2][32]u8 = undefined;
    const screen_format = "screen:       {s} (virtual size), {s} bits per pixel, rotation {s}";
    report_line(fd, &line_buffer, screen_format, .{
        read_trim("/sys/class/graphics/fb0/virtual_size", &geometry[0]),
        read_trim("/sys/class/graphics/fb0/bits_per_pixel", &geometry[1]),
        read_trim("/sys/class/graphics/fb0/rotate", &value_buffer),
    });
    const driver_ok = supported_driver(driver);
    report_line(fd, &line_buffer, "display:      {s} ({s})", .{
        if (driver.len > 0) driver else "unknown",
        if (driver_ok) "supported" else "not supported yet",
    });

    const found = devices.find_inputs();
    report_input(fd, &line_buffer, "touch:", found.touch);
    report_input(fd, &line_buffer, "power button:", found.power);

    if (devices.power()) |power| {
        report_line(fd, &line_buffer, "battery:      {d}%, {s}", .{
            power.level,
            if (power.plugged) "plugged in" else "not plugged in",
        });
    } else {
        report_line(fd, &line_buffer, "battery:      not found", .{});
    }

    const services = if (lipc.airplane_on() != null) "answer" else "don't answer";
    report_line(fd, &line_buffer, "system:       Kindle services {s} (lipc)", .{services});
    const bluetooth = if (lipc.bluetooth_on() != null) "yes" else "no";
    report_line(fd, &line_buffer, "bluetooth:    {s}", .{bluetooth});

    const ok = driver_ok and found.touch != null;
    report_line(fd, &line_buffer, "", .{});
    if (ok) {
        report_line(fd, &line_buffer, "noface should run on this Kindle.", .{});
    } else {
        report_line(fd, &line_buffer, "noface can't run on this Kindle yet. Please paste " ++
            "this report into an issue at", .{});
        report_line(fd, &line_buffer, "https://github.com/Andree37/noface/issues so " ++
            "support can be added.", .{});
    }
    return ok;
}

test "only MediaTek's display driver is supported" {
    try std.testing.expect(supported_driver("hwtcon_v2"));
    try std.testing.expect(!supported_driver("mxc_epdc_fb"));
    try std.testing.expect(!supported_driver(""));
}
