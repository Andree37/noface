//! Memory with a budget, out of a region reserved at startup. A budget counts what it
//! hands out, keeps the peak, and refuses anything past its limit; its region is the
//! address space it hands out from, taken from the system once, before `seal`. Every
//! lifetime in noface (the app, an open book, a single action) gets one, so a leak or a
//! runaway book shows up as a number in the log, not as a slow Kindle, and running out
//! is an error the caller handles, never a request the system might turn down later.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Set once startup has reserved every region: from then on noface asks the system for
/// no memory, which `Region.reserve` and a budget without a region assert.
pub var sealed: bool = false;

/// How many times this file has asked the system for memory: once per region. A test
/// reads it to prove nothing more is asked for after `seal`.
pub var system_requests: u32 = 0;

/// Allocations a budget without a region asked of the system after `seal`: each one
/// breaks the rule, and should be 0.
pub var late_requests: u32 = 0;

/// Ends startup: every region is reserved, and no more may be.
pub fn seal() void {
    assert(!sealed); // Once, at the end of startup
    assert(system_requests > 0); // Startup reserved its regions first
    sealed = true;
}

/// What a heap region hands out whole, and cuts into slots for small blocks.
pub const unit_bytes: u32 = 64 << 10;

/// A heap region's most units: 64 MB. Its tables have one byte per unit.
const units_max: u32 = 1 << order_max;

/// A heap block is 2^order units; the largest is the whole of the largest region.
const order_max: u5 = 10;

/// Small blocks go in slots of 16 bytes to 32 KB, each class twice the last.
const slot_bytes_min: u32 = 16;
const slot_classes: u32 = 12;

/// In `Region.taken`: a unit cut into slots, which stays so.
const slab: u8 = 0xff;

comptime {
    assert(slot_bytes_min << slot_classes == unit_bytes);
    assert(slot_bytes_min >= @sizeOf(u32)); // A free slot holds the next one's place
    assert(order_max + 1 < slab); // Orders and the slab mark never meet
    // Pages given back are whole: a unit is a whole number of pages
    assert(unit_bytes % std.heap.page_size_max == 0);
}

