//! The library's covers, decoded and scaled once and kept in a pool of fixed size: a
//! cover not seen for a while gives its slot to the next, and is decoded again (about
//! 10 ms) if it comes back. However many books the library has, and however far it's
//! paged through, every book shows its own cover, in the same memory.
const std = @import("std");
const assert = std.debug.assert;
const image = @import("../gfx/image.zig");
const memory = @import("../base/memory.zig");

/// Covers of the grid kept at once: the page shown and those either side (twelve each
/// at most) are ready together, and as many again stay for paging back and forth.
pub const grid_slots: u32 = 64;
/// Covers of the hero's size: the book to continue, and the few it was before.
pub const hero_slots: u32 = 4;

/// What the pool takes, in the library's region.
pub const bytes: u64 = grid_slots * grid_cover_bytes + hero_slots * hero_cover_bytes;
const grid_cover_bytes: u32 = image.width * image.height;
const hero_cover_bytes: u32 = image.hero_width * image.hero_height;

comptime {
    // The page shown and both sides fit, with room to spare
    assert(grid_slots >= 3 * 12 + 12);
    assert(hero_slots >= 1);
    assert(bytes <= 8 << 20);
}

pub const Pool = struct {
    grid: Shelf(grid_slots, image.width, image.height),
    hero: Shelf(hero_slots, image.hero_width, image.hero_height),

    /// A pool whose pixels come from `budget`, kept for good, and memory only once a
    /// cover is drawn into them.
    pub fn init(pool: *Pool, budget: *memory.Budget) !void {
        pool.grid = .{ .pixels = try budget.untouched_one(@TypeOf(pool.grid).Pixels) };
        pool.hero = .{ .pixels = try budget.untouched_one(@TypeOf(pool.hero).Pixels) };
        assert(pool.grid.hand == 0);
        assert(pool.hero.hand == 0);
    }

    /// Forgets every cover, for a library whose covers may have changed under the same
    /// names (a new scenario in the tests).
    pub fn clear(pool: *Pool) void {
        pool.grid.clear();
        pool.hero.clear();
        assert(pool.grid.keys[0] == null);
        assert(pool.hero.keys[0] == null);
    }

    /// The grid-sized cover of the picture at `path`, or null for none (no path, or a
    /// picture that won't decode, which isn't tried again while it's kept).
    pub fn grid_cover(pool: *Pool, path: ?[:0]const u8) ?[]const u8 {
        const cover = pool.grid.get(path) orelse return null;
        assert(cover.len == grid_cover_bytes);
        return cover;
    }

    /// The hero-sized cover of the picture at `path`, as `grid_cover`.
    pub fn hero_cover(pool: *Pool, path: ?[:0]const u8) ?[]const u8 {
        const cover = pool.hero.get(path) orelse return null;
        assert(cover.len == hero_cover_bytes);
        return cover;
    }
};

/// `slots` covers of `width` x `height`, each found by its picture's path, given back
/// by CLOCK: the hand passes over slots used since it last came round (clearing that),
/// and takes the first that wasn't.
fn Shelf(comptime slots: u32, comptime width: u32, comptime height: u32) type {
    comptime assert(slots > 0);
    comptime assert(width * height > 0);
    return struct {
        const S = @This();
        const Pixels = [slots][width * height]u8;

        pixels: *Pixels,
        keys: [slots]?u64 = @splat(null), // Null: no cover in it
        decoded: [slots]bool = @splat(false), // False: tried, and no picture
        used: [slots]bool = @splat(false),
        hand: u32 = 0,

        fn clear(s: *S) void {
            assert(s.hand < slots);
            s.keys = @splat(null);
            s.used = @splat(false);
            s.hand = 0;
        }

        /// The cover of the picture at `path`, or null for none: no path (a book without
        /// a thumbnail), or a picture that doesn't decode.
        fn get(s: *S, path: ?[:0]const u8) ?[]const u8 {
            assert(s.hand < slots);
            const p = path orelse return null;
            const key = key_of(p);
            const slot = for (s.keys, 0..) |k, i| {
                if (k == key) break @as(u32, @intCast(i));
            } else s.fill(key, p);
            assert(s.keys[slot] == key);
            s.used[slot] = true;
            return if (s.decoded[slot]) &s.pixels[slot] else null;
        }

        /// Decodes the picture at `path` into the slot the hand gives, and returns it.
        fn fill(s: *S, key: u64, path: [:0]const u8) u32 {
            assert(path.len > 0);
            // Twice round at most: the first pass clears every slot's use
            const slot = for (0..2 * slots) |_| {
                const at = s.hand;
                s.hand = (s.hand + 1) % slots;
                if (!s.used[at]) break at;
                s.used[at] = false;
            } else unreachable;
            assert(slot < slots);
            s.keys[slot] = key;
            s.decoded[slot] = image.load_into(&s.pixels[slot], path, width, height);
            return slot;
        }
    };
}

/// A picture's path as a number: two different paths giving one is about 2^-64.
fn key_of(path: []const u8) u64 {
    assert(path.len > 0);
    return std.hash.Wyhash.hash(0x6e6f66616365, path);
}

test "the pool keeps every cover it can and gives back the least lately used" {
    const alloc = std.testing.allocator;
    var budget = memory.Budget{ .name = "covers", .child = alloc, .limit = 64 << 20 };
    var pool: Pool = undefined;
    try pool.init(&budget);
    defer budget.allocator().destroy(pool.grid.pixels);
    defer budget.allocator().destroy(pool.hero.pixels);
    var names: [grid_slots + 8][32]u8 = undefined;
    var paths: [grid_slots + 8][:0]const u8 = undefined;
    for (&names, &paths, 0..) |*name, *path, i| {
        path.* = try std.fmt.bufPrintSentinel(name, "/no/such/cover-{d}", .{i}, 0);
    }
    // Pictures that don't decode are kept as "none", so they aren't tried again
    for (paths[0..grid_slots]) |path| try std.testing.expect(pool.grid_cover(path) == null);
    for (paths[0..grid_slots]) |path| {
        const key = key_of(path);
        try std.testing.expect(std.mem.indexOfScalar(?u64, &pool.grid.keys, key) != null);
    }
    // More than fit: older ones give way, and every new one has a slot
    for (paths[grid_slots..]) |path| _ = pool.grid_cover(path);
    for (paths[grid_slots..]) |path| {
        const key = key_of(path);
        try std.testing.expect(std.mem.indexOfScalar(?u64, &pool.grid.keys, key) != null);
    }
    try std.testing.expect(pool.grid_cover(null) == null); // No picture, no cover
    pool.clear();
    try std.testing.expect(std.mem.indexOfScalar(?u64, &pool.grid.keys, key_of(paths[0])) == null);
}
