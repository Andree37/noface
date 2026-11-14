//! What noface hears besides touches, and owes others while it waits: powerd's lock,
//! wake and charger news, a computer on USB, the power key, the heartbeat for the
//! watchdog in device/noface.sh, and a word to powerd now and then. These are
//! `Input`'s methods (input.zig names each one); the state they keep is Input's.
const std = @import("std");
const input = @import("../input.zig");
const evdev = @import("evdev.zig");
const paths = @import("../paths.zig");
const lipc = @import("../lipc.zig");
const touch_zones = @import("../touch.zig");
const state = @import("../../sys/state.zig");
const linux = @import("../../sys/calls.zig");
const os = @import("../../sys/os.zig");
const Input = input.Input;
const Action = input.Action;
const InputEvent = evdev.InputEvent;
const failed = os.failed;
const nowUs = os.nowUs;
const ev_key = evdev.ev_key;
const key_power = evdev.key_power;
const ev = @import("gestures.zig").ev;

const heartbeat_every_us = 30 * 1000 * 1000;
const heartbeat_path = paths.heartbeat; // In RAM: device/noface.sh's watchdog reads it
pub const watcher_retry_ms = 5000;
/// Tell powerd about activity at most once a minute, and only just after a touch:
/// later the Kindle may already be locking, and powerd refuses the call then.
const activity_every_us = 60 * 1000 * 1000;
const activity_fresh_us = 5 * 1000 * 1000;

/// Whether powerd's or USB's watcher has something to say, without waiting.
pub fn newsWaiting(in: *Input) bool {
    var fds = [_]linux.pollfd{
        .{ .fd = in.power_events, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = in.usb_events, .events = linux.POLL.IN, .revents = 0 },
    };
    const n = linux.poll(&fds, fds.len, 0);
    return !failed(n) and n > 0;
}

/// Tells the watchdog in device/noface.sh that noface is alive, now.
pub fn beat(in: *Input) void {
    in.heartbeat_us = nowUs();
    var stamp: [24]u8 = undefined;
    state.writeSmall(heartbeat_path, std.fmt.bufPrint(&stamp, "{d}\n", .{os.unixTime()}) catch "0\n");
}

/// Waking up: the monotonic clock stood still while the Kindle slept, so the last
/// beat may be hours old by the wall clock the watchdog uses. Beat before it looks.
pub fn unlocked(in: *Input) Action {
    beat(in);
    return .unlock;
}

/// Starts listening for lock and unlock from powerd.
pub fn startUsbWatcher(in: *Input) void {
    const child = lipc.watchUsbEvents() orelse return;
    in.usb_events = child.out;
    in.usb_watcher_pid = child.pid;
}

pub fn startWatcher(in: *Input) void {
    const child = lipc.watchPowerEvents() orelse {
        in.power_events = -1;
        in.watcher_pid = 0;
        return;
    };
    in.power_events = child.out;
    in.watcher_pid = child.pid;
}

/// What noface owes others while it waits: a heartbeat for the watchdog in
/// device/noface.sh, and, as touches are grabbed and powerd can't see them, a word
/// to powerd now and then so it doesn't lock the Kindle ten minutes into a book.
pub fn keepAlive(in: *Input) void {
    if (nowUs() > in.heartbeat_us + heartbeat_every_us) beat(in);
    if (shouldTellPowerd(in.locked, nowUs(), in.last_input, in.told_powerd_us)) {
        in.told_powerd_us = in.last_input;
        lipc.stillActive();
    }
}

/// powerd acts on the power key itself: it's read only so presses don't pile up,
/// except while locked with no watcher, when a press is the only way to wake.
pub fn fromPowerKey(in: *Input) ?Action {
    var drained: [16]InputEvent = undefined;
    const got = linux.read(in.power, @ptrCast(&drained), @sizeOf(@TypeOf(drained)));
    if (failed(got) or !in.locked or in.power_events >= 0) return null;
    return if (powerPressed(drained[0 .. got / @sizeOf(InputEvent)])) unlocked(in) else null;
}

