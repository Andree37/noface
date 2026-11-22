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
const input_mod = @import("../../kindle/input.zig");
const Query = @import("../../model/search.zig").Query;

/// The sheet starts under the reader's status row, so is drawn and hit-tested from there.
const sheet_top = toolbar.status_row;

comptime {
    // The bar, then the space for a note, then the keyboard, top to bottom
    assert(sheet_top <= search_sheet.top);
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

/// The page number entry, to open over the page (`screen.open`): done with the index
/// of the page typed.
pub fn make(a: *app.App, s: *const sess.Session) PageEntry {
    assert(s.pages.len > 0);
    assert(s.pages.len <= std.math.maxInt(u32));
    return .{ .a = a, .page_count = @intCast(s.pages.len) };
}

/// A page number typed on the keyboard, under the toolbar.
pub const PageEntry = struct {
    pub const Result = u32;
    pub const touches = typing.touches;
    a: *app.App,
    page_count: u32,
    typed: Query = .{},
    typist: typing.Typist = .digits_first, // A page is a number
    note: []const u8 = "", // Why Enter did nothing, until the next tap

    pub fn draw(e: *PageEntry, part: screen.Part) !void {
        assert(e.page_count > 0);
        const a = e.a;
        const page = a.display.on_screen();
        var placeholder_buffer: [48]u8 = undefined;
        const placeholder = std.fmt.bufPrint(
            &placeholder_buffer,
            "Page, from 1 to {d}",
            .{e.page_count},
        ) catch "Page";
        const top = sheet_top;
        try search_sheet.render_bar(a.ui, page, top, e.typed.slice(), placeholder, .none);
        const note_height = keyboard.top - search_sheet.content_top;
        page.fill_rect(0, search_sheet.content_top, page.width, note_height, 0xff);
        if (e.note.len > 0) {
            const baseline = search_sheet.note_baseline(a.ui.small);
            try a.ui.small.draw(page, style.margin, baseline, e.note);
        }
        const keys_due = e.typist.redraw_keys(part == .all);
        if (keys_due) try keyboard.render(a.ui, page, e.typist.keys);
        const bottom: u32 = if (keys_due) a.display.screen.height else keyboard.top;
        assert(bottom > top);
        try a.display.show_band(top, bottom - top);
    }

    pub fn on_tap(e: *PageEntry, t: screen.Tap) !screen.Step(u32) {
        assert(e.page_count > 0);
        if (t.y < sheet_top) return .close; // Above the sheet
        if (search_sheet.bar_hit(sheet_top, t.x, t.y)) |h| {
            return if (h == .cancel) .close else .stay;
        }
        return e.edited(e.typist.tap(&e.typed, t.x, t.y, typing.digits));
    }

    /// A key held: as if tapped, but for a letter's accents, which a number has none of.
    pub fn on_action(e: *PageEntry, action: input_mod.Action) !screen.Step(u32) {
        // A finger followed after a hold, and the like, does nothing here
        if (action != .hold) return .stay;
        const h = action.hold;
        if (h.y < keyboard.top) return e.on_tap(.{ .x = h.x, .y = h.y, .us = 0 });
        return e.edited(e.typist.hold(&e.typed, h.x, h.y, typing.digits));
    }

    /// What a key did: the page for Enter, if it's one of the book's; else redrawn.
    fn edited(e: *PageEntry, edit: typing.Edit) screen.Step(u32) {
        assert(e.page_count > 0);
        e.note = "";
        if (edit.enter) {
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
