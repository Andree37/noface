//! Typing to find something: a rounded search bar along the top with Cancel beside it,
//! what matches under it, and the keyboard below. The library lists matching books as
//! you type; book search and Go to page use the same bar. Every tap target is at least
//! a fingertip tall.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const icons = @import("icons.zig");
const keyboard = @import("keyboard.zig");
const catalog = @import("../model/catalog.zig");
const Fonts = @import("fonts.zig").Fonts;

/// Everything under the status strip is the sheet's.
pub const top = style.status_height;

const bar_gap = 16; // Over the bar, under the status strip
const bar_top = top + bar_gap;
const bar_height = style.fingertip;
/// The bar takes taps this far under what's drawn of it.
const bar_reach_below = 12;
const cancel_width = 170; // Room for "Cancel" and a fingertip either side of it
const field_right = style.screen_width - style.margin - cancel_width;
/// The field's pill stops this far short of Cancel's room.
const field_gap = 8;
/// Inside the field: the magnifier's middle and the text's start in from its left, the
/// text's start with no magnifier, the text's baseline under the field's middle, the
/// placeholder's gray band and the cursor in from the field's top and bottom, the
/// cursor's width and its gap after the typed text.
const field = struct {
    const icon_inset = 52;
    const icon_scale = 0.8;
    const text_inset = 96;
    const text_inset_plain = 44;
    const baseline_drop = 12;
    const tint_inset = 20;
    const cursor_inset = 26;
    const cursor_width = 3;
    const cursor_gap = 4;
    const placeholder_shade = 0x90;
};

const rows_gap = 24; // Between the bar and the rows
const rows_top = bar_top + bar_height + rows_gap;
/// Where what's under the bar starts: a note line, then a list.
pub const content_top = rows_top;
const row_height = 112;
const rows_gap_below = 16; // Over the keyboard
const rows_bottom = keyboard.top - rows_gap_below;
/// A row's title's and author's baselines, and the author's gray band, down from its top.
const row_title_drop = 50;
const row_author_drop = 88;
const row_author_tint_drop = 64;
const row_author_tint_height = 34;
/// The hint or "No books match." on the first row: its baseline, and the hint's gray
/// band, down from the rows' top.
const note_drop = 56;
const note_tint_drop = 20;
const note_tint_height = 50;
/// "Press Search to see them all." over the rows' foot: its baseline's rise, and its
/// gray band's rise and height.
const more_rise = 12;
const more_tint_rise = 40;
const more_tint_height = 36;

/// How many matching books fit between the bar and the keyboard.
pub const max_rows = (rows_bottom - rows_top) / row_height;

comptime {
    // The bar, the rows and the keyboard each have their own band, top to bottom.
    assert(bar_top + bar_height + bar_reach_below <= rows_top);
    assert(rows_top + max_rows * row_height <= rows_bottom);
    assert(rows_bottom < keyboard.top);
    assert(max_rows >= 5);
    assert(style.margin + 2 * bar_height < field_right); // The field is wider than its ends
    // Every tap target is a fingertip tall, or wide.
    assert(row_height >= style.fingertip);
    assert(bar_height >= style.fingertip);
    assert(cancel_width >= style.fingertip);
}

pub const Hit = union(enum) { none, cancel, field, row: u32 };

/// The bar's own taps, or null below it.
pub fn bar_hit(x: i32, y: i32) ?Hit {
    if (y < top or y >= bar_top + bar_height + bar_reach_below) return null;
    return if (x >= field_right) .cancel else .field;
}

pub fn hit(x: i32, y: i32, rows: u32) Hit {
    assert(rows <= max_rows);
    if (bar_hit(x, y)) |h| return h;
    if (y >= rows_top and y < rows_bottom) {
        const row: u32 = @intCast(@divTrunc(y - rows_top, row_height));
        assert(row < max_rows + 1); // The band below the last whole row is a part row
        if (row < rows) return .{ .row = row };
    }
    return .none;
}

pub const Icon = enum { search, none };

