//! The glyphs fonts have drawn, kept in memory fixed at startup, the least used given
//! up for new ones. Every font shares one cache of two parts.
//!
//! A table of glyphs: which glyph a character is in a font, how far it moves the pen,
//! and where its bitmap is. It's set-associative, as TigerBeetle's cache is: a key
//! picks a set of `ways` places, and a CLOCK hand in each set gives up the glyph used
//! least lately when a new one needs its place.
//!
//! A log of bitmaps, in segments of 64 KB: each bitmap is written after the last, in
//! the segment being filled, whatever its size, so no memory waits for glyphs of one
//! size while glyphs of another go wanting. When that segment is full, the oldest is
//! emptied for it: the glyphs drawn since it was last emptied move on to a spare
//! segment, the rest are given up, and the spare becomes the one being filled. That
//! is CLOCK again, a glyph drawn lately getting a second chance.
//!
//! What's drawn never depends on what fits: a glyph given up is drawn again when next
//! shown, and one too large for a segment is drawn each time it shows. The rasterizer
//! works in a scratch region emptied before each glyph, so nothing it needs is freed in
//! any other order; a glyph that needs more than the scratch has (only a damaged or
//! hostile font's: a real one needs a few hundred KB at most) draws nothing.
const std = @import("std");
const assert = std.debug.assert;
const memory = @import("../base/memory.zig");
const truetype = @import("truetype.zig");

/// Places in a set: a key is looked for in these, and only these.
pub const ways: u32 = 16;
/// How many times a glyph's use is counted before the set's hand passes it by.
const uses_max = 3;
/// A segment of the log, and the header before each bitmap in it: the glyph's place in
/// the table, plus one, and the bitmap's length.
pub const segment_bytes: u32 = 64 << 10;
const record_header_bytes: u32 = 8;
/// The largest bitmap kept: one more is drawn each time it shows.
pub const bitmap_bytes_max = segment_bytes - record_header_bytes;
const code_point_max = 0x10ffff;

comptime {
    assert(std.math.isPowerOfTwo(ways));
    // Two bits of a byte count a glyph's uses
    assert(uses_max < 4);
    // A key puts the font above the character, which takes 21 bits
    assert(code_point_max < 1 << 21);
    // Records start 4-aligned, so their headers' numbers can be read in place
    assert(record_header_bytes % 4 == 0);
    assert(segment_bytes % 4 == 0);
}

/// How large a cache is: how many glyphs its table holds, and how many segments its
/// log has.
pub const Config = struct {
    entries: u32,
    segments: u32,

    /// What noface keeps: 16384 glyphs, and 16 MB of bitmaps: a CJK book's characters
    /// at the middle sizes (2 KB each at 46 px), or 3000 at the largest.
    pub const default: Config = .{ .entries = 16384, .segments = 256 };

    /// The bytes a cache of this size takes from its region, alignment included.
    pub fn bytes(config: Config) u32 {
        assert(config.entries % ways == 0);
        // One being filled, a spare, and one to empty
        assert(config.segments >= 3);
        var total: u32 = config.entries * (@sizeOf(u64) + @sizeOf(Entry));
        total += config.entries / ways; // A hand per set
        total += config.segments * (segment_bytes + @sizeOf(u32));
        // Each of the five blocks may start up to 8 bytes on, for its alignment
        return total + 5 * 8;
    }
};

comptime {
    assert(Config.default.bytes() < 20 << 20);
    // A set's places are within its table
    assert(Config.default.entries / ways > 0);
    assert(std.math.isPowerOfTwo(Config.default.entries / ways));
}

/// What a glyph's bitmap is, as far as the cache knows.
const State = union(enum) {
    /// Not drawn yet, or its bitmap given up: drawn when next shown.
    measured,
    /// Draws nothing: no pixels, or more than the scratch could hold.
    blank,
    /// Its bitmap is in the log, starting here.
    kept: u32,
    /// Too large for a segment: drawn from the scratch each time.
    too_large,
};

