//! TrueType fonts through stb_truetype: measuring and drawing text onto a page.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("page.zig").Page;

comptime {
    _ = @import("c_memory.zig"); // The malloc and free stb's C shim calls
}

extern fn ft_open(ttf: [*]const u8) ?*anyopaque;
extern fn ft_close(f: *anyopaque) void;
extern fn ft_scale(f: *anyopaque, px: f32) f32;
extern fn ft_vmetrics(f: *anyopaque, asc: *c_int, desc: *c_int, gap: *c_int) void;
extern fn ft_index(f: *anyopaque, cp: c_int) c_int;
extern fn ft_hmetrics(f: *anyopaque, g: c_int, adv: *c_int, lsb: *c_int) void;
extern fn ft_kern(f: *anyopaque, a: c_int, b: c_int) c_int;
extern fn ft_bitmap(
    f: *anyopaque,
    scale: f32,
    g: c_int,
    w: *c_int,
    h: *c_int,
    xo: *c_int,
    yo: *c_int,
) ?[*]u8;

/// The font file's first bytes: its version, which says what kind of font it is.
const sfnt_version_truetype = 0x00010000;
const sfnt_version_apple = 0x74727565; // "true"
const sfnt_version_opentype = 0x4f54544f; // "OTTO"
/// A font's table directory: version, table count and search hints, then the records.
const table_directory_size = 12;
const table_record_size = 16;
/// A collection's header: "ttcf", version, font count, then the first font's offset.
const collection_header_size = 16;
/// Combining diacritics, which sit over the letter before and take no room of their own.
const combining_first = 0x300;
const combining_last = 0x36f;
const code_point_max = 0x10ffff;

comptime {
    assert(sfnt_version_apple == std.mem.readInt(u32, "true", .big));
    assert(sfnt_version_opentype == std.mem.readInt(u32, "OTTO", .big));
    // The directory holds the version and the table count read from it
    assert(table_directory_size >= 4 + 2);
    // A record holds its tag, checksum, offset and length
    assert(table_record_size == 4 * 4);
    assert(collection_header_size == 12 + 4);
    assert(combining_first < combining_last);
}

fn is_combining(code_point: u32) bool {
    return code_point >= combining_first and code_point <= combining_last;
}

const Glyph = struct {
    index: c_int,
    advance: f32,
    width: i32,
    height: i32,
    x_offset: i32,
    y_offset: i32,
    pixels: ?[*]u8,
};

