//! Go to page: type a page number, jump there. Returns the page index, if any.
const std = @import("std");
const keyboard = @import("../../ui/keyboard.zig");
const search_sheet = @import("../../ui/search_sheet.zig");
const style = @import("../../ui/style.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const screen = @import("../screen.zig");
const typing = @import("../typing.zig");
const Query = @import("../../model/search.zig").Query;

/// A typed page number as a page index, or null when it isn't a page of this book.
pub fn page_index(typed: []const u8, pages: usize) ?usize {
    const n = std.fmt.parseInt(usize, typed, 10) catch return null;
    return if (n >= 1 and n <= pages) n - 1 else null;
}

pub fn run(a: *app.App, s: *sess.Session) !?usize {
    var entry = PageEntry{ .a = a, .pages = s.pages.len };
    return screen.run(a, &entry);
}

/// A page number typed on the keyboard, under the toolbar.
const PageEntry = struct {
    pub const Result = usize;
    a: *app.App,
    pages: usize,
    typed: Query = .{},
    note: []const u8 = "", // Why Enter did nothing, until the next tap

    pub fn draw(e: *PageEntry, part: screen.Part) !void {
        const a = e.a;
        const page = a.page(a.screen.pixels);
        var placeholder_buf: [48]u8 = undefined;
        const placeholder = std.fmt.bufPrint(&placeholder_buf, "Page, from 1 to {d}", .{e.pages}) catch "Page";
        try search_sheet.render_bar(a.ui, page, toolbar.status_row, e.typed.slice(), placeholder, .none);
        page.fill_rect(0, search_sheet.content_top, page.width, keyboard.top - search_sheet.content_top, 0xff);
        if (e.note.len > 0) try a.ui.small.draw(page, style.margin, search_sheet.content_top + 56, e.note);
        if (part == .all) try keyboard.render(a.ui, page);
        const bottom: u32 = if (part == .all) a.screen.height else keyboard.top;
        try a.show_band(toolbar.status_row, bottom - toolbar.status_row);
    }

    pub fn on_tap(e: *PageEntry, t: screen.Tap) !screen.Step(usize) {
        if (search_sheet.bar_hit(t.x, t.y)) |h| return if (h == .cancel) .close else .stay;
        if (t.y < search_sheet.top) return .close; // Above the sheet
        e.note = "";
        if (typing.key(&e.typed, t, typing.digits) == .enter) {
            if (page_index(e.typed.slice(), e.pages)) |index| return .{ .done = index };
            e.note = "There's no such page in this book.";
        }
        return .{ .redraw = .changing };
    }
};

test "typed numbers become pages of this book" {
    try std.testing.expectEqual(@as(usize, 0), page_index("1", 760).?);
    try std.testing.expectEqual(@as(usize, 759), page_index("760", 760).?);
    try std.testing.expect(page_index("761", 760) == null);
    try std.testing.expect(page_index("0", 760) == null);
    try std.testing.expect(page_index("", 760) == null);
}
