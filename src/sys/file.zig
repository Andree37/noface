//! Files: mapping one to read it, reading and writing small ones whole (a new one written
//! beside and renamed over, so a crash can't lose the old), appending, and copying.
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
    // usize: mmap's length is the address space's size
    const size = std.math.cast(usize, end) orelse return error.MmapFailed;
    if (size == 0) return error.EmptyFile;
    const address = linux.mmap(
        null,
        size,
        .{ .READ = true },
        // Shared: a write to the file later, in place, shows in the mapping (on every
        // system, where a private mapping's is unspecified)
        .{ .TYPE = .SHARED },
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

/// The size and change time of the file at `path`, or null when it isn't there.
pub fn facts_of(path: [*:0]const u8) ?linux.Facts {
    assert(path[0] != 0);
    return linux.facts_at(path);
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

/// A small file's contents, or nothing if it can't be read.
pub fn read_small(path: [*:0]const u8, buf: []u8) []const u8 {
    assert(path[0] != 0);
    assert(buf.len > 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Only read: nothing is lost if closing fails
    const n = linux.read(fd, buf.ptr, buf.len);
    if (failed(n)) return "";
    assert(n <= buf.len);
    return buf[0..n];
}

/// Writes beside the real file and renames, so a crash can't lose the old contents.
pub fn write_small(path: [*:0]const u8, data: []const u8) void {
    assert(path[0] != 0);
    assert(data.len <= std.math.maxInt(u32));
    write_parts(path, &.{data});
}

/// Writes `parts`, one after another, beside the real file and renames, as
/// `write_small`.
pub fn write_parts(path: [*:0]const u8, parts: []const []const u8) void {
    assert(path[0] != 0);
    assert(parts.len > 0);
    var tmp: [320]u8 = undefined;
    const name = std.mem.sliceTo(path, 0);
    const tmp_path = std.fmt.bufPrintSentinel(&tmp, "{s}.tmp", .{name}, 0) catch return;
    assert(std.mem.endsWith(u8, tmp_path, ".tmp")); // Beside the real file, never it
    const rc = linux.open(
        tmp_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (failed(rc)) return;
    const fd: i32 = @intCast(rc);
    var total: u64 = 0;
    const whole = for (parts) |part| {
        if (!write_all(fd, part)) break false;
        total += part.len;
    } else true;
    // A failed close may mean a short file: the rename below needs it whole
    const closed = !failed(linux.close(fd));
    // Never an empty file in place of the old one
    if (!whole or !closed or total == 0) return;
    _ = linux.rename(tmp_path, path); // Failed: the old file stays, whole
}

pub fn write_all(fd: i32, data: []const u8) bool {
    assert(fd >= 0);
    var done: u32 = 0;
    // Each write moves at least a byte, or fails
    while (done < data.len) {
        const wrote = linux.write(fd, data[done..].ptr, data.len - done);
        if (failed(wrote) or wrote == 0) return false;
        done += @intCast(wrote);
    }
    assert(done == data.len);
    return true;
}

/// The largest file `copy` copies: larger than any catalog.
const copy_bytes_max = 1 << 30;
const copy_chunk_bytes = 1 << 16;

comptime {
    assert(copy_bytes_max % copy_chunk_bytes == 0);
}

/// Copies the file at `source` to `target`, replacing it. False when it couldn't
/// be copied whole, in which case no partial copy is left.
pub fn copy_file(source: [*:0]const u8, target: [*:0]const u8) bool {
    assert(source[0] == '/');
    assert(target[0] == '/');
    const in_rc = linux.open(source, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(in_rc)) return false;
    const in: i32 = @intCast(in_rc);
    defer _ = linux.close(in); // Only read: nothing is lost if closing fails
    const out_flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const out_rc = linux.open(target, out_flags, 0o644);
    if (failed(out_rc)) return false;
    const out: i32 = @intCast(out_rc);
    var chunk: [copy_chunk_bytes]u8 = undefined;
    var copied: u64 = 0;
    const whole = for (0..copy_bytes_max / copy_chunk_bytes) |_| {
        const got = linux.read(in, &chunk, chunk.len);
        if (failed(got)) break false;
        if (got == 0) break true;
        if (!write_all(out, chunk[0..got])) break false;
        copied += got;
    } else false; // Larger than any catalog
    const closed = !failed(linux.close(out)); // A copy that can't be closed may be short
    if (!whole or !closed) _ = linux.unlink(target); // A partial copy goes
    assert(copied <= copy_bytes_max);
    return whole and closed;
}

/// Appends `text` to the file at `path`, as a shell's `echo text >> path` does.
pub fn append_file(path: [*:0]const u8, text: []const u8) void {
    assert(path[0] == '/');
    assert(text.len > 0);
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    };
    const rc = linux.open(path, flags, 0o644);
    if (failed(rc)) return; // A log line that can't be written is only a log line
    const fd: i32 = @intCast(rc);
    _ = write_all(fd, text); // Likewise
    _ = linux.close(fd); // Likewise
}
