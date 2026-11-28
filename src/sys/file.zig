//! Files: mapping one to read it, reading and writing small ones whole (a new one written
//! beside, onto the drive, and renamed over, so neither a crash nor a power cut can lose
//! the old), appending, and copying.
const std = @import("std");
const assert = std.debug.assert;
/// Lines for noface's log, which the tests keep quiet.
const log = std.log.scoped(.file);
const linux = @import("calls.zig");
const os = @import("os.zig");
const failed = os.failed;

/// The longest path noface names, as Linux's PATH_MAX.
pub const path_bytes_max: u32 = 4096;

/// Room for a path in one of noface's own folders, which are short: the folder, a slash
/// and a name noface gives the file. A book's own path may be longer (`path_bytes_max`).
pub const own_path_bytes_max = 320;

comptime {
    assert(own_path_bytes_max < path_bytes_max);
}

/// Why a file couldn't be mapped. Only `NotFound` and `EmptyFile` say there's nothing in
/// it; the others mean it may hold something that couldn't be read this time, which a
/// caller about to write over it must not take for nothing.
pub const MapError = error{ NotFound, OpenFailed, SeekFailed, EmptyFile, MmapFailed };

pub fn map(path: [*:0]const u8) MapError![]const u8 {
    assert(path[0] != 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(fd)) return if (os.not_found(fd)) error.NotFound else error.OpenFailed;
    defer _ = linux.close(@intCast(fd)); // Ignored: the mapping outlives it
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
    _ = linux.close(@intCast(fd)); // Ignored: only opened to see that it could be
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
    // Ignored: only read
    defer _ = linux.close(@intCast(fd));
    var end: linux.off_t = 0;
    if (failed(linux.llseek(@intCast(fd), 0, &end, linux.SEEK.END))) return 0;
    assert(end >= 0); // A file's end is never before its start
    return @intCast(end);
}

/// Why a small file wasn't read: there's none (`NotFound`, nothing to keep), or it's
/// there and may hold something this read couldn't get (`CantRead`), which a caller about
/// to write over it must never take for nothing.
pub const ReadError = error{ NotFound, CantRead };

/// A small file of noface's own: its start, as much as `buf` holds. noface writes such
/// a file sized to fit the buffer it's read back into, so one longer was damaged or
/// written by hand, and that's said in the log. A file that only grows, read for its
/// newest part, is read with `read_end`.
pub fn read_small(path: [*:0]const u8, buf: []u8) ReadError![]const u8 {
    const read = try read_start(path, buf);
    if (read.longer) {
        std.debug.print("{s}: longer than the {d} bytes read of it\n", .{ path, buf.len });
    }
    return read.text;
}

/// A file the system keeps (in /sys or /proc, a mark in /tmp): its text, as much as
/// `buf` holds, or nothing when it's missing or can't be read, which for such a file
/// says the same. Its length is the system's, so one longer than `buf` is no news.
pub fn read_system(path: [*:0]const u8, buf: []u8) []const u8 {
    const read = read_start(path, buf) catch return "";
    return read.text;
}