const Entry = struct {
    index: u32,
    advance: f32,
    width: i32 = 0,
    height: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    state: State = .measured,
    uses: u8 = 0,
    drawn_lately: bool = false,
};

/// A font as the cache knows it: an id no other font shares, and what draws it.
pub const FontRef = struct {
    id: u32,
    info: *const truetype.Info,
    scale: f32,
};

/// What measuring a character needs: its glyph, and how far it moves the pen.
pub const Metrics = struct { index: u32, advance: f32 };

/// A glyph ready to draw: `pixels` (null for none) are good until the cache is next
/// used, so a caller draws them straight away.
pub const Drawn = struct {
    index: u32,
    advance: f32,
    width: i32,
    height: i32,
    x_offset: i32,
    y_offset: i32,
    pixels: ?[]const u8,
};

pub const Cache = struct {
    keys: []u64, // 0 for an empty place
    entries: []Entry,
    hands: []u8, // Per set, the place its hand is at
    log: []u8, // The segments, one after another: memory only as glyphs are written
    used: []u32, // Per segment, the bytes written in it
    filling: u32 = 0, // The segment bitmaps are written to
    spare: u32 = 1, // Empty, for the glyphs kept when a segment is emptied
    oldest: u32 = 2, // The next segment to empty
    scratch: *memory.Budget, // On a bump region, emptied before each glyph is drawn
    // Counted for the log and the tests
    misses: u64 = 0,
    rasterized: u64 = 0,
    bitmaps_given_up: u64 = 0,

    /// A cache of `config`'s size, its table and log taken from `store_budget` once, now.
    pub fn init(
        cache: *Cache,
        config: Config,
        store_budget: *memory.Budget,
        scratch: *memory.Budget,
    ) !void {
        assert(config.segments >= 3);
        assert(scratch.region.?.kind == .bump);
        const store = store_budget.allocator();
        cache.* = .{
            .keys = try store.alloc(u64, config.entries),
            .entries = try store.alloc(Entry, config.entries),
            .hands = try store.alloc(u8, config.entries / ways),
            .log = try store_budget.untouched(u8, config.segments * segment_bytes),
            .used = try store.alloc(u32, config.segments),
            .scratch = scratch,
        };
        @memset(cache.keys, 0);
        @memset(cache.hands, 0);
        @memset(cache.used, 0);
        assert(cache.sets() > 0);
        assert(std.math.isPowerOfTwo(cache.sets()));
    }

    fn sets(cache: *const Cache) u32 {
        assert(cache.keys.len == cache.entries.len);
        assert(cache.keys.len % ways == 0);
        return @intCast(cache.keys.len / ways);
    }

    fn segments(cache: *const Cache) u32 {
        assert(cache.used.len >= 3);
        assert(cache.log.len == cache.used.len * segment_bytes);
        return @intCast(cache.used.len);
    }

    /// Which glyph a character is in a font, and its advance at the font's scale.
    pub fn metrics(cache: *Cache, font: FontRef, code_point: u32) Metrics {
        const at = cache.find_or_add(font, code_point);
        const entry = &cache.entries[at];
        assert(cache.keys[at] == key_of(font, code_point));
        assert(std.math.isFinite(entry.advance));
        return .{ .index = entry.index, .advance = entry.advance };
    }

    /// A character's glyph with its bitmap, drawn now if it isn't kept.
    pub fn drawn(cache: *Cache, font: FontRef, code_point: u32) Drawn {
        const at = cache.find_or_add(font, code_point);
        const entry = &cache.entries[at];
        var pixels: ?[]const u8 = null;
        switch (entry.state) {
            .kept => pixels = cache.kept_pixels(entry),
            .blank => {},
            .measured => pixels = cache.draw_new(font, at),
            .too_large => pixels = cache.draw_again(font, entry),
        }
        entry.drawn_lately = true;
        if (pixels) |p| {
            assert(p.len == @as(u64, @intCast(entry.width)) * @as(u64, @intCast(entry.height)));
        } else {
            assert(entry.state == .blank);
        }
        return .{
            .index = entry.index,
            .advance = entry.advance,
            .width = entry.width,
            .height = entry.height,
            .x_offset = entry.x_offset,
            .y_offset = entry.y_offset,
            .pixels = pixels,
        };
    }

    /// The place of a character's glyph in the table: found, or made there now,
    /// giving up the glyph its set's hand points at.
    fn find_or_add(cache: *Cache, font: FontRef, code_point: u32) u32 {
        // Code points come from decoding UTF-8, which yields only these
        assert(code_point <= code_point_max);
        assert(font.id > 0);
        const key = key_of(font, code_point);
        const set = set_of(key, cache.sets());
        const first = set * ways;
        for (cache.keys[first..][0..ways], first..) |k, at| {
            if (k == key) {
                const entry = &cache.entries[at];
                entry.uses = @min(entry.uses + 1, uses_max);
                return @intCast(at);
            }
        }
        cache.misses += 1;
        const at = cache.give_up_in_set(set);
        const index = truetype.glyph_index(font.info, code_point);
        const advance = truetype.horizontal_metrics(font.info, index).advance;
        cache.keys[at] = key;
        // Its bitmap, if the place's last glyph had one kept, is left in the log for
        // nothing: no glyph owns it now, so emptying its segment skips it
        cache.entries[at] = .{
            .index = index,
            .advance = @as(f32, @floatFromInt(advance)) * font.scale,
        };
        assert(cache.entries[at].state == .measured);
        return at;
    }

    /// An empty place in `set`, or one whose glyph was used least lately, given up.
    fn give_up_in_set(cache: *Cache, set: u32) u32 {
        assert(set < cache.sets());
        const first = set * ways;
        const hand = &cache.hands[set];
        // Each turn passes a place, lowering its count of uses: by the time the hand
        // has gone round as many times as a glyph can count, one is at none
        for (0..ways * (uses_max + 1) + 1) |_| {
            const at = first + hand.*;
            hand.* = @intCast((hand.* + 1) % ways);
            if (cache.keys[at] == 0) return at;
            const entry = &cache.entries[at];
            if (entry.uses > 0) {
                entry.uses -= 1;
                continue;
            }
            cache.keys[at] = 0;
            return at;
        }
        unreachable; // Every use counted was taken back above
    }

    /// Draws a glyph not drawn before (or given up since), and keeps its bitmap in the
    /// log when it fits in a segment.
    fn draw_new(cache: *Cache, font: FontRef, at: u32) ?[]const u8 {
        const entry = &cache.entries[at];
        assert(entry.state == .measured);
        const bitmap = cache.rasterize(font, entry);
        entry.width = bitmap.width;
        entry.height = bitmap.height;
        entry.x_offset = bitmap.x_offset;
        entry.y_offset = bitmap.y_offset;
        const pixels = bitmap.pixels orelse {
            entry.state = .blank;
            return null;
        };
        if (pixels.len > bitmap_bytes_max) {
            entry.state = .too_large;
            return pixels;
        }
        const kept = cache.keep(at, @intCast(pixels.len));
        @memcpy(kept, pixels);
        assert(entry.state == .kept);
        assert(kept.len == pixels.len);
        return kept;
    }

    /// Draws a glyph too large for a segment again, into the scratch.
    fn draw_again(cache: *Cache, font: FontRef, entry: *Entry) ?[]const u8 {
        assert(entry.state == .too_large);
        const bitmap = cache.rasterize(font, entry);
        // The same glyph in the same scratch draws the same, in the same box
        assert(bitmap.width == entry.width);
        assert(bitmap.height == entry.height);
        if (bitmap.pixels == null) entry.state = .blank;
        return bitmap.pixels;
    }

    /// Draws a glyph into the scratch, emptied first. A glyph that needs more than the
    /// scratch has is a box with no pixels.
    fn rasterize(cache: *Cache, font: FontRef, entry: *const Entry) truetype.Bitmap {
        assert(entry.state == .measured or entry.state == .too_large);
        cache.scratch.reset(.keep);
        cache.rasterized += 1;
        const scratch = cache.scratch.allocator();
        const bitmap = truetype.glyph_bitmap(font.info, scratch, font.scale, entry.index) catch
            truetype.glyph_bitmap_box(font.info, font.scale, entry.index);
        if (bitmap.pixels) |p| {
            assert(p.len == @as(u64, @intCast(bitmap.width)) * @as(u64, @intCast(bitmap.height)));
        }
        return bitmap;
    }

    /// Room for glyph `at`'s bitmap of `len` bytes at the end of the log, emptying the
    /// oldest segments for it as needed; the glyph is kept there from now on.
    fn keep(cache: *Cache, at: u32, len: u32) []u8 {
        assert(len > 0);
        assert(len <= bitmap_bytes_max);
        const size = record_size(len);
        // Each segment emptied clears the marks of the glyphs it moves, so by the time
        // every segment has been emptied twice, the one being filled has room
        for (0..2 * cache.segments() + 1) |_| {
            if (cache.used[cache.filling] + size <= segment_bytes) break;
            cache.empty_oldest();
        } else unreachable; // Two rounds of emptying make room, as above
        const cell = cache.write(cache.filling, at, len);
        cache.entries[at].state = .{ .kept = cell };
        return cache.log[cell..][0..len];
    }

    /// Writes a record for glyph `at`'s bitmap of `len` bytes at the end of `segment`.
    /// Returns where its bitmap goes, for the caller to fill.
    fn write(cache: *Cache, segment: u32, at: u32, len: u32) u32 {
        const start = segment * segment_bytes + cache.used[segment];
        assert(cache.used[segment] + record_size(len) <= segment_bytes);
        assert(at < cache.entries.len);
        std.mem.writeInt(u32, cache.log[start..][0..4], at + 1, .little);
        std.mem.writeInt(u32, cache.log[start + 4 ..][0..4], len, .little);
        cache.used[segment] += record_size(len);
        return start + record_header_bytes;
    }

    /// Empties the oldest segment: the glyphs in it drawn since it was last emptied
    /// move to the spare one, the rest are given up. The spare becomes the one being
    /// filled, and the emptied one the spare.
    fn empty_oldest(cache: *Cache) void {
        const source = cache.oldest;
        const target = cache.spare;
        assert(cache.used[target] == 0);
        assert(source != cache.filling);
        const source_start = source * segment_bytes;
        var offset: u32 = 0;
        // Each turn passes one record, of at least a header's bytes
        for (0..segment_bytes / record_header_bytes) |_| {
            if (offset >= cache.used[source]) break;
            const record = cache.log[source_start + offset ..];
            const owner = std.mem.readInt(u32, record[0..4], .little);
            const len = std.mem.readInt(u32, record[4..8], .little);
            const cell = source_start + offset + record_header_bytes;
            offset += record_size(len);
            assert(owner > 0);
            const entry = &cache.entries[owner - 1];
            // A record its glyph no longer points at is one given up already
            const kept_at = switch (entry.state) {
                .kept => |at| at,
                .measured, .blank, .too_large => continue,
            };
            if (kept_at != cell) continue;
            if (entry.drawn_lately) {
                entry.drawn_lately = false;
                const moved = cache.write(target, owner - 1, len);
                @memcpy(cache.log[moved..][0..len], cache.log[cell..][0..len]);
                entry.state = .{ .kept = moved };
            } else {
                entry.state = .measured;
                cache.bitmaps_given_up += 1;
            }
        }
        assert(offset == cache.used[source]);
        cache.used[source] = 0;
        cache.spare = source;
        cache.filling = target;
        cache.oldest = cache.next_to_empty(source);
    }

    /// The segment emptied after `segment`: the next in turn, past the one being filled
    /// and the spare.
    fn next_to_empty(cache: *const Cache, segment: u32) u32 {
        var next = segment;
        for (0..3) |_| {
            next = (next + 1) % cache.segments();
            if (next != cache.filling and next != cache.spare) break;
        }
        assert(next != cache.filling);
        assert(next != cache.spare);
        return next;
    }

    fn kept_pixels(cache: *const Cache, entry: *const Entry) []const u8 {
        const cell = entry.state.kept;
        const len: u32 = @intCast(entry.width * entry.height);
        assert(len <= bitmap_bytes_max);
        assert(cell + len <= cache.log.len);
        return cache.log[cell..][0..len];
    }
};

