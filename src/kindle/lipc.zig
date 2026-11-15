//! Amazon's lipc services: light, warmth, wireless, Bluetooth, sync, settings and power
//! events. Every call goes through the lipc command line tools.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const process = @import("../sys/process.zig");
const quick_model = @import("../model/quick.zig");
const devices = @import("devices.zig");

const lipc_get: [*:0]const u8 = "/usr/bin/lipc-get-prop";

const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

/// Every lipc service is Amazon's, named under this.
const service_prefix = "com.lab126.";

/// The most commands `process.run_all` runs at once.
const commands_at_once_max = 16;

// Assertions: it parses lipc's answer, which is outside data.
pub fn parse_int(output: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, output, " \n"), 10) catch null;
}

/// Settings calls answer at once when lipc is healthy; when it isn't, give up fast.
const lipc_timeout_ms = 3000;

fn lipc_deadline() u64 {
    const now = os.now_us();
    const deadline = now + lipc_timeout_ms * 1000;
    assert(deadline > now);
    return deadline;
}

fn get(comptime service: [*:0]const u8, comptime prop: [*:0]const u8, deadline: u64) ?u32 {
    comptime assert(std.mem.startsWith(u8, std.mem.span(service), service_prefix));
    comptime assert(std.mem.span(prop).len > 0);
    const argv = [_:null]?[*:0]const u8{ lipc_get, service, prop };
    var buffer: [32]u8 = undefined;
    const length = process.run_until(&argv, &buffer, deadline) orelse return null;
    assert(length <= buffer.len);
    return parse_int(buffer[0..length]);
}

fn set(comptime service: [*:0]const u8, comptime prop: [*:0]const u8, value: u32) void {
    comptime assert(std.mem.startsWith(u8, std.mem.span(service), service_prefix));
    comptime assert(std.mem.span(prop).len > 0);
    // Room for any u32's ten digits and the closing zero, so formatting never fails
    var text: [16]u8 = undefined;
    comptime assert(text.len >= 10 + 1);
    const argument = std.fmt.bufPrintSentinel(&text, "{d}", .{value}, 0) catch return;
    assert(argument.len > 0);
    const argv = [_:null]?[*:0]const u8{ lipc_set, service, prop, argument };
    var buffer: [32]u8 = undefined;
    // A set answers nothing worth reading: whoever needs to know reads the value back
    _ = process.run_until(&argv, &buffer, lipc_deadline());
}

fn get_text(
    comptime service: [*:0]const u8,
    comptime prop: [*:0]const u8,
    buffer: []u8,
    deadline: u64,
) []const u8 {
    comptime assert(std.mem.startsWith(u8, std.mem.span(service), service_prefix));
    comptime assert(std.mem.span(prop).len > 0);
    assert(buffer.len > 0);
    const argv = [_:null]?[*:0]const u8{ lipc_get, "-s", service, prop };
    const length = process.run_until(&argv, buffer, deadline) orelse return "";
    assert(length <= buffer.len);
    return std.mem.trim(u8, buffer[0..length], " \n");
}

/// Maps wifid's "5/5" to the three arcs of the icon.
// Assertions: it reads wifid's answer, which is outside data; only its result is ours.
pub fn signal_bars(signal: []const u8) u32 {
    const slash = std.mem.indexOfScalar(u8, signal, '/') orelse return 0;
    const value = std.fmt.parseInt(u32, signal[0..slash], 10) catch return 0;
    const bars = @min((value + 1) / 2, 3);
    assert(bars <= 3);
    return bars;
}

