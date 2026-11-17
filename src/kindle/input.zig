//! Touch and power input: raw events in, taps, holds, drags and power changes out.
//! `Input` and how screens use it are here. How touches become actions is in
//! input/gestures.zig, what's heard besides touches in input/watchers.zig, and the
//! kernel's event format in input/evdev.zig.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const devices = @import("devices.zig");
const touch_zones = @import("touch.zig");

const failed = os.failed;
const now_us = os.now_us;

const evdev = @import("input/evdev.zig");
const gestures = @import("input/gestures.zig");
const watchers = @import("input/watchers.zig");
const process = @import("../sys/process.zig");
pub const eviocgrab = evdev.eviocgrab;
pub const should_tell_powerd = watchers.should_tell_powerd;
pub const power_pressed = watchers.power_pressed;
pub const beat_to = watchers.beat_to;
pub const turn_direction = gestures.turn_direction;
const InputEvent = evdev.InputEvent;

/// The longest a wait for input lasts before looking again, so ticks and a stop
/// request are seen within a second.
const wait_ms_max = 1000;
/// How often a press is looked at while it may yet become a hold.
const hold_poll_ms = 30;

/// Set by a signal; the loop reads it, as nothing is done inside a signal handler.
var stop_requested = std.atomic.Value(bool).init(false);

fn on_signal(signal: linux.SIG) callconv(.c) void {
    assert(signal == .TERM or signal == .INT or signal == .HUP);
    stop_requested.store(true, .release);
}

pub fn install_signals() void {
    var action = std.mem.zeroes(linux.Sigaction);
    action.handler = .{ .handler = on_signal };
    for ([_]linux.SIG{ .TERM, .INT, .HUP }) |signal| {
        const rc = linux.sigaction(signal, &action, null);
        // Only KILL and STOP can't be caught, and a handler of ours is a valid address
        assert(!failed(rc));
    }
}

/// A tap: where, and when the finger touched (microseconds on the monotonic clock).
pub const Tap = struct { x: i32, y: i32, us: u64 };

/// A sideways stroke that lifted: `direction` 1 is on (leftwards), -1 back. `us` is
/// when the finger landed, as a tap's, so a turn by swipe is timed as one by tap.
pub const Swipe = struct { direction: i32, us: u64 };

pub const Action = union(enum) {
    tap: Tap,
    hold: struct { x: i32, y: i32 },
    pull,
    drag: Point, // Where a finger being followed is
    swipe: Swipe,
    drag_end,
    tick,
    charger, // A charger came or went: the status bar's bolt follows
    lock,
    unlock,
    power,
    computer, // Plugged into a computer for file transfer: the Kindle's own screens take over
    stop,
};

comptime {
    assert(wait_ms_max >= 1);
    // A hold is noticed within a small part of the time it takes
    assert(hold_poll_ms * 10 <= touch_zones.hold_ms);
    assert(hold_poll_ms < wait_ms_max);
}

/// What a scenario test does, in order: an action as the reader's finger or the power
/// button would give it, one made at the same moment as the one before (a second tap
/// while the app was still answering the first), or a wait on the virtual clock
/// (os.fake_us).
pub const Step = union(enum) { act: Action, act_queued: Action, wait_ms: u64 };