/// The bytes a record for a bitmap of `len` bytes takes: its header, the bitmap, and
/// what brings the next to a multiple of 4.
fn record_size(len: u32) u32 {
    assert(len > 0);
    assert(len <= bitmap_bytes_max);
    const size = std.mem.alignForward(u32, record_header_bytes + len, 4);
    assert(size <= segment_bytes);
    return size;
}

/// A glyph's key: its font above its character, never 0.
fn key_of(font: FontRef, code_point: u32) u64 {
    assert(font.id > 0);
    assert(code_point <= code_point_max);
    return (@as(u64, font.id) << 32) | code_point;
}

/// The set a key's glyph is kept in: its bits mixed, so a font's characters in a row
/// spread over every set.
fn set_of(key: u64, sets_count: u32) u32 {
    assert(key != 0);
    assert(std.math.isPowerOfTwo(sets_count));
    const mixed = key *% 0x9e3779b97f4a7c15;
    return @intCast((mixed >> 32) & (sets_count - 1));
}

/// Fonts made so far: each new one takes the next id, so no two share their glyphs.
var fonts_made: u32 = 0;

/// An id for a new font, for its glyphs' keys.
pub fn new_font_id() u32 {
    assert(fonts_made < std.math.maxInt(u32));
    fonts_made += 1;
    assert(fonts_made > 0); // 0 is no font
    return fonts_made;
}

