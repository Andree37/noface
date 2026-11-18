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
//! (screens/reader.zig) routes
//! taps and ticks here while it's on, and moves its place along as the phrases do.
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

/// The phrase's size: nearly twice a page's, readable as it blurs, a sentence of an
/// average length in a few lines. The lines before and after it are smaller, not bold:
/// there to place it, not to read.
const phrase_px = 84;
const context_px = 46;
const phrase_line_spacing = 1.35;
/// The most lines a phrase takes: more, and the eye starts losing its line again.
const phrase_lines_max = 6;
/// Where the phrase sits: its middle a little above the screen's, nearer the eye on a
/// treadmill's console.
const phrase_middle_y = 860;
const phrase_margin_px = 70;
const lines_max = phrase_lines_max + 1; // One more, to tell a phrase that doesn't fit
/// The page map, in the top right corner: the page as the reader would see it, shrunk,
/// its words as bars and the phrase's thick.
const map_width_px = 180;
const map_margin_px = 80;
const map_top = 40;
const map_word_px = 2;
const map_phrase_px = 6;
const text_top = map_top + map_width_px * 4 / 3 + 30; // Under the map
/// The line before the phrase and the line after it: their baselines, from the top of
/// the text's band and from the footer's top.
const before_below_top_px = 70;
const after_above_footer_px = 60;
/// The footer: the pause button on the left, the dial and the minutes left on the right.
const footer_height_px = 140;
const footer_baseline_above_bottom_px = 60;
const footer_margin_px = 80;
/// The dial: a thin ring thickening round from twelve o'clock like a clock's hand, from
/// a phrase coming up to the next one coming, with an arrow in its middle while the
/// pace has just gone up or down. Pure black and white, drawn without smoothing, as is
/// the pause button: the quick waveform changes both cleanly, with no blink.
const dial_radius_px = 22;
const ring_px = 2;
const sweep_px = 7; // How thick the ring is where it has swept
const arrow_half_px = 7; // The arrow's half width, and its height
const dial_gap_px = 22; // From the dial to the minutes left beside it
/// The dial's and the button's centre, up from the footer's baseline to its text's middle.
const icons_above_baseline_px = 11;
/// Steps of the sweep, as a clock's hours: each a quick refresh of the dial alone.
const dial_steps = 12;
/// From the pause button to the pace beside it.
const pace_gap_px = 20;
const pause_radius_px = 24;
const pause_x = footer_margin_px + pause_radius_px;
/// A tap this near the button's centre is on it: a fingertip around it.
const icon_reach_px = 60;
/// Earlier phrases kept, for going back to.
const history_max = 32;
/// How often the reader ticks while running: often, so each phrase changes on time.
pub const tick_us = 100 * std.time.us_per_ms;
/// The band at the top of the screen whose taps pause: bigger than the toolbar's, as a
/// hand mid-stride lands less precisely.
pub const pause_band_px = 300;

