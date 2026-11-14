//! A screen of its own over the library or a page: a card, a sheet, a list, a
//! keyboard. Every one works the same way, so this runs them all:
//!
//!     var go_to = GoTo{ ... };
//!     const page = try screen.run(a, &go_to) orelse return; // null: closed, or locked
//!
//! A screen is a struct that says what makes it different, and nothing else (its
//! functions `pub`, as they're called from here):
//!
//!   - `pub const Result = T;` what it gives back when it's done (`void` for none).
//!   - `pub const touches: Input.Modes = ...;` how it takes touches, usually
//!     `Input.Modes.sheet`. Optional: without it, touches stay as they were.
//!   - `pub const tick_us: u64 = ...;` a tick this often, for a screen that changes on
//!     its own. Optional: without it, no ticks.
//!   - `fn draw(s, part: Part) !void` draws it: all of it, or what changes as it's used.
//!   - `fn on_tap(s, Tap) !Step(Result)` what a tap does.
//!   - `fn on_tick(s) !Step(Result)` what a tick does, if it asks for ticks.
//!   - `fn on_action(s, Action) !Step(Result)` holds, swipes and drags, if it cares.
//!
//! Anything else `pub` on it, or a name spelled wrong (`onTik`), doesn't compile, nor
//! does a tick without `on_tick`: a screen can't quietly miss what it meant to handle.
//! Helpers of its own stay private. The test at the end of this file is a screen to
//! copy from.
//!
//! `run` draws it whole first, then waits and hands it each action, drawing what each
//! step asks for. When the Kindle locks or noface is told to leave, the screen closes
//! (`run` returns null) and the action is kept for the screen underneath, so it locks
//! or leaves in turn. Touch modes and the tick are put back as they were either way.
//! A caller that must tell "closed" from "locked or leaving" uses `run_to_end`.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../app.zig");
const input_mod = @import("../kindle/input.zig");

pub const Tap = input_mod.Tap;
pub const Action = input_mod.Action;

/// What to draw: everything (the first time, or after a big change), or only what
/// changes as the screen is used (a field, a list, a number), quicker and without
/// redrawing what stays, like a keyboard.
pub const Part = enum { all, changing };

/// What a screen wants after an action.
pub fn Step(comptime Result: type) type {
    return union(enum) {
        stay, // Nothing changed on screen
        redraw: Part, // Draw it again
        done: Result, // Finished, with this result
        close, // Finished with nothing: cancelled, or tapped outside it
    };
}

/// What a screen may declare `pub`.
const hooks = [_][]const u8{
    "Result",
    "touches",
    "tick_us",
    "draw",
    "on_tap",
    "on_tick",
    "on_action",
};

/// Fails the build when `S` isn't a screen as described above.
fn check(comptime S: type) void {
    const name = @typeName(S);
    for (std.meta.declarations(S)) |decl| {
        for (hooks) |h| {
            if (std.mem.eql(u8, decl, h)) break;
        } else @compileError(name ++ ": a screen has no `" ++ decl ++ "` (it may have " ++
            "Result, touches, tick_us, draw, on_tap, on_tick, on_action); make a helper private");
    }
    for ([_][]const u8{ "Result", "draw", "on_tap" }) |needed| {
        if (!@hasDecl(S, needed)) {
            @compileError(name ++ ": a screen needs a pub `" ++ needed ++ "`");
        }
    }
    if (@hasDecl(S, "tick_us") != @hasDecl(S, "on_tick")) {
        @compileError(name ++ ": `tick_us` and `on_tick` go together");
    }
    if (@hasDecl(S, "touches") and @TypeOf(S.touches) != input_mod.Input.Modes) {
        @compileError(name ++ ": `touches` is an Input.Modes");
    }
}

/// How a screen ended.
pub fn Ending(comptime Result: type) type {
    return union(enum) {
        done: Result, // Finished, with this result
        closed, // Cancelled, or tapped outside it
        /// The Kindle locked, or noface was told to leave: kept for the screen underneath.
        interrupted: Action,
    };
}

/// Runs screen `s` until it's done (its result), or closes or the Kindle locks (null).
pub fn run(a: *app.App, s: anytype) !?@TypeOf(s.*).Result {
    const modes_before = a.input.modes();
    const tick_before_us = a.input.tick_us;
    const ending = try run_to_end(a, s);
    // However it ended, touches and the tick are as they were before it opened
    assert(std.meta.eql(a.input.modes(), modes_before));
    assert(a.input.tick_us == tick_before_us);
    return switch (ending) {
        .done => |result| result,
        .closed, .interrupted => null,
    };
}

