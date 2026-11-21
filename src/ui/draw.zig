//! Small drawing pieces several screens use.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;
const icons = @import("icons.zig");

/// A back arrow at the left margin with where it goes back to beside it: Home on the
/// toolbar, Library on the screens over the library. Its arrow's middle and its label's
/// left in from the margin; the label is centred on the arrow's middle.
pub const back_link = struct {
    pub const arrow_inset = style.space.snug;
    pub const label_inset = style.space.wide;
    /// Its arrow's middle under the strip above it: the reader's status line on the
    /// toolbar, the library's status strip on the screens over the library.
    pub const drop = style.space.wide;
};

/// The back link, the arrow's middle at `centre_y`.
pub fn draw_back_link(font: *Font, page: Page, centre_y: u32, label: []const u8) !void {
    assert(label.len > 0);
    assert(centre_y > 0);
    icons.back(page, style.margin + back_link.arrow_inset, @floatFromInt(centre_y));
    const baseline = font.centred_on(@intCast(centre_y));
    try font.draw(page, style.margin + back_link.label_inset, baseline, label);
}

/// Text centred on `center_x`.
pub fn centered(font: *Font, page: Page, center_x: f32, y: i32, s: []const u8) !void {
    assert(std.math.isFinite(center_x));
    assert(center_x >= 0);
    try font.draw(page, center_x - try font.measure(s) / 2, y, s);
}

/// Text cut to `avail`, ending in "..." when it doesn't fit.
pub fn clipped(font: *Font, page: Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
    assert(std.math.isFinite(x));
    assert(std.math.isFinite(avail));
    const width = try font.measure(s);
    if (width <= avail) return font.draw(page, x, y, s);
    const dots = "...";
    var buffer: [256]u8 = undefined;
    const dots_width = try font.measure(dots);
    var cut = @min(try font.fit(s, avail - dots_width), buffer.len - dots.len);
    assert(cut <= s.len);
    // Never inside a character
    while (cut > 0 and cut < s.len and s[cut] & 0xc0 == 0x80) cut -= 1;
    const part = std.mem.trimEnd(u8, s[0..cut], " ");
    assert(part.len + dots.len <= buffer.len);
    @memcpy(buffer[0..part.len], part);
    @memcpy(buffer[part.len..][0..dots.len], dots);
    try font.draw(page, x, y, buffer[0 .. part.len + dots.len]);
}

/// Text cut at its start to `avail`, beginning with "..." when it doesn't fit, so the
/// end of what's being typed stays in view. Returns the width drawn.
pub fn clipped_start(font: *Font, page: Page, x: f32, y: i32, s: []const u8, avail: f32) !f32 {
    assert(std.math.isFinite(x));
    assert(std.math.isFinite(avail));
    const width = try font.measure(s);
    if (width <= avail) {
        try font.draw(page, x, y, s);
        return width;
    }
    const dots = "...";
    var buffer: [256]u8 = undefined;
    const start = try tail_start(font, s, avail - try font.measure(dots), buffer.len - dots.len);
    const tail = s[start..];
    assert(dots.len + tail.len <= buffer.len);
    @memcpy(buffer[0..dots.len], dots);
    @memcpy(buffer[dots.len..][0..tail.len], tail);
    const shown = buffer[0 .. dots.len + tail.len];
    try font.draw(page, x, y, shown);
    return font.measure(shown);
}

/// Where the longest end of `s` that fits `avail`, and is at most `len_max` bytes,
/// starts: never inside a character.
fn tail_start(font: *Font, s: []const u8, avail: f32, len_max: u32) !u32 {
    assert(std.math.isFinite(avail));
    assert(s.len <= std.math.maxInt(u32));
    const len: u32 = @intCast(s.len);
    // Ends of `s` only get narrower as they start later, so the start is found by halves.
    var low: u32 = len -| len_max;
    var high: u32 = len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try font.measure(s[middle..]) <= avail) high = middle else low = middle + 1;
    }
    var start = low;
    while (start < len and s[start] & 0xc0 == 0x80) start += 1;
    assert(start <= len);
    return start;
}

/// Where the line starting `s` ends to fit `avail`: after the last whole word that
/// fits (the word just before an overflowing space counts), or mid-word when even
/// the first word doesn't fit.
pub fn line_end(font: *Font, s: []const u8, avail: f32) !u32 {
    assert(s.len > 0);
    assert(s.len <= std.math.maxInt(u32));
    if (try font.measure(s) <= avail) return @intCast(s.len);
    const cut = try font.fit(s, avail);
    assert(cut <= s.len);
    if (cut < s.len and s[cut] == ' ' and cut > 0) return @intCast(cut);
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |space| {
        if (space > 0) return @intCast(space);
    }
    return @intCast(@max(cut, 1));
}

