//! Typing to find something: a rounded search bar along the top with Cancel beside it,
//! what matches under it, and the keyboard below. The library lists matching books as
//! you type; book search and Go to page use the same bar. Every tap target is at least
//! a fingertip (about 100 px) tall.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const icons = @import("icons.zig");
const keyboard = @import("keyboard.zig");
const catalog = @import("../model/catalog.zig");
const Fonts = @import("fonts.zig").Fonts;

/// Everything under the status strip is the sheet's.
pub const top = style.status_height;

const bar_top = top + 16;
const bar_height = 100;
const cancel_width = 170; // Room for "Cancel" and a fingertip either side of it
const field_right = style.screen_width - style.margin - cancel_width;

const rows_top = bar_top + bar_height + 24;
/// Where what's under the bar starts: a note line, then a list.
pub const content_top = rows_top;
const row_height = 112;
const rows_bottom = keyboard.top - 16;

/// How many matching books fit between the bar and the keyboard.
pub const max_rows = (rows_bottom - rows_top) / row_height;

pub const Hit = union(enum) { none, cancel, field, row: usize };

/// The bar's own taps, or null below it.
pub fn barHit(x: i32, y: i32) ?Hit {
    if (y < top or y >= bar_top + bar_height + 12) return null;
    return if (x >= field_right) .cancel else .field;
}

pub fn hit(x: i32, y: i32, rows: usize) Hit {
    if (barHit(x, y)) |h| return h;
    if (y >= rows_top and y < rows_bottom) {
        const row: usize = @intCast(@divTrunc(y - rows_top, row_height));
        if (row < rows) return .{ .row = row };
    }
    return .none;
}

pub const Icon = enum { search, none };

/// Clears from `from` (the bottom of the status strip above) down to `content_top`
/// and draws the bar: a magnifier when searching, what's typed (or the
/// `placeholder`), a cursor, and Cancel.
pub fn renderBar(fonts: Fonts, page: Page, from: u32, query: []const u8, placeholder: []const u8, icon: Icon) !void {
    page.fillRect(0, from, page.width, content_top - from, style.white);
    const r: f32 = bar_height / 2;
    const cy: f32 = bar_top + r;
    const left: f32 = style.margin;
    const right: f32 = field_right - 8;
    page.pill(left + r, right - r, cy, r, 0x00);
    page.pill(left + r, right - r, cy, r - 2, 0xff);
    if (icon == .search) icons.searchScaled(page, left + 52, cy, 0.8);
    const text_x = left + @as(f32, if (icon == .search) 96 else 44);
    const baseline: i32 = @intFromFloat(cy + 12);
    const avail = right - r / 2 - text_x;
    if (query.len == 0) {
        try fonts.small.draw(page, text_x, baseline, placeholder);
        page.tint(@intFromFloat(text_x), bar_top + 20, @intFromFloat(avail), bar_height - 40, 0x90);
    } else {
        try draw.clipped(fonts.small, page, text_x, baseline, query, avail);
    }
    const typed = @min(try fonts.small.measure(query), avail);
    const cursor = text_x + typed + (if (query.len > 0) @as(f32, 4) else 0);
    page.fillRect(@intFromFloat(cursor), bar_top + 26, 3, bar_height - 52, style.black);
    try draw.centered(fonts.small, page, field_right + cancel_width / 2, baseline, "Cancel");
}

fn drawRow(fonts: Fonts, page: Page, y: u32, e: *const catalog.Entry) !void {
    const avail: f32 = @floatFromInt(page.width - 2 * style.margin);
    try draw.clipped(fonts.small, page, style.margin, @intCast(y + 50), e.title, avail);
    if (e.author.len > 0) {
        try draw.clipped(fonts.caption, page, style.margin, @intCast(y + 88), e.author, avail);
        page.tint(style.margin, y + 64, @intFromFloat(avail), 34, style.quiet);
    }
    page.fillRect(style.margin, y + row_height - 1, page.width - 2 * style.margin, 1, style.rule);
}

/// The sheet over the status strip's screen. `matches` are indexes into `entries`,
/// at most `max_rows` of them; `more` says whether others matched too.
pub fn render(fonts: Fonts, page: Page, query: []const u8, entries: []const catalog.Entry, matches: []const usize, more: bool) !void {
    page.fillRect(0, top, page.width, page.height - top, style.white);
    try renderBar(fonts, page, top, query, "Title or author", .search);
    if (query.len == 0) {
        try fonts.small.draw(page, style.margin, rows_top + 56, "Find a book by its title or its author.");
        page.tint(style.margin, rows_top + 20, page.width - 2 * style.margin, 50, style.quiet);
    } else if (matches.len == 0) {
        try fonts.small.draw(page, style.margin, rows_top + 56, "No books match.");
    }
    for (matches, 0..) |m, i| try drawRow(fonts, page, rows_top + @as(u32, @intCast(i)) * row_height, &entries[m]);
    if (more) {
        try fonts.caption.draw(page, style.margin, @intCast(rows_bottom - 12), "Press Search to see them all.");
        page.tint(style.margin, rows_bottom - 40, page.width - 2 * style.margin, 36, style.quiet);
    }
    try keyboard.render(fonts, page);
}

test "bar, rows and keyboard each get their own taps" {
    try std.testing.expectEqual(Hit.cancel, hit(1150, bar_top + 50, 3));
    try std.testing.expectEqual(Hit.field, hit(300, bar_top + 50, 3));
    try std.testing.expectEqual(Hit{ .row = 0 }, hit(300, rows_top + 10, 3));
    try std.testing.expectEqual(Hit{ .row = 2 }, hit(300, rows_top + 2 * row_height + 10, 3));
    try std.testing.expectEqual(Hit.none, hit(300, rows_top + 3 * row_height + 10, 3));
}

test "rows fit above the keyboard and are a fingertip tall" {
    try std.testing.expect(max_rows >= 5);
    try std.testing.expect(rows_top + max_rows * row_height <= rows_bottom);
    try std.testing.expect(row_height >= 100 and bar_height >= 100 and cancel_width >= 100);
}
