//! What noface hears besides touches, and owes others while it waits: powerd's lock,
//! wake and charger news, a computer on USB, the power key, the heartbeat for the
//! launcher's watchdog (src/kindle/supervisor.zig), and a word to powerd now and then. These are
//! `Input`'s methods (input.zig names each one); the state they keep is Input's.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("../../sys/file.zig");
const input = @import("../input.zig");
const evdev = @import("evdev.zig");
const paths = @import("../paths.zig");
const lipc = @import("../lipc.zig");
const linux = @import("../../sys/calls.zig");
const os = @import("../../sys/os.zig");
const process = @import("../../sys/process.zig");
const Input = input.Input;
const Action = input.Action;
const InputEvent = evdev.InputEvent;
const failed = os.failed;
const now_us = os.now_us;
const ev_key = evdev.ev_key;
const key_power = evdev.key_power;
const ev = @import("gestures.zig").ev;

const heartbeat_every_us = 30 * 1000 * 1000;
const heartbeat_path = paths.heartbeat; // In RAM: the launcher's watchdog reads it
/// How long the launcher's watchdog (src/kindle/supervisor.zig) waits for a beat before
/// stopping noface.
const watchdog_patience_us = 2 * 60 * 1000 * 1000;
pub const watcher_retry_ms = 5000;
/// Tell powerd about activity at most once a minute, and only just after a touch:
/// later the Kindle may already be locking, and powerd refuses the call then.
const activity_every_us = 60 * 1000 * 1000;
const activity_fresh_us = 5 * 1000 * 1000;
/// How long powerd waits, untold, before it locks the Kindle.
const powerd_lock_after_us = 10 * 60 * 1000 * 1000;

comptime {
    // A beat or two can be late (a long layout) before the watchdog gives up
    assert(heartbeat_every_us * 2 < watchdog_patience_us);
    // A fresh touch is fresher than the last word to powerd can be old
    assert(activity_fresh_us < activity_every_us);
    // Told this often, powerd never locks the Kindle mid-book
    assert(activity_every_us < powerd_lock_after_us);
    assert(watcher_retry_ms > 0);
    // Beats go to RAM: a write every 30 s to the user drive would wear it for nothing
    assert(std.mem.startsWith(u8, heartbeat_path, "/tmp/"));
}

/// A watcher's pipe to poll, or -1, which poll passes over, when it isn't running.
pub fn fd_of(watcher: ?process.Child) i32 {
    const w = watcher orelse return -1;
    assert(w.out >= 0);
    return w.out;
}

/// Whether powerd's or USB's watcher has something to say, without waiting.
pub fn news_waiting(in: *Input) bool {
    var fds = [_]linux.pollfd{
        .{ .fd = fd_of(in.power_watcher), .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = fd_of(in.usb_watcher), .events = linux.POLL.IN, .revents = 0 },
    };
    const n = linux.poll(&fds, fds.len, 0);
    if (failed(n)) return false;
    assert(n <= fds.len);
    return n > 0;
}

/// Tells the launcher's watchdog (src/kindle/supervisor.zig) that noface is alive, now.
pub fn beat(in: *Input) void {
    in.heartbeat_us = now_us();
    beat_to(heartbeat_path);
}

/// Writes the heartbeat at `path` (the watchdog's, but for the tests): the time now,
/// by the wall clock the watchdog reads it with. Needs no Input, so noface beats as it
/// starts, and work that runs long before the loop first turns (a library build) beats.
pub fn beat_to(path: [*:0]const u8) void {
    // Room for any u64 and its newline, so the stamp is never the fallback's zero
    var stamp: [24]u8 = undefined;
    comptime assert(stamp.len >= 20 + 1);
    const text = std.fmt.bufPrint(&stamp, "{d}\n", .{os.unix_time()}) catch "0\n";
    assert(text.len > 1);
    // Unwritten, the beat is missed, which is what the watchdog watches for: it decides
    _ = file.write_small(path, text);
}

/// Beats at `path` if the last beat, at `last_us` on the monotonic clock, was a beat's
/// interval ago: the loop's cadence, and a long job's, which keeps its own `last_us`.
pub fn beat_when_due(path: [*:0]const u8, last_us: *u64) void {
    const now = now_us();
    if (now <= last_us.* + heartbeat_every_us) return;
    last_us.* = now;
    beat_to(path);
}

/// Waking up: the monotonic clock stood still while the Kindle slept, so the last
/// beat may be hours old by the wall clock the watchdog uses. Beat before it looks.
pub fn unlocked(in: *Input) Action {
    beat(in);
    return .unlock;
}

/// Starts listening for a computer on USB, from the volume manager.
pub fn start_usb_watcher(in: *Input) void {
    assert(in.usb_watcher == null);
    in.usb_watcher = lipc.watch_usb_events();
}

/// Starts listening for lock and unlock, and the charger, from powerd.
pub fn start_watcher(in: *Input) void {
    // Only once the last one is gone: two would hear every event twice
    assert(in.power_watcher == null);
    in.power_watcher = lipc.watch_power_events();
}

