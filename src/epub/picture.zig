//! A picture's size from its header, without decoding it: JPEG and PNG, the formats
//! noface can draw. Layout needs sizes for every picture, decoding waits for drawing.
//! A picture the book keeps deflated is inflated only as far as its header.
const std = @import("std");
const assert = std.debug.assert;
const book = @import("../model/book.zig");
const zip = @import("zip.zig");

pub const Size = struct { width: u32, height: u32 };

const png_signature = "\x89PNG\r\n\x1a\n";
/// The signature, then the IHDR chunk's length and type, then its width and height.
const png_header_size = 24;
/// A JPEG segment's marker and length, then the frame header's precision, height and
/// width: the bytes read past a segment's start.
const jpeg_segment_read_size = 9;
/// Larger than any picture a book carries or noface could decode, and small enough that
/// a position in it, plus a JPEG segment's length, fits in 32 bits.
const data_size_max = 1 << 31;

comptime {
    assert(png_signature.len == 8);
    assert(png_header_size == png_signature.len + 4 * 4);
    assert(jpeg_segment_read_size == 2 + 2 + 1 + 2 + 2);
    assert(data_size_max + 2 + std.math.maxInt(u16) <= std.math.maxInt(u32));
    // A segment's bytes read, and the one past them, fit the inflater's buffer
    assert(jpeg_segment_read_size + 1 <= std.compress.flate.max_window_len);
}

/// The picture's size in pixels, or null for a picture that isn't a JPEG or PNG, or
/// whose header is broken. The data comes from a book, so nothing about it is assumed.
pub fn size(data: []const u8) ?Size {
    if (data.len > data_size_max) return null;
    var reader: std.Io.Reader = .fixed(data);
    const found = size_of_format(&reader, @intCast(data.len)) orelse return null;
    // A picture without pixels can't be laid out: every size given is whole
    assert(found.width > 0);
    assert(found.height > 0);
    return found;
}