comptime {
    assert(ring_px < sweep_px);
    assert(sweep_px + arrow_half_px < dial_radius_px);
    assert(2 * icon_reach_px >= 100); // A fingertip
    assert(icon_reach_px > pause_radius_px);
    // The phrase at its most lines lies between the lines before and after it
    const half_block = phrase_lines_max * phrase_px * 135 / 100 / 2;
    assert(text_top + before_below_top_px + context_px < phrase_middle_y - half_block);
    assert(map_phrase_px > map_word_px);
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
    dial_step: u32 = 0, // How far the dial has swept over the phrase's time
    /// Which way the reader's tap just moved the pace: shown in the dial while the
    /// phrase that tap brought up is on screen.
    pace_moved: ?Pace = null,

    pub const Pace = enum { up, down };

    /// What a move did: the place of the phrase now on screen, or null when none
    /// changed.
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
        run.phrase = try phrase_at(a, s, from);
        const page = a.page(a.screen.pixels);
        page.fill_rect(0, 0, a.screen.width, a.screen.height, 0xff);
        a.stamp_clock();
        try run.draw_phrases(a, s);
        try run.draw_footer(a, s);
        try draw_map(a, s, run.phrase);
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
        const step: u32 = @intCast(elapsed * dial_steps / run.phrase_us);
        assert(step < dial_steps);
        if (step != run.dial_step) {
            run.dial_step = step;
            try show_dial(a, run.dial_x, step, run.pace_moved);
        }
        return null;
    }

    /// The next phrase now, the one on screen kept for going back to.
    pub fn forward(run: *Run, a: *app.App, s: *sess.Session, now: u64) !Moved {
        const p = run.phrase orelse return null; // The book's end: nothing after
        run.remember(.{ .para = p.para, .byte = p.start });
        run.stopped_at = null;
        return try run.move_to(a, s, p.after(), now);
    }

    /// The phrase before, again, its timer going.
    pub fn back(run: *Run, a: *app.App, s: *sess.Session, now: u64) !Moved {
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

    /// The phrase at `at`, or the first after it, in place of the one on screen, with
    /// the ends of the ones around it and the footer: in one clean refresh, from the
    /// text's top to the screen's foot.
    fn move_to(
        run: *Run,
        a: *app.App,
        s: *sess.Session,
        at: book_model.Pos,
        now: u64,
    ) !Moved {
        assert(at.para <= s.paragraphs.len); // From a phrase's end, or a phrase kept
        run.phrase = try phrase_at(a, s, at);
        run.start_timer(a, now);
        run.dial_step = 0; // Empty, for the phrase just shown
        try run.draw_phrases(a, s);
        try run.draw_footer(a, s);
        const height = a.screen.height - text_top;
        const marker = try a.screen.show_region(0, text_top, a.screen.width, height, .quick);
        try a.screen.wait_complete(marker);
        const p = run.phrase orelse return null;
        return .{ .para = p.para, .byte = p.start };
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
        try run.show_footer(a, s);
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

    /// Whole minutes run so far.
    pub fn minutes(run: *const Run, now: u64) u64 {
        return (now -| run.started_us) / std.time.us_per_min;
    }

    /// The phrase on screen, large and bold, centred about `phrase_middle_y`, the end of
    /// the one before it above and the start of the one after below, small; at the
    /// book's end, saying so. Pure black and white, which the quick refresh changes cleanly. Drawn
    /// into the screen, not shown.
    fn draw_phrases(run: *const Run, a: *app.App, s: *sess.Session) !void {
        const page = a.page(a.screen.pixels);
        const band = a.screen.height - footer_height_px - text_top;
        page.fill_rect(0, text_top, a.screen.width, band, 0xff);
        const family = a.settings.family_index();
        const big = try a.typefaces.phrase_face(family, true, phrase_px);
        const small = try a.typefaces.phrase_face(family, false, context_px);
        const width: f32 = @floatFromInt(a.screen.width - 2 * phrase_margin_px);
        if (run.history_len > 0) {
            if (try phrase_at(a, s, run.history[run.history_len - 1])) |before| {
                const tail = try ends_within(small, phrase_text(s, before), width, .tail);
                const baseline = text_top + before_below_top_px;
                try draw_line(a, small, tail.text, baseline, .{ .before = tail.cut });
            }
        }
        if (run.phrase) |p| {
            try draw_text(a, big, phrase_px, phrase_text(s, p), phrase_middle_y);
            if (try phrase_at(a, s, p.after())) |after| {
                const head = try ends_within(small, phrase_text(s, after), width, .head);
                const footer_top = a.screen.height - footer_height_px;
                const baseline: i32 = @intCast(footer_top - after_above_footer_px);
                try draw_line(a, small, head.text, baseline, .{ .after = head.cut });
            }
        } else {
            try draw_text(a, big, phrase_px, "The end", phrase_middle_y);
        }
        // Pure black and white, so the quick refresh shows it as drawn
        page.threshold(text_top, band);
    }

    /// The page map, marking the phrase on screen on the page now holding it: after
    /// the reader's place has followed the phrase there.
    pub fn show_map(run: *const Run, a: *app.App, s: *sess.Session) !void {
        try draw_map(a, s, run.phrase);
        const left = a.screen.width - map_margin_px - map_width_px;
        const marker = try a.screen.show_region(left, map_top, map_width_px, map_height(a), .quick);
        try a.screen.wait_complete(marker);
    }

    fn show_footer(run: *Run, a: *app.App, s: *sess.Session) !void {
        try run.draw_footer(a, s);
        const top = a.screen.height - footer_height_px;
        const marker = try a.screen.show_region(0, top, a.screen.width, footer_height_px, .quick);
        try a.screen.wait_complete(marker);
    }

    /// The footer: the pause button, two bars while the phrases go on and a triangle
    /// once stopped; and the dial with the minutes left in the chapter beside it.
    /// Drawn into the screen, not shown.
    fn draw_footer(run: *Run, a: *app.App, s: *sess.Session) !void {
        const page = a.page(a.screen.pixels);
        const top = a.screen.height - footer_height_px;
        page.fill_rect(0, top, a.screen.width, footer_height_px, 0xff);
        const cy = icons_y(a);
        draw_pause_button(a, pause_x, cy, run.stopped_at != null);
        const baseline: i32 = @intCast(a.screen.height - footer_baseline_above_bottom_px);
        // The pace, so a reader can see it follow their taps
        var pace_line: [32]u8 = undefined;
        const wpm: u32 = @intFromFloat(@round(a.running_pace.?));
        const pace = std.fmt.bufPrint(&pace_line, "{d} words a minute", .{wpm}) catch "";
        const pace_x: f32 = @floatFromInt(pause_x + pause_radius_px + pace_gap_px);
        try a.footer.draw(page, pace_x, baseline, pace);
        const words_left = if (run.phrase) |p|
            s.chapter_words_left(.{ .para = p.para, .byte = p.start })
        else
            0;
        const chapter_minutes = running_model.minutes_for(a.running_pace.?, words_left);
        var minutes_buffer: [48]u8 = undefined;
        var line: [64]u8 = undefined;
        const left = stats.format_minutes(&minutes_buffer, chapter_minutes);
        const text = std.fmt.bufPrint(&line, "{s} left in chapter", .{left}) catch "";
        const right: f32 = @floatFromInt(a.screen.width - footer_margin_px);
        const text_x = right - try a.footer.measure(text);
        try a.footer.draw(page, text_x, baseline, text);
        run.dial_x = @as(i32, @intFromFloat(text_x)) - dial_gap_px - dial_radius_px;
        // The dial stays clear of the pause button, whatever the minutes' width
        assert(run.dial_x - icon_reach_px > pause_x + icon_reach_px);
        draw_dial(a, run.dial_x, cy, run.dial_step, run.pace_moved);
    }
};

/// Whether a tap at (`x`, `y`) is on the pause button.
pub fn on_pause_button(a: *const app.App, x: i32, y: i32) bool {
    const cy = icons_y(a);
    return @abs(x - pause_x) <= icon_reach_px and @abs(y - cy) <= icon_reach_px;
}

/// The phrase at `at`, or the first after it, as long as fits the screen at the
/// phrase's size (model/phrases.zig).
fn phrase_at(a: *app.App, s: *const sess.Session, at: book_model.Pos) !?phrases.Phrase {
    const font = try a.typefaces.phrase_face(a.settings.family_index(), true, phrase_px);
    const width: f32 = @floatFromInt(a.screen.width - 2 * phrase_margin_px);
    const room: Room = .{ .font = font, .width = width };
    return phrases.at(s.paragraphs, at, .{ .ctx = &room, .call = Room.fits });
}

/// The space a phrase is shown in: `phrase_lines_max` lines of `width` in `font`.
const Room = struct {
    font: *Font,
    width: f32,

    fn fits(ctx: *const anyopaque, text: []const u8) bool {
        const room: *const Room = @ptrCast(@alignCast(ctx));
        var lines: [lines_max][]const u8 = undefined;
        // A font that can't measure fits nothing more: the phrase ends where it was
        const count = wrap(room.font, text, room.width, &lines) catch return false;
        return count <= phrase_lines_max;
    }
};

/// The words of `text` at its end (`tail`) or start (`head`) that fit one line of
/// `width`, the ellipsis that marks the cut included; whether any were left out.
fn ends_within(
    font: *Font,
    text: []const u8,
    width: f32,
    which: enum { head, tail },
) !struct { text: []const u8, cut: bool } {
    assert(width > 0);
    const room = width - try font.measure("\u{2026} ");
    if (try font.measure(text) <= width) return .{ .text = text, .cut = false };
    var best: []const u8 = "";
    // Each turn tries one word more, from the end it keeps
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var count: u32 = 0;
    while (words.next()) |_| count += 1;
    for (1..count + 1) |taken| {
        const part = switch (which) {
            .head => head_words(text, @intCast(taken)),
            .tail => tail_words(text, @intCast(taken)),
        };
        if (try font.measure(part) > room) break;
        best = part;
    }
    return .{ .text = best, .cut = true };
}

fn head_words(text: []const u8, count: u32) []const u8 {
    assert(count > 0);
    var seen: u32 = 0;
    for (text, 0..) |c, i| {
        if (c == ' ' and i > 0 and text[i - 1] != ' ') {
            seen += 1;
            if (seen == count) return text[0..i];
        }
    }
    return text;
}

fn tail_words(text: []const u8, count: u32) []const u8 {
    assert(count > 0);
    var seen: u32 = 0;
    var i = text.len;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == ' ' and i < text.len and text[i] != ' ') {
            seen += 1;
            if (seen == count) return text[i..];
        }
    }
    return text;
}

