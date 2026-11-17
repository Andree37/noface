//! TrueType and OpenType fonts: their tables, which glyph a character is, how wide it
//! is, how far apart two glyphs sit, and the glyph's outline (TrueType's quadratic
//! curves, or CFF's cubic ones) drawn into a bitmap.
//!
//! A port of the parts of stb_truetype noface used, so that text sets and looks
//! exactly as it did. Every read of the font stays inside the file: a damaged font
//! gives zeros, missing glyphs and blank bitmaps, never a crash.
const std = @import("std");
const assert = std.debug.assert;
const cff = @import("cff.zig");
const raster = @import("raster.zig");
const Vertex = @import("outline.zig").Vertex;

pub const Error = error{OutOfMemory};

/// A composite glyph may be made of composite glyphs this deep, and no deeper: real
/// fonts nest one or two; a font that loops is damaged.
const composite_depth_max = 8;
/// The most points a simple glyph can have: its last point's number is 16 bits.
const glyph_points_max = 1 << 16;
/// A bitmap wider or taller than this is a damaged glyph, drawn as nothing.
const bitmap_side_max = 1 << 14;

comptime {
    assert(composite_depth_max >= 2);
    assert(glyph_points_max == 65536);
}

// Reading big-endian numbers anywhere in the font, as zeros outside it.

/// Offsets are worked out in 64 bits, so no sum of a font's 32-bit offsets wraps.
fn byte_at(data: []const u8, at: i64) u8 {
    assert(data.len <= std.math.maxInt(u32));
    if (at < 0 or at >= data.len) return 0;
    return data[@intCast(at)];
}

fn ushort(data: []const u8, at: i64) u16 {
    assert(data.len <= std.math.maxInt(u32));
    if (at < 0 or at + 2 > data.len) return 0;
    return std.mem.readInt(u16, data[@intCast(at)..][0..2], .big);
}

fn short(data: []const u8, at: i64) i16 {
    return @bitCast(ushort(data, at));
}

fn ulong(data: []const u8, at: i64) u32 {
    assert(data.len <= std.math.maxInt(u32));
    if (at < 0 or at + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[@intCast(at)..][0..4], .big);
}

fn tag_at(data: []const u8, at: i64, tag: *const [4]u8) bool {
    return ulong(data, at) == std.mem.readInt(u32, tag, .big);
}

/// A font, as stb_truetype's `stbtt_fontinfo` held it: where its tables are.
pub const Info = struct {
    data: []const u8,
    start: u32,
    glyph_count: u32,
    head: u32,
    hhea: u32,
    hmtx: u32,
    /// The kerning tables the font has: GPOS is read when it has both.
    kern: ?u32,
    gpos: ?u32,
    index_map: u32,
    outlines: Outlines,
};

/// Where the glyphs' outlines are: TrueType's glyf table, found through loca, or CFF's.
const Outlines = union(enum) {
    truetype: Glyf,
    cff: cff.Font,
};

const Glyf = struct {
    glyf: u32,
    loca: u32,
    /// From head: 0 for loca's offsets as halved 16-bit ones, 1 for 32-bit ones. Any
    /// other is a damaged font, whose glyphs are all empty, as stb_truetype drew them.
    loc_format: u16,
};

/// Whether a font's version says it's one: TrueType, OpenType, or Apple's.
fn is_font(data: []const u8) bool {
    assert(data.len <= std.math.maxInt(u32));
    comptime assert(std.mem.readInt(u32, "OTTO", .big) == 0x4f54544f);
    return tag_at(data, 0, "1\x00\x00\x00") or tag_at(data, 0, "typ1") or
        tag_at(data, 0, "OTTO") or tag_at(data, 0, "\x00\x01\x00\x00") or
        tag_at(data, 0, "true");
}

/// Where the first font starts: the file's start, or a collection's first.
// Assertions: it reads a font, outside data: what isn't one gives null.
fn first_font_offset(data: []const u8) ?u32 {
    assert(data.len <= std.math.maxInt(u32));
    if (is_font(data)) return 0;
    if (!tag_at(data, 0, "ttcf")) return null;
    const version = ulong(data, 4);
    if (version != 0x00010000 and version != 0x00020000) return null;
    const count: i32 = @bitCast(ulong(data, 8));
    if (count <= 0) return null;
    return ulong(data, 12);
}

/// The offset of table `tag`, or null if the font has none. Offset 0, where the font
/// itself starts, is no table: stb_truetype took it as none, and so does this.
// Assertions: it reads a font's directory, outside data: a table it lacks is null.
fn find_table(data: []const u8, start: u32, tag: *const [4]u8) ?u32 {
    const tables = ushort(data, @as(i64, start) + 4);
    const directory = @as(i64, start) + 12;
    for (0..tables) |i| {
        const record = directory + 16 * @as(i64, @intCast(i));
        if (tag_at(data, record, tag)) {
            const offset = ulong(data, record + 8);
            return if (offset == 0) null else offset;
        }
    }
    return null;
}

/// Reads a font (the first, in a collection). Null for one stb_truetype turned down.
// Assertions: it reads a font, outside data: what it can't use gives null.
pub fn init(data: []const u8) ?Info {
    if (data.len > std.math.maxInt(u32)) return null;
    const start = first_font_offset(data) orelse return null;
    const cmap = find_table(data, start, "cmap") orelse return null;
    const head = find_table(data, start, "head") orelse return null;
    const maxp = find_table(data, start, "maxp");
    const info: Info = .{
        .data = data,
        .start = start,
        .glyph_count = if (maxp) |table| ushort(data, @as(i64, table) + 4) else 0xffff,
        .head = head,
        .hhea = find_table(data, start, "hhea") orelse return null,
        .hmtx = find_table(data, start, "hmtx") orelse return null,
        .kern = find_table(data, start, "kern"),
        .gpos = find_table(data, start, "GPOS"),
        .index_map = find_index_map(data, cmap),
        .outlines = find_outlines(data, start, head) orelse return null,
    };
    if (info.index_map == 0) return null;
    // A font sized by its ascent less its descent needs that to be a height: one whose
    // descent is at or above its ascent can't be scaled to any size
    const metrics = vertical_metrics(&info);
    if (metrics.ascent - metrics.descent <= 0) return null;
    return info;
}

