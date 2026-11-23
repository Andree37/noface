//! Pictures in JPEG XR, decoded by the Kindle's own library through the jxr2pgm helper.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const failed = os.failed;
const process = @import("../sys/process.zig");

const jxr_helper = paths.jxr_helper;

const jxr_input = paths.jxr_input;

/// The bytes that start a JPEG XR file: "II", then the format's number.
const jpeg_xr_magic = "II\xbc\x01";

/// Room past the pixels for the PGM header the helper writes first.
const pgm_header_size_max = 64;

comptime {
    assert(jpeg_xr_magic.len == 4);
    // "P5\n", two numbers of at most ten digits with their separators, and "255\n".
    assert(pgm_header_size_max >= 3 + 2 * 11 + 4);
}

/// True for JPEG XR data, which most pictures in Kindle books are.
pub fn is_jpeg_xr(data: []const u8) bool {
    if (data.len <= jpeg_xr_magic.len) return false;
    return std.mem.eql(u8, data[0..jpeg_xr_magic.len], jpeg_xr_magic);
}

pub const Gray = struct { pixels: []u8, width: u32, height: u32 };

/// Decodes a JPEG XR picture with the Kindle's own decoder, through the helper,
/// which scales it to exactly `width` x `height`: the size it will be drawn.
pub fn decode_jpeg_xr(
    alloc: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) ?Gray {
    return decode_through(alloc, data, .{ .width = width, .height = height, .input = jxr_input });
}

/// What `decode_through` decodes to, and the file the picture is handed over in: the
/// one noface's own, a test's its own so tests running side by side don't share it.
const Through = struct { width: u32, height: u32, input: [:0]const u8 };

fn decode_through(alloc: std.mem.Allocator, data: []const u8, through: Through) ?Gray {
    assert(through.input.len > 0);
    const width = through.width;
    const height = through.height;
    const result = linux.open(
        through.input,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o600,
    );
    if (failed(result)) return null;
    // /tmp is RAM, shared with Amazon's services: a page-sized picture isn't left there
    defer _ = linux.unlink(through.input); // Ignored: gone already: nothing is left to free
    const written = linux.write(@intCast(result), data.ptr, data.len);
    // Ignored: the bytes are written; a close that fails loses nothing of them.
    _ = linux.close(@intCast(result));
    if (failed(written) or written != data.len) return null;
    const pixel_count = std.math.mul(u32, width, height) catch return null;
    const out_size = std.math.add(u32, pixel_count, pgm_header_size_max) catch return null;
    const out = alloc.alloc(u8, out_size) catch return null;
    var command_buffer: [160]u8 = undefined;
    const command_format = jxr_helper ++ " {d} {d} < {s}";
    const command = std.fmt.bufPrintSentinel(
        &command_buffer,
        command_format,
        .{ width, height, through.input },
        0,
    ) catch return null;
    assert(command.len < command_buffer.len); // Room for the sentinel
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const output_size = process.run(&argv, out) orelse return null;
    assert(output_size <= out.len);
    const gray = parse_pgm(out[0..output_size]) orelse return null;
    // Paired with parse_pgm: the pixels are exactly the picture.
    assert(gray.pixels.len == @as(u64, gray.width) * gray.height);
    return gray;
}

/// Reads "P5\n<w> <h>\n255\n<pixels>".
pub fn parse_pgm(data: []u8) ?Gray {
    var at: u32 = 0;
    var fields: [4][]const u8 = undefined;
    // Helper output never comes near 4 GB; past that, the header can't be read.
    if (data.len > std.math.maxInt(u32)) return null;
    for (&fields) |*f| {
        while (at < data.len and (data[at] == ' ' or data[at] == '\n')) at += 1;
        const start = at;
        while (at < data.len and data[at] != ' ' and data[at] != '\n') at += 1;
        f.* = data[start..at];
    }
    assert(at <= data.len);
    at += 1; // The one whitespace byte before the pixels
    if (!std.mem.eql(u8, fields[0], "P5")) return null;
    const width = std.fmt.parseInt(u32, fields[1], 10) catch return null;
    const height = std.fmt.parseInt(u32, fields[2], 10) catch return null;
    const size = std.math.mul(u32, width, height) catch return null;
    if (at > data.len or data.len - at < size) return null;
    const gray = Gray{ .pixels = data[at..][0..size], .width = width, .height = height };
    assert(gray.pixels.len == size);
    return gray;
}

test "the picture handed to the helper isn't left in /tmp, decoded or not" {
    var memory: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    // A size past any picture: given up on after the picture was written for the helper
    const side = std.math.maxInt(u32);
    var input_buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrintSentinel(&input_buffer, "/tmp/noface-picture-{d}.jxr", .{
        linux.getpid(),
    }, 0);
    const through: Through = .{ .width = side, .height = side, .input = input };
    try std.testing.expect(decode_through(fixed.allocator(), "II\xbc\x01 a", through) == null);
    const opened = linux.open(input, .{ .ACCMODE = .RDONLY }, 0);
    if (!failed(opened)) _ = linux.close(@intCast(opened)); // Only looked for
    try std.testing.expect(failed(opened));
}

test "helper output is read as a grayscale image" {
    var data = "P5\n2 2\n255\n\x00\x40\x80\xff".*;
    const g = parse_pgm(&data).?;
    try std.testing.expectEqual(@as(u32, 2), g.width);
    try std.testing.expectEqual(@as(u8, 0x80), g.pixels[2]);
    var short = "P5\n4 4\n255\nab".*;
    try std.testing.expect(parse_pgm(&short) == null);
    var huge = "P5\n4294967296 4294967296\n255\nab".*;
    try std.testing.expect(parse_pgm(&huge) == null);
    try std.testing.expect(is_jpeg_xr("II\xbc\x01\x20"));
    try std.testing.expect(!is_jpeg_xr("\xff\xd8\xff"));
}
