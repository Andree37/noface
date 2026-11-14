//! The Go To sheet under the toolbar: the book's contents, or its bookmarks and
//! highlights, a page of rows at a time.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const book_model = @import("../model/book.zig");
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const style = @import("style.zig");
const text = @import("../layout/text.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const top = 228; // Under the toolbar, which stays visible above
const tabs_baseline = top + 72;
pub const list_top = top + 112; // Above it: the tabs here, the query field in search
const row_height = 100;
pub const rows = 11;
const indent = 48; // Per level of nesting
const mark_width = 56; // Room for a bookmark or highlight sign before the text
const page_label_width = 140;
const pager = draw.bottom_pager;

comptime {
    if (list_top + rows * row_height > pager.top) @compileError("the list runs into the pager");
}

pub const Tab = enum { contents, notes };

pub const Mark = enum { none, bookmark, highlight };

/// One row: a chapter, a bookmark or a highlight.
/// `note`, when given, shows on the right instead of the page number ("" for nothing).
pub const Row = struct { label: []const u8, page: usize, depth: u8 = 0, mark: Mark = .none, note: ?[]const u8 = null };

pub fn pageCount(count: usize) usize {
    return @max(1, (count + rows - 1) / rows);
}

/// The list page holding a row, so the sheet opens where the reader is.
pub fn listPageOf(row: usize) usize {
    return row / rows;
}

/// The chapter being read: the last one starting at or before `para`.
pub fn current(chapters: []const book_model.Chapter, para: usize) ?usize {
    var found: ?usize = null;
    var best: u32 = 0;
    for (chapters, 0..) |c, i| {
        if (c.para <= para and (found == null or c.para >= best)) {
            found = i;
            best = c.para;
        }
    }
    return found;
}

pub const Hit = union(enum) { none, close, tab: Tab, row: usize, prev, next };

pub fn hit(x: i32, y: i32, list_page: usize, count: usize) Hit {
    if (y < top) return .close;
    if (y < list_top) return .{ .tab = if (x < style.screen_width / 2) .contents else .notes };
    if (pager.hit(x, y)) |h| return if (h == .prev) .prev else .next;
    const row: usize = @intCast(@divTrunc(y - list_top, row_height));
    if (row >= rows) return .none;
    const index = list_page * rows + row;
    return if (index < count) .{ .row = index } else .none;
}

/// A list shown a page of rows at a time: which page is up, and what a tap on it
/// means. Turning the page happens here, so a screen with a list only says what a
/// tapped row does.
pub const Pages = struct {
    page: usize = 0,

    pub const Tap = union(enum) {
        none, // Nothing: an empty row, or the page already first or last
        close, // Above the list
        tab: Tab,
        row: usize, // The index of the row tapped, in the whole list
        turned, // The page turned: draw it again
    };

    pub fn tap(p: *Pages, x: i32, y: i32, count: usize) Tap {
        return switch (hit(x, y, p.page, count)) {
            .prev => if (p.turn(-1, count)) .turned else .none,
            .next => if (p.turn(1, count)) .turned else .none,
            .none => .none,
            .close => .close,
            .tab => |t| .{ .tab = t },
            .row => |i| .{ .row = i },
        };
    }

    fn turn(p: *Pages, by: i2, count: usize) bool {
        const last = pageCount(count) - 1;
        const to = if (by < 0) p.page -| 1 else @min(p.page + 1, last);
        if (to == p.page) return false;
        p.page = to;
        return true;
    }
};

fn drawMark(page: Page, mark: Mark, x: f32, y: u32) void {
    const cy: f32 = @floatFromInt(y + row_height / 2);
    switch (mark) {
        .none => {},
        .bookmark => icons.bookmarkFilled(page, x + 17, cy),
        .highlight => icons.highlighter(page, x + 17, cy),
    }
}

/// Draws one page of rows. `reading` marks the row the reader is in.
pub fn render(fonts: Fonts, page: Page, tab: Tab, list: []const Row, reading: ?usize, list_page: usize) !void {
    page.fillRect(0, top, page.width, page.height - top, style.white);
    page.fillRect(0, top, page.width, 1, style.rule);
    const half: f32 = @floatFromInt(page.width / 2);
    try draw.choice(fonts, page, half / 2, .center, tabs_baseline, "Contents", tab == .contents, tabs_baseline + 14);
    try draw.choice(fonts, page, half + half / 2, .center, tabs_baseline, "Notes", tab == .notes, tabs_baseline + 14);
    const empty = if (tab == .contents) "This book has no contents list." else "No bookmarks or highlights yet.";
    try renderList(fonts, page, list, reading, list_page, empty);
}

/// The rows under the header, with the pager below. `empty` shows when there are none.
pub fn renderList(fonts: Fonts, page: Page, list: []const Row, reading: ?usize, list_page: usize, empty: []const u8) !void {
    page.fillRect(0, list_top - 12, page.width, page.height - (list_top - 12), style.white);
    page.fillRect(style.margin, list_top - 12, page.width - 2 * style.margin, 1, style.rule);
    if (list.len == 0) {
        try draw.centered(fonts.small, page, @floatFromInt(page.width / 2), list_top + 200, empty);
        return;
    }
    const first = list_page * rows;
    const end = @min(first + rows, list.len);
    const right: f32 = @floatFromInt(page.width - style.margin);
    for (list[first..end], first..) |r, i| {
        const y: u32 = list_top + @as(u32, @intCast(i - first)) * row_height;
        const baseline: i32 = @intCast(y + 62);
        const here = reading == i;
        var left: f32 = @floatFromInt(style.margin + @as(u32, @min(r.depth, 4)) * indent);
        if (r.mark != .none) {
            drawMark(page, r.mark, left, y);
            left += mark_width;
        }
        const font = if (here) fonts.title else fonts.small;
        try draw.clipped(font, page, left, baseline, r.label, right - page_label_width - left);
        if (here) page.fillRect(style.margin - 28, y + 22, 8, 56, style.black);
        var label: [16]u8 = undefined;
        const number = r.note orelse std.fmt.bufPrint(&label, "{d}", .{r.page + 1}) catch "";
        try fonts.caption.draw(page, right - try fonts.caption.measure(number), baseline, number);
    }
    try pager.render(fonts, page, list_page, pageCount(list.len));
}

test "the current chapter is the last one started" {
    const chapters = [_]book_model.Chapter{
        .{ .title = "a", .para = 0, .depth = 0 },
        .{ .title = "b", .para = 10, .depth = 0 },
        .{ .title = "b.1", .para = 12, .depth = 1 },
        .{ .title = "c", .para = 30, .depth = 0 },
    };
    try std.testing.expectEqual(@as(usize, 0), current(&chapters, 5).?);
    try std.testing.expectEqual(@as(usize, 2), current(&chapters, 20).?);
    try std.testing.expectEqual(@as(usize, 3), current(&chapters, 99).?);
    const late = [_]book_model.Chapter{.{ .title = "x", .para = 50, .depth = 0 }};
    try std.testing.expect(current(&late, 5) == null);
}

test "taps pick a tab, a row on the shown page, or close" {
    try std.testing.expectEqual(Hit.close, hit(600, 100, 0, 30));
    try std.testing.expectEqual(Hit{ .tab = .contents }, hit(300, top + 60, 0, 30));
    try std.testing.expectEqual(Hit{ .tab = .notes }, hit(900, top + 60, 0, 30));
    try std.testing.expectEqual(Hit{ .row = 0 }, hit(600, list_top + 10, 0, 30));
    try std.testing.expectEqual(Hit{ .row = rows + 2 }, hit(600, list_top + 2 * row_height + 10, 1, 30));
    try std.testing.expectEqual(Hit.none, hit(600, list_top + 9 * row_height + 10, 2, 30)); // Past the last
    try std.testing.expectEqual(@as(usize, 3), pageCount(30));
    try std.testing.expectEqual(@as(usize, 1), pageCount(0));
}

test "a list turns a page at a time, and not past either end" {
    var p = Pages{};
    const y = pager.top + 20;
    const prev_x = draw.Pager.prev_left + 10;
    const next_x = draw.Pager.next_left + 10;
    try std.testing.expect(p.tap(prev_x, y, 3 * rows) == .none); // Already first
    try std.testing.expect(p.tap(next_x, y, 3 * rows) == .turned);
    try std.testing.expect(p.tap(next_x, y, 3 * rows) == .turned);
    try std.testing.expect(p.tap(next_x, y, 3 * rows) == .none); // Already last
    try std.testing.expectEqual(@as(usize, 2), p.page);
    try std.testing.expectEqual(Pages.Tap{ .row = 2 * rows }, p.tap(100, list_top + 10, 3 * rows));
}

test "the list fits on screen" {
    try std.testing.expect(pager.bottom <= style.screen_height);
}