/// The font's outlines: TrueType's when it has a glyf table, else CFF's. Null for a
/// font with neither, or with glyf but no loca to find its glyphs by.
// Assertions: it reads a font, outside data: what it can't use gives null.
fn find_outlines(data: []const u8, start: u32, head: u32) ?Outlines {
    if (find_table(data, start, "glyf")) |glyf| {
        return .{ .truetype = .{
            .glyf = glyf,
            .loca = find_table(data, start, "loca") orelse return null,
            .loc_format = ushort(data, @as(i64, head) + 50),
        } };
    }
    const table = find_table(data, start, "CFF ") orelse return null;
    return .{ .cff = cff.init(data, table) orelse return null };
}

/// The character map to use: the last Unicode one, as stb_truetype chose.
fn find_index_map(data: []const u8, cmap: u32) u32 {
    assert(cmap != 0);
    const tables = ushort(data, @as(i64, cmap) + 2);
    var index_map: u32 = 0;
    for (0..tables) |i| {
        const record = @as(i64, cmap) + 4 + 8 * @as(i64, @intCast(i));
        const platform = ushort(data, record);
        const encoding = ushort(data, record + 2);
        const microsoft_unicode = platform == 3 and (encoding == 1 or encoding == 10);
        // Platform 0 is Unicode, whatever the encoding
        if (microsoft_unicode or platform == 0) index_map = cmap +% ulong(data, record + 4);
    }
    return index_map;
}

/// The glyph for a character, 0 for none.
pub fn glyph_index(info: *const Info, code_point: u32) u32 {
    assert(code_point <= 0x10ffff);
    assert(info.index_map != 0);
    const data = info.data;
    const map: i64 = info.index_map;
    const format = ushort(data, map);
    switch (format) {
        0 => {
            const bytes: i64 = ushort(data, map + 2);
            if (code_point < bytes - 6) return byte_at(data, map + 6 + code_point);
            return 0;
        },
        6 => {
            const first: u32 = ushort(data, map + 6);
            const count: u32 = ushort(data, map + 8);
            if (code_point >= first and code_point < first + count) {
                return ushort(data, map + 10 + (code_point - first) * 2);
            }
            return 0;
        },
        4 => return glyph_index_segments(data, map, code_point),
        12, 13 => return glyph_index_groups(data, map, code_point, format),
        // High-byte mappings (format 2) and the rest: no glyph, as stb_truetype had it
        else => return 0,
    }
}

/// Format 4: a binary search of segments, the usual map for the Basic Multilingual Plane.
fn glyph_index_segments(data: []const u8, map: i64, code_point: u32) u32 {
    assert(map >= 0);
    if (code_point > 0xffff) return 0;
    const segment_count: i64 = ushort(data, map + 6) >> 1;
    var search_range: i64 = ushort(data, map + 8) >> 1;
    const entry_selector = ushort(data, map + 10);
    const range_shift: i64 = ushort(data, map + 12) >> 1;
    const end_count = map + 14;
    var search = end_count;
    if (code_point >= ushort(data, search + range_shift * 2)) search += range_shift * 2;
    search -= 2;
    for (0..entry_selector) |_| {
        search_range >>= 1;
        const end = ushort(data, search + search_range * 2);
        if (code_point > end) search += search_range * 2;
    }
    search += 2;
    const item: i64 = @as(u16, @truncate(@as(u64, @bitCast(search - end_count)) >> 1));
    const start = ushort(data, map + 14 + segment_count * 2 + 2 + 2 * item);
    const last = ushort(data, end_count + 2 * item);
    if (code_point < start or code_point > last) return 0;
    const offset_at = map + 14 + segment_count * 6 + 2 + 2 * item;
    const offset = ushort(data, offset_at);
    if (offset == 0) {
        const delta = short(data, map + 14 + segment_count * 4 + 2 + 2 * item);
        return @as(u16, @truncate(code_point +% @as(u32, @bitCast(@as(i32, delta)))));
    }
    assert(code_point >= start);
    return ushort(data, offset_at + offset + (code_point - start) * 2);
}

/// Formats 12 and 13: a binary search of groups of characters, for any plane.
fn glyph_index_groups(data: []const u8, map: i64, code_point: u32, format: u16) u32 {
    assert(format == 12 or format == 13);
    const groups: i32 = @bitCast(ulong(data, map + 12));
    var low: i64 = 0;
    var high: i64 = groups;
    // Halves the range each turn
    while (low < high) {
        const middle = low + ((high - low) >> 1);
        assert(middle >= low); // Inside the range, so it shrinks each turn
        assert(middle < high);
        const group = map + 16 + middle * 12;
        const start_char = ulong(data, group);
        const end_char = ulong(data, group + 4);
        if (code_point < start_char) {
            high = middle;
        } else if (code_point > end_char) {
            low = middle + 1;
        } else {
            const start_glyph = ulong(data, group + 8);
            if (format == 12) return start_glyph +% code_point -% start_char;
            return start_glyph;
        }
    }
    return 0;
}

pub const VerticalMetrics = struct { ascent: i32, descent: i32, line_gap: i32 };

pub fn vertical_metrics(info: *const Info) VerticalMetrics {
    assert(info.hhea != 0);
    const hhea: i64 = info.hhea;
    const metrics: VerticalMetrics = .{
        .ascent = short(info.data, hhea + 4),
        .descent = short(info.data, hhea + 6),
        .line_gap = short(info.data, hhea + 8),
    };
    return metrics;
}

/// The scale that makes the font's ascent less its descent `height` pixels tall.
pub fn scale_for_pixel_height(info: *const Info, height: f32) f32 {
    assert(height > 0);
    const metrics = vertical_metrics(info);
    const font_height = metrics.ascent - metrics.descent;
    // `init` turned down every font without a height, so the scale is above zero
    assert(font_height > 0);
    assert(font_height <= std.math.maxInt(u16));
    return height / @as(f32, @floatFromInt(font_height));
}

pub const HorizontalMetrics = struct { advance: i32, left_side_bearing: i32 };