/// Everything the panel and status bar show. All reads share one short deadline,
/// so a hung lipc costs one wait, not one per value. A value that can't be read keeps
/// what `previous` had, so the panel never acts on a made-up zero.
pub fn read(previous: quick_model.Quick) quick_model.Quick {
    // Every value at once: ten small programs side by side take about as long as one
    var argvs: [readings.len][*:null]const ?[*:0]const u8 = undefined;
    for (readings, &argvs) |reading, *argv| argv.* = reading.argv;
    var buffers: [readings.len][40]u8 = undefined;
    var outs: [readings.len][]u8 = undefined;
    for (&outs, &buffers) |*out, *buffer| out.* = buffer;
    // How much each printed, as `process.run_all` counts it
    var lengths: [readings.len]?u32 = undefined;
    process.run_all(&argvs, &outs, &lengths, lipc_deadline());

    // In the table's order. A value that couldn't be read keeps what `previous` had
    var quick = previous;
    for (readings, buffers, lengths) |reading, buffer, length| {
        if (length) |printed| assert(printed <= buffer.len);
        const text = std.mem.trim(u8, buffer[0 .. length orelse 0], " \n");
        if (text.len > 0) reading.apply(&quick, text);
    }
    // Wi-Fi's state is applied before its signal, so no bars show while it's off
    if (!quick.wifi_on) assert(quick.wifi_bars == 0);
    assert(quick.clock_len <= quick.clock.len);
    // Plugged in, whether or not it's charging: a computer's port can be too weak to
    // charge, and a full battery stops; the stock Kindle shows the bolt either way.
    // The usbState of powerd stays 1 after the cable is pulled, so on a Kindle the
    // charger's own file decides. The scenario tests' pretend Kindle has no such file:
    // there its usbState stands.
    if (process.fake == null) {
        if (devices.power()) |power| quick.plugged = power.plugged;
    }
    return quick;
}

/// One value the status bar and quick panel show: the command that reads it, what a
/// healthy Kindle answers (for the scenario tests' pretend one), and where it goes.
pub const Reading = struct {
    argv: [*:null]const ?[*:0]const u8,
    healthy: []const u8,
    apply: *const fn (quick: *quick_model.Quick, text: []const u8) void,

    /// "service prop", as the pretend Kindle names a property. Empty for `date`.
    pub fn key(r: Reading, buffer: []u8) []const u8 {
        assert(buffer.len > 0);
        const argv = r.argv;
        if (argv[0] != lipc_get) return "";
        const at: u8 = if (std.mem.eql(u8, std.mem.span(argv[1].?), "-s")) 2 else 1;
        const service = argv[at].?;
        assert(std.mem.startsWith(u8, std.mem.span(service), service_prefix));
        return std.fmt.bufPrint(buffer, "{s} {s}", .{ service, argv[at + 1].? }) catch "";
    }
};

const Apply = *const fn (*quick_model.Quick, []const u8) void;

/// Sets a number in the Quick from the value read.
fn number(comptime field: []const u8) Apply {
    comptime assert(@FieldType(quick_model.Quick, field) == u32);
    return struct {
        fn apply(quick: *quick_model.Quick, text: []const u8) void {
            assert(text.len > 0);
            if (parse_int(text)) |value| @field(quick, field) = value;
        }
    }.apply;
}

/// Which values of a number mean a switch is on.
const OnWhen = enum { one, zero, not_zero };

/// Sets a switch in the Quick from the number read: on when it's `on_when`.
fn flag(comptime field: []const u8, comptime on_when: OnWhen) Apply {
    comptime assert(@FieldType(quick_model.Quick, field) == bool);
    return struct {
        fn apply(quick: *quick_model.Quick, text: []const u8) void {
            assert(text.len > 0);
            const value = parse_int(text) orelse return;
            @field(quick, field) = switch (on_when) {
                .one => value == 1,
                .zero => value == 0,
                .not_zero => value != 0,
            };
        }
    }.apply;
}

fn apply_wifi_state(quick: *quick_model.Quick, text: []const u8) void {
    assert(text.len > 0);
    quick.wifi_on = std.mem.eql(u8, text, "CONNECTED");
    if (!quick.wifi_on) quick.wifi_bars = 0;
    assert(quick.wifi_bars <= 3);
}

fn apply_wifi_signal(quick: *quick_model.Quick, text: []const u8) void {
    assert(text.len > 0);
    quick.wifi_bars = if (quick.wifi_on) signal_bars(text) else 0;
    assert(quick.wifi_bars <= 3);
}

fn apply_clock(quick: *quick_model.Quick, text: []const u8) void {
    assert(text.len > 0);
    const length: u32 = @intCast(@min(text.len, quick.clock.len));
    assert(length <= quick.clock.len);
    @memcpy(quick.clock[0..length], text[0..length]);
    quick.clock_len = length;
}

