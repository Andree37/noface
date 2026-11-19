//! Following a dragged finger as a screen of its own, over the one the drag began on.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../app.zig");
const input_mod = @import("../kindle/input.zig");
const screen = @import("screen.zig");

/// Follows the dragged finger until it lifts, as a screen over the one the drag began
/// on (`screen.open`), made with the update that drew where it began (`marker`).
/// `follow.moved(x, y)` redraws for a new position and returns the update to wait on,
/// or null when nothing changed. Only one update runs at a time: overlapping ones
/// smear on the panel. Done when the finger lifts; interrupted when the Kindle locks.
/// Once it has ended, `ended` waits for its last update.
pub fn Drag(comptime Follow: type) type {
    // What the drag calls on each move: a function of the new place
    comptime assert(@hasDecl(Follow, "moved"));
    comptime assert(@typeInfo(@TypeOf(Follow.moved)) == .@"fn");
    return struct {
        const D = @This();
        pub const Result = void;
        a: *app.App,
        follow: Follow,
        marker: ?u32,

        /// The finger of the touch that opened it is the one followed from now on.
        pub fn on_open(d: *D) !screen.Step(void) {
            d.a.input.begin_drag();
            if (d.marker) |m| assert(m < d.a.display.screen.next_marker);
            return .stay;
        }

        /// Where it began is drawn as it begins.
        pub fn draw(d: *D, part: screen.Part) !void {
            assert(part == .all);
            if (d.marker) |m| assert(m < d.a.display.screen.next_marker);
        }

        /// A tap while a finger is followed: nothing to do.
        pub fn on_tap(d: *D, _: screen.Tap) !screen.Step(void) {
            if (d.marker) |m| assert(m < d.a.display.screen.next_marker);
            assert(d.a.input.tick_us == null); // It never ticks
            return .stay;
        }

        pub fn on_action(d: *D, action: input_mod.Action) !screen.Step(void) {
            assert(d.a.input.tick_us == null); // It never ticks
            switch (action) {
                .drag => |first| {
                    if (d.marker) |m| try d.a.display.screen.wait_complete(m);
                    const at = d.a.input.latest_drag() orelse first;
                    d.marker = try d.follow.moved(at.x, at.y);
                    if (d.marker) |m| assert(m < d.a.display.screen.next_marker);
                    return .stay;
                },
                .drag_end => return .{ .done = {} },
                // A finger is followed until it lifts: nothing else it does counts
                .hold, .pull, .swipe, .charger, .unlock => return .stay,
                // Taps and ticks have hooks of their own, and a lock or a leaving ends
                // the drag before it could come here (it takes neither)
                .tap, .tick, .lock, .power, .computer, .stop => unreachable,
            }
        }
    };
}

/// A drag that has ended: its last update waited for. True when the finger lifted,
/// false when the drag was cut short (the Kindle locking, say).
pub fn ended(d: anytype, ending: screen.Ending(void)) !bool {
    if (d.marker) |m| {
        assert(m < d.a.display.screen.next_marker);
        try d.a.display.screen.wait_complete(m);
    }
    d.marker = null;
    // A drag ends when the finger lifts, or the Kindle locks or noface leaves
    assert(ending != .closed);
    return ending == .done;
}
