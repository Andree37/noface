//! Where a place in an open book's text is by Amazon's numbering, which highlights and
//! bookmarks are saved with (note_store.zig keeps them).
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const annotations = @import("../../kindle/annotations.zig");
const sess = @import("session.zig");

/// Amazon's position for a place in the text. Null for paragraphs it doesn't number,
/// and for a place past the largest position a record can hold, which only a damaged
/// book has: such a place can't be saved.
pub fn point_for(s: *sess.Session, para: u32, byte: u32) ?annotations.Point {
    assert(para < s.paragraphs.len);
    assert(byte <= s.paragraphs[para].text.len);
    return point_in(&s.paragraphs[para], byte);
}

fn point_in(p: *const book_model.Paragraph, byte: u32) ?annotations.Point {
    assert(byte <= p.text.len);
    if (p.position == 0) return null;
    const chars = book_model.char_offset(p.text, byte);
    assert(chars <= byte); // A character takes at least a byte
    // A KFX's positions are sums of its own numbers, which stop at the largest
    const short = std.math.add(u32, p.position, chars) catch return null;
    assert(short >= p.position);
    return .{ .element = p.element, .offset = chars, .short = short };
}

test "a place past the largest position can't be saved, and never overflows" {
    const max = std.math.maxInt(u32);
    var p = book_model.Paragraph{ .text = "a damaged paragraph", .position = max };
    try std.testing.expectEqual(@as(u32, max), point_in(&p, 0).?.short);
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 1));
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 19));
    p.position = max - 5;
    try std.testing.expectEqual(@as(u32, max), point_in(&p, 5).?.short);
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 6));
    p.position = 0; // Not numbered at all
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 0));
}
