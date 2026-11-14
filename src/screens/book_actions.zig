//! What can be done to a book from the library: its sheet of actions (download,
//! remove, mark read), and the card offering the next of a series.
const std = @import("std");
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

/// Saves the book as unread, so the reload that follows doesn't bring back 100%.
/// Dated just after the last time it was opened anywhere: newer than stock's
/// percent, so it wins, without moving the book up in recent order.
pub fn forget_finished(a: *app.App, e: *const catalog.Entry) !void {
    var path_buf: [320]u8 = undefined;
    const path = try a.state_path(&path_buf, e.path);
    var saved = state.load(path);
    saved.percent = 0;
    saved.opened = @max(saved.opened, e.kindle_last) + 1;
    state.save(path, saved);
}

/// Marks a book read or unread, from its sheet here or the reader's menu. The Kindle
/// keeps this for its own books; an EPUB's is kept with its place. Marked unread, it
/// also starts again from the beginning.
pub fn mark_read(a: *app.App, e: *catalog.Entry, done: bool) void {
    store.mark_read(e.key, e.kind, done);
    e.finished = done;
    if (e.is_epub()) {
        var path_buf: [320]u8 = undefined;
        if (a.state_path(&path_buf, e.path)) |p| {
            var saved = state.load(p);
            saved.finished = done;
            state.save(p, saved);
        } else |_| {}
    }
    if (done) {
        a.journal.finish(a.today());
        app.save_journal(a);
    }
    if (!done and e.is_local()) forget_finished(a, e) catch {};
    std.debug.print("marked {s}\n", .{if (done) "read" else "unread"});
}

/// What a book's actions changed, which decides what the library does next.
/// What a book's sheet changed: `reload` re-reads the library (a series set by hand),
/// `redraw` only repaints it (a screen of its own was shown and nothing changed).
pub const Change = enum { none, downloading, other, reload, redraw };

/// Shows a book's actions.
pub fn book_sheet(a: *app.App, e: *catalog.Entry, entries: []const catalog.Entry, background: []const u8) !Change {
    std.debug.print("sheet: {s}\n", .{e.title});
    var confirming = false;
    while (true) {
        var list_buf: [4]book_actions.Option = undefined;
        var row_buf: [4]card.Row = undefined;
        var subtitle_buf: [320]u8 = undefined;
        const list = book_actions.options(e, confirming, &list_buf);
        const subtitle = book_actions.subtitle(&subtitle_buf, e, confirming);
        const picked = try app.choose_from_card(a, background, e.title, subtitle, book_actions.rows(list, &row_buf)) orelse return .none;
        switch (list[picked]) {
            .cancel => return .none,
            .remove => confirming = true,
            .series => return if (try series_screen.choose(a, entries, e)) .reload else .redraw,
            .confirm_remove => {
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
}

pub fn up_next(a: *app.App, next: *const catalog.Entry, background: []u8) !bool {
    if (next.availability != .local) return false;
    var label_buf: [160]u8 = undefined;
    var subtitle_buf: [200]u8 = undefined;
    const subtitle = std.fmt.bufPrint(&subtitle_buf, "Up next in {s}", .{catalog.series_label(&label_buf, next.*)}) catch "Up next";
    std.debug.print("up next: {s}\n", .{next.title});
    // Over the page just left, not whatever the reader last kept in this buffer
    @memcpy(background, a.screen.pixels);
    // Its cover beside the title, half the grid's size, when it has one
    const w = cover_image.width / 2;
    const h = cover_image.height / 2;
    const small = if (next.thumbnail.len > 0) cover_image.load(a.alloc, next.thumbnail, w, h) else null;
    defer if (small) |px| a.alloc.free(px);
    const book_cover: ?card.Cover = if (small) |px| .{ .pixels = px, .width = w, .height = h } else null;
    return try app.choose_from_card_with(a, background, next.title, subtitle, &.{.{ .label = "Read it now" }}, book_cover) != null;
}
