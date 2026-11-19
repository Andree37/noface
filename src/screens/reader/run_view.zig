//! How running mode looks (screens/reader/run.zig keeps what it does): the phrase
//! large and still in the screen's middle, the end of the one before above it and the
//! start of the one after below, a map of the page in the top right corner, and the
//! footer with the pause button and the pace on the left and the dial and the minutes
//! left in the chapter on the right. Everything is drawn into the screen from a `Run`
//! read, never changed: what a draw works out that running needs (where the dial went)
//! it gives back. Also how much of the book fits as one phrase, as that's the screen's
//! to say.
const std = @import("std");
const assert = std.debug.assert;
const phrases = @import("../../model/phrases.zig");
const book_model = @import("../../model/book.zig");
const stats = @import("../../model/stats.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const Font = @import("../../gfx/font.zig").Font;
const Page = @import("../../gfx/page.zig").Page;
const style = @import("../../ui/style.zig");
const Run = @import("run.zig").Run;

/// The phrase's size: nearly twice a page's, readable as it blurs, a sentence of an
/// average length in a few lines. The lines before and after it are smaller, not bold:
/// there to place it, not to read.
const phrase_px = 84;
const context_px = 46;
const phrase_line_spacing = 1.35;
/// The most lines a phrase takes: more, and the eye starts losing its line again.
const phrase_lines_max = 6;
/// Where the phrase sits: its middle at the screen's, between the line before it under
/// the map and the line after it over the footer.
pub const phrase_middle_y = style.screen_height / 2;
const phrase_margin_px = 70;
const lines_max = phrase_lines_max + 1; // One more, to tell a phrase that doesn't fit
/// The page map, in the top right corner: the page as the reader would see it, shrunk,
/// its words as bars and the phrase's thick.
const map_width_px = 180;
const map_margin_px = 80;
const map_top = 40;
const map_word_px = 2;
const map_edge_px = 2; // Its outline
/// As tall as the page it shows, for its width.
const map_height_px = map_width_px * style.screen_height / style.screen_width;
const map_gap_px = 30; // Between the map and the text under it
const map_phrase_px = 6;
const text_top = map_top + map_height_px + map_gap_px; // Under the map
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
/// pace has just gone up or down. Drawn with smooth edges, as is the pause button, as
/// the letters beside them are: the text waveform changes so small a gray cleanly.
const dial_radius_px = 22;
const ring_px = 2;
const sweep_px = 7; // How thick the ring is where it has swept
const arrow_half_px = 7; // The arrow's half width, and its height
const dial_gap_px = 22; // From the dial to the minutes left beside it
/// The dial's and the button's centre, up from the footer's baseline to its text's middle.
const icons_above_baseline_px = 11;
/// Steps of the sweep, as a clock's hours: each a refresh of the dial alone.
pub const dial_steps = 12;
/// From the pause button to the pace beside it.
const pace_gap_px = 20;
const pause_radius_px = 24;
const pause_x = footer_margin_px + pause_radius_px;
/// A tap this near the button's centre is on it: a fingertip around it.
const icon_reach_px = 60;
comptime {
    assert(ring_px < sweep_px);
    assert(sweep_px + arrow_half_px < dial_radius_px);
    assert(2 * icon_reach_px >= style.fingertip);
    assert(icon_reach_px > pause_radius_px);
    // The phrase at its most lines lies between the lines before and after it
    const block: comptime_float = phrase_lines_max * phrase_px * phrase_line_spacing;
    const half_block: u32 = @intFromFloat(@floor(block / 2.0));
    assert(text_top + before_below_top_px + context_px < phrase_middle_y - half_block);
    assert(map_phrase_px > map_word_px);
}

/// The whole screen afresh, with a flash: the phrases, the clock above, the footer and
/// the map; where the dial went.
pub fn show_whole(run: *const Run, a: *app.App, s: *sess.Session) !i32 {
    assert(run.place != null); // Its phrase set, or the book's end
    assert(a.running_pace != null); // The footer shows it
    const page = a.display.on_screen();
    page.fill_rect(0, 0, a.display.screen.width, a.display.screen.height, style.white);
    a.stamp_clock();
    try draw_phrases(run, a, s);
    const dial_x = try draw_footer(run, a, s);
    try draw_map(a, s, run.phrase);
    try a.display.screen.wait_complete(try a.display.screen.show(.flash));
    return dial_x;
}

/// What a move put on screen: the phrases, the footer and the map, the map on the
/// page the reader's place has followed to, all in one clean refresh; where the dial
/// went.
pub fn show_moved(run: *const Run, a: *app.App, s: *sess.Session) !i32 {
    assert(run.place != null);
    assert(a.running_pace != null); // The footer shows it
    try draw_phrases(run, a, s);
    const dial_x = try draw_footer(run, a, s);
    try draw_map(a, s, run.phrase);
    const height = a.display.screen.height - map_top;
    const screen = a.display.screen;
    const marker = try screen.show_region(0, map_top, screen.width, height, .page);
    try a.display.screen.wait_complete(marker);
    return dial_x;
}

/// The phrase on screen, large and bold, centred about `phrase_middle_y`, the end of
/// the one before it above and the start of the one after below, small; at the
/// book's end, saying so. Drawn into the screen, not shown.
fn draw_phrases(run: *const Run, a: *app.App, s: *sess.Session) !void {
    assert(a.display.screen.height > text_top + footer_height_px);
    assert(run.history_len <= run.history.len);
    const page = a.display.on_screen();
    const band = a.display.screen.height - footer_height_px - text_top;
    page.fill_rect(0, text_top, a.display.screen.width, band, 0xff);
    const family = a.settings.family_index();
    const big = try a.typefaces.phrase_face(family, true, phrase_px);
    const small = try a.typefaces.phrase_face(family, false, context_px);
    const width: f32 = @floatFromInt(a.display.screen.width - 2 * phrase_margin_px);
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
            const footer_top = a.display.screen.height - footer_height_px;
            const baseline: i32 = @intCast(footer_top - after_above_footer_px);
            try draw_line(a, small, head.text, baseline, .{ .after = head.cut });
        }
    } else {
        try draw_text(a, big, phrase_px, "The end", phrase_middle_y);
    }
}

