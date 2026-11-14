//! Touch and power input: raw events in, taps, holds, drags and power changes out.
//! `Input` and how screens use it are here. How touches become actions is in
//! input/gestures.zig, what's heard besides touches in input/watchers.zig, and the
//! kernel's event format in input/evdev.zig.
const std = @import("std");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const devices = @import("devices.zig");
const touch_zones = @import("touch.zig");

const failed = os.failed;
const nowUs = os.nowUs;

const evdev = @import("input/evdev.zig");
const gestures = @import("input/gestures.zig");
const watchers = @import("input/watchers.zig");
pub const eviocgrab = evdev.eviocgrab;
pub const shouldTellPowerd = watchers.shouldTellPowerd;
pub const powerPressed = watchers.powerPressed;
pub const turnDirection = gestures.turnDirection;
const InputEvent = evdev.InputEvent;

var stop_requested = std.atomic.Value(bool).init(false);

fn onSignal(_: linux.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

pub fn installSignals() void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = onSignal };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |sig| _ = linux.sigaction(sig, &act, null);
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

    /// How touches are taken: whether a resting thumb along the edges is ignored
    /// (`grips`), whether taps wait for the finger to lift so a press can become a hold
    /// (`deferred`), and whether the top edge is held back for the toolbar (`edge_zones`).
    pub const Modes = struct {
        grips: bool,
        deferred: bool,
        edge_zones: bool,

        /// A sheet, card or list over the page: every touch counts, even along the
        /// bottom edge where its buttons sit, and taps act as they land (nothing on it
        /// becomes a hold, and a tap kept for the lift could reach whatever replaces it).
        pub const sheet = Modes{ .grips = false, .deferred = false, .edge_zones = true };
    };

    pub fn modes(in: *const Input) Modes {
        return .{ .grips = in.grips, .deferred = in.deferred, .edge_zones = in.edge_zones };
    }

    /// Takes touches as `m` says, from now on.
    pub fn take(in: *Input, m: Modes) void {
        in.grips = m.grips;
        in.deferred = m.deferred;
        in.edge_zones = m.edge_zones;
    }

    /// Everything about taking input that a screen sets for itself while it's open.
    pub const Scope = struct { modes: Modes, tick_us: u64, grip_exempt: ?Zone };

    /// For a screen opening: takes touches as `m` says, ticks every `tick_us` (0:
    /// never) counting from now, with no control exempt from the grip zones. Returns
    /// how it all was, for `leave` when the screen closes:
    ///
    ///     const was = in.enter(modes, tick_us);
    ///     defer in.leave(was);
    pub fn enter(in: *Input, m: Modes, tick_us: u64) Scope {
        const was = Scope{ .modes = in.modes(), .tick_us = in.tick_us, .grip_exempt = in.grip_exempt };
        in.take(m);
        in.tick_us = tick_us;
        in.last_tick = nowUs();
        in.grip_exempt = null;
        return was;
    }

    /// Puts back what `enter` changed.
    pub fn leave(in: *Input, was: Scope) void {
        in.take(was.modes);
        in.tick_us = was.tick_us;
        in.grip_exempt = was.grip_exempt;
    }

    /// Keeps `action` back, for the next call to `next`: for a screen that ends because
    /// of it, so the one underneath acts on it in turn.
    pub fn holdBack(in: *Input, action: Action) void {
        in.stashed = action;
    }

    /// An action kept back for the next call to `next`, if any: a lock or a stop that
    /// closed a screen, or something that turned up while a drag was being followed.
    pub fn heldBack(in: *const Input) ?Action {
        return in.stashed;
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

    pub const ignores = gestures.ignores;

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

    const newsWaiting = watchers.newsWaiting;

    const beat = watchers.beat;

    const unlocked = watchers.unlocked;

    const startUsbWatcher = watchers.startUsbWatcher;

    const startWatcher = watchers.startWatcher;

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

    const heldLongEnough = gestures.heldLongEnough;

    /// A tick, if one is due. It waits for powerd and USB news already in: with short
    /// ticks (a book laid out in idle moments) they'd otherwise go unread for seconds.
    fn tickDue(in: *Input) ?Action {
        if (in.tick_us == 0 or nowUs() - in.last_tick < in.tick_us or in.newsWaiting()) return null;
        in.last_tick = nowUs();
        return .tick;
    }

    const keepAlive = watchers.keepAlive;

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
        if (in.locked and in.tick_us == 0) return if (in.power_events < 0) watchers.watcher_retry_ms else -1;
        // No longer than until the next tick, so a short one (a double tap's window)
        // isn't stretched to the full second
        if (in.tick_us == 0) return 1000;
        return @intCast(@max(1, @min(1000, (in.last_tick + in.tick_us -| nowUs()) / 1000)));
    }

    const fromPowerKey = watchers.fromPowerKey;

    const restartWatcherIfDead = watchers.restartWatcherIfDead;

    const fromUsbWatcher = watchers.fromUsbWatcher;

    const fromPowerWatcher = watchers.fromPowerWatcher;

    const powerWatcherDied = watchers.powerWatcherDied;

    pub const handle = gestures.handle;

    const screenX = gestures.screenX;

    const screenY = gestures.screenY;

    const onAxis = gestures.onAxis;

    const fingerUp = gestures.fingerUp;

    const lifted = gestures.lifted;

    const onPacketEnd = gestures.onPacketEnd;

    const touchedDown = gestures.touchedDown;
};




/// Opens touch and power, and takes the touchscreen from the stock UI.
pub fn open(width: u32, height: u32) !Input {
    // Found by what they report, as Kindles number them differently; this model's
    // numbers if nothing answers
    const found = devices.findInputs();
    var touch_buf: [24]u8 = undefined;
    var power_buf: [24]u8 = undefined;
    const touch_path = if (found.touch) |n| std.fmt.bufPrintSentinel(&touch_buf, "/dev/input/event{d}", .{n}, 0) catch evdev.touch_device else evdev.touch_device;
    const power_path = if (found.power) |n| std.fmt.bufPrintSentinel(&power_buf, "/dev/input/event{d}", .{n}, 0) catch evdev.power_device else evdev.power_device;
    std.debug.print("input: touch {s}, power {s}\n", .{ touch_path, power_path });
    const touch = try evdev.openInput(touch_path);
    const power = try evdev.openInput(power_path);
    if (failed(linux.ioctl(touch, eviocgrab, 1))) return error.GrabFailed;
    // The kernel only reports coordinates that change, so start from the current ones.
    var in = Input{
        .touch = touch,
        .power = power,
        .width = @intCast(width),
        .height = @intCast(height),
        .x_max = evdev.axisMax(touch, evdev.eviocgabs_x),
        .y_max = evdev.axisMax(touch, evdev.eviocgabs_y),
        .xs = evdev.slotValues(touch, evdev.abs_mt_x),
        .ys = evdev.slotValues(touch, evdev.abs_mt_y),
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

