//! Actions for one book, opened by holding it in the library, or from the dots beside
//! the book to continue. Shown as a card.
const std = @import("std");
const assert = std.debug.assert;
const stats = @import("../model/stats.zig");
const catalog = @import("../model/catalog.zig");
const card = @import("card.zig");

pub const Option = enum {
    download,
    remove,
    hide,
    mark_read,
    mark_unread,
    series,
    confirm_remove,
    confirm_hide,
    cancel,
};

/// What the card asks before doing it, in place of the book's actions.
pub const Question = enum {
    remove,
    hide,

    /// The question's answer, then Cancel.
    fn answer(q: Question) Option {
        return switch (q) {
            .remove => .confirm_remove,
            .hide => .confirm_hide,
        };
    }
};

/// What hiding a book says it does, and what it doesn't: deleting it from the store's
/// library is the device's own screens'.
pub const hide_note = "To delete it from your Amazon library, use the Kindle's own screens.";

comptime {
    // Every option says what it does
    for (std.enums.values(Option)) |o| assert(label(o).len > 0);
}

/// The card's rows for a list of options.
pub fn rows(list: []const Option, out: []card.Row) []card.Row {
    assert(out.len >= list.len);
    for (list, out[0..list.len]) |o, *r| {
        r.* = .{ .label = label(o), .danger = o == .remove or o == .confirm_remove };
    }
    const result = out[0..list.len];
    assert(result.len == list.len);
    return result;
}

/// What a book being downloaded says in place of its actions, which it has none of.
pub const downloading_note = "Downloading. It opens once it's here.";

/// The line under the title: the author and time read, what the question's answer
/// means, or that the book is still on its way.
pub fn subtitle(buf: []u8, e: *const catalog.Entry, asking: ?Question) []const u8 {
    if (asking) |q| return switch (q) {
        .remove => "It stays in your Amazon library.",
        .hide => hide_note,
    };
    if (e.availability == .downloading) return downloading_note;
    var series_buf: [160]u8 = undefined;
    var time_buf: stats.Minutes = undefined;
    // Room for the series and the time, so only a long author falls back to itself
    assert(buf.len >= series_buf.len + time_buf.len);
    const series = catalog.series_label(&series_buf, e.*);
    const time = stats.reading_time(&time_buf, e.seconds_read);
    // The author, then the series and time read here when known, dot between each
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(e.author) catch return e.author;
    for ([_]?[]const u8{ series, time }, 0..) |known, i| {
        const part = known orelse continue;
        if (w.buffered().len > 0) w.writeAll("  \u{b7}  ") catch return e.author;
        if (i == 1) w.writeAll("read here for ") catch return e.author;
        w.writeAll(part) catch return e.author;
    }
    assert(w.buffered().len >= e.author.len); // The author leads, whole
    return w.buffered();
}

/// What a book offers. `asking` swaps the list for that question.
// Assertions: a table by where the book is, which the switch keeps complete.
pub fn options(e: *const catalog.Entry, asking: ?Question, out: *[4]Option) []Option {
    if (asking) |q| {
        out[0] = q.answer();
        out[1] = .cancel;
        return out[0..2];
    }
    const mark: Option = if (e.is_read()) .mark_unread else .mark_read;
    // No Cancel: tapping above the sheet closes it. The removal question keeps one.
    switch (e.availability) {
        // Hidden, as only the device's own screens delete it from the store's library;
        // by its key, so not one the catalog names none for
        .cloud => {
            out[0..2].* = .{ .download, mark };
            if (e.key.len == 0) return out[0..2];
            out[2] = .hide;
            return out[0..3];
        },
        // Nothing until it's here
        .downloading => return out[0..0],
        // A series can be set for books on the Kindle, which have a file to key it by
        .local => {
            out[0..3].* = .{ .remove, mark, .series };
            return out[0..3];
        },
    }
}

// Assertions: a table, which the switch keeps complete.
pub fn label(o: Option) []const u8 {
    return switch (o) {
        .download => "Download",
        .remove => "Remove download",
        .hide => "Hide from this library",
        .mark_read => "Mark as read",
        .mark_unread => "Mark as unread",
        .series => "Series\u{2026}",
        .confirm_remove => "Remove from this Kindle",
        .confirm_hide => "Hide it",
        .cancel => "Cancel",
    };
}

// Assertions: a book for the tests, made as they ask.
fn entry(availability: catalog.Availability, percent: u32) catalog.Entry {
    assert(percent <= 100);
    return .{
        .path = "/a",
        .title = "T",
        .author = "",
        .percent = percent,
        .last = 0,
        .availability = availability,
        .key = "B0TEST", // As the catalog names every book it has
        .kind = "PDOC",
    };
}

test "options follow where the book is" {
    var out: [4]Option = undefined;
    const local = entry(.local, 0);
    const local_options = options(&local, null, &out);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_read, .series }, local_options);
    const cloud = entry(.cloud, 0);
    const cloud_options = options(&cloud, null, &out);
    try std.testing.expectEqualSlices(Option, &.{ .download, .mark_read, .hide }, cloud_options);
    const read = entry(.local, 100);
    const read_options = options(&read, null, &out);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_unread, .series }, read_options);
    const busy = entry(.downloading, 0);
    try std.testing.expectEqualSlices(Option, &.{}, options(&busy, null, &out));
}

test "a book being downloaded shows a card that says so, with nothing to pick" {
    var out: [4]Option = undefined;
    var subtitle_buffer: [320]u8 = undefined;
    const busy = entry(.downloading, 0);
    const busy_options = options(&busy, null, &out);
    try std.testing.expectEqual(@as(usize, 0), busy_options.len);
    const busy_subtitle = subtitle(&subtitle_buffer, &busy, null);
    try std.testing.expectEqualStrings(downloading_note, busy_subtitle);
    // The card the sheet shows for it: no rows, so only a tap above it closes it
    var row_buffer: [4]card.Row = undefined;
    try std.testing.expectEqual(@as(usize, 0), rows(busy_options, &row_buffer).len);
    const above: i32 = @as(i32, @intCast(card.top(0))) - 1;
    try std.testing.expectEqual(@as(?u32, null), card.hit(above, 0));
    try std.testing.expectEqual(@as(?u32, 0), card.hit(above + 1, 0)); // On it: no row
}

test "removal asks first" {
    var out: [4]Option = undefined;
    const local = entry(.local, 0);
    const asked = options(&local, .remove, &out);
    try std.testing.expectEqualSlices(Option, &.{ .confirm_remove, .cancel }, asked);
}

test "hiding asks first, and says deleting is the device's own screens'" {
    var out: [4]Option = undefined;
    const cloud = entry(.cloud, 0);
    const asked = options(&cloud, .hide, &out);
    try std.testing.expectEqualSlices(Option, &.{ .confirm_hide, .cancel }, asked);
    var subtitle_buffer: [320]u8 = undefined;
    try std.testing.expectEqualStrings(hide_note, subtitle(&subtitle_buffer, &cloud, .hide));
}