/// Everything `read` asks, in the order it's applied (Wi-Fi's state before its signal).
pub const readings = [_]Reading{
    .{
        .argv = &.{ lipc_get, "-s", "com.lab126.wifid", "cmState" },
        .healthy = "CONNECTED",
        .apply = apply_wifi_state,
    },
    .{
        .argv = &.{ lipc_get, "-s", "com.lab126.wifid", "signalStrength" },
        .healthy = "5/5",
        .apply = apply_wifi_signal,
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.powerd", "flIntensity" },
        .healthy = "12",
        .apply = number("brightness"),
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.powerd", "currentAmberLevel" },
        .healthy = "0",
        .apply = number("warmth"),
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.powerd", "amberSchedEnable" },
        .healthy = "0",
        .apply = flag("schedule", .one),
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.cmd", "wirelessEnable" },
        .healthy = "1",
        .apply = flag("airplane", .zero),
    },
    // 0 off, 1 on, 2 connected
    .{
        .argv = &.{ lipc_get, bt_service, "BTstate" },
        .healthy = "0",
        .apply = flag("bluetooth", .not_zero),
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.powerd", "battLevel" },
        .healthy = "80",
        .apply = number("battery"),
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.powerd", "usbState" },
        .healthy = "0",
        .apply = flag("plugged", .not_zero),
    },
    .{
        .argv = &.{ "/bin/date", "+%H:%M - %d %b %Y" },
        .healthy = "",
        .apply = apply_clock,
    },
};

comptime {
    // All at once, as `read` asks them
    assert(readings.len <= commands_at_once_max);
    // Wi-Fi's signal is read as nothing while it's off, so its state comes first
    assert(readings[0].apply == &apply_wifi_state);
    assert(readings[1].apply == &apply_wifi_signal);
}

/// Tells powerd the reader is active, so it doesn't lock while they read. noface holds
/// the touchscreen, so powerd never sees the touches itself.
// Assertions: one lipc call with constants, which `set` checks.
pub fn still_active() void {
    set("com.lab126.powerd", "touchScreenSaverTimeout", 1);
}

/// Whether the Kindle is showing its lock screen. Null when powerd can't be asked.
pub fn in_screen_saver() ?bool {
    var buffer: [32]u8 = undefined;
    const state = get_text("com.lab126.powerd", "state", &buffer, lipc_deadline());
    assert(state.len <= buffer.len); // Read into `buffer`
    if (state.len == 0) return null;
    return std.mem.eql(u8, state, "screenSaver");
}

/// Starts a child that prints the named events of one lipc publisher, one per line.
/// Its `out` pipe is non-blocking.
fn watch_events(comptime publisher: [*:0]const u8, comptime events: [*:0]const u8) ?process.Child {
    comptime assert(std.mem.startsWith(u8, std.mem.span(publisher), service_prefix));
    comptime assert(std.mem.span(events).len > 0);
    const argv = [_:null]?[*:0]const u8{ "/usr/bin/lipc-wait-event", "-m", publisher, events };
    const child = process.spawn(&argv) orelse return null;
    assert(child.pid > 0);
    assert(child.out >= 0);
    const flags = linux.fcntl(child.out, linux.F.GETFL, 0);
    // A pipe of our own is always ours to set: the flag can't be refused
    _ = linux.fcntl(child.out, linux.F.SETFL, flags | 0o4000); // O_NONBLOCK
    return child;
}

/// Locking and waking, from powerd.
pub fn watch_power_events() ?process.Child {
    // The charger's coming and going too, so the status bar's bolt follows at once.
    // The launcher finds this watcher by the start of its arguments, which stays the
    // same (src/kindle/stock_ui.zig)
    const events = "goingToScreenSaver,outOfScreenSaver,charging,notCharging";
    const child = watch_events("com.lab126.powerd", events);
    if (child) |c| assert(c.pid > 0); // Its whole group is killed on the way out
    return child;
}

/// A computer setting up the USB connection, from the volume manager.
pub fn watch_usb_events() ?process.Child {
    const child = watch_events("com.lab126.volumd", "usbConfigured");
    if (child) |c| assert(c.pid > 0); // Its whole group is killed on the way out
    return child;
}