pub const Font = struct {
    handle: *anyopaque,
    scale: f32,
    ascent: i32,
    line_height: i32,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    alloc: std.mem.Allocator,

    /// Whether `ttf` is a font that can set text: it opens, and has letters. Any file
    /// can be named .ttf, and stb_truetype trusts what it's given, so its table
    /// directory is checked first: every table inside the file.
    pub fn usable(ttf: []const u8) bool {
        if (!tables_inside(ttf)) return false;
        assert(ttf.len >= table_directory_size);
        const handle = ft_open(ttf.ptr) orelse return false;
        defer ft_close(handle);
        return ft_index(handle, 'a') != 0 and ft_index(handle, 'A') != 0;
    }

    /// A TrueType or OpenType font (or the first of a collection) whose tables all lie
    /// within `data`.
    pub fn tables_inside(data: []const u8) bool {
        if (data.len < table_directory_size) return false;
        // Offsets in a font are 32 bits: a larger file isn't a font
        if (data.len > std.math.maxInt(u32)) return false;
        var at: u32 = 0;
        if (std.mem.eql(u8, data[0..4], "ttcf")) {
            if (data.len < collection_header_size) return false;
            at = std.mem.readInt(u32, data[12..16], .big);
            if (at > data.len - table_directory_size) return false;
        }
        assert(at + table_directory_size <= data.len);
        const version = std.mem.readInt(u32, data[at..][0..4], .big);
        if (version != sfnt_version_truetype and version != sfnt_version_apple and
            version != sfnt_version_opentype) return false;
        const tables = std.mem.readInt(u16, data[at + 4 ..][0..2], .big);
        if (tables == 0) return false;
        const records_size = @as(u32, tables) * table_record_size;
        if (@as(u64, at) + table_directory_size + records_size > data.len) return false;
        const records = data[at + table_directory_size ..][0..records_size];
        assert(records.len == @as(u32, tables) * table_record_size);
        for (0..tables) |i| {
            const record = records[i * table_record_size ..][0..table_record_size];
            const offset = std.mem.readInt(u32, record[8..12], .big);
            const length = std.mem.readInt(u32, record[12..16], .big);
            if (@as(u64, offset) + length > data.len) return false;
        }
        return true;
    }

    pub fn init(alloc: std.mem.Allocator, ttf: []const u8, px: f32, line_spacing: f32) !Font {
        // Sizes and spacings are noface's own, from its tables, never a book's
        assert(px > 0);
        assert(line_spacing >= 1);
        const handle = ft_open(ttf.ptr) orelse return error.BadFont;
        const scale = ft_scale(handle, px);
        // A font whose ascent equals its descent has no height to scale by: the
        // division gives infinity, which can't be turned into whole pixels below.
        if (!std.math.isFinite(scale)) {
            ft_close(handle);
            return error.BadFont;
        }
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        ft_vmetrics(handle, &ascent, &descent, &line_gap);
        return .{
            .handle = handle,
            .scale = scale,
            .ascent = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale),
            .line_height = @intFromFloat(px * line_spacing),
            .alloc = alloc,
        };
    }

    fn glyph(f: *Font, code_point: u32) !Glyph {
        // Code points come from decoding UTF-8, which yields only these
        assert(code_point <= code_point_max);
        if (f.glyphs.get(code_point)) |g| return g;
        const index = ft_index(f.handle, @intCast(code_point));
        // A font keeps glyph indexes as 16-bit unsigned numbers, 0 for a missing glyph
        assert(index >= 0);
        var advance: c_int = 0;
        var left_side_bearing: c_int = 0;
        ft_hmetrics(f.handle, index, &advance, &left_side_bearing);
        var width: c_int = 0;
        var height: c_int = 0;
        var x_offset: c_int = 0;
        var y_offset: c_int = 0;
        const pixels = ft_bitmap(f.handle, f.scale, index, &width, &height, &x_offset, &y_offset);
        const g = Glyph{
            .index = index,
            .advance = @as(f32, @floatFromInt(advance)) * f.scale,
            .width = width,
            .height = height,
            .x_offset = x_offset,
            .y_offset = y_offset,
            .pixels = pixels,
        };
        try f.glyphs.put(f.alloc, code_point, g);
        return g;
    }

    fn kern(f: *Font, a: *const Glyph, b: *const Glyph) f32 {
        assert(a.index >= 0);
        assert(b.index >= 0);
        return @as(f32, @floatFromInt(ft_kern(f.handle, a.index, b.index))) * f.scale;
    }

    pub fn measure(f: *Font, word: []const u8) !f32 {
        var width: f32 = 0;
        var previous: ?Glyph = null;
        var it = (std.unicode.Utf8View.init(word) catch return 0).iterator();
        while (it.nextCodepoint()) |code_point| {
            if (is_combining(code_point)) continue;
            const g = try f.glyph(code_point);
            if (previous) |p| width += f.kern(&p, &g);
            width += g.advance;
            previous = g;
        }
        // Only a word with letters has width
        if (previous == null) assert(width == 0);
        return width;
    }

    /// Bytes of `word` that fit in `avail`, always at least one character.
    pub fn fit(f: *Font, word: []const u8, avail: f32) !usize {
        // Words are pieces of a paragraph or of noface's own text, far under 4 GB
        assert(word.len <= std.math.maxInt(u32));
        var width: f32 = 0;
        var previous: ?Glyph = null;
        var last: u32 = 0;
        var it = (std.unicode.Utf8View.init(word) catch return word.len).iterator();
        while (it.nextCodepoint()) |code_point| {
            if (is_combining(code_point)) {
                last = @intCast(it.i);
                continue;
            }
            const g = try f.glyph(code_point);
            if (previous) |p| width += f.kern(&p, &g);
            width += g.advance;
            if (width > avail and last > 0) break;
            last = @intCast(it.i);
            previous = g;
        }
        assert(last <= word.len);
        if (word.len > 0) assert(last > 0);
        return last;
    }

    pub fn draw(f: *Font, page: Page, x_start: f32, baseline: i32, word: []const u8) !void {
        // Positions come from layout, which never makes one that isn't a number
        assert(std.math.isFinite(x_start));
        assert(page.holds_rows());
        var x = x_start;
        var previous: ?Glyph = null;
        var it = (std.unicode.Utf8View.init(word) catch return).iterator();
        var base_x = x;
        while (it.nextCodepoint()) |code_point| {
            const g = try f.glyph(code_point);
            if (is_combining(code_point)) {
                // Centred over the letter it belongs to.
                const letter = if (previous) |p| p.advance else 0;
                const mark = @as(f32, @floatFromInt(g.width));
                const mark_x: i32 = @intFromFloat(base_x + (letter - mark) / 2);
                blit(page, &g, mark_x, baseline + g.y_offset);
                continue;
            }
            if (previous) |p| x += f.kern(&p, &g);
            blit(page, &g, @as(i32, @intFromFloat(x)) + g.x_offset, baseline + g.y_offset);
            base_x = x;
            x += g.advance;
            previous = g;
        }
    }
};

