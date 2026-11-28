//! Amazon's lipc services: light, warmth, wireless, Bluetooth, sync and power
//! events. Every call goes through the lipc command line tools.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../text/line.zig").of;
const unicode = @import("../text/unicode.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const process = @import("../sys/process.zig");
const archive = @import("archive.zig");
const quick_model = @import("../model/quick.zig");
const devices = @import("devices.zig");

const lipc_get: [*:0]const u8 = "/usr/bin/lipc-get-prop";
/// Reads a property that's a table of fields, given a table (an empty one) on its input.
const lipc_hash = "/usr/bin/lipc-hash-prop";

const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

/// Every lipc service is Amazon's, named under this.
const service_prefix = "com.lab126.";

/// The most commands `process.run_all` runs at once.
const commands_at_once_max = 16;

pub fn parse_int(output: []const u8) ?u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, output, " \n"), 10) catch null;
}

/// Settings calls answer at once when lipc is healthy; when it isn't, give up fast.
const lipc_timeout_ms = 3000;
/// As long as a call waits for its answer, in µs: what a setting is given to take.
pub const answer_us: u64 = lipc_timeout_ms * std.time.us_per_ms;

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
    var text: [value_bytes_max]u8 = undefined;
    const argv = set_command(&text, service, prop, value);
    var buffer: [32]u8 = undefined;
    // Ignored: a set answers nothing worth reading: whoever needs to know reads the value back
    _ = process.run_until(&argv, &buffer, lipc_deadline());
}

/// Room for any u32's ten digits and the closing zero, so formatting never fails.
const value_bytes_max = 16;

/// The command that sets `prop` of `service` to `value`, its value written in `text`.
fn set_command(
    text: *[value_bytes_max]u8,
    comptime service: [*:0]const u8,
    comptime prop: [*:0]const u8,
    value: u32,
) [4:null]?[*:0]const u8 {
    comptime assert(std.mem.startsWith(u8, std.mem.span(service), service_prefix));
    comptime assert(std.mem.span(prop).len > 0);
    comptime assert(value_bytes_max >= 10 + 1);
    // Ten digits at most, with room after for the closing zero
    const digits = std.fmt.printInt(text[0 .. text.len - 1], value, 10, .lower, .{});
    assert(digits > 0);
    assert(digits < text.len);
    text[digits] = 0;
    const argument: [:0]const u8 = text[0..digits :0];
    return .{ lipc_set, service, prop, argument };
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

/// The name of the Wi-Fi network the Kindle is connected to, into `out`: empty when it
/// isn't connected or wifid doesn't say. Never logged: it's the reader's own.
pub fn network_name(out: []u8) []const u8 {
    assert(out.len > 0);
    // The table is answered only when asked with one: an empty table, on the input
    const command = "echo '{}' | " ++ lipc_hash ++ " com.lab126.wifid currentEssid";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    var answer: [network_answer_bytes_max]u8 = undefined;
    const length = process.run_until(&argv, &answer, lipc_deadline()) orelse return out[0..0];
    assert(length <= answer.len);
    return essid_of(answer[0..length], out);
}

/// The most of wifid's table read: a network's fields, each a short line.
const network_answer_bytes_max = 512;

/// The network's name in wifid's table (`\tessid = "Home"`, with `\tconnected =
/// "yes"`), into `out`, cut at a character's end where it doesn't fit; empty when it
/// isn't connected.
pub fn essid_of(answer: []const u8, out: []u8) []const u8 {
    assert(out.len > 0);
    var name: []const u8 = "";
    var connected = false;
    var lines = std.mem.splitScalar(u8, answer, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "connected = ")) {
            connected = std.mem.eql(u8, trimmed["connected = ".len..], "\"yes\"");
        }
        if (!std.mem.startsWith(u8, trimmed, "essid = \"")) continue;
        const quoted = trimmed["essid = ".len..];
        // Between its quotes: the last one on the line ends it
        const end = std.mem.lastIndexOfScalar(u8, quoted, '"') orelse continue;
        if (end > 0) name = quoted[1..end];
    }
    if (!connected) return out[0..0];
    // A name not in UTF-8 (an old router's Latin-1) can't be drawn: none, so "On" shows
    if (!unicode.is_utf8(name)) return out[0..0];
    // Never inside a character
    const length = unicode.start_at_or_before(name, @intCast(@min(name.len, out.len)));
    @memcpy(out[0..length], name[0..length]);
    assert(length <= out.len);
    return out[0..length];
}

