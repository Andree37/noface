//! The toolbar's bookmark button: marks the page, or unmarks it.
const std = @import("std");
const annotations = @import("../../kindle/annotations.zig");
const bookmarks = @import("../../model/bookmarks.zig");
const catalog = @import("../../model/catalog.zig");
const annotation_db = @import("../../kindle/annotation_db.zig");
const lipc = @import("../../kindle/lipc.zig");
const app = @import("../../app.zig");
const records = @import("records.zig");
const sess = @import("session.zig");

/// Adds a bookmark at the top of the page, or removes every one on it. Both sync.
pub fn toggle(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry) !void {
    defer a.forget_pages(); // The ribbon is drawn into the page
    const from = s.pages[s.current];
    const to = s.page_end(s.current);
    if (s.is_bookmarked(s.current)) {
        var i: usize = 0;
        while (i < s.bookmarks.items.len) {
            const b = s.bookmarks.items[i];
            if (!bookmarks.is_on_page(b, from, to)) {
                i += 1;
                continue;
            }
            if (!records.delete(s, entry, .bookmark, b.id)) return app.show_notice(a, "This bookmark couldn't be removed.");
            _ = s.bookmarks.orderedRemove(i);
        }
        std.debug.print("bookmark removed\n", .{});
    } else {
        const at = first_position(s, s.current) orelse return app.show_notice(a, "This page can't be bookmarked.");
        const point = records.point_for(s, at.para, at.byte).?;
        const id = try std.fmt.allocPrint(alloc, "{s}{d}", .{ annotations.Kind.bookmark.prefix(), point.short });
        if (!records.write(s, entry, .bookmark, id, point, point)) return app.show_notice(a, "This bookmark couldn't be saved.");
        try s.bookmarks.append(alloc, .{ .id = id, .para = at.para, .byte = at.byte });
        std.debug.print("bookmark added\n", .{});
    }
    records.sync();
}

/// The first place on a page that Amazon numbers. Pages can open on a heading
/// or image it doesn't, so look further down the page, but never onto the next one.
fn first_position(s: *const sess.Session, index: usize) ?struct { para: u32, byte: u32 } {
    const from = s.pages[index];
    const to = s.page_end(index);
    var para = from.para;
    while (para < s.paragraphs.len) : (para += 1) {
        const byte: usize = if (para == from.para) from.byte else 0;
        // Stop where the next page begins: at its paragraph, unless this page holds its start.
        if (to) |e| {
            if (para > e.para or (para == e.para and byte >= e.byte)) return null;
        }
        if (s.paragraphs[para].position == 0) continue;
        return .{ .para = @intCast(para), .byte = @intCast(byte) };
    }
    return null;
}