pub fn horizontal_metrics(info: *const Info, glyph: u32) HorizontalMetrics {
    assert(info.hmtx != 0);
    const long_metrics: i64 = ushort(info.data, @as(i64, info.hhea) + 34);
    const hmtx: i64 = info.hmtx;
    const g: i64 = glyph;
    if (g < long_metrics) {
        return .{
            .advance = short(info.data, hmtx + 4 * g),
            .left_side_bearing = short(info.data, hmtx + 4 * g + 2),
        };
    }
    // Past the long metrics, glyphs share the last advance
    assert(g >= long_metrics);
    return .{
        .advance = short(info.data, hmtx + 4 * (long_metrics - 1)),
        .left_side_bearing = short(info.data, hmtx + 4 * long_metrics + 2 * (g - long_metrics)),
    };
}

/// How much closer (negative) or further apart two glyphs sit than their advances
/// say: from the GPOS table if the font has one, else from its kern table.
pub fn kern_advance(info: *const Info, first: u32, second: u32) i32 {
    assert(info.data.len > 0);
    if (info.gpos) |gpos| return gpos_advance(info.data, gpos, first, second);
    if (info.kern) |kern| return kern_table_advance(info.data, kern, first, second);
    return 0;
}

/// The kern table at `offset`: its first subtable, if horizontal format 0, by binary
/// search.
fn kern_table_advance(data: []const u8, offset: u32, first: u32, second: u32) i32 {
    assert(offset != 0);
    const kern: i64 = offset;
    if (ushort(data, kern + 2) < 1) return 0;
    if (ushort(data, kern + 8) != 1) return 0;
    var left: i64 = 0;
    var right: i64 = @as(i64, ushort(data, kern + 10)) - 1;
    const needle = (first << 16) | (second & 0xffff);
    // Halves the range each turn
    while (left <= right) {
        const middle = (left + right) >> 1;
        assert(middle >= left); // Inside the range, so it shrinks each turn
        assert(middle <= right);
        const straw = ulong(data, kern + 18 + middle * 6);
        if (needle < straw) {
            right = middle - 1;
        } else if (needle > straw) {
            left = middle + 1;
        } else {
            return short(data, kern + 22 + middle * 6);
        }
    }
    return 0;
}

/// Where `glyph` is in a coverage table, or null if it isn't.
fn coverage_index(data: []const u8, table: i64, glyph: u32) ?u32 {
    assert(table >= 0);
    const format = ushort(data, table);
    const count: i64 = ushort(data, table + 2);
    var left: i64 = 0;
    var right: i64 = count - 1;
    // Halves the range each turn
    while (left <= right) {
        const middle = (left + right) >> 1;
        assert(middle >= left); // Inside the range, so it shrinks each turn
        assert(middle <= right);
        switch (format) {
            1 => {
                const straw = ushort(data, table + 4 + 2 * middle);
                if (glyph < straw) {
                    right = middle - 1;
                } else if (glyph > straw) {
                    left = middle + 1;
                } else {
                    return @intCast(middle);
                }
            },
            2 => {
                const record = table + 4 + 6 * middle;
                const range_start = ushort(data, record);
                const range_end = ushort(data, record + 2);
                if (glyph < range_start) {
                    right = middle - 1;
                } else if (glyph > range_end) {
                    left = middle + 1;
                } else {
                    return @as(u32, ushort(data, record + 4)) +% glyph -% range_start;
                }
            },
            else => return null,
        }
    }
    return null;
}

/// A glyph's class in a class definition table: 0 when it has none, null for a
/// format stb_truetype didn't read.
fn glyph_class(data: []const u8, table: i64, glyph: u32) ?u32 {
    assert(table >= 0);
    const format = ushort(data, table);
    if (format == 1) {
        const start: u32 = ushort(data, table + 2);
        const count: u32 = ushort(data, table + 4);
        if (glyph >= start and glyph < start + count) {
            return ushort(data, table + 6 + 2 * @as(i64, glyph - start));
        }
        return 0;
    }
    if (format != 2) return null;
    var left: i64 = 0;
    var right: i64 = @as(i64, ushort(data, table + 2)) - 1;
    // Halves the range each turn
    while (left <= right) {
        const middle = (left + right) >> 1;
        assert(middle >= left); // Inside the range, so it shrinks each turn
        assert(middle <= right);
        const record = table + 4 + 6 * middle;
        if (glyph < ushort(data, record)) {
            right = middle - 1;
        } else if (glyph > ushort(data, record + 2)) {
            left = middle + 1;
        } else {
            return ushort(data, record + 4);
        }
    }
    return 0;
}

/// Pair adjustments from the GPOS table: its type 2 lookups, in formats 1 (pairs) and
/// 2 (classes), when they adjust only the first glyph's advance.
fn gpos_advance(data: []const u8, offset: u32, first: u32, second: u32) i32 {
    assert(offset != 0);
    const gpos: i64 = offset;
    if (ushort(data, gpos) != 1 or ushort(data, gpos + 2) != 0) return 0;
    const lookup_list = gpos + ushort(data, gpos + 8);
    const lookup_count = ushort(data, lookup_list);
    for (0..lookup_count) |i| {
        const lookup = lookup_list + ushort(data, lookup_list + 2 + 2 * @as(i64, @intCast(i)));
        if (ushort(data, lookup) != 2) continue; // Not pair adjustment
        const subtable_count = ushort(data, lookup + 4);
        for (0..subtable_count) |s| {
            const table = lookup + ushort(data, lookup + 6 + 2 * @as(i64, @intCast(s)));
            const result = pair_adjustment(data, table, first, second);
            switch (result) {
                .next => {},
                .found => |value| return value,
            }
        }
    }
    return 0;
}

const PairResult = union(enum) { next, found: i32 };

fn pair_adjustment(data: []const u8, table: i64, first: u32, second: u32) PairResult {
    assert(table >= 0);
    assert(data.len <= std.math.maxInt(u32));
    const format = ushort(data, table);
    const coverage = coverage_index(data, table + ushort(data, table + 2), first) orelse {
        return .next;
    };
    // Only an x advance on the first glyph, and nothing on the second, is read: for
    // any other, stb_truetype gave no kerning and looked no further
    if (ushort(data, table + 4) != 4 or ushort(data, table + 6) != 0) return .{ .found = 0 };
    switch (format) {
        1 => return pair_by_glyph(data, table, coverage, second),
        2 => return pair_by_class(data, table, first, second),
        else => return .{ .found = 0 },
    }
}

