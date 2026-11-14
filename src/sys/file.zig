//! Read-only memory mapping of a file, using raw Linux syscalls.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("calls.zig");
const failed = @import("os.zig").failed;

pub fn map(path: [*:0]const u8) ![]const u8 {
    assert(path[0] != 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(fd)) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd)); // The mapping outlives it
    var end: linux.off_t = 0;
    _ = linux.llseek(@intCast(fd), 0, &end, linux.SEEK.END); // Failed: `end` stays 0, empty
    // A file larger than the address space (4 GB on the Kindle) can't be mapped whole
    const size = std.math.cast(usize, end) orelse return error.MmapFailed;
    if (size == 0) return error.EmptyFile;
    const address = linux.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        @intCast(fd),
        0,
    );
    if (failed(address)) return error.MmapFailed;
    assert(std.mem.isAligned(address, std.heap.page_size_min)); // Mappings start on a page
    return @as([*]const u8, @ptrFromInt(address))[0..size];
}

pub fn unmap(data: []const u8) void {
    assert(data.len > 0); // `map` never maps an empty file
    const rc = linux.munmap(data.ptr, data.len);
    assert(!failed(rc)); // It was mapped whole, by `map`
}

/// Whether `path` names something that can be read.
pub fn exists(path: [*:0]const u8) bool {
    assert(path[0] != 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(fd)) return false;
    assert(fd <= std.math.maxInt(i32)); // A descriptor, as every call taking one expects
    _ = linux.close(@intCast(fd)); // Only opened to see that it could be
    return true;
}

/// How many bytes `path` holds now, or 0 when it can't be opened.
pub fn size_of(path: [*:0]const u8) u64 {
    assert(path[0] != 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(fd)) return 0;
    defer _ = linux.close(@intCast(fd));
    var end: linux.off_t = 0;
    if (failed(linux.llseek(@intCast(fd), 0, &end, linux.SEEK.END))) return 0;
    assert(end >= 0); // A file's end is never before its start
    return @intCast(end);
}
