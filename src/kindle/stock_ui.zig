//! The Kindle's own screens, paused while noface runs and always put back after.
//!
//! noface draws its own lock screen and owns the touch panel, so while it runs the
//! stock screensaver is unloaded, the status bar and dialogs (pillow) are switched
//! off, and the window manager (awesome) is stopped. `restore` undoes each, and turns
//! the radio back on if noface had turned it off: the launcher calls it however noface
//! ends, and its panic handler calls it if the launcher itself crashes.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const process = @import("../sys/process.zig");
const service = @import("../sys/service.zig");
const wifi_saver = @import("wifi_saver.zig");

const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

/// The watchers noface starts, of powerd and the volume manager, by their command lines
/// with the zero bytes between arguments read as spaces. lipc-wait-event splits its
/// event list in place, so the comma between events reads as a space too. Stock has
/// listeners of its own that must keep running.
const watcher_signatures = [_][]const u8{
    "-m com.lab126.powerd goingToScreenSaver outOfScreenSaver",
    "-m com.lab126.volumd usbConfigured",
};

/// Whether the stock screens are paused, so a crash knows to put them back.
pub var paused = false;
/// Whether `restore` has begun, so a crash inside it doesn't start it again.
var restoring = false;

/// Pauses the stock screens, so noface can take the screen and the touch panel.
pub fn pause() void {
    assert(!paused);
    assert(!restoring);
    paused = true;
    set("com.lab126.powerd", "preventScreenSaver", "0");
    set("com.lab126.blanket", "unload", "screensaver");
    set("com.lab126.pillow", "disableEnablePillow", "disable");
    _ = service.signal_named("awesome", .STOP);
}

/// Puts the stock screens back, ends any watcher noface left behind, and turns the
/// radio back on if noface turned it off. Runs once, however it's reached.
pub fn restore() void {
    if (restoring) return;
    restoring = true;
    _ = service.signal_named("awesome", .CONT);
    set("com.lab126.pillow", "disableEnablePillow", "enable");
    set("com.lab126.blanket", "load", "screensaver");
    // Only noface's own, in case noface died before ending them
    const stopped = service.each_named("lipc-wait-event", @as(u8, 0), stop_watcher);
    if (stopped > 0) std.debug.print("restore: ended {d} watcher(s)\n", .{stopped});
    wifi_saver.restore(); // In case noface couldn't turn it back on itself
    paused = false;
    assert(restoring);
    assert(!paused);
}

fn stop_watcher(_: u8, pid: i32, cmdline: []const u8) void {
    assert(pid > 0);
    assert(restoring);
    if (!is_noface_watcher(cmdline)) return;
    _ = linux.kill(pid, .TERM); // Ended since it was found: nothing to stop
}

/// Whether a lipc-wait-event command line (arguments split by zero bytes) is one of
/// noface's watchers.
pub fn is_noface_watcher(cmdline: []const u8) bool {
    var spaced: [1024]u8 = undefined;
    const length = @min(cmdline.len, spaced.len);
    for (cmdline[0..length], spaced[0..length]) |c, *s| s.* = if (c == 0) ' ' else c;
    assert(length <= spaced.len);
    for (watcher_signatures) |signature| {
        assert(signature.len < spaced.len);
        if (std.mem.indexOf(u8, spaced[0..length], signature) != null) return true;
    }
    return false;
}

/// `lipc-set-prop service property value`. What it prints goes to the log: the
/// Kindle carries on either way, as it did when a script did this.
fn set(
    comptime service_name: [*:0]const u8,
    comptime property: [*:0]const u8,
    value: [*:0]const u8,
) void {
    comptime assert(std.mem.startsWith(u8, std.mem.span(service_name), "com.lab126."));
    assert(value[0] != 0);
    const argv = [_:null]?[*:0]const u8{ lipc_set, service_name, property, value };
    var out: [256]u8 = undefined;
    const printed = process.run(&argv, &out) orelse {
        const format = "lipc-set-prop {s} {s} {s}: no answer\n";
        std.debug.print(format, .{ service_name, property, value });
        return;
    };
    assert(printed <= out.len);
    if (printed > 0) std.debug.print("{s}", .{out[0..printed]});
}

test "noface's own watchers are told from the Kindle's" {
    const power = "/usr/bin/lipc-wait-event\x00-m\x00com.lab126.powerd\x00goingToScreenSaver" ++
        "\x00outOfScreenSaver\x00charging\x00notCharging\x00";
    try std.testing.expect(is_noface_watcher(power));
    const usb = "/usr/bin/lipc-wait-event\x00-m\x00com.lab126.volumd\x00usbConfigured\x00";
    try std.testing.expect(is_noface_watcher(usb));
    const stock = "lipc-wait-event\x00-s\x000\x00com.lab126.powerd\x00goingToScreenSaver\x00";
    try std.testing.expect(!is_noface_watcher(stock));
}