fn pair_by_glyph(data: []const u8, table: i64, coverage: u32, second: u32) PairResult {
    assert(table >= 0);
    const pair_set_count = ushort(data, table + 8);
    const pair_set = table + ushort(data, table + 10 + 2 * @as(i64, coverage));
    if (coverage >= pair_set_count) return .{ .found = 0 };
    var left: i64 = 0;
    var right: i64 = @as(i64, ushort(data, pair_set)) - 1;
    // Halves the range each turn
    while (left <= right) {
        const middle = (left + right) >> 1;
        assert(middle >= left); // Inside the range, so it shrinks each turn
        assert(middle <= right);
        const pair = pair_set + 2 + 4 * middle;
        const straw = ushort(data, pair);
        if (second < straw) {
            right = middle - 1;
        } else if (second > straw) {
            left = middle + 1;
        } else {
            return .{ .found = short(data, pair + 2) };
        }
    }
    return .next;
}

// Assertions: it reads a font, outside data: a class out of range gives no kerning.
fn pair_by_class(data: []const u8, table: i64, first: u32, second: u32) PairResult {
    assert(table >= 0);
    const first_class = glyph_class(data, table + ushort(data, table + 8), first);
    const second_class = glyph_class(data, table + ushort(data, table + 10), second);
    const class1_count = ushort(data, table + 12);
    const class2_count = ushort(data, table + 14);
    const class1 = first_class orelse return .{ .found = 0 };
    const class2 = second_class orelse return .{ .found = 0 };
    if (class1 >= class1_count or class2 >= class2_count) return .{ .found = 0 };
    const records = table + 16 + 2 * (@as(i64, class1) * class2_count);
    return .{ .found = short(data, records + 2 * @as(i64, class2)) };
}

// Outlines.

/// Where a TrueType glyph's outline is, or null for an empty or missing one.
fn glyf_offset(info: *const Info, tables: *const Glyf, glyph: u32) ?i64 {
    assert(tables.glyf != 0);
    assert(tables.loca != 0);
    if (glyph >= info.glyph_count) return null;
    if (tables.loc_format >= 2) return null;
    const loca: i64 = tables.loca;
    const glyf: i64 = tables.glyf;
    const g: i64 = glyph;
    var g1: i64 = undefined;
    var g2: i64 = undefined;
    if (tables.loc_format == 0) {
        g1 = glyf + @as(i64, ushort(info.data, loca + g * 2)) * 2;
        g2 = glyf + @as(i64, ushort(info.data, loca + g * 2 + 2)) * 2;
    } else {
        g1 = glyf + ulong(info.data, loca + g * 4);
        g2 = glyf + ulong(info.data, loca + g * 4 + 4);
    }
    assert(g1 >= 0);
    return if (g1 == g2) null else g1;
}

const GlyphBox = struct { x0: i32 = 0, y0: i32 = 0, x1: i32 = 0, y1: i32 = 0 };

/// A glyph's bounds in font units: TrueType's from its header, CFF's by drawing it.
fn glyph_box(info: *const Info, glyph: u32) GlyphBox {
    switch (info.outlines) {
        .cff => |*font| {
            var c: cff.Context = .{ .out = .{ .bounds = null } };
            if (!cff.run(font, glyph, &c)) return .{};
            const box = c.out.bounds orelse return .{}; // A glyph with no outline: a space
            return .{ .x0 = box.min_x, .y0 = box.min_y, .x1 = box.max_x, .y1 = box.max_y };
        },
        .truetype => |*tables| {
            const g = glyf_offset(info, tables, glyph) orelse return .{};
            assert(g >= 0);
            return .{
                .x0 = short(info.data, g + 2),
                .y0 = short(info.data, g + 4),
                .x1 = short(info.data, g + 6),
                .y1 = short(info.data, g + 8),
            };
        },
    }
}

/// A glyph's outline, allocated from `alloc` (the caller frees it). Empty for a glyph
/// with none, or a damaged one.
fn glyph_shape(info: *const Info, alloc: std.mem.Allocator, glyph: u32) Error![]Vertex {
    switch (info.outlines) {
        .cff => |*font| {
            var counting: cff.Context = .{ .out = .{ .bounds = null } };
            if (!cff.run(font, glyph, &counting)) return &.{};
            const vertices = try alloc.alloc(Vertex, counting.vertex_count);
            errdefer alloc.free(vertices);
            var drawing: cff.Context = .{ .out = .{ .vertices = vertices } };
            if (!cff.run(font, glyph, &drawing)) {
                alloc.free(vertices);
                return &.{};
            }
            // Both runs read the same charstring
            assert(drawing.vertex_count == counting.vertex_count);
            return vertices;
        },
        .truetype => |*tables| {
            var list: std.ArrayList(Vertex) = .empty;
            errdefer list.deinit(alloc);
            try glyph_shape_truetype(info, tables, alloc, glyph, &list);
            assert(list.items.len <= std.math.maxInt(u32));
            return list.toOwnedSlice(alloc);
        },
    }
}

/// A composite glyph being read: where its next component is, and the transform of
/// the component in hand.
const Frame = struct {
    at: i64,
    more: bool,
    matrix: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    m: f32 = 1,
    n: f32 = 1,
};

