//! The toolbar's bookmark button: marks the page, or unmarks it.
const std = @import("std");
const assert = std.debug.assert;
const annotations = @import("../../kindle/annotations.zig");
const bookmarks = @import("../../model/bookmarks.zig");
const catalog = @import("../../model/catalog.zig");
const annotation_db = @import("../../kindle/annotation_db.zig");
const lipc = @import("../../kindle/lipc.zig");
const app = @import("../../app.zig");
const records = @import("records.zig");
const sess = @import("session.zig");

/// Adds a bookmark at the top of the page, or removes every one on it. Both sync.
pub fn toggle(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
) !void {
    assert(s.current < s.pages.len);
    defer a.forget_pages(); // The ribbon is drawn into the page
    const from = s.pages[s.current];
    const to = s.page_end(s.current);
    if (s.is_bookmarked(s.current)) {
        var index: u32 = 0;
        while (index < s.bookmarks.items.len) {
            const b = s.bookmarks.items[index];
            if (!bookmarks.is_on_page(b, from, to)) {
                index += 1;
                continue;
            }
            if (!records.delete(s, entry, .bookmark, b.id)) {
                return app.show_notice(a, "This bookmark couldn't be removed.");
            }
            _ = s.bookmarks.orderedRemove(index);
        }
        assert(!s.is_bookmarked(s.current));
        std.debug.print("bookmark removed\n", .{});
    } else {
        const page_index: u32 = @intCast(s.current);
        const at = first_position(s, page_index) orelse {
            return app.show_notice(a, "This page can't be bookmarked.");
        };
        // A place Amazon numbers always has a point: first_position looked for one
        const point = records.point_for(s, at.para, at.byte).?;
        const prefix = annotations.Kind.bookmark.prefix();
        const id = try std.fmt.allocPrint(alloc, "{s}{d}", .{ prefix, point.short });
        if (!records.write(s, entry, .bookmark, id, point, point)) {
            return app.show_notice(a, "This bookmark couldn't be saved.");
        }
        try s.bookmarks.append(alloc, .{ .id = id, .para = at.para, .byte = at.byte });
        assert(s.is_bookmarked(s.current));
        std.debug.print("bookmark added\n", .{});
    }
    records.sync();
}

/// The first place on a page that Amazon numbers. Pages can open on a heading
/// or image it doesn't, so look further down the page, but never onto the next one.
fn first_position(s: *const sess.Session, page_index: u32) ?struct { para: u32, byte: u32 } {
    assert(page_index < s.pages.len);
    const from = s.pages[page_index];
    const to = s.page_end(page_index);
    var para = from.para;
    while (para < s.paragraphs.len) : (para += 1) {
        const byte = if (para == from.para) from.byte else 0;
        // Stop where the next page begins: at its paragraph, unless this page holds its start.
        if (to) |end| {
            if (para > end.para) return null;
            if (para == end.para and byte >= end.byte) return null;
        }
        if (s.paragraphs[para].position == 0) continue;
        assert(para >= from.para);
        assert(byte <= s.paragraphs[para].text.len);
        return .{ .para = @intCast(para), .byte = @intCast(byte) };
    }
    return null;
}
