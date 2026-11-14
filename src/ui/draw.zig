//! Small drawing pieces several screens use.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;

/// Text centred on `center_x`.
pub fn centered(font: *Font, page: Page, center_x: f32, y: i32, s: []const u8) !void {
    try font.draw(page, center_x - try font.measure(s) / 2, y, s);
}

/// Text cut to `avail`, ending in "..." when it doesn't fit.
pub fn clipped(font: *Font, page: Page, x: f32, y: i32, s: []const u8, avail: f32) !void {
    const w = try font.measure(s);
    if (w <= avail) return font.draw(page, x, y, s);
    const dots = "...";
    var cut = @min(try font.fit(s, avail - try font.measure(dots)), 256 - dots.len);
    while (cut > 0 and cut < s.len and s[cut] & 0xc0 == 0x80) cut -= 1; // Never inside a character
    var buf: [256]u8 = undefined;
    const part = std.mem.trimEnd(u8, s[0..cut], " ");
    @memcpy(buf[0..part.len], part);
    @memcpy(buf[part.len..][0..dots.len], dots);
    try font.draw(page, x, y, buf[0 .. part.len + dots.len]);
}

/// Where the line starting `s` ends to fit `avail`: after the last whole word that
/// fits (the word just before an overflowing space counts), or mid-word when even
/// the first word doesn't fit.
pub fn lineEnd(font: *Font, s: []const u8, avail: f32) !usize {
    if (try font.measure(s) <= avail) return s.len;
    const cut = try font.fit(s, avail);
    if (cut < s.len and s[cut] == ' ' and cut > 0) return cut;
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |space| {
        if (space > 0) return space;
    }
    return @max(cut, 1);
}

/// Wraps text over at most `lines` lines `step` apart, clipping the last, and
/// returns the lines used.
pub fn wrapped(font: *Font, page: Page, x: f32, y: i32, step: i32, s: []const u8, avail: f32, lines: u32) !u32 {
    var rest = s;
    var line: u32 = 0;
    while (rest.len > 0 and line < lines) : (line += 1) {
        const row = y + @as(i32, @intCast(line)) * step;
        if (line + 1 == lines) {
            try clipped(font, page, x, row, rest, avail);
            return line + 1;
        }
        const n = try lineEnd(font, rest, avail);
        try font.draw(page, x, row, rest[0..n]);
        rest = std.mem.trimStart(u8, rest[n..], " ");
    }
    return line;
}

/// An outlined box with rounded corners, the shape every button and bubble shares.
pub fn box(page: Page, x: u32, y: u32, w: u32, h: u32) void {
    boxWith(page, x, y, w, h, style.border, @floatFromInt(@min(style.button_corner, h / 2)));
}

/// A box with an outline `edge` thick and corners of radius `corner`.
pub fn boxWith(page: Page, x: u32, y: u32, w: u32, h: u32, edge: u32, corner: f32) void {
    page.roundRect(x, y, w, h, corner, style.black);
    page.roundRect(x + edge, y + edge, w - 2 * edge, h - 2 * edge, corner - @as(f32, @floatFromInt(edge)), style.white);
}

/// A sheet rising from the bottom of the screen from `top`: outlined, rounded at the
/// top (its bottom corners run off the screen), with a grab bar.
pub fn sheet(page: Page, top: u32) void {
    const h = page.height - top;
    page.roundRect(0, top, page.width, h + style.sheet_corner, style.sheet_corner, style.black);
    page.roundRect(0, top + 2, page.width, h + style.sheet_corner, style.sheet_corner - 1, style.white);
    page.roundRect(page.width / 2 - 36, top + 18, 72, 8, 4, style.rule); // Grab bar
}

pub const Align = enum { left, center };

