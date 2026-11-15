//! Every screen of noface, and the one loop that runs them. The library is at the
//! root of a stack of screens; a book opens over it, and a card, a sheet, a list, the
//! keyboard, the lock screen or a finger being followed opens over either. The one in
//! front gets every action, but for a lock or a stop, which ends the screens in front
//! of the first that takes it (`takes`). Each action goes to exactly one screen.
//!
//!     var go_to = goto.make(...);                         // Kept in the screen under it
//!     return .{ .push = screen.open(&go_to, &ending) };   // Opens it over that one
//!     ...
//!     pub fn on_resume(s) ... // It ended: `ending` says how (done, closed, interrupted)
//!
//! A screen is a struct that says what makes it different, and nothing else (its
//! functions `pub`, as they're called from here):
//!
//!   - `pub const Result = T;` what it gives back when it's done (`void` for none).
//!   - `pub const touches: Input.Modes = ...;` how it takes touches, usually
//!     `Input.Modes.sheet`. Optional: without it, touches stay as they were.
//!   - `pub const tick_us: u64 = ...;` a tick this often, for a screen that changes on
//!     its own. Optional: without it, no ticks.
//!   - `pub fn setting(s) Input.Scope` in place of both, for a screen whose touches or
//!     tick change as it's used (the library, a book, the lock screen).
//!   - `pub const takes: Takes = ...;` the lock, or leaving, for a screen that handles
//!     them itself rather than ending (the library, a book, the lock screen).
//!   - `fn draw(s, part: Part) !void` draws it: all of it, or what changes as it's used.
//!   - `fn on_tap(s, Tap) !Step(Result)` what a tap does.
//!   - `fn on_tick(s) !Step(Result)` what a tick does, if it asks for ticks.
//!   - `fn on_action(s, Action) !Step(Result)` holds, swipes and drags, if it cares.
//!   - `fn on_open(s) !Step(Result)` called once it's drawn as it opens, for a screen
//!     that only leads to others (a book's actions, setting a series): it opens its
//!     first at once.
//!   - `fn on_resume(s) !Step(Result)` the screen it opened over itself has ended.
//!
//! Anything else `pub` on it, or a name spelled wrong (`onTik`), doesn't compile, nor
//! does a tick without `on_tick`: a screen can't quietly miss what it meant to handle.
//! Helpers of its own stay private. The test at the end of this file is a screen to
//! copy from.
//!
//! A screen is drawn whole as it opens, and then as each step asks. When the Kindle
//! locks or noface is told to leave, the screens in front of the one that takes it end
//! `interrupted`, each one under them resuming in turn (to put back what a card
//! covered, say), and the one that takes it gets the action. Touches and the tick are
//! the screen in front's, set before each wait.
const std = @import("std");
const assert = std.debug.assert;
/// Which screen opened, which ended and what ended it: noface.log on the Kindle, quiet
/// in the unit tests.
const log = std.log.scoped(.screen);
const app = @import("../app.zig");
const input_mod = @import("../kindle/input.zig");
const os = @import("../sys/os.zig");

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
        /// Open another screen over it (see `open`); when that one ends, this one's
        /// `on_resume` is called.
        push: Frame,
    };
}

/// What a screen may declare `pub`.
const hooks = [_][]const u8{
    "Result",
    "touches",
    "tick_us",
    "takes",
    "draw",
    "setting",
    "on_tap",
    "on_tick",
    "on_action",
    "on_resume",
    "on_open",
};

/// The actions that end the screens in front of the one that takes them: the Kindle
/// locking, and noface being told to leave. Only a screen that says so (`takes`) gets
/// them; every one in front of it is ended first, `interrupted` by the action.
pub const Takes = struct { lock: bool = false, leave: bool = false };

/// Whether a screen that takes `t` gets `action`, which ends the ones in front of it.
fn takes_it(t: Takes, action: Action) bool {
    return switch (action) {
        .lock => t.lock,
        .power, .computer, .stop => t.leave,
        else => false,
    };
}

/// Whether `action` ends the screens in front of the one that takes it.
fn interrupts(action: Action) bool {
    const all = Takes{ .lock = true, .leave = true };
    return takes_it(all, action);
}

/// The most screens open at once, each over the one before: the library, a book, a
/// card over it, a list from the card, a list from that, the keyboard, and the lock
/// screen over them all, with room to spare.
pub const depth_max = 8;

