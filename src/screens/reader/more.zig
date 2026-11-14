//! The reader's three-dots menu: go to a page, back to the start, book details,
//! a screen refresh, and marking the book finished or unread.
const std = @import("std");
const assert = std.debug.assert;
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

/// The longest label, so each fits its row on one line.
const label_bytes_max = 32;

fn label(option: Option) []const u8 {
    const text = switch (option) {
        .go_to_page => "Go to page\u{2026}",
        .beginning => "Go to beginning",
        .details => "Book details",
        .refresh => "Refresh screen",
        .finished => "Mark as finished",
        .unread => "Mark as unread",
        .cancel => "Cancel",
    };
    assert(text.len > 0);
    assert(text.len <= label_bytes_max);
    return text;
}

pub fn run(a: *app.App, s: *sess.Session, entry: *catalog.Entry) !Result {
    assert(s.pages.len > 0);
    assert(s.current < s.pages.len);
    // No Cancel: tapping above the sheet closes it
    const read_option: Option = if (entry.is_read()) .unread else .finished;
    const list = [_]Option{ .go_to_page, .beginning, .details, .refresh, read_option };
    var rows: [list.len]card.Row = undefined;
    for (list, &rows) |option, *row| row.* = .{ .label = label(option) };
    const background = try s.ensure(s.current, s.current);
    const picked = try app.choose_from_card(
        a,
        background,
        entry.title,
        entry.author,
        &rows,
    ) orelse return .stay;
    assert(picked < list.len);
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
fn details(
    a: *app.App,
    s: *sess.Session,
    entry: *const catalog.Entry,
    background: []const u8,
) !void {
    assert(s.pages.len > 0);
    assert(s.current < s.pages.len);
    const percent = (s.current + 1) * 100 / s.pages.len;
    assert(percent <= 100);
    var progress_buffer: [64]u8 = undefined;
    const progress = std.fmt.bufPrint(
        &progress_buffer,
        "Page {d} of {d}, {d}%",
        .{ s.current + 1, s.pages.len, percent },
    ) catch "";
    var time_read_buffer: [32]u8 = undefined;
    var read_buffer: [64]u8 = undefined;
    var read: []const u8 = "Not read here yet";
    if (stats.reading_time(&time_read_buffer, s.seconds_read_total())) |time| {
        read = std.fmt.bufPrint(&read_buffer, "Read here for {s}", .{time}) catch "";
    }
    var time_left_buffer: [32]u8 = undefined;
    var left_buffer: [64]u8 = undefined;
    var left: []const u8 = "Learning your reading speed";
    if (s.time_left(s.current).book) |minutes| {
        const time = stats.format_minutes(&time_left_buffer, minutes);
        left = std.fmt.bufPrint(&left_buffer, "{s} left in the book", .{time}) catch "";
    }
    var counts_buffer: [96]u8 = undefined;
    const highlights = highlights_model.count(s.highlights.items);
    const counts = std.fmt.bufPrint(
        &counts_buffer,
        "{d} chapters, {d} highlights, {d} bookmarks",
        .{ s.chapters.len, highlights, s.bookmarks.items.len },
    ) catch "";
    const rows = [_]card.Row{
        .{ .quiet = true, .label = progress },
        .{ .quiet = true, .label = read },
        .{ .quiet = true, .label = left },
        .{ .quiet = true, .label = counts },
    };
    _ = try app.choose_from_card(a, background, entry.title, entry.author, &rows);
}
