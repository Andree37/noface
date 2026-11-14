//! What the picture decoders hand back: one gray byte per pixel, row after row.
const std = @import("std");
const assert = std.debug.assert;

/// A decoded picture. The pixels belong to the allocator the decoder was given.
pub const Gray = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

/// The longest side a decoder accepts: stb_image's limit, kept so that the same
/// pictures open as before.
pub const side_max = 1 << 24;

/// The most pixels a decoder accepts, so that every size it works out fits 32 bits.
pub const pixels_max = 1 << 30;

comptime {
    assert(side_max <= pixels_max);
    // Four bytes a pixel, the most any decoder keeps, still fit 32 bits
    assert(@as(u64, pixels_max) * 4 <= std.math.maxInt(u32) + 1);
}

/// The gray of a colour, with the weights stb_image used (77, 150 and 29 out of 256).
pub fn luma(red: u8, green: u8, blue: u8) u8 {
    const sum = @as(u32, red) * 77 + @as(u32, green) * 150 + @as(u32, blue) * 29;
    // The weights add up to 256, so the gray of white is white
    assert(sum >> 8 <= 255);
    comptime assert(77 + 150 + 29 == 256);
    return @intCast(sum >> 8);
}

/// The same for 16-bit samples, kept in 16 bits as stb_image did before dropping the
/// low byte.
pub fn luma16(red: u16, green: u16, blue: u16) u16 {
    const sum = @as(u32, red) * 77 + @as(u32, green) * 150 + @as(u32, blue) * 29;
    assert(sum >> 8 <= std.math.maxInt(u16));
    comptime assert(77 + 150 + 29 == 256);
    return @intCast(sum >> 8);
}