comptime {
    // The library and a book, at least, with something over them
    assert(depth_max >= 3);
    assert(interrupts(.lock));
    assert(!interrupts(.unlock));
    assert(!interrupts(.{ .tap = .{ .x = 0, .y = 0, .us = 0 } }));
}

/// An open screen, whatever its type: where it is, where its ending goes, and how
/// it's run. Made by `open`, kept on the stack while the screen is up.
pub const Frame = struct {
    screen: *anyopaque,
    ending: *anyopaque,
    kind: *const Kind,
    /// The touches of the screen it opened over, kept when it opens.
    inherited: ?input_mod.Input.Modes = null,

    /// What `run_root` needs of a screen, for its type.
    const Kind = struct {
        name: []const u8,
        takes: Takes,
        /// Its own touches, or null to keep those of the screen it opens over.
        touches: ?input_mod.Input.Modes,
        tick_us: u64,
        resumes: bool, // It has `on_resume`, so it may open others
        opens: bool, // It has `on_open`, called once it's drawn as it opens
        call: *const fn (screen: *anyopaque, ending: *anyopaque, c: Call) anyerror!Turn,
        setting: ?*const fn (screen: *anyopaque) input_mod.Input.Scope,
    };

    /// What `run_root` asks of a screen: draw it, hand it an action, tell it it has
    /// opened or the one over it ended, or end it, interrupted by a lock or a stop it
    /// doesn't take.
    const Call = union(enum) {
        draw: Part,
        act: Action,
        open,
        @"resume",
        interrupt: Action,
    };

    fn draw(f: *const Frame, part: Part) !void {
        assert(f.kind.name.len > 0);
        const t = try f.kind.call(f.screen, f.ending, .{ .draw = part });
        // Drawing changes nothing but the screen
        assert(t == .stay);
    }
};

/// A step with its result kept: what the stack does next.
const Turn = union(enum) { stay, redraw: Part, push: Frame, end };

/// Screen `s`, to open with `.push` (or `run_root`): how it ends is written to
/// `ending`, null until then, for the screen under it to read in its `on_resume`.
pub fn open(s: anytype, ending: *?Ending(@TypeOf(s.*).Result)) Frame {
    const S = @TypeOf(s.*);
    comptime check(S);
    ending.* = null;
    const kind = &Kinds(S).kind;
    assert(kind.name.len > 0);
    assert(ending.* == null);
    return .{ .screen = s, .ending = ending, .kind = kind };
}

/// What runs a screen of type `S` through `Frame`.
fn Kinds(comptime S: type) type {
    const R = S.Result;
    return struct {
        const kind = Frame.Kind{
            .name = short_name(@typeName(S)),
            .takes = if (@hasDecl(S, "takes")) S.takes else .{},
            .touches = if (@hasDecl(S, "touches")) S.touches else null,
            .tick_us = if (@hasDecl(S, "tick_us")) S.tick_us else 0,
            .resumes = @hasDecl(S, "on_resume"),
            .opens = @hasDecl(S, "on_open"),
            .call = call,
            .setting = if (@hasDecl(S, "setting")) setting else null,
        };

        /// Calls the hook for `c`, and keeps how the screen ended, if it did, where the
        /// screen under it reads it.
        fn call(screen: *anyopaque, ending: *anyopaque, c: Frame.Call) anyerror!Turn {
            const s: *S = @ptrCast(@alignCast(screen));
            const e: *?Ending(R) = @ptrCast(@alignCast(ending));
            // A screen still up hasn't ended, and ends once
            assert(e.* == null);
            const step: Step(R) = switch (c) {
                .draw => |part| {
                    try s.draw(part);
                    return .stay;
                },
                .act => |action| switch (action) {
                    .tap => |t| try s.on_tap(t),
                    .tick => if (@hasDecl(S, "on_tick")) try s.on_tick() else .stay,
                    else => if (@hasDecl(S, "on_action")) try s.on_action(action) else .stay,
                },
                .@"resume" => if (@hasDecl(S, "on_resume")) try s.on_resume() else unreachable,
                .open => if (@hasDecl(S, "on_open")) try s.on_open() else unreachable,
                .interrupt => |action| {
                    e.* = .{ .interrupted = action };
                    log_ending(kind.name, "interrupted", c);
                    return .end;
                },
            };
            switch (step) {
                .stay => return .stay,
                .redraw => |p| return .{ .redraw = p },
                .push => |f| {
                    // Only a screen that hears how the one it opens ends may open one
                    assert(@hasDecl(S, "on_resume"));
                    return .{ .push = f };
                },
                .done => |result| e.* = .{ .done = result },
                .close => e.* = .closed,
            }
            assert(e.* != null);
            log_ending(kind.name, @tagName(e.*.?), c);
            return .end;
        }

        fn setting(screen: *anyopaque) input_mod.Input.Scope {
            const s: *S = @ptrCast(@alignCast(screen));
            const scope = s.setting();
            // Only the lock screen is up while the Kindle sleeps, and it takes the lock
            if (scope.locked) assert(kind.takes.lock);
            if (scope.grip_exempt) |zone| assert(zone.w >= 0);
            return scope;
        }
    };
}

