//! Where the font and picture decoders take their memory from: a budget, like
//! everything else, so glyph bitmaps and decoded pictures show up in its numbers.
const std = @import("std");
const assert = std.debug.assert;
const memory = @import("../base/memory.zig");

const default_limit = 256 << 20;

/// For code that never chose one (the development tools, tests): taken from the
/// system as it's used, within its limit.
var default_budget = memory.Budget{
    .name = "decoders",
    .child = std.heap.smp_allocator,
    .limit = default_limit,
};
var budget: *memory.Budget = &default_budget;

comptime {
    assert(default_limit > 0);
    assert(default_limit <= 480 << 20);
}

/// Sends the decoders' allocations to `b` from now on. Call before any font or picture
/// is used: a glyph's bitmap is freed, if ever, to the budget it came from.
pub fn use(b: *memory.Budget) void {
    // A budget with no room could never hold a glyph
    assert(b.limit > 0);
    budget = b;
    assert(budget.live <= budget.limit);
}

/// Back to the built-in budget: for a caller whose budget is about to go away (a
/// test's, or a scenario's), so nothing is left pointing at it.
pub fn use_default() void {
    budget = &default_budget;
    // Nothing changes the built-in budget's limit
    assert(budget.limit == default_limit);
}

/// Where the font and picture decoders take their memory from: the budget given to
/// `use`, or the built-in one.
pub fn allocator() std.mem.Allocator {
    assert(budget.limit > 0);
    assert(budget.live <= budget.limit);
    return budget.allocator();
}

test "the decoders take their memory from the budget in use" {
    var b = memory.Budget{ .name = "decoders", .child = std.testing.allocator, .limit = 1 << 20 };
    use(&b);
    defer use_default();
    const block = try allocator().alloc(u8, 100);
    try std.testing.expectEqual(@as(u64, 100), b.live);
    allocator().free(block);
    try std.testing.expectEqual(@as(u64, 0), b.live);
    try std.testing.expectError(error.OutOfMemory, allocator().alloc(u8, 2 << 20));
    use_default();
    try std.testing.expect(budget == &default_budget);
}