/// Scratch for drawing a glyph: the most a real font's glyph was measured to take at
/// the largest size, outline and bitmap, is 39 KB (of 80000 CJK and Latin ones): a
/// megabyte is room for any real glyph many times over.
pub const scratch_bytes: u32 = 1 << 20;

comptime {
    // The largest bitmap kept, and the outline it's drawn from, fit with room to spare
    assert(scratch_bytes >= 16 * segment_bytes);
    assert(scratch_bytes % memory.unit_bytes == 0);
}

/// A cache in two regions of its own, reserved once: one for its table and log, one
/// for the scratch.
pub const Reserved = struct {
    regions: [2]memory.Region,
    budgets: [2]memory.Budget,
    cache: Cache,

    /// Reserves the regions, `store_bytes` and `scratch_size` long, and makes a cache
    /// of `config`'s size in them. Only during startup: `reserve` asks the system.
    pub fn reserve(
        reserved: *Reserved,
        config: Config,
        store_bytes: u32,
        scratch_size: u32,
    ) !void {
        assert(store_bytes >= config.bytes());
        assert(scratch_size > 0);
        reserved.regions[0] = try .reserve("glyphs", .bump, store_bytes);
        reserved.regions[1] = try .reserve("glyph scratch", .bump, scratch_size);
        const names = [_][]const u8{ "glyphs", "glyph scratch" };
        for (&reserved.budgets, &reserved.regions, names) |*budget, *region, name| {
            budget.* = .{ .name = name, .region = region, .limit = region.bytes.len };
        }
        try reserved.cache.init(config, &reserved.budgets[0], &reserved.budgets[1]);
        assert(reserved.budgets[0].live <= store_bytes);
    }
};