/// Logs how screen `name` ended, and by what: a tap's place, so a log tells which
/// screen each tap went to.
fn log_ending(name: []const u8, how: []const u8, c: Frame.Call) void {
    assert(name.len > 0);
    assert(how.len > 0);
    const action = switch (c) {
        .act, .interrupt => |action| action,
        .draw, .open, .@"resume" => {
            log.info("screen: {s} {s}", .{ name, how });
            return;
        },
    };
    switch (action) {
        .tap => |t| log.info("screen: {s} {s} by tap {d},{d}", .{ name, how, t.x, t.y }),
        else => log.info("screen: {s} {s} by {s}", .{ name, how, @tagName(action) }),
    }
}

/// The last part of a type's name: `Stats` of `screens.stats.Stats`, and `Drag` of
/// `app.Drag(screens.panel.Follow)`.
fn short_name(comptime full: []const u8) []const u8 {
    const plain = comptime full[0 .. std.mem.indexOfScalar(u8, full, '(') orelse full.len];
    const dot = comptime std.mem.lastIndexOfScalar(u8, plain, '.');
    const name = if (dot) |d| plain[d + 1 ..] else plain;
    comptime assert(name.len > 0);
    comptime assert(name.len <= full.len);
    return name;
}

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
    // Ticks come every `tick_us`, or as `setting` says
    const ticks = @hasDecl(S, "tick_us") or @hasDecl(S, "setting");
    if (ticks != @hasDecl(S, "on_tick")) {
        @compileError(name ++ ": `tick_us` (or `setting`) and `on_tick` go together");
    }
    if (@hasDecl(S, "touches") and @TypeOf(S.touches) != input_mod.Input.Modes) {
        @compileError(name ++ ": `touches` is an Input.Modes");
    }
    if (@hasDecl(S, "takes") and @TypeOf(S.takes) != Takes) {
        @compileError(name ++ ": `takes` is a screen.Takes");
    }
    // A screen that sets its input itself says it all there
    if (@hasDecl(S, "setting") and (@hasDecl(S, "touches") or @hasDecl(S, "tick_us"))) {
        @compileError(name ++ ": `setting` says the touches and the tick itself");
    }
}

/// A screen opened over another, kept by the one under it together with how it ended:
/// what a parent holds of each screen it opens, in one place, so the two can't part.
pub fn Child(comptime S: type) type {
    return struct {
        const C = @This();
        screen: S,
        ending: ?Ending(S.Result) = null,

        /// The frame to open it with: its ending is written here.
        pub fn frame(c: *C) Frame {
            const f = open(&c.screen, &c.ending);
            assert(c.ending == null);
            return f;
        }

        /// How it ended, once it has.
        pub fn ended(c: *const C) Ending(S.Result) {
            return c.ending orelse unreachable; // Only asked once its parent resumes
        }
    };
}

/// How a screen ended.
pub fn Ending(comptime Result: type) type {
    return union(enum) {
        done: Result, // Finished, with this result
        closed, // Cancelled, or tapped outside it
        /// The Kindle locked, or noface was told to leave: taken by a screen underneath.
        interrupted: Action,
    };
}

