//! Memory with a budget: an allocator that counts what it hands out, keeps the
//! peak, and refuses anything past its limit. Every lifetime in noface (the app,
//! an open book, a single action) gets one, so a leak or a runaway book shows up as
//! a number in the log, not as a slow Kindle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Budget = struct {
    name: []const u8,
    child: Allocator,
    limit: usize,
    live: usize = 0, // Bytes handed out and not yet freed
    peak: usize = 0,
    allocations: u64 = 0,
    refused: u64 = 0, // Requests turned down for going over the limit

    pub fn allocator(b: *Budget) Allocator {
        return .{ .ptr = b, .vtable = &vtable };
    }

    /// One line for the log: "memory book: 3120 KB live, 8440 KB peak, 1520 allocations".
    pub fn report(b: *const Budget) void {
        std.debug.print("memory {s}: {d} KB live, {d} KB peak, {d} allocations{s}\n", .{
            b.name, b.live / 1024, b.peak / 1024, b.allocations, if (b.refused > 0) ", OVER LIMIT" else "",
        });
    }

    fn fits(b: *Budget, more: usize) bool {
        if (b.live + more <= b.limit) return true;
        if (b.refused == 0 and !@import("builtin").is_test) std.debug.print("memory {s}: over its {d} KB limit\n", .{ b.name, b.limit / 1024 });
        b.refused += 1;
        return false;
    }

    fn grew(b: *Budget, more: usize) void {
        b.live += more;
        b.peak = @max(b.peak, b.live);
    }

    const vtable = Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        if (!b.fits(len)) return null;
        const p = b.child.rawAlloc(len, alignment, ret) orelse return null;
        b.grew(len);
        b.allocations += 1;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) bool {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !b.fits(new_len - memory.len)) return false;
        if (!b.child.rawResize(memory, alignment, new_len, ret)) return false;
        if (new_len > memory.len) b.grew(new_len - memory.len) else b.live -= memory.len - new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !b.fits(new_len - memory.len)) return null;
        const p = b.child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        if (new_len > memory.len) b.grew(new_len - memory.len) else b.live -= memory.len - new_len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        b.child.rawFree(memory, alignment, ret);
        b.live -= memory.len;
    }
};

test "a budget counts what is live and refuses what doesn't fit" {
    var b = Budget{ .name = "test", .child = std.testing.allocator, .limit = 100 };
    const a = b.allocator();
    const x = try a.alloc(u8, 60);
    try std.testing.expectEqual(@as(usize, 60), b.live);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 50));
    try std.testing.expectEqual(@as(u64, 1), b.refused);
    a.free(x);
    try std.testing.expectEqual(@as(usize, 0), b.live);
    try std.testing.expectEqual(@as(usize, 60), b.peak);
    const y = try a.alloc(u8, 90); // Fits again once freed
    a.free(y);
}

test "arenas on a budget count their blocks, and reset gives them back" {
    var b = Budget{ .name = "test", .child = std.testing.allocator, .limit = 1 << 20 };
    var arena = std.heap.ArenaAllocator.init(b.allocator());
    _ = try arena.allocator().alloc(u8, 5000);
    try std.testing.expect(b.live >= 5000);
    arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), b.live);
}
