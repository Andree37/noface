//! A picture's size from its header, without decoding it: JPEG and PNG, the formats
//! noface can draw. Layout needs sizes for every picture, decoding waits for drawing.
const std = @import("std");

pub const Size = struct { width: u32, height: u32 };

pub fn size(data: []const u8) ?Size {
    if (data.len >= 24 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) {
        const w = std.mem.readInt(u32, data[16..20], .big);
        const h = std.mem.readInt(u32, data[20..24], .big);
        return if (w > 0 and h > 0) .{ .width = w, .height = h } else null;
    }
    if (data.len >= 4 and data[0] == 0xff and data[1] == 0xd8) return jpeg_size(data);
    return null;
}

/// Walks JPEG segments to the frame header (SOF0 to SOF15, except DHT, JPG and DAC).
fn jpeg_size(data: []const u8) ?Size {
    var at: usize = 2;
    while (at + 9 < data.len) {
        if (data[at] != 0xff) return null;
        const marker = data[at + 1];
        if (marker == 0xff) {
            at += 1;
            continue;
        }
        const len: usize = std.mem.readInt(u16, data[at + 2 ..][0..2], .big);
        const frame = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (frame) {
            const h = std.mem.readInt(u16, data[at + 5 ..][0..2], .big);
            const w = std.mem.readInt(u16, data[at + 7 ..][0..2], .big);
            return if (w > 0 and h > 0) .{ .width = w, .height = h } else null;
        }
        if (len < 2) return null;
        at += 2 + len;
    }
    return null;
}

test "sizes come from PNG and JPEG headers" {
    var png = std.mem.zeroes([24]u8);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[16..20], 300, .big);
    std.mem.writeInt(u32, png[20..24], 200, .big);
    try std.testing.expectEqual(Size{ .width = 300, .height = 200 }, size(&png).?);
    // SOI, an APP0 segment of length 4, then SOF0 with height 50 and width 80.
    const jpeg = [_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x32, 0x00, 0x50, 0x03 };
    try std.testing.expectEqual(Size{ .width = 80, .height = 50 }, size(&jpeg).?);
    try std.testing.expect(size("GIF89a") == null);
}
