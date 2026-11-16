//! Where the font and picture decoders take their memory from: a budget, like
//! everything else, so glyph bitmaps and decoded pictures show up in its numbers.
//! There is none until one is given: the Kindle and the scenarios give
//! the decoders' region (`setup.decoders`), and each tool or test its own, so nothing
//! decodes on memory nobody chose.
const std = @import("std");
const assert = std.debug.assert;
const memory = @import("../base/memory.zig");

var budget: ?*memory.Budget = null;

/// Sends the decoders' allocations to `b` from now on. Call before any font or picture
/// is used: a glyph's bitmap is freed, if ever, to the budget it came from.
pub fn use(b: *memory.Budget) void {
    // A budget with no room could never hold a glyph
    assert(b.limit > 0);
    budget = b;
    assert(b.live <= b.limit);
}

/// Forgets the budget given to `use`: for a caller whose budget is about to go away (a
/// test's, or a scenario's), so nothing is left pointing at it.
pub fn stop_using(b: *memory.Budget) void {
    assert(budget == b); // Only the budget in use is let go of
    assert(b.live <= b.limit);
    budget = null;
}

/// Where the font and picture decoders take their memory from: the budget given to
/// `use`, which must have been called first.
pub fn allocator() std.mem.Allocator {
    const b = budget orelse @panic("decoders used before decoder_memory.use");
    assert(b.limit > 0);
    assert(b.live <= b.limit);
    return b.allocator();
}

test "the decoders take their memory from the budget in use" {
    var b = memory.Budget{ .name = "decoders", .child = std.testing.allocator, .limit = 1 << 20 };
    use(&b);
    defer stop_using(&b);
    const block = try allocator().alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), b.live);
    allocator().free(block);
    try std.testing.expectEqual(@as(u64, 0), b.live);
    try std.testing.expectError(error.OutOfMemory, allocator().alloc(u8, 2 << 20));
}
