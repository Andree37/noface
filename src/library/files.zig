//! The files the library keeps on the user drive, read and written through buffers of
//! fixed size the caller owns: never a whole file in memory, however many books.
//!
//! The user drive is a slow FUSE file system, so a file is written once, start to end,
//! beside the one it replaces, and renamed over it when whole. A file in use is never
//! cut short: it's replaced, so a reader holding the old one keeps reading the old one.
const std = @import("std");
const assert = std.debug.assert;
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const failed = @import("../sys/os.zig").failed;

/// The longest path the library names, as Linux's PATH_MAX.
pub const path_bytes_max: u32 = 4096;

/// Writes a file from start to end through `buffer`. A write that fails is remembered,
/// and `finish` reports it, so the caller checks once, at the end.
pub const Writer = struct {
    fd: i32,
    buffer: []u8,
    used: u32 = 0,
    size: u64 = 0, // Bytes written so far, those still in the buffer included
    broken: bool = false,

    /// A new, empty file at `path`, replacing any there.
    pub fn create(path: [*:0]const u8, buffer: []u8) !Writer {
        assert(path[0] != 0);
        assert(buffer.len > 0);
        const rc = calls.open(
            path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            0o644,
        );
        if (failed(rc)) return error.CantWrite;
        return .{ .fd = @intCast(rc), .buffer = buffer };
    }

    /// The file at `path`, kept as it is, to write on at its end.
    pub fn append(path: [*:0]const u8, buffer: []u8) !Writer {
        assert(path[0] != 0);
        assert(buffer.len > 0);
        const rc = calls.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true }, 0);
        if (failed(rc)) return error.CantWrite;
        const fd: i32 = @intCast(rc);
        const facts = calls.facts(fd) orelse {
            _ = calls.close(fd); // Ignored: nothing was written
            return error.CantWrite;
        };
        return .{ .fd = fd, .buffer = buffer, .size = facts.size };
    }

    pub fn write(w: *Writer, bytes: []const u8) void {
        assert(w.used <= w.buffer.len);
        if (bytes.len > w.buffer.len - w.used) w.flush();
        if (bytes.len > w.buffer.len) {
            // Larger than the buffer: straight through, after what was buffered
            if (!file.write_all(w.fd, bytes)) w.broken = true;
        } else {
            @memcpy(w.buffer[w.used..][0..bytes.len], bytes);
            w.used += @intCast(bytes.len);
        }
        w.size += bytes.len;
        assert(w.used <= w.buffer.len);
    }

    pub fn write_int(w: *Writer, comptime T: type, value: T) void {
        comptime assert(@typeInfo(T) == .int);
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        const size_before = w.size;
        w.write(&bytes);
        assert(w.size == size_before + @sizeOf(T));
    }

    fn flush(w: *Writer) void {
        assert(w.used <= w.buffer.len);
        if (w.used > 0 and !file.write_all(w.fd, w.buffer[0..w.used])) w.broken = true;
        w.used = 0;
    }

    /// Writes what's left and closes the file: its size, or an error if any write
    /// failed, in which case the file is partial and the caller removes it.
    pub fn finish(w: *Writer) !u64 {
        assert(w.fd >= 0); // Finished once
        w.flush();
        // A file that can't be closed may be short
        if (failed(calls.close(w.fd))) w.broken = true;
        w.fd = -1;
        if (w.broken) return error.CantWrite;
        assert(w.used == 0);
        return w.size;
    }

    /// After an error, closes the file unless `finish` already has (it closes it
    /// whether or not it fails), so it can be deferred over the whole of a write: the
    /// caller removes the file.
    pub fn abandon(w: *Writer) void {
        if (w.fd < 0) return; // Closed by `finish`
        _ = calls.close(w.fd); // Ignored: the file is removed, whole or not
        w.fd = -1;
    }
};

/// Reads a file through `buffer`: a range the buffer holds is served from it, and any
/// other is read in, starting where it starts. Reading on through a file, each part is
/// read from the drive once.
pub const Reader = struct {
    fd: i32,
    buffer: []u8,
    size: u64,
    start: u64 = 0, // Where in the file `buffer` begins
    len: u32 = 0, // How much of `buffer` holds the file

    pub fn open(path: [*:0]const u8, buffer: []u8) !Reader {
        assert(path[0] != 0);
        assert(buffer.len > 0);
        const rc = calls.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (failed(rc)) return error.CantRead;
        const fd: i32 = @intCast(rc);
        const facts = calls.facts(fd) orelse {
            _ = calls.close(fd); // Ignored: only read
            return error.CantRead;
        };
        return .{ .fd = fd, .buffer = buffer, .size = facts.size };
    }

    pub fn close(r: *Reader) void {
        assert(r.fd >= 0);
        _ = calls.close(r.fd); // Ignored: only read, so nothing is lost
        r.fd = -1;
        assert(r.fd < 0);
    }

    /// The `len` bytes at `offset`, valid until the next read. An error when they run
    /// past the file's end (a file cut short, which the caller treats as damaged) or
    /// can't be read.
    pub fn read_at(r: *Reader, offset: u64, len: u32) ![]const u8 {
        assert(len <= r.buffer.len);
        assert(r.fd >= 0);
        if (offset + len > r.size) return error.Truncated;
        const held = offset >= r.start and offset + len <= r.start + r.len;
        if (!held) try r.fill(offset);
        const at: u32 = @intCast(offset - r.start);
        assert(at + len <= r.len);
        return r.buffer[at..][0..len];
    }

    /// Reads into the buffer as much of the file as fits, from `offset`.
    fn fill(r: *Reader, offset: u64) !void {
        assert(offset <= r.size);
        const want: u32 = @intCast(@min(r.buffer.len, r.size - offset));
        r.len = 0;
        r.start = offset;
        // Each read moves at least a byte, or ends: a file shorter than it was is damaged
        while (r.len < want) {
            const position: i64 = @intCast(offset + r.len);
            const got = calls.pread(r.fd, r.buffer[r.len..want].ptr, want - r.len, position);
            if (failed(got) or got == 0) return error.CantRead;
            r.len += @intCast(got);
        }
        assert(r.len == want);
    }
};