/// A picture in a book's zip, as the book keeps it: a stored one's bytes in the
/// archive, a deflated one's still deflated, its size read from its header. Null for a
/// file that isn't a picture noface can draw.
pub fn image(entry: *const zip.Entry) ?book.Image {
    if (zip.stored_bytes(entry)) |data| {
        const found = size(data) orelse return null;
        return .{ .data = data, .width = found.width, .height = found.height };
    }
    if (!zip.deflated(entry)) return null;
    if (entry.size == 0 or entry.size > data_size_max) return null;
    var input: std.Io.Reader = .fixed(entry.data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater: std.compress.flate.Decompress = .init(&input, .raw, &window);
    const found = size_of_format(&inflater.reader, entry.size) orelse return null;
    assert(found.width > 0);
    assert(found.height > 0);
    return .{
        .data = entry.data,
        .width = found.width,
        .height = found.height,
        .deflated = true,
        .inflated_size = entry.size,
    };
}

/// The size from a picture read from its start, `length` bytes in all.
fn size_of_format(reader: *std.Io.Reader, length: u32) ?Size {
    assert(length <= data_size_max);
    assert(reader.seek == 0);
    if (length >= png_header_size) {
        // Ignored: a picture shorter than a PNG's header may still be a JPEG.
        if (reader.peek(png_header_size)) |head| {
            if (std.mem.eql(u8, head[0..8], png_signature)) return png_size(head[0..24]);
        } else |_| {}
    }
    if (length < 4) return null;
    const head = reader.peek(4) catch return null;
    if (head[0] == 0xff and head[1] == 0xd8) return jpeg_size(reader, length);
    return null;
}

/// The size from PNG's first chunk, IHDR, which the format puts right after the signature.
fn png_size(head: *const [png_header_size]u8) ?Size {
    assert(std.mem.eql(u8, head[0..png_signature.len], png_signature));
    assert(head.len == png_header_size);
    const width = std.mem.readInt(u32, head[16..20], .big);
    const height = std.mem.readInt(u32, head[20..24], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

/// Walks JPEG segments to the frame header (SOF0 to SOF15, except DHT, JPG and DAC),
/// reading no more of the picture than the segments before it.
fn jpeg_size(reader: *std.Io.Reader, length: u32) ?Size {
    assert(length >= 4);
    assert(length <= data_size_max);
    reader.toss(2);
    var at: u32 = 2;
    // Each segment moves `at` on by at least one byte, so this ends within length steps
    for (0..length) |_| {
        if (at + jpeg_segment_read_size >= length) return null;
        const segment = reader.peek(jpeg_segment_read_size + 1) catch return null;
        if (segment[0] != 0xff) return null;
        const marker = segment[1];
        if (marker == 0xff) {
            reader.toss(1);
            at += 1;
            continue;
        }
        if (is_frame_marker(marker)) {
            const height = std.mem.readInt(u16, segment[5..7], .big);
            const width = std.mem.readInt(u16, segment[7..9], .big);
            if (width == 0 or height == 0) return null;
            return .{ .width = width, .height = height };
        }
        const segment_length = std.mem.readInt(u16, segment[2..4], .big);
        if (segment_length < 2) return null;
        const skipped = 2 + @as(u32, segment_length);
        at += skipped;
        reader.discardAll(skipped) catch return null;
    }
    return null;
}

/// SOF0 to SOF15 start a frame, but for DHT (0xc4), JPG (0xc8) and DAC (0xcc), which
/// share their range.
fn is_frame_marker(marker: u8) bool {
    if (marker < 0xc0 or marker > 0xcf) return false;
    return marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
}

test "sizes come from PNG and JPEG headers" {
    var png = std.mem.zeroes([24]u8);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[16..20], 300, .big);
    std.mem.writeInt(u32, png[20..24], 200, .big);
    try std.testing.expectEqual(Size{ .width = 300, .height = 200 }, size(&png).?);
    try std.testing.expectEqual(Size{ .width = 80, .height = 50 }, size(&test_jpeg).?);
    try std.testing.expect(size("GIF89a") == null);
}

/// SOI, an APP0 segment of length 4, then SOF0 with height 50 and width 80.
const test_jpeg = [_]u8{
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff,
    0xc0, 0x00, 0x11, 0x08, 0x00, 0x32, 0x00, 0x50, 0x03,
};

test "a deflated picture's size comes from inflating its header alone" {
    // Deflate's stored blocks: the picture as it is, in two pieces, after a long
    // segment the size is read past
    var picture: [70_000]u8 = @splat(0);
    @memcpy(picture[0..4], test_jpeg[0..4]);
    std.mem.writeInt(u16, picture[4..6], 60_000, .big);
    @memcpy(picture[60_004..][0 .. test_jpeg.len - 8], test_jpeg[8..]);
    const deflated = try test_stored_blocks(std.testing.allocator, &picture);
    defer std.testing.allocator.free(deflated);
    const entry = zip.Entry{ .name = "a.jpg", .method = 8, .data = deflated, .size = 70_000 };
    const found = image(&entry).?;
    try std.testing.expect(found.deflated);
    try std.testing.expectEqual(@as(u32, 70_000), found.inflated_size);
    try std.testing.expect(found.data.ptr == deflated.ptr); // Kept deflated, not copied
    try std.testing.expectEqual(@as(u32, 80), found.width);
    try std.testing.expectEqual(@as(u32, 50), found.height);
    const stored = zip.Entry{ .name = "a.jpg", .method = 0, .data = &test_jpeg, .size = 18 };
    const kept = image(&stored).?;
    try std.testing.expect(kept.data.ptr == &test_jpeg); // The archive's own bytes
    try std.testing.expect(!kept.deflated);
    const broken = zip.Entry{ .name = "a.jpg", .method = 8, .data = "\xff\xff", .size = 9 };
    try std.testing.expect(image(&broken) == null);
}

/// Raw deflate data holding `data` as it is, in stored blocks of up to 64 KB.
fn test_stored_blocks(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    assert(data.len > 0);
    assert(data.len < 1 << 24);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var at: u32 = 0;
    while (at < data.len) {
        const length: u16 = @intCast(@min(data.len - at, 65535));
        const last: u8 = if (at + length == data.len) 1 else 0;
        const l: [2]u8 = @bitCast(std.mem.nativeToLittle(u16, length));
        try out.appendSlice(alloc, &.{ last, l[0], l[1], ~l[0], ~l[1] });
        try out.appendSlice(alloc, data[at..][0..length]);
        at += length;
    }
    return out.toOwnedSlice(alloc);
}

test "frame markers are SOF0 to SOF15 but DHT, JPG and DAC" {
    try std.testing.expect(is_frame_marker(0xc0));
    try std.testing.expect(is_frame_marker(0xcf));
    try std.testing.expect(!is_frame_marker(0xc4));
    try std.testing.expect(!is_frame_marker(0xc8));
    try std.testing.expect(!is_frame_marker(0xcc));
    try std.testing.expect(!is_frame_marker(0xd8));
}
