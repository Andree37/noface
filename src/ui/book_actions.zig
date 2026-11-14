//! Actions for one book, opened from the three dots beside its cover. Shown as a card.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const stats = @import("../model/stats.zig");
const catalog = @import("../model/catalog.zig");
const card = @import("card.zig");
const cover = @import("../gfx/image.zig");
const library = @import("library.zig");

pub const Option = enum {
    download,
    remove,
    mark_read,
    mark_unread,
    series,
    confirm_remove,
    cancel,
};

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

/// The line under the title: the author and time read, or what removal means.
pub fn subtitle(buf: []u8, e: *const catalog.Entry, confirming: bool) []const u8 {
    if (confirming) return "It stays in your Amazon library.";
    var series_buf: [160]u8 = undefined;
    var time_buf: [32]u8 = undefined;
    // Room for the series and the time, so only a long author falls back to itself
    assert(buf.len >= series_buf.len + time_buf.len);
    const series = catalog.series_label(&series_buf, e.*);
    const time = stats.reading_time(&time_buf, e.seconds_read);
    // The author, then the series and time read here when known, dot between each
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(e.author) catch return e.author;
    for ([_][]const u8{ series, if (time) |t| t else "" }, 0..) |part, i| {
        if (part.len == 0) continue;
        if (w.buffered().len > 0) w.writeAll("  \u{b7}  ") catch return e.author;
        if (i == 1) w.writeAll("read here for ") catch return e.author;
        w.writeAll(part) catch return e.author;
    }
    assert(w.buffered().len >= e.author.len); // The author leads, whole
    return w.buffered();
}

/// What a book offers. `confirming` swaps the list for the removal question.
pub fn options(e: *const catalog.Entry, confirming: bool, out: *[4]Option) []Option {
    if (confirming) {
        out[0] = .confirm_remove;
        out[1] = .cancel;
        return out[0..2];
    }
    var count: u32 = 0;
    switch (e.availability) {
        .cloud => {
            out[0] = .download;
            count = 1;
        },
        .downloading => {},
        .local => {
            out[0] = .remove;
            count = 1;
        },
    }
    if (e.availability != .downloading) {
        out[count] = if (e.is_read()) .mark_unread else .mark_read;
        count += 1;
    }
    // A series can be set for books on the Kindle, which have a file to key it by
    if (e.availability == .local) {
        out[count] = .series;
        count += 1;
    }
    // A book being downloaded offers nothing until it's here
    if (e.availability == .downloading) assert(count == 0);
    assert(count < out.len);
    if (e.availability == .local) assert(out[0] == .remove);
    assert(std.mem.indexOfScalar(Option, out[0..count], .cancel) == null);
    // No Cancel: tapping above the sheet closes it. The removal question keeps one.
    return out[0..count];
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

fn entry(availability: catalog.Availability, percent: u32) catalog.Entry {
    assert(percent <= 100);
    return .{
        .path = "/a",
        .title = "T",
        .author = "",
        .percent = percent,
        .last = 0,
        .availability = availability,
    };
}

test "options follow where the book is" {
    var out: [4]Option = undefined;
    const local = entry(.local, 0);
    const local_options = options(&local, false, &out);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_read, .series }, local_options);
    const cloud = entry(.cloud, 0);
    const cloud_options = options(&cloud, false, &out);
    try std.testing.expectEqualSlices(Option, &.{ .download, .mark_read }, cloud_options);
    const read = entry(.local, 100);
    const read_options = options(&read, false, &out);
    try std.testing.expectEqualSlices(Option, &.{ .remove, .mark_unread, .series }, read_options);
    const busy = entry(.downloading, 0);
    try std.testing.expectEqualSlices(Option, &.{}, options(&busy, false, &out));
}

test "removal asks first" {
    var out: [4]Option = undefined;
    const local = entry(.local, 0);
    const asked = options(&local, true, &out);
    try std.testing.expectEqualSlices(Option, &.{ .confirm_remove, .cancel }, asked);
}