/// One option in a row of options: bold and underlined at `underline_y` when chosen.
/// `x` is its left edge or its centre.
pub fn choice(fonts: Fonts, page: Page, x: f32, align_to: Align, y: i32, label: []const u8, chosen: bool, underline_y: u32) !void {
    const font = if (chosen) fonts.title else fonts.small;
    const w = try font.measure(label);
    const left = if (align_to == .center) x - w / 2 else x;
    try font.draw(page, left, y, label);
    if (chosen) page.fillRect(@intFromFloat(left), underline_y, @intFromFloat(w), style.underline, style.black);

}

/// The "1 of 4" row with back and forward arrows, under a list shown a page at a time.
pub const Pager = struct {
    top: u32,
    bottom: u32,
    reach: u32 = 0, // Taps count down to here, when that's past `bottom`

    const button = 200;
    pub const prev_left = 340;
    pub const next_left = 732;

    pub const Hit = enum { prev, next };

    pub fn hit(p: Pager, x: i32, y: i32) ?Hit {
        if (y < p.top or y >= @max(p.bottom, p.reach)) return null;
        if (x >= prev_left and x < prev_left + button) return .prev;
        if (x >= next_left and x < next_left + button) return .next;
        return null;
    }

    pub fn render(p: Pager, fonts: Fonts, page: Page, index: usize, pages: usize) !void {
        const y: i32 = @intCast((p.top + p.bottom) / 2 + 12);
        var label: [32]u8 = undefined;
        const count = std.fmt.bufPrint(&label, "{d} of {d}", .{ index + 1, pages }) catch "";
        try centered(fonts.small, page, @floatFromInt(page.width / 2), y, count);
        const mid: f32 = @floatFromInt(y - 11);
        const prev_x: f32 = prev_left + button / 2;
        const next_x: f32 = next_left + button / 2;
        page.stroke(prev_x + 9, mid - 18, prev_x - 9, mid, 4);
        page.stroke(prev_x - 9, mid, prev_x + 9, mid + 18, 4);
        page.stroke(next_x - 9, mid - 18, next_x + 9, mid, 4);
        page.stroke(next_x + 9, mid, next_x - 9, mid + 18, 4);
        // Faded when there's nowhere to go.
        if (index == 0) page.tint(prev_left, p.top, button, p.bottom - p.top, style.disabled);
        if (index + 1 >= pages) page.tint(next_left, p.top, button, p.bottom - p.top, style.disabled);
    }
};

/// Where every list's pager sits: near the bottom, taking taps right to the edge,
/// so a thumb reaching low still turns the page.
pub const bottom_pager = Pager{ .top = 1530, .bottom = 1650, .reach = style.screen_height };

test "the shared pager takes taps to the bottom edge" {
    try std.testing.expectEqual(Pager.Hit.next, bottom_pager.hit(800, 1690).?);
    try std.testing.expect(bottom_pager.hit(800, 1500) == null);
}

test "pager arrows sit either side of the count" {
    const p = Pager{ .top = 100, .bottom = 200 };
    try std.testing.expectEqual(Pager.Hit.prev, p.hit(400, 150).?);
    try std.testing.expectEqual(Pager.Hit.next, p.hit(800, 150).?);
    try std.testing.expect(p.hit(600, 150) == null);
    try std.testing.expect(p.hit(400, 250) == null);
}

test "a line keeps a word that fits just before the space that overflows" {
    const c_memory = @import("../gfx/c_memory.zig");
    const memory = @import("../base/memory.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit(); // Fonts are kept for the app's life, so nothing frees them
    var budget = memory.Budget{ .name = "test", .child = arena.allocator(), .limit = 16 << 20 };
    c_memory.use(&budget);
    defer c_memory.useDefault();
    var font = try Font.init(arena.allocator(), @embedFile("../testdata/fonts/Go-Regular.ttf"), 40, 1.2);
    const s = "abc def ghi";
    // Exactly as wide as "abc def": the space after it is what overflows
    const avail = try font.measure("abc def");
    try std.testing.expectEqualStrings("abc def", s[0..try lineEnd(&font, s, avail)]);
    try std.testing.expectEqualStrings("abc", s[0..try lineEnd(&font, s, avail - 1)]);
}
