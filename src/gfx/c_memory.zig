//! Where the stb C libraries get their memory: from a budget, like everything else,
//! instead of C's malloc where noface can't see it. Each block keeps its size in a
//! small header, since C's free doesn't pass one.
const std = @import("std");
const memory = @import("../base/memory.zig");

const header = 16; // Keeps the block after it aligned for any C type

var default_budget = memory.Budget{ .name = "stb", .child = std.heap.smp_allocator, .limit = 256 << 20 };
var budget: *memory.Budget = &default_budget;

/// Sends stb's allocations to `b` from now on. Call before any font or picture is used.
pub fn use(b: *memory.Budget) void {
    budget = b;
}

/// Back to the built-in budget: for a caller whose budget is about to go away (a
/// test's, or a scenario's), so nothing is left pointing at it.
pub fn use_default() void {
    budget = &default_budget;
}

fn size_of(block: [*]u8) usize {
    return std.mem.readInt(usize, block[0..@sizeOf(usize)], .little);
}

export fn noface_malloc(size: usize) ?*anyopaque {
    const block = budget.allocator().alignedAlloc(u8, .@"16", header + size) catch return null;
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], size, .little);
    return block.ptr + header;
}

export fn noface_free(p: ?*anyopaque) void {
    const user: [*]u8 = @ptrCast(p orelse return);
    const block: [*]align(16) u8 = @alignCast(user - header);
    budget.allocator().free(block[0 .. header + size_of(block)]);
}

export fn noface_realloc(p: ?*anyopaque, size: usize) ?*anyopaque {
    const old: [*]u8 = @ptrCast(p orelse return noface_malloc(size));
    const old_size = size_of(old - header);
    const fresh: [*]u8 = @ptrCast(noface_malloc(size) orelse return null);
    @memcpy(fresh[0..@min(size, old_size)], old[0..@min(size, old_size)]);
    noface_free(p);
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