/// The power watcher died: start another now and then. A wake-up while no one
/// listened is gone for good, so then powerd is asked instead.
pub fn restartWatcherIfDead(in: *Input) ?Action {
    if (in.power_events >= 0 or nowUs() < in.watcher_retry_us) return null;
    in.watcher_retry_us = nowUs() + watcher_retry_ms * 1000;
    startWatcher(in);
    std.debug.print("power watcher restarted: {}\n", .{in.power_events >= 0});
    if (in.locked and lipc.inScreenSaver() == false) return unlocked(in);
    return null;
}

/// A computer setting up USB for files (not for a network, as SSH uses).
pub fn fromUsbWatcher(in: *Input) ?Action {
    if (in.usb_events < 0) return null;
    var buf: [512]u8 = undefined;
    const line = readWatcher(in.usb_events, &buf) orelse {
        // That watcher died; handing over to the computer is lost until a restart
        _ = linux.close(in.usb_events);
        in.usb_events = -1;
        std.debug.print("usb watcher stopped\n", .{});
        return null;
    };
    if (std.mem.indexOf(u8, line, "usbConfigured") == null) return null;
    return if (lipc.usbForNetwork()) null else .computer;
}

/// Locking, waking, and a charger coming or going, from powerd.
pub fn fromPowerWatcher(in: *Input) ?Action {
    if (in.power_events < 0) return null;
    var buf: [512]u8 = undefined;
    const line = readWatcher(in.power_events, &buf) orelse {
        powerWatcherDied(in);
        return null;
    };
    if (touch_zones.lastPowerEvent(line)) |event| return if (event == .lock) .lock else unlocked(in);
    if (touch_zones.chargerChanged(line)) {
        in.charger_changed = true;
        return .tick; // For the status bar to catch up
    }
    return null;
}

/// Without closing it, the dead pipe would wake every wait at once, forever.
pub fn powerWatcherDied(in: *Input) void {
    _ = linux.close(in.power_events);
    in.power_events = -1;
    in.watcher_retry_us = nowUs() + watcher_retry_ms * 1000;
    var status: i32 = 0;
    while (true) {
        const reaped = linux.waitpid(-1, &status, linux.W.NOHANG);
        if (reaped == 0 or failed(reaped)) break;
    }
}

/// Tell powerd about activity at most once a minute, and only just after a touch:
/// later the Kindle may already be locking, and powerd refuses the call then.
pub fn shouldTellPowerd(locked: bool, now: u64, last_touch: u64, last_told: u64) bool {
    return !locked and now -| last_touch < activity_fresh_us and last_touch > last_told + activity_every_us;
}

/// True when the events include the power key going down.
pub fn powerPressed(events: []const InputEvent) bool {
    for (events) |e| {
        if (e.kind == ev_key and e.code == key_power and e.value == 1) return true;
    }
    return false;
}

/// A line from a lipc watcher's pipe, or null when it has closed (the watcher died).
/// Nothing waiting gives an empty line.
pub fn readWatcher(fd: i32, buf: []u8) ?[]const u8 {
    const got = linux.read(fd, buf.ptr, buf.len);
    if (got == 0) return null;
    if (failed(got)) return "";
    return buf[0..got];
}

test "only a power key press counts" {
    try std.testing.expect(powerPressed(&.{ ev(0, 0, 0), ev(ev_key, key_power, 1) }));
    try std.testing.expect(!powerPressed(&.{ev(ev_key, key_power, 0)})); // Release
    try std.testing.expect(!powerPressed(&.{ev(ev_key, 30, 1)}));
    try std.testing.expect(!powerPressed(&.{}));
}

test "powerd hears about touches only while they're fresh" {
    const min = 60 * 1000 * 1000;
    try std.testing.expect(shouldTellPowerd(false, 10 * min, 10 * min - 1000, 8 * min));
    try std.testing.expect(!shouldTellPowerd(false, 10 * min, 9 * min, 7 * min)); // Touch a minute old
    try std.testing.expect(!shouldTellPowerd(false, 10 * min, 10 * min, 10 * min - 1000)); // Told just now
    try std.testing.expect(!shouldTellPowerd(true, 10 * min, 10 * min, 0)); // Locked
}