/// One line of `text` centred across the screen at `baseline`, with an ellipsis
/// where it was cut: before it, for the end of what came before; after, for the start
/// of what comes next.
fn draw_line(
    a: *app.App,
    font: *Font,
    text: []const u8,
    baseline: i32,
    cut: union(enum) { before: bool, after: bool },
) !void {
    var buffer: [512]u8 = undefined;
    const line = switch (cut) {
        .before => |b| if (b) with_ellipsis(&buffer, "\u{2026} ", text, "") else text,
        .after => |b| if (b) with_ellipsis(&buffer, "", text, " \u{2026}") else text,
    };
    const centre: f32 = @floatFromInt(a.screen.width / 2);
    try font.draw(a.page(a.screen.pixels), centre - try font.measure(line) / 2, baseline, line);
}

fn with_ellipsis(buffer: []u8, before: []const u8, text: []const u8, after: []const u8) []const u8 {
    assert(before.len + after.len > 0); // One side has it
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ before, text, after }) catch text;
}

fn phrase_text(s: *const sess.Session, p: phrases.Phrase) []const u8 {
    const text = s.paragraphs[p.para].text;
    assert(p.end <= text.len);
    return text[p.start..p.end];
}

/// `text` in `font`, its lines centred across the screen and, as a block, about `middle`.
fn draw_text(a: *app.App, font: *Font, px: i32, text: []const u8, middle: i32) !void {
    assert(px > 0);
    const page = a.page(a.screen.pixels);
    var lines: [lines_max][]const u8 = undefined;
    const width: f32 = @floatFromInt(a.screen.width - 2 * phrase_margin_px);
    const count = try wrap(font, text, width, &lines);
    assert(count > 0); // A phrase has a word at least
    const line_px: i32 = @intFromFloat(@as(f32, @floatFromInt(px)) * phrase_line_spacing);
    // Each line's text's middle sits a third of its size above its baseline
    const block = @as(i32, @intCast(count)) * line_px;
    var baseline = middle - @divTrunc(block, 2) + @divTrunc(line_px, 2) + @divTrunc(px, 3);
    const centre: f32 = @floatFromInt(a.screen.width / 2);
    for (lines[0..count]) |line| {
        const x = centre - try font.measure(line) / 2;
        try font.draw(page, x, baseline, line);
        baseline += line_px;
    }
}