/// What noface owes others while it waits: a heartbeat for the launcher's watchdog
/// (src/kindle/supervisor.zig), and, as touches are grabbed and powerd can't see them, a word
/// to powerd now and then so it doesn't lock the Kindle ten minutes into a book.
pub fn keep_alive(in: *Input) void {
    // What powerd heard of is a touch already made, on the same clock
    assert(in.told_powerd_us <= in.last_input);
    beat_when_due(heartbeat_path, &in.heartbeat_us);
    if (should_tell_powerd(in.locked, now_us(), in.last_input, in.told_powerd_us)) {
        assert(!in.locked);
        in.told_powerd_us = in.last_input;
        lipc.still_active();
    }
}

/// The power key is powerd's to act on: it's read only so presses don't pile up,
/// except while locked with no watcher, when a press is the only way to wake.
pub fn from_power_key(in: *Input) ?Action {
    var drained: [16]InputEvent = undefined;
    const got = linux.read(in.power, @ptrCast(&drained), @sizeOf(@TypeOf(drained)));
    if (failed(got) or !in.locked or in.power_watcher != null) return null;
    assert(got <= @sizeOf(@TypeOf(drained)));
    const events = drained[0 .. got / @sizeOf(InputEvent)];
    assert(events.len <= drained.len);
    return if (power_pressed(events)) unlocked(in) else null;
}

/// The power watcher died: start another now and then. A wake-up while no one
/// listened is gone for good, so then powerd is asked instead.
pub fn restart_watcher_if_dead(in: *Input) ?Action {
    if (in.power_watcher != null or now_us() < in.watcher_retry_us) return null;
    in.watcher_retry_us = now_us() + watcher_retry_ms * 1000;
    start_watcher(in);
    std.debug.print("power watcher restarted: {}\n", .{in.power_watcher != null});
    if (!in.locked) return null;
    // No answer: still locked as far as anyone knows, till powerd's next event reaches
    // the new watcher (there's no restart after this one to ask again)
    const state = lipc.power_state() orelse return null;
    return switch (state) {
        .awake => unlocked(in),
        .asleep => null,
    };
}

/// The USB watcher died, or never started: another now and then, so plugging into a
/// computer still hands the Kindle over to it.
pub fn restart_usb_watcher_if_dead(in: *Input) void {
    if (in.usb_watcher != null or now_us() < in.usb_retry_us) return;
    in.usb_retry_us = now_us() + watcher_retry_ms * std.time.us_per_ms;
    start_usb_watcher(in);
    std.debug.print("usb watcher restarted: {}\n", .{in.usb_watcher != null});
    assert(in.usb_retry_us > 0);
}

/// A computer setting up USB for files (not for a network, as SSH uses).
pub fn from_usb_watcher(in: *Input) ?Action {
    const w = in.usb_watcher orelse return null;
    var buffer: [512]u8 = undefined;
    const line = read_watcher(w.out, &buffer) orelse {
        // That watcher died; handing over to the computer is lost until a restart
        reap(&in.usb_watcher);
        std.debug.print("usb watcher stopped\n", .{});
        return null;
    };
    assert(line.len <= buffer.len);
    if (std.mem.indexOf(u8, line, "usbConfigured") == null) return null;
    return if (lipc.usb_for_network()) null else .computer;
}

/// What powerd's watcher reads, as lipc.zig asks for it (`lipc.power_watched`).
pub const PowerEvent = enum { lock, unlock };

/// The newest power event in what was read, so a quick lock and unlock settles
/// on where the Kindle ended up.
pub fn last_power_event(line: []const u8) ?PowerEvent {
    const lock = std.mem.lastIndexOf(u8, line, "goingToScreenSaver");
    const unlock = std.mem.lastIndexOf(u8, line, "outOfScreenSaver");
    if (unlock) |unlock_at| {
        assert(unlock_at < line.len);
        // The two names can't overlap, so they never start at the same place
        if (lock) |lock_at| assert(lock_at != unlock_at);
        if (lock == null or unlock_at > lock.?) return .unlock;
    }
    return if (lock != null) .lock else null;
}

/// Whether powerd said a charger came or went: "charging" or "notCharging".
pub fn charger_changed(line: []const u8) bool {
    const charging = std.mem.indexOf(u8, line, "charging") != null;
    const not_charging = std.mem.indexOf(u8, line, "Charging") != null;
    return charging or not_charging;
}

/// Locking, waking, and a charger coming or going, from powerd.
pub fn from_power_watcher(in: *Input) ?Action {
    const w = in.power_watcher orelse return null;
    var buffer: [512]u8 = undefined;
    const line = read_watcher(w.out, &buffer) orelse {
        power_watcher_died(in);
        return null;
    };
    assert(line.len <= buffer.len);
    if (last_power_event(line)) |event| {
        return if (event == .lock) .lock else unlocked(in);
    }
    if (charger_changed(line)) return .charger;
    return null;
}