/// True while USB carries a network (as Jobman's SSH does) rather than file transfer.
// Assertions: one lipc read, whose answer is outside data.
pub fn usb_for_network() bool {
    return (get("com.lab126.volumd", "useUsbForNetwork", lipc_deadline()) orelse 0) == 1;
}

/// Same as the Sync button in the stock panel.
pub fn sync_now() void {
    const service = "com.lab126.quickactions";
    comptime assert(std.mem.startsWith(u8, service, service_prefix));
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", service, "syncAndCheck", "1" };
    var out: [32]u8 = undefined;
    // The sync runs on its own; what the command prints says nothing about how it went
    _ = process.run(&argv, &out);
}

pub fn open_settings() void {
    const service = "com.lab126.appmgrd";
    comptime assert(std.mem.startsWith(u8, service, service_prefix));
    const app = "app://com.lab126.booklet.settings";
    const argv = [_:null]?[*:0]const u8{ lipc_set, service, "start", app };
    var buffer: [32]u8 = undefined;
    // The settings open on their own, or don't: there's nothing noface could do instead
    _ = process.run(&argv, &buffer);
}

// Assertions: one lipc call; the level may have started as lipc's own answer, outside data.
pub fn set_brightness(level: u32) void {
    set("com.lab126.powerd", "flIntensity", level);
}

/// With the schedule on, its own level has to move too or it would snap back.
// Assertions: one lipc call; the level may have started as lipc's own answer, outside data.
pub fn set_warmth(level: u32, scheduled: bool) void {
    set("com.lab126.powerd", "currentAmberLevel", level);
    if (scheduled) set("com.lab126.powerd", "schedAmberLevel", level);
}

// Assertions: one lipc call; a switch has no wrong value to assert.
pub fn set_schedule(on: bool) void {
    set("com.lab126.powerd", "amberSchedEnable", if (on) 1 else 0);
}

// Assertions: one lipc call; a switch has no wrong value to assert.
pub fn set_airplane(on: bool) void {
    set("com.lab126.cmd", "wirelessEnable", if (on) 0 else 1);
}

/// Whether Wi-Fi has a connection. Null when wifid can't be asked.
pub fn wifi_connected() ?bool {
    var buffer: [32]u8 = undefined;
    const state = get_text("com.lab126.wifid", "cmState", &buffer, lipc_deadline());
    assert(state.len <= buffer.len); // Read into `buffer`
    if (state.len == 0) return null;
    return std.mem.eql(u8, state, "CONNECTED");
}

// Assertions: one lipc read, whose answer is outside data.
pub fn airplane_on() ?bool {
    const value = get("com.lab126.cmd", "wirelessEnable", lipc_deadline()) orelse return null;
    return value == 0;
}

const bt_service: [*:0]const u8 = "com.lab126.btfd";

/// Null when btfd can't be asked. Its state is 0 off, 1 on, 2 connected.
// Assertions: one lipc read, whose answer is outside data.
pub fn bluetooth_on() ?bool {
    const value = get(bt_service, "BTstate", lipc_deadline()) orelse return null;
    return value != 0;
}

/// The Bluetooth daemon takes "<on>:<mode>". Mode 2 is the user's own switch, which
/// it remembers across reboots; mode 1 belongs to VoiceView, and other modes are refused.
// Assertions: one lipc call; a switch has no wrong value to assert.
pub fn set_bluetooth(on: bool) void {
    const value: [*:0]const u8 = if (on) "1:2" else "0:2";
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", bt_service, "BTenable", value };
    var buffer: [32]u8 = undefined;
    // Whether it took is read back with `bluetooth_on`, as the panel does
    _ = process.run_until(&argv, &buffer, lipc_deadline());
}

test "tool output parses" {
    try std.testing.expectEqual(@as(u32, 21), parse_int("21\n").?);
    try std.testing.expect(parse_int("failed\n") == null);
}

test "signal maps to icon arcs" {
    try std.testing.expectEqual(@as(u32, 3), signal_bars("5/5"));
    try std.testing.expectEqual(@as(u32, 2), signal_bars("3/5"));
    try std.testing.expectEqual(@as(u32, 1), signal_bars("1/5"));
    try std.testing.expectEqual(@as(u32, 0), signal_bars("none"));
}
