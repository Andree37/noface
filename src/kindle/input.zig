//! Touch and power input: raw events in, taps, holds, drags and power changes out.
const std = @import("std");
const state = @import("../sys/state.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const devices = @import("devices.zig");
const lipc = @import("lipc.zig");
const touch_zones = @import("touch.zig");

const failed = os.failed;
const nowUs = os.nowUs;
const heartbeat_every_us = 30 * 1000 * 1000;
const heartbeat_path = "/tmp/noface-alive"; // In RAM: device/noface.sh's watchdog reads it
const watcher_retry_ms = 5000;
const activity_every_us = 60 * 1000 * 1000;
const activity_fresh_us = 5 * 1000 * 1000;

/// Tell powerd about activity at most once a minute, and only just after a touch:
/// later the Kindle may already be locking, and powerd refuses the call then.
pub fn shouldTellPowerd(locked: bool, now: u64, last_touch: u64, last_told: u64) bool {
    return !locked and now -| last_touch < activity_fresh_us and last_touch > last_told + activity_every_us;
}
const key_power = 116;

/// True when the events include the power key going down.
pub fn powerPressed(events: []const InputEvent) bool {
    for (events) |e| {
        if (e.kind == ev_key and e.code == key_power and e.value == 1) return true;
    }
    return false;
}

// The Paperwhite 12th gen's, used when nothing else is found
const touch_device = "/dev/input/event1";
const power_device = "/dev/input/event0";
pub const eviocgrab: u32 = 0x40044590;
const eviocsclockid: u32 = 0x400445a0;
const eviocgabs_x: u32 = 0x80184540 + 0x35;
const eviocgabs_y: u32 = 0x80184540 + 0x36;

const ev_key = 1;
const ev_abs = 3;
const abs_mt_slot = 0x2f;
const abs_mt_x = 0x35;
const abs_mt_y = 0x36;
const abs_mt_tracking = 0x39;

const InputEvent = extern struct { sec: u32, usec: u32, kind: u16, code: u16, value: i32 };

var stop_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

pub fn installSignals() void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = onSignal };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &act, null);
}

fn openInput(path: [*:0]const u8) !i32 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return error.InputOpen;
    const fd: i32 = @intCast(rc);
    var clock: i32 = 1; // CLOCK_MONOTONIC, so event times compare with nowUs
    _ = linux.ioctl(fd, eviocsclockid, @intFromPtr(&clock));
    return fd;
}

fn axisMax(fd: i32, req: u32) i32 {
    var info = std.mem.zeroes([6]i32);
    _ = linux.ioctl(fd, req, @intFromPtr(&info));
    return @max(info[2], 1);
}

/// Current position of a multitouch axis in both slots (EVIOCGMTSLOTS).
fn slotValues(fd: i32, code: u32) [2]i32 {
    var request = [_]i32{ @intCast(code), 0, 0 };
    _ = linux.ioctl(fd, 0x800c450a, @intFromPtr(&request));
    return .{ request[1], request[2] };
}

/// A tap: where, and when the finger touched (microseconds on the monotonic clock).
pub const Tap = struct { x: i32, y: i32, us: u64 };

pub const Action = union(enum) {
    tap: Tap,
    hold: struct { x: i32, y: i32 },
    pull,
    drag: i32, // Finger x while a drag is being followed
    swipe: i32, // A sideways stroke that lifted: 1 is on (leftwards), -1 back
    drag_end,
    tick,
    lock,
    unlock,
    power,
    computer, // Plugged into a computer for file transfer: the Kindle's own screens take over
    stop,
};

/// What a scenario test does, in order: an action as the reader's finger or the power
/// button would give it, or a wait on the virtual clock (os.fake_us).
pub const Step = union(enum) { act: Action, wait_ms: u64 };

