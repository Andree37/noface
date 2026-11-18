//! Running mode over an open book: reading on a treadmill. A bouncing head loses its
//! line on a page, so running shows no page: the book a phrase at a time
//! (model/phrases.zig), a few words large and bold at one fixed spot, each changing to
//! the next at the reader's running pace (model/running.zig). Under them, a pause
//! button, and a dial filling over the chapter beside the minutes left in it; a tap on
//! the dial stops running. The reader (screens/reader.zig) routes taps and ticks here
//! while it's on, and moves its place along as the phrases do.
const std = @import("std");
const assert = std.debug.assert;
const running_model = @import("../../model/running.zig");
const phrases = @import("../../model/phrases.zig");
const book_model = @import("../../model/book.zig");
const stats = @import("../../model/stats.zig");
const card = @import("../../ui/card.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const Font = @import("../../gfx/font.zig").Font;

/// The phrases' size: about two and a half times a page's, readable as it blurs.
const phrase_px = 112;
const phrase_line_spacing = 1.3;
/// Where the phrases sit: their middle a little above the screen's, nearer the eye on
/// a treadmill's console, between the clock and the footer.
const phrase_middle_y = 760;
const phrase_margin_px = 70;
const lines_max = 4; // A phrase is at most two lines, but for one long word broken
const text_top = 120; // Under the clock
/// The footer: the pause button on the left, the dial and the minutes left on the right.
const footer_height_px = 140;
const footer_baseline_above_bottom_px = 60;
const footer_margin_px = 80;
/// The dial: a ring with a wedge sweeping round inside it like a clock's hand, filling
/// over the chapter. Pure black and white, drawn without smoothing, as is the pause
/// button: the quick waveform changes both cleanly, with no blink.
const dial_radius_px = 17;
const ring_px = 3;
const wedge_gap_px = 2; // Between the ring and the wedge, so each reads on its own
const dial_gap_px = 22; // From the dial to the minutes left beside it
/// The dial's and the button's centre, up from the footer's baseline to its text's middle.
const icons_above_baseline_px = 11;
const dial_steps = 60;
const pause_radius_px = 24;
const pause_x = footer_margin_px + pause_radius_px;
/// A tap this near the dial's or the button's centre is on it: a fingertip around it.
const icon_reach_px = 60;
/// Earlier phrases kept, for going back to.
const history_max = 32;
/// How often the reader ticks while running: often, so each phrase changes on time.
pub const tick_us = 100 * std.time.us_per_ms;
/// The band at the top of the screen whose taps pause: bigger than the toolbar's, as a
/// hand mid-stride lands less precisely.
pub const pause_band_px = 300;

comptime {
    assert(ring_px + wedge_gap_px < dial_radius_px);
    assert(2 * icon_reach_px >= 100); // A fingertip
    assert(icon_reach_px > pause_radius_px);
    assert(text_top < phrase_middle_y);
    assert(tick_us < phrases.phrase_us_min);
    assert(pause_band_px < phrase_middle_y);
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
    dial_step: u32 = 0,
    minutes_left: u64 = 0,

    /// What a move did: the place of the phrase now on screen, or null when none
    /// changed.
    pub const Moved = ?book_model.Pos;

    /// The whole screen: the phrase at `from`, or the first after it, the clock above
    /// and the footer below, cleanly, with a flash.
    pub fn show_all(
        run: *Run,
        a: *app.App,
        s: *const sess.Session,
        from: book_model.Pos,
        now: u64,
    ) !void {
        assert(from.para < s.paragraphs.len); // The reader's place, inside the book
        run.phrase = phrases.at(s.paragraphs, from);
        const page = a.page(a.screen.pixels);
        page.fill_rect(0, 0, a.screen.width, a.screen.height, 0xff);
        a.stamp_clock();
        try run.draw_phrase(a, s);
        try run.draw_footer(a, s);
        try a.screen.wait_complete(try a.screen.show(.flash));
        run.start_timer(a, now);
        assert(run.shown_us == now);
        std.debug.print("running: phrases from {d}:{d}\n", .{ from.para, from.byte });
    }

    /// The phrase on screen's timer started, or stopped at the book's end.
    fn start_timer(run: *Run, a: *const app.App, now: u64) void {
        assert(a.running);
        run.shown_us = now;
        const p = run.phrase orelse {
            run.stopped_at = 0;
            return;
        };
        run.phrase_us = phrases.phrase_us(a.running_pace.?, p);
        assert(run.phrase_us >= phrases.phrase_us_min);
    }

    /// The timer gone on: the next phrase when this one's time is up.
    pub fn tick(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !Moved {
        const shown = run.shown_us orelse {
            try run.show_all(a, s, s.anchor, now);
            return null;
        };
        if (run.stopped_at != null) return null;
        // A phrase on screen with its timer going has a time to stay
        assert(run.phrase != null);
        assert(run.phrase_us >= phrases.phrase_us_min);
        if (now -| shown < run.phrase_us) return null;
        return try run.forward(a, s, now);
    }

    /// The next phrase now, the one on screen kept for going back to.
    pub fn forward(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !Moved {
        const p = run.phrase orelse return null; // The book's end: nothing after
        run.remember(.{ .para = p.para, .byte = p.start });
        run.stopped_at = null;
        return try run.move_to(a, s, p.after(), now);
    }

    /// The phrase before, again, its timer going.
    pub fn back(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !Moved {
        if (run.history_len == 0) return null; // The first since running began
        run.history_len -= 1;
        const before = run.history[run.history_len];
        run.stopped_at = null;
        return try run.move_to(a, s, before, now);
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

    /// The phrase at `at`, or the first after it, in place of the one on screen.
    fn move_to(
        run: *Run,
        a: *app.App,
        s: *const sess.Session,
        at: book_model.Pos,
        now: u64,
    ) !Moved {
        assert(at.para <= s.paragraphs.len); // From a phrase's end, or a phrase kept
        run.phrase = phrases.at(s.paragraphs, at);
        try run.draw_phrase(a, s);
        const band = a.screen.height - footer_height_px - text_top;
        const marker = try a.screen.show_region(0, text_top, a.screen.width, band, .page);
        try a.screen.wait_complete(marker);
        run.start_timer(a, now);
        if (run.footer_changed(a, s)) try run.show_footer(a, s);
        const p = run.phrase orelse return null;
        return .{ .para = p.para, .byte = p.start };
    }

    /// Stops the phrase where its timer is, the button showing it'll carry on; or
    /// carries on from there.
    pub fn pause_or_resume(run: *Run, a: *app.App, s: *const sess.Session, now: u64) !void {
        // A tap comes once the screen is shown, its timer started
        const shown = run.shown_us.?;
        if (run.stopped_at) |elapsed| {
            if (run.phrase == null) return; // The book's end: nothing to carry on to
            run.shown_us = now -| elapsed;
            run.stopped_at = null;
        } else {
            run.stopped_at = @min(now -| shown, run.phrase_us);
        }
        try run.show_footer(a, s);
        // Stopped no further in than its time
        if (run.stopped_at) |elapsed| assert(elapsed <= run.phrase_us);
    }

    pub fn stopped(run: *const Run) bool {
        return run.stopped_at != null;
    }

    /// Whether a tap at (`x`, `y`) is on the pause button.
    pub fn on_pause_button(a: *const app.App, x: i32, y: i32) bool {
        const cy = icons_y(a);
        return @abs(x - pause_x) <= icon_reach_px and @abs(y - cy) <= icon_reach_px;
    }

    /// Whether a tap at (`x`, `y`) is on the dial, which stops running.
    pub fn on_dial(run: *const Run, a: *const app.App, x: i32, y: i32) bool {
        // Placed as the footer is first drawn: until then there's no dial to tap
        if (run.dial_x == 0) return false;
        const cy = icons_y(a);
        return @abs(x - run.dial_x) <= icon_reach_px and @abs(y - cy) <= icon_reach_px;
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

    /// The phrase on screen, large and bold, its lines centred about `phrase_middle_y`;
    /// at the book's end, saying so. Drawn into the screen, not shown.
    fn draw_phrase(run: *const Run, a: *app.App, s: *const sess.Session) !void {
        const page = a.page(a.screen.pixels);
        const band = a.screen.height - footer_height_px - text_top;
        page.fill_rect(0, text_top, a.screen.width, band, 0xff);
        const font = try a.typefaces.phrase_face(a.settings.family_index(), 1, phrase_px);
        const centre: f32 = @floatFromInt(a.screen.width / 2);
        const p = run.phrase orelse {
            const end_text = "The end";
            const x = centre - try font.measure(end_text) / 2;
            return font.draw(page, x, phrase_middle_y + phrase_px / 3, end_text);
        };
        assert(p.end <= s.paragraphs[p.para].text.len);
        const text = s.paragraphs[p.para].text[p.start..p.end];
        var lines: [lines_max][]const u8 = undefined;
        const width: f32 = @floatFromInt(a.screen.width - 2 * phrase_margin_px);
        const count = try wrap(font, text, width, &lines);
        assert(count > 0); // A phrase has a word at least
        const line_px: i32 = @intFromFloat(phrase_px * phrase_line_spacing);
        // The block of lines centred: each line's text's middle sits a third of the
        // size above its baseline
        const block = @as(i32, @intCast(count)) * line_px;
        var baseline = phrase_middle_y - @divTrunc(block, 2) + @divTrunc(line_px, 2) +
            phrase_px / 3;
        for (lines[0..count]) |line| {
            const x = centre - try font.measure(line) / 2;
            try font.draw(page, x, baseline, line);
            baseline += line_px;
        }
    }

    /// Whether the footer would show something else now: the dial a step on, or
    /// another minute left.
    fn footer_changed(run: *const Run, a: *const app.App, s: *const sess.Session) bool {
        const now = footer_state(run, a, s);
        return now.step != run.dial_step or now.minutes != run.minutes_left;
    }

    fn show_footer(run: *Run, a: *app.App, s: *const sess.Session) !void {
        try run.draw_footer(a, s);
        const top = a.screen.height - footer_height_px;
        const marker = try a.screen.show_region(0, top, a.screen.width, footer_height_px, .quick);
        try a.screen.wait_complete(marker);
    }

    /// The footer: the pause button, two bars while the phrases go on and a triangle
    /// once stopped; and the dial with the minutes left in the chapter beside it.
    /// Drawn into the screen, not shown.
    fn draw_footer(run: *Run, a: *app.App, s: *const sess.Session) !void {
        const page = a.page(a.screen.pixels);
        const top = a.screen.height - footer_height_px;
        page.fill_rect(0, top, a.screen.width, footer_height_px, 0xff);
        const cy = icons_y(a);
        draw_pause_button(a, pause_x, cy, run.stopped_at != null);
        const state = footer_state(run, a, s);
        run.dial_step = state.step;
        run.minutes_left = state.minutes;
        var minutes_buffer: [48]u8 = undefined;
        var line: [64]u8 = undefined;
        const left = stats.format_minutes(&minutes_buffer, state.minutes);
        const text = std.fmt.bufPrint(&line, "{s} left in chapter", .{left}) catch "";
        const right: f32 = @floatFromInt(a.screen.width - footer_margin_px);
        const text_x = right - try a.footer.measure(text);
        const baseline: i32 = @intCast(a.screen.height - footer_baseline_above_bottom_px);
        try a.footer.draw(page, text_x, baseline, text);
        run.dial_x = @as(i32, @intFromFloat(text_x)) - dial_gap_px - dial_radius_px;
        // The dial stays clear of the pause button, whatever the minutes' width
        assert(run.dial_x - icon_reach_px > pause_x + icon_reach_px);
        draw_dial(a, run.dial_x, cy, state.step);
    }
};

const FooterState = struct { step: u32, minutes: u64 };

/// The dial's step and the minutes left, for the phrase on screen.
fn footer_state(run: *const Run, a: *const app.App, s: *const sess.Session) FooterState {
    const p = run.phrase orelse return .{ .step = dial_steps - 1, .minutes = 0 };
    const progress = s.chapter_progress(.{ .para = p.para, .byte = p.start });
    const step: u32 = @intFromFloat(@min(progress.share * dial_steps, dial_steps - 1));
    const minutes = running_model.minutes_for(a.running_pace.?, progress.words_left);
    return .{ .step = step, .minutes = minutes };
}

fn icons_y(a: *const app.App) i32 {
    const bottom: i32 = @intCast(a.screen.height);
    return bottom - footer_baseline_above_bottom_px - icons_above_baseline_px;
}

/// `text`'s words in lines no wider than `width`, as many as `lines` holds; a word
/// wider than a line by itself is broken where it reaches the edge.
fn wrap(font: *Font, text: []const u8, width: f32, lines: [][]const u8) !u32 {
    assert(width > 0);
    assert(lines.len > 0);
    var count: u32 = 0;
    var start: u32 = 0;
    // Each turn ends a line, at least a character long
    while (start < text.len and count < lines.len) {
        while (start < text.len and text[start] == ' ') start += 1;
        if (start == text.len) break;
        var fitted = start;
        // Each turn tries one more word on the line
        while (fitted < text.len) {
            var next = fitted;
            while (next < text.len and text[next] == ' ') next += 1;
            while (next < text.len and text[next] != ' ') next += 1;
            if (try font.measure(text[start..next]) > width) break;
            fitted = next;
        }
        if (fitted == start) fitted = start + try font.fit(text[start..], width); // One long word
        lines[count] = text[start..fitted];
        count += 1;
        start = fitted;
    }
    assert(count <= lines.len);
    return count;
}

/// The pause button centred on (`cx`, `cy`): a ring like the dial's, a little larger,
/// with two bars in it while the phrases go on, and a triangle to carry on once
/// stopped. Drawn into the screen, not shown.
fn draw_pause_button(a: *app.App, cx: i32, cy: i32, stopped: bool) void {
    const r = pause_radius_px;
    assert(cx - r >= 0);
    assert(cy + r < a.screen.height);
    const page = a.page(a.screen.pixels);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    const side: u32 = 2 * r + 1;
    const ring_inner = r - ring_px;
    const icon = r / 2; // The bars' and the triangle's half height
    for (0..side) |row| for (0..side) |column| {
        const dx: i32 = @as(i32, @intCast(column)) - r;
        const dy: i32 = @as(i32, @intCast(row)) - r;
        const d2 = dx * dx + dy * dy;
        var black = d2 <= r * r and d2 >= ring_inner * ring_inner;
        if (@abs(dy) <= icon) {
            if (stopped) {
                // A triangle pointing right, its middle a little right of the centre
                const from = -icon + 3;
                const reach = 2 * (icon - @as(i32, @intCast(@abs(dy))));
                black = black or (dx >= from and dx - from <= reach);
            } else {
                black = black or (@abs(dx) >= 3 and @abs(dx) <= 3 + 4); // Two bars
            }
        }
        page.buf[(top + row) * page.stride + left + column] = if (black) 0x00 else 0xff;
    };
}

/// The dial centred on (`cx`, `cy`), swept `step` sixtieths of the way round. Drawn
/// into the screen, not shown.
fn draw_dial(a: *app.App, cx: i32, cy: i32, step: u32) void {
    assert(step < dial_steps);
    const r = dial_radius_px;
    assert(cx - r >= 0);
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

test "going back returns the phrases gone past, the latest first, as far as kept" {
    var run: Run = .{ .started_us = 0 };
    for (0..history_max + 5) |i| run.remember(.{ .para = @intCast(i), .byte = 0 });
    try std.testing.expectEqual(@as(u32, history_max), run.history_len);
    const latest = run.history[run.history_len - 1].para;
    try std.testing.expectEqual(@as(u32, history_max + 4), latest);
    try std.testing.expectEqual(@as(u32, 5), run.history[0].para); // The oldest given up
}
