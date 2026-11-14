//! Amazon's lipc services: light, warmth, wireless, Bluetooth, sync, settings and power events.
//! Every call goes through the lipc command line tools.
const std = @import("std");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const process = @import("../sys/process.zig");
const quick_model = @import("../model/quick.zig");
const devices = @import("devices.zig");

const lipc_get: [*:0]const u8 = "/usr/bin/lipc-get-prop";

const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

pub fn parseInt(output: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, output, " \n"), 10) catch null;
}

/// Settings calls answer at once when lipc is healthy; when it isn't, give up fast.
const lipc_timeout_ms = 3000;

fn lipcDeadline() u64 {
    return os.nowUs() + lipc_timeout_ms * 1000;
}

fn get(service: [*:0]const u8, prop: [*:0]const u8, deadline: u64) ?u32 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, service, prop };
    var buf: [32]u8 = undefined;
    const n = process.runUntil(&argv, &buf, deadline) orelse return null;
    return parseInt(buf[0..n]);
}

fn set(service: [*:0]const u8, prop: [*:0]const u8, value: u32) void {
    var text: [16]u8 = undefined;
    const arg = std.fmt.bufPrintSentinel(&text, "{d}", .{value}, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ lipc_set, service, prop, arg };
    var buf: [32]u8 = undefined;
    _ = process.runUntil(&argv, &buf, lipcDeadline());
}

fn getText(service: [*:0]const u8, prop: [*:0]const u8, buf: []u8, deadline: u64) []const u8 {
    const argv = [_:null]?[*:0]const u8{ lipc_get, "-s", service, prop };
    const n = process.runUntil(&argv, buf, deadline) orelse return "";
    return std.mem.trim(u8, buf[0..n], " \n");
}

/// Maps wifid's "5/5" to the three arcs of the icon.
pub fn signalBars(signal: []const u8) u32 {
    const value = std.fmt.parseInt(u32, signal[0 .. std.mem.indexOfScalar(u8, signal, '/') orelse return 0], 10) catch return 0;
    return @min((value + 1) / 2, 3);
}

/// Everything the panel and status bar show. All reads share one short deadline,
/// so a hung lipc costs one wait, not one per value. A value that can't be read keeps
/// what `previous` had, so the panel never acts on a made-up zero.
pub fn read(previous: quick_model.Quick) quick_model.Quick {
    // Every value at once: nine small programs side by side take about as long as one
    const argvs = [_][*:null]const ?[*:0]const u8{
        &.{ lipc_get, "-s", "com.lab126.wifid", "cmState" },
        &.{ lipc_get, "-s", "com.lab126.wifid", "signalStrength" },
        &.{ lipc_get, "com.lab126.powerd", "flIntensity" },
        &.{ lipc_get, "com.lab126.powerd", "currentAmberLevel" },
        &.{ lipc_get, "com.lab126.powerd", "amberSchedEnable" },
        &.{ lipc_get, "com.lab126.cmd", "wirelessEnable" },
        &.{ lipc_get, bt_service, "BTstate" },
        &.{ lipc_get, "com.lab126.powerd", "battLevel" },
        &.{ "/bin/date", "+%H:%M - %d %b %Y" },
        &.{ lipc_get, "com.lab126.powerd", "usbState" },
    };
    var bufs: [argvs.len][40]u8 = undefined;
    var outs: [argvs.len][]u8 = undefined;
    for (&outs, &bufs) |*o, *b| o.* = b;
    var lens: [argvs.len]?usize = undefined;
    process.runAll(&argvs, &outs, &lens, lipcDeadline());
    const Out = struct {
        bufs: *const [argvs.len][40]u8,
        lens: *const [argvs.len]?usize,
        fn text(o: @This(), i: usize) []const u8 {
            return std.mem.trim(u8, o.bufs[i][0 .. o.lens[i] orelse 0], " \n");
        }
        fn int(o: @This(), i: usize) ?u32 {
            return parseInt(o.text(i));
        }
    };
    const out = Out{ .bufs = &bufs, .lens = &lens };

    // A value that couldn't be read keeps what `previous` had
    var q = previous;
    if (out.text(0).len > 0) {
        q.wifi_on = std.mem.eql(u8, out.text(0), "CONNECTED");
        q.wifi_bars = if (q.wifi_on) signalBars(out.text(1)) else 0;
    }
    if (out.int(2)) |v| q.brightness = v;
    if (out.int(3)) |v| q.warmth = v;
    if (out.int(4)) |v| q.schedule = v == 1;
    if (out.int(5)) |v| q.airplane = v == 0;
    if (out.int(6)) |v| q.bluetooth = v != 0; // 0 off, 1 on, 2 connected
    if (out.int(7)) |v| q.battery = v;
    // Plugged in, whether or not it's charging: a computer's port can be too weak to
    // charge, and a full battery stops; the stock Kindle shows the bolt either way
    // powerd's usbState stays 1 after the cable is pulled; the charger's own file says
    // whether one is there. The scenario tests' pretend Kindle answers usbState instead
    if (process.fake == null) {
        if (devices.power()) |p| q.plugged = p.plugged;
    } else if (out.int(9)) |v| q.plugged = v != 0;
    const clock = out.text(8);
    if (clock.len > 0) {
        @memcpy(q.clock[0..clock.len], clock);
        q.clock_len = clock.len;
    }
    return q;
}

