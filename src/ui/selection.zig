//! Text selection on a page: which words a finger covers, and how they look.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("style.zig");
const book_model = @import("../model/book.zig");
const Page = @import("../gfx/page.zig").Page;

/// The word exactly under a point, if any.
pub fn word_under(words: []const book_model.Word, x: i32, y: i32) ?book_model.Word {
    for (words) |w| {
        const across = x >= w.x and x < w.x + w.w;
        const down = y >= w.y and y < w.y + w.h;
        if (across and down) return w;
    }
    return null;
}

/// The word under or nearest to a point. Lines match by height first.
pub fn word_at(words: []const book_model.Word, x: i32, y: i32) ?u32 {
    var best: ?u32 = null;
    var best_row: i32 = std.math.maxInt(i32);
    var best_column: i32 = std.math.maxInt(i32);
    for (words, 0..) |w, index| {
        // How far the point is from the word, down and across: zero when inside it
        const row = if (y < w.y) w.y - y else if (y >= w.y + w.h) y - (w.y + w.h) + 1 else 0;
        const column = if (x < w.x) w.x - x else if (x >= w.x + w.w) x - (w.x + w.w) + 1 else 0;
        assert(row >= 0);
        assert(column >= 0);
        if (row < best_row or (row == best_row and column < best_column)) {
            best = @intCast(index);
            best_row = row;
            best_column = column;
        }
    }
    // Any word at all is nearest to somewhere.
    assert((best == null) == (words.len == 0));
    const found = best orelse return null;
    assert(found < words.len);
    return found;
}

const underline = style.space.hair;
const handle_radius = style.space.small;
const handle_reach = style.space.roomy; // Above the first line and below the last
pub const grab_distance = style.space.wider; // How near a finger counts as grabbing a handle
/// A handle's stem, and how far out from its word's edge it stands.
const stem = style.space.hair;
const handle_outset = style.border;

comptime {
    // A finger anywhere on a handle's disc grabs it, and the disc clears the line.
    assert(grab_distance > handle_radius);
    assert(handle_radius < handle_reach);
}

/// A handle at each end of the selection, like the marks in the margin of a proof.
pub const Handle = struct { x: i32, y: i32 };

pub fn start_handle(selected: []const book_model.Word) Handle {
    assert(selected.len > 0);
    const w = selected[0];
    return .{ .x = w.x - handle_outset, .y = w.y - handle_reach + @divTrunc(w.h, 4) };
}

pub fn end_handle(selected: []const book_model.Word) Handle {
    assert(selected.len > 0);
    const w = selected[selected.len - 1];
    return .{ .x = w.x + w.w + handle_outset, .y = w.y + w.h + handle_reach - @divTrunc(w.h, 4) };
}

pub fn near_handle(h: Handle, x: i32, y: i32) bool {
    return @abs(x - h.x) < grab_distance and @abs(y - h.y) < grab_distance;
}

/// Underlines the selected words line by line, with a handle at each end.
pub fn draw(page: Page, selected: []const book_model.Word) void {
    assert(selected.len > 0);
    var i: u32 = 0;
    while (i < selected.len) {
        var j = i;
        while (j + 1 < selected.len and selected[j + 1].y == selected[i].y) j += 1;
        const first_on_line = selected[i];
        const last_on_line = selected[j];
        const left = first_on_line.x;
        const right = last_on_line.x + last_on_line.w;
        const underline_y = first_on_line.y + first_on_line.h - underline - 2;
        const width = right - left;
        const line_y: u32 = @intCast(underline_y);
        page.fill_rect(@intCast(left), line_y, @intCast(width), underline, style.black);
        i = j + 1;
    }
    assert(i == selected.len); // Every line underlined, none twice
    const first = selected[0];
    const start = start_handle(selected);
    // Each handle's stem runs from the handle to its word, downward.
    assert(start.y <= first.y + first.h);
    const start_stem = first.y + first.h - start.y;
    const stem_left = start.x - stem / 2;
    page.fill_rect(@intCast(stem_left), @intCast(start.y), stem, @intCast(start_stem), style.black);
    page.disc(start.x, start.y, handle_radius, 0, style.black);
    const final = selected[selected.len - 1];
    const end = end_handle(selected);
    assert(end.y >= final.y);
    const end_stem_left = end.x - stem / 2;
    const end_stem = end.y - final.y;
    const end_top: u32 = @intCast(final.y);
    page.fill_rect(@intCast(end_stem_left), end_top, stem, @intCast(end_stem), style.black);
    page.disc(end.x, end.y, handle_radius, 0, style.black);
}

pub const Band = struct { top: u32, height: u32 };

/// Rows the selection and its handles touch.
pub fn band(selected: []const book_model.Word) Band {
    assert(selected.len > 0);
    const margin = handle_reach + handle_radius;
    const top = @max(selected[0].y - margin, 0);
    const last = selected[selected.len - 1];
    const bottom = last.y + last.h + margin;
    assert(bottom >= top); // Selected words run down the page
    return .{ .top = @intCast(top), .height = @intCast(bottom - top) };
}

fn word(x: i32, y: i32) book_model.Word {
    assert(x >= 0);
    assert(y >= 0);
    const w = style.space.wide;
    const h = style.space.roomy;
    return .{ .x = x, .y = y, .w = w, .h = h, .para = 0, .start = 0, .end = 1 };
}

test "finds the word under a finger" {
    const words = [_]book_model.Word{
        word(100, 100), word(200, 100),
        word(100, 160), word(200, 160),
    };
    try std.testing.expectEqual(@as(u32, 1), word_at(&words, 220, 120).?);
    try std.testing.expectEqual(@as(u32, 2), word_at(&words, 110, 170).?);
}

test "a finger between lines or past the edge snaps to the nearest word" {
    const words = [_]book_model.Word{
        word(100, 100), word(200, 100),
        word(100, 160), word(200, 160),
    };
    try std.testing.expectEqual(@as(u32, 1), word_at(&words, 900, 110).?);
    try std.testing.expectEqual(@as(u32, 0), word_at(&words, 10, 10).?);
}

test "no words means no selection" {
    try std.testing.expect(word_at(&.{}, 10, 10) == null);
}

test "band includes the handles" {
    const words = [_]book_model.Word{ word(100, 100), word(100, 160) };
    const b = band(&words);
    try std.testing.expect(b.top < 100);
    try std.testing.expect(b.top + b.height > 200);
}

test "a finger near a handle grabs it" {
    const words = [_]book_model.Word{ word(100, 100), word(200, 100) };
    const end = end_handle(&words);
    try std.testing.expect(near_handle(end, end.x + 20, end.y - 20));
    try std.testing.expect(!near_handle(end, 600, 600));
}
