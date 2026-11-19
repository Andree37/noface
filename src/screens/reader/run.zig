//! Running mode over an open book: reading on a treadmill. A bouncing head loses its
//! line on a page, so running shows no page: the book a phrase at a time
//! (model/phrases.zig), a sentence or so, large and bold at one fixed spot, each
//! changing to the next at the reader's running pace (model/running.zig) in a single
//! refresh, the text standing still between: e-ink can't move text smoothly, each
//! frame taking a tenth of a second and more. The end of the phrase before is above
//! it and the start of the one after below, small, and a small map of the page in the
//! corner marks where it is on it. Under them, the pause button with the pace beside
//! it, and a dial filling over the phrase's time beside the minutes left in the
//! chapter, an arrow in it when the pace has just gone up or down. The reader
//! (screens/reader.zig) routes taps and ticks here while it's on, and moves its place
//! along as the phrases do. Here is what running does: the phrases, their timing, going
//! back, the pace and what a tap means; how it looks is run_view.zig's.
const std = @import("std");
const assert = std.debug.assert;
const running_model = @import("../../model/running.zig");
const phrases = @import("../../model/phrases.zig");
const book_model = @import("../../model/book.zig");
const card = @import("../../ui/card.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const view = @import("run_view.zig");
const lipc = @import("../../kindle/lipc.zig");

/// A touch while running: when the panel says it came down, and how long it stayed
/// (null for a hold or a swipe, down long already).
pub const Touch = struct { touched_us: u64, held_us: ?u64 = null };

/// Earlier phrases kept, for going back to.
const history_max = 32;
/// How often the reader ticks while running: often, so each phrase changes on time.
pub const tick_us = 100 * std.time.us_per_ms;
/// The band at the top of the screen whose taps pause: bigger than the toolbar's, as a
/// hand mid-stride lands less precisely.
pub const pause_band_px = 300;

comptime {
    assert(tick_us < phrases.phrase_us_min);
    assert(pause_band_px < view.phrase_middle_y);
}

/// Running, over the open book.
pub const Run = struct {
    started_us: u64, // When running began, for the time run
    last_touch_us: u64 = 0, // The last touch that acted, so a bump right after is let go
    /// The phrase on screen; null at the book's end.
    phrase: ?phrases.Phrase = null,
    /// When the phrase came up with its timer going; null until the next tick shows
    /// the whole screen again: as running starts, and after the toolbar, the pause card
    /// or the lock covered it.
    shown_us: ?u64 = null,
    phrase_us: u64 = 0, // How long the phrase on screen stays up
    /// Stopped on its phrase, its timer this far in, until the button or a tap carries
    /// on: paused, or at the book's end.
    stopped_at: ?u64 = null,
    /// Where earlier phrases started, the latest last, for going back.
    history: [history_max]book_model.Pos = undefined,
    history_len: u32 = 0,
    dial_x: i32 = 0, // The dial's centre, which follows the minutes left beside it
    dial_step: u32 = 0, // How far the dial has swept over the phrase's time
    /// Which way the reader's tap just moved the pace: shown in the dial while the
    /// phrase that tap brought up is on screen.
    pace_moved: ?Pace = null,
    /// Where what's on screen is in the book: the phrase's start, or past the last
    /// phrase at the book's end. The reader's place follows it.
    place: ?book_model.Pos = null,
    /// The Kindle held awake, as running last asked (lipc.hold_awake).
    awake: bool = false,

    pub const Pace = enum { up, down };

    /// What a tap asks of the reader, beyond what running did itself: nothing more,
    /// the pause card, or the reader's place to follow the phrase it brought up before
    /// it's shown (`show_moved`).
    pub const Tapped = union(enum) { nothing, card, moved: book_model.Pos };

    /// What a move did: the place of what's on screen now, to follow and show
    /// (`show_moved`), or null when nothing moved.
    pub const Moved = ?book_model.Pos;

    /// The whole screen: the phrase at `from`, or the first after it, the clock above
    /// and the footer below, cleanly, with a flash.
    pub fn show_all(
        run: *Run,
        a: *app.App,
        s: *sess.Session,
        from: book_model.Pos,
        now: u64,
    ) !void {
        assert(from.para < s.paragraphs.len); // The reader's place, inside the book
        // Put back where it was, it goes on with its phrases; anywhere else (the
        // reader jumped, from the toolbar), the phrases before it aren't these
        if (run.place) |place| {
            if (place.para != from.para or place.byte != from.byte) run.history_len = 0;
        }
        try run.set_phrase(a, s, from);
        run.dial_x = try view.show_whole(run, a, s);
        run.start_timer(a, now);
        assert(run.shown_us == now);
        assert(run.place != null);
        std.debug.print("running: phrases from {d}:{d}\n", .{ from.para, from.byte });
    }

    /// The phrase on screen's timer started, or stopped at the book's end.
    fn start_timer(run: *Run, a: *const app.App, now: u64) void {
        assert(a.running_pace != null); // Set as running began
        run.shown_us = now;
        const p = run.phrase orelse {
            run.stopped_at = 0;
            return;
        };
        run.phrase_us = phrases.phrase_us(a.running_pace.?, p);
        assert(run.phrase_us >= phrases.phrase_us_min);
    }

    /// The timer gone on: the next phrase when this one's time is up.
    pub fn tick(run: *Run, a: *app.App, s: *sess.Session, now: u64) !Moved {
        const shown = run.shown_us orelse {
            try run.show_all(a, s, s.anchor, now);
            return null;
        };
        if (run.stopped_at != null) return null;
        // A phrase on screen with its timer going has a time to stay
        assert(run.phrase != null);
        assert(run.phrase_us >= phrases.phrase_us_min);
        const elapsed = now -| shown;
        if (elapsed >= run.phrase_us) {
            run.pace_moved = null; // Moving on by itself: the pace stays
            return try run.forward(a, s, now);
        }
        const step: u32 = @intCast(elapsed * view.dial_steps / run.phrase_us);
        assert(step < view.dial_steps);
        if (step != run.dial_step) {
            run.dial_step = step;
            try view.show_dial(a, run.dial_x, step, run.pace_moved);
        }
        return null;
    }

    /// The next phrase now, the one on screen kept for going back to.
    pub fn forward(run: *Run, a: *app.App, s: *sess.Session, now: u64) !Moved {
        const p = run.phrase orelse return null; // The book's end: nothing after
        run.remember(.{ .para = p.para, .byte = p.start });
        run.stopped_at = null;
        return try run.go_to(a, s, p.after(), now);
    }

    /// Whether going on would move: not past the book's end.
    pub fn can_go_on(run: *const Run) bool {
        return run.phrase != null;
    }

    /// Whether going back would move: not before the first phrase since running began.
    pub fn can_go_back(run: *const Run) bool {
        return run.history_len > 0;
    }

    /// The phrase before, again, its timer going.
    pub fn back(run: *Run, a: *app.App, s: *sess.Session, now: u64) !Moved {
        if (!run.can_go_back()) return null;
        run.history_len -= 1;
        const before = run.history[run.history_len];
        run.stopped_at = null;
        return try run.go_to(a, s, before, now);
    }

    fn remember(run: *Run, at: book_model.Pos) void {
        assert(run.history_len <= history_max);
        if (run.history_len == history_max) {
            // The oldest goes: a runner goes back a phrase or two, not thirty
            const kept = run.history[1..];
            std.mem.copyForwards(book_model.Pos, run.history[0 .. history_max - 1], kept);
            run.history_len -= 1;
        }
        run.history[run.history_len] = at;
        run.history_len += 1;
        assert(run.history_len <= history_max);
    }

    /// The phrase at `at`, or the first after it, in place of the one on screen, its
    /// timer started and its dial empty; shown by `show_moved`, once the reader's place
    /// has followed it.
    fn go_to(run: *Run, a: *app.App, s: *sess.Session, at: book_model.Pos, now: u64) !Moved {
        assert(at.para <= s.paragraphs.len); // From a phrase's end, or a phrase kept
        try run.set_phrase(a, s, at);
        run.start_timer(a, now);
        run.dial_step = 0;
        return run.place.?;
    }

    /// The phrase at `at`, or the first after it, and where that is: at the book's
    /// end, `at` itself, past the last phrase.
    fn set_phrase(run: *Run, a: *app.App, s: *sess.Session, at: book_model.Pos) !void {
        run.phrase = try view.phrase_at(a, s, at);
        run.place = if (run.phrase) |p| .{ .para = p.para, .byte = p.start } else at;
        assert(run.place != null);
    }

    /// What a move put on screen, in one clean refresh (run_view.zig).
    pub fn show_moved(run: *Run, a: *app.App, s: *sess.Session) !void {
        assert(run.place != null);
        run.dial_x = try view.show_moved(run, a, s);
    }

    /// Stops the phrase where its timer is, the button showing it'll carry on; or
    /// carries on from there.
    pub fn pause_or_resume(run: *Run, a: *app.App, s: *sess.Session, now: u64) !void {
        // A tap comes once the screen is shown, its timer started
        const shown = run.shown_us.?;
        if (run.stopped_at) |elapsed| {
            if (run.phrase == null) return; // The book's end: nothing to carry on to
            run.shown_us = now -| elapsed;
            run.stopped_at = null;
        } else {
            run.stopped_at = @min(now -| shown, run.phrase_us);
        }
        run.dial_x = try view.show_footer(run, a, s);
        // Stopped no further in than its time
        if (run.stopped_at) |elapsed| assert(elapsed <= run.phrase_us);
    }

    pub fn stopped(run: *const Run) bool {
        return run.stopped_at != null;
    }

    /// Whether a touch now acts: not when it comes right after one that did, which a
    /// bump or a drop of sweat makes far more often than a hand does.
    pub fn takes_touch(run: *Run, now: u64) bool {
        if (now -| run.last_touch_us < running_model.touch_gap_us) return false;
        run.last_touch_us = now;
        return true;
    }

    /// The Kindle kept awake while the phrases go on by themselves, and let sleep when
    /// they stop: paused, or at the book's end. Asked only when that changes, as each
    /// ask starts a program.
    pub fn sync_awake(run: *Run) void {
        const wanted = !run.stopped();
        if (wanted == run.awake) return;
        lipc.hold_awake(wanted);
        run.awake = wanted;
        assert(run.awake == !run.stopped());
    }

    /// Let go of: the Kindle free to sleep again.
    pub fn release_awake(run: *Run) void {
        if (run.awake) lipc.hold_awake(false);
        run.awake = false;
    }

    /// A tap while running, wherever it lands: the top band asks for the card, the left
    /// column shows the phrase before again, the middle one (and the pause button)
    /// stops or carries on, and the right one shows the next phrase now. Going on early
    /// says the pace is slow; going back, that it's fast.
    pub fn tap(
        run: *Run,
        a: *app.App,
        s: *sess.Session,
        x: i32,
        y: i32,
        touch: Touch,
        now: u64,
    ) !Tapped {
        assert(a.running_pace != null); // Set as running began
        // A contact too short for a finger: a drop of sweat, a brush. Let go before it
        // counts as a touch, so it never holds off the tap that follows. Timed by the
        // panel, as the finger lifted: noface may read it later
        if (touch.held_us) |held| if (held < running_model.contact_us_min) {
            std.debug.print("running: too short a touch, {d} ms\n", .{held / 1000});
            return .nothing;
        };
        // Until the screen is shown, there's nothing on it to tap
        if (run.shown_us == null) return .nothing;
        // Timed by when it touched, not when it's read, as a slow change may hold it up
        if (!run.takes_touch(touch.touched_us)) return .nothing;
        // The button showing whether it's paused takes taps too, in the left column
        const zone: running_model.Zone = if (view.on_pause_button(a, x, y))
            .toggle
        else
            running_model.zone(x, y, a.display.screen.width, pause_band_px);
        std.debug.print("running: tap {s}\n", .{@tagName(zone)});
        const was_stopped = run.stopped();
        // The dial shows only what this tap does to the pace
        run.pace_moved = null;
        const moved = switch (zone) {
            .card => return .card,
            .toggle => {
                try run.pause_or_resume(a, s, now);
                std.debug.print("running: {s}\n", .{if (run.stopped()) "paused" else "resumed"});
                return .nothing;
            },
            .next => moved: {
                // Read before its time was up: not from one stopped, read already, nor
                // at the book's end, where nothing comes next
                if (!was_stopped and run.can_go_on()) {
                    a.running_pace = running_model.faster(a.running_pace.?);
                    run.pace_moved = .up;
                }
                break :moved try run.forward(a, s, now);
            },
            .back => moved: {
                // Only when there's a phrase to go back to
                if (!was_stopped and run.can_go_back()) {
                    a.running_pace = running_model.slower(a.running_pace.?);
                    run.pace_moved = .down;
                }
                break :moved try run.back(a, s, now);
            },
        };
        const at = moved orelse return .nothing;
        return .{ .moved = at };
    }

    /// Whole minutes run so far.
    pub fn minutes(run: *const Run, now: u64) u64 {
        return (now -| run.started_us) / std.time.us_per_min;
    }
};

/// Running's card, opened by a tap in the pause band: carry on, change the text, or stop.
pub const pause_rows = [_]card.Row{
    .{ .label = "Resume" },
    .{ .label = "Text settings" },
    .{ .label = "Stop running" },
};
pub const Paused = enum { resume_running, text_settings, stop };

comptime {
    assert(pause_rows.len == std.enums.values(Paused).len);
}

test "going back returns the phrases gone past, the latest first, as far as kept" {
    var run: Run = .{ .started_us = 0 };
    for (0..history_max + 5) |i| run.remember(.{ .para = @intCast(i), .byte = 0 });
    try std.testing.expectEqual(@as(u32, history_max), run.history_len);
    const latest = run.history[run.history_len - 1].para;
    try std.testing.expectEqual(@as(u32, history_max + 4), latest);
    try std.testing.expectEqual(@as(u32, 5), run.history[0].para); // The oldest given up
}