fn map_height(a: *const app.App) u32 {
    // The page's own shape
    return map_width_px * a.screen.height / a.screen.width;
}

/// The page map: the page holding the reader's place, drawn as the reader would see
/// it, shrunk to the corner, its words thin bars and `phrase`'s thick. Black and white,
/// for the quick waveform. Drawn into the screen, not shown.
fn draw_map(a: *app.App, s: *sess.Session, phrase: ?phrases.Phrase) !void {
    const height = map_height(a);
    const left = a.screen.width - map_margin_px - map_width_px;
    const page = a.page(a.screen.pixels);
    page.fill_rect(left, map_top, map_width_px, height, 0xff);
    // Its edge
    page.fill_rect(left, map_top, map_width_px, 2, 0x00);
    page.fill_rect(left, map_top + height - 2, map_width_px, 2, 0x00);
    page.fill_rect(left, map_top, 2, height, 0x00);
    page.fill_rect(left + map_width_px - 2, map_top, 2, height, 0x00);
    // The page as drawn, for where its words are
    _ = try s.ensure(s.current, s.current);
    const slot = a.slot_for(s.current) orelse return;
    const words = slot.hits.words[0..slot.hits.word_count];
    const scale = @as(f32, @floatFromInt(map_width_px)) / @as(f32, @floatFromInt(a.screen.width));
    for (words) |w| {
        const in_phrase = if (phrase) |p|
            w.para == p.para and w.start >= p.start and w.end <= p.end
        else
            false;
        const thick: u32 = if (in_phrase) map_phrase_px else map_word_px;
        const x: u32 = left + shrink(w.x, scale);
        const y: u32 = map_top + shrink(w.y + @divTrunc(w.h, 2), scale) -| thick / 2;
        const width: u32 = @max(1, shrink(w.w, scale));
        // Inside the map's edge
        if (x + width >= left + map_width_px - 2 or y + thick >= map_top + height - 2) continue;
        page.fill_rect(x, @max(y, map_top + 2), width, thick, 0x00);
    }
}

