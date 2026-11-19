//! The Go To sheet under the toolbar: the book's contents, or its bookmarks and
//! highlights, a page of rows at a time.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const book_model = @import("../model/book.zig");
const draw = @import("draw.zig");
const icons = @import("icons.zig");
const style = @import("style.zig");
const toolbar = @import("toolbar.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const top = toolbar.top_height; // Under the toolbar, which stays visible above
/// The tabs' band over the list, or the query field's in search; the tabs' labels'
/// baseline in it, and the line under the open one under that.
const header_band = 112;
const tabs_baseline_drop = 72;
const tabs_underline_drop = 14;
const tabs_baseline = top + tabs_baseline_drop;
pub const list_top = top + header_band;
/// The rule over the list, this far over its first row.
const list_rule_rise = 12;
const row_height = style.fingertip;
const row_baseline = 62; // From a row's top to its text's baseline
/// As many rows as fit between the header and the pager.
pub const rows = (pager.top - list_top) / row_height;
/// "No bookmarks or highlights yet.", down from the list's top.
const empty_drop = 200;
/// A bookmark's or highlight's sign: its middle in from where the row's text would start.
const mark_middle_inset = 17;
/// The bar left of the row being read: in from the margin's edge, its top down from the
/// row's, and its size.
const reading_bar_outset = 28;
const reading_bar_drop = 22;
const reading_bar_width = 8;
const reading_bar_height = 56;
const indent = 48; // Per level of nesting
const depth_shown_max = 4; // Deeper rows are indented no further
const mark_width = 56; // Room for a bookmark or highlight sign before the text
const page_label_width = 140;
const pager = draw.bottom_pager;

comptime {
    if (list_top + rows * row_height > pager.top) @compileError("the list runs into the pager");
    assert(rows > 0);
    assert(row_baseline < row_height);
    assert(tabs_baseline < list_top);
    assert(pager.bottom <= style.screen_height);
    // The deepest row, marked, still leaves room for its text before the page number
    const text_left = style.margin + depth_shown_max * indent + mark_width;
    assert(text_left + page_label_width < style.screen_width - style.margin);
}

pub const Tab = enum { contents, notes };
const empty_contents = "This book has no contents list.";
const empty_notes = "No bookmarks or highlights yet.";

pub const Mark = enum { none, bookmark, highlight };

/// One row: a chapter, a bookmark or a highlight.
/// `note`, when given, shows on the right instead of the page number ("" for nothing).
pub const Row = struct {
    label: []const u8,
    page: u32,
    depth: u8 = 0,
    mark: Mark = .none,
    note: ?[]const u8 = null,
};

fn page_count(count: u32) u32 {
    const result: u32 = @max(1, (count + rows - 1) / rows); // Rounded up
    assert(result >= 1);
    assert(result * rows >= count);
    return result;
}

/// The list page holding a row, so the sheet opens where the reader is.
pub fn list_page_of(row: u32) u32 {
    const list_page = row / rows;
    assert(list_page * rows <= row);
    assert(row < (list_page + 1) * rows);
    return list_page;
}

/// The chapter being read: the last one starting at or before `para`.
pub fn current(chapters: []const book_model.Chapter, para: u32) ?u32 {
    assert(chapters.len <= std.math.maxInt(u32));
    var found: ?u32 = null;
    var best: u32 = 0;
    for (chapters, 0..) |c, i| {
        if (c.para <= para and (found == null or c.para >= best)) {
            found = @intCast(i);
            best = c.para;
        }
    }
    if (found) |i| {
        assert(i < chapters.len);
        assert(chapters[i].para <= para);
    }
    return found;
}

pub const Hit = union(enum) { none, close, tab: Tab, row: u32, prev, next };

/// The middle of a control's taps: a tab's, a row's of the list's page, the pager's
/// arrows', and closing's, on the toolbar above.
pub fn place(h: Hit) style.Point {
    const point: style.Point = switch (h) {
        .close => .{ .x = style.screen_width / 2, .y = top / 2 },
        .tab => |t| .{
            .x = switch (t) {
                .contents => style.screen_width / 4,
                .notes => style.screen_width * 3 / 4,
            },
            .y = (top + list_top) / 2,
        },
        .row => |r| .{
            .x = style.screen_width / 2,
            .y = @intCast(list_top + r % rows * row_height + row_height / 2),
        },
        .prev => pager.place(.prev),
        .next => pager.place(.next),
        .none => unreachable, // Not a control
    };
    assert(point.y < style.screen_height);
    return point;
}

test "every control's place is a tap on it" {
    const count = 2 * rows; // Two pages of rows
    const controls = [_]Hit{
        .close, .{ .tab = .contents }, .{ .tab = .notes }, .{ .row = 0 }, .{ .row = rows - 1 },
        .prev,  .next,
    };
    for (controls) |h| {
        const p = place(h);
        try std.testing.expectEqual(h, hit(p.x, p.y, 0, count));
    }
}

pub fn hit(x: i32, y: i32, list_page: u32, count: u32) Hit {
    if (y < top) return .close;
    if (y < list_top) return .{ .tab = if (x < style.screen_width / 2) .contents else .notes };
    if (pager.hit(x, y)) |h| return if (h == .prev) .prev else .next;
    assert(y >= list_top);
    const row: u32 = @intCast(@divTrunc(y - list_top, row_height));
    if (row >= rows) return .none;
    const index = list_page * rows + row;
    assert(index / rows == list_page);
    return if (index < count) .{ .row = index } else .none;
}

/// A list shown a page of rows at a time: which page is up, and what a tap on it
/// means. Turning the page happens here, so a screen with a list only says what a
/// tapped row does.
pub const Pages = struct {
    page: u32 = 0,

    pub const Tap = union(enum) {
        none, // Nothing: an empty row, or the page already first or last
        close, // Above the list
        tab: Tab,
        row: u32, // The index of the row tapped, in the whole list
        turned, // The page turned: draw it again
    };

    pub fn tap(p: *Pages, x: i32, y: i32, count: u32) Tap {
        assert(p.page < page_count(count));
        const result: Tap = switch (hit(x, y, p.page, count)) {
            .prev => if (p.turn(-1, count)) .turned else .none,
            .next => if (p.turn(1, count)) .turned else .none,
            .none => .none,
            .close => .close,
            .tab => |t| .{ .tab = t },
            .row => |i| row: {
                assert(i < count);
                break :row .{ .row = i };
            },
        };
        assert(p.page < page_count(count)); // Turned or not, still a page of the list
        return result;
    }

    fn turn(p: *Pages, by: i2, count: u32) bool {
        assert(by == -1 or by == 1);
        const last = page_count(count) - 1;
        const to = if (by < 0) p.page -| 1 else @min(p.page + 1, last);
        if (to == p.page) return false;
        p.page = to;
        assert(p.page <= last);
        return true;
    }
};

fn draw_mark(page: Page, mark: Mark, x: f32, y: u32) void {
    assert(mark != .none);
    assert(y >= list_top);
    const cy: f32 = @floatFromInt(y + row_height / 2);
    switch (mark) {
        .none => unreachable, // Asserted above: only marked rows draw one
        .bookmark => icons.bookmark_filled(page, x + mark_middle_inset, cy),
        .highlight => icons.highlighter(page, x + mark_middle_inset, cy),
    }
}

/// Draws one page of rows. `reading` marks the row the reader is in.
pub fn render(
    fonts: Fonts,
    page: Page,
    tab: Tab,
    list: []const Row,
    reading: ?u32,
    list_page: u32,
) !void {
    // The chapter being read is one of the contents
    if (reading) |r| assert(r < list.len);
    assert(tab == .contents or reading == null);
    page.fill_rect(0, top, page.width, page.height - top, style.white);
    page.fill_rect(0, top, page.width, 1, style.rule);
    const half: f32 = @floatFromInt(page.width / 2);
    const underline_y = tabs_baseline + tabs_underline_drop;
    const contents = tab == .contents;
    const baseline = tabs_baseline;
    const left_centre = half / 2;
    const right_centre = half + half / 2;
    try draw.choice(fonts, page, left_centre, .center, baseline, "Contents", contents, underline_y);
    try draw.choice(fonts, page, right_centre, .center, baseline, "Notes", !contents, underline_y);
    const empty = if (contents) empty_contents else empty_notes;
    try render_list(fonts, page, list, reading, list_page, empty);
}

/// The rows under the header, with the pager below. `empty` shows when there are none.
pub fn render_list(
    fonts: Fonts,
    page: Page,
    list: []const Row,
    reading: ?u32,
    list_page: u32,
    empty: []const u8,
) !void {
    const rule_y = list_top - list_rule_rise;
    page.fill_rect(0, rule_y, page.width, page.height - rule_y, style.white);
    page.fill_rect(style.margin, rule_y, page.width - 2 * style.margin, 1, style.rule);
    if (list.len == 0) {
        const middle: f32 = @floatFromInt(page.width / 2);
        try draw.centered(fonts.small, page, middle, list_top + empty_drop, empty);
        return;
    }
    const first = list_page * rows;
    // A page past the end would have nothing on it
    assert(first < list.len);
    const end = @min(first + rows, list.len);
    assert(end - first <= rows);
    const right: f32 = @floatFromInt(page.width - style.margin);
    for (list[first..end], first..) |r, i| {
        const y: u32 = list_top + @as(u32, @intCast(i - first)) * row_height;
        const baseline: i32 = @intCast(y + row_baseline);
        const here = if (reading) |reading_index| reading_index == i else false;
        const depth: u32 = @min(r.depth, depth_shown_max);
        var left: f32 = @floatFromInt(style.margin + depth * indent);
        if (r.mark != .none) {
            draw_mark(page, r.mark, left, y);
            left += mark_width;
        }
        const font = if (here) fonts.title else fonts.small;
        try draw.clipped(font, page, left, baseline, r.label, right - page_label_width - left);
        if (here) {
            const bar_left = style.margin - reading_bar_outset;
            const bar_top = y + reading_bar_drop;
            const bar_w = reading_bar_width;
            page.fill_rect(bar_left, bar_top, bar_w, reading_bar_height, style.black);
        }
        var label: [16]u8 = undefined;
        const number = r.note orelse std.fmt.bufPrint(&label, "{d}", .{r.page + 1}) catch "";
        try fonts.caption.draw(page, right - try fonts.caption.measure(number), baseline, number);
    }
    try pager.render(fonts, page, list_page, page_count(@intCast(list.len)));
}

test "the current chapter is the last one started" {
    const chapters = [_]book_model.Chapter{
        .{ .title = "a", .para = 0, .depth = 0 },
        .{ .title = "b", .para = 10, .depth = 0 },
        .{ .title = "b.1", .para = 12, .depth = 1 },
        .{ .title = "c", .para = 30, .depth = 0 },
    };
    try std.testing.expectEqual(@as(u32, 0), current(&chapters, 5).?);
    try std.testing.expectEqual(@as(u32, 2), current(&chapters, 20).?);
    try std.testing.expectEqual(@as(u32, 3), current(&chapters, 99).?);
    const late = [_]book_model.Chapter{.{ .title = "x", .para = 50, .depth = 0 }};
    try std.testing.expect(current(&late, 5) == null);
}

test "taps pick a tab, a row on the shown page, or close" {
    const x = style.screen_width / 2;
    const count = 2 * rows + rows / 2; // Two pages and a half
    try std.testing.expectEqual(Hit.close, hit(x, top - 1, 0, count));
    const tabs_y = (top + list_top) / 2;
    const contents_x = style.screen_width / 4;
    const notes_x = 3 * style.screen_width / 4;
    try std.testing.expectEqual(Hit{ .tab = .contents }, hit(contents_x, tabs_y, 0, count));
    try std.testing.expectEqual(Hit{ .tab = .notes }, hit(notes_x, tabs_y, 0, count));
    const first_row = list_top + row_height / 2;
    try std.testing.expectEqual(Hit{ .row = 0 }, hit(x, first_row, 0, count));
    const third_row = first_row + 2 * row_height;
    try std.testing.expectEqual(Hit{ .row = rows + 2 }, hit(x, third_row, 1, count));
    // Past the last, on the last page
    const past_last = first_row + (rows / 2) * row_height;
    try std.testing.expectEqual(Hit.none, hit(x, past_last, 2, count));
    try std.testing.expectEqual(@as(u32, 3), page_count(count));
    try std.testing.expectEqual(@as(u32, 1), page_count(0));
}

test "a list turns a page at a time, and not past either end" {
    var p = Pages{};
    const y = (pager.top + pager.bottom) / 2;
    const prev_x = draw.Pager.prev_left + 1;
    const next_x = draw.Pager.next_left + 1;
    try std.testing.expect(p.tap(prev_x, y, 3 * rows) == .none); // Already first
    try std.testing.expect(p.tap(next_x, y, 3 * rows) == .turned);
    try std.testing.expect(p.tap(next_x, y, 3 * rows) == .turned);
    try std.testing.expect(p.tap(next_x, y, 3 * rows) == .none); // Already last
    try std.testing.expectEqual(@as(u32, 2), p.page);
    const first_row = list_top + row_height / 2;
    const first_tap = p.tap(style.margin, first_row, 3 * rows);
    try std.testing.expectEqual(Pages.Tap{ .row = 2 * rows }, first_tap);
}

test "the list fits on screen" {
    try std.testing.expect(pager.bottom <= style.screen_height);
}
