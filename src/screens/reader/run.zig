//! Running mode over an open book: reading on a treadmill, the book turning its own
//! pages at the reader's running pace (model/running.zig), a small dial in the footer
//! filling as the next turn comes, and an arrow in the left margin moving down the lines
//! at that pace, for the eye to find its line again after a bounce; a tap on the dial
//! stops running. The reader
//! (screens/reader.zig) routes taps and ticks here while it's on; this keeps the page's
//! timer and draws the dial.
const std = @import("std");
const assert = std.debug.assert;
const running_model = @import("../../model/running.zig");
const card = @import("../../ui/card.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const hl = @import("highlight.zig");
const book_model = @import("../../model/book.zig");

/// The dial: a ring with a wedge sweeping round inside it like a clock's hand, beside
/// the footer's time left, about as tall as its text. Pure black and white, drawn
/// without smoothing, so the quick waveform changes it cleanly, with no blink.
const dial_radius_px = 17;
const ring_px = 3;
const wedge_gap_px = 2; // Between the ring and the wedge, so each reads on its own
const dial_gap_px = 22; // From the dial to the time left beside it
/// The dial's centre, up from the footer's baseline to the middle of its text.
const dial_above_baseline_px = 11;
/// Steps of the sweep: it moves on only when the wedge would change, each step a
/// sixtieth of the way round, as a clock's seconds do.
const dial_steps = 60;
/// How often the reader ticks while running: often, so each step shows when it falls.
pub const dial_step_us = 250 * std.time.us_per_ms;
/// A tap this near the dial's centre stops running: a fingertip around it.
const dial_reach_px = 60;
/// The band at the top of the page whose taps pause: bigger than the toolbar's, as a
/// hand mid-stride lands less precisely.
pub const pause_band_px = 300;

/// The line marker: an arrow pointing at the line the pace says is being read, in the
/// left margin, black and white like the dial.
const marker_width_px = 26;
const marker_half_height_px = 13;
const marker_gap_px = 14; // From the arrow's tip to the text
/// Lines a page is followed by; a page with more (none at running's sizes) has the
/// rest counted as its last.
const lines_max = 64;

comptime {
    assert(ring_px + wedge_gap_px < dial_radius_px);
    assert(marker_half_height_px * 2 <= marker_width_px + 2);
    assert(2 * dial_reach_px >= 100); // A fingertip
    assert(dial_reach_px > dial_radius_px);
}

/// Running, over the open book.
pub const Run = struct {
    /// When the page on screen came up with its timer going; null until the next tick
    /// starts it: on a page just shown, or after the toolbar, the pause card or the lock.
    page_started_us: ?u64 = null,
    page_us: u64 = 0, // How long the page on screen stays up
    /// Held on its page until a tap: after going back a page, or at the book's end.
    holding: bool = false,
    started_us: u64, // When running began, for the time run
    last_touch_us: u64 = 0, // The last touch that acted, so a bump right after is let go
    /// The dial on this page: its centre, which follows the time left beside it, and
    /// the step of the sweep shown.
    dial_x: i32 = 0,
    dial_y: i32 = 0,
    dial_step: u32 = 0,
    /// The page's lines: where each one's text sits, and the words up to its end.
    lines: [lines_max]Line = undefined,
    lines_count: u32 = 0,
    marker_line: ?u32 = null, // The line the arrow points at, when it's drawn

    const Line = struct { middle: i32, words_through: u32 };

    /// What a tick asks of the reader: nothing, or the next page.
    pub const Due = enum { wait, turn };

    /// Starts the page on screen's timer, its dial empty.
    pub fn begin_page(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !void {
        assert(s.current < s.pages.len);
        const wpm = a.running_pace.?; // Running always has a pace (`App.set_running`)
        run.page_us = running_model.page_us(wpm, s.words_on_page(s.current));
        run.page_started_us = now;
        const seconds = run.page_us / std.time.us_per_s;
        std.debug.print("running: page {d} for {d} s\n", .{ s.current + 1, seconds });
        const start = try s.footer_right_start(s.current, dial_gap_px);
        run.dial_x = @as(i32, @intFromFloat(start.x)) - dial_radius_px;
        run.dial_y = start.y - dial_above_baseline_px;
        run.dial_step = 0;
        try draw_dial(a, run.dial_x, run.dial_y, 0);
        run.find_lines(hl.page_words(a, s), a.settings.px());
        run.marker_line = null;
        try run.move_marker(a, 0);
        assert(run.page_us >= running_model.page_us_min);
    }

    /// The page's lines, from its words as they were drawn: a new line wherever a word
    /// sits lower than the one before. Its text's middle is a little over half the
    /// text size below the line's top, where the letters without ascenders sit.
    fn find_lines(run: *Run, words: []const book_model.Word, px: f32) void {
        assert(px > 0);
        run.lines_count = 0;
        const middle_below_top: i32 = @intFromFloat(px * 0.55);
        var top: ?i32 = null;
        for (words, 0..) |w, i| {
            const new_line = top == null or w.y > top.?;
            if (new_line and run.lines_count < lines_max) {
                const middle = w.y + middle_below_top;
                run.lines[run.lines_count] = .{ .middle = middle, .words_through = 0 };
                run.lines_count += 1;
                top = w.y;
            }
            run.lines[run.lines_count - 1].words_through = @intCast(i + 1);
        }
        assert(run.lines_count <= lines_max);
        if (run.lines_count > 0) {
            assert(run.lines[run.lines_count - 1].words_through == words.len);
        }
    }

    /// The arrow at the line the pace has reached, `share` of the page's words in: moved
    /// only when that's another line.
    fn move_marker(run: *Run, a: *app.App, share: f64) !void {
        assert(share >= 0);
        if (run.lines_count == 0) return; // A picture alone: no line to point at
        const total = run.lines[run.lines_count - 1].words_through;
        const read: u32 = @intFromFloat(@as(f64, @floatFromInt(total)) * share);
        var line: u32 = run.lines_count - 1;
        for (run.lines[0..run.lines_count], 0..) |l, i| {
            if (read < l.words_through) {
                line = @intCast(i);
                break;
            }
        }
        if (run.marker_line == line) return;
        const old = run.marker_line;
        run.marker_line = line;
        try draw_marker(a, if (old) |o| run.lines[o].middle else null, run.lines[line].middle);
    }

    /// The page's timer gone on: its dial swept further, or the page due to turn.
    pub fn tick(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !Due {
        if (run.holding) return .wait;
        const started = run.page_started_us orelse {
            try run.begin_page(a, s, now);
            return .wait;
        };
        assert(run.page_us > 0);
        const elapsed = now -| started;
        if (elapsed >= run.page_us) return .turn;
        const share = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(run.page_us));
        try run.move_marker(a, share);
        const step: u32 = @intCast(elapsed * dial_steps / run.page_us);
        assert(step < dial_steps);
        if (step == run.dial_step) return .wait;
        run.dial_step = step;
        try draw_dial(a, run.dial_x, run.dial_y, step);
        return .wait;
    }

    /// Whether a tap at (`x`, `y`) is on the dial, which stops running.
    pub fn on_dial(run: *const Run, x: i32, y: i32) bool {
        // Placed by `begin_page`: until then there's no dial to tap
        if (run.dial_x == 0) return false;
        const dx = @abs(x - run.dial_x);
        const dy = @abs(y - run.dial_y);
        return dx <= dial_reach_px and dy <= dial_reach_px;
    }

    /// Whether a touch now acts: not when it comes right after one that did, which a
    /// bump or a drop of sweat makes far more often than a hand does.
    pub fn takes_touch(run: *Run, now: u64) bool {
        if (now -| run.last_touch_us < running_model.touch_gap_us) return false;
        run.last_touch_us = now;
        return true;
    }

    /// Whole minutes run so far.
    pub fn minutes(run: *const Run, now: u64) u64 {
        return (now -| run.started_us) / std.time.us_per_min;
    }
};

/// The arrow moved from the line whose text's middle is at `from` (none drawn yet when
/// null) to the one at `to`, in the left margin, both refreshed in one strip.
fn draw_marker(a: *app.App, from: ?i32, to: i32) !void {
    const page = a.page(a.screen.pixels);
    const tip = a.layout.margin_x - marker_gap_px;
    const left = tip - marker_width_px;
    assert(left >= 0);
    const h = marker_half_height_px;
    const box_width: u32 = marker_width_px + 1;
    if (from) |y| page.fill_rect(@intCast(left), @intCast(y - h), box_width, 2 * h + 1, 0xff);
    // An arrow pointing right, at the text: as tall as its line's letters at its base
    for (0..2 * h + 1) |row| {
        const dy: i32 = @as(i32, @intCast(row)) - h;
        const reach = @divTrunc((h - @as(i32, @intCast(@abs(dy)))) * marker_width_px, h);
        if (reach > 0) page.fill_rect(@intCast(left), @intCast(to + dy), @intCast(reach), 1, 0x00);
    }
    const top = @min(from orelse to, to) - h;
    const bottom = @max(from orelse to, to) + h + 1;
    assert(top >= 0);
    assert(bottom <= a.screen.height);
    const x: u32 = @intCast(left);
    const height: u32 = @intCast(bottom - top);
    const marker = try a.screen.show_region(x, @intCast(top), box_width, height, .quick);
    try a.screen.wait_complete(marker);
}

/// The dial centred on (`cx`, `cy`), swept `step` sixtieths of the way round, on the
/// screen, refreshed in its square alone.
fn draw_dial(a: *app.App, cx: i32, cy: i32, step: u32) !void {
    assert(step < dial_steps);
    const r = dial_radius_px;
    assert(cx - r >= 0);
    assert(cy - r >= 0);
    assert(cx + r < a.screen.width);
    assert(cy + r < a.screen.height);
    const page = a.page(a.screen.pixels);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    const side: u32 = 2 * r + 1;
    const ring_inner = r - ring_px;
    const wedge_outer = ring_inner - wedge_gap_px;
    const swept = @as(f32, @floatFromInt(step)) / dial_steps * std.math.tau;
    for (0..side) |row| for (0..side) |column| {
        const dx = @as(f32, @floatFromInt(column)) - r;
        const dy = @as(f32, @floatFromInt(row)) - r;
        const d2 = dx * dx + dy * dy;
        var black = d2 <= r * r and d2 >= ring_inner * ring_inner;
        if (d2 <= wedge_outer * wedge_outer and step > 0) {
            // Clockwise from twelve o'clock
            var angle = std.math.atan2(dx, -dy);
            if (angle < 0) angle += std.math.tau;
            black = angle < swept;
        }
        page.buf[(top + row) * page.stride + left + column] = if (black) 0x00 else 0xff;
    };
    const marker = try a.screen.show_region(left, top, side, side, .quick);
    try a.screen.wait_complete(marker);
}

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

test "a tap on the dial, or a fingertip around it, stops running; one beside it doesn't" {
    var run: Run = .{ .started_us = 0 };
    // Before the first page's dial is placed, there's none to tap
    try std.testing.expect(!run.on_dial(0, 0));
    run.dial_x = 900;
    run.dial_y = 1625;
    try std.testing.expect(run.on_dial(900, 1625));
    try std.testing.expect(run.on_dial(900 - dial_reach_px, 1625 + dial_reach_px));
    try std.testing.expect(!run.on_dial(900 + dial_reach_px + 1, 1625));
    try std.testing.expect(!run.on_dial(900, 1625 - dial_reach_px - 1));
}