/// A scenario being played back. Waits deliver the ticks the app asked for, at the
/// times they'd come; once the steps run out the app is told to stop.
pub const Script = struct {
    steps: []const Step,
    at: u32 = 0,
    waiting_us: u64 = 0, // What's left of the current wait
    /// Called once, when the steps run out and before noface is told to stop: the
    /// screen as the script left it, for a test to keep.
    at_end: ?struct { ctx: *anyopaque, call: *const fn (ctx: *anyopaque) void } = null,
    ended: bool = false,
    touched_us: u64 = 0, // When the finger touched for the last action played

    fn next(script: *Script, in: *Input) Action {
        assert(script.at <= script.steps.len);
        // Each pass that doesn't return takes a step, and one with none left returns
        const passes_max = script.steps.len - script.at + 1;
        for (0..passes_max) |_| {
            if (script.waiting_us > 0) {
                if (script.next_tick(in)) |tick| return tick;
            }
            assert(script.waiting_us == 0);
            if (script.at >= script.steps.len) {
                if (!script.ended) {
                    if (script.at_end) |at_end| at_end.call(at_end.ctx);
                }
                script.ended = true;
                return .stop;
            }
            const step = script.steps[script.at];
            script.at += 1;
            switch (step) {
                .act => |action| {
                    if (script.touch(in, action, now_us())) |touched| return touched;
                },
                .act_queued => |action| {
                    if (script.touch(in, action, script.touched_us)) |touched| return touched;
                },
                .wait_ms => |ms| script.waiting_us = ms * 1000,
            }
        }
        unreachable; // See `passes_max`: the last pass always returns
    }

    /// `action` as the panel gives it, a tap stamped with when the finger touched
    /// (`touched_us`); null when the grip zones ignore it, as they would a finger.
    fn touch(script: *Script, in: *Input, action: Action, touched_us: u64) ?Action {
        assert(touched_us <= now_us());
        script.touched_us = touched_us;
        os.fake_us = now_us() + 1000; // A touch takes a moment
        var touched = action;
        switch (touched) {
            .tap => |*tap| {
                if (in.ignores(tap.x, tap.y)) return null;
                tap.us = touched_us;
            },
            .hold => |hold| if (in.ignores(hold.x, hold.y)) return null,
            else => {},
        }
        in.last_input = now_us();
        assert(in.last_input > touched_us);
        return touched;
    }

    /// Moves the virtual clock on through the current wait: to the next tick, if one
    /// falls inside it, or else to its end.
    fn next_tick(script: *Script, in: *Input) ?Action {
        assert(script.waiting_us > 0);
        const now = now_us();
        const tick_at = if (in.tick_us) |every| in.last_tick + every else std.math.maxInt(u64);
        if (tick_at <= now + script.waiting_us) {
            const step = tick_at -| now;
            assert(step <= script.waiting_us);
            os.fake_us = now + step;
            script.waiting_us -= step;
            in.last_tick = now_us();
            return .tick;
        }
        os.fake_us = now + script.waiting_us;
        script.waiting_us = 0;
        return null;
    }
};

/// A finger watched from where it touched: its slot, where and when it touched, and
/// whether it has moved off that place since.
pub const Press = struct { slot: u32, x: i32, y: i32, us: u64, moved: bool = false };

/// A place on the screen, in its pixels.
pub const Point = struct { x: i32, y: i32 };

/// An area of the screen, in screen pixels.
pub const Zone = struct { x: i32, y: i32, w: i32, h: i32 };