/// The screens open, each over the one before; the last is in front, and takes every
/// action but those a screen under it takes (`Takes`).
const Stack = struct {
    frames: [depth_max]Frame = undefined,
    input: *input_mod.Input,
    depth: u32 = 0,
    changes: u32 = 0, // Screens opened and ended, counting on (wrapping)
    /// When the screen in front was put up: a tap touched before then wasn't meant
    /// for it.
    shown_us: u64 = 0,

    /// The most turns settling one action can take: each opens or ends a screen, but
    /// for the last, and a screen ended may have one opened in its place a few times.
    const settle_turns_max = 4 * depth_max;
    /// The most turns ending the screens in front of one taking a lock or a stop: a
    /// screen under one ended may open another, which ends at once, a few times.
    const unwind_turns_max = 4 * depth_max;

    fn top(stack: *const Stack) *const Frame {
        assert(stack.depth > 0);
        assert(stack.depth <= depth_max);
        return &stack.frames[stack.depth - 1];
    }

    /// The input as the screen in front wants it.
    fn scope(stack: *const Stack) input_mod.Input.Scope {
        const f = stack.top();
        if (f.kind.setting) |setting| return setting(f.screen);
        // Without touches of its own, a screen keeps those it opened over, kept as it
        // opened
        assert(f.inherited != null);
        const modes = f.kind.touches orelse f.inherited.?;
        if (f.kind.touches) |own| assert(std.meta.eql(modes, own));
        return .{ .modes = modes, .tick_us = f.kind.tick_us };
    }

    /// Opens `f` in front, and draws it whole.
    fn push(stack: *Stack, a: *app.App, f: Frame) !void {
        assert(stack.depth < depth_max);
        assert(f.inherited == null);
        stack.frames[stack.depth] = f;
        stack.frames[stack.depth].inherited = a.input.modes(); // Those it opens over
        stack.depth += 1;
        stack.changes +%= 1;
        assert(stack.top().screen == f.screen);
        log.info("screen: {s} opened", .{f.kind.name});
        a.input.apply(stack.scope(), true);
        try f.draw(.all);
    }

    /// Takes the screen in front off, its ending written already.
    fn pop(stack: *Stack) Frame {
        assert(stack.depth > 0);
        const f = stack.top().*;
        stack.depth -= 1;
        stack.changes +%= 1;
        assert(stack.depth < depth_max);
        // The one under it takes input as it did, before it hears how this one ended
        if (stack.depth > 0) stack.input.apply(stack.scope(), false);
        return f;
    }

    /// Hands `action` to the screen that takes it: the one in front, or for a lock or a
    /// stop the first under it that takes those, the ones in front of it ended first.
    fn route(stack: *Stack, a: *app.App, action: Action) !void {
        assert(stack.depth > 0);
        const changes_before = stack.changes;
        defer if (stack.changes != changes_before) {
            // Another screen is in front, drawn: from now on taps are meant for it
            stack.shown_us = os.now_us();
        };
        if (interrupts(action)) try stack.unwind(action);
        if (stack.depth == 0) return; // The root ended as the screens over it did
        const f = stack.top().*;
        if (interrupts(action)) assert(takes_it(f.kind.takes, action));
        switch (action) {
            .tap => |t| if (t.us < stack.shown_us) {
                // The finger touched while another screen was in front: the tap was
                // meant for that one, which has ended, never for this one
                log.info("tap {d},{d} dropped: touched before {s} was shown", .{
                    t.x, t.y, f.kind.name,
                });
                return;
            },
            else => {},
        }
        // Exactly one screen gets it: the one in front, and only once
        try stack.settle(a, try f.kind.call(f.screen, f.ending, .{ .act = action }));
    }

    /// Does what the screen in front asked: and as each screen ends, what the one
    /// under it asks on resuming.
    fn settle(stack: *Stack, a: *app.App, first: Turn) !void {
        // A screen asked, but for the root as it opens, with none under it
        if (first != .push) assert(stack.depth > 0);
        var t = first;
        for (0..settle_turns_max) |_| {
            switch (t) {
                .stay => return,
                .redraw => |p| return stack.top().draw(p),
                .push => |f| {
                    try stack.push(a, f);
                    const opened = stack.top().*;
                    if (!opened.kind.opens) return;
                    // A screen that only leads to others opens its first at once
                    t = try opened.kind.call(opened.screen, opened.ending, .open);
                },
                .end => {
                    _ = stack.pop();
                    if (stack.depth == 0) return; // The root ended: noface is leaving
                    t = try stack.resume_top();
                },
            }
        }
        unreachable; // See `settle_turns_max`: every turn but the last opens or ends one
    }

    /// The screen in front again, the one over it ended.
    fn resume_top(stack: *Stack) !Turn {
        // One was just taken off over it
        assert(stack.depth < depth_max);
        const f = stack.top().*;
        // Only a screen that reads how the ones it opens end opens any
        assert(f.kind.resumes);
        return f.kind.call(f.screen, f.ending, .@"resume");
    }

    /// Ends every screen in front of the first that takes `action`, each `interrupted`
    /// by it, and lets the one under each do what it does on resuming: put back what
    /// was under a card, say. One it opens then is ended at once, never drawn.
    fn unwind(stack: *Stack, action: Action) !void {
        assert(interrupts(action));
        assert(stack.depth > 0);
        var ended = false; // The screen in front has ended on its own, resuming
        for (0..unwind_turns_max) |_| {
            if (!ended and takes_it(stack.top().kind.takes, action)) return;
            const f = stack.pop();
            if (!ended) {
                const t = try f.kind.call(f.screen, f.ending, .{ .interrupt = action });
                assert(t == .end);
            }
            if (stack.depth == 0) {
                // The root takes every interruption: it went only by ending itself
                assert(ended);
                return;
            }
            ended = false;
            switch (try stack.resume_top()) {
                .stay => {},
                .redraw => |p| try stack.top().draw(p),
                .push => |opened| {
                    // Opened as the Kindle locks or noface leaves: ended before it shows
                    assert(stack.depth < depth_max);
                    stack.frames[stack.depth] = opened;
                    stack.depth += 1;
                    stack.changes +%= 1;
                },
                .end => ended = true,
            }
        }
        unreachable; // See `unwind_turns_max`
    }
};

