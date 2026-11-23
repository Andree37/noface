//! PGM, the plain gray picture format noface's tools and the Kindle's JPEG XR helper
//! speak: "P5", the width and height, the largest value (255: a byte a pixel), each
//! followed by whitespace, then the pixels, row by row. Written and read here alone.
const std = @import("std");
const assert = std.debug.assert;

/// The largest value a pixel has: one byte each.
pub const max_value = 255;
const header_format = "P5\n{d} {d}\n" ++ std.fmt.comptimePrint("{d}", .{max_value}) ++ "\n";
/// Room for any picture's header.
const header_bytes_max = std.fmt.count(header_format, .{ max_side, max_side });
const max_side = std.math.maxInt(u32);
pub const Header = [header_bytes_max]u8;

/// The header of a `width` by `height` picture, its pixels to follow.
pub fn header(buf: *Header, width: u32, height: u32) []const u8 {
    assert(width > 0);
    assert(height > 0);
    // Ignored: `Header` holds the longest, both sides at their largest
    return std.fmt.bufPrint(buf, header_format, .{ width, height }) catch unreachable;
}

/// What a PGM's header says: its size, and where its pixels start, every one of them
/// in the data read.
pub const Read = struct { width: u32, height: u32, pixels_at: u32 };

/// The header of `data`, outside data: null when it isn't a PGM of a byte a pixel, or
/// its pixels aren't all there.
pub fn read(data: []const u8) ?Read {
    if (data.len > std.math.maxInt(u32)) return null; // Past any picture noface reads
    var at: u32 = 0;
    var fields: [4][]const u8 = undefined;
    for (&fields) |*field| {
        while (at < data.len and std.ascii.isWhitespace(data[at])) at += 1;
        const start = at;
        while (at < data.len and !std.ascii.isWhitespace(data[at])) at += 1;
        field.* = data[start..at];
    }
    // The one whitespace byte between the largest value and the pixels
    if (at >= data.len) return null;
    at += 1;
    if (!std.mem.eql(u8, fields[0], "P5")) return null;
    const width = std.fmt.parseInt(u32, fields[1], 10) catch return null;
    const height = std.fmt.parseInt(u32, fields[2], 10) catch return null;
    const largest = std.fmt.parseInt(u32, fields[3], 10) catch return null;
    if (largest != max_value) return null; // Two bytes a pixel: not read as one
    if (width == 0 or height == 0) return null;
    const size = std.math.mul(u32, width, height) catch return null;
    if (data.len - at < size) return null;
    assert(at + size <= data.len);
    assert(at >= "P5 1 1 255 ".len); // Past a header: its four fields, and a space each
    return .{ .width = width, .height = height, .pixels_at = at };
}

test "a picture's header is read back as written, and anything else is refused" {
    var buf: Header = undefined;
    const pixels = [_]u8{ 0, 0x40, 0x80, 0xff };
    var data: [64]u8 = undefined;
    const head = header(&buf, 2, 2);
    @memcpy(data[0..head.len], head);
    @memcpy(data[head.len..][0..pixels.len], &pixels);
    const got = read(data[0 .. head.len + pixels.len]).?;
    try std.testing.expectEqual(@as(u32, 2), got.width);
    try std.testing.expectEqualSlices(u8, &pixels, data[got.pixels_at..][0..4]);
    try std.testing.expect(read("P5\n2 2\n65535\nabcdefgh") == null); // Two bytes a pixel
    try std.testing.expect(read("P5\n4 4\n255\nab") == null); // Pixels missing
    try std.testing.expect(read("P6\n1 1\n255\nabc") == null); // Colour
    try std.testing.expect(read("P5\n4294967296 4294967296\n255\nab") == null);
}