/// Turns raw touch events into taps.
/// The panel reports two slots. Every new finger counts, so a resting thumb
/// can't block taps from another finger.
pub const Input = struct {
    touch: i32,
    power: i32,
    /// The lipc-wait-event children whose lines are powerd's events (lock, unlock, the
    /// charger) and the volume manager's (a computer on USB), while they run.
    power_watcher: ?process.Child = null,
    usb_watcher: ?process.Child = null,
    heartbeat_us: u64 = 0, // When the watchdog last heard noface is alive
    width: i32,
    height: i32,
    x_max: i32,
    y_max: i32,
    events: [64]InputEvent = undefined,
    event_count: u32 = 0,
    event_next: u32 = 0,
    slot: u32 = 0,
    xs: [slots_count]i32 = .{ 0, 0 },
    ys: [slots_count]i32 = .{ 0, 0 },
    pending: ?u32 = null,
    down_us: u64 = 0,
    /// A finger down that may yet become a tap, a hold, a swipe or a pull, watched
    /// until it lifts, moves or is held.
    top: ?Press = null,
    deferred: bool = false, // On book pages: taps wait for lift, so a press can become a hold
    last_touched: u32 = 0,
    grips: bool = true, // Off while controls sit where a thumb usually rests
    edge_zones: bool = true, // Off while handles can sit at the screen edges
    tick_us: ?u64 = null, // How often `poll` returns .tick, or null for never
    last_tick: u64 = 0,
    drag_slot: ?u32 = null,
    last_input: u64 = 0,
    stashed: ?Action = null,
    locked: bool = false, // Nothing to check on a timer, so sleep until an event
    watcher_retry_us: u64 = 0, // When to restart a power-event watcher that died
    told_powerd_us: u64 = 0, // When powerd last heard the reader is active
    script: ?*Script = null, // Set in scenario tests: actions to play instead of the panel
    /// Set when powerd said a charger came or went: whoever shows the status bar reads it
    /// again and clears this.
    /// A control inside the grip zones (the reader's Back button): touches there count.
    grip_exempt: ?Zone = null,

    /// The touch slots the panel reports, one per finger.
    pub const slots_count = 2;

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

        comptime {
            assert(!sheet.grips);
            assert(!sheet.deferred);
        }
    };

    /// Everything about taking input that a screen sets for itself while it's open:
    /// how touches are taken, how often it ticks (null: never), a control exempt from the
    /// grip zones, and whether the Kindle is asleep under it (the lock screen).
    pub const Scope = struct {
        modes: Modes,
        tick_us: ?u64,
        grip_exempt: ?Zone = null,
        locked: bool = false,
    };

    /// Takes input as the screen in front says, from now on. `opened`: it has just come
    /// to the front, so its ticks count from now.
    pub fn apply(in: *Input, scope: Scope, opened: bool) void {
        in.take(scope.modes);
        in.tick_us = scope.tick_us;
        in.grip_exempt = scope.grip_exempt;
        in.locked = scope.locked;
        if (opened) in.last_tick = now_us();
        assert(in.locked == scope.locked);
        if (in.tick_us) |every| assert(every > 0); // A tick, when there is one, takes time
    }

    /// What holds of the input's state between any two calls: the events read are
    /// within the buffer, every finger is one of the panel's slots, and the panel's
    /// range is never empty (it's divided by).
    pub fn invariants(in: *const Input) void {
        assert(in.event_count <= in.events.len);
        assert(in.event_next <= in.event_count);
        assert(in.slot < slots_count);
        assert(in.last_touched < slots_count);
        if (in.pending) |slot| assert(slot < slots_count);
        if (in.top) |press| assert(press.slot < slots_count);
        if (in.drag_slot) |slot| assert(slot < slots_count);
        assert(in.x_max >= 1);
        assert(in.y_max >= 1);
    }

    pub fn modes(in: *const Input) Modes {
        return .{ .grips = in.grips, .deferred = in.deferred, .edge_zones = in.edge_zones };
    }

    /// Takes touches as `m` says, from now on.
    pub fn take(in: *Input, m: Modes) void {
        in.grips = m.grips;
        in.deferred = m.deferred;
        in.edge_zones = m.edge_zones;
        assert(std.meta.eql(in.modes(), m));
    }

    /// Keeps `action` back, for the next call to `poll`: a lock noface starts under,
    /// say.
    pub fn hold_back(in: *Input, action: Action) void {
        in.stashed = action;
    }

    pub const ignores = gestures.ignores;

    /// How long to wait for input with a tick due: no longer than until the tick, so a
    /// short one (a double tap's window) isn't stretched, and no longer than a second.
    fn wait_ms_for_tick(in: *const Input, now: u64) i32 {
        const every = in.tick_us orelse return wait_ms_max;
        const until_tick_ms = (in.last_tick + every -| now) / 1000;
        const wait_ms_tick: i32 = @intCast(@max(1, @min(wait_ms_max, until_tick_ms)));
        assert(wait_ms_tick >= 1);
        assert(wait_ms_tick <= wait_ms_max);
        return wait_ms_tick;
    }

    const news_waiting = watchers.news_waiting;

    const beat = watchers.beat;

    const unlocked = watchers.unlocked;

    const start_usb_watcher = watchers.start_usb_watcher;

    const start_watcher = watchers.start_watcher;

    /// The most reads of the panel one call takes in: each holds up to 64 events, so
    /// this is minutes of a finger moving without a pause.
    const panel_reads_max = 4096;

    /// The next action from touch events already waiting, reading more only when the
    /// panel has them ready. Null once nothing more is waiting.
    fn waiting(in: *Input) ?Action {
        in.invariants();
        for (0..panel_reads_max) |_| {
            while (in.event_next < in.event_count) {
                const event = in.events[in.event_next];
                in.event_next += 1;
                if (in.handle(event)) |action| return action;
            }
            assert(in.event_next == in.event_count);
            const buffer_size = @sizeOf(@TypeOf(in.events));
            const n = linux.read(in.touch, @ptrCast(&in.events), buffer_size);
            if (failed(n) or n < @sizeOf(InputEvent)) return null;
            assert(n <= buffer_size);
            in.event_count = @intCast(n / @sizeOf(InputEvent));
            in.event_next = 0;
            in.last_input = now_us();
        }
        // Still more: what's read so far is handled, and the caller's poll finds the
        // rest waiting and comes straight back
        return null;
    }

    /// Follows the finger of the last tap until it lifts.
    pub fn begin_drag(in: *Input) void {
        assert(in.last_touched < slots_count);
        in.drag_slot = in.last_touched;
    }

    /// Skips to the newest finger position already waiting, if any.
    /// Anything else that turns up is kept for the next call to `poll`.
    pub fn latest_drag(in: *Input) ?Point {
        var latest: ?Point = null;
        while (in.stashed == null) {
            const action = in.waiting() orelse return latest;
            switch (action) {
                .drag => |point| latest = point,
                else => in.stashed = action,
            }
        }
        // Stopped by something other than a drag, kept for the next call to `poll`
        assert(in.stashed != null);
        return latest;
    }

    /// Sums page-turn taps already waiting, so fast tapping jumps instead of lagging.
    /// Anything else that turns up is kept for the next call to `poll`.
    pub fn take_turns(in: *Input) i32 {
        var delta: i32 = 0;
        while (in.stashed == null) {
            const action = in.waiting() orelse return delta;
            switch (action) {
                .tap => |tap| {
                    if (tap.y < touch_zones.top_zone) {
                        in.stashed = action;
                    } else {
                        delta += turn_direction(tap.x, in.width);
                    }
                },
                else => in.stashed = action,
            }
        }
        // Stopped by something other than a page turn, kept for the next call to `poll`
        assert(in.stashed != null);
        return delta;
    }

    /// The next action, if one comes: a touch, the power button, the Kindle locking or
    /// waking, a USB computer, a tick of the timer, or a request to stop. Waits once,
    /// until something happens or the next tick is due, and returns null when that was
    /// nothing to act on: one turn of noface's event loop (screens/screen.zig).
    pub fn poll(in: *Input) ?Action {
        in.invariants();
        if (in.ready()) |action| return action;
        in.keep_alive();
        in.wait_for_events();
        if (in.from_power_key()) |action| return action;
        if (in.restart_watcher_if_dead()) |action| return action;
        if (in.from_usb_watcher()) |action| return action;
        return in.from_power_watcher();
    }

    /// An action already known, without waiting: a request to stop, one kept back for
    /// the next call, the tests' script, touches already read, a
    /// press held long enough to be a hold, or a tick that's due.
    fn ready(in: *Input) ?Action {
        if (stop_requested.load(.acquire)) return .stop;
        if (in.stashed) |action| {
            in.stashed = null;
            return action;
        }
        if (in.script) |script| return script.next(in);
        if (in.waiting()) |action| return action;
        if (in.held_long_enough()) |action| return action;
        return in.tick_due();
    }

    const held_long_enough = gestures.held_long_enough;

    /// A tick, if one is due. It waits for powerd and USB news already in: with short
    /// ticks (a book laid out in idle moments) they'd otherwise go unread for seconds.
    fn tick_due(in: *Input) ?Action {
        const every = in.tick_us orelse return null;
        const now = now_us();
        assert(in.last_tick <= now);
        if (now - in.last_tick < every) return null;
        if (in.news_waiting()) return null;
        in.last_tick = now_us();
        return .tick;
    }

    const keep_alive = watchers.keep_alive;

    /// Sleeps until a touch or a watcher has something, or the next tick is due. Locked,
    /// with nothing to tick, it sleeps on (waking now and then to restart a dead watcher).
    fn wait_for_events(in: *Input) void {
        // The power key matters only while locked with no watcher, as the way to unlock
        const key_fd = if (in.locked and in.power_watcher == null) in.power else -1;
        var fds = [_]linux.pollfd{
            .{ .fd = in.touch, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = watchers.fd_of(in.power_watcher), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = watchers.fd_of(in.usb_watcher), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = key_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        // Woken, timed out or interrupted, the loop looks at every source alike
        _ = linux.poll(&fds, fds.len, in.wait_ms());
    }

    fn wait_ms(in: *const Input) i32 {
        if (in.top != null) return hold_poll_ms; // A press that may become a hold
        if (in.locked and in.tick_us == null) {
            return if (in.power_watcher == null) watchers.watcher_retry_ms else -1;
        }
        const wait = in.wait_ms_for_tick(now_us());
        assert(wait >= 1);
        return wait;
    }

    const from_power_key = watchers.from_power_key;

    const restart_watcher_if_dead = watchers.restart_watcher_if_dead;

    const from_usb_watcher = watchers.from_usb_watcher;

    const from_power_watcher = watchers.from_power_watcher;

    const power_watcher_died = watchers.power_watcher_died;

    pub const handle = gestures.handle;

    const screen_point = gestures.screen_point;

    const on_axis = gestures.on_axis;

    const finger_up = gestures.finger_up;

    const lifted = gestures.lifted;

    const on_packet_end = gestures.on_packet_end;

    const touched_down = gestures.touched_down;
};

/// The device file of input device `number`, or `fallback` when none was found.
fn open_path(buffer: []u8, number: ?u8, fallback: [:0]const u8) [:0]const u8 {
    // Room for any u8's three digits and the closing zero, so the fallback below is
    // only ever taken when nothing was found
    assert(buffer.len >= "/dev/input/event".len + 3 + 1);
    assert(fallback.len > 0);
    const found = number orelse return fallback;
    const format = "/dev/input/event{d}";
    return std.fmt.bufPrintSentinel(buffer, format, .{found}, 0) catch fallback;
}

/// Opens touch and power, and takes the touchscreen from the stock UI.
pub fn open(width: u32, height: u32) !Input {
    // Found by what they report, as Kindles number them differently; this model's
    // numbers if nothing answers
    const found = devices.find_inputs();
    var touch_buffer: [24]u8 = undefined;
    var power_buffer: [24]u8 = undefined;
    const touch_path = open_path(&touch_buffer, found.touch, evdev.touch_device);
    const power_path = open_path(&power_buffer, found.power, evdev.power_device);
    std.debug.print("input: touch {s}, power {s}\n", .{ touch_path, power_path });
    // Let go of on the way out of a failed open: closing ends a grab too
    const touch = try evdev.open_input(touch_path);
    errdefer _ = linux.close(touch); // Only read, never written: nothing is lost
    const power = try evdev.open_input(power_path);
    errdefer _ = linux.close(power); // Only read, never written: nothing is lost
    assert(touch != power);
    if (failed(linux.ioctl(touch, eviocgrab, 1))) return error.GrabFailed;
    // The kernel only reports coordinates that change, so start from the current ones.
    var in = Input{
        .touch = touch,
        .power = power,
        .width = @intCast(width),
        .height = @intCast(height),
        .x_max = evdev.axis_max(touch, evdev.eviocgabs_x),
        .y_max = evdev.axis_max(touch, evdev.eviocgabs_y),
        .xs = evdev.slot_values(touch, evdev.abs_mt_x),
        .ys = evdev.slot_values(touch, evdev.abs_mt_y),
        .last_input = now_us(),
    };
    in.invariants();
    in.start_watcher();
    in.start_usb_watcher();
    return in;
}

/// Gives the touchscreen back to the stock UI.
pub fn release(in: *const Input) void {
    // Only an Input from `open` has devices to give back: not a test's
    assert(in.touch >= 0);
    assert(in.script == null);
    // On the way out: if the grab won't let go, closing the device does it anyway
    _ = linux.ioctl(in.touch, eviocgrab, 0);
    for ([_]?process.Child{ in.power_watcher, in.usb_watcher }) |watcher| {
        const w = watcher orelse continue;
        // A watcher already gone needs neither: both are only to leave no child behind
        _ = linux.kill(w.pid, linux.SIG.TERM);
        var status: i32 = 0;
        _ = linux.waitpid(w.pid, &status, 0);
    }
}

// A pretend panel, the size of the screen, with no devices behind it.