/// The footer drawn again and shown alone; where the dial went.
pub fn show_footer(run: *const Run, a: *app.App, s: *sess.Session) !i32 {
    const dial_x = try draw_footer(run, a, s);
    const top = a.display.screen.height - footer_height_px;
    const screen = a.display.screen;
    const marker = try screen.show_region(0, top, screen.width, footer_height_px, .page);
    try a.display.screen.wait_complete(marker);
    return dial_x;
}

/// The footer: the pause button, two bars while the phrases go on and a triangle
/// once stopped; and the dial with the minutes left in the chapter beside it.
/// Drawn into the screen, not shown; gives back where the dial's centre went, which
/// follows the minutes' width.
fn draw_footer(run: *const Run, a: *app.App, s: *sess.Session) !i32 {
    const page = a.display.on_screen();
    const top = a.display.screen.height - footer_height_px;
    page.fill_rect(0, top, a.display.screen.width, footer_height_px, 0xff);
    const cy = icons_y(a);
    draw_pause_button(a, pause_x, cy, run.stopped_at != null);
    const baseline: i32 = @intCast(a.display.screen.height - footer_baseline_above_bottom_px);
    // Paused, the footer says so, white on a black bar seen from a stride away; going
    // on, it shows the pace, so a reader can see it follow their taps
    const paused = run.stopped_at != null and run.phrase != null;
    var pace_line: [32]u8 = undefined;
    const wpm: u32 = @intFromFloat(@round(a.running_pace.?));
    const pace = if (paused)
        "Paused \u{00B7} tap the middle to carry on"
    else
        std.fmt.bufPrint(&pace_line, "{d} words a minute", .{wpm}) catch "";
    const pace_x: f32 = @floatFromInt(pause_x + pause_radius_px + pace_gap_px);
    try a.footer.draw(page, pace_x, baseline, pace);
    // The minutes left in the chapter; past the book's last phrase, none
    var minutes_buffer: [48]u8 = undefined;
    var line: [64]u8 = undefined;
    var text: []const u8 = "End of the book";
    if (run.phrase) |p| {
        const words_left = s.chapter_words_left(.{ .para = p.para, .byte = p.start });
        assert(words_left >= p.words); // The phrase's own, at least
        const chapter_minutes = stats.minutes_at(a.running_pace.?, words_left);
        const left = stats.format_minutes(&minutes_buffer, chapter_minutes);
        text = std.fmt.bufPrint(&line, "{s} left in chapter", .{left}) catch "";
    }
    const right: f32 = @floatFromInt(a.display.screen.width - footer_margin_px);
    const text_x = right - try a.footer.measure(text);
    try a.footer.draw(page, text_x, baseline, text);
    const dial_x = @as(i32, @intFromFloat(text_x)) - dial_gap_px - dial_radius_px;
    // The dial stays clear of the pause button, whatever the minutes' width
    assert(dial_x - icon_reach_px > pause_x + icon_reach_px);
    draw_dial(a, dial_x, cy, run.dial_step, run.pace_moved);
    if (paused) invert(page, top, footer_height_px);
    return dial_x;
}
/// Whether a tap at (`x`, `y`) is on the pause button.
pub fn on_pause_button(a: *const app.App, x: i32, y: i32) bool {
    const cy = icons_y(a);
    return @abs(x - pause_x) <= icon_reach_px and @abs(y - cy) <= icon_reach_px;
}

