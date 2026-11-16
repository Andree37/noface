//! Bookmarks: a single position marking a page.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("book.zig");
const highlights = @import("highlights.zig");

pub const Bookmark = struct { id: []const u8, para: u32, byte: u32 };

/// Bookmarks from stored notes. A bookmark starts and ends at the same place, so only
/// the start counts.
pub fn parse(
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    notes: []const highlights.Note,
) ![]Bookmark {
    var out: std.ArrayList(Bookmark) = .empty;
    for (notes) |note| {
        const id = note.id;
        const at = highlights.locate(paragraphs, note.start) orelse continue;
        assert(at.para < paragraphs.len);
        assert(at.byte <= paragraphs[at.para].text.len);
        try out.append(alloc, .{ .id = try alloc.dupe(u8, id), .para = at.para, .byte = at.byte });
    }
    const list = try out.toOwnedSlice(alloc);
    for (list) |b| assert(b.para < paragraphs.len);
    return list;
}

fn at_or_after(b: Bookmark, pos: book_model.Pos) bool {
    const after = b.para > pos.para or (b.para == pos.para and b.byte >= pos.byte);
    return after;
}

/// True when bookmark `b` falls on the page from `from` up to `to` (the next page's start).
pub fn is_on_page(b: Bookmark, from: book_model.Pos, to: ?book_model.Pos) bool {
    // Pages follow each other: the next page never starts before this one.
    if (to) |end| assert(from.para <= end.para);
    if (!at_or_after(b, from)) return false;
    const end = to orelse return true;
    const on_page = !at_or_after(b, end);
    return on_page;
}

pub fn any_on_page(list: []const Bookmark, from: book_model.Pos, to: ?book_model.Pos) bool {
    if (to) |end| assert(from.para <= end.para);
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

test "bookmark notes become positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{
        .{ .text = "abcdef", .position = 100 },
        .{ .text = "ghij", .position = 106 },
    };
    const notes = [_]highlights.Note{
        .{ .id = "kindle.bookmark-107", .start = 107, .end = 107 },
        .{ .id = "outside", .start = 1, .end = 1 },
    };
    const list = try parse(arena.allocator(), &paras, &notes);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(u32, 1), list[0].para);
    try std.testing.expectEqual(@as(u32, 1), list[0].byte);
}