/// Reads a text file a line at a time through a `Reader`. A line longer than the
/// buffer is passed over (and counted): none of noface's files has one.
pub const Lines = struct {
    reader: Reader,
    at: u64 = 0, // Where the next line starts
    skipped: u32 = 0, // Lines too long for the buffer, passed over

    /// The next line, without its line break, or null at the end. Valid until the next.
    pub fn next(l: *Lines) !?[]const u8 {
        assert(l.at <= l.reader.size);
        // Each pass reads a buffer further on, so this many reach the end
        const passes: u64 = l.reader.size / l.reader.buffer.len + 2;
        const passes_max: u32 = @intCast(@min(passes, std.math.maxInt(u32)));
        var long = false;
        for (0..passes_max) |_| {
            if (l.at == l.reader.size) return null;
            const want: u32 = @intCast(@min(l.reader.buffer.len, l.reader.size - l.at));
            const chunk = try l.reader.read_at(l.at, want);
            const end = std.mem.indexOfScalar(u8, chunk, '\n') orelse {
                const last = l.at + chunk.len == l.reader.size;
                l.at += chunk.len;
                if (last and !long) return chunk; // The last line, without a break
                long = true; // Longer than the buffer: on to its end
                continue;
            };
            l.at += end + 1;
            if (!long) return chunk[0..end];
            l.skipped += 1;
            long = false;
        }
        unreachable; // Each pass moved on by a buffer, or to a line's end
    }

    pub fn close(l: *Lines) void {
        assert(l.reader.fd >= 0);
        l.reader.close();
        assert(l.reader.fd < 0);
    }
};

/// Writes `bytes` over the file at `path` at `offset`, in place: for a record that
/// changed. False when it couldn't be written whole.
pub fn write_at(path: [*:0]const u8, offset: u64, bytes: []const u8) bool {
    assert(path[0] != 0);
    assert(bytes.len > 0);
    const rc = calls.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return false;
    const fd: i32 = @intCast(rc);
    const wrote = calls.pwrite(fd, bytes.ptr, bytes.len, @intCast(offset));
    const closed = !failed(calls.close(fd));
    return closed and !failed(wrote) and wrote == bytes.len;
}

/// "<dir>/<name>" in `buffer`.
pub fn path_in(buffer: []u8, dir: []const u8, name: []const u8) ![:0]u8 {
    assert(dir.len > 0);
    assert(name.len > 0);
    const path = try std.fmt.bufPrintSentinel(buffer, "{s}/{s}", .{ dir, name }, 0);
    assert(std.mem.endsWith(u8, path, name));
    return path;
}

/// Replaces the file at `target` with the one at `source`, whole, in one step.
pub fn replace(source: [*:0]const u8, target: [*:0]const u8) !void {
    assert(source[0] != 0);
    assert(target[0] != 0);
    if (failed(calls.rename(source, target))) return error.CantReplace;
}

/// Removes the file at `path`, if there is one.
pub fn remove(path: [*:0]const u8) void {
    assert(path[0] != 0);
    assert(path[0] == '/'); // Never relative to wherever noface happens to run
    _ = calls.unlink(path); // Ignored: one that isn't there is as good as removed
}

test "a file written through a small buffer reads back through another" {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/noface-files-{d}", .{
        calls.getpid(),
    }, 0);
    defer remove(path);
    var write_buffer: [7]u8 = undefined;
    var w = try Writer.create(path, &write_buffer);
    for (0..1000) |i| w.write_int(u32, @intCast(i));
    const large: [20]u8 = @splat(0xaa);
    w.write(&large); // Larger than the buffer
    try std.testing.expectEqual(@as(u64, 4020), try w.finish());
    var read_buffer: [64]u8 = undefined;
    var r = try Reader.open(path, &read_buffer);
    defer r.close();
    try std.testing.expectEqual(@as(u64, 4020), r.size);
    for ([_]u32{ 999, 0, 500, 501, 3 }) |i| {
        const bytes = try r.read_at(i * 4, 4);
        try std.testing.expectEqual(i, std.mem.readInt(u32, bytes[0..4], .little));
    }
    try std.testing.expectEqual(@as(u8, 0xaa), (try r.read_at(4019, 1))[0]);
    try std.testing.expectError(error.Truncated, r.read_at(4019, 2));
    try std.testing.expect(write_at(path, 0, &.{ 9, 0, 0, 0 }));
    r.len = 0; // What's buffered is from before the write
    try std.testing.expectEqual(@as(u8, 9), (try r.read_at(0, 1))[0]);
}