/// The cache fonts draw through: the one given to `use`, or, for code that never
/// chose one (the development tools, tests), one reserved the first time it's needed.
var current: ?*Cache = null;
var built_in: Reserved = undefined;

/// Sends every font's glyphs to `cache` from now on.
pub fn use(cache: *Cache) void {
    assert(cache.keys.len > 0);
    assert(cache.scratch.limit > 0);
    current = cache;
}

/// The cache in use.
pub fn get() !*Cache {
    if (current) |cache| return cache;
    // Startup gives the app's cache before anything is drawn, so the built-in one is
    // never asked of the system after it
    assert(!memory.sealed);
    const store_bytes = std.mem.alignForward(u32, Config.default.bytes(), memory.unit_bytes);
    try built_in.reserve(.default, store_bytes, scratch_bytes);
    current = &built_in.cache;
    assert(built_in.cache.keys.len == Config.default.entries);
    return &built_in.cache;
}

/// A cache of `config`'s size in regions of its own, for a test; `test_release`
/// gives them back.
fn test_reserve(reserved: *Reserved, config: Config, scratch_size: u32) !void {
    assert(scratch_size % memory.unit_bytes == 0);
    assert(config.segments >= 3);
    const store_bytes = std.mem.alignForward(u32, config.bytes(), memory.unit_bytes);
    try reserved.reserve(config, store_bytes, scratch_size);
}