/// Draws a glyph's coverage onto a page, darkening what's already there.
fn blit(p: Page, g: *const Glyph, x: i32, y: i32) void {
    const source = g.pixels orelse return;
    // Checked once here, not per pixel: the rows clipped to the page lie in its buffer
    assert(p.holds_rows());
    assert(p.height <= std.math.maxInt(i32));
    const height: i32 = @intCast(p.height);
    const width: i32 = @intCast(p.width);
    var row: i32 = 0;
    while (row < g.height) : (row += 1) {
        const py = y + row;
        if (py < 0 or py >= height) continue;
        var col: i32 = 0;
        while (col < g.width) : (col += 1) {
            const px = x + col;
            if (px < 0 or px >= width) continue;
            const a = source[@intCast(row * g.width + col)];
            const at = @as(u32, @intCast(py)) * p.stride + @as(u32, @intCast(px));
            p.buf[at] = @min(p.buf[at], 255 - a);
        }
    }
}

test "files that aren't fonts are turned down before stb sees them" {
    try std.testing.expect(!Font.tables_inside(""));
    const html = "<!doctype html><html><head><title>font</title></head>";
    try std.testing.expect(!Font.tables_inside(html));
    var zeros: [4096]u8 = @splat(0);
    try std.testing.expect(!Font.tables_inside(&zeros));
    // A real font's directory, then the same with one table said to run past the end
    const go = @embedFile("../testdata/fonts/Go-Regular.ttf");
    try std.testing.expect(Font.tables_inside(go));
    try std.testing.expect(!Font.tables_inside(go[0 .. go.len / 2]));
}

test "a font with no height is turned down, not scaled by infinity" {
    const go = @embedFile("../testdata/fonts/Go-Regular.ttf");
    var flat: [go.len]u8 = go.*;
    // Finds the hhea table and gives the font a descent equal to its ascent
    const tables = std.mem.readInt(u16, flat[4..6], .big);
    for (0..tables) |i| {
        const record = flat[12 + i * 16 ..][0..16];
        if (!std.mem.eql(u8, record[0..4], "hhea")) continue;
        const offset = std.mem.readInt(u32, record[8..12], .big);
        const ascent = flat[offset + 4 ..][0..2].*;
        flat[offset + 6 ..][0..2].* = ascent;
    }
    try std.testing.expectError(error.BadFont, Font.init(std.testing.allocator, &flat, 30, 1.2));
}

test "words fit by whole characters, at least one" {
    const go = @embedFile("../testdata/fonts/Go-Regular.ttf");
    var font = try Font.init(std.testing.allocator, go, 40, 1.2);
    defer font.glyphs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), try font.fit("wide", 0));
    try std.testing.expectEqual(@as(usize, 4), try font.fit("wide", 10_000));
    try std.testing.expectEqual(@as(usize, 0), try font.fit("", 10));
    try std.testing.expectEqual(@as(f32, 0), try font.measure(""));
}