/// A TrueType glyph's outline, simple or composite. Components are read in order,
/// depth first, and each simple one is moved by every transform it sits under, the
/// innermost first, as stb_truetype's recursion did.
fn glyph_shape_truetype(
    info: *const Info,
    tables: *const Glyf,
    alloc: std.mem.Allocator,
    glyph: u32,
    list: *std.ArrayList(Vertex),
) Error!void {
    assert(list.items.len == 0);
    const g = glyf_offset(info, tables, glyph) orelse return;
    const contours = short(info.data, g);
    if (contours > 0) return simple_glyph(info.data, alloc, g, list);
    if (contours == 0) return;
    var frames: [composite_depth_max]Frame = undefined;
    frames[0] = .{ .at = g + 10, .more = true };
    var depth: u32 = 1;
    // Each turn reads a component, or finishes a composite: bounded by the font's
    // bytes, as each component takes at least four
    for (0..info.data.len / 4 + composite_depth_max) |_| {
        if (depth == 0) break;
        const frame = &frames[depth - 1];
        if (!frame.more) {
            depth -= 1;
            continue;
        }
        const component = read_component(info.data, frame);
        const child = glyf_offset(info, tables, component) orelse continue;
        const child_contours = short(info.data, child);
        if (child_contours < 0 and depth < composite_depth_max) {
            frames[depth] = .{ .at = child + 10, .more = true };
            depth += 1;
        } else if (child_contours > 0) {
            const first: u32 = @intCast(list.items.len);
            try simple_glyph(info.data, alloc, child, list);
            for (0..depth) |level| transform(list.items[first..], &frames[depth - 1 - level]);
        }
    }
    // Still inside a composite after more steps than the font has components: it uses
    // its components over and over (nested many times, or naming itself), as no real
    // font does. A damaged glyph, drawn as nothing.
    if (depth > 0) {
        list.clearAndFree(alloc);
        return;
    }
    assert(depth == 0);
    assert(frames[0].at > g);
}

/// Reads a component record at `frame.at`: its transform into `frame`. Returns the
/// component's glyph.
fn read_component(data: []const u8, frame: *Frame) u32 {
    assert(frame.more);
    const flags: u16 = ushort(data, frame.at);
    const glyph: u32 = ushort(data, frame.at + 2);
    var at = frame.at + 4;
    frame.matrix = .{ 1, 0, 0, 1, 0, 0 };
    if (flags & 2 != 0) {
        // Offsets, as words or as bytes
        if (flags & 1 != 0) {
            frame.matrix[4] = @floatFromInt(short(data, at));
            frame.matrix[5] = @floatFromInt(short(data, at + 2));
            at += 4;
        } else {
            frame.matrix[4] = @floatFromInt(@as(i8, @bitCast(byte_at(data, at))));
            frame.matrix[5] = @floatFromInt(@as(i8, @bitCast(byte_at(data, at + 1))));
            at += 2;
        }
    } else {
        // Points to match up, which stb_truetype couldn't read: no offset, and its
        // arguments skipped
        at += if (flags & 1 != 0) 4 else 2;
    }
    at = read_component_scale(data, flags, at, &frame.matrix);
    const mtx = frame.matrix;
    frame.m = @floatCast(@sqrt(@as(f64, mtx[0] * mtx[0] + mtx[1] * mtx[1])));
    frame.n = @floatCast(@sqrt(@as(f64, mtx[2] * mtx[2] + mtx[3] * mtx[3])));
    frame.more = flags & (1 << 5) != 0;
    frame.at = at;
    assert(frame.at > 0);
    return glyph;
}

fn read_component_scale(data: []const u8, flags: u16, start: i64, matrix: *[6]f32) i64 {
    assert(start >= 0);
    var at = start;
    if (flags & (1 << 3) != 0) {
        matrix[0] = f2dot14(data, at);
        matrix[3] = matrix[0];
        at += 2;
    } else if (flags & (1 << 6) != 0) {
        matrix[0] = f2dot14(data, at);
        matrix[3] = f2dot14(data, at + 2);
        at += 4;
    } else if (flags & (1 << 7) != 0) {
        for (0..4) |i| matrix[i] = f2dot14(data, at + 2 * @as(i64, @intCast(i)));
        at += 8;
    }
    assert(at >= start);
    return at;
}

fn f2dot14(data: []const u8, at: i64) f32 {
    assert(at >= 0);
    const value: f32 = @floatFromInt(short(data, at));
    return value / 16384.0;
}

/// Moves a component's vertices by its transform, scaled as stb_truetype scaled it.
fn transform(vertices: []Vertex, frame: *const Frame) void {
    const mtx = frame.matrix;
    assert(!std.math.isNan(frame.m));
    for (vertices) |*v| {
        const x: f32 = @floatFromInt(v.x);
        const y: f32 = @floatFromInt(v.y);
        v.x = to_short(frame.m * (mtx[0] * x + mtx[2] * y + mtx[4]));
        v.y = to_short(frame.n * (mtx[1] * x + mtx[3] * y + mtx[5]));
        const cx: f32 = @floatFromInt(v.cx);
        const cy: f32 = @floatFromInt(v.cy);
        v.cx = to_short(frame.m * (mtx[0] * cx + mtx[2] * cy + mtx[4]));
        v.cy = to_short(frame.n * (mtx[1] * cx + mtx[3] * cy + mtx[5]));
    }
    assert(vertices.len <= std.math.maxInt(u32));
}

/// A coordinate to 16 bits, toward zero as C converts, wrapping as C's short did.
fn to_short(value: f32) i16 {
    const whole = to_int(@trunc(value));
    assert(@abs(@as(f64, @floatFromInt(whole))) <= @abs(@as(f64, value)) or std.math.isNan(value));
    return @truncate(whole);
}

/// The points of a simple glyph, read into arrays.
const Points = struct { flags: []const u8, xs: []const i16, ys: []const i16 };

/// A simple glyph's outline: its points, on and off the curve, into moves, lines and
/// quadratic curves, appended to `list`.
fn simple_glyph(
    data: []const u8,
    alloc: std.mem.Allocator,
    g: i64,
    list: *std.ArrayList(Vertex),
) Error!void {
    const contours: u32 = @intCast(short(data, g));
    assert(contours > 0);
    assert(g >= 0);
    const end_points = g + 10;
    const after_ends = end_points + @as(i64, contours) * 2;
    const point_count = @as(u32, ushort(data, after_ends - 2)) + 1;
    assert(point_count <= glyph_points_max);
    const flags = try alloc.alloc(u8, point_count);
    defer alloc.free(flags);
    const coordinates = try alloc.alloc(i16, point_count * 2);
    defer alloc.free(coordinates);
    const xs = coordinates[0..point_count];
    const ys = coordinates[point_count..];
    var at = after_ends + 2 + ushort(data, after_ends); // Past the instructions
    at = read_flags(data, at, flags);
    at = read_coordinates(data, at, flags, xs, .{ .short = 2, .same_or_positive = 16 });
    _ = read_coordinates(data, at, flags, ys, .{ .short = 4, .same_or_positive = 32 });
    // As many vertices as stb_truetype made room for: no glyph needs more
    try list.ensureUnusedCapacity(alloc, point_count + 2 * contours);
    const points: Points = .{ .flags = flags, .xs = xs, .ys = ys };
    const room = list.unusedCapacitySlice();
    const made = points_to_vertices(data, end_points, &points, room);
    list.items.len += made;
    assert(list.items.len <= list.capacity);
}