fn test_release(reserved: *Reserved) void {
    assert(reserved.regions[0].bytes.len > 0);
    assert(reserved.regions[1].bytes.len > 0);
    for (&reserved.regions) |*region| region.release();
}

/// Every character `info` has a glyph for, below U+3000, into `out`; how many.
fn test_code_points(info: *const truetype.Info, out: []u32) u32 {
    assert(out.len > 0);
    var count: u32 = 0;
    for (0..0x3000) |code_point| {
        if (count == out.len) break;
        if (truetype.glyph_index(info, @intCast(code_point)) == 0) continue;
        out[count] = @intCast(code_point);
        count += 1;
    }
    assert(count <= out.len);
    return count;
}

/// Checks that what the cache hands over for a character is what the rasterizer
/// draws for it, pixel for pixel.
fn test_expect_drawn(cache: *Cache, font: FontRef, code_point: u32) !void {
    assert(font.id > 0);
    assert(code_point <= code_point_max);
    const got = cache.drawn(font, code_point);
    const alloc = std.testing.allocator;
    const index = truetype.glyph_index(font.info, code_point);
    const want = try truetype.glyph_bitmap(font.info, alloc, font.scale, index);
    defer if (want.pixels) |pixels| alloc.free(pixels);
    try std.testing.expectEqual(index, got.index);
    try std.testing.expectEqual(want.width, got.width);
    try std.testing.expectEqual(want.height, got.height);
    try std.testing.expectEqual(want.x_offset, got.x_offset);
    try std.testing.expectEqual(want.y_offset, got.y_offset);
    try std.testing.expectEqual(want.pixels == null, got.pixels == null);
    if (want.pixels) |pixels| try std.testing.expectEqualSlices(u8, pixels, got.pixels.?);
}

test "a cache far smaller than the glyphs drawn gives up the least used, drawing all right" {
    var reserved: Reserved = undefined;
    try test_reserve(&reserved, .{ .entries = 64, .segments = 3 }, scratch_bytes);
    defer test_release(&reserved);
    const cache = &reserved.cache;
    const store_used = reserved.regions[0].end;
    const info = truetype.init(@embedFile("../testdata/fonts/Go-Regular.ttf")).?;
    var code_points: [1024]u32 = undefined;
    const count = test_code_points(&info, &code_points);
    try std.testing.expect(count > 500);
    const sizes = [_]f32{ 26, 46, 115.5 };
    var fonts: [sizes.len]FontRef = undefined;
    for (&fonts, sizes) |*font, px| {
        const scale = truetype.scale_for_pixel_height(&info, px);
        font.* = .{ .id = new_font_id(), .info = &info, .scale = scale };
    }
    // A few characters drawn over and over, among all the others in turn: the few
    // stay kept, while the others come and go
    var prng = std.Random.DefaultPrng.init(0x61f4);
    const random = prng.random();
    for (0..3 * count) |turn| {
        const font = fonts[turn % fonts.len];
        const often = [_]u32{ 'e', 't', 'a' };
        try test_expect_drawn(cache, font, often[turn % often.len]);
        try test_expect_drawn(cache, font, code_points[random.uintLessThan(u32, count)]);
    }
    try std.testing.expect(cache.bitmaps_given_up > 100);
    try std.testing.expect(cache.misses > count);
    // Nothing more was taken for any of it
    try std.testing.expectEqual(store_used, reserved.regions[0].end);
    try std.testing.expect(reserved.regions[1].end_peak <= scratch_bytes);
}

