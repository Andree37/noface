//! Files: mapping one to read it, reading and writing small ones whole (a new one written
//! beside, onto the drive, and renamed over, so neither a crash nor a power cut can lose
//! the old), appending, and copying.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("calls.zig");
const os = @import("os.zig");
const failed = os.failed;

/// The longest path noface names, as Linux's PATH_MAX.
pub const path_bytes_max: u32 = 4096;

/// Why a file couldn't be mapped. Only `NotFound` and `EmptyFile` say there's nothing in
/// it; the others mean it may hold something that couldn't be read this time, which a
/// caller about to write over it must not take for nothing.
pub const MapError = error{ NotFound, OpenFailed, SeekFailed, EmptyFile, MmapFailed };

pub fn map(path: [*:0]const u8) MapError![]const u8 {
    assert(path[0] != 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(fd)) return if (os.not_found(fd)) error.NotFound else error.OpenFailed;
    defer _ = linux.close(@intCast(fd)); // The mapping outlives it
    var end: linux.off_t = 0;
    if (failed(linux.llseek(@intCast(fd), 0, &end, linux.SEEK.END))) return error.SeekFailed;
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

/// Writes beside the real file and renames, so a crash or a power cut can't lose the old
/// contents.
pub fn write_small(path: [*:0]const u8, data: []const u8) void {
    assert(path[0] != 0);
    assert(data.len <= std.math.maxInt(u32));
    write_parts(path, &.{data});
}

/// Writes `parts`, one after another, beside the real file and renames, as
/// `write_small`. The old file stays as it was unless the new one is whole on the drive.
pub fn write_parts(path: [*:0]const u8, parts: []const []const u8) void {
    assert(path[0] != 0);
    assert(parts.len > 0);
    var tmp: [path_bytes_max + ".tmp".len]u8 = undefined;
    const name = std.mem.sliceTo(path, 0);
    const tmp_path = std.fmt.bufPrintSentinel(&tmp, "{s}.tmp", .{name}, 0) catch {
        std.debug.print("not saved, its path is too long: {s}\n", .{name});
        return;
    };
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
    // On the drive before the rename: renamed first, a power cut could leave the new
    // name over contents never written, and the old contents gone
    const synced = whole and !failed(linux.fsync(fd));
    if (whole and !synced) std.debug.print("not saved, the drive didn't take it: {s}\n", .{name});
    // A failed close may mean a short file: the rename below needs it whole
    const closed = !failed(linux.close(fd));
    // Never an empty file in place of the old one
    if (synced and closed and total > 0) {
        if (!failed(linux.rename(tmp_path, path))) return;
    }
    // Not renamed: the old file stays, whole, and the partial new one goes
    _ = linux.unlink(tmp_path); // Ignored: one left over is only space, written over next time
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

/// "/tmp<between>/noface-file-<pid>-<name>" in `buffer`, gone from before.
fn test_path(buffer: []u8, between: []const u8, name: []const u8) ![:0]u8 {
    const format = "/tmp{s}/noface-file-{d}-{s}";
    const fields = .{ between, linux.getpid(), name };
    const path = try std.fmt.bufPrintSentinel(buffer, format, fields, 0);
    _ = linux.unlink(path); // Ignored: only there after a run that stopped
    return path;
}

test "only a file that isn't there, or is empty, maps as nothing in it" {
    var buffer: [64]u8 = undefined;
    const path = try test_path(&buffer, "", "map");
    try std.testing.expectError(error.NotFound, map(path));
    write_small(path, "");
    try std.testing.expectError(error.NotFound, map(path)); // Never an empty file in place
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try std.testing.expect(!failed(rc));
    try std.testing.expect(!failed(linux.close(@intCast(rc))));
    try std.testing.expectError(error.EmptyFile, map(path));
    try std.testing.expect(!failed(linux.unlink(path)));
    // A link to itself is there but can't be opened, as on a drive that fails a read
    try std.testing.expect(!failed(linux.symlink(path, path)));
    defer _ = linux.unlink(path);
    try std.testing.expectError(error.OpenFailed, map(path));
}

test "a save that can't be written leaves the old file as it was" {
    var buffer: [64]u8 = undefined;
    const path = try test_path(&buffer, "", "save");
    defer _ = linux.unlink(path);
    write_small(path, "old");
    var tmp_buffer: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&tmp_buffer, "{s}.tmp", .{path}, 0);
    try std.testing.expect(!failed(linux.symlink(tmp_path, tmp_path))); // Can't be opened
    defer _ = linux.unlink(tmp_path);
    write_parts(path, &.{ "new", " and more" });
    const data = try map(path);
    defer unmap(data);
    try std.testing.expectEqualStrings("old", data);
}

test "a save to a long path is written, and leaves nothing beside it" {
    var buffer: [path_bytes_max]u8 = undefined;
    // Over 400 bytes, while no name in it is over the 255 a folder allows
    const between: [400]u8 = comptime blk: {
        var steps: [400]u8 = undefined;
        for (0..200) |i| steps[i * 2 ..][0..2].* = "/.".*;
        break :blk steps;
    };
    const path = try test_path(&buffer, &between, "long");
    try std.testing.expect(path.len > 400);
    defer _ = linux.unlink(path);
    write_parts(path, &.{ "a", "b" });
    const data = try map(path);
    defer unmap(data);
    try std.testing.expectEqualStrings("ab", data);
    var tmp_buffer: [path_bytes_max]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&tmp_buffer, "{s}.tmp", .{path}, 0);
    try std.testing.expect(!exists(tmp_path));
}
