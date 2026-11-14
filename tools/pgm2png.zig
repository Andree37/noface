//! Converts a PGM image (as noface-scenarios writes its snapshots) to an 8-bit gray PNG.
//!
//! Usage: pgm2png <in.pgm> <out.png>
//! Built for this computer by `zig build host-tools`, into zig-out/bin. Prints the
//! picture's width and height.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;

const png_signature = "\x89PNG\r\n\x1a\n";
/// The largest picture read: a few times the Kindle's screen.
const pgm_bytes_max = 64 << 20;
/// The widest and tallest picture taken: PNG allows 2^31 - 1, and the Kindle's screen
/// is under 2000 pixels each way.
const side_max = 1 << 16;

comptime {
    assert(png_signature.len == 8);
    assert(side_max * side_max >= pgm_bytes_max); // The byte limit is what binds
}

pub const Gray = struct { width: u32, height: u32, pixels: []const u8 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) {
        std.debug.print("usage: pgm2png <in.pgm> <out.png>\n", .{});
        std.process.exit(2);
    }
    assert(args.len == 3);
    const io = init.io;
    const pgm = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(pgm_bytes_max));
    const image = try parse_pgm(pgm);
    const png = try encode_png(gpa, image);
    assert(std.mem.startsWith(u8, png, png_signature));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = png });
    var line: [32]u8 = undefined;
    const size = try std.fmt.bufPrint(&line, "{d} {d}\n", .{ image.width, image.height });
    try std.Io.File.stdout().writeStreamingAll(io, size);
}

/// A binary PGM as noface writes it: "P5", the width and height, the largest value,
/// each on its own line, then a byte per pixel.
pub fn parse_pgm(data: []const u8) !Gray {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const kind = lines.next() orelse return error.NotPgm;
    if (!std.mem.eql(u8, kind, "P5")) return error.NotPgm;
    const size = lines.next() orelse return error.NotPgm;
    var numbers = std.mem.tokenizeScalar(u8, size, ' ');
    const width = try std.fmt.parseInt(u32, numbers.next() orelse return error.NotPgm, 10);
    const height = try std.fmt.parseInt(u32, numbers.next() orelse return error.NotPgm, 10);
    _ = lines.next() orelse return error.NotPgm; // The largest value: 255, a byte a pixel
    const pixels = lines.rest();
    if (width == 0 or height == 0) return error.NotPgm;
    if (width > side_max or height > side_max) return error.NotPgm;
    if (pixels.len < @as(u64, width) * height) return error.PixelsMissing;
    const image: Gray = .{
        .width = width,
        .height = height,
        .pixels = pixels[0 .. width * height],
    };
    assert(image.pixels.len == @as(u64, image.width) * image.height);
    return image;
}

/// The picture as a PNG: 8-bit gray, no interlace, each row unfiltered.
pub fn encode_png(gpa: std.mem.Allocator, image: Gray) ![]u8 {
    assert(image.width > 0);
    assert(image.pixels.len == @as(u64, image.width) * image.height);
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(gpa);
    for (0..image.height) |y| {
        try rows.append(gpa, 0); // Filter: none
        try rows.appendSlice(gpa, image.pixels[y * image.width ..][0..image.width]);
    }
    // Deflate writes through a buffer of at least 8 bytes
    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var zlib = try flate.Compress.init(&compressed.writer, window, .zlib, .level_6);
    try zlib.writer.writeAll(rows.items);
    try zlib.finish();

    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(gpa, png_signature);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8..13].* = .{ 8, 0, 0, 0, 0 }; // Bit depth 8, gray, deflate, no filter, no interlace
    try append_chunk(gpa, &png, "IHDR", &header);
    try append_chunk(gpa, &png, "IDAT", compressed.written());
    try append_chunk(gpa, &png, "IEND", "");
    return png.items;
}

/// One PNG chunk: its length, type, data, and the CRC of type and data.
fn append_chunk(
    gpa: std.mem.Allocator,
    png: *std.ArrayList(u8),
    kind: *const [4]u8,
    data: []const u8,
) !void {
    assert(png.items.len >= png_signature.len);
    if (data.len > std.math.maxInt(u31)) return error.ChunkTooLarge;
    const start = png.items.len;
    var number: [4]u8 = undefined;
    std.mem.writeInt(u32, &number, @intCast(data.len), .big);
    try png.appendSlice(gpa, &number);
    try png.appendSlice(gpa, kind);
    try png.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    std.mem.writeInt(u32, &number, crc.final(), .big);
    try png.appendSlice(gpa, &number);
    assert(png.items.len == start + 12 + data.len);
}

test "a PGM becomes a PNG holding the same pixels" {
    const gpa = std.testing.allocator;
    const pgm = "P5\n3 2\n255\n" ++ [_]u8{ 0, 128, 255, 10, 20, 30 };
    const image = try parse_pgm(pgm);
    try std.testing.expectEqual(@as(u32, 3), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const png = try encode_png(arena.allocator(), image);
    try std.testing.expect(std.mem.startsWith(u8, png, png_signature));
    // The last chunk is IEND, whose CRC every PNG shares
    try std.testing.expect(std.mem.endsWith(u8, png, "IEND\xae\x42\x60\x82"));
    // The image data inflates back to each row behind its filter byte
    const idat_length = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualStrings("IDAT", png[37..41]);
    var input: std.Io.Reader = .fixed(png[41..][0..idat_length]);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&input, .zlib, &window);
    var rows: [8]u8 = undefined;
    try inflate.reader.readSliceAll(&rows);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 255, 0, 10, 20, 30 }, &rows);
}

test "what isn't a whole PGM is refused" {
    try std.testing.expectError(error.NotPgm, parse_pgm("P6\n1 1\n255\nx"));
    try std.testing.expectError(error.PixelsMissing, parse_pgm("P5\n2 2\n255\nabc"));
    try std.testing.expectError(error.NotPgm, parse_pgm("P5\n0 2\n255\n"));
}
