//! The memory one picture is decoded in: an arena over the decoders' memory, with a
//! fixed limit, every block handed back at once when the picture is done. A decoder
//! asks for what the picture needs as it goes, and frees nothing: a picture too large
//! for the limit is decoded smaller instead (see `image.zig`).
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// The most one picture's decoding may hold, besides its scaled result: enough for
/// every picture the decoders read whole before (a 48 MP progressive gray JPEG, whose
/// coefficients take two bytes a pixel), and half the decoders' region.
pub const bytes_max: u64 = 96 << 20;

/// The most blocks a picture's decoding takes: tables, a few rows or planes per
/// component, and the scaler's sums. A decoder that took more would be a bug.
const blocks_max = 32;

comptime {
    assert(bytes_max <= std.math.maxInt(u32));
    assert(blocks_max >= 16);
}

pub const Workspace = struct {
    parent: Allocator,
    limit: u64,
    used: u64 = 0,
    peak: u64 = 0,
    blocks: [blocks_max]Block = undefined,
    count: u32 = 0,

    const Block = struct { memory: []u8, alignment: Alignment };

    /// How far a workspace has got, for `rewind`.
    pub const Mark = struct { count: u32, used: u64 };

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = Allocator.noResize,
        .remap = Allocator.noRemap,
        .free = free,
    };

    pub fn init(parent: Allocator, limit: u64) Workspace {
        assert(limit > 0);
        assert(limit <= std.math.maxInt(u32) * @as(u64, blocks_max));
        return .{ .parent = parent, .limit = limit };
    }

    /// An allocator whose blocks come back by `rewind` and `reset`, not `free`. A block
    /// isn't zeroed or filled: the decoders set what they read.
    pub fn allocator(w: *Workspace) Allocator {
        assert(w.used <= w.limit);
        assert(w.count <= blocks_max);
        return .{ .ptr = w, .vtable = &vtable };
    }

    pub fn mark(w: *const Workspace) Mark {
        assert(w.count <= blocks_max);
        assert(w.used <= w.limit);
        return .{ .count = w.count, .used = w.used };
    }

    /// Hands back every block taken since `at`, the last first.
    pub fn rewind(w: *Workspace, at: Mark) void {
        assert(at.count <= w.count);
        assert(at.used <= w.used);
        for (0..w.count - at.count) |_| {
            w.count -= 1;
            const block = w.blocks[w.count];
            w.parent.rawFree(block.memory, block.alignment, @returnAddress());
        }
        w.used = at.used;
        assert(w.count == at.count);
    }

    /// Hands back every block.
    pub fn reset(w: *Workspace) void {
        w.rewind(.{ .count = 0, .used = 0 });
        assert(w.count == 0);
        assert(w.used == 0);
    }

    // usize: std.mem.Allocator's interface
    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const w: *Workspace = @ptrCast(@alignCast(context));
        assert(w.used <= w.limit);
        // Every block a decoder takes is counted: one more is a bug
        assert(w.count < blocks_max);
        if (len > w.limit - w.used) return null;
        // The parent counts it too: a picture shows in the decoders' budget
        const pointer = w.parent.rawAlloc(len, alignment, return_address) orelse return null;
        w.blocks[w.count] = .{ .memory = pointer[0..len], .alignment = alignment };
        w.count += 1;
        w.used += len;
        w.peak = @max(w.peak, w.used);
        assert(w.used <= w.limit);
        return pointer;
    }

    /// Only the last block comes back at once, as on a bump region; the others wait
    /// for `rewind` or `reset`.
    // usize: std.mem.Allocator's interface
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const w: *Workspace = @ptrCast(@alignCast(context));
        assert(w.count > 0); // Only blocks this workspace handed out come back
        assert(memory.len <= w.used);
        const last = w.blocks[w.count - 1];
        if (last.memory.ptr != memory.ptr) return;
        assert(last.memory.len == memory.len);
        w.count -= 1;
        w.used -= memory.len;
        w.parent.rawFree(last.memory, alignment, return_address);
    }
};

test "a workspace hands its blocks back at once, and keeps to its limit" {
    var w = Workspace.init(std.testing.allocator, 1000);
    const alloc = w.allocator();
    const first = try alloc.alloc(u8, 400);
    const kept = w.mark();
    _ = try alloc.alloc(u32, 100);
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 300));
    try std.testing.expectEqual(@as(u64, 800), w.used);
    w.rewind(kept);
    try std.testing.expectEqual(@as(u64, 400), w.used);
    const last = try alloc.alloc(u8, 600);
    alloc.free(first); // Not the last: waits for the reset
    alloc.free(last); // The last block comes back at once
    try std.testing.expectEqual(@as(u64, 400), w.used);
    try std.testing.expectEqual(@as(u64, 1000), w.peak);
    w.reset();
    try std.testing.expectEqual(@as(u32, 0), w.count);
}
