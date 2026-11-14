//! Actions for one book, opened from the three dots beside its cover. Shown as a card.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const stats = @import("../model/stats.zig");
const catalog = @import("../model/catalog.zig");
const card = @import("card.zig");
const cover = @import("../gfx/image.zig");
const library = @import("library.zig");

pub const Option = enum { download, remove, mark_read, mark_unread, series, confirm_remove, cancel };

/// What a book offers. `confirming` swaps the list for the removal question.
/// The card's rows for a list of options.
pub fn rows(list: []const Option, out: []card.Row) []card.Row {
    for (list, out[0..list.len]) |o, *r| r.* = .{ .label = label(o), .danger = o == .remove or o == .confirm_remove };
    return out[0..list.len];
}

/// The line under the title: the author and time read, or what removal means.
pub fn subtitle(buf: []u8, e: *const catalog.Entry, confirming: bool) []const u8 {
    if (confirming) return "It stays in your Amazon library.";
    var series_buf: [160]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    const series = catalog.seriesLabel(&series_buf, e.*);
    const time = stats.readingTime(&time_buf, e.seconds_read);
    // The author, then the series and time read here when known, dot between each
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(e.author) catch return e.author;
    for ([_][]const u8{ series, if (time) |t| t else "" }, 0..) |part, i| {
        if (part.len == 0) continue;
        if (w.buffered().len > 0) w.writeAll("  \u{b7}  ") catch return e.author;
        if (i == 1) w.writeAll("read here for ") catch return e.author;
        w.writeAll(part) catch return e.author;
    }
    return w.buffered();
}

pub fn options(e: *const catalog.Entry, confirming: bool, out: *[4]Option) []Option {
    if (confirming) {
        out[0] = .confirm_remove;
        out[1] = .cancel;
        return out[0..2];
    }
    var n: usize = 0;
    switch (e.availability) {
        .cloud => {
            out[0] = .download;
            n = 1;
        },
        .downloading => {},
        .local => {
            out[0] = .remove;
            n = 1;
        },
    }
    if (e.availability != .downloading) {
        out[n] = if (e.isRead()) .mark_unread else .mark_read;
        n += 1;
    }
    // A series can be set for books on the Kindle, which have a file to key it by
    if (e.availability == .local) {
        out[n] = .series;
        n += 1;
    }
    // No Cancel: tapping above the sheet closes it. The removal question keeps one.
    return out[0..n];
}

pub fn label(o: Option) []const u8 {
    return switch (o) {
        .download => "Download",
        .remove => "Remove download",
        .mark_read => "Mark as read",
        .mark_unread => "Mark as unread",
        .series => "Series\u{2026}",
        .confirm_remove => "Remove from this Kindle",
        .cancel => "Cancel",
    };
}

fn entry(a: catalog.Availability, percent: u32) catalog.Entry {
    return .{ .path = "/a", .title = "T", .author = "", .percent = percent, .last = 0, .availability = a };
}

test "options follow where the book is" {
    var out: [4]Option = undefined;
    const local = entry(.local, 0);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_read, .series }, options(&local, false, &out));
    const cloud = entry(.cloud, 0);
    try std.testing.expectEqualSlices(Option, &.{ .download, .mark_read }, options(&cloud, false, &out));
    const read = entry(.local, 100);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_unread, .series }, options(&read, false, &out));
    const busy = entry(.downloading, 0);
    try std.testing.expectEqualSlices(Option, &.{}, options(&busy, false, &out));
}

test "removal asks first" {
    var out: [4]Option = undefined;
    const local = entry(.local, 0);
    try std.testing.expectEqualSlices(Option, &.{ .confirm_remove, .cancel }, options(&local, true, &out));
}