test "the network's name is read from wifid's table while it's connected" {
    const answer = "Hash Index: 0\n\tnetid = 0\n\tessid = \"Casa Nova\"\n" ++
        "\tbssid = \"aa:bb:cc:dd:ee:ff\"\n\tconnected = \"yes\"\n";
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Casa Nova", essid_of(answer, &out));
    // Not connected, or no name: none
    const off = "\tessid = \"Casa\"\n\tconnected = \"no\"\n";
    try std.testing.expectEqualStrings("", essid_of(off, &out));
    try std.testing.expectEqualStrings("", essid_of("\tconnected = \"yes\"\n", &out));
    try std.testing.expectEqualStrings("", essid_of("", &out));
    // Cut to fit, never inside a character
    var short: [5]u8 = undefined;
    const accented = "\tessid = \"Caf\u{e9}s\"\n\tconnected = \"yes\"\n";
    try std.testing.expectEqualStrings("Caf\u{e9}", essid_of(accented, &short));
    var shorter: [4]u8 = undefined;
    try std.testing.expectEqualStrings("Caf", essid_of(accented, &shorter));
    // Not UTF-8: no name, so the tile says On
    const latin1 = "\tessid = \"Caf\xe9\"\n\tconnected = \"yes\"\n";
    try std.testing.expectEqualStrings("", essid_of(latin1, &out));
}

/// The most the Wi-Fi daemon says the signal is.
const signal_max = 5;