/// Runs `root` (the library) and everything it opens, one screen in front at a time,
/// until it ends: noface's event loop. Each action goes to exactly one screen.
pub fn run_root(a: *app.App, root: anytype) !Ending(@TypeOf(root.*).Result) {
    const R = @TypeOf(root.*).Result;
    comptime {
        // Nothing is under it to take a lock or a stop
        const takes: Takes = @TypeOf(root.*).takes;
        assert(takes.lock);
        assert(takes.leave);
    }
    var ending: ?Ending(R) = null;
    var stack = Stack{ .input = a.input };
    try stack.settle(a, .{ .push = open(root, &ending) });
    stack.shown_us = os.now_us();
    // Unbounded: noface's event loop, the only one, which runs for as long as the
    // reader reads: each turn waits once for something to happen, and hands what
    // happened, if anything, to the screen that takes it
    while (true) {
        a.input.apply(stack.scope(), false);
        const action = a.input.poll() orelse continue;
        try stack.route(a, action);
        if (stack.depth == 0) break;
    }
    assert(stack.depth == 0);
    return ending.?;
}

/// A screen to copy from: a counter that finishes on its third tap. A real one draws
/// in `draw` (see battery.zig, the smallest), and keeps what it shows in its fields.
const Example = struct {
    pub const Result = u32; // What it ends with when it's done
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

/// The root for the test: it opens an Example over itself at once, and ends with how
/// that one ended, or on a stop.
const ExampleRoot = struct {
    pub const Result = ?Ending(u32);
    pub const takes = Takes{ .lock = true, .leave = true };
    example: Example = .{},
    ending: ?Ending(u32) = null,

    pub fn draw(r: *ExampleRoot, part: Part) !void {
        assert(part == .all);
        assert(r.example.taps == 0);
    }

    pub fn on_open(r: *ExampleRoot) !Step(?Ending(u32)) {
        assert(r.example.taps == 0);
        assert(r.ending == null);
        return .{ .push = open(&r.example, &r.ending) };
    }

    pub fn on_resume(r: *ExampleRoot) !Step(?Ending(u32)) {
        assert(r.ending != null);
        assert(r.example.taps <= Example.taps_max);
        return .{ .done = r.ending };
    }

    pub fn on_tap(r: *ExampleRoot, _: Tap) !Step(?Ending(u32)) {
        assert(r.ending == null);
        unreachable; // The example is in front until it ends, and that ends this
    }

    pub fn on_action(r: *ExampleRoot, action: Action) !Step(?Ending(u32)) {
        assert(action == .stop); // The script runs out
        assert(r.ending != null); // The example ended first, interrupted by it
        return .{ .done = r.ending };
    }
};

test "a screen draws whole, takes taps until done, and gives back its result" {
    // Scripted taps move the test clock: the real one comes back after, for the tests that
    // follow
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
    var root = ExampleRoot{};
    const ended = (try run_root(&a, &root)).done.?;
    try std.testing.expectEqual(@as(u32, 3), ended.done);
    try std.testing.expectEqual(@as(u32, 1), root.example.drawn[0]); // Whole, once, first
    try std.testing.expectEqual(@as(u32, 2), root.example.drawn[1]);
    try std.testing.expectEqual(before, input.modes()); // Touches as they were
    // A script that runs out stops noface: the example ends interrupted, and the root
    // takes the stop
    var none = [_]input_mod.Step{};
    script = .{ .steps = &none };
    root = .{};
    const stopped = (try run_root(&a, &root)).done.?;
    try std.testing.expect(stopped.interrupted == .stop);
}