/// The phrase at `at`, or the first after it, as long as fits the screen at the
/// phrase's size (model/phrases.zig).
pub fn phrase_at(a: *app.App, s: *const sess.Session, at: book_model.Pos) !?phrases.Phrase {
    const font = try a.typefaces.phrase_face(a.settings.family_index(), true, phrase_px);
    const width: f32 = @floatFromInt(a.display.screen.width - 2 * phrase_margin_px);
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
    assert(count <= text.len); // A word is a letter at least
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
    assert(count <= text.len); // A word is a letter at least
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
    const centre: f32 = @floatFromInt(a.display.screen.width / 2);
    try font.draw(a.display.on_screen(), centre - try font.measure(line) / 2, baseline, line);
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
    const page = a.display.on_screen();
    var lines: [lines_max][]const u8 = undefined;
    const width: f32 = @floatFromInt(a.display.screen.width - 2 * phrase_margin_px);
    const count = try wrap(font, text, width, &lines);
    assert(count > 0); // A phrase has a word at least
    const line_px: i32 = @intFromFloat(@as(f32, @floatFromInt(px)) * phrase_line_spacing);
    // Each line's text's middle sits a third of its size above its baseline
    const block = @as(i32, @intCast(count)) * line_px;
    var baseline = middle - @divTrunc(block, 2) + @divTrunc(line_px, 2) + @divTrunc(px, 3);
    const centre: f32 = @floatFromInt(a.display.screen.width / 2);
    for (lines[0..count]) |line| {
        const x = centre - try font.measure(line) / 2;
        try font.draw(page, x, baseline, line);
        baseline += line_px;
    }
}

/// The page map: the page holding the reader's place, drawn as the reader would see
/// it, shrunk to the corner, its words thin bars and `phrase`'s thick. Drawn into the
/// screen, not shown.
fn draw_map(a: *app.App, s: *sess.Session, phrase: ?phrases.Phrase) !void {
    assert(a.display.screen.width > map_margin_px + map_width_px);
    assert(map_top + map_height_px < text_top);
    const height = map_height_px;
    const edge = map_edge_px;
    const left = a.display.screen.width - map_margin_px - map_width_px;
    const page = a.display.on_screen();
    page.fill_rect(left, map_top, map_width_px, height, style.white);
    // Its edge
    page.fill_rect(left, map_top, map_width_px, edge, style.black);
    page.fill_rect(left, map_top + height - edge, map_width_px, edge, style.black);
    page.fill_rect(left, map_top, edge, height, style.black);
    page.fill_rect(left + map_width_px - edge, map_top, edge, height, style.black);
    // The page as drawn, for where its words are
    _ = try s.ensure(s.current, s.current);
    const words = s.page_words();
    const screen_width: f32 = @floatFromInt(a.display.screen.width);
    const scale = @as(f32, @floatFromInt(map_width_px)) / screen_width;
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
        const past_right = x + width >= left + map_width_px - edge;
        const past_foot = y + thick >= map_top + height - edge;
        if (past_right or past_foot) continue;
        page.fill_rect(x, @max(y, map_top + edge), width, thick, style.black);
    }
}

/// A length on the page, shrunk to the map; nothing for one off the page's top or left.
fn shrink(length: i32, scale: f32) u32 {
    assert(scale > 0);
    assert(scale < 1);
    return @intFromFloat(@as(f32, @floatFromInt(@max(length, 0))) * scale);
}

/// The dial swept to `step`, refreshed alone.
pub fn show_dial(a: *app.App, cx: i32, step: u32, arrow: ?Run.Pace) !void {
    assert(step < dial_steps);
    assert(cx > pause_x + icon_reach_px); // Right of the pause button, as drawn
    const cy = icons_y(a);
    draw_dial(a, cx, cy, step, arrow);
    const r = dial_radius_px;
    const side: u32 = 2 * r + 1;
    const screen = a.display.screen;
    const marker = try screen.show_region(@intCast(cx - r), @intCast(cy - r), side, side, .page);
    try a.display.screen.wait_complete(marker);
}