/// A scenario being played back. Waits deliver the ticks the app asked for, at the
/// times they'd come; once the steps run out the app is told to stop.
pub const Script = struct {
    steps: []const Step,
    at: usize = 0,
    waiting_us: u64 = 0, // What's left of the current wait
    /// Called once, when the steps run out and before noface is told to stop: the
    /// screen as the script left it, for a test to keep.
    at_end: ?struct { ctx: *anyopaque, call: *const fn (ctx: *anyopaque) void } = null,
    ended: bool = false,

    fn next(sc: *Script, in: *Input) Action {
        while (true) {
            if (sc.waiting_us > 0) {
                const now = nowUs();
                const tick_at = if (in.tick_us != 0) in.last_tick + in.tick_us else std.math.maxInt(u64);
                if (tick_at <= now + sc.waiting_us) {
                    const step = tick_at -| now;
                    os.fake_us = now + step;
                    sc.waiting_us -= step;
                    in.last_tick = nowUs();
                    return .tick;
                }
                os.fake_us = now + sc.waiting_us;
                sc.waiting_us = 0;
            }
            if (sc.at >= sc.steps.len) {
                if (!sc.ended) if (sc.at_end) |e| e.call(e.ctx);
                sc.ended = true;
                return .stop;
            }
            const step = sc.steps[sc.at];
            sc.at += 1;
            switch (step) {
                .act => |a| {
                    os.fake_us = nowUs() + 1000; // A touch takes a moment
                    // Through the same grip zones as a finger, so a test can't tap what
                    // a reader couldn't
                    switch (a) {
                        .tap => |t| if (in.ignores(t.x, t.y)) continue,
                        .hold => |h| if (in.ignores(h.x, h.y)) continue,
                        else => {},
                    }
                    in.last_input = nowUs();
                    return a;
                },
                .wait_ms => |ms| sc.waiting_us = ms * 1000,
            }
        }
    }
};

/// An area of the screen, in screen pixels.
pub const Zone = struct { x: i32, y: i32, w: i32, h: i32 };

