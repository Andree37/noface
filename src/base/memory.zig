//! Memory with a budget: an allocator that counts what it hands out, keeps the
//! peak, and refuses anything past its limit. Every lifetime in noface (the app,
//! an open book, a single action) gets one, so a leak or a runaway book shows up as
//! a number in the log, not as a slow Kindle.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Budget = struct {
    name: []const u8,
    child: Allocator,
    limit: u64, // Bytes
    live: u64 = 0, // Bytes handed out and not yet freed
    peak: u64 = 0, // The most bytes live at once
    allocations: u64 = 0,
    refused: u64 = 0, // Requests turned down for going over the limit

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator(budget: *Budget) Allocator {
        assert(budget.name.len > 0); // The log names it
        assert(budget.live <= budget.limit);
        return .{ .ptr = budget, .vtable = &vtable };
    }

    /// One line for the log: "memory book: 3120 KB live, 8440 KB peak, 1520 allocations".
    pub fn report(budget: *const Budget) void {
        assert(budget.live <= budget.peak);
        assert(budget.peak <= budget.limit);
        const over = if (budget.refused > 0) ", OVER LIMIT" else "";
        std.debug.print("memory {s}: {d} KB live, {d} KB peak, {d} allocations{s}\n", .{
            budget.name, budget.live / 1024, budget.peak / 1024, budget.allocations, over,
        });
    }

    fn fits(budget: *Budget, more: u64) bool {
        assert(budget.live <= budget.limit);
        assert(more > 0); // Growing by nothing needs no room
        if (budget.live + more <= budget.limit) return true;
        if (budget.refused == 0 and !@import("builtin").is_test) {
            std.debug.print("memory {s}: over its {d} KB limit\n", .{
                budget.name,
                budget.limit / 1024,
            });
        }
        budget.refused += 1;
        return false;
    }

    fn grew(budget: *Budget, more: u64) void {
        assert(budget.live + more <= budget.limit); // Only after `fits` said so
        budget.live += more;
        budget.peak = @max(budget.peak, budget.live);
        assert(budget.peak >= budget.live);
    }

    /// Takes back `less` bytes this budget handed out.
    fn shrank(budget: *Budget, less: u64) void {
        assert(less <= budget.live); // Only what this budget handed out comes back
        budget.live -= less;
        assert(budget.live <= budget.peak);
    }

    /// Counts a block that went from `old_len` bytes to `new_len`.
    fn resized(budget: *Budget, old_len: u64, new_len: u64) void {
        assert(old_len <= budget.live);
        if (new_len > old_len) {
            budget.grew(new_len - old_len);
        } else {
            budget.shrank(old_len - new_len);
        }
        assert(new_len <= budget.live);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(budget.live <= budget.limit);
        if (!budget.fits(len)) return null;
        const pointer = budget.child.rawAlloc(len, alignment, return_address) orelse return null;
        budget.grew(len);
        budget.allocations += 1;
        assert(budget.live <= budget.limit);
        return pointer;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        if (new_len > memory.len and !budget.fits(new_len - memory.len)) return false;
        if (!budget.child.rawResize(memory, alignment, new_len, return_address)) return false;
        budget.resized(memory.len, new_len);
        assert(budget.live <= budget.limit);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        if (new_len > memory.len and !budget.fits(new_len - memory.len)) return null;
        const pointer = budget.child.rawRemap(memory, alignment, new_len, return_address) orelse
            return null;
        budget.resized(memory.len, new_len);
        assert(budget.live <= budget.limit);
        return pointer;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        budget.child.rawFree(memory, alignment, return_address);
        budget.shrank(memory.len);
    }
};

test "a budget counts what is live and refuses what doesn't fit" {
    var b = Budget{ .name = "test", .child = std.testing.allocator, .limit = 100 };
    const a = b.allocator();
    const x = try a.alloc(u8, 60);
    try std.testing.expectEqual(@as(u64, 60), b.live);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 50));
    try std.testing.expectEqual(@as(u64, 1), b.refused);
    a.free(x);
    try std.testing.expectEqual(@as(u64, 0), b.live);
    try std.testing.expectEqual(@as(u64, 60), b.peak);
    const y = try a.alloc(u8, 90); // Fits again once freed
    a.free(y);
}

test "arenas on a budget count their blocks, and reset gives them back" {
    var b = Budget{ .name = "test", .child = std.testing.allocator, .limit = 1 << 20 };
    var arena = std.heap.ArenaAllocator.init(b.allocator());
    _ = try arena.allocator().alloc(u8, 5000);
    try std.testing.expect(b.live >= 5000);
    arena.deinit();
    try std.testing.expectEqual(@as(u64, 0), b.live);
}
