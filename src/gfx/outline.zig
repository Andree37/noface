//! A glyph's outline, as the font readers hand it to the rasterizer: moves, lines,
//! and quadratic (TrueType) or cubic (CFF) curves, in font units.
const std = @import("std");
const assert = std.debug.assert;

pub const Vertex = struct {
    kind: Kind,
    /// Where the segment ends.
    x: i16,
    y: i16,
    /// A curve's control point, the first of a cubic's two.
    cx: i16 = 0,
    cy: i16 = 0,
    /// A cubic's second control point.
    cx1: i16 = 0,
    cy1: i16 = 0,

    pub const Kind = enum(u8) { move = 1, line = 2, curve = 3, cubic = 4 };
};

comptime {
    // Small enough to keep thousands of a glyph's in a few kilobytes
    assert(@sizeOf(Vertex) <= 14);
    assert(@sizeOf(Vertex.Kind) == 1);
}