/// Turns raw touch events into taps.
/// The panel reports two slots. Every new finger counts, so a resting thumb
/// can't block taps from another finger.
pub const Input = struct {
    touch: i32,
    power: i32,
    power_events: i32 = -1,
    watcher_pid: i32 = 0, // The lipc-wait-event child behind power_events
    usb_events: i32 = -1, // Lines from a second watcher, on USB connections
    usb_watcher_pid: i32 = 0,
    heartbeat_us: u64 = 0, // When the watchdog last heard noface is alive
    width: i32,
    height: i32,
    x_max: i32,
    y_max: i32,
    events: [64]InputEvent = undefined,
    event_count: usize = 0,
    event_next: usize = 0,
    slot: usize = 0,
    xs: [2]i32 = .{ 0, 0 },
    ys: [2]i32 = .{ 0, 0 },
    pending: ?usize = null,
    down_us: u64 = 0,
    top_slot: ?usize = null,
    top_x: i32 = 0,
    top_y: i32 = 0,
    top_us: u64 = 0,
    top_moved: bool = false,
    deferred: bool = false, // On book pages: taps wait for lift, so a press can become a hold
    last_touched: usize = 0,
    grips: bool = true, // Off while controls sit where a thumb usually rests
    edge_zones: bool = true, // Off while handles can sit at the screen edges
    tick_us: u64 = 0, // When set, `next` returns .tick this often
    last_tick: u64 = 0,
    drag_slot: ?usize = null,
    drag_y: i32 = 0,
    last_input: u64 = 0,
    stashed: ?Action = null,
    locked: bool = false, // Nothing to check on a timer, so sleep until an event
    watcher_retry_us: u64 = 0, // When to restart a power-event watcher that died
    told_powerd_us: u64 = 0, // When powerd last heard the reader is active
    script: ?*Script = null, // Set in scenario tests: actions to play instead of the panel
    /// Set in the simulator: a pipe of whole Actions, written by its web page's taps.
    remote: i32 = -1,
    /// Set when powerd said a charger came or went: whoever shows the status bar reads it
    /// again and clears this.
    charger_changed: bool = false,
    /// A control inside the grip zones (the reader's Back button): touches there count.
    grip_exempt: ?Zone = null,

    /// How touches were before a sheet changed them, for `restore`.
    pub const Modes = struct { grips: bool, deferred: bool };

    /// Touches for a sheet or card over the page: every touch counts, even along the
    /// bottom edge where its buttons sit (a resting thumb is otherwise ignored there),
    /// and taps act as they land (nothing on a sheet becomes a hold, and a tap kept for
    /// the lift could reach whatever replaces it). Returns what was there before.
    pub fn forSheet(in: *Input) Modes {
        const was = Modes{ .grips = in.grips, .deferred = in.deferred };
        in.grips = false;
        in.deferred = false;
        return was;
    }

    pub fn restore(in: *Input, was: Modes) void {
        in.grips = was.grips;
        in.deferred = was.deferred;
    }

    /// For a screen of its own (a sheet, a list, a card): the next action, or null when
    /// the Kindle locks or noface is told to leave. That action is kept for the loop
    /// underneath, and the screen should close.
    pub fn nextFor(in: *Input) ?Action {
        const action = in.next();
        switch (action) {
            .lock, .power, .computer, .stop => {
                in.stashed = action;
                return null;
            },
            else => return action,
        }
    }

    /// The next tap, anything else passed over; null as with `nextFor`.
    pub fn nextTap(in: *Input) ?Tap {
        while (in.nextFor()) |action| {
            switch (action) {
                .tap => |t| return t,
                else => {},
            }
        }
        return null;
    }

    /// Whether a touch at (x, y) is taken for a resting thumb and ignored.
    pub fn ignores(in: *const Input, x: i32, y: i32) bool {
        if (!(in.edge_zones and in.grips and touch_zones.isGrip(x, y, in.width, in.height))) return false;
        if (in.grip_exempt) |r| {
            if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return false;
        }
        return true;
    }

    /// The next action from the simulator's pipe, or a tick when one is due first.
    fn fromRemote(in: *Input) Action {
        while (true) {
            const now = nowUs();
            if (in.tick_us != 0 and now - in.last_tick >= in.tick_us) {
                in.last_tick = now;
                return .tick;
            }
            const wait: i32 = if (in.tick_us == 0) 1000 else @intCast(@max(1, @min(1000, (in.last_tick + in.tick_us -| now) / 1000)));
            var fds = [_]linux.pollfd{.{ .fd = in.remote, .events = linux.POLL.IN, .revents = 0 }};
            const woke = linux.poll(&fds, 1, wait);
            if (stop_requested.load(.acquire)) return .stop;
            if (failed(woke) or woke == 0) continue;
            var action: Action = undefined;
            const got = linux.read(in.remote, @ptrCast(&action), @sizeOf(Action));
            if (got == 0) return .stop; // The simulator closed it
            if (got != @sizeOf(Action)) continue;
            in.last_input = nowUs();
            return action;
        }
    }

    /// Whether powerd's or USB's watcher has something to say, without waiting.
    fn newsWaiting(in: *Input) bool {
        var fds = [_]linux.pollfd{
            .{ .fd = in.power_events, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = in.usb_events, .events = linux.POLL.IN, .revents = 0 },
        };
        const n = linux.poll(&fds, fds.len, 0);
        return !failed(n) and n > 0;
    }

    /// Tells the watchdog in device/noface.sh that noface is alive, now.
    fn beat(in: *Input) void {
        in.heartbeat_us = nowUs();
        var stamp: [24]u8 = undefined;
        state.writeSmall(heartbeat_path, std.fmt.bufPrint(&stamp, "{d}\n", .{os.unixTime()}) catch "0\n");
    }

    /// Waking up: the monotonic clock stood still while the Kindle slept, so the last
    /// beat may be hours old by the wall clock the watchdog uses. Beat before it looks.
    fn unlocked(in: *Input) Action {
        in.beat();
        return .unlock;
    }

    /// Starts listening for lock and unlock from powerd.
    fn startUsbWatcher(in: *Input) void {
        const child = lipc.watchUsbEvents() orelse return;
        in.usb_events = child.out;
        in.usb_watcher_pid = child.pid;
    }

    fn startWatcher(in: *Input) void {
        const child = lipc.watchPowerEvents() orelse {
            in.power_events = -1;
            in.watcher_pid = 0;
            return;
        };
        in.power_events = child.out;
        in.watcher_pid = child.pid;
    }

    /// The next action from touch events already waiting, reading more only when the
    /// panel has them ready. Null once nothing more is waiting.
    fn waiting(in: *Input) ?Action {
        while (true) {
            while (in.event_next < in.event_count) {
                const e = in.events[in.event_next];
                in.event_next += 1;
                if (in.handle(e)) |action| return action;
            }
            const n = linux.read(in.touch, @ptrCast(&in.events), @sizeOf(@TypeOf(in.events)));
            if (failed(n) or n < @sizeOf(InputEvent)) return null;
            in.event_count = n / @sizeOf(InputEvent);
            in.event_next = 0;
            in.last_input = nowUs();
        }
    }

    /// Follows the finger of the last tap until it lifts.
    pub fn beginDrag(in: *Input) void {
        in.drag_slot = in.last_touched;
    }

    /// Skips to the newest finger position already waiting, if any.
    /// Anything else that turns up is kept for the next call to `next`.
    pub fn latestDrag(in: *Input) ?i32 {
        var latest: ?i32 = null;
        while (in.stashed == null) {
            const action = in.waiting() orelse return latest;
            switch (action) {
                .drag => |x| latest = x,
                else => in.stashed = action,
            }
        }
        return latest;
    }

    /// Sums page-turn taps already waiting, so fast tapping jumps instead of lagging.
    /// Anything else that turns up is kept for the next call to `next`.
    pub fn takeTurns(in: *Input) i32 {
        var delta: i32 = 0;
        while (in.stashed == null) {
            const action = in.waiting() orelse return delta;
            switch (action) {
                .tap => |t| {
                    if (t.y < touch_zones.top_zone) {
                        in.stashed = action;
                    } else {
                        delta += turnDirection(t.x, in.width);
                    }
                },
                else => in.stashed = action,
            }
        }
        return delta;
    }

    /// The next action: a touch, the power button, the Kindle locking or waking, a USB
    /// computer, a tick of the timer, or a request to stop. Waits until there is one.
    pub fn next(in: *Input) Action {
        while (true) {
            if (in.ready()) |action| return action;
            in.keepAlive();
            in.waitForEvents();
            if (in.fromPowerKey()) |action| return action;
            if (in.restartWatcherIfDead()) |action| return action;
            if (in.fromUsbWatcher()) |action| return action;
            if (in.fromPowerWatcher()) |action| return action;
        }
    }

    /// An action already known, without waiting: a request to stop, one kept back for
    /// the next call, the tests' script or the simulator's, touches already read, a
    /// press held long enough to be a hold, or a tick that's due.
    fn ready(in: *Input) ?Action {
        if (stop_requested.load(.acquire)) return .stop;
        if (in.stashed) |action| {
            in.stashed = null;
            return action;
        }
        if (in.script) |sc| return sc.next(in);
        if (in.remote >= 0) return in.fromRemote();
        if (in.waiting()) |action| return action;
        if (in.heldLongEnough()) |action| return action;
        return in.tickDue();
    }

    /// A press on a page that stayed put long enough: a hold, followed from here as a drag.
    fn heldLongEnough(in: *Input) ?Action {
        const slot = in.top_slot orelse return null;
        if (!in.deferred or in.top_moved) return null;
        if (nowUs() -| in.top_us < touch_zones.hold_ms * 1000) return null;
        in.top_slot = null;
        in.drag_slot = slot;
        return .{ .hold = .{ .x = in.top_x, .y = in.top_y } };
    }

    /// A tick, if one is due. It waits for powerd and USB news already in: with short
    /// ticks (a book laid out in idle moments) they'd otherwise go unread for seconds.
    fn tickDue(in: *Input) ?Action {
        if (in.tick_us == 0 or nowUs() - in.last_tick < in.tick_us or in.newsWaiting()) return null;
        in.last_tick = nowUs();
        return .tick;
    }

    /// What noface owes others while it waits: a heartbeat for the watchdog in
    /// device/noface.sh, and, as touches are grabbed and powerd can't see them, a word
    /// to powerd now and then so it doesn't lock the Kindle ten minutes into a book.
    fn keepAlive(in: *Input) void {
        if (nowUs() > in.heartbeat_us + heartbeat_every_us) in.beat();
        if (shouldTellPowerd(in.locked, nowUs(), in.last_input, in.told_powerd_us)) {
            in.told_powerd_us = in.last_input;
            lipc.stillActive();
        }
    }

    /// Sleeps until a touch or a watcher has something, or the next tick is due. Locked,
    /// with nothing to tick, it sleeps on (waking now and then to restart a dead watcher).
    fn waitForEvents(in: *Input) void {
        // The power key matters only while locked with no watcher, as the way to unlock
        const key_fd = if (in.locked and in.power_events < 0) in.power else -1;
        var fds = [_]linux.pollfd{
            .{ .fd = in.touch, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = in.power_events, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = in.usb_events, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = key_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        _ = linux.poll(&fds, fds.len, in.waitMs());
    }

    fn waitMs(in: *const Input) i32 {
        if (in.top_slot != null) return 30; // A press that may become a hold
        if (in.locked and in.tick_us == 0) return if (in.power_events < 0) watcher_retry_ms else -1;
        // No longer than until the next tick, so a short one (a double tap's window)
        // isn't stretched to the full second
        if (in.tick_us == 0) return 1000;
        return @intCast(@max(1, @min(1000, (in.last_tick + in.tick_us -| nowUs()) / 1000)));
    }

    /// powerd acts on the power key itself: it's read only so presses don't pile up,
    /// except while locked with no watcher, when a press is the only way to wake.
    fn fromPowerKey(in: *Input) ?Action {
        var drained: [16]InputEvent = undefined;
        const got = linux.read(in.power, @ptrCast(&drained), @sizeOf(@TypeOf(drained)));
        if (failed(got) or !in.locked or in.power_events >= 0) return null;
        return if (powerPressed(drained[0 .. got / @sizeOf(InputEvent)])) in.unlocked() else null;
    }

    /// The power watcher died: start another now and then. A wake-up while no one
    /// listened is gone for good, so then powerd is asked instead.
    fn restartWatcherIfDead(in: *Input) ?Action {
        if (in.power_events >= 0 or nowUs() < in.watcher_retry_us) return null;
        in.watcher_retry_us = nowUs() + watcher_retry_ms * 1000;
        in.startWatcher();
        std.debug.print("power watcher restarted: {}\n", .{in.power_events >= 0});
        if (in.locked and lipc.inScreenSaver() == false) return in.unlocked();
        return null;
    }

    /// A computer setting up USB for files (not for a network, as SSH uses).
    fn fromUsbWatcher(in: *Input) ?Action {
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
    fn fromPowerWatcher(in: *Input) ?Action {
        if (in.power_events < 0) return null;
        var buf: [512]u8 = undefined;
        const line = readWatcher(in.power_events, &buf) orelse {
            in.powerWatcherDied();
            return null;
        };
        if (touch_zones.lastPowerEvent(line)) |event| return if (event == .lock) .lock else in.unlocked();
        if (touch_zones.chargerChanged(line)) {
            in.charger_changed = true;
            return .tick; // For the status bar to catch up
        }
        return null;
    }

    /// Without closing it, the dead pipe would wake every wait at once, forever.
    fn powerWatcherDied(in: *Input) void {
        _ = linux.close(in.power_events);
        in.power_events = -1;
        in.watcher_retry_us = nowUs() + watcher_retry_ms * 1000;
        var status: i32 = 0;
        while (true) {
            const reaped = linux.waitpid(-1, &status, linux.W.NOHANG);
            if (reaped == 0 or failed(reaped)) break;
        }
    }

    /// One raw event from the touch panel, turned into an action when one is complete.
    pub fn handle(in: *Input, e: InputEvent) ?Action {
        if (e.kind == ev_abs) return in.onAxis(e);
        // A packet of events ends with a SYN: a new touch's place is known only then
        if (e.kind == 0) return in.onPacketEnd();
        return null;
    }

    fn screenX(in: *const Input, slot: usize) i32 {
        return @divTrunc(in.xs[slot] * in.width, in.x_max);
    }

    fn screenY(in: *const Input, slot: usize) i32 {
        return @divTrunc(in.ys[slot] * in.height, in.y_max);
    }

    /// A finger's slot, place, or touching down or lifting.
    fn onAxis(in: *Input, e: InputEvent) ?Action {
        switch (e.code) {
            abs_mt_slot => in.slot = @min(@as(usize, @intCast(@max(e.value, 0))), 1),
            abs_mt_x => in.xs[in.slot] = e.value,
            abs_mt_y => in.ys[in.slot] = e.value,
            abs_mt_tracking => {
                if (e.value < 0) return in.fingerUp();
                in.pending = in.slot; // Down: where is known at the packet's end
                in.down_us = @as(u64, e.sec) * 1_000_000 + e.usec;
            },
            else => {},
        }
        return null;
    }

    fn fingerUp(in: *Input) ?Action {
        if (in.drag_slot == in.slot) {
            in.drag_slot = null;
            return .drag_end;
        }
        if (in.top_slot == in.slot) {
            in.top_slot = null;
            return in.lifted();
        }
        return null;
    }

    /// A finger lifted that nothing was following: a sideways stroke is a swipe, and a
    /// finger that stayed put or only rolled a little a tap where it began. A real
    /// stroke some other way is neither: turning a page by where an arc began would be
    /// a guess, often the wrong way.
    fn lifted(in: *Input) ?Action {
        const x = in.screenX(in.slot);
        const y = in.screenY(in.slot);
        if (in.top_moved) {
            if (touch_zones.swipeDirection(in.top_x, in.top_y, x, y)) |dir| return .{ .swipe = dir };
            if (touch_zones.isStroke(in.top_x, in.top_y, x, y)) return null;
        }
        return .{ .tap = .{ .x = in.top_x, .y = in.top_y, .us = in.top_us } };
    }

    /// The end of a packet: a followed finger moved, a pressed one moved or pulled
    /// down from the top, or a new touch landed.
    fn onPacketEnd(in: *Input) ?Action {
        if (in.drag_slot) |slot| {
            in.pending = null;
            in.drag_y = in.screenY(slot);
            return .{ .drag = in.screenX(slot) };
        }
        if (in.top_slot) |slot| {
            const x = in.screenX(slot);
            const y = in.screenY(slot);
            if (touch_zones.movedOff(in.top_x, in.top_y, x, y)) in.top_moved = true;
            if (in.top_y < touch_zones.top_zone and touch_zones.isPull(in.top_y, y)) {
                in.top_slot = null;
                return .pull;
            }
        }
        const touched = in.pending orelse return null;
        in.pending = null;
        return in.touchedDown(touched);
    }

    /// A new touch: ignored as a resting thumb, a tap at once, or (on a book page, and
    /// at the top edge) a press to watch until it lifts, moves or is held.
    fn touchedDown(in: *Input, slot: usize) ?Action {
        in.last_touched = slot;
        const x = in.screenX(slot);
        const y = in.screenY(slot);
        if (in.ignores(x, y)) return null;
        const watch = in.deferred or (in.edge_zones and y < touch_zones.top_zone);
        if (!watch) return .{ .tap = .{ .x = x, .y = y, .us = in.down_us } };
        in.top_slot = slot;
        in.top_x = x;
        in.top_y = y;
        in.top_us = in.down_us;
        in.top_moved = false;
        return null;
    }
};

/// A line from a lipc watcher's pipe, or null when it has closed (the watcher died).
/// Nothing waiting gives an empty line.
fn readWatcher(fd: i32, buf: []u8) ?[]const u8 {
    const got = linux.read(fd, buf.ptr, buf.len);
    if (got == 0) return null;
    if (failed(got)) return "";
    return buf[0..got];
}

/// Left third goes back a page, the rest forward.
pub fn turnDirection(x: i32, width: i32) i32 {
    return if (x < @divTrunc(width, 3)) -1 else 1;
}

/// Opens touch and power, and takes the touchscreen from the stock UI.
pub fn open(width: u32, height: u32) !Input {
    // Found by what they report, as Kindles number them differently; this model's
    // numbers if nothing answers
    const found = devices.findInputs();
    var touch_buf: [24]u8 = undefined;
    var power_buf: [24]u8 = undefined;
    const touch_path = if (found.touch) |n| std.fmt.bufPrintSentinel(&touch_buf, "/dev/input/event{d}", .{n}, 0) catch touch_device else touch_device;
    const power_path = if (found.power) |n| std.fmt.bufPrintSentinel(&power_buf, "/dev/input/event{d}", .{n}, 0) catch power_device else power_device;
    std.debug.print("input: touch {s}, power {s}\n", .{ touch_path, power_path });
    const touch = try openInput(touch_path);
    const power = try openInput(power_path);
    if (failed(linux.ioctl(touch, eviocgrab, 1))) return error.GrabFailed;
    // The kernel only reports coordinates that change, so start from the current ones.
    var in = Input{
        .touch = touch,
        .power = power,
        .width = @intCast(width),
        .height = @intCast(height),
        .x_max = axisMax(touch, eviocgabs_x),
        .y_max = axisMax(touch, eviocgabs_y),
        .xs = slotValues(touch, abs_mt_x),
        .ys = slotValues(touch, abs_mt_y),
        .last_input = nowUs(),
    };
    in.startWatcher();
    in.startUsbWatcher();
    return in;
}

/// Gives the touchscreen back to the stock UI.
pub fn release(in: *const Input) void {
    _ = linux.ioctl(in.touch, eviocgrab, 0);
    for ([_]i32{ in.watcher_pid, in.usb_watcher_pid }) |pid| {
        if (pid <= 0) continue;
        _ = linux.kill(pid, linux.SIG.TERM);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
    }
}

// A pretend panel, the size of the screen, with no devices behind it.
fn testInput() Input {
    return .{ .touch = -1, .power = -1, .width = 1272, .height = 1696, .x_max = 1272, .y_max = 1696 };
}

fn ev(kind: u16, code: u16, value: i32) InputEvent {
    return .{ .sec = 0, .usec = 0, .kind = kind, .code = code, .value = value };
}

/// Feeds one finger's down (or move) packet, returning what it produced.
fn press(in: *Input, slot: i32, x: i32, y: i32, new: bool) ?Action {
    _ = in.handle(ev(ev_abs, abs_mt_slot, slot));
    if (new) _ = in.handle(ev(ev_abs, abs_mt_tracking, 7));
    _ = in.handle(ev(ev_abs, abs_mt_x, x));
    _ = in.handle(ev(ev_abs, abs_mt_y, y));
    return in.handle(ev(0, 0, 0));
}

fn lift(in: *Input, slot: i32) ?Action {
    _ = in.handle(ev(ev_abs, abs_mt_slot, slot));
    const lifted = in.handle(ev(ev_abs, abs_mt_tracking, -1));
    const synced = in.handle(ev(0, 0, 0));
    return lifted orelse synced;
}

test "a touch in the middle taps at once" {
    var in = testInput();
    const a = press(&in, 0, 900, 900, true).?;
    try std.testing.expectEqual(@as(i32, 900), a.tap.x);
    try std.testing.expect(lift(&in, 0) == null);
}

test "on book pages a tap waits for the finger to lift" {
    var in = testInput();
    in.deferred = true;
    try std.testing.expect(press(&in, 0, 900, 900, true) == null);
    try std.testing.expectEqual(@as(i32, 900), lift(&in, 0).?.tap.y);
}

test "the top edge taps on lift, unless edge zones are off" {
    var in = testInput();
    try std.testing.expect(press(&in, 0, 500, 100, true) == null);
    try std.testing.expectEqual(@as(i32, 100), lift(&in, 0).?.tap.y);
    in.edge_zones = false;
    try std.testing.expectEqual(@as(i32, 100), press(&in, 0, 500, 100, true).?.tap.y);
}

test "a resting thumb is ignored, unless edge zones are off" {
    var in = testInput();
    try std.testing.expect(press(&in, 1, 150, 1600, true) == null);
    try std.testing.expect(lift(&in, 1) == null);
    in.edge_zones = false;
    try std.testing.expect(press(&in, 1, 150, 1600, true) != null);
}

test "dragging down from the top pulls the panel" {
    var in = testInput();
    try std.testing.expect(press(&in, 0, 600, 40, true) == null);
    try std.testing.expect(press(&in, 0, 600, 200, false).? == .pull);
}

test "a followed finger drags, then ends on lift" {
    var in = testInput();
    _ = press(&in, 0, 300, 900, true);
    in.beginDrag();
    try std.testing.expectEqual(@as(i32, 420), press(&in, 0, 420, 910, false).?.drag);
    try std.testing.expectEqual(@as(i32, 910), in.drag_y);
    try std.testing.expect(lift(&in, 0).? == .drag_end);
}

test "on waiting pages a sideways stroke swipes instead of tapping" {
    var in = testInput();
    in.deferred = true;
    try std.testing.expect(press(&in, 0, 900, 800, true) == null);
    _ = press(&in, 0, 600, 810, false);
    try std.testing.expectEqual(@as(i32, 1), lift(&in, 0).?.swipe);
    try std.testing.expect(press(&in, 0, 900, 800, true) == null);
    _ = press(&in, 0, 920, 805, false); // A wobble
    try std.testing.expectEqual(@as(i32, 900), lift(&in, 0).?.tap.x);
    // A thumb's arc, as far down as across, still swipes
    try std.testing.expect(press(&in, 0, 900, 700, true) == null);
    _ = press(&in, 0, 780, 760, false);
    _ = press(&in, 0, 650, 860, false);
    try std.testing.expectEqual(@as(i32, 1), lift(&in, 0).?.swipe);
    // Moved, but mostly up or down: nothing, not a tap where it began
    try std.testing.expect(press(&in, 0, 600, 600, true) == null);
    _ = press(&in, 0, 620, 900, false);
    try std.testing.expect(lift(&in, 0) == null);
    // A finger that rolls 40 px is still a tap
    try std.testing.expect(press(&in, 0, 400, 1140, true) == null);
    _ = press(&in, 0, 440, 1140, false);
    try std.testing.expectEqual(@as(i32, 400), lift(&in, 0).?.tap.x);
}

test "a second finger taps while a thumb rests" {
    var in = testInput();
    _ = press(&in, 0, 150, 1600, true); // Thumb, ignored
    try std.testing.expectEqual(@as(i32, 800), press(&in, 1, 800, 800, true).?.tap.x);
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