test "thousands of characters at the largest size stay within the cache's fixed memory" {
    var reserved: Reserved = undefined;
    try test_reserve(&reserved, .default, scratch_bytes);
    defer test_release(&reserved);
    const cache = &reserved.cache;
    const store_used = reserved.regions[0].end;
    const files = [_][]const u8{
        @embedFile("../testdata/fonts/Go-Regular.ttf"),
        @embedFile("../testdata/fonts/Go-Bold.ttf"),
        @embedFile("../testdata/fonts/GoCubic.otf"),
    };
    var infos: [files.len]truetype.Info = undefined;
    for (&infos, files) |*info, data| info.* = truetype.init(data).?;
    var code_points: [1024]u32 = undefined;
    var drawn_count: u32 = 0;
    // The largest reader size at the largest book size and the sizes under it, as a
    // CJK book's thousands of characters would be drawn, then the largest again
    for ([_]f32{ 66 * 1.75, 110, 105, 100, 95, 90, 66 * 1.75 }) |px| {
        for (&infos) |*info| {
            const count = test_code_points(info, &code_points);
            const scale = truetype.scale_for_pixel_height(info, px);
            const font: FontRef = .{ .id = new_font_id(), .info = info, .scale = scale };
            for (code_points[0..count], 0..) |code_point, i| {
                // Every glyph drawn; one in seven held to the rasterizer's own
                if (i % 7 == 0) {
                    try test_expect_drawn(cache, font, code_point);
                } else {
                    _ = cache.drawn(font, code_point);
                }
                drawn_count += 1;
            }
        }
    }
    try std.testing.expect(drawn_count > 9000);
    // More than fits: some were given up, and the memory stayed what it was
    try std.testing.expect(cache.bitmaps_given_up > 0);
    try std.testing.expectEqual(store_used, reserved.regions[0].end);
    try std.testing.expect(store_used <= Config.default.bytes());
    try std.testing.expect(reserved.regions[1].end_peak <= 64 << 10);
}

test "a glyph too large to keep is drawn each time; one too large to draw draws nothing" {
    var reserved: Reserved = undefined;
    try test_reserve(&reserved, .{ .entries = 64, .segments = 3 }, scratch_bytes);
    defer test_release(&reserved);
    const cache = &reserved.cache;
    const info = truetype.init(@embedFile("../testdata/fonts/Go-Regular.ttf")).?;
    // 'W' at 400 px is over 64 KB, past a segment, within the scratch
    const large: FontRef = .{
        .id = new_font_id(),
        .info = &info,
        .scale = truetype.scale_for_pixel_height(&info, 400),
    };
    const before = cache.rasterized;
    for (0..3) |_| try test_expect_drawn(cache, large, 'W');
    try std.testing.expectEqual(before + 3, cache.rasterized);
    // At 4000 px its bitmap alone is past the scratch: a hostile font's glyph, as
    // far as the cache can tell, drawn as nothing, and not tried again
    const huge: FontRef = .{
        .id = new_font_id(),
        .info = &info,
        .scale = truetype.scale_for_pixel_height(&info, 4000),
    };
    for (0..3) |_| {
        const drawn_huge = cache.drawn(huge, 'W');
        try std.testing.expect(drawn_huge.pixels == null);
        try std.testing.expect(drawn_huge.width > 1000);
    }
    try std.testing.expectEqual(before + 4, cache.rasterized);
    // And the glyphs drawn after it are right
    try test_expect_drawn(cache, large, 'W');
}
