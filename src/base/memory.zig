//! Memory with a budget, out of a region reserved at startup. A budget counts what it
//! hands out, keeps the peak, and refuses anything past its limit; its region is the
//! address space it hands out from, taken from the system once, before `seal`. Every
//! lifetime in noface (the app, an open book, a single action) gets one, so a leak or a
//! runaway book shows up as a number in the log, not as a slow Kindle, and running out
//! is an error the caller handles, never a request the system might turn down later.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.memory);
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

/// A heap region's most units: 128 MB. Its tables have two bytes and a bit per unit.
const units_max: u32 = 2048;

/// Small blocks go in slots of 16 bytes to 32 KB, each class twice the last. A larger
/// block is a run of whole units, so it wastes less than a unit, never half itself.
const slot_bytes_min: u32 = 16;
const slot_classes: u32 = 12;

/// In `Region.taken`: a unit cut into slots, which stays so.
const slab: u16 = std.math.maxInt(u16);

comptime {
    assert(slot_bytes_min << slot_classes == unit_bytes);
    assert(slot_bytes_min >= @sizeOf(u32)); // A free slot holds the next one's place
    assert(units_max < slab); // A run's length and the slab mark never meet
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
    // A heap region's, per unit: whether it's handed out, and at the first unit of a
    // run handed out, the run's length in units (`slab` for a unit cut into slots)
    used: std.StaticBitSet(units_max) = .empty,
    taken: [units_max]u16 = @splat(0),
    // Per slot class: the first free slot (its offset + 1, 0 for none), and where the
    // next new slot is cut (a multiple of `unit_bytes` when a new slab is needed)
    slots_free: [slot_classes]u32 = @splat(0),
    slots_next: [slot_classes]u32 = @splat(0),
    units_taken: u32 = 0,
    units_peak: u32 = 0,
    // Bytes of freed heap blocks whose pages went back to the system, ever
    bytes_given_back: u64 = 0,

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
        const region = Region{ .name = name, .kind = kind, .bytes = bytes };
        assert(region.units_taken == 0); // Every unit free
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

    /// Hands the pages of a bump region past its end back to the system, as `reset`
    /// hands back all of them: after a rewind let go of more than is worth keeping.
    pub fn give_back_past_end(region: *Region) void {
        assert(region.kind == .bump);
        assert(region.end <= region.touched);
        const from = std.mem.alignForward(u32, region.end, std.heap.page_size_min);
        const to = std.mem.alignForward(u32, region.touched, unit_bytes);
        if (to <= from) return;
        assert(to <= region.bytes.len);
        region.touched = from;
        const advice = std.posix.MADV.DONTNEED;
        const pages: []align(std.heap.page_size_min) u8 = @alignCast(region.bytes[from..to]);
        std.posix.madvise(pages.ptr, pages.len, advice) catch {}; // Ignored: only advice
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

    /// Takes back a block `take` handed out, at its current length. The bytes it took
    /// back: on a bump region none, but for its last block.
    fn give(region: *Region, block: []u8, alignment: Alignment) u64 {
        const at = region.offset_of(block.ptr);
        assert(at + block.len <= region.bytes.len);
        switch (region.kind) {
            // Only the last block comes back, as an arena's would
            .bump => {
                if (at + block.len != region.end) return 0;
                region.end = at;
                return block.len;
            },
            .heap => {
                const size = slot_size(block.len, alignment.toByteUnits()).?;
                if (size < unit_bytes) {
                    region.slot_give(at, class_of(size));
                } else {
                    assert(at % unit_bytes == 0); // A run starts at a unit
                    assert(region.taken[at / unit_bytes] == units_for(block.len));
                    region.run_give(at / unit_bytes);
                }
                return block.len;
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
                if (!region.is_last(block)) return new_len <= block.len;
                if (at + new_len > region.bytes.len) return false;
                region.bump_to(at + @as(u32, @intCast(new_len)));
                return true;
            },
            .heap => {
                const align_bytes = alignment.toByteUnits();
                const size = slot_size(block.len, align_bytes).?;
                const new_size = slot_size(new_len, align_bytes) orelse return false;
                // A slot stays its size; a run grows or shrinks where it is
                if (size < unit_bytes or new_size < unit_bytes) return new_size == size;
                if (new_len > region.bytes.len) return false;
                return region.run_resize(at / unit_bytes, units_for(new_len));
            },
        }
    }

    /// Whether `block` ends where the bump region does: the one block it takes back.
    fn is_last(region: *const Region, block: []u8) bool {
        assert(region.kind == .bump);
        return region.offset_of(block.ptr) + block.len == region.end;
    }

    /// Starts the region's peak again from what it holds now: a book's own, as it opens.
    pub fn restart_peak(region: *Region) void {
        assert(region.kind == .bump);
        assert(region.end <= region.end_peak);
        region.end_peak = region.end;
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

    fn heap_take(region: *Region, len: u64, align_bytes: u64) ?[*]u8 {
        assert(region.kind == .heap);
        assert(align_bytes <= unit_bytes);
        const size = slot_size(len, align_bytes) orelse return null;
        if (size < unit_bytes) return region.slot_take(class_of(size));
        const unit = region.run_take(units_for(len)) orelse return null;
        return region.bytes.ptr + unit * unit_bytes; // Within 128 MB, so in u32
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
            const unit = region.run_take(1) orelse return null;
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

    /// The first `count` free units in a row, handed out as one run: its first unit.
    fn run_take(region: *Region, count: u32) ?u32 {
        assert(count > 0);
        assert(region.units_taken <= region.units());
        if (count > region.units() - region.units_taken) return null;
        var start: u32 = 0;
        for (0..region.units()) |unit| {
            if (region.used.isSet(unit)) {
                start = @intCast(unit + 1);
            } else if (unit + 1 - start == count) {
                region.mark(start, count);
                region.taken[start] = @intCast(count);
                return start;
            }
        }
        return null;
    }

    /// Frees the run that starts at `unit`, handing its pages back.
    fn run_give(region: *Region, unit: u32) void {
        const count = region.taken[unit];
        assert(count != slab); // Slabs stay slabs
        assert(count > 0); // A run handed out starts here
        region.taken[unit] = 0;
        region.unmark(unit, count);
    }

    /// Whether the run at `unit` becomes `count` units where it is: a shrink always,
    /// handing the end's pages back; a growth when the units after it are free.
    fn run_resize(region: *Region, unit: u32, count: u32) bool {
        const old = region.taken[unit];
        assert(old != slab);
        assert(old > 0);
        assert(count > 0);
        if (count < old) {
            region.unmark(unit + count, old - count);
        } else if (count > old) {
            if (unit + count > region.units()) return false;
            for (unit + old..unit + count) |next| {
                if (region.used.isSet(next)) return false;
            }
            region.mark(unit + old, count - old);
        }
        region.taken[unit] = @intCast(count);
        return true;
    }

    /// Hands out the `count` free units from `unit`.
    fn mark(region: *Region, unit: u32, count: u32) void {
        assert(count > 0);
        assert(unit + count <= region.units());
        region.used.setRangeValue(.{ .start = unit, .end = unit + count }, true);
        region.units_taken += count;
        region.units_peak = @max(region.units_peak, region.units_taken);
    }

    /// Takes back the `count` units from `unit`, and hands their pages to the system.
    fn unmark(region: *Region, unit: u32, count: u32) void {
        assert(count > 0);
        assert(region.units_taken >= count);
        region.used.setRangeValue(.{ .start = unit, .end = unit + count }, false);
        region.units_taken -= count;
        region.give_back(unit, count);
    }

    /// Hands the pages of `count` free units from `unit` back to the system, which
    /// gives them again, zeroed, when next touched: a big picture or a library scan
    /// leaves nothing resident once freed, while the region stays reserved.
    fn give_back(region: *Region, unit: u32, count: u32) void {
        assert(count > 0);
        assert(unit + count <= region.units());
        const start: [*]align(unit_bytes) u8 = @alignCast(region.bytes.ptr + unit * unit_bytes);
        const length = count * unit_bytes;
        const advice = std.posix.MADV.DONTNEED;
        std.posix.madvise(start, length, advice) catch return; // Ignored: only advice
        region.bytes_given_back += length;
    }
};

/// The slot size a heap region keeps `len` bytes at `align_bytes` in: a power of two,
/// so slots of the same size can stand in for each other. `unit_bytes` or more means a
/// run of whole units instead.
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

/// The whole units a run of `len` bytes takes: at least one.
fn units_for(len: u64) u32 {
    assert(len > 0);
    assert(len <= @as(u64, units_max) * unit_bytes); // No region is larger
    const count: u32 = @intCast((len + unit_bytes - 1) / unit_bytes);
    assert(count >= 1);
    return count;
}

pub const Budget = struct {
    name: []const u8,
    region: ?*Region = null, // Where its memory comes from: reserved at startup
    child: ?Allocator = null, // Or, before `seal` only (tests, tools), the system
    limit: u64, // Bytes
    /// Bytes this budget holds of its region: handed out and not yet taken back. A bump
    /// region takes back only its last block, so what's freed before it stays held.
    live: u64 = 0,
    peak: u64 = 0, // The most bytes live at once
    /// Of `live`, bytes freed but held, as a bump region holds them till a rewind or reset.
    stranded: u64 = 0,
    allocations: u64 = 0,
    refused: u64 = 0, // Requests turned down for going over the limit, or a full region

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// `count` items of `T` kept for good, their contents meaning nothing until written:
    /// buffers taken at startup. `Allocator.alloc` fills a new block with 0xaa in safe
    /// builds, which makes every page of it resident at once; these come straight from
    /// the region instead, so their pages become memory only as they're written.
    pub fn untouched(budget: *Budget, comptime T: type, count: u32) ![]T {
        assert(count > 0);
        assert(budget.live <= budget.limit);
        const bytes: usize = @as(usize, @sizeOf(T)) * count; // usize: Allocator's interface
        const raw = budget.allocator().rawAlloc(bytes, .of(T), @returnAddress()) orelse
            return error.OutOfMemory;
        const items: [*]T = @ptrCast(@alignCast(raw));
        return items[0..count];
    }

    /// One `T` kept for good, as `untouched`.
    pub fn untouched_one(budget: *Budget, comptime T: type) !*T {
        const one = try budget.untouched(T, 1);
        assert(one.len == 1);
        return &one[0];
    }

    pub fn allocator(budget: *Budget) Allocator {
        assert(budget.name.len > 0); // The log names it
        assert(budget.live <= budget.limit);
        assert((budget.region == null) != (budget.child == null)); // One or the other
        return .{ .ptr = budget, .vtable = &vtable };
    }

    /// One line for the log: "memory book: 3120 KB live (40 KB stranded), 8440 KB peak,
    /// 1520 allocations, region 9216 of 131072 KB used at most".
    pub fn report(budget: *const Budget) void {
        assert(budget.live <= budget.peak);
        assert(budget.peak <= budget.limit);
        assert(budget.stranded <= budget.live);
        const over = if (budget.refused > 0) ", OVER LIMIT" else "";
        // A budget of the system's has no region to say. Room for any two numbers, so
        // the region's part is always said
        const region_format = ", region {d} of {d} KB used at most";
        const most = std.math.maxInt(u64);
        var region_buffer: [std.fmt.count(region_format, .{ most, most })]u8 = undefined;
        const region_part = if (budget.region) |region|
            std.fmt.bufPrint(&region_buffer, region_format, .{
                region.used_peak() / 1024,
                region.bytes.len / 1024,
            }) catch ""
        else
            "";
        // A line of noface's log, which the tests keep quiet
        log.info("memory {s}: {d} KB live ({d} KB stranded), {d} KB peak, {d} allocations{s}{s}", .{
            budget.name,
            budget.live / 1024,
            budget.stranded / 1024,
            budget.peak / 1024,
            budget.allocations,
            over,
            region_part,
        });
    }

    /// Forgets all a budget on a bump region handed out, at once, as an arena is
    /// emptied: nothing it handed out may be used after.
    pub fn reset(budget: *Budget, pages: Region.Pages) void {
        const region = budget.region.?;
        assert(region.kind == .bump);
        assert(budget.live <= budget.limit);
        budget.live = 0;
        budget.stranded = 0;
        region.reset(pages);
        assert(region.empty());
    }

    /// Where a budget on a bump region has got to, for `rewind`.
    pub const Mark = struct { end: u32, live: u64, stranded: u64 };

    pub fn mark(budget: *const Budget) Mark {
        const region = budget.region.?;
        assert(region.kind == .bump);
        assert(budget.live <= region.end); // What's live lies before the end
        return .{ .end = region.end, .live = budget.live, .stranded = budget.stranded };
    }

    /// Forgets what the budget handed out since `at`, as `reset` forgets all of it:
    /// for a loop that needs memory for each turn, on top of what it keeps throughout.
    pub fn rewind(budget: *Budget, at: Mark) void {
        const region = budget.region.?;
        assert(region.kind == .bump);
        assert(at.end <= region.end); // Marked before what's handed out since
        assert(at.live <= budget.live);
        region.end = at.end;
        budget.live = at.live;
        budget.stranded = at.stranded;
    }

    /// The system's allocator, for a budget without a region: never after `seal`. One
    /// asked for after it is a bug, a crash in a debug build and in the tests; elsewhere
    /// it's counted, and named in the log the first time, so the budget can be given a
    /// region (the scenarios fail on that count).
    fn system(budget: *Budget) Allocator {
        assert(budget.region == null);
        assert(budget.child != null); // `allocator` checked it has one or the other
        if (sealed) {
            const crash = builtin.mode == .debug or builtin.is_test;
            if (crash) @panic("memory asked of the system after startup");
            if (late_requests == 0) {
                std.debug.print("memory {s}: asked of the system after startup\n", .{budget.name});
            }
            late_requests += 1;
        }
        return budget.child.?;
    }

    /// Whether `more` bytes fit under the limit, counting a request turned down: one an
    /// `alloc` makes. A block that can't grow in place (`resize`, `remap`) asks
    /// `has_room` alone: its caller moves it instead, through `alloc`, which counts.
    fn fits(budget: *Budget, more: u64) bool {
        if (budget.has_room(more)) return true;
        budget.refuse("over its limit");
        return false;
    }

    fn has_room(budget: *const Budget, more: u64) bool {
        assert(budget.live <= budget.limit);
        assert(more > 0); // Growing by nothing needs no room
        return budget.live + more <= budget.limit;
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

    /// Counts a block that went from `old_len` bytes to `new_len`, of which `taken_back`
    /// the region took back when it shrank.
    fn resized(budget: *Budget, old_len: u64, new_len: u64, taken_back: u64) void {
        assert(old_len <= budget.live);
        if (new_len > old_len) {
            assert(taken_back == 0);
            budget.grew(new_len - old_len);
        } else {
            budget.let_go(old_len - new_len, taken_back);
        }
        assert(new_len <= budget.live);
    }

    /// `freed` bytes this budget handed out are free again, `taken_back` of them taken
    /// back by the region; the rest stay held, stranded.
    fn let_go(budget: *Budget, freed: u64, taken_back: u64) void {
        assert(taken_back <= freed);
        budget.shrank(taken_back);
        budget.stranded += freed - taken_back;
        assert(budget.stranded <= budget.live);
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
        if (new_len > memory.len and !budget.has_room(new_len - memory.len)) return false;
        const taken_back = budget.taken_back_by_resize(memory, new_len);
        const done = if (budget.region) |region|
            region.resize(memory, alignment, new_len)
        else
            budget.system().rawResize(memory, alignment, new_len, return_address);
        if (!done) return false;
        budget.resized(memory.len, new_len, taken_back);
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
        if (new_len > memory.len and !budget.has_room(new_len - memory.len)) return null;
        const taken_back = budget.taken_back_by_resize(memory, new_len);
        const moved = if (budget.region) |region|
            (if (region.resize(memory, alignment, new_len)) memory.ptr else null)
        else
            budget.system().rawRemap(memory, alignment, new_len, return_address);
        const pointer = moved orelse return null;
        budget.resized(memory.len, new_len, taken_back);
        assert(budget.live <= budget.limit);
        return pointer;
    }

    // usize: std.mem.Allocator's interface
    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const budget: *Budget = @ptrCast(@alignCast(context));
        assert(memory.len <= budget.live); // Memory this budget handed out
        assert(budget.allocations > 0);
        const taken_back = if (budget.region) |region|
            region.give(memory, alignment)
        else taken_back: {
            // Handed out before `seal`, so given back to the system even after it
            budget.child.?.rawFree(memory, alignment, return_address);
            break :taken_back memory.len;
        };
        budget.let_go(memory.len, taken_back);
    }

    /// The bytes a region takes back as `memory` shrinks to `new_len`, should it: all
    /// of them, but from a bump region's block before its last, which keeps them.
    fn taken_back_by_resize(budget: *const Budget, memory: []u8, new_len: u64) u64 {
        if (new_len >= memory.len) return 0;
        const region = budget.region orelse return memory.len - new_len;
        return switch (region.kind) {
            .heap => memory.len - new_len,
            .bump => if (region.is_last(memory)) memory.len - new_len else 0,
        };
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
    // Big blocks of every size, freed out of order, leave the region whole again
    const a = b.allocator();
    var blocks: [6][]u8 = undefined;
    for (&blocks, 0..) |*block, i| block.* = try a.alloc(u8, (unit_bytes << @intCast(i % 3)) - 7);
    for ([_]u32{ 3, 0, 5, 1, 4, 2 }) |i| a.free(blocks[i]);
    const slabs = region.units_taken;
    for (region.taken[0..region.units()]) |t| try std.testing.expect(t == 0 or t == slab);
    // All of the region bar its slabs is free again
    try std.testing.expectEqual(slabs, @as(u32, @intCast(region.used.count())));
    const whole = try a.alloc(u8, 2 << 20); // Half the region, in one piece
    a.free(whole);
    try std.testing.expectEqual(slabs, region.units_taken);
}

test "a heap region keeps a big block in whole units, not a power of two" {
    var region = try Region.reserve("test", .heap, 64 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    const a = b.allocator();
    // 40 and 20 MB: a power of two each would take 64 and 32
    const large = try a.alloc(u8, 40 << 20);
    defer a.free(large);
    var medium = try a.alloc(u8, 20 << 20);
    defer a.free(medium);
    try std.testing.expectEqual(@as(u32, 60 << 20), region.units_taken * unit_bytes);
    // A run shrinks where it is, its end free again, and grows back into it
    medium = try a.realloc(medium, 3 << 20);
    try std.testing.expectEqual(@as(u32, 43 << 20), region.units_taken * unit_bytes);
    const at = medium.ptr;
    medium = try a.realloc(medium, (20 << 20) + 1);
    try std.testing.expect(medium.ptr == at);
    try std.testing.expectEqual(@as(u32, (60 << 20) + unit_bytes), region.units_taken * unit_bytes);
    // A slot never becomes a run where it is, nor a run a slot
    const small = try a.alloc(u8, 100);
    try std.testing.expect(!a.resize(small, 200 << 10));
    a.free(small);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 4 << 20)); // Full
}

test "a heap region gives a freed block's pages back, and keeps its slabs" {
    var region = try Region.reserve("test", .heap, 4 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    const a = b.allocator();
    const small = try a.alloc(u8, 100);
    const big = try a.alloc(u8, 1 << 20);
    @memset(big, 0x55); // Touched, so resident
    const big_start: u32 = @intCast(big.ptr - region.bytes.ptr);
    try std.testing.expectEqual(@as(u64, 0), region.bytes_given_back);
    a.free(big);
    try std.testing.expectEqual(@as(u64, 1 << 20), region.bytes_given_back);
    a.free(small); // A slot: its slab stays, for the next small block
    try std.testing.expectEqual(@as(u64, 1 << 20), region.bytes_given_back);
    // Given back, the pages read as zeros. Read through the region, not a new block:
    // the allocator fills a new block with 0xaa in safe builds, hiding the pages.
    if (builtin.os.tag == .linux) {
        try std.testing.expectEqual(@as(u8, 0), region.bytes[big_start + 4096]);
    }
    const again = try a.alloc(u8, 1 << 20);
    defer a.free(again);
    try std.testing.expect(again.len == 1 << 20);
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
    // A loop's memory for each turn, on top of what it keeps throughout
    const kept = try a.alloc(u8, 1000);
    const each_turn = b.mark();
    for (0..10) |_| {
        b.rewind(each_turn);
        _ = try a.alloc(u8, 100_000);
    }
    try std.testing.expectEqual(@as(u64, 1000 + 100_000), b.live);
    try std.testing.expectEqual(@as(u32, 1000 + 100_000), region.end);
    try std.testing.expect(kept.ptr == region.bytes.ptr); // Kept where it was put
    _ = try a.alloc(u8, 1 << 20);
    b.reset(.give_back);
    try std.testing.expectEqual(@as(u32, 0), region.touched);
    try std.testing.expect(region.end_peak >= 1 << 20);
}

test "a second budget on a bump region rewinds to its mark, and its pages go back" {
    var region = try Region.reserve("book", .bump, 4 << 20);
    defer region.release();
    var book = Budget{ .name = "book", .region = &region, .limit = region.bytes.len };
    const kept = try book.allocator().alloc(u8, 1000);
    const end = region.end;
    var viewer = Budget{ .name = "picture", .region = &region, .limit = 2 << 20 };
    const start = viewer.mark();
    _ = try viewer.allocator().alloc(u8, 1 << 20);
    try std.testing.expect(region.touched >= end + (1 << 20));
    viewer.rewind(start);
    region.give_back_past_end();
    try std.testing.expectEqual(end, region.end);
    try std.testing.expect(region.touched < unit_bytes); // Only the book's first page
    try std.testing.expectEqual(@as(u64, 1000), book.live);
    try std.testing.expect(kept.ptr == region.bytes.ptr);
    region.give_back_past_end(); // Nothing more past the end: nothing happens
    try std.testing.expectEqual(end, region.end);
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

test "an untouched block leaves its pages out of memory until written" {
    var region = try Region.reserve("test", .bump, 4 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    const block = try b.untouched(u8, 1 << 20);
    try std.testing.expectEqual(@as(u64, 1 << 20), b.live);
    // Not filled: a fresh region's pages still read as the system gave them
    if (builtin.os.tag == .linux) try std.testing.expectEqual(@as(u8, 0), block[4096]);
    const one = try b.untouched_one(u64);
    one.* = 7;
    try std.testing.expectEqual(@as(u64, 7), one.*);
}

test "a bump region's budget counts what it holds, its freed blocks before the last too" {
    var region = try Region.reserve("test", .bump, 1 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    const a = b.allocator();
    // A list grown between other blocks leaves each copy it moved from behind
    var list: std.ArrayList(u8) = .empty;
    for (0..8) |i| {
        try list.appendNTimes(a, 'x', 1000);
        _ = try a.alloc(u8, 10 + i); // After the list, so its old copy can't come back
    }
    // Live is what the region holds, the copies left behind included: bytes, aligned
    // to a byte, so the region skipped none between them
    try std.testing.expect(b.stranded > 0);
    try std.testing.expectEqual(@as(u64, region.end), b.live);
    try std.testing.expect(b.peak >= b.live);
}

test "freed blocks a bump region holds still count against the budget's limit" {
    var region = try Region.reserve("test", .bump, 1 << 20);
    defer region.release();
    // A limit below the region's size, as the picture viewer's
    var b = Budget{ .name = "test", .region = &region, .limit = 4096 };
    const a = b.allocator();
    const first = try a.alloc(u8, 3000);
    _ = try a.alloc(u8, 16); // After it, so it can't come back
    a.free(first);
    try std.testing.expectEqual(@as(u64, 3000), b.stranded);
    // Held still: what's left under the limit is the limit less all it holds
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 3000));
}

test "a block that can't grow in place, moved instead, isn't counted as refused" {
    var region = try Region.reserve("test", .bump, 1 << 20);
    defer region.release();
    var b = Budget{ .name = "test", .region = &region, .limit = region.bytes.len };
    const a = b.allocator();
    const block = try a.alloc(u8, 100);
    _ = try a.alloc(u8, 16); // After it: it can't grow where it is
    try std.testing.expect(!a.resize(block, 200));
    const moved = try a.realloc(block, 200);
    try std.testing.expectEqual(@as(usize, 200), moved.len);
    try std.testing.expectEqual(@as(u64, 0), b.refused);
}
