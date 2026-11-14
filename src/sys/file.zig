//! Read-only memory mapping of a file, using raw Linux syscalls.
const std = @import("std");
const linux = @import("calls.zig");

pub fn map(path: [*:0]const u8) ![]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd > std.math.maxInt(usize) - 4096) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd)); // The mapping outlives it
    var end: i64 = 0;
    _ = linux.llseek(@intCast(fd), 0, &end, 2); // SEEK_END
    const size: usize = @intCast(end);
    if (size == 0) return error.EmptyFile;
    const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, @intCast(fd), 0);
    if (addr > std.math.maxInt(usize) - 4096) return error.MmapFailed;
    return @as([*]const u8, @ptrFromInt(addr))[0..size];
}

pub fn unmap(data: []const u8) void {
    _ = linux.munmap(data.ptr, data.len);
}

/// Whether `path` names something that can be read.
pub fn exists(path: [*:0]const u8) bool {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd > std.math.maxInt(usize) - 4096) return false;
    _ = linux.close(@intCast(fd));
    return true;
}

/// How many bytes `path` holds now, or 0 when it can't be opened.
pub fn size_of(path: [*:0]const u8) u64 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (fd > std.math.maxInt(usize) - 4096) return 0;
    defer _ = linux.close(@intCast(fd));
    var end: linux.off_t = 0;
    if (linux.llseek(@intCast(fd), 0, &end, linux.SEEK.END) > std.math.maxInt(usize) - 4096) return 0;
    return @intCast(end);
}