/// Address space taken from the system once, at startup; its pages come in as they
/// are first touched. A heap region hands out and takes back blocks in any order (the
/// app's memory); a bump region hands them out one after another and is emptied all at
/// once (a book's, while it's open).
pub const Region = struct {
    name: []const u8,
    kind: Kind,
    bytes: []align(unit_bytes) u8,
    // A bump region's: where the next block goes, and the furthest it has been, ever
    // and since its pages were last given back
    end: u32 = 0,
    end_peak: u32 = 0,
    touched: u32 = 0,
    // A heap region's, per unit: the order + 1 of the free block that starts there,
    // and of the block handed out that starts there (`slab` for one cut into slots);
    // 0 for neither
    free: [units_max]u8 = @splat(0),
    taken: [units_max]u8 = @splat(0),
    // Per slot class: the first free slot (its offset + 1, 0 for none), and where the
    // next new slot is cut (a multiple of `unit_bytes` when a new slab is needed)
    slots_free: [slot_classes]u32 = @splat(0),
    slots_next: [slot_classes]u32 = @splat(0),
    units_taken: u32 = 0,
    units_peak: u32 = 0,

    pub const Kind = enum { heap, bump };

    /// What emptying a bump region does with the pages it touched.
    pub const Pages = enum { keep, give_back };

    /// Takes `size` bytes of address space from the system: only during startup.
    pub fn reserve(name: []const u8, kind: Kind, size: u32) !Region {
        assert(!sealed); // After startup, nothing more is asked of the system
        assert(size % unit_bytes == 0);
        assert(size > 0);
        if (kind == .heap) assert(size <= units_max * unit_bytes);
        const pointer = std.heap.PageAllocator.map(size, .fromByteUnits(unit_bytes)) orelse
            return error.OutOfMemory;
        system_requests += 1;
        const bytes: []align(unit_bytes) u8 = @alignCast(pointer[0..size]);
        var region = Region{ .name = name, .kind = kind, .bytes = bytes };
        if (kind == .heap) region.heap_init();
        return region;
    }

    /// Gives the address space back: for tests, which reserve their own.
    pub fn release(region: *Region) void {
        assert(region.bytes.len > 0);
        assert(builtin.is_test); // noface keeps its regions until it exits
        std.heap.PageAllocator.unmap(region.bytes);
        region.bytes = &.{};
    }

    /// Empties a bump region. With `.give_back`, also hands the pages it touched back
    /// to the system, which gives them again, zeroed, when next touched: the region
    /// stays reserved, and an idle noface holds no more than with nothing open.
    pub fn reset(region: *Region, pages: Pages) void {
        assert(region.kind == .bump);
        assert(region.end <= region.touched);
        region.end = 0;
        if (pages == .keep) return;
        const touched = std.mem.alignForward(u32, region.touched, unit_bytes);
        region.touched = 0;
        if (touched == 0) return;
        assert(touched <= region.bytes.len);
        const advice = std.posix.MADV.DONTNEED;
        std.posix.madvise(region.bytes.ptr, touched, advice) catch {}; // Ignored: only advice
    }

    /// Whether nothing is handed out: a bump region's end at its start.
    pub fn empty(region: *const Region) bool {
        assert(region.bytes.len > 0);
        assert(region.kind == .bump); // A heap region keeps its slabs
        return region.end == 0;
    }

    /// The most bytes of the region in use at once, slack and slabs included.
    pub fn used_peak(region: *const Region) u64 {
        assert(region.end_peak <= region.bytes.len);
        assert(region.units_peak <= units_max);
        return switch (region.kind) {
            .bump => region.end_peak,
            .heap => @as(u64, region.units_peak) * unit_bytes,
        };
    }

    fn units(region: *const Region) u32 {
        assert(region.kind == .heap);
        const count: u32 = @intCast(region.bytes.len / unit_bytes);
        assert(count <= units_max);
        return count;
    }

    fn offset_of(region: *const Region, pointer: [*]u8) u32 {
        assert(@intFromPtr(pointer) >= @intFromPtr(region.bytes.ptr)); // One of its blocks
        const at = @intFromPtr(pointer) - @intFromPtr(region.bytes.ptr);
        assert(at < region.bytes.len);
        return @intCast(at);
    }

    /// A block of `len` bytes at `alignment`, or null when the region has no room.
    fn take(region: *Region, len: u64, alignment: Alignment) ?[*]u8 {
        assert(len > 0);
        assert(region.bytes.len > 0);
        const align_bytes: u64 = alignment.toByteUnits();
        if (align_bytes > unit_bytes) return null;
        if (len > region.bytes.len) return null;
        return switch (region.kind) {
            .bump => region.bump_take(@intCast(len), @intCast(align_bytes)),
            .heap => region.heap_take(len, align_bytes),
        };
    }

    /// Takes back a block `take` handed out, at its current length.
    fn give(region: *Region, block: []u8, alignment: Alignment) void {
        const at = region.offset_of(block.ptr);
        assert(at + block.len <= region.bytes.len);
        switch (region.kind) {
            // Only the last block comes back, as an arena's would
            .bump => if (at + block.len == region.end) {
                region.end = at;
            },
            .heap => {
                const size = slot_size(block.len, alignment.toByteUnits()).?;
                if (size < unit_bytes) {
                    region.slot_give(at, class_of(size));
                } else {
                    region.block_give(at / unit_bytes, order_of(size).?);
                }
            },
        }
    }

    /// Whether `block` can become `new_len` bytes where it is.
    fn resize(region: *Region, block: []u8, alignment: Alignment, new_len: u64) bool {
        const at = region.offset_of(block.ptr);
        assert(at + block.len <= region.bytes.len);
        assert(new_len > 0);
        switch (region.kind) {
            .bump => {
                if (at + block.len != region.end) return new_len <= block.len;
                if (at + new_len > region.bytes.len) return false;
                region.bump_to(at + @as(u32, @intCast(new_len)));
                return true;
            },
            .heap => {
                const align_bytes = alignment.toByteUnits();
                const new_size = slot_size(new_len, align_bytes) orelse return false;
                return new_size == slot_size(block.len, align_bytes).?;
            },
        }
    }

    fn bump_take(region: *Region, len: u32, align_bytes: u32) ?[*]u8 {
        assert(region.kind == .bump);
        assert(std.math.isPowerOfTwo(align_bytes));
        const start = std.mem.alignForward(u32, region.end, align_bytes);
        if (@as(u64, start) + len > region.bytes.len) return null;
        region.bump_to(start + len);
        return region.bytes.ptr + start;
    }

    fn bump_to(region: *Region, end: u32) void {
        assert(region.kind == .bump);
        assert(end <= region.bytes.len);
        region.end = end;
        region.end_peak = @max(region.end_peak, end);
        region.touched = @max(region.touched, end);
    }

    fn heap_init(region: *Region) void {
        const count = region.units();
        assert(count > 0);
        // Free blocks as large as fit, each starting at a multiple of its own size
        var unit: u32 = 0;
        while (unit < count) {
            var order: u5 = order_max;
            while (unit % (@as(u32, 1) << order) != 0 or unit + (@as(u32, 1) << order) > count) {
                order -= 1;
            }
            region.free[unit] = @as(u8, order) + 1;
            unit += @as(u32, 1) << order;
        }
        assert(unit == count);
    }

    fn heap_take(region: *Region, len: u64, align_bytes: u64) ?[*]u8 {
        assert(region.kind == .heap);
        assert(align_bytes <= unit_bytes);
        const size = slot_size(len, align_bytes) orelse return null;
        if (size < unit_bytes) return region.slot_take(class_of(size));
        const unit = region.block_take(order_of(size) orelse return null) orelse return null;
        return region.bytes.ptr + unit * unit_bytes; // Within 64 MB, so in u32
    }

    fn slot_take(region: *Region, class: u32) ?[*]u8 {
        assert(class < slot_classes);
        const size = slot_bytes_min << @intCast(class);
        const first = region.slots_free[class];
        if (first != 0) {
            const at = first - 1;
            assert(at % size == 0);
            region.slots_free[class] = std.mem.bytesToValue(u32, region.bytes[at..][0..4]);
            return region.bytes.ptr + at;
        }
        // None yet, or the slab is used up: cut a fresh unit into slots
        if (region.slots_next[class] % unit_bytes == 0) {
            const unit = region.block_take(0) orelse return null;
            region.taken[unit] = slab;
            region.slots_next[class] = unit * unit_bytes;
        }
        const at = region.slots_next[class];
        region.slots_next[class] = at + size;
        assert(at % size == 0); // Aligned to its own size, so to any smaller alignment
        return region.bytes.ptr + at;
    }

    fn slot_give(region: *Region, at: u32, class: u32) void {
        assert(class < slot_classes);
        assert(region.taken[at / unit_bytes] == slab); // A slot of a slab
        const next = region.slots_free[class];
        region.bytes[at..][0..4].* = std.mem.toBytes(next);
        region.slots_free[class] = at + 1;
    }

    /// The smallest free block of `order` or more, split down to `order`: its first unit.
    fn block_take(region: *Region, order: u5) ?u32 {
        assert(order <= order_max);
        assert(region.units_taken <= region.units());
        var best: ?u32 = null;
        var best_order: u32 = order_max + 1;
        for (region.free[0..region.units()], 0..) |head, unit| {
            if (head == 0) continue;
            const o = head - 1;
            if (o >= order and o < best_order) {
                best = @intCast(unit);
                best_order = o;
            }
        }
        const unit = best orelse return null;
        region.free[unit] = 0;
        var o: u5 = @intCast(best_order);
        while (o > order) {
            o -= 1;
            region.free[unit + (@as(u32, 1) << o)] = @as(u8, o) + 1; // The upper half stays free
        }
        region.taken[unit] = @as(u8, order) + 1;
        region.units_taken += @as(u32, 1) << order;
        region.units_peak = @max(region.units_peak, region.units_taken);
        return unit;
    }

    /// Frees the block at `unit`, merging it with its free neighbours of the same size.
    fn block_give(region: *Region, unit: u32, order: u5) void {
        assert(region.taken[unit] == @as(u8, order) + 1); // Handed out at this size
        assert(region.units_taken >= @as(u32, 1) << order);
        region.taken[unit] = 0;
        region.units_taken -= @as(u32, 1) << order;
        var at = unit;
        var o = order;
        while (o < order_max) {
            const buddy = at ^ (@as(u32, 1) << o);
            if (buddy >= region.units() or region.free[buddy] != @as(u8, o) + 1) break;
            region.free[buddy] = 0;
            at = @min(at, buddy);
            o += 1;
        }
        region.free[at] = @as(u8, o) + 1;
    }
};