/// Without closing it, the dead pipe would wake every wait at once, forever.
pub fn power_watcher_died(in: *Input) void {
    assert(in.power_watcher != null);
    reap(&in.power_watcher);
    in.watcher_retry_us = now_us() + watcher_retry_ms * 1000;
}

/// A watcher that died: its pipe closed, which frees the number (it's dead already),
/// and it reaped. Only the watcher: any other child (a download, a lipc command) is
/// waited for by whoever started it, which would otherwise find it gone. Its pipe
/// closes as it dies, before it can be waited for: a wait that doesn't block can come
/// too soon and leave it a zombie, so it's stopped and waited for, which is at once.
fn reap(watcher: *?process.Child) void {
    const w = watcher.* orelse return;
    assert(w.pid > 0);
    _ = linux.close(w.out); // Ignored: dead already: closing only frees the number
    process.stop(w.pid);
    watcher.* = null;
}

/// Tell powerd about activity at most once a minute, and only just after a touch:
/// later the Kindle may already be locking, and powerd refuses the call then.
pub fn should_tell_powerd(locked: bool, now: u64, last_touch: u64, last_told: u64) bool {
    // All three are times on the monotonic clock, taken in this order
    assert(last_told <= last_touch);
    assert(last_touch <= now);
    if (locked) return false;
    if (now -| last_touch >= activity_fresh_us) return false;
    return last_touch > last_told + activity_every_us;
}

/// True when the events include the power key going down.
pub fn power_pressed(events: []const InputEvent) bool {
    for (events) |event| {
        if (event.kind == ev_key and event.code == key_power and event.value == 1) return true;
    }
    return false;
}

/// A line from a lipc watcher's pipe, or null when it has closed (the watcher died).
/// Nothing waiting gives an empty line.
pub fn read_watcher(fd: i32, buffer: []u8) ?[]const u8 {
    assert(fd >= 0);
    assert(buffer.len > 0);
    const got = linux.read(fd, buffer.ptr, buffer.len);
    if (got == 0) return null;
    if (failed(got)) return "";
    assert(got <= buffer.len);
    return buffer[0..got];
}

test "only a power key press counts" {
    try std.testing.expect(power_pressed(&.{ ev(0, 0, 0), ev(ev_key, key_power, 1) }));
    try std.testing.expect(!power_pressed(&.{ev(ev_key, key_power, 0)})); // Release
    try std.testing.expect(!power_pressed(&.{ev(ev_key, 30, 1)}));
    try std.testing.expect(!power_pressed(&.{}));
}

test "a long job beats once a beat's interval has passed, and not while the clock stands" {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/noface-beat-{d}", .{
        linux.getpid(),
    }, 0);
    _ = linux.unlink(path); // Ignored: none there is as good
    defer _ = linux.unlink(path); // Ignored: only /tmp is left fuller
    const clock_was = os.fake_us;
    defer os.fake_us = clock_was;
    os.fake_us = 1000;
    var last_us: u64 = 1000; // The job's clock, started as it starts
    beat_when_due(path, &last_us);
    try std.testing.expect(!file.exists(path)); // Not a beat's interval yet
    os.fake_us.? += heartbeat_every_us + 1;
    beat_when_due(path, &last_us);
    try std.testing.expect(file.exists(path));
    try std.testing.expectEqual(os.fake_us.?, last_us);
    var stamp_buffer: [24]u8 = undefined;
    const stamp = file.read_system(path, &stamp_buffer);
    const beat_s = try std.fmt.parseInt(u64, stamp[0 .. stamp.len - 1], 10);
    try std.testing.expectEqual(os.unix_time(), beat_s);
    _ = linux.unlink(path); // Ignored: checked just below
    beat_when_due(path, &last_us);
    try std.testing.expect(!file.exists(path)); // Beat just now
}

test "powerd hears about touches only while they're fresh" {
    const min = 60 * 1000 * 1000;
    try std.testing.expect(should_tell_powerd(false, 10 * min, 10 * min - 1000, 8 * min));
    // A touch a minute old
    try std.testing.expect(!should_tell_powerd(false, 10 * min, 9 * min, 7 * min));
    // Told just now
    try std.testing.expect(!should_tell_powerd(false, 10 * min, 10 * min, 10 * min - 1000));
    try std.testing.expect(!should_tell_powerd(true, 10 * min, 10 * min, 0)); // Locked
}

test "the newest power event wins" {
    const lock = "goingToScreenSaver\n";
    const both = "goingToScreenSaver\noutOfScreenSaver\n";
    const both_reversed = "outOfScreenSaver\ngoingToScreenSaver\n";
    try std.testing.expectEqual(PowerEvent.lock, last_power_event(lock).?);
    try std.testing.expectEqual(PowerEvent.unlock, last_power_event(both).?);
    try std.testing.expectEqual(PowerEvent.lock, last_power_event(both_reversed).?);
    try std.testing.expect(last_power_event("something else\n") == null);
}
