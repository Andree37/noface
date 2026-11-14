//! The reader's three-dots menu: go to a page, back to the start, book details,
//! a screen refresh, and marking the book finished or unread.
const std = @import("std");
const card = @import("../../ui/card.zig");
const catalog = @import("../../model/catalog.zig");
const stats = @import("../../model/stats.zig");
const store = @import("../../kindle/store.zig");
const app = @import("../../app.zig");
const book_actions = @import("../book_actions.zig");
const page_number = @import("page_number.zig");
const sess = @import("session.zig");
const highlights_model = @import("../../model/highlights.zig");

/// What the reader does after the menu.
pub const Result = union(enum) {
    stay, // Back to the toolbar
    page: usize, // Show this page
    refresh, // Show the current page with a full, clean refresh
};

const Option = enum { go_to_page, beginning, details, refresh, finished, unread, cancel };

fn label(o: Option) []const u8 {
    return switch (o) {
        .go_to_page => "Go to page\u{2026}",
        .beginning => "Go to beginning",
        .details => "Book details",
        .refresh => "Refresh screen",
        .finished => "Mark as finished",
        .unread => "Mark as unread",
        .cancel => "Cancel",
    };
}

pub fn run(a: *app.App, s: *sess.Session, entry: *catalog.Entry) !Result {
    // No Cancel: tapping above the sheet closes it
    const list = [_]Option{ .go_to_page, .beginning, .details, .refresh, if (entry.is_read()) .unread else .finished };
    var rows: [list.len]card.Row = undefined;
    for (list, &rows) |o, *r| r.* = .{ .label = label(o) };
    const background = try s.ensure(s.current, s.current);
    const picked = try app.choose_from_card(a, background, entry.title, entry.author, &rows) orelse return .stay;
    switch (list[picked]) {
        .cancel => return .stay,
        .go_to_page => return if (try page_number.run(a, s)) |index| .{ .page = index } else .stay,
        .beginning => return .{ .page = 0 },
        .refresh => return .refresh,
        .details => {
            try details(a, s, entry, background);
            return .stay;
        },
        .finished, .unread => |choice| {
            book_actions.mark_read(a, entry, choice == .finished);
            return .stay;
        },
    }
}

/// A sheet of facts about the book. Any tap closes it.
fn details(a: *app.App, s: *sess.Session, entry: *const catalog.Entry, background: []const u8) !void {
    var progress_buf: [64]u8 = undefined;
    var read_buf: [64]u8 = undefined;
    var left_buf: [64]u8 = undefined;
    var counts_buf: [96]u8 = undefined;
    var t1: [32]u8 = undefined;
    var t2: [32]u8 = undefined;
    const percent = (s.current + 1) * 100 / s.pages.len;
    const highlights = highlights_model.count(s.highlights.items);
    const rows = [_]card.Row{
        .{ .quiet = true, .label = std.fmt.bufPrint(&progress_buf, "Page {d} of {d}, {d}%", .{ s.current + 1, s.pages.len, percent }) catch "" },
        .{ .quiet = true, .label = if (stats.reading_time(&t1, s.seconds_read_total())) |time| std.fmt.bufPrint(&read_buf, "Read here for {s}", .{time}) catch "" else "Not read here yet" },
        .{ .quiet = true, .label = if (s.time_left(s.current).book) |m| std.fmt.bufPrint(&left_buf, "{s} left in the book", .{stats.format_minutes(&t2, m)}) catch "" else "Learning your reading speed" },
        .{ .quiet = true, .label = std.fmt.bufPrint(&counts_buf, "{d} chapters, {d} highlights, {d} bookmarks", .{ s.chapters.len, highlights, s.bookmarks.items.len }) catch "" },
    };
    _ = try app.choose_from_card(a, background, entry.title, entry.author, &rows);
}
