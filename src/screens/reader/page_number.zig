//! Go to page: type a page number, jump there. Returns the page index, if any.
const std = @import("std");
const keyboard = @import("../../ui/keyboard.zig");
const search_sheet = @import("../../ui/search_sheet.zig");
const style = @import("../../ui/style.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// A typed page number as a page index, or null when it isn't a page of this book.
pub fn pageIndex(typed: []const u8, pages: usize) ?usize {
    const n = std.fmt.parseInt(usize, typed, 10) catch return null;
    return if (n >= 1 and n <= pages) n - 1 else null;
}

pub fn run(a: *app.App, s: *sess.Session) !?usize {
    var digits: [6]u8 = undefined;
    var len: usize = 0;
    var placeholder_buf: [48]u8 = undefined;
    const placeholder = std.fmt.bufPrint(&placeholder_buf, "Page, from 1 to {d}", .{s.pages.len}) catch "Page";
    var note: []const u8 = "";
    var whole = true; // Draw the keyboard the first time
    while (true) {
        const page = a.page(a.screen.pixels);
        try search_sheet.renderBar(a.ui, page, toolbar.status_row, digits[0..len], placeholder, .none);
        page.fillRect(0, search_sheet.content_top, page.width, keyboard.top - search_sheet.content_top, 0xff);
        if (note.len > 0) try a.ui.small.draw(page, style.margin, search_sheet.content_top + 56, note);
        if (whole) try keyboard.render(a.ui, page);
        const bottom: u32 = if (whole) a.screen.height else keyboard.top;
        try a.showBand(toolbar.status_row, bottom - toolbar.status_row);
        whole = false;

        const t = a.input.nextTap() orelse return null; // Locked, or leaving
        if (search_sheet.barHit(t.x, t.y)) |h| {
            if (h == .cancel) return null;
            continue;
        }
        if (t.y < search_sheet.top) return null; // Above the sheet
        note = "";
        switch (keyboard.hit(t.x, t.y) orelse continue) {
            .char => |c| {
                // Only digits mean anything here; letters are ignored
                if (std.ascii.isDigit(c) and len < digits.len) {
                    digits[len] = c;
                    len += 1;
                }
            },
            .backspace => len -|= 1,
            .space => {},
            .enter => {
                if (pageIndex(digits[0..len], s.pages.len)) |index| return index;
                note = "There's no such page in this book.";
            },
        }
    }
}

test "typed numbers become pages of this book" {
    try std.testing.expectEqual(@as(usize, 0), pageIndex("1", 760).?);
    try std.testing.expectEqual(@as(usize, 759), pageIndex("760", 760).?);
    try std.testing.expect(pageIndex("761", 760) == null);
    try std.testing.expect(pageIndex("0", 760) == null);
    try std.testing.expect(pageIndex("", 760) == null);
}
