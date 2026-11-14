//! Go to page: type a page number, jump there. Returns the page index, if any.
const std = @import("std");
const assert = std.debug.assert;
const keyboard = @import("../../ui/keyboard.zig");
const search_sheet = @import("../../ui/search_sheet.zig");
const style = @import("../../ui/style.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const screen = @import("../screen.zig");
const typing = @import("../typing.zig");
const Query = @import("../../model/search.zig").Query;

comptime {
    // The bar, then the space for a note, then the keyboard, top to bottom
    assert(toolbar.status_row < search_sheet.content_top);
    assert(search_sheet.content_top < keyboard.top);
}

/// A typed page number as a page index, or null when it isn't a page of this book.
pub fn page_index(typed: []const u8, page_count: u32) ?u32 {
    const number = std.fmt.parseInt(u32, typed, 10) catch return null;
    if (number < 1) return null;
    if (number > page_count) return null;
    const index = number - 1;
    assert(index < page_count);
    return index;
}

pub fn run(a: *app.App, s: *sess.Session) !?u32 {
    assert(s.pages.len > 0);
    assert(s.pages.len <= std.math.maxInt(u32));
    var entry = PageEntry{ .a = a, .page_count = @intCast(s.pages.len) };
    const index = try screen.run(a, &entry) orelse return null;
    assert(index < s.pages.len);
    return index;
}

/// A page number typed on the keyboard, under the toolbar.
const PageEntry = struct {
    pub const Result = u32;
    a: *app.App,
    page_count: u32,
    typed: Query = .{},
    note: []const u8 = "", // Why Enter did nothing, until the next tap

    pub fn draw(e: *PageEntry, part: screen.Part) !void {
        assert(e.page_count > 0);
        const a = e.a;
        const page = a.page(a.screen.pixels);
        var placeholder_buffer: [48]u8 = undefined;
        const placeholder = std.fmt.bufPrint(
            &placeholder_buffer,
            "Page, from 1 to {d}",
            .{e.page_count},
        ) catch "Page";
        const top = toolbar.status_row;
        try search_sheet.render_bar(a.ui, page, top, e.typed.slice(), placeholder, .none);
        const note_height = keyboard.top - search_sheet.content_top;
        page.fill_rect(0, search_sheet.content_top, page.width, note_height, 0xff);
        if (e.note.len > 0) {
            try a.ui.small.draw(page, style.margin, search_sheet.content_top + 56, e.note);
        }
        if (part == .all) try keyboard.render(a.ui, page);
        const bottom: u32 = if (part == .all) a.screen.height else keyboard.top;
        assert(bottom > top);
        try a.show_band(top, bottom - top);
    }

    pub fn on_tap(e: *PageEntry, t: screen.Tap) !screen.Step(u32) {
        assert(e.page_count > 0);
        if (search_sheet.bar_hit(t.x, t.y)) |h| return if (h == .cancel) .close else .stay;
        if (t.y < search_sheet.top) return .close; // Above the sheet
        e.note = "";
        if (typing.key(&e.typed, t, typing.digits) == .enter) {
            if (page_index(e.typed.slice(), e.page_count)) |index| {
                assert(index < e.page_count);
                return .{ .done = index };
            }
            e.note = "There's no such page in this book.";
        }
        return .{ .redraw = .changing };
    }
};

test "typed numbers become pages of this book" {
    try std.testing.expectEqual(@as(u32, 0), page_index("1", 760).?);
    try std.testing.expectEqual(@as(u32, 759), page_index("760", 760).?);
    try std.testing.expect(page_index("761", 760) == null);
    try std.testing.expect(page_index("0", 760) == null);
    try std.testing.expect(page_index("", 760) == null);
}