/// A length on the page, shrunk to the map; nothing for one off the page's top or left.
fn shrink(length: i32, scale: f32) u32 {
    assert(scale > 0);
    assert(scale < 1);
    return @intFromFloat(@as(f32, @floatFromInt(@max(length, 0))) * scale);
}

/// The dial swept to `step`, refreshed alone.
fn show_dial(a: *app.App, cx: i32, step: u32, arrow: ?Run.Pace) !void {
    const cy = icons_y(a);
    draw_dial(a, cx, cy, step, arrow);
    const r = dial_radius_px;
    const side: u32 = 2 * r + 1;
    const marker = try a.screen.show_region(@intCast(cx - r), @intCast(cy - r), side, side, .quick);
    try a.screen.wait_complete(marker);
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

/// The dial centred on (`cx`, `cy`), swept `step` twelfths of the way round, with
/// `arrow` in its middle, up or down, when there is one. Drawn into the screen, not
/// shown.
fn draw_dial(a: *app.App, cx: i32, cy: i32, step: u32, arrow: ?Run.Pace) void {
    assert(step < dial_steps);
    const r = dial_radius_px;
    assert(cx - r >= 0);
    assert(cy + r < a.screen.height);
    const page = a.page(a.screen.pixels);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    const side: u32 = 2 * r + 1;
    const thin = r - ring_px;
    const thick = r - sweep_px;
    const swept = @as(f32, @floatFromInt(step)) / dial_steps * std.math.tau;
    for (0..side) |row| for (0..side) |column| {
        const dx: i32 = @as(i32, @intCast(column)) - r;
        const dy: i32 = @as(i32, @intCast(row)) - r;
        const d2 = dx * dx + dy * dy;
        var black = d2 <= r * r and d2 >= thin * thin;
        if (d2 <= r * r and d2 >= thick * thick and step > 0) {
            // Clockwise from twelve o'clock
            var angle = std.math.atan2(@as(f32, @floatFromInt(dx)), @as(f32, @floatFromInt(-dy)));
            if (angle < 0) angle += std.math.tau;
            if (angle < swept) black = true;
        }
        if (arrow) |way| {
            // A triangle, its point up for a quicker pace, down for a slower
            const h = arrow_half_px;
            const from_point = switch (way) {
                .up => dy + h / 2,
                .down => h / 2 - dy,
            };
            const in_arrow = from_point >= 0 and from_point <= h and @abs(dx) <= from_point;
            if (in_arrow) black = true;
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
