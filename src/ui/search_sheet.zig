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
const Font = @import("../gfx/font.zig").Font;

/// Where the bar's layout starts: under the library's status strip. A screen may draw
/// the sheet from higher up (`render_bar`'s `from`); the band down to here is then
/// the bar's too, so the same `from` goes to `bar_hit` and `hit`.
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
/// Inside the field, its text centred on its middle: the magnifier's middle and the
/// text's start in from its left, the text's start with no magnifier, the cursor in
/// from the field's top and bottom, the cursor's width and its gap after the typed
/// text, and how far the placeholder is faded.
const field = struct {
    const icon_inset = 52;
    const icon_scale = 0.8;
    const text_inset = 96;
    const text_inset_plain = 44;
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
const rows_bottom = keyboard.top; // Down to the keyboard's tray
/// A row's title's and quiet author's baselines, down from its top.
const row_title_drop = 50;
const row_author_drop = 88;
/// "Press Search to see them all.", quiet, over the rows' foot: its baseline's rise.
const more_rise = 12;

/// The note line under the bar, the first row's band: a hint, "No books match.", a
/// search's count, a page that isn't there.
pub const note_height = row_height;

/// The note line's baseline, its text centred in its band.
pub fn note_baseline(font: *const Font) i32 {
    const baseline = font.centred_baseline(rows_top, note_height);
    assert(baseline < rows_top + note_height);
    return baseline;
}

/// How many matching books fit between the bar and the keyboard.
pub const max_rows = (rows_bottom - rows_top) / row_height;

comptime {
    // The bar, the rows and the keyboard each have their own band, top to bottom.
    assert(bar_top + bar_height + bar_reach_below <= rows_top);
    assert(rows_top + max_rows * row_height <= rows_bottom);
    assert(rows_bottom <= keyboard.top);
    assert(max_rows >= 5);
    assert(style.margin + 2 * bar_height < field_right); // The field is wider than its ends
    // Every tap target is a fingertip tall, or wide.
    assert(row_height >= style.fingertip);
    assert(bar_height >= style.fingertip);
    assert(cancel_width >= style.fingertip);
}

pub const Hit = union(enum) { none, cancel, field, row: u32 };

/// The bar's own taps, from `from` (where the sheet is drawn from, as given to
/// `render_bar`) down to the bar's foot, or null outside them.
pub fn bar_hit(from: u32, x: i32, y: i32) ?Hit {
    assert(from <= top);
    if (y < from or y >= bar_top + bar_height + bar_reach_below) return null;
    return if (x >= field_right) .cancel else .field;
}

/// What a tap on a sheet drawn from `from` lands on, with `rows` rows listed.
pub fn hit(from: u32, x: i32, y: i32, rows: u32) Hit {
    assert(rows <= max_rows);
    if (bar_hit(from, x, y)) |h| return h;
    if (y >= rows_top and y < rows_bottom) {
        const row: u32 = @intCast(@divTrunc(y - rows_top, row_height));
        assert(row < max_rows + 1); // The band below the last whole row is a part row
        if (row < rows) return .{ .row = row };
    }
    return .none;
}

/// The middle of row `row`'s taps, on a sheet with that many rows or more.
pub fn place_row(row: u32) style.Point {
    assert(row < max_rows);
    const y: i32 = @intCast(rows_top + row * row_height + row_height / 2);
    const point: style.Point = .{ .x = style.screen_width / 2, .y = y };
    assert(std.meta.eql(hit(top, point.x, point.y, row + 1), Hit{ .row = row }));
    return point;
}

pub const Icon = enum { search, none };

/// Clears from `from` (the bottom of the status strip above, at most `top`) down to
/// `content_top` and draws the bar: a magnifier when searching, what's typed (or the
/// `placeholder`), a cursor, and Cancel.
pub fn render_bar(
    fonts: Fonts,
    page: Page,
    from: u32,
    query: []const u8,
    placeholder: []const u8,
    icon: Icon,
) !void {
    assert(from <= top);
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
    const baseline = fonts.small.centred_on(@intFromFloat(cy));
    const avail = right - r / 2 - text_x;
    var typed: f32 = 0; // How wide what's typed is drawn: the cursor follows it
    if (query.len == 0) {
        try fonts.small.draw(page, text_x, baseline, placeholder);
        const avail_px: u32 = @intFromFloat(avail);
        fonts.small.fade(page, @intFromFloat(text_x), baseline, avail_px, field.placeholder_shade);
    } else {
        // Its end, where letters are being typed, stays in view.
        typed = try draw.clipped_start(fonts.small, page, text_x, baseline, query, avail);
    }
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
        fonts.caption.fade(page, style.margin, author_y, @intFromFloat(avail), style.quiet);
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
        const hint_y = note_baseline(fonts.small);
        try fonts.small.draw(page, style.margin, hint_y, hint);
        fonts.small.fade(page, style.margin, hint_y, width, style.quiet);
    } else if (matches.len == 0) {
        const note_y = note_baseline(fonts.small);
        try fonts.small.draw(page, style.margin, note_y, "No books match.");
    }
    for (matches, 0..) |match, index| {
        assert(match < entries.len); // An index into `entries`
        const y = rows_top + @as(u32, @intCast(index)) * row_height;
        try draw_row(fonts, page, y, &entries[match]);
    }
    if (more) {
        const see_all = "Press Search to see them all.";
        const see_all_y: i32 = @intCast(rows_bottom - more_rise);
        try fonts.caption.draw(page, style.margin, see_all_y, see_all);
        fonts.caption.fade(page, style.margin, see_all_y, width, style.quiet);
    }
    try keyboard.render(fonts, page);
}

test "bar, rows and keyboard each get their own taps" {
    const bar_y = bar_top + bar_height / 2;
    const cancel_x = field_right + cancel_width / 2;
    try std.testing.expectEqual(Hit.cancel, hit(top, cancel_x, bar_y, 3));
    try std.testing.expectEqual(Hit.field, hit(top, style.screen_width / 4, bar_y, 3));
    const x = style.screen_width / 4;
    const first_row = rows_top + row_height / 2;
    try std.testing.expectEqual(Hit{ .row = 0 }, hit(top, x, first_row, 3));
    try std.testing.expectEqual(Hit{ .row = 2 }, hit(top, x, first_row + 2 * row_height, 3));
    try std.testing.expectEqual(Hit.none, hit(top, x, first_row + 3 * row_height, 3));
}

test "a sheet drawn from higher up takes taps from where it's drawn" {
    const x = style.screen_width / 4;
    const from = top / 2;
    try std.testing.expectEqual(@as(?Hit, null), bar_hit(top, x, from));
    try std.testing.expectEqual(@as(?Hit, Hit.field), bar_hit(from, x, from));
    try std.testing.expectEqual(@as(?Hit, null), bar_hit(from, x, from - 1));
}

test "rows fit above the keyboard and are a fingertip tall" {
    try std.testing.expect(max_rows >= 5);
    try std.testing.expect(rows_top + max_rows * row_height <= rows_bottom);
    try std.testing.expect(row_height >= style.fingertip);
    try std.testing.expect(cancel_width >= style.fingertip);
}
