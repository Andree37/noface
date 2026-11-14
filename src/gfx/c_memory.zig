//! Where the stb C libraries get their memory: from a budget, like everything else,
//! instead of C's malloc where noface can't see it. Each block keeps its size in a
//! small header, since C's free doesn't pass one.
const std = @import("std");
const assert = std.debug.assert;
const memory = @import("../base/memory.zig");

/// C's size_t, which the shim's malloc and realloc are asked for, and which each
/// block's header keeps.
const c_size = usize;

const header = 16; // Keeps the block after it aligned for any C type
const block_alignment = 16;
const default_limit = 256 << 20;

comptime {
    assert(header >= @sizeOf(c_size));
    assert(header % block_alignment == 0);
    assert(block_alignment >= @alignOf(c_longdouble));
    assert(default_limit > header);
}

var default_budget = memory.Budget{
    .name = "stb",
    .child = std.heap.smp_allocator,
    .limit = default_limit,
};
var budget: *memory.Budget = &default_budget;

/// Sends stb's allocations to `b` from now on. Call before any font or picture is used.
pub fn use(b: *memory.Budget) void {
    // A budget too small for one header could never give C anything
    assert(b.limit > header);
    budget = b;
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
    assert(budget.limit > header);
    assert(budget.live <= budget.limit);
    return budget.allocator();
}

/// The size a block was asked for, from its header.
fn size_of(block: [*]u8) c_size {
    assert(@intFromPtr(block) % block_alignment == 0);
    const size = std.mem.readInt(c_size, block[0..@sizeOf(c_size)], .little);
    // `noface_malloc` only made blocks whose total fits
    assert(size <= std.math.maxInt(c_size) - header);
    return size;
}

export fn noface_malloc(size: c_size) ?*anyopaque {
    // Out of range is out of memory, as C's malloc would have it
    const total = std.math.add(c_size, header, size) catch return null;
    const block = budget.allocator().alignedAlloc(u8, .@"16", total) catch return null;
    assert(block.len == total);
    std.mem.writeInt(c_size, block[0..@sizeOf(c_size)], size, .little);
    const user = block.ptr + header;
    assert(@intFromPtr(user) % block_alignment == 0);
    return user;
}

export fn noface_free(p: ?*anyopaque) void {
    const user: [*]u8 = @ptrCast(p orelse return);
    // Every block handed to C is aligned: one that isn't was never ours
    assert(@intFromPtr(user) % block_alignment == 0);
    const block: [*]align(16) u8 = @alignCast(user - header);
    budget.allocator().free(block[0 .. header + size_of(block)]);
}

export fn noface_realloc(p: ?*anyopaque, size: c_size) ?*anyopaque {
    const old: [*]u8 = @ptrCast(p orelse return noface_malloc(size));
    assert(@intFromPtr(old) % block_alignment == 0);
    const old_size = size_of(old - header);
    const fresh: [*]u8 = @ptrCast(noface_malloc(size) orelse return null);
    const kept = @min(size, old_size);
    @memcpy(fresh[0..kept], old[0..kept]);
    noface_free(p);
    assert(size_of(fresh - header) == size);
    return fresh;
}

test "C blocks remember their size and come back whole" {
    var b = memory.Budget{ .name = "c", .child = std.testing.allocator, .limit = 1 << 20 };
    use(&b);
    defer use(&default_budget);
    const p = noface_malloc(100).?;
    try std.testing.expectEqual(@as(usize, 100 + header), b.live);
    const q = noface_realloc(p, 300).?;
    try std.testing.expectEqual(@as(usize, 300 + header), b.live);
    noface_free(q);
    try std.testing.expectEqual(@as(usize, 0), b.live);
    noface_free(null);
}
