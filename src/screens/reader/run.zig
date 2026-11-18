//! Running mode over an open book: reading on a treadmill, the book turning its own
//! pages at the reader's running pace (model/running.zig), a bar along the foot of the
//! page filling as the next turn comes. The reader (screens/reader.zig) routes taps and
//! ticks here while it's on; this keeps the page's timer and draws the bar.
const std = @import("std");
const assert = std.debug.assert;
const running_model = @import("../../model/running.zig");
const card = @import("../../ui/card.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// The bar: pure black and white, which this panel changes without the black blink a
/// gray gives (hwtcon.Refresh.page), under the footer's line, across the text's width.
const bar_above_bottom_px = 26;
const bar_height_px = 10;
const track_px = 2; // The empty bar: a thin line, the filled part over it full height
/// The bar is drawn again at most this often: the panel needn't follow every pixel.
pub const bar_step_us = std.time.us_per_s;
/// The band at the top of the page whose taps pause: bigger than the toolbar's, as a
/// hand mid-stride lands less precisely.
pub const pause_band_px = 300;

comptime {
    assert(track_px < bar_height_px);
    assert(bar_height_px < bar_above_bottom_px);
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
    bar_drawn_us: u64 = 0,

    /// What a tick asks of the reader: nothing, or the next page.
    pub const Due = enum { wait, turn };

    /// Starts the page on screen's timer, its bar empty.
    pub fn begin_page(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !void {
        assert(s.current < s.pages.len);
        const wpm = a.running_pace.?; // Running always has a pace (`App.set_running`)
        run.page_us = running_model.page_us(wpm, s.words_on_page(s.current));
        run.page_started_us = now;
        const seconds = run.page_us / std.time.us_per_s;
        std.debug.print("running: page {d} for {d} s\n", .{ s.current + 1, seconds });
        try draw_bar(a, 0);
        run.bar_drawn_us = now;
        assert(run.page_us >= running_model.page_us_min);
    }

    /// The page's timer gone on: its bar filled further, or the page due to turn.
    pub fn tick(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !Due {
        if (run.holding) return .wait;
        const started = run.page_started_us orelse {
            try run.begin_page(a, s, now);
            return .wait;
        };
        assert(run.page_us > 0);
        const elapsed = now -| started;
        if (elapsed >= run.page_us) return .turn;
        if (now -| run.bar_drawn_us < bar_step_us) return .wait;
        const share = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(run.page_us));
        try draw_bar(a, share);
        run.bar_drawn_us = now;
        return .wait;
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

/// The bar filled `share` of the way, on the screen, refreshed in its band alone.
fn draw_bar(a: *app.App, share: f64) !void {
    assert(share >= 0);
    assert(share <= 1);
    const page = a.page(a.screen.pixels);
    const margin: u32 = @intCast(a.layout.margin_x);
    assert(2 * margin < a.screen.width);
    const width = a.screen.width - 2 * margin;
    const top = a.screen.height - bar_above_bottom_px;
    const filled: u32 = @intFromFloat(@as(f64, @floatFromInt(width)) * share);
    assert(filled <= width);
    page.fill_rect(margin, top, width, bar_height_px, 0xff);
    const track_top = top + (bar_height_px - track_px) / 2;
    page.fill_rect(margin, track_top, width, track_px, 0x00);
    if (filled > 0) page.fill_rect(margin, top, filled, bar_height_px, 0x00);
    const marker = try a.screen.show_region(margin, top, width, bar_height_px, .page);
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