fn icons_y(a: *const app.App) i32 {
    const bottom: i32 = @intCast(a.display.screen.height);
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

/// Rows `top` to `top + height` turned over, black for white and white for black,
/// their smooth edges with them.
fn invert(page: Page, top: u32, height: u32) void {
    assert(height > 0);
    assert(top + height <= page.height);
    for (top..top + height) |row| {
        for (page.buf[row * page.stride ..][0..page.width]) |*pixel| pixel.* = 255 - pixel.*;
    }
}

/// How finely an icon's pixels are sampled for their smooth edges: this many across
/// and down, as the letters beside them are smoothed.
const samples = 4;

/// Paints the square of `side` pixels from (`left`, `top`) in each pixel's share of
/// `shape`: black where it covers it all, gray where only some, as smooth as the text.
/// `shape.inside(x, y)` takes a point from the square's middle.
fn paint(page: Page, left: u32, top: u32, side: u32, shape: anytype) void {
    assert(side > 0);
    assert(left + side <= page.width);
    assert(top + side <= page.height);
    const half = @as(f32, @floatFromInt(side)) / 2;
    for (0..side) |row| for (0..side) |column| {
        var covered: u32 = 0;
        for (0..samples) |i| for (0..samples) |j| {
            const x = sample_at(column, j) - half;
            const y = sample_at(row, i) - half;
            if (shape.inside(x, y)) covered += 1;
        };
        assert(covered <= samples * samples);
        const value = 255 - covered * 255 / (samples * samples);
        const y: u32 = top + @as(u32, @intCast(row));
        const x: u32 = left + @as(u32, @intCast(column));
        page.buf[y * page.stride + x] = @intCast(value);
    };
}

/// Sample `sample` of pixel `pixel`, across or down: evenly inside it.
fn sample_at(pixel: usize, sample: usize) f32 { // usize: loop counters
    assert(sample < samples);
    const offset = (@as(f32, @floatFromInt(sample)) + 0.5) / samples;
    return @as(f32, @floatFromInt(pixel)) + offset;
}

/// Whether (`x`, `y`) lies in a ring of `outer` and `inner` radii about the middle.
fn in_ring(x: f32, y: f32, outer: f32, inner: f32) bool {
    assert(inner < outer);
    const d2 = x * x + y * y;
    return d2 <= outer * outer and d2 >= inner * inner;
}

/// The pause button: a ring like the dial's, a little larger, with two bars in it while
/// the phrases go on, and a triangle to carry on once stopped.
const PauseShape = struct {
    stopped: bool,

    // Assertions: a pure shape test, asked once for each sample of each pixel
    fn inside(shape: PauseShape, x: f32, y: f32) bool {
        const r: f32 = pause_radius_px;
        if (in_ring(x, y, r, r - ring_px)) return true;
        const icon = r / 2; // The bars' and the triangle's half height
        if (@abs(y) > icon) return false;
        if (shape.stopped) {
            // A triangle pointing right, its middle a little right of the centre
            const from = -icon + 3;
            return x >= from and x - from <= 2 * (icon - @abs(y));
        }
        return @abs(x) >= 3 and @abs(x) <= 3 + 4; // Two bars
    }
};

/// The dial: a thin ring, thick where it has swept, with an arrow up or down in it.
const DialShape = struct {
    swept: f32, // How far round, from twelve o'clock, in radians
    arrow: ?Run.Pace,

    // Assertions: a pure shape test, asked once for each sample of each pixel
    fn inside(shape: DialShape, x: f32, y: f32) bool {
        const r: f32 = dial_radius_px;
        if (in_ring(x, y, r, r - ring_px)) return true;
        if (shape.swept > 0 and in_ring(x, y, r, r - sweep_px)) {
            // Clockwise from twelve o'clock
            var angle = std.math.atan2(x, -y);
            if (angle < 0) angle += std.math.tau;
            if (angle < shape.swept) return true;
        }
        const way = shape.arrow orelse return false;
        // A triangle, its point up for a quicker pace, down for a slower
        const h: f32 = arrow_half_px;
        const from_point = switch (way) {
            .up => y + h / 2,
            .down => h / 2 - y,
        };
        return from_point >= 0 and from_point <= h and @abs(x) <= from_point;
    }
};

/// The pause button centred on (`cx`, `cy`). Drawn into the screen, not shown.
fn draw_pause_button(a: *app.App, cx: i32, cy: i32, stopped: bool) void {
    const r = pause_radius_px;
    assert(cx - r >= 0);
    assert(cy + r < a.display.screen.height);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    paint(a.display.on_screen(), left, top, 2 * r + 1, PauseShape{ .stopped = stopped });
}

/// The dial centred on (`cx`, `cy`), swept `step` twelfths of the way round, with
/// `arrow` in its middle, up or down, when there is one. Drawn into the screen, not
/// shown.
fn draw_dial(a: *app.App, cx: i32, cy: i32, step: u32, arrow: ?Run.Pace) void {
    assert(step < dial_steps);
    const r = dial_radius_px;
    assert(cx - r >= 0);
    assert(cy + r < a.display.screen.height);
    const left: u32 = @intCast(cx - r);
    const top: u32 = @intCast(cy - r);
    const swept = @as(f32, @floatFromInt(step)) / dial_steps * std.math.tau;
    const shape: DialShape = .{ .swept = swept, .arrow = arrow };
    paint(a.display.on_screen(), left, top, 2 * r + 1, shape);
}
