//! Bookmarks: a single position marking a page.
const std = @import("std");
const book_model = @import("book.zig");
const highlights = @import("highlights.zig");

pub const Bookmark = struct { id: []const u8, para: u32, byte: u32 };

/// Reads "id|start|end" lines from the annotation database. Bookmarks start and
/// end at the same place, so only the start counts.
pub fn parse(alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, lines: []const u8) ![]Bookmark {
    var out: std.ArrayList(Bookmark) = .empty;
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        const id = fields.next() orelse continue;
        const start = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const at = highlights.locate(paragraphs, start) orelse continue;
        try out.append(alloc, .{ .id = try alloc.dupe(u8, id), .para = at.para, .byte = at.byte });
    }
    return out.toOwnedSlice(alloc);
}

fn at_or_after(b: Bookmark, pos: book_model.Pos) bool {
    return b.para > pos.para or (b.para == pos.para and b.byte >= pos.byte);
}

/// True when bookmark `b` falls on the page from `from` up to `to` (the next page's start).
pub fn is_on_page(b: Bookmark, from: book_model.Pos, to: ?book_model.Pos) bool {
    if (!at_or_after(b, from)) return false;
    const end = to orelse return true;
    return !at_or_after(b, end);
}

pub fn any_on_page(list: []const Bookmark, from: book_model.Pos, to: ?book_model.Pos) bool {
    for (list) |b| {
        if (is_on_page(b, from, to)) return true;
    }
    return false;
}

test "a bookmark belongs to the page it falls on" {
    const b = Bookmark{ .id = "x", .para = 4, .byte = 20 };
    try std.testing.expect(is_on_page(b, .{ .para = 4, .byte = 0 }, .{ .para = 5, .byte = 0 }));
    try std.testing.expect(is_on_page(b, .{ .para = 4, .byte = 20 }, .{ .para = 4, .byte = 21 }));
    try std.testing.expect(!is_on_page(b, .{ .para = 4, .byte = 21 }, null));
    try std.testing.expect(!is_on_page(b, .{ .para = 3, .byte = 0 }, .{ .para = 4, .byte = 20 }));
    try std.testing.expect(is_on_page(b, .{ .para = 2, .byte = 0 }, null)); // Last page
}

test "bookmark lines become positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{ .{ .text = "abcdef", .style = 0, .position = 100 }, .{ .text = "ghij", .style = 0, .position = 106 } };
    const list = try parse(arena.allocator(), &paras, "kindle.bookmark-107|107|107\nbad\n");
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(u32, 1), list[0].para);
    try std.testing.expectEqual(@as(u32, 1), list[0].byte);
}