/// Clears from `from` (the bottom of the status strip above) down to `content_top`
/// and draws the bar: a magnifier when searching, what's typed (or the
/// `placeholder`), a cursor, and Cancel.
pub fn render_bar(
    fonts: Fonts,
    page: Page,
    from: u32,
    query: []const u8,
    placeholder: []const u8,
    icon: Icon,
) !void {
    assert(from <= content_top);
    assert(placeholder.len > 0);
    page.fill_rect(0, from, page.width, content_top - from, style.white);
    const r: f32 = bar_height / 2;
    const cy: f32 = bar_top + r;
    const left: f32 = style.margin;
    const right: f32 = field_right - field_gap;
    page.pill(left + r, right - r, cy, r, 0x00);
    page.pill(left + r, right - r, cy, r - 2, 0xff);
    const icon_x = left + field.icon_inset;
    if (icon == .search) icons.search_scaled(page, icon_x, cy, field.icon_scale);
    const inset: f32 = if (icon == .search) field.text_inset else field.text_inset_plain;
    const text_x = left + inset;
    const baseline: i32 = @intFromFloat(cy + field.baseline_drop);
    const avail = right - r / 2 - text_x;
    if (query.len == 0) {
        try fonts.small.draw(page, text_x, baseline, placeholder);
        const avail_px: u32 = @intFromFloat(avail);
        const tint_top = bar_top + field.tint_inset;
        const tint_height = bar_height - 2 * field.tint_inset;
        const shade = field.placeholder_shade;
        page.tint(@intFromFloat(text_x), tint_top, avail_px, tint_height, shade);
    } else {
        try draw.clipped(fonts.small, page, text_x, baseline, query, avail);
    }
    const typed = @min(try fonts.small.measure(query), avail);
    const gap: f32 = if (query.len > 0) field.cursor_gap else 0;
    const cursor: u32 = @intFromFloat(text_x + typed + gap);
    const cursor_top = bar_top + field.cursor_inset;
    const cursor_height = bar_height - 2 * field.cursor_inset;
    page.fill_rect(cursor, cursor_top, field.cursor_width, cursor_height, style.black);
    try draw.centered(fonts.small, page, field_right + cancel_width / 2, baseline, "Cancel");
}

fn draw_row(fonts: Fonts, page: Page, y: u32, e: *const catalog.Entry) !void {
    assert(y >= rows_top);
    assert(y + row_height <= rows_bottom);
    const avail: f32 = @floatFromInt(page.width - 2 * style.margin);
    const title_y: i32 = @intCast(y + row_title_drop);
    try draw.clipped(fonts.small, page, style.margin, title_y, e.title, avail);
    if (e.author.len > 0) {
        const author_y: i32 = @intCast(y + row_author_drop);
        try draw.clipped(fonts.caption, page, style.margin, author_y, e.author, avail);
        const tint_top = y + row_author_tint_drop;
        const tint_width: u32 = @intFromFloat(avail);
        page.tint(style.margin, tint_top, tint_width, row_author_tint_height, style.quiet);
    }
    page.fill_rect(style.margin, y + row_height - 1, page.width - 2 * style.margin, 1, style.rule);
}

/// The sheet over the status strip's screen. `matches` are indexes into `entries`,
/// at most `max_rows` of them; `more` says whether others matched too.
pub fn render(
    fonts: Fonts,
    page: Page,
    query: []const u8,
    entries: []const catalog.Entry,
    matches: []const u32,
    more: bool,
) !void {
    assert(matches.len <= max_rows);
    assert(page.height > rows_bottom);
    page.fill_rect(0, top, page.width, page.height - top, style.white);
    try render_bar(fonts, page, top, query, "Title or author", .search);
    const width = page.width - 2 * style.margin;
    if (query.len == 0) {
        const hint = "Find a book by its title or its author.";
        try fonts.small.draw(page, style.margin, rows_top + note_drop, hint);
        const tint_top = rows_top + note_tint_drop;
        page.tint(style.margin, tint_top, width, note_tint_height, style.quiet);
    } else if (matches.len == 0) {
        try fonts.small.draw(page, style.margin, rows_top + note_drop, "No books match.");
    }
    for (matches, 0..) |match, index| {
        assert(match < entries.len); // An index into `entries`
        const y = rows_top + @as(u32, @intCast(index)) * row_height;
        try draw_row(fonts, page, y, &entries[match]);
    }
    if (more) {
        const see_all = "Press Search to see them all.";
        try fonts.caption.draw(page, style.margin, @intCast(rows_bottom - more_rise), see_all);
        const tint_top = rows_bottom - more_tint_rise;
        page.tint(style.margin, tint_top, width, more_tint_height, style.quiet);
    }
    try keyboard.render(fonts, page);
}

test "bar, rows and keyboard each get their own taps" {
    const bar_y = bar_top + bar_height / 2;
    const cancel_x = field_right + cancel_width / 2;
    try std.testing.expectEqual(Hit.cancel, hit(cancel_x, bar_y, 3));
    try std.testing.expectEqual(Hit.field, hit(style.screen_width / 4, bar_y, 3));
    const x = style.screen_width / 4;
    const first_row = rows_top + row_height / 2;
    try std.testing.expectEqual(Hit{ .row = 0 }, hit(x, first_row, 3));
    try std.testing.expectEqual(Hit{ .row = 2 }, hit(x, first_row + 2 * row_height, 3));
    try std.testing.expectEqual(Hit.none, hit(x, first_row + 3 * row_height, 3));
}

test "rows fit above the keyboard and are a fingertip tall" {
    try std.testing.expect(max_rows >= 5);
    try std.testing.expect(rows_top + max_rows * row_height <= rows_bottom);
    try std.testing.expect(row_height >= style.fingertip);
    try std.testing.expect(cancel_width >= style.fingertip);
}