/// Wraps text over at most `lines` lines `step` apart, clipping the last, and
/// returns the lines used.
pub fn wrapped(
    font: *Font,
    page: Page,
    x: f32,
    y: i32,
    step: i32,
    s: []const u8,
    avail: f32,
    lines: u32,
) !u32 {
    assert(lines > 0);
    assert(step > 0);
    var rest = s;
    var line: u32 = 0;
    while (rest.len > 0 and line < lines) : (line += 1) {
        const row = y + @as(i32, @intCast(line)) * step;
        if (line + 1 == lines) {
            try clipped(font, page, x, row, rest, avail);
            return line + 1;
        }
        const n = try line_end(font, rest, avail);
        try font.draw(page, x, row, rest[0..n]);
        rest = std.mem.trimStart(u8, rest[n..], " ");
    }
    assert(line <= lines);
    return line;
}

/// An outlined box with rounded corners, the shape every button and bubble shares.
pub fn box(page: Page, x: u32, y: u32, w: u32, h: u32) void {
    assert(w > 2 * style.border);
    assert(h > 2 * style.border);
    // Corners that fit a box narrower than it is tall too
    const corner: f32 = @floatFromInt(@min(style.button_corner, @min(w, h) / 2));
    box_with(page, x, y, w, h, style.border, corner);
}

/// A box with an outline `edge` thick and corners of radius `corner`.
pub fn box_with(page: Page, x: u32, y: u32, w: u32, h: u32, edge: u32, corner: f32) void {
    assert(w > 2 * edge);
    assert(h > 2 * edge);
    page.round_rect(x, y, w, h, corner, style.black);
    const inner_corner = corner - @as(f32, @floatFromInt(edge));
    page.round_rect(x + edge, y + edge, w - 2 * edge, h - 2 * edge, inner_corner, style.white);
}

/// A sheet rising from the bottom of the screen from `top`: outlined, rounded at the
/// top (its bottom corners run off the screen), with a grab bar.
pub fn sheet(page: Page, top: u32) void {
    assert(top < page.height);
    assert(page.width > grab_bar_width);
    const h = page.height - top;
    // Taller than the room left, so the bottom corners fall off the screen
    const tall = h + style.sheet_corner;
    page.round_rect(0, top, page.width, tall, style.sheet_corner, style.black);
    const inner = style.sheet_corner - 1;
    page.round_rect(0, top + sheet_edge, page.width, tall, inner, style.white);
    const grab_left = page.width / 2 - grab_bar_width / 2;
    const grab_top = top + grab_bar_drop;
    const grab_corner = grab_bar_height / 2;
    page.round_rect(grab_left, grab_top, grab_bar_width, grab_bar_height, grab_corner, style.rule);
}

/// A sheet's black edge along its top, and the grab bar in its middle, down from its top.
const sheet_edge = 2;
const grab_bar_width = style.space.wider;
const grab_bar_height = style.space.tiny;
const grab_bar_drop = style.space.snug;

pub const Align = enum { left, center };

/// One option in a row of options: bold and underlined at `underline_y` when chosen.
/// `x` is its left edge or its centre.
pub fn choice(
    fonts: Fonts,
    page: Page,
    x: f32,
    align_to: Align,
    y: i32,
    label: []const u8,
    chosen: bool,
    underline_y: u32,
) !void {
    assert(std.math.isFinite(x));
    assert(x >= 0);
    const font = if (chosen) fonts.title else fonts.small;
    const w = try font.measure(label);
    const left = if (align_to == .center) x - w / 2 else x;
    try font.draw(page, left, y, label);
    if (chosen) {
        const left_px: u32 = @intFromFloat(left);
        const width_px: u32 = @intFromFloat(w);
        page.fill_rect(left_px, underline_y, width_px, style.underline, style.black);
    }
}