/// Each point's flags: a repeat flag lets one byte stand for a run of points.
fn read_flags(data: []const u8, start: i64, flags: []u8) i64 {
    assert(flags.len > 0);
    var at = start;
    var repeat: u8 = 0;
    var current: u8 = 0;
    for (flags) |*flag| {
        if (repeat == 0) {
            current = byte_at(data, at);
            at += 1;
            if (current & 8 != 0) {
                repeat = byte_at(data, at);
                at += 1;
            }
        } else {
            repeat -= 1;
        }
        flag.* = current;
    }
    assert(at >= start);
    return at;
}

/// Which flag bits say a coordinate is one byte, and its sign or that it repeats.
const CoordinateBits = struct { short: u8, same_or_positive: u8 };

/// One axis of the points: each a change from the one before, of one byte, two, or
/// none. Kept to 16 bits, as stb_truetype kept them.
fn read_coordinates(
    data: []const u8,
    start: i64,
    flags: []const u8,
    values: []i16,
    bits: CoordinateBits,
) i64 {
    assert(flags.len == values.len);
    assert(bits.short != bits.same_or_positive);
    var at = start;
    // The running sum is 32 bits; only what's kept is cut to 16
    var value: i32 = 0;
    for (flags, values) |flag, *out| {
        if (flag & bits.short != 0) {
            const delta: i32 = byte_at(data, at);
            at += 1;
            value +%= if (flag & bits.same_or_positive != 0) delta else -delta;
        } else if (flag & bits.same_or_positive == 0) {
            value +%= short(data, at);
            at += 2;
        }
        out.* = @truncate(value);
    }
    assert(at >= start);
    return at;
}

/// The state of `points_to_vertices` as it walks a glyph's points.
const Walk = struct {
    made: u32 = 0,
    was_off: bool = false,
    start_off: bool = false,
    sx: i32 = 0,
    sy: i32 = 0,
    cx: i32 = 0,
    cy: i32 = 0,
    scx: i32 = 0,
    scy: i32 = 0,

    fn add(walk: *Walk, out: []Vertex, kind: Vertex.Kind, xy: [4]i32) void {
        assert(walk.made <= out.len);
        // Room was made for every vertex a glyph can make; a damaged one loses the rest
        if (walk.made >= out.len) return;
        out[walk.made] = .{
            .kind = kind,
            .x = @truncate(xy[0]),
            .y = @truncate(xy[1]),
            .cx = @truncate(xy[2]),
            .cy = @truncate(xy[3]),
        };
        walk.made += 1;
        assert(walk.made <= out.len);
    }

    /// Back to the contour's start, by a line or, from off the curve, a curve.
    fn close(walk: *Walk, out: []Vertex) void {
        assert(walk.made <= out.len);
        const made_before = walk.made;
        defer assert(walk.made <= made_before + 2);
        if (walk.start_off) {
            if (walk.was_off) {
                const mx = (walk.cx + walk.scx) >> 1;
                const my = (walk.cy + walk.scy) >> 1;
                walk.add(out, .curve, .{ mx, my, walk.cx, walk.cy });
            }
            walk.add(out, .curve, .{ walk.sx, walk.sy, walk.scx, walk.scy });
        } else if (walk.was_off) {
            walk.add(out, .curve, .{ walk.sx, walk.sy, walk.cx, walk.cy });
        } else {
            walk.add(out, .line, .{ walk.sx, walk.sy, 0, 0 });
        }
    }
};

/// Turns points on and off the curve into moves, lines and curves: two points off
/// the curve in a row have one on it, halfway, between them. Returns how many
/// vertices it made.
fn points_to_vertices(data: []const u8, end_points: i64, points: *const Points, out: []Vertex) u32 {
    const n: u32 = @intCast(points.flags.len);
    assert(n > 0);
    var walk: Walk = .{};
    var next_move: u32 = 0;
    var contour: i64 = 0;
    var i: u32 = 0;
    // Each turn takes a point, or two
    while (i < n) : (i += 1) {
        const on = points.flags[i] & 1 != 0;
        const x: i32 = points.xs[i];
        const y: i32 = points.ys[i];
        if (next_move == i) {
            if (i != 0) walk.close(out);
            i = start_contour(&walk, points, i, out);
            next_move = @as(u32, ushort(data, end_points + contour * 2)) + 1;
            contour += 1;
        } else if (!on) {
            if (walk.was_off) {
                const middle = [4]i32{ (walk.cx + x) >> 1, (walk.cy + y) >> 1, walk.cx, walk.cy };
                walk.add(out, .curve, middle);
            }
            walk.cx = x;
            walk.cy = y;
            walk.was_off = true;
        } else {
            if (walk.was_off) {
                walk.add(out, .curve, .{ x, y, walk.cx, walk.cy });
            } else {
                walk.add(out, .line, .{ x, y, 0, 0 });
            }
            walk.was_off = false;
        }
    }
    walk.close(out);
    assert(walk.made <= out.len);
    return walk.made;
}

/// Starts a contour at point `i`. One off the curve starts it from the point on the
/// curve next to it, or halfway to the next, also off. Returns the last point used.
fn start_contour(walk: *Walk, points: *const Points, i: u32, out: []Vertex) u32 {
    const n: u32 = @intCast(points.flags.len);
    assert(i < n);
    const x: i32 = points.xs[i];
    const y: i32 = points.ys[i];
    var last = i;
    walk.start_off = points.flags[i] & 1 == 0;
    if (walk.start_off) {
        walk.scx = x;
        walk.scy = y;
        // Past the last point, stb_truetype read beyond its array: here, zeros
        const next_on = i + 1 < n and points.flags[i + 1] & 1 != 0;
        const nx: i32 = if (i + 1 < n) points.xs[i + 1] else 0;
        const ny: i32 = if (i + 1 < n) points.ys[i + 1] else 0;
        if (!next_on) {
            walk.sx = (x + nx) >> 1;
            walk.sy = (y + ny) >> 1;
        } else {
            walk.sx = nx;
            walk.sy = ny;
            last = i + 1;
        }
    } else {
        walk.sx = x;
        walk.sy = y;
    }
    walk.add(out, .move, .{ walk.sx, walk.sy, 0, 0 });
    walk.was_off = false;
    assert(last <= i + 1);
    return last;
}

