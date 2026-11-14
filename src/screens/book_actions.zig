//! What can be done to a book from the library: its sheet of actions (download,
//! remove, mark read), and the card offering the next of a series.
const std = @import("std");
const assert = std.debug.assert;
const card = @import("../ui/card.zig");
const catalog = @import("../model/catalog.zig");
const library = @import("../ui/library.zig");
const book_actions = @import("../ui/book_actions.zig");
const state = @import("../sys/state.zig");
const store = @import("../kindle/store.zig");
const app = @import("../app.zig");
const series_screen = @import("series.zig");
const cover_image = @import("../gfx/image.zig");
const screen = @import("screen.zig");
const reader = @import("reader.zig");

/// The rounds a book's sheet can take: its actions, then, for a removal, the question
/// whether to remove it.
const sheet_rounds_max = 2;

comptime {
    // The card's small cover is half the grid's, so it's never empty
    assert(cover_image.width / 2 > 0);
    assert(cover_image.height / 2 > 0);
}

/// Saves the book as unread, so the reload that follows doesn't bring back 100%.
/// Dated just after the last time it was opened anywhere: newer than stock's
/// percent, so it wins, without moving the book up in recent order.
pub fn forget_finished(a: *app.App, e: *const catalog.Entry) !void {
    assert(e.is_local());
    var path_buffer: [320]u8 = undefined;
    const path = try a.state_path(&path_buffer, e.path);
    var saved = state.load(path);
    saved.percent = 0;
    saved.opened = @max(saved.opened, e.kindle_last) + 1;
    // Newer than stock's record, so the 0% wins over its 100%
    assert(saved.opened > e.kindle_last);
    state.save(path, saved);
}

/// Marks a book read or unread, from its sheet here or the reader's menu. The Kindle
/// keeps this for its own books; an EPUB's is kept with its place. Marked unread, it
/// also starts again from the beginning.
pub fn mark_read(a: *app.App, e: *catalog.Entry, done: bool) void {
    store.mark_read(e.key, e.kind, done);
    e.finished = done;
    assert(e.finished == done);
    if (done) assert(e.is_read());
    if (e.is_epub()) {
        var path_buffer: [320]u8 = undefined;
        if (a.state_path(&path_buffer, e.path)) |p| {
            var saved = state.load(p);
            saved.finished = done;
            state.save(p, saved);
        } else |_| {}
    }
    if (done) {
        a.journal.finish(a.today());
        app.save_journal(a);
    }
    if (!done and e.is_local()) {
        forget_finished(a, e) catch |err| {
            std.debug.print("unread not saved with its place: {s}\n", .{@errorName(err)});
        };
    }
    std.debug.print("marked {s}\n", .{if (done) "read" else "unread"});
}

/// What a book's actions changed, which decides what the library does next.
/// What a book's sheet changed: `reload` re-reads the library (a series set by hand),
/// `redraw` only repaints it (a screen of its own was shown and nothing changed).
pub const Change = enum { none, downloading, other, reload, redraw };

/// Shows a book's actions.
pub fn book_sheet(
    a: *app.App,
    e: *catalog.Entry,
    entries: []const catalog.Entry,
    background: []const u8,
) !Change {
    std.debug.print("sheet: {s}\n", .{e.title});
    for (0..sheet_rounds_max) |round| {
        const confirming = round == 1;
        var list_buffer: [4]book_actions.Option = undefined;
        var row_buffer: [4]card.Row = undefined;
        var subtitle_buffer: [320]u8 = undefined;
        const list = book_actions.options(e, confirming, &list_buffer);
        assert(list.len > 0);
        const subtitle = book_actions.subtitle(&subtitle_buffer, e, confirming);
        const rows = book_actions.rows(list, &row_buffer);
        const picked = try app.choose_from_card(a, background, e.title, subtitle, rows) orelse
            return .none;
        assert(picked < list.len);
        switch (list[picked]) {
            .cancel => return .none,
            .remove => {
                assert(!confirming);
                continue;
            },
            .series => return if (try series_screen.choose(a, entries, e)) .reload else .redraw,
            .confirm_remove => {
                assert(confirming);
                store.remove_download(e.key, e.kind);
                std.debug.print("removed download: {s}\n", .{e.title});
                return .other;
            },
            .download => {
                store.download_book(e.key, e.kind);
                std.debug.print("download requested: {s}\n", .{e.title});
                return .downloading;
            },
            .mark_read, .mark_unread => |choice| {
                mark_read(a, e, choice == .mark_read);
                return .other;
            },
        }
    }
    // Only removing goes round again, and the question it asks has no removing in it
    unreachable;
}

pub fn up_next(a: *app.App, next: *const catalog.Entry, background: []u8) !bool {
    if (next.availability != .local) return false;
    assert(next.is_local());
    var label_buffer: [160]u8 = undefined;
    var subtitle_buffer: [200]u8 = undefined;
    const label = catalog.series_label(&label_buffer, next.*);
    const subtitle = std.fmt.bufPrint(&subtitle_buffer, "Up next in {s}", .{label}) catch
        "Up next";
    std.debug.print("up next: {s}\n", .{next.title});
    // Over the page just left, not whatever the reader last kept in this buffer
    assert(background.len == a.screen.pixels.len);
    @memcpy(background, a.screen.pixels);
    // Its cover beside the title, half the grid's size, when it has one
    const cover_width = cover_image.width / 2;
    const cover_height = cover_image.height / 2;
    var small: ?[]u8 = null;
    if (next.thumbnail.len > 0) {
        small = cover_image.load(a.alloc, next.thumbnail, cover_width, cover_height);
    }
    defer if (small) |pixels| a.alloc.free(pixels);
    var book_cover: ?card.Cover = null;
    if (small) |pixels| {
        assert(pixels.len == cover_width * cover_height);
        book_cover = .{ .pixels = pixels, .width = cover_width, .height = cover_height };
    }
    const rows = [_]card.Row{.{ .label = "Read it now" }};
    const chosen = try app.choose_from_card_with(
        a,
        background,
        next.title,
        subtitle,
        &rows,
        book_cover,
    );
    return chosen != null;
}
