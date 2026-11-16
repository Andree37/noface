//! Which cached page to overwrite when rendering a new one.
const std = @import("std");
const assert = std.debug.assert;

/// Picks a free slot, else one outside the window around `center`.
/// Keeps the page on screen and both of its neighbours.
pub fn victim(pages: [3]?u32, center: u32) u32 {
    const free = std.mem.indexOfScalar(?u32, &pages, null);
    const index: u32 = if (free) |i| @intCast(i) else for (pages, 0..) |p, i| {
        // Every slot holds a page: none was free
        if (p.? + 1 < center or p.? > center + 1) break @intCast(i);
    } else for (pages, 0..) |p, i| {
        if (p.? != center) break @intCast(i);
    } else 0;
    assert(index < pages.len);
    // The page on screen is overwritten only when every slot holds it
    if (pages[index] == center) assert(std.mem.allEqual(?u32, &pages, center));
    return index;
}

test "both neighbours stay cached" {
    var pages = [_]?u32{ null, null, null };
    pages[victim(pages, 5)] = 5;
    pages[victim(pages, 5)] = 6;
    pages[victim(pages, 5)] = 4;
    try std.testing.expect(std.mem.indexOfScalar(?u32, &pages, 4) != null);
    try std.testing.expect(std.mem.indexOfScalar(?u32, &pages, 5) != null);
    try std.testing.expect(std.mem.indexOfScalar(?u32, &pages, 6) != null);
}

test "turning forward evicts the page left behind" {
    var pages = [_]?u32{ 4, 5, 6 };
    pages[victim(pages, 6)] = 7;
    try std.testing.expect(std.mem.indexOfScalar(?u32, &pages, 4) == null);
    try std.testing.expect(std.mem.indexOfScalar(?u32, &pages, 5) != null);
}
