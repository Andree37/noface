//! A picture's size from its header, without decoding it: JPEG and PNG, the formats
//! noface can draw. Layout needs sizes for every picture, decoding waits for drawing.
const std = @import("std");
const assert = std.debug.assert;

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
}

/// The picture's size in pixels, or null for a picture that isn't a JPEG or PNG, or
/// whose header is broken. The data comes from a book, so nothing about it is assumed.
pub fn size(data: []const u8) ?Size {
    const found = size_of_format(data) orelse return null;
    // A picture without pixels can't be laid out: every size given is whole
    assert(found.width > 0);
    assert(found.height > 0);
    return found;
}

fn size_of_format(data: []const u8) ?Size {
    if (data.len > data_size_max) return null;
    if (data.len >= png_header_size and std.mem.eql(u8, data[0..8], png_signature)) {
        return png_size(data);
    }
    if (data.len >= 4 and data[0] == 0xff and data[1] == 0xd8) return jpeg_size(data);
    return null;
}

/// The size from PNG's first chunk, IHDR, which the format puts right after the signature.
fn png_size(data: []const u8) ?Size {
    assert(data.len >= png_header_size);
    assert(std.mem.eql(u8, data[0..png_signature.len], png_signature));
    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

/// Walks JPEG segments to the frame header (SOF0 to SOF15, except DHT, JPG and DAC).
fn jpeg_size(data: []const u8) ?Size {
    assert(data.len >= 4);
    assert(data[0] == 0xff);
    assert(data[1] == 0xd8);
    assert(data.len <= data_size_max);
    var at: u32 = 2;
    // Each segment moves `at` on by at least one byte, so this ends within data.len steps
    for (0..data.len) |_| {
        if (at + jpeg_segment_read_size >= data.len) return null;
        if (data[at] != 0xff) return null;
        const marker = data[at + 1];
        if (marker == 0xff) {
            at += 1;
            continue;
        }
        if (is_frame_marker(marker)) {
            const height = std.mem.readInt(u16, data[at + 5 ..][0..2], .big);
            const width = std.mem.readInt(u16, data[at + 7 ..][0..2], .big);
            if (width == 0 or height == 0) return null;
            return .{ .width = width, .height = height };
        }
        const segment_length = std.mem.readInt(u16, data[at + 2 ..][0..2], .big);
        if (segment_length < 2) return null;
        at += 2 + @as(u32, segment_length);
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
    // SOI, an APP0 segment of length 4, then SOF0 with height 50 and width 80.
    const jpeg = [_]u8{
        0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff,
        0xc0, 0x00, 0x11, 0x08, 0x00, 0x32, 0x00, 0x50, 0x03,
    };
    try std.testing.expectEqual(Size{ .width = 80, .height = 50 }, size(&jpeg).?);
    try std.testing.expect(size("GIF89a") == null);
}

test "frame markers are SOF0 to SOF15 but DHT, JPG and DAC" {
    try std.testing.expect(is_frame_marker(0xc0));
    try std.testing.expect(is_frame_marker(0xcf));
    try std.testing.expect(!is_frame_marker(0xc4));
    try std.testing.expect(!is_frame_marker(0xc8));
    try std.testing.expect(!is_frame_marker(0xcc));
    try std.testing.expect(!is_frame_marker(0xd8));
}