/// Maps wifid's "5/5" to the arcs of the icon.
pub fn signal_bars(signal: []const u8) u32 {
    comptime assert(quick_model.Quick.wifi_bars_max * 2 - 1 == signal_max); // Two steps an arc
    const slash = std.mem.indexOfScalar(u8, signal, '/') orelse return 0;
    const value = std.fmt.parseInt(u32, signal[0..slash], 10) catch return 0;
    // Out of 5, rounded up to the arcs. wifid's number is outside data: clamped first,
    // so rounding it up can't overflow
    const bars = @divFloor(@min(value, signal_max) + 1, 2);
    assert(bars <= quick_model.Quick.wifi_bars_max);
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
    assert(quick.wifi_bars <= 3);
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
/// Room for a property's key: its service's name and its own.
pub const Key = [key_bytes_max]u8;
const key_bytes_max = 96;

pub const Reading = struct {
    argv: [*:null]const ?[*:0]const u8,
    healthy: []const u8,
    apply: *const fn (quick: *quick_model.Quick, text: []const u8) void,

    /// "service prop", as the pretend Kindle names a property. Empty for `date`.
    pub fn key(r: Reading, buffer: *Key) []const u8 {
        const argv = r.argv;
        if (argv[0] != lipc_get) return "";
        const at: u8 = if (std.mem.eql(u8, std.mem.span(argv[1].?), "-s")) 2 else 1;
        const service = argv[at].?;
        assert(std.mem.startsWith(u8, std.mem.span(service), service_prefix));
        return line_of(buffer, "{s} {s}", .{ service, argv[at + 1].? });
    }
};

const Apply = *const fn (*quick_model.Quick, []const u8) void;

/// Sets a number in the Quick from the value read, at most `max`: what the Kindle says
/// is outside data, which the screens draw and step from as a level they know.
fn number(comptime field: []const u8, comptime max: u32) Apply {
    comptime assert(@FieldType(quick_model.Quick, field) == u32);
    return struct {
        fn apply(quick: *quick_model.Quick, text: []const u8) void {
            assert(text.len > 0);
            if (parse_int(text)) |value| @field(quick, field) = @min(value, max);
            assert(@field(quick, field) <= max);
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
}

fn apply_wifi_signal(quick: *quick_model.Quick, text: []const u8) void {
    assert(text.len > 0);
    quick.wifi_bars = signal_bars(text);
    assert(quick.wifi_bars <= 3);
}

fn apply_clock(quick: *quick_model.Quick, text: []const u8) void {
    assert(text.len > 0);
    const length: u32 = @intCast(@min(text.len, quick.clock.len));
    assert(length <= quick.clock.len);
    @memcpy(quick.clock[0..length], text[0..length]);
    quick.clock_len = length;
}

/// Everything `read` asks, each applied on its own: Wi-Fi's signal is kept whether or
/// not it's connected, and drawn only while it is (`Quick.wifi_shown`).
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
        .apply = number("brightness", quick_model.max_brightness),
    },
    .{
        .argv = &.{ lipc_get, "com.lab126.powerd", "currentAmberLevel" },
        .healthy = "0",
        .apply = number("warmth", quick_model.max_warmth),
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
        .apply = number("battery", quick_model.battery_full),
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
}

/// Tells powerd the reader is active, so it doesn't lock while they read: noface holds
/// the touchscreen, so powerd never sees the touches itself. Asked from the input loop,
/// so never waited for: its child, which the caller reaps.
pub fn tell_still_active() ?process.Child {
    var text: [value_bytes_max]u8 = undefined;
    const argv = set_command(&text, "com.lab126.powerd", "touchScreenSaverTimeout", 1);
    return process.start(&argv);
}

/// What powerd's `state` says of the Kindle.
pub const PowerState = enum {
    awake,
    /// Locked: its lock screen up, or the Kindle going to sleep, or asleep, under it.
    asleep,
};

/// The state powerd names in `text`. Null for one not listed (a state at boot, or one
/// passing), and for no answer: unknown, which no caller takes as locked.
pub fn power_state_of(text: []const u8) ?PowerState {
    if (std.mem.eql(u8, text, "active")) return .awake;
    const asleep = [_][]const u8{ "screenSaver", "readyToSuspend", "suspended" };
    for (asleep) |name| {
        if (std.mem.eql(u8, text, name)) return .asleep;
    }
    return null;
}

/// Whether the Kindle is awake or locked, as powerd says now. Null when it can't be
/// asked, or says something else.
pub fn power_state() ?PowerState {
    var buffer: [32]u8 = undefined;
    const state = get_text("com.lab126.powerd", "state", &buffer, lipc_deadline());
    assert(state.len <= buffer.len); // Read into `buffer`
    return power_state_of(state);
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
    // Read without waiting by the loop that polls it: one that would block is stopped
    if (!linux.set_nonblocking(child.out)) {
        process.stop(child.pid);
        _ = linux.close(child.out); // Ignored: our end of a pipe now unused
        return null;
    }
    return child;
}

/// What noface watches: a publisher, and its events, comma-separated as
/// lipc-wait-event takes them. The launcher finds these watchers by them too
/// (src/kindle/stock_ui.zig `is_noface_watcher`).
pub const Watched = struct { publisher: [:0]const u8, events: [:0]const u8 };
/// Locking and waking, and the charger's coming and going too, so the status bar's
/// bolt follows at once.
pub const power_watched: Watched = .{
    .publisher = "com.lab126.powerd",
    .events = "goingToScreenSaver,outOfScreenSaver,charging,notCharging",
};
/// A computer setting up the USB connection.
pub const usb_watched: Watched = .{ .publisher = "com.lab126.volumd", .events = "usbConfigured" };

/// Locking and waking, from powerd.
pub fn watch_power_events() ?process.Child {
    const child = watch_events(power_watched.publisher, power_watched.events);
    if (child) |c| assert(c.pid > 0); // Its whole group is killed on the way out
    return child;
}

/// A computer setting up the USB connection, from the volume manager.
pub fn watch_usb_events() ?process.Child {
    const child = watch_events(usb_watched.publisher, usb_watched.events);
    if (child) |c| assert(c.pid > 0); // Its whole group is killed on the way out
    return child;
}

/// True while USB carries a network (as Jobman's SSH does) rather than file transfer.
pub fn usb_for_network() bool {
    return (get("com.lab126.volumd", "useUsbForNetwork", lipc_deadline()) orelse 0) == 1;
}

/// Same as the Sync button in the stock panel, with the service that lists new books
/// started again first if it had stopped (kindle/archive.zig).
pub fn sync_now() void {
    archive.ensure_running();
    const service = "com.lab126.quickactions";
    comptime assert(std.mem.startsWith(u8, service, service_prefix));
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", service, "syncAndCheck", "1" };
    var out: [32]u8 = undefined;
    // Given up on as fast as every other setting, so a hung lipc can't hold the panel.
    // Ignored: the sync runs on its own; what the command prints says nothing of it
    _ = process.run_until(&argv, &out, lipc_deadline());
}

/// Whether a sync asked for is still under way, as the Kindle's own Sync button shows
/// it: null when it can't be asked.
pub fn syncing() ?bool {
    var buffer: [8]u8 = undefined;
    const state = get_text("com.lab126.quickactions", "getSyncState", &buffer, lipc_deadline());
    assert(state.len <= buffer.len); // Read into `buffer`
    if (std.mem.eql(u8, state, "0")) return false;
    if (std.mem.eql(u8, state, "1")) return true;
    return null;
}

pub fn set_brightness(level: u32) void {
    set("com.lab126.powerd", "flIntensity", level);
}

/// With the schedule on, its own level has to move too or it would snap back.
pub fn set_warmth(level: u32, scheduled: bool) void {
    set("com.lab126.powerd", "currentAmberLevel", level);
    if (scheduled) set("com.lab126.powerd", "schedAmberLevel", level);
}

pub fn set_schedule(on: bool) void {
    set("com.lab126.powerd", "amberSchedEnable", if (on) 1 else 0);
}

/// Keeps the Kindle awake, its screensaver and sleep held off, while running mode moves
/// on by itself; off again lets it sleep when idle, as usual.
pub fn hold_awake(on: bool) void {
    set("com.lab126.powerd", "preventScreenSaver", @intFromBool(on));
}

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

pub fn airplane_on() ?bool {
    const value = get("com.lab126.cmd", "wirelessEnable", lipc_deadline()) orelse return null;
    return value == 0;
}

const bt_service: [*:0]const u8 = "com.lab126.btfd";

/// Null when btfd can't be asked. Its state is 0 off, 1 on, 2 connected.
pub fn bluetooth_on() ?bool {
    const value = get(bt_service, "BTstate", lipc_deadline()) orelse return null;
    return value != 0;
}

/// The Bluetooth daemon takes "<on>:<mode>". Mode 2 is the user's own switch, which
/// it remembers across reboots; mode 1 belongs to VoiceView, and other modes are refused.
pub fn set_bluetooth(on: bool) void {
    const value: [*:0]const u8 = if (on) "1:2" else "0:2";
    const argv = [_:null]?[*:0]const u8{ lipc_set, "-s", bt_service, "BTenable", value };
    var buffer: [32]u8 = undefined;
    // Ignored: whether it took is read back with `bluetooth_on`, as the panel does
    _ = process.run_until(&argv, &buffer, lipc_deadline());
}

test "tool output parses" {
    try std.testing.expectEqual(@as(u32, 21), parse_int("21\n").?);
    try std.testing.expect(parse_int("failed\n") == null);
}

test "a light or battery level past its end is read as its end" {
    var quick: quick_model.Quick = .{};
    number("brightness", quick_model.max_brightness)(&quick, "25\n");
    try std.testing.expectEqual(@as(u32, quick_model.max_brightness), quick.brightness);
    number("warmth", quick_model.max_warmth)(&quick, "7\n");
    try std.testing.expectEqual(@as(u32, 7), quick.warmth);
    number("battery", quick_model.battery_full)(&quick, "101\n");
    try std.testing.expectEqual(@as(u32, quick_model.battery_full), quick.battery);
}

test "powerd's states read as awake, locked, or unknown, which is never locked" {
    try std.testing.expectEqual(PowerState.awake, power_state_of("active").?);
    try std.testing.expectEqual(PowerState.asleep, power_state_of("screenSaver").?);
    try std.testing.expectEqual(PowerState.asleep, power_state_of("readyToSuspend").?);
    try std.testing.expectEqual(PowerState.asleep, power_state_of("suspended").?);
    try std.testing.expectEqual(null, power_state_of(""));
    try std.testing.expectEqual(null, power_state_of("activeX"));
}

test "signal maps to icon arcs" {
    try std.testing.expectEqual(@as(u32, 3), signal_bars("5/5"));
    try std.testing.expectEqual(@as(u32, 2), signal_bars("3/5"));
    try std.testing.expectEqual(@as(u32, 1), signal_bars("1/5"));
    try std.testing.expectEqual(@as(u32, 0), signal_bars("none"));
    try std.testing.expectEqual(@as(u32, 0), signal_bars("0/5"));
    try std.testing.expectEqual(@as(u32, 3), signal_bars("4294967295/5")); // Not an overflow
}