/// A glyph's bitmap: coverage, a byte a pixel, row after row, or null for a glyph that
/// draws nothing. `x_offset` and `y_offset` place its top left from the pen.
pub const Bitmap = struct {
    pixels: ?[]u8,
    width: i32,
    height: i32,
    x_offset: i32,
    y_offset: i32,
};

/// Draws glyph `glyph` at `scale`, its pixels allocated from `alloc` for the caller.
pub fn glyph_bitmap(
    info: *const Info,
    alloc: std.mem.Allocator,
    scale: f32,
    glyph: u32,
) Error!Bitmap {
    assert(scale > 0);
    var bitmap = glyph_bitmap_box(info, scale, glyph);
    // A box with no pixels draws nothing
    if (bitmap.width <= 0 or bitmap.height <= 0) return bitmap;
    assert(bitmap.width <= bitmap_side_max);
    assert(bitmap.height <= bitmap_side_max);
    const vertices = try glyph_shape(info, alloc, glyph);
    defer alloc.free(vertices);
    const width: u32 = @intCast(bitmap.width);
    const height: u32 = @intCast(bitmap.height);
    const pixels = try alloc.alloc(u8, width * height);
    errdefer alloc.free(pixels);
    @memset(pixels, 0);
    const where: raster.Box = .{
        .x = bitmap.x_offset,
        .y = bitmap.y_offset,
        .width = width,
        .height = height,
    };
    try raster.rasterize(alloc, vertices, scale, where, pixels);
    bitmap.pixels = pixels;
    assert(pixels.len == width * height);
    return bitmap;
}

/// Where a glyph's bitmap lies, and its size, without drawing it: the pixels its
/// box touches, as stb_truetype rounded them. A box reaching further than
/// `bitmap_side_max` pixels from the pen, or wider or taller than that, is a damaged
/// glyph's (a CFF outline can wander far past the 16-bit points it's drawn with): it
/// has no pixels and sits at the pen, so placing it can't overflow a page's numbers.
pub fn glyph_bitmap_box(info: *const Info, scale: f32, glyph: u32) Bitmap {
    assert(scale > 0);
    assert(std.math.isFinite(scale));
    const empty: Bitmap = .{
        .pixels = null,
        .width = 0,
        .height = 0,
        .x_offset = 0,
        .y_offset = 0,
    };
    const box = glyph_box(info, glyph);
    // Negated as floats: a CFF box's side may be the smallest i32, which has no negative
    const x0 = pixel_side(@floor(@as(f32, @floatFromInt(box.x0)) * scale)) orelse return empty;
    const y0 = pixel_side(@floor(-@as(f32, @floatFromInt(box.y1)) * scale)) orelse return empty;
    const x1 = pixel_side(@ceil(@as(f32, @floatFromInt(box.x1)) * scale)) orelse return empty;
    const y1 = pixel_side(@ceil(-@as(f32, @floatFromInt(box.y0)) * scale)) orelse return empty;
    // Each side within reach of the pen, so neither difference can overflow
    const width = x1 - x0;
    const height = y1 - y0;
    if (width > bitmap_side_max or height > bitmap_side_max) return empty;
    return .{ .pixels = null, .width = width, .height = height, .x_offset = x0, .y_offset = y0 };
}

/// A side of a glyph's box, in whole pixels from the pen; null when it lies further
/// than `bitmap_side_max` (or isn't a number), where no glyph of a working font reaches.
fn pixel_side(whole: f32) ?i32 {
    if (!(@abs(whole) <= bitmap_side_max)) return null;
    return @intFromFloat(whole);
}

/// A whole number to 32 bits, held to its range (a damaged font's huge transform).
fn to_int(whole: f32) i32 {
    if (!(whole > -2147483648.0)) return if (whole < 0) std.math.minInt(i32) else 0;
    if (!(whole < 2147483648.0)) return std.math.maxInt(i32);
    return @intFromFloat(whole);
}

/// A TrueType font made in memory for tests: the tables `init` needs, character 'A'
/// mapped to glyph 1, and `glyphs` as the glyf table's glyphs, the first glyph 0.
fn test_font(alloc: std.mem.Allocator, glyphs: []const []const u8) ![]u8 {
    assert(glyphs.len > 1);
    assert(glyphs.len < 256);
    const tags = [_]*const [4]u8{ "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp" };
    var tables: [tags.len]std.ArrayList(u8) = @splat(.empty);
    defer for (&tables) |*t| t.deinit(alloc);
    const count: u16 = @intCast(glyphs.len);
    // The character map: one Unicode subtable of format 0, a glyph for each byte
    var cmap_bytes: [12 + 262]u8 = @splat(0);
    std.mem.writeInt(u16, cmap_bytes[2..4], 1, .big);
    std.mem.writeInt(u32, cmap_bytes[8..12], 12, .big);
    std.mem.writeInt(u16, cmap_bytes[14..16], 262, .big);
    cmap_bytes[18 + 'A'] = 1;
    try tables[0].appendSlice(alloc, &cmap_bytes);
    var locations: std.ArrayList(u8) = .empty;
    defer locations.deinit(alloc);
    for (glyphs) |g| {
        var offset: [4]u8 = undefined;
        std.mem.writeInt(u32, &offset, @intCast(tables[1].items.len), .big);
        try tables[5].appendSlice(alloc, &offset);
        try tables[1].appendSlice(alloc, g);
    }
    var last: [4]u8 = undefined;
    std.mem.writeInt(u32, &last, @intCast(tables[1].items.len), .big);
    try tables[5].appendSlice(alloc, &last);
    var head: [54]u8 = @splat(0);
    std.mem.writeInt(u16, head[18..20], 1000, .big); // Units per em
    std.mem.writeInt(u16, head[50..52], 1, .big); // Long offsets in loca
    try tables[2].appendSlice(alloc, &head);
    var hhea: [36]u8 = @splat(0);
    std.mem.writeInt(i16, hhea[4..6], 800, .big);
    std.mem.writeInt(i16, hhea[6..8], -200, .big);
    std.mem.writeInt(u16, hhea[34..36], count, .big);
    try tables[3].appendSlice(alloc, &hhea);
    for (glyphs) |_| try tables[4].appendSlice(alloc, &.{ 0x01, 0xf4, 0, 0 });
    var maxp: [6]u8 = .{ 0, 0, 0x50, 0, 0, 0 };
    std.mem.writeInt(u16, maxp[4..6], count, .big);
    try tables[6].appendSlice(alloc, &maxp);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var header: [12]u8 = .{ 0, 1, 0, 0, 0, tags.len, 0, 0, 0, 0, 0, 0 };
    try out.appendSlice(alloc, &header);
    var at: u32 = 12 + 16 * tags.len;
    for (tags, tables) |tag, t| {
        var record: [16]u8 = @splat(0);
        @memcpy(record[0..4], tag);
        std.mem.writeInt(u32, record[8..12], at, .big);
        std.mem.writeInt(u32, record[12..16], @intCast(t.items.len), .big);
        try out.appendSlice(alloc, &record);
        at += @intCast(t.items.len);
    }
    for (tables) |t| try out.appendSlice(alloc, t.items);
    assert(out.items.len == at);
    return out.toOwnedSlice(alloc);
}

