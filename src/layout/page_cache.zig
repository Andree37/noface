//! Which cached page to overwrite when rendering a new one.
const std = @import("std");
const assert = std.debug.assert;
const check = @import("../base/check.zig");

/// Picks a free slot, else one outside the window around `center`.
/// Keeps the page on screen and both of its neighbours.
pub fn victim(pages: [3]i64, center: i64) usize {
    check.that(center >= 0, "the page being read has a number");
    const index = for (pages, 0..) |p, i| {
        if (p < 0) break i;
    } else for (pages, 0..) |p, i| {
        if (p < center - 1 or p > center + 1) break i;
    } else for (pages, 0..) |p, i| {
        if (p != center) break i;
    } else 0;
    // The page on screen is overwritten only when every slot holds it
    if (pages[index] == center) assert(std.mem.allEqual(i64, &pages, center));
    return index;
}

test "both neighbours stay cached" {
    var pages = [_]i64{ -1, -1, -1 };
    pages[victim(pages, 5)] = 5;
    pages[victim(pages, 5)] = 6;
    pages[victim(pages, 5)] = 4;
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 4) != null);
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 5) != null);
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 6) != null);
}

test "turning forward evicts the page left behind" {
    var pages = [_]i64{ 4, 5, 6 };
    pages[victim(pages, 6)] = 7;
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 4) == null);
    try std.testing.expect(std.mem.indexOfScalar(i64, &pages, 5) != null);
}
