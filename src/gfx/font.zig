//! TrueType and OpenType fonts (TrueType or CFF outlines): measuring and drawing text
//! onto a page.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("page.zig").Page;
const truetype = @import("truetype.zig");
const decoder_memory = @import("decoder_memory.zig");

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
    index: u32,
    advance: f32,
    width: i32,
    height: i32,
    x_offset: i32,
    y_offset: i32,
    pixels: ?[]u8,
};

pub const Font = struct {
    info: truetype.Info,
    scale: f32,
    ascent: i32,
    line_height: i32,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    alloc: std.mem.Allocator,

    /// Whether `ttf` is a font that can set text: it opens, and has letters. Any file
    /// can be named .ttf, so its table directory is checked first: every table inside
    /// the file.
    pub fn usable(ttf: []const u8) bool {
        if (!tables_inside(ttf)) return false;
        assert(ttf.len >= table_directory_size);
        const info = truetype.init(ttf) orelse return false;
        return truetype.glyph_index(&info, 'a') != 0 and truetype.glyph_index(&info, 'A') != 0;
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
        const info = truetype.init(ttf) orelse return error.BadFont;
        const scale = truetype.scale_for_pixel_height(&info, px);
        // A font whose ascent equals its descent has no height to scale by: the
        // division gives infinity, which can't be turned into whole pixels below.
        if (!std.math.isFinite(scale)) return error.BadFont;
        const ascent = truetype.vertical_metrics(&info).ascent;
        return .{
            .info = info,
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
        const index = truetype.glyph_index(&f.info, code_point);
        const advance = truetype.horizontal_metrics(&f.info, index).advance;
        // Kept as long as the font: glyphs are drawn once, from the decoders' budget.
        // With no room left there, a glyph is drawn blank, as stb_truetype drew it.
        const decoders = decoder_memory.allocator();
        const bitmap = truetype.glyph_bitmap(&f.info, decoders, f.scale, index) catch
            truetype.glyph_bitmap_box(&f.info, f.scale, index);
        const g = Glyph{
            .index = index,
            .advance = @as(f32, @floatFromInt(advance)) * f.scale,
            .width = bitmap.width,
            .height = bitmap.height,
            .x_offset = bitmap.x_offset,
            .y_offset = bitmap.y_offset,
            .pixels = bitmap.pixels,
        };
        // Paired with `blit`, which reads `width` times `height` pixels
        if (g.pixels) |pixels| {
            assert(pixels.len == @as(u64, @intCast(g.width)) * @as(u64, @intCast(g.height)));
        }
        try f.glyphs.put(f.alloc, code_point, g);
        return g;
    }

    fn kern(f: *Font, a: *const Glyph, b: *const Glyph) f32 {
        assert(std.math.isFinite(f.scale));
        assert(f.scale != 0);
        const units = truetype.kern_advance(&f.info, a.index, b.index);
        return @as(f32, @floatFromInt(units)) * f.scale;
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
    pub fn fit(f: *Font, word: []const u8, avail: f32) !u32 {
        // Words are pieces of a paragraph or of noface's own text, far under 4 GB
        assert(word.len <= std.math.maxInt(u32));
        var width: f32 = 0;
        var previous: ?Glyph = null;
        var last: u32 = 0;
        var it = (std.unicode.Utf8View.init(word) catch return @intCast(word.len)).iterator();
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

/// Draws a glyph's coverage onto a page, darkening what's already there. Clipped to
/// the page once, here, so the rows drawn need no test per pixel.
fn blit(p: Page, g: *const Glyph, x: i32, y: i32) void {
    const source = g.pixels orelse return;
    // Checked once here, not per pixel: the rows clipped to the page lie in its buffer
    assert(p.holds_rows());
    // Paired with `glyph`, which keeps `width` times `height` pixels
    assert(source.len == @as(u64, @intCast(g.width)) * @as(u64, @intCast(g.height)));
    // In 64 bits, so a glyph placed far off the page can't overflow its edges
    const left: i64 = x;
    const top: i64 = y;
    const column_start = std.math.clamp(-left, 0, g.width);
    const column_end = std.math.clamp(@as(i64, p.width) - left, 0, g.width);
    const row_start = std.math.clamp(-top, 0, g.height);
    const row_end = std.math.clamp(@as(i64, p.height) - top, 0, g.height);
    if (column_start >= column_end) return;
    if (row_start >= row_end) return;
    // What's left lies on the page
    assert(left + column_start >= 0);
    assert(left + column_end <= p.width);
    assert(top + row_start >= 0);
    assert(top + row_end <= p.height);
    const glyph_width: u32 = @intCast(g.width);
    const target_first: u32 = @intCast((top + row_start) * p.stride + left + column_start);
    const source_first: u32 = @intCast(row_start * glyph_width + column_start);
    blit_rows(.{
        .target = p.buf[target_first..],
        .target_stride = p.stride,
        .source = source[source_first..],
        .source_stride = glyph_width,
        .rows = @intCast(row_end - row_start),
        .columns = @intCast(column_end - column_start),
    });
}

/// A block of a glyph's coverage and where on a page it goes: `rows` rows of
/// `columns` pixels, each row `source_stride` after the last in `source` and
/// `target_stride` after the last in `target`.
const BlitRows = struct {
    target: []u8,
    target_stride: u32,
    source: []const u8,
    source_stride: u32,
    rows: u32,
    columns: u32,
};

/// The hot loop of `blit`: each row darkened whole, its bounds checked once a row,
/// not once a pixel.
fn blit_rows(b: BlitRows) void {
    assert(b.rows > 0);
    assert(b.columns > 0);
    assert(b.columns <= b.target_stride);
    assert(b.columns <= b.source_stride);
    assert(@as(u64, b.rows - 1) * b.target_stride + b.columns <= b.target.len);
    assert(@as(u64, b.rows - 1) * b.source_stride + b.columns <= b.source.len);
    var target_at: u32 = 0;
    var source_at: u32 = 0;
    for (0..b.rows) |_| {
        const target = b.target[target_at..][0..b.columns];
        const source = b.source[source_at..][0..b.columns];
        for (target, source) |*pixel, coverage| pixel.* = @min(pixel.*, 255 - coverage);
        target_at += b.target_stride;
        source_at += b.source_stride;
    }
}

test "a glyph drawn across any edge of the page is clipped there, pixel for pixel" {
    var coverage: [7 * 5]u8 = undefined;
    for (&coverage, 0..) |*pixel, index| pixel.* = @intCast(index * 7 % 256);
    const g = Glyph{
        .index = 1,
        .advance = 7,
        .width = 7,
        .height = 5,
        .x_offset = 0,
        .y_offset = 0,
        .pixels = &coverage,
    };
    var drawn: [12 * 9]u8 = undefined;
    var expected: [12 * 9]u8 = undefined;
    // Ten columns of twelve in memory, so a row's padding must stay untouched
    const page = Page{ .buf = &drawn, .width = 10, .height = 9, .stride = 12 };
    const places = [_][2]i32{
        .{ 2, 2 },   .{ -3, 1 },  .{ 6, 1 },  .{ 2, -2 },                   .{ 2, 7 },
        .{ -6, -4 }, .{ 9, 8 },   .{ -7, 0 }, .{ 10, 0 },                   .{ 0, 9 },
        .{ 0, -5 },  .{ -3, -3 }, .{ 5, 6 },  .{ std.math.minInt(i32), 0 },
    };
    for (places) |place| {
        for (&drawn, &expected, 0..) |*a, *b, index| {
            a.* = @intCast(255 - index % 200);
            b.* = a.*;
        }
        blit(page, &g, place[0], place[1]);
        // One pixel at a time, each tested against the page's edges
        for (0..5) |row| for (0..7) |column| {
            const x = @as(i64, place[0]) + @as(i64, @intCast(column));
            const y = @as(i64, place[1]) + @as(i64, @intCast(row));
            if (x < 0 or y < 0 or x >= page.width or y >= page.height) continue;
            const at: u32 = @intCast(y * page.stride + x);
            expected[at] = @min(expected[at], 255 - coverage[row * 7 + column]);
        };
        try std.testing.expectEqualSlices(u8, &expected, &drawn);
    }
}

test "files that aren't fonts are turned down before they're read" {
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
    try std.testing.expectEqual(@as(u32, 1), try font.fit("wide", 0));
    try std.testing.expectEqual(@as(u32, 4), try font.fit("wide", 10_000));
    try std.testing.expectEqual(@as(u32, 0), try font.fit("", 10));
    try std.testing.expectEqual(@as(f32, 0), try font.measure(""));
}

/// A hash of every glyph's metrics, then of every glyph's bitmap at each size, so a
/// test can hold the whole font to what stb_truetype drew.
fn test_font_digest(info: *const truetype.Info, sizes: []const f32) !u64 {
    assert(sizes.len > 0);
    assert(info.glyph_count > 0);
    var hasher = std.hash.Wyhash.init(0);
    for (0..info.glyph_count) |glyph| {
        const metrics = truetype.horizontal_metrics(info, @intCast(glyph));
        hasher.update(std.mem.asBytes(&metrics.advance));
        hasher.update(std.mem.asBytes(&metrics.left_side_bearing));
    }
    for (sizes) |px| {
        const scale = truetype.scale_for_pixel_height(info, px);
        for (0..info.glyph_count) |glyph| {
            const allocator = std.testing.allocator;
            const bitmap = try truetype.glyph_bitmap(info, allocator, scale, @intCast(glyph));
            defer if (bitmap.pixels) |pixels| allocator.free(pixels);
            const box = [_]i32{ bitmap.width, bitmap.height, bitmap.x_offset, bitmap.y_offset };
            for (box) |value| hasher.update(std.mem.asBytes(&value));
            if (bitmap.pixels) |pixels| hasher.update(pixels);
        }
    }
    return hasher.final();
}

test "fonts draw the glyphs stb_truetype drew" {
    // Digests of stb_truetype's metrics and bitmaps, built without fused
    // multiply-adds (with them, a pixel in a few million comes out one gray apart)
    const cases = .{
        .{ "Go-Regular.ttf", 712, 0x02e5b2a7673601b3 },
        .{ "Go-Bold.ttf", 712, 0x434e5d8b4ebbfe99 },
        .{ "GoKernGpos.ttf", 13, 0x0c58cf1ea5e5ffc7 },
        .{ "GoKernTable.ttf", 13, 0x0c58cf1ea5e5ffc7 },
        .{ "GoCubic.otf", 13, 0xe6b79c084d80d4cd },
    };
    inline for (cases) |case| {
        const info = truetype.init(@embedFile("../testdata/fonts/" ++ case[0])).?;
        try std.testing.expectEqual(@as(u32, case[1]), info.glyph_count);
        const digest = try test_font_digest(&info, &.{ 26, 46, 80.5 });
        try std.testing.expectEqual(@as(u64, case[2]), digest);
    }
}

test "kerning comes from GPOS pairs and classes, or from the kern table" {
    const gpos = truetype.init(@embedFile("../testdata/fonts/GoKernGpos.ttf")).?;
    const table = truetype.init(@embedFile("../testdata/fonts/GoKernTable.ttf")).?;
    const cubic = truetype.init(@embedFile("../testdata/fonts/GoCubic.otf")).?;
    const fonts = [_]*const truetype.Info{ &gpos, &table, &cubic };
    for (fonts) |info| {
        const a = truetype.glyph_index(info, 'A');
        const v = truetype.glyph_index(info, 'V');
        try std.testing.expectEqual(@as(i32, -120), truetype.kern_advance(info, a, v));
        try std.testing.expectEqual(@as(i32, 0), truetype.kern_advance(info, v, a));
    }
    // A pair by classes: V or W, then o or e
    for ([_]*const truetype.Info{ &gpos, &cubic }) |info| {
        const w = truetype.glyph_index(info, 'W');
        const e = truetype.glyph_index(info, 'e');
        try std.testing.expectEqual(@as(i32, -45), truetype.kern_advance(info, w, e));
    }
    const o = truetype.glyph_index(&table, 'o');
    const v = truetype.glyph_index(&table, 'V');
    try std.testing.expectEqual(@as(i32, -40), truetype.kern_advance(&table, v, o));
}

test "damaged fonts draw blank or wrong glyphs, never crash" {
    const fonts = [_][]const u8{
        @embedFile("../testdata/fonts/GoKernGpos.ttf"),
        @embedFile("../testdata/fonts/GoCubic.otf"),
    };
    var prng = std.Random.DefaultPrng.init(0xf0e7);
    const random = prng.random();
    var buffer: [16 << 10]u8 = undefined;
    for (fonts) |font| {
        for (0..300) |round| {
            const damaged = buffer[0..font.len];
            @memcpy(damaged, font);
            // Cut short, or bytes changed anywhere
            const cut = random.uintLessThan(u32, @intCast(font.len));
            const length = if (round % 3 == 0) cut else font.len;
            for (0..1 + random.uintLessThan(u32, 8)) |_| {
                damaged[random.uintLessThan(u32, @intCast(font.len))] = random.int(u8);
            }
            const info = truetype.init(damaged[0..length]) orelse continue;
            try test_draw_everything(&info);
        }
    }
}

fn test_draw_everything(info: *const truetype.Info) !void {
    assert(info.data.len > 0);
    assert(info.index_map != 0);
    const allocator = std.testing.allocator;

    for ([_]u32{ 'A', 'V', 'a', 'o', 'y', 0xf6, 0x1f600 }) |code_point| {
        const glyph = truetype.glyph_index(info, code_point);
        _ = truetype.horizontal_metrics(info, glyph);
        _ = truetype.kern_advance(info, glyph, truetype.glyph_index(info, 'V'));
        const scale = truetype.scale_for_pixel_height(info, 40);
        if (!std.math.isFinite(scale) or scale <= 0) return;
        const bitmap = try truetype.glyph_bitmap(info, allocator, scale, glyph);
        if (bitmap.pixels) |pixels| allocator.free(pixels);
    }
}