/// The slot or block size a heap region keeps `len` bytes at `align_bytes` in: a power
/// of two, so blocks of the same size can stand in for each other.
fn slot_size(len: u64, align_bytes: u64) ?u64 {
    assert(len > 0);
    assert(std.math.isPowerOfTwo(align_bytes));
    return std.math.ceilPowerOfTwo(u64, @max(len, align_bytes, slot_bytes_min)) catch null;
}

fn class_of(size: u64) u32 {
    assert(size >= slot_bytes_min);
    assert(size < unit_bytes);
    return std.math.log2_int(u64, size) - std.math.log2_int(u64, slot_bytes_min);
}

fn order_of(size: u64) ?u5 {
    assert(size >= unit_bytes);
    assert(std.math.isPowerOfTwo(size));
    const order = std.math.log2_int(u64, size / unit_bytes);
    if (order > order_max) return null;
    return @intCast(order);
}

pub const Budget = struct {
    name: []const u8,
    region: ?*Region = null, // Where its memory comes from: reserved at startup
    child: ?Allocator = null, // Or, before `seal` only (tests, tools), the system
    limit: u64, // Bytes
    live: u64 = 0, // Bytes handed out and not yet freed
    peak: u64 = 0, // The most bytes live at once
    allocations: u64 = 0,
    refused: u64 = 0, // Requests turned down for going over the limit, or a full region

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator(budget: *Budget) Allocator {
        assert(budget.name.len > 0); // The log names it
        assert(budget.live <= budget.limit);
        assert((budget.region == null) != (budget.child == null)); // One or the other
        return .{ .ptr = budget, .vtable = &vtable };
    }

    /// One line for the log: "memory book: 3120 KB live, 8440 KB peak, 1520 allocations,
    /// region 9216 of 131072 KB used at most".
    pub fn report(budget: *const Budget) void {
        assert(budget.live <= budget.peak);
        assert(budget.peak <= budget.limit);
        const over = if (budget.refused > 0) ", OVER LIMIT" else "";
        std.debug.print("memory {s}: {d} KB live, {d} KB peak, {d} allocations{s}", .{
            budget.name, budget.live / 1024, budget.peak / 1024, budget.allocations, over,
        });
        if (budget.region) |region| {
            std.debug.print(", region {d} of {d} KB used at most", .{
                region.used_peak() / 1024,
                region.bytes.len / 1024,
            });
        }
        std.debug.print("\n", .{});
    }

    /// Forgets all a budget on a bump region handed out, at once, as an arena is
    /// emptied: nothing it handed out may be used after.
    pub fn reset(budget: *Budget, pages: Region.Pages) void {
        const region = budget.region.?;
        assert(region.kind == .bump);
        assert(budget.live <= budget.limit);
        budget.live = 0;
        region.reset(pages);
        assert(region.empty());
    }

    /// The system's allocator, for a budget without a region: never after `seal`. One
    /// asked for after it is a bug, a crash in a debug build; elsewhere it's counted,
    /// and named in the log the first time, so the budget can be given a region.
    fn system(budget: *Budget) Allocator {
        assert(budget.region == null);
        assert(budget.child != null); // `allocator` checked it has one or the other
        if (sealed) {
            if (builtin.mode == .debug) @panic("memory asked of the system after startup");
            if (late_requests == 0) {
                std.debug.print("memory {s}: asked of the system after startup\n", .{budget.name});
            }
            late_requests += 1;
        }
        return budget.child.?;
    }

    fn fits(budget: *Budget, more: u64) bool {
        assert(budget.live <= budget.limit);
        assert(more > 0); // Growing by nothing needs no room
        if (budget.live + more <= budget.limit) return true;
        budget.refuse("over its limit");
        return false;
    }

    /// Counts a request turned down, saying why in the log the first time.
    fn refuse(budget: *Budget, why: []const u8) void {
        assert(why.len > 0);
        assert(budget.live <= budget.limit);
        if (budget.refused == 0 and !builtin.is_test) {
            const limit_kb = budget.limit / 1024;
            std.debug.print("memory {s}: {s} ({d} KB)\n", .{ budget.name, why, limit_kb });
        }
        budget.refused += 1;
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

    // usize: std.mem.Allocator's interface
    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(budget.live <= budget.limit);
        if (!budget.fits(len)) return null;
        const taken = if (budget.region) |region|
            region.take(len, alignment)
        else
            budget.system().rawAlloc(len, alignment, return_address);
        const pointer = taken orelse {
            budget.refuse("out of room in its region");
            return null;
        };
        budget.grew(len);
        budget.allocations += 1;
        assert(budget.live <= budget.limit);
        return pointer;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize, // usize: std.mem.Allocator's interface
        return_address: usize, // usize: std.mem.Allocator's interface
    ) bool {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        if (new_len > memory.len and !budget.fits(new_len - memory.len)) return false;
        const done = if (budget.region) |region|
            region.resize(memory, alignment, new_len)
        else
            budget.system().rawResize(memory, alignment, new_len, return_address);
        if (!done) return false;
        budget.resized(memory.len, new_len);
        assert(budget.live <= budget.limit);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize, // usize: std.mem.Allocator's interface
        return_address: usize, // usize: std.mem.Allocator's interface
    ) ?[*]u8 {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        if (new_len > memory.len and !budget.fits(new_len - memory.len)) return null;
        const moved = if (budget.region) |region|
            (if (region.resize(memory, alignment, new_len)) memory.ptr else null)
        else
            budget.system().rawRemap(memory, alignment, new_len, return_address);
        const pointer = moved orelse return null;
        budget.resized(memory.len, new_len);
        assert(budget.live <= budget.limit);
        return pointer;
    }

    // usize: std.mem.Allocator's interface
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        assert(budget.allocations > 0);
        if (budget.region) |region| {
            region.give(memory, alignment);
        } else {
            // Handed out before `seal`, so given back to the system even after it
            budget.child.?.rawFree(memory, alignment, return_address);
        }
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

test "a heap region passes the standard allocator tests, and merges what comes back" {
    var region = try Region.reserve("test", .heap, 4 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    try std.heap.testAllocator(b.allocator());
    try std.heap.testAllocatorAligned(b.allocator());
    try std.heap.testAllocatorAlignedShrink(b.allocator());
    try std.testing.expectEqual(@as(u64, 0), b.live);
    // Big blocks of every size, freed out of order, merge back into whole free blocks
    const a = b.allocator();
    var blocks: [6][]u8 = undefined;
    for (&blocks, 0..) |*block, i| block.* = try a.alloc(u8, (unit_bytes << @intCast(i % 3)) - 7);
    for ([_]u32{ 3, 0, 5, 1, 4, 2 }) |i| a.free(blocks[i]);
    const slabs = region.units_taken;
    for (region.taken[0..region.units()]) |t| try std.testing.expect(t == 0 or t == slab);
    // All of the region bar its slabs is free again, in blocks no buddy could join
    var free_units: u32 = 0;
    for (region.free[0..region.units()]) |head| {
        if (head != 0) free_units += @as(u32, 1) << @intCast(head - 1);
    }
    try std.testing.expectEqual(region.units(), free_units + slabs);
    const whole = try a.alloc(u8, 2 << 20); // Half the region, in one piece
    a.free(whole);
}

test "a bump region is an arena: in turn, the last given back, all emptied at once" {
    var region = try Region.reserve("test", .bump, 2 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    const a = b.allocator();
    var list: std.ArrayList(u32) = .empty;
    for (0..100_000) |i| try list.append(a, @intCast(i)); // Grows where it is
    try std.testing.expectEqual(list.capacity * 4, region.end); // No copies left behind
    const last = try a.alloc(u8, 3000);
    const end = region.end;
    a.free(last);
    try std.testing.expectEqual(end - 3000, region.end); // The last block comes back
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 4 << 20));
    b.reset(.keep);
    try std.testing.expect(region.empty());
    try std.testing.expectEqual(@as(u64, 0), b.live);
    _ = try a.alloc(u8, 1 << 20);
    b.reset(.give_back);
    try std.testing.expectEqual(@as(u32, 0), region.touched);
    try std.testing.expect(region.end_peak >= 1 << 20);
}

test "after seal, budgets on regions ask the system for nothing" {
    var app = try Region.reserve("app", .heap, 8 << 20);
    defer app.release();
    var book = try Region.reserve("book", .bump, 2 << 20);
    defer book.release();
    var app_budget = Budget{ .name = "app", .region = &app, .limit = app.bytes.len };
    const requests = system_requests;
    sealed = true;
    defer sealed = false;
    const a = app_budget.allocator();
    var kept: [16][]u8 = @splat(&.{});
    // Books opened and closed in turn, the app's memory churning alongside
    for (0..40) |round| {
        var book_budget = Budget{ .name = "book", .region = &book, .limit = book.bytes.len };
        const b = book_budget.allocator();
        for (0..50) |i| _ = try b.alloc(u8, 1 + (round * 997 + i * 131) % 20000);
        const slot = round % kept.len;
        a.free(kept[slot]);
        kept[slot] = try a.alloc(u8, 1 + (round * 7919) % 150_000);
        // A book too big for its region is an error to handle, not a crash
        try std.testing.expectError(error.OutOfMemory, b.alloc(u8, 4 << 20));
        book_budget.reset(.give_back);
    }
    for (kept) |block| a.free(block);
    try std.testing.expectEqual(@as(u64, 0), app_budget.live);
    try std.testing.expectEqual(requests, system_requests);
    try std.testing.expectEqual(@as(u32, 0), late_requests);
}