/// A composite glyph of `count` copies of glyph `component`, each moved a little.
fn test_composite(alloc: std.mem.Allocator, component: u16, count: u32) ![]u8 {
    assert(count > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ 0xff, 0xff, 0, 0, 0, 0, 0, 100, 0, 100 });
    for (0..count) |i| {
        // Offsets as bytes (2), and more after this one (0x20) but for the last
        const more: u8 = if (i + 1 < count) 0x20 else 0;
        const glyph: [2]u8 = @bitCast(std.mem.nativeToBig(u16, component));
        try out.appendSlice(alloc, &.{ 0, 0x02 | more, glyph[0], glyph[1], 1, 1 });
    }
    assert(out.items.len == 10 + 6 * count);
    return out.toOwnedSlice(alloc);
}

test "composites that nest or repeat past the font's size draw nothing, never crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A triangle: one contour of three points on the curve, as words
    const triangle = [_]u8{
        0, 1, 0, 0, 0, 0, 0, 100, 0, 100, // One contour, its box
        0, 2, 0, 0, 1, 1, 1, // Its last point, no instructions, three flags
        0, 0, 0, 100, 0xff, 0xce, // x: 0, then 100 on, then 50 back
        0, 0, 0, 0, 0, 100, // y: 0, 0, then 100 up
    };
    // 40 triangles, 22 of those, 28 of those: far more steps than bytes
    const nested = try test_font(alloc, &.{
        "",
        &triangle,
        try test_composite(alloc, 1, 40),
        try test_composite(alloc, 2, 22),
        try test_composite(alloc, 3, 28),
    });
    // Itself, twice, as deep as a composite may nest
    const looping = try test_font(alloc, &.{ "", &triangle, try test_composite(alloc, 2, 2) });
    for ([_][]const u8{ nested, looping }, [_]u32{ 4, 2 }) |data, glyph| {
        const info = init(data) orelse return error.TestUnexpectedResult;
        // The triangle itself draws
        const simple = try glyph_shape(&info, alloc, 1);
        try std.testing.expect(simple.len > 0);
        const shape = try glyph_shape(&info, alloc, glyph);
        try std.testing.expectEqual(@as(usize, 0), shape.len);
        const bitmap = try glyph_bitmap(&info, alloc, 0.1, glyph);
        if (bitmap.pixels) |pixels| for (pixels) |p| try std.testing.expectEqual(0, p);
    }
}

test "a glyph box wider than any glyph or far from the pen is empty, at the pen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A triangle's points, after a header of one contour and the box given
    const points = [_]u8{ 0, 2, 0, 0, 1, 1, 1, 0, 0, 0, 100, 0xff, 0xce, 0, 0, 0, 0, 0, 100 };
    const boxes = [_][4]i16{
        .{ 0, 0, 100, 100 }, // The triangle's own
        .{ 20000, 0, 20001, 1 }, // One pixel, far past the pen
        .{ -10000, 0, 10000, 100 }, // Each side within reach, but wider than any glyph
    };
    var glyphs: [boxes.len + 1][]const u8 = undefined;
    glyphs[0] = "";
    for (boxes, glyphs[1..]) |box, *glyph| {
        var bytes: std.ArrayList(u8) = .empty;
        try bytes.appendSlice(alloc, &.{ 0, 1 });
        for (box) |side| {
            const big: [2]u8 = @bitCast(std.mem.nativeToBig(i16, side));
            try bytes.appendSlice(alloc, &big);
        }
        try bytes.appendSlice(alloc, &points);
        glyph.* = bytes.items;
    }
    const info = init(try test_font(alloc, &glyphs)) orelse return error.TestUnexpectedResult;
    // The test font's ascent less descent is 1000 units: one unit a pixel
    const scale = scale_for_pixel_height(&info, 1000);
    try std.testing.expectEqual(@as(f32, 1), scale);
    const drawn = try glyph_bitmap(&info, alloc, scale, 1);
    try std.testing.expectEqual(@as(i32, 100), drawn.width);
    try std.testing.expectEqual(@as(i32, 100), drawn.height);
    try std.testing.expect(drawn.pixels != null);
    for ([_]u32{ 2, 3 }) |glyph| {
        const bitmap = try glyph_bitmap(&info, alloc, scale, glyph);
        try std.testing.expect(bitmap.pixels == null);
        try std.testing.expectEqual(@as(i32, 0), bitmap.width);
        try std.testing.expectEqual(@as(i32, 0), bitmap.height);
        try std.testing.expectEqual(@as(i32, 0), bitmap.x_offset);
        try std.testing.expectEqual(@as(i32, 0), bitmap.y_offset);
    }
}