/// A file's start, as much as `buf` holds, and whether there's more past it.
fn read_start(path: [*:0]const u8, buf: []u8) ReadError!struct { text: []const u8, longer: bool } {
    assert(path[0] != 0);
    assert(buf.len > 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return if (os.not_found(rc)) error.NotFound else error.CantRead;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Ignored: only read: nothing is lost if closing fails
    const n = linux.read(fd, buf.ptr, buf.len);
    if (failed(n)) return error.CantRead;
    assert(n <= buf.len);
    var longer = false;
    if (n == buf.len) {
        var more: [1]u8 = undefined;
        const past = linux.pread(fd, &more, more.len, @intCast(buf.len));
        longer = !failed(past) and past > 0;
    }
    return .{ .text = buf[0..n], .longer = longer };
}

/// One of the reader's own files that noface reads and writes back whole: a book's
/// place, the settings, the reading speed. Missing, it's a new one. There but unreadable,
/// what it holds is unknown: written over, it would be lost for good, so it never is.
/// The rule lives here, with the file, so no caller decides it again.
pub const Kept = struct {
    path: [*:0]const u8,
    /// Whether what the file holds is known: every read so far read it, or found none.
    known: bool = true,

    pub fn at(path: [*:0]const u8) Kept {
        assert(path[0] != 0);
        return .{ .path = path };
    }

    /// Its text: nothing when there's none yet, or when it's there but unreadable, which
    /// leaves it unknown, never to be written over by this `Kept`.
    pub fn read(k: *Kept, buf: []u8) []const u8 {
        assert(buf.len > 0);
        return read_small(k.path, buf) catch |err| switch (err) {
            error.NotFound => "",
            error.CantRead => {
                log.info("{s}: there but unreadable, never written over", .{k.path});
                k.known = false;
                return "";
            },
        };
    }

    /// Its contents mapped (`map`), to be let go of with `unmap`: null when there's none,
    /// or when it's there but unreadable, which leaves it unknown, as `read` does.
    pub fn mapped(k: *Kept) ?[]const u8 {
        return map(k.path) catch |err| switch (err) {
            error.NotFound, error.EmptyFile => null,
            error.OpenFailed, error.SeekFailed, error.MmapFailed => {
                log.info("{s}: there but unreadable, never written over", .{k.path});
                k.known = false;
                return null;
            },
        };
    }

    /// Writes `parts` as the file's whole text, as `write_parts`, unless what it holds
    /// is unknown. Whether it was written, whole.
    pub fn write(k: *const Kept, parts: []const []const u8) bool {
        assert(parts.len > 0);
        if (!k.known) return false;
        return write_parts(k.path, parts);
    }
};

/// The end of a file that grows (a log), as much as `buf` holds, from a line's start:
/// its newest lines. Nothing if it can't be read.
pub fn read_end(path: [*:0]const u8, buf: []u8) []const u8 {
    assert(path[0] != 0);
    assert(buf.len > 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Ignored: only read: nothing is lost if closing fails
    var size: linux.off_t = 0;
    if (failed(linux.llseek(fd, 0, &size, linux.SEEK.END))) return "";
    const from: u64 = @as(u64, @intCast(size)) -| buf.len;
    const n = linux.pread(fd, buf.ptr, buf.len, @intCast(from));
    if (failed(n)) return "";
    assert(n <= buf.len);
    const read = buf[0..n];
    if (from == 0) return read; // The whole file
    // Cut into a line: from the next whole one
    const first = std.mem.indexOfScalar(u8, read, '\n') orelse return "";
    return read[first + 1 ..];
}

/// Writes beside the real file and renames, so a crash or a power cut can't lose the old
/// contents. Whether the new contents are the file's now, whole on the drive.
pub fn write_small(path: [*:0]const u8, data: []const u8) bool {
    assert(path[0] != 0);
    assert(data.len <= std.math.maxInt(u32));
    return write_parts(path, &.{data});
}

/// Writes `parts`, one after another, beside the real file and renames, as
/// `write_small`. The old file stays as it was unless the new one is whole on the drive.
/// Whether it is: false leaves the old one, and says nothing was saved.
pub fn write_parts(path: [*:0]const u8, parts: []const []const u8) bool {
    assert(path[0] != 0);
    assert(parts.len > 0);
    var tmp: [path_bytes_max + ".tmp".len]u8 = undefined;
    const name = std.mem.sliceTo(path, 0);
    const tmp_path = std.fmt.bufPrintSentinel(&tmp, "{s}.tmp", .{name}, 0) catch {
        log.info("not saved, its path is too long: {s}", .{name});
        return false;
    };
    assert(std.mem.endsWith(u8, tmp_path, ".tmp")); // Beside the real file, never it
    const rc = linux.open(
        tmp_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (failed(rc)) {
        log.info("not saved, its new copy couldn't be made: {s}", .{name});
        return false;
    }
    const fd: i32 = @intCast(rc);
    var total: u64 = 0;
    const whole = for (parts) |part| {
        if (!write_all(fd, part)) break false;
        total += part.len;
    } else true;
    // On the drive before the rename: renamed first, a power cut could leave the new
    // name over contents never written, and the old contents gone
    const synced = whole and !failed(linux.fsync(fd));
    // A failed close may mean a short file: the rename below needs it whole
    const closed = !failed(linux.close(fd));
    // Each way it can fail said, so a save lost leaves a line in the log. Never an
    // empty file in place of the old one
    const why: []const u8 = why: {
        if (!whole) break :why "the drive didn't take all of it";
        if (!synced) break :why "the drive didn't take it";
        if (!closed) break :why "its new copy didn't close";
        if (total == 0) break :why "it was empty";
        if (failed(linux.rename(tmp_path, path))) break :why "its new copy couldn't take its place";
        return true;
    };
    log.info("not saved, {s}: {s}", .{ why, name });
    // Not renamed: the old file stays, whole, and the partial new one goes
    _ = linux.unlink(tmp_path); // Ignored: one left over is only space, written over next time
    return false;
}

/// Writes all of `data` to `fd`, however many writes it takes. False when one fails.
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

/// Copies the file at `source` to `target`, replacing it: written beside it, onto the
/// drive, and renamed over, as `write_parts`, so a crash or a power cut leaves either
/// the old target or the whole copy, never part of one. False when it wasn't copied.
pub fn copy_file(source: [*:0]const u8, target: [*:0]const u8) bool {
    assert(source[0] == '/');
    assert(target[0] == '/');
    var tmp: [path_bytes_max + ".tmp".len]u8 = undefined;
    const name = std.mem.sliceTo(target, 0);
    const tmp_path = std.fmt.bufPrintSentinel(&tmp, "{s}.tmp", .{name}, 0) catch {
        return false; // Too long a path to have a file beside it
    };
    assert(std.mem.endsWith(u8, tmp_path, ".tmp")); // Beside the target, never it
    const in_rc = linux.open(source, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(in_rc)) return false;
    const in: i32 = @intCast(in_rc);
    defer _ = linux.close(in); // Ignored: only read, nothing is lost if closing fails
    const out_flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const out_rc = linux.open(tmp_path, out_flags, 0o644);
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
    } else false; // Larger than any file copied
    // On the drive before the rename, as `write_parts`
    const synced = whole and !failed(linux.fsync(out));
    const closed = !failed(linux.close(out)); // A copy that can't be closed may be short
    assert(copied <= copy_bytes_max);
    if (synced and closed and !failed(linux.rename(tmp_path, target))) return true;
    _ = linux.unlink(tmp_path); // Ignored: one left over is only space, written over next time
    return false;
}

/// Whether there's a file at a path: there, not there, or not known (it couldn't be
/// opened for another reason), which a caller about to write there takes as there.
pub const Presence = enum { here, absent, unknown };

pub fn presence(path: [*:0]const u8) Presence {
    assert(path[0] != 0);
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (os.not_found(fd)) return .absent;
    if (failed(fd)) return .unknown;
    _ = linux.close(@intCast(fd)); // Ignored: only opened to see that it could be
    return .here;
}

/// Adds `line` and its end at the end of the file at `path`, made if it isn't there:
/// on a line of its own, even after a last line a write cut short. Whether all of it
/// landed, closed whole.
pub fn append_line(path: [*:0]const u8, line: []const u8) bool {
    assert(path[0] == '/');
    assert(line.len > 0);
    assert(std.mem.indexOfScalar(u8, line, '\n') == null); // One line
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const rc = linux.open(path, flags, 0o644);
    if (failed(rc)) return false;
    const fd: i32 = @intCast(rc);
    var size: linux.off_t = 0;
    var ok = !failed(linux.llseek(fd, 0, &size, linux.SEEK.END));
    if (ok and size > 0) {
        var last: [1]u8 = undefined;
        const n = linux.pread(fd, &last, 1, @intCast(size - 1));
        ok = !failed(n) and n == 1;
        if (ok and last[0] != '\n') ok = write_all(fd, "\n"); // Ends the line cut short
    }
    if (ok) ok = write_all(fd, line);
    if (ok) ok = write_all(fd, "\n");
    // A close that fails can mean what was written didn't land
    const closed = !failed(linux.close(fd));
    return ok and closed;
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
    _ = linux.close(fd); // Ignored: likewise
}

/// "/tmp<between>/noface-file-<pid>-<name>" in `buffer`, gone from before.
fn test_path(buffer: []u8, between: []const u8, name: []const u8) ![:0]u8 {
    const format = "/tmp{s}/noface-file-{d}-{s}";
    const fields = .{ between, linux.getpid(), name };
    const path = try std.fmt.bufPrintSentinel(buffer, format, fields, 0);
    _ = linux.unlink(path); // Ignored: only there after a run that stopped
    return path;
}

test "a kept file there but unreadable is never written over; a missing one is new" {
    var buffer: [8]u8 = undefined;
    var path_buffer: [64]u8 = undefined;
    const format = "/tmp/noface-kept-{d}";
    const path = try std.fmt.bufPrintSentinel(&path_buffer, format, .{linux.getpid()}, 0);
    _ = linux.unlink(path); // Ignored: none there is what's wanted
    var missing = Kept.at(path);
    try std.testing.expectEqualStrings("", missing.read(&buffer));
    try std.testing.expect(missing.known); // None there: a new one, written freely
    // A link to itself is there but can't be opened, as on a drive failing a read
    try std.testing.expect(!failed(linux.symlink(path, path)));
    defer _ = linux.unlink(path); // Ignored: only /tmp is left fuller
    var unreadable = Kept.at(path);
    try std.testing.expectEqualStrings("", unreadable.read(&buffer));
    try std.testing.expect(!unreadable.write(&.{"over it"}));
    // Still the link: nothing was renamed over it
    try std.testing.expectError(error.CantRead, read_small(path, &buffer));
}

test "a small file missing and one there but unreadable are told apart" {
    var buffer: [8]u8 = undefined;
    var path_buffer: [64]u8 = undefined;
    const format = "/tmp/noface-read-small-{d}";
    const path = try std.fmt.bufPrintSentinel(&path_buffer, format, .{linux.getpid()}, 0);
    _ = linux.unlink(path); // Ignored: none there is what's wanted
    try std.testing.expectError(error.NotFound, read_small(path, &buffer));
    // A link to itself is there but can't be opened, as on a drive failing a read
    try std.testing.expect(!failed(linux.symlink(path, path)));
    defer _ = linux.unlink(path); // Ignored: only /tmp is left fuller
    try std.testing.expectError(error.CantRead, read_small(path, &buffer));
}

test "only a file that isn't there, or is empty, maps as nothing in it" {
    var buffer: [64]u8 = undefined;
    const path = try test_path(&buffer, "", "map");
    try std.testing.expectError(error.NotFound, map(path));
    try std.testing.expect(!write_small(path, "")); // Never an empty file in place
    try std.testing.expectError(error.NotFound, map(path));
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
    try std.testing.expect(write_small(path, "old"));
    var tmp_buffer: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&tmp_buffer, "{s}.tmp", .{path}, 0);
    try std.testing.expect(!failed(linux.symlink(tmp_path, tmp_path))); // Can't be opened
    defer _ = linux.unlink(tmp_path);
    // Said, as well as kept: the caller learns its save didn't happen
    try std.testing.expect(!write_parts(path, &.{ "new", " and more" }));
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
    try std.testing.expect(write_parts(path, &.{ "a", "b" }));
    const data = try map(path);
    defer unmap(data);
    try std.testing.expectEqualStrings("ab", data);
    var tmp_buffer: [path_bytes_max]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintSentinel(&tmp_buffer, "{s}.tmp", .{path}, 0);
    try std.testing.expect(!exists(tmp_path));
}
