//! A book as noface holds it, whatever format it came from: paragraphs with their look,
//! links, pictures and contents. Parsers fill it; layout and screens read it.
const std = @import("std");

/// A byte range of a paragraph that links to another paragraph.
/// `inside`: the target is an anchor partway into its paragraph (a page marker, say),
/// not the paragraph's start, so it can't be where a note begins.
pub const Link = struct { start: usize, end: usize, target: u32, inside: bool = false };

/// How text is set: weight, slant, size, alignment and spacing around it.
pub const Look = struct {
    bold: bool = false,
    italic: bool = false,
    size: u8 = normal_size, // Index into `size_scales`
    alignment: Alignment = .auto,
    space_before: u8 = 0, // Tenths of a line
    space_after: u8 = 0,

    pub const Alignment = enum { auto, left, center, right, justify };
};

/// Text sizes, relative to the reader's chosen size. Book sizes snap to these.
pub const size_scales = [_]f32{ 0.8, 1.0, 1.2, 1.45, 1.75 };

pub const normal_size = 1;

/// Snaps a book's size (1.0 is body text) to the nearest step in `size_scales`.
pub fn size_class(rem: f64) u8 {
    if (rem < 0.9) return 0;
    if (rem < 1.1) return 1;
    if (rem < 1.33) return 2;
    if (rem < 1.62) return 3;
    return 4;
}

/// Bold or italic over part of a paragraph.
pub const Run = struct { start: u32, end: u32, bold: bool, italic: bool };

/// A picture in the text: its encoded bytes (JPEG or PNG) and size in pixels.
pub const Image = struct { data: []const u8, width: u32, height: u32 };

pub const Paragraph = struct {
    image: ?Image = null, // A picture standing alone, in place of text
    text: []const u8,
    style: u32,
    look: Look = .{},
    runs: []const Run = &.{},
    links: []const Link = &.{},
    section: u32 = 0,
    element: u32 = 0, // Position IDs Amazon uses for this text
    position: u32 = 0,
    note: bool = false, // Part of a note, so hidden from the flow
    note_start: bool = false, // First paragraph of a note: what references point at
};

/// A paragraph's number counting text only. Saved reading positions use this, so
/// they stay put whether or not pictures are shown.
pub fn text_index(paragraphs: []const Paragraph, para: usize) usize {
    var n: usize = 0;
    for (paragraphs[0..@min(para, paragraphs.len)]) |p| {
        if (p.image == null) n += 1;
    }
    return n;
}

/// The paragraph for a number from `text_index`.
pub fn from_text_index(paragraphs: []const Paragraph, index: usize) usize {
    var n: usize = 0;
    for (paragraphs, 0..) |p, i| {
        if (p.image != null) continue;
        if (n == index) return i;
        n += 1;
    }
    return paragraphs.len;
}

/// Characters before a byte offset, which is how Amazon counts positions.
pub fn char_offset(text: []const u8, byte: usize) u32 {
    var bytes: usize = 0;
    var chars: u32 = 0;
    while (bytes < byte and bytes < text.len) : (chars += 1) {
        bytes += std.unicode.utf8ByteSequenceLength(text[bytes]) catch 1;
    }
    return chars;
}

/// Byte offset of the `count`th code point, as KFX offsets count characters.
pub fn byte_offset(text: []const u8, count: u64) usize {
    var bytes: usize = 0;
    var seen: u64 = 0;
    while (bytes < text.len and seen < count) : (seen += 1) {
        bytes += std.unicode.utf8ByteSequenceLength(text[bytes]) catch 1;
    }
    return @min(bytes, text.len);
}

/// A table of contents entry: its title, where it starts, and how deep it nests.
pub const Chapter = struct { title: []const u8, para: u32, depth: u8 };

pub const Book = struct {
    paragraphs: []Paragraph,
    chapters: []Chapter = &.{},
    sections: u32,
    missing_refs: u32,
};

/// Some books style every paragraph bold, so the reader's Bold switch could never
/// make them regular. When most text paragraphs are bold, bold is that book's normal
/// weight: show it regular. Bold words inside paragraphs stay bold.
pub fn plain_body(paragraphs: []Paragraph) void {
    var text: usize = 0;
    var bold: usize = 0;
    for (paragraphs) |p| {
        if (p.image != null) continue;
        text += 1;
        if (p.look.bold) bold += 1;
    }
    if (bold * 2 <= text) return;
    for (paragraphs) |*p| p.look.bold = false;
}

test "a book that is bold throughout reads as regular" {
    var ps = [_]Paragraph{
        .{ .text = "a", .style = 0, .look = .{ .bold = true } },
        .{ .text = "b", .style = 0, .look = .{ .bold = true } },
        .{ .text = "c", .style = 0 },
    };
    plain_body(&ps);
    for (ps) |p| try std.testing.expect(!p.look.bold);
}

test "a few bold headings stay bold" {
    const runs = [_]Run{.{ .start = 0, .end = 1, .bold = true, .italic = false }};
    var ps = [_]Paragraph{
        .{ .text = "Chapter", .style = 0, .look = .{ .bold = true } },
        .{ .text = "b", .style = 0, .runs = &runs },
        .{ .text = "c", .style = 0 },
    };
    plain_body(&ps);
    try std.testing.expect(ps[0].look.bold);
    try std.testing.expect(ps[1].runs[0].bold);
}

test "offsets count characters, not bytes" {
    try std.testing.expectEqual(@as(usize, 3), byte_offset("\u{e1}bc", 2));
    try std.testing.expectEqual(@as(usize, 4), byte_offset("\u{e1}bc", 99));
}

test "byte and character offsets agree" {
    try std.testing.expectEqual(@as(u32, 2), char_offset("\u{e1}bc", 3));
    try std.testing.expectEqual(@as(u32, 0), char_offset("abc", 0));
}

test "book sizes snap to the reader's steps" {
    try std.testing.expectEqual(@as(u8, 0), size_class(0.8));
    try std.testing.expectEqual(@as(u8, 1), size_class(1.0));
    try std.testing.expectEqual(@as(u8, 2), size_class(1.125));
    try std.testing.expectEqual(@as(u8, 3), size_class(1.5));
    try std.testing.expectEqual(@as(u8, 4), size_class(2.0));
}

test "saved positions count text paragraphs only" {
    const img = Image{ .data = "", .width = 1, .height = 1 };
    const paras = [_]Paragraph{ .{ .text = "a", .style = 0 }, .{ .text = "", .style = 0, .image = img }, .{ .text = "b", .style = 0 } };
    try std.testing.expectEqual(@as(usize, 1), text_index(&paras, 2));
    try std.testing.expectEqual(@as(usize, 2), from_text_index(&paras, 1));
    try std.testing.expectEqual(@as(usize, 0), from_text_index(&paras, 0));
}

/// A place in a book: a paragraph, and a byte within its text.
pub const Pos = struct { para: usize = 0, byte: usize = 0 };

/// A word as laid out on a page: where it is on screen and where it came from.
pub const Word = struct { x: i32, y: i32, w: i32, h: i32, para: u32, start: u32, end: u32 };

/// Part of a paragraph with a highlight on it.
pub const Mark = struct { para: u32, start: u32, end: u32 };
