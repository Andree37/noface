//! Pictures in JPEG XR, decoded by the Kindle's own library through the jxr2pgm helper.
const std = @import("std");
const paths = @import("paths.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const failed = os.failed;
const process = @import("../sys/process.zig");

const jxr_helper = paths.jxr_helper;

const jxr_input = paths.jxr_input;

/// True for JPEG XR data, which most pictures in Kindle books are.
pub fn isJpegXr(data: []const u8) bool {
    return data.len > 4 and data[0] == 'I' and data[1] == 'I' and data[2] == 0xbc and data[3] == 0x01;
}

pub const Gray = struct { pixels: []u8, width: usize, height: usize };

/// Decodes a JPEG XR picture with the Kindle's own decoder, through the helper,
/// which scales it to exactly `width` x `height`: the size it will be drawn.
pub fn decodeJpegXr(alloc: std.mem.Allocator, data: []const u8, width: usize, height: usize) ?Gray {
    const rc = linux.open(jxr_input, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (failed(rc)) return null;
    const written = linux.write(@intCast(rc), data.ptr, data.len);
    _ = linux.close(@intCast(rc));
    if (failed(written) or written != data.len) return null;
    const out = alloc.alloc(u8, width * height + 64) catch return null;
    var command_buf: [160]u8 = undefined;
    const command = std.fmt.bufPrintSentinel(&command_buf, jxr_helper ++ " {d} {d} < " ++ jxr_input, .{ width, height }, 0) catch return null;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const n = process.run(&argv, out) orelse return null;
    return parsePgm(out[0..n]);
}

/// Reads "P5\n<w> <h>\n255\n<pixels>".
pub fn parsePgm(data: []u8) ?Gray {
    var at: usize = 0;
    var fields: [4][]const u8 = undefined;
    for (&fields) |*f| {
        while (at < data.len and (data[at] == ' ' or data[at] == '\n')) at += 1;
        const start = at;
        while (at < data.len and data[at] != ' ' and data[at] != '\n') at += 1;
        f.* = data[start..at];
    }
    at += 1; // The one whitespace byte before the pixels
    if (!std.mem.eql(u8, fields[0], "P5")) return null;
    const w = std.fmt.parseInt(usize, fields[1], 10) catch return null;
    const h = std.fmt.parseInt(usize, fields[2], 10) catch return null;
    if (at > data.len or data.len - at < w * h) return null;
    return .{ .pixels = data[at..][0 .. w * h], .width = w, .height = h };
}

test "helper output is read as a grayscale image" {
    var data = "P5\n2 2\n255\n\x00\x40\x80\xff".*;
    const g = parsePgm(&data).?;
    try std.testing.expectEqual(@as(usize, 2), g.width);
    try std.testing.expectEqual(@as(u8, 0x80), g.pixels[2]);
    var short = "P5\n4 4\n255\nab".*;
    try std.testing.expect(parsePgm(&short) == null);
    try std.testing.expect(isJpegXr("II\xbc\x01\x20"));
    try std.testing.expect(!isJpegXr("\xff\xd8\xff"));
}