/// The "1 of 4" row with back and forward arrows, under a list shown a page at a time.
pub const Pager = struct {
    top: u32,
    bottom: u32,
    reach: ?u32 = null, // Taps count down to here, past `bottom`; else to `bottom`

    /// An arrow's taps, two fingertips across, and its middle a button's width either
    /// side of the screen's middle, clear of the count between them.
    const button = 2 * style.fingertip;
    const arrow_offset = button;
    pub const prev_left = style.screen_width / 2 - arrow_offset - button / 2;
    pub const next_left = style.screen_width / 2 + arrow_offset - button / 2;

    pub const Hit = enum { prev, next };

    pub fn hit(p: Pager, x: i32, y: i32) ?Hit {
        assert(p.top < p.bottom);
        const taps_bottom = p.reach orelse p.bottom;
        assert(taps_bottom >= p.bottom); // A reach takes more taps, never fewer
        if (y < p.top or y >= taps_bottom) return null;
        if (x >= prev_left and x < prev_left + button) return .prev;
        if (x >= next_left and x < next_left + button) return .next;
        return null;
    }

    /// The middle of an arrow's taps, inside the band it's drawn in.
    pub fn place(p: Pager, h: Hit) style.Point {
        assert(p.top < p.bottom);
        const left: i32 = switch (h) {
            .prev => prev_left,
            .next => next_left,
        };
        const middle: i32 = @intCast((p.top + p.bottom) / 2);
        const point: style.Point = .{ .x = left + button / 2, .y = middle };
        assert(p.hit(point.x, point.y).? == h);
        return point;
    }

    pub fn render(p: Pager, fonts: Fonts, page: Page, index: u32, pages: u32) !void {
        assert(p.top < p.bottom);
        assert(pages > 0);
        assert(index < pages);
        // The count and both arrows centred on the band's middle
        const middle: i32 = @intCast((p.top + p.bottom) / 2);
        var label: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&label, "{d} of {d}", .{ index + 1, pages }) catch "";
        const baseline = fonts.small.centred_on(middle);
        try centered(fonts.small, page, @floatFromInt(page.width / 2), baseline, count);
        const mid: f32 = @floatFromInt(middle);
        icons.pager_arrow(page, prev_left + button / 2, mid, false);
        icons.pager_arrow(page, next_left + button / 2, mid, true);
        // Faded when there's nowhere to go.
        const height = p.bottom - p.top;
        if (index == 0) page.tint(prev_left, p.top, button, height, style.disabled);
        if (index + 1 >= pages) page.tint(next_left, p.top, button, height, style.disabled);
    }
};

/// Where every list's pager sits: near the bottom, taking taps right to the edge,
/// so a thumb reaching low still turns the page.
pub const bottom_pager = Pager{
    .top = style.screen_height - pager_above_bottom,
    .bottom = style.screen_height - pager_bottom_above_bottom,
    .reach = style.screen_height,
};
/// The pager's band, its top and its foot up from the screen's: a fingertip and more
/// tall, a thumb's reach above the edge.
const pager_above_bottom = style.space.band + style.space.wider;
const pager_bottom_above_bottom = style.space.wide;

comptime {
    // The arrows' tap areas don't overlap, and both sit on the screen.
    assert(Pager.prev_left + Pager.button <= Pager.next_left);
    assert(Pager.next_left + Pager.button <= style.screen_width);
    assert(bottom_pager.top < bottom_pager.bottom);
    assert(bottom_pager.reach.? > bottom_pager.bottom);
}

test "the shared pager takes taps to the bottom edge" {
    // On the next arrow, at the screen's last row of pixels and just over the pager
    const x = Pager.next_left + 1;
    try std.testing.expectEqual(Pager.Hit.next, bottom_pager.hit(x, style.screen_height - 1).?);
    try std.testing.expect(bottom_pager.hit(x, bottom_pager.top - 1) == null);
}

test "pager arrows sit either side of the count" {
    const p = Pager{ .top = 100, .bottom = 200 };
    const prev_x = Pager.prev_left + 1;
    const next_x = Pager.next_left + 1;
    const count_x = style.screen_width / 2; // Between the arrows
    try std.testing.expectEqual(Pager.Hit.prev, p.hit(prev_x, 150).?);
    try std.testing.expectEqual(Pager.Hit.next, p.hit(next_x, 150).?);
    try std.testing.expect(p.hit(count_x, 150) == null);
    try std.testing.expect(p.hit(prev_x, 250) == null);
}

test "a line keeps a word that fits just before the space that overflows" {
    const go_regular = @embedFile("../testdata/fonts/Go-Regular.ttf");
    var font = try Font.init(go_regular, 40, 1.2);
    const s = "abc def ghi";
    // Exactly as wide as "abc def": the space after it is what overflows
    const avail = try font.measure("abc def");
    try std.testing.expectEqualStrings("abc def", s[0..try line_end(&font, s, avail)]);
    try std.testing.expectEqualStrings("abc", s[0..try line_end(&font, s, avail - 1)]);
}

test "a long field shows the end of what's typed" {
    const go_regular = @embedFile("../testdata/fonts/Go-Regular.ttf");
    var font = try Font.init(go_regular, 40, 1.2);
    const s = "the quick brown fox";
    const avail = try font.measure("brown fox");
    try std.testing.expectEqualStrings("brown fox", s[try tail_start(&font, s, avail, s.len)..]);
    try std.testing.expectEqualStrings("fox", s[try tail_start(&font, s, avail, 3)..]);
    // Just too narrow for "é au lait": the cut never lands inside the é
    const accented = "caf\xc3\xa9 au lait";
    const narrow = try font.measure(accented[3..]) - 1;
    const start = try tail_start(&font, accented, narrow, accented.len);
    try std.testing.expect(start > 3);
    try std.testing.expect(accented[start] & 0xc0 != 0x80);
    try std.testing.expect(try font.measure(accented[start..]) <= narrow);
}