/// Whether the Kindle is showing its lock screen. Null when powerd can't be asked.
/// Tells powerd the reader is active, so it doesn't lock while they read. noface holds
/// the touchscreen, so powerd never sees the touches itself.
pub fn stillActive() void {
    set("com.lab126.powerd", "touchScreenSaverTimeout", 1);
}

pub fn inScreenSaver() ?bool {
    var buf: [32]u8 = undefined;
    const state = getText("com.lab126.powerd", "state", &buf, lipcDeadline());
    if (state.len == 0) return null;
    return std.mem.eql(u8, state, "screenSaver");
}

/// Starts a child that prints the named events of one lipc publisher, one per line.
/// Its `out` pipe is non-blocking.
fn watchEvents(publisher: [*:0]const u8, events: [*:0]const u8) ?process.Child {
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/lipc-wait-event", "-m", publisher, events };
    const child = process.spawn(&argv) orelse return null;
    const flags = linux.fcntl(child.out, linux.F.GETFL, 0);
    _ = linux.fcntl(child.out, linux.F.SETFL, flags | 0o4000); // O_NONBLOCK
    return child;
}

/// Locking and waking, from powerd.
pub fn watchPowerEvents() ?process.Child {
    // The charger's coming and going too, so the status bar's bolt follows at once.
    // noface.sh finds this watcher by the start of its arguments, which stays the same
    return watchEvents("com.lab126.powerd", "goingToScreenSaver,outOfScreenSaver,charging,notCharging");
}

/// A computer setting up the USB connection, from the volume manager.
pub fn watchUsbEvents() ?process.Child {
    return watchEvents("com.lab126.volumd", "usbConfigured");
}

/// True while USB carries a network (as Jobman's SSH does) rather than file transfer.
pub fn usbForNetwork() bool {
    return (get("com.lab126.volumd", "useUsbForNetwork", lipcDeadline()) orelse 0) == 1;
}

/// Same as the Sync button in the stock panel.
pub fn syncNow() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", "com.lab126.quickactions", "syncAndCheck", "1" };
    var out: [32]u8 = undefined;
    _ = process.run(&argv, &out);
}

pub fn openSettings() void {
    const argv = [_:null]?[*:0]const u8{ lipc_set, "com.lab126.appmgrd", "start", "app://com.lab126.booklet.settings" };
    var buf: [32]u8 = undefined;
    _ = process.run(&argv, &buf);
}

pub fn setBrightness(level: u32) void {
    set("com.lab126.powerd", "flIntensity", level);
}

/// With the schedule on, its own level has to move too or it would snap back.
pub fn setWarmth(level: u32, scheduled: bool) void {
    set("com.lab126.powerd", "currentAmberLevel", level);
    if (scheduled) set("com.lab126.powerd", "schedAmberLevel", level);
}

pub fn setSchedule(on: bool) void {
    set("com.lab126.powerd", "amberSchedEnable", if (on) 1 else 0);
}

pub fn setAirplane(on: bool) void {
    set("com.lab126.cmd", "wirelessEnable", if (on) 0 else 1);
}

/// Whether Wi-Fi has a connection. Null when wifid can't be asked.
pub fn wifiConnected() ?bool {
    var buf: [32]u8 = undefined;
    const state = getText("com.lab126.wifid", "cmState", &buf, lipcDeadline());
    if (state.len == 0) return null;
    return std.mem.eql(u8, state, "CONNECTED");
}

pub fn airplaneOn() ?bool {
    const v = get("com.lab126.cmd", "wirelessEnable", lipcDeadline()) orelse return null;
    return v == 0;
}

const bt_service: [*:0]const u8 = "com.lab126.btfd";

/// Null when btfd can't be asked. Its state is 0 off, 1 on, 2 connected.
pub fn bluetoothOn() ?bool {
    const v = get(bt_service, "BTstate", lipcDeadline()) orelse return null;
    return v != 0;
}

/// btfd takes "<on>:<mode>". Mode 2 is the user's own switch, which btfd remembers
/// across reboots; mode 1 belongs to VoiceView, and other modes are refused.
pub fn setBluetooth(on: bool) void {
    const value: [*:0]const u8 = if (on) "1:2" else "0:2";
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", bt_service, "BTenable", value };
    var buf: [32]u8 = undefined;
    _ = process.runUntil(&argv, &buf, lipcDeadline());
}

test "tool output parses" {
    try std.testing.expectEqual(@as(u32, 21), parseInt("21\n").?);
    try std.testing.expect(parseInt("failed\n") == null);
}

test "signal maps to icon arcs" {
    try std.testing.expectEqual(@as(u32, 3), signalBars("5/5"));
    try std.testing.expectEqual(@as(u32, 2), signalBars("3/5"));
    try std.testing.expectEqual(@as(u32, 1), signalBars("1/5"));
    try std.testing.expectEqual(@as(u32, 0), signalBars("none"));
}
