//! An open book's words, counted once as it opens: how many come before each paragraph,
//! so the words before any place, on a page and left in a chapter are found at once,
//! for the time left, running's minutes left and the reading speed (session.zig).
//! Notes' words aren't counted: they're out of the flow, read only when tapped.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const stats = @import("../../model/stats.zig");

pub const Words = struct {
    /// The words before each paragraph, and last the whole book's: one more than the
    /// paragraphs.
    before: []const u64 = &.{},

    /// The words of `paragraphs`, counted in `alloc`, the open book's memory.
    pub fn count(alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph) !Words {
        assert(paragraphs.len > 0); // Parsing refuses a book without any
        const before = try alloc.alloc(u64, paragraphs.len + 1);
        before[0] = 0;
        for (paragraphs, 0..) |p, i| {
            before[i + 1] = before[i] + (if (p.note) 0 else stats.count_words(p.text));
        }
        assert(before[paragraphs.len] >= before[0]);
        return .{ .before = before };
    }

    /// Every word of the book.
    pub fn total(w: Words) u64 {
        assert(w.before.len > 0); // Counted
        return w.before[w.before.len - 1];
    }

    /// The words before place `p` of `paragraphs`, the book counted.
    pub fn at(w: Words, paragraphs: []const book_model.Paragraph, p: book_model.Pos) u64 {
        assert(w.before.len == paragraphs.len + 1);
        assert(p.para < paragraphs.len);
        const para = paragraphs[p.para];
        if (para.note) return w.before[p.para];
        const before = para.text[0..@min(p.byte, para.text.len)];
        return w.before[p.para] + stats.count_words(before);
    }

    /// The words from `here` (words before a place, `at`) to the end of its chapter:
    /// the next chapter's start, or the book's end past the last. A book without
    /// chapters is one.
    pub fn chapter_left(w: Words, chapters: []const book_model.Chapter, here: u64) u64 {
        assert(here <= w.total());
        var end = w.total();
        for (chapters) |c| {
            assert(c.para < w.before.len);
            const start = w.before[c.para];
            if (start > here and start < end) end = start;
        }
        assert(here <= end);
        return end - here;
    }
};

test "words are counted before each place, notes left out, and to each chapter's end" {
    const paragraphs = [_]book_model.Paragraph{
        .{ .text = "one two three" },
        .{ .text = "a note's words", .note = true },
        .{ .text = "four five" },
        .{ .text = "six seven eight nine" },
    };
    var memory: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const w = try Words.count(fixed.allocator(), &paragraphs);
    try std.testing.expectEqual(@as(u64, 9), w.total());
    try std.testing.expectEqual(@as(u64, 0), w.at(&paragraphs, .{}));
    try std.testing.expectEqual(@as(u64, 1), w.at(&paragraphs, .{ .byte = 4 })); // "one "
    try std.testing.expectEqual(@as(u64, 3), w.at(&paragraphs, .{ .para = 1, .byte = 5 }));
    try std.testing.expectEqual(@as(u64, 5), w.at(&paragraphs, .{ .para = 3 }));
    // Chapters at the first and the last paragraph
    const chapters = [_]book_model.Chapter{
        .{ .title = "One", .para = 0, .depth = 0 },
        .{ .title = "Two", .para = 3, .depth = 0 },
    };
    try std.testing.expectEqual(@as(u64, 4), w.chapter_left(&chapters, 1));
    try std.testing.expectEqual(@as(u64, 3), w.chapter_left(&chapters, 6));
    try std.testing.expectEqual(@as(u64, 8), w.chapter_left(&.{}, 1)); // One chapter
}