/// Runs screen `s`, saying how it ended.
pub fn run_to_end(a: *app.App, s: anytype) !Ending(@TypeOf(s.*).Result) {
    const S = @TypeOf(s.*);
    comptime check(S);
    const touches = if (@hasDecl(S, "touches")) S.touches else a.input.modes();
    const tick_us: u64 = if (@hasDecl(S, "tick_us")) S.tick_us else 0;
    const was = a.input.enter(touches, tick_us);
    defer a.input.leave(was);
    assert(std.meta.eql(a.input.modes(), touches));
    assert(a.input.tick_us == tick_us);

    var part: ?Part = .all;
    // Unbounded: a screen stays open for as long as the reader takes, until it's done
    while (true) {
        if (part) |p| try s.draw(p);
        part = null;
        // Locked, or leaving: the action is kept for the screen underneath
        const action = a.input.next_for() orelse return .{
            .interrupted = a.input.held_back().?,
        };
        // Those end the screen, and never reach it
        assert(action != .lock);
        assert(action != .stop);
        const step: Step(S.Result) = switch (action) {
            .tap => |t| try s.on_tap(t),
            .tick => if (@hasDecl(S, "on_tick")) try s.on_tick() else .stay,
            else => if (@hasDecl(S, "on_action")) try s.on_action(action) else .stay,
        };
        switch (step) {
            .stay => {},
            .redraw => |p| part = p,
            .done => |result| return .{ .done = result },
            .close => return .closed,
        }
    }
}

/// A screen to copy from: a counter that finishes on its third tap. A real one draws
/// in `draw` (see battery.zig, the smallest), and keeps what it shows in its fields.
const Example = struct {
    pub const Result = u32; // What `run` gives back when it's done
    pub const touches = input_mod.Input.Modes.sheet; // Optional: how it takes touches

    taps: u32 = 0,
    drawn: [2]u32 = .{ 0, 0 }, // How often each part was drawn, for the test

    const taps_max = 3; // Done on this tap

    /// `.all` the first time and when a step asks; `.changing` for what taps change.
    pub fn draw(e: *Example, part: Part) !void {
        // Done on the third tap, so never drawn after it
        assert(e.taps < taps_max);
        // Whole the first time, before any tap
        if (e.taps == 0) assert(part == .all);
        e.drawn[@backingInt(part)] += 1;
    }

    /// Every tap comes here; holds, swipes and ticks go to `on_action` and `on_tick`.
    pub fn on_tap(e: *Example, _: Tap) !Step(u32) {
        assert(e.taps < taps_max);
        e.taps += 1;
        assert(e.taps <= taps_max);
        if (e.taps == taps_max) return .{ .done = e.taps };
        return .{ .redraw = .changing };
    }
};

test "a screen draws whole, takes taps until done, and gives back its result" {
    // Scripted taps move the test clock: the real one comes back after, for the tests that
    // follow
    const os = @import("../sys/os.zig");
    defer os.fake_us = null;
    // Clear of the thumb zones
    const middle: input_mod.Step = .{ .act = .{ .tap = .{ .x = 600, .y = 800, .us = 0 } } };
    var steps = [_]input_mod.Step{ middle, middle, middle };
    var script = input_mod.Script{ .steps = &steps };
    var input = input_mod.Input{
        .touch = -1,
        .power = -1,
        .width = 1272,
        .height = 1696,
        .x_max = 1272,
        .y_max = 1696,
        .script = &script,
    };
    var a: app.App = undefined;
    a.input = &input;
    const before = input.modes();
    var e = Example{};
    try std.testing.expectEqual(@as(?u32, 3), try run(&a, &e));
    try std.testing.expectEqual(@as(u32, 1), e.drawn[0]); // Whole, once, first
    try std.testing.expectEqual(@as(u32, 2), e.drawn[1]);
    try std.testing.expectEqual(before, input.modes()); // Touches as they were
    // A script that runs out stops noface: the screen closes, and the stop is kept
    var none = [_]input_mod.Step{};
    script = .{ .steps = &none };
    e = .{};
    try std.testing.expect(try run(&a, &e) == null);
    try std.testing.expect(input.held_back().? == .stop);
}
