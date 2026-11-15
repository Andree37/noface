//! Highlights and bookmarks of books Amazon doesn't sync, like EPUBs copied over the
//! cable, kept in a file beside the book's state. One line per record:
//! "<highlight|bookmark> <id> <start> <end>", with character positions like Amazon's.
const std = @import("std");
const assert = std.debug.assert;
const annotations = @import("../../kindle/annotations.zig");
const file = @import("../../sys/file.zig");
const linux = @import("../../sys/calls.zig");
const failed = @import("../../sys/os.zig").failed;

fn kind_name(kind: annotations.Kind) []const u8 {
    const name = switch (kind) {
        .highlight => "highlight",
        .bookmark => "bookmark",
    };
    // The first word of a line, so it can't hold the space between words
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, ' ') == null);
    return name;
}

/// The records of one kind as "id|start|end" lines, the shape the Kindle's database
/// gives, so highlights.parse and bookmarks.parse read both alike.
pub fn read(alloc: std.mem.Allocator, path: [*:0]const u8, kind: annotations.Kind) ![]const u8 {
    assert(std.mem.len(path) > 0);
    const data = file.map(path) catch return "";
    defer file.unmap(data);
    const lines = try select(alloc, data, kind);
    if (lines.len > 0) assert(lines[lines.len - 1] == '\n');
    return lines;
}

pub fn select(alloc: std.mem.Allocator, data: []const u8, kind: annotations.Kind) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, words.next() orelse continue, kind_name(kind))) continue;
        const id = words.next() orelse continue;
        const start = words.next() orelse continue;
        const end = words.next() orelse continue;
        try out.print(alloc, "{s}|{s}|{s}\n", .{ id, start, end });
    }
    // Each line loses its kind and keeps its id, positions and one separator per word
    assert(out.items.len <= data.len);
    if (out.items.len > 0) assert(out.items[out.items.len - 1] == '\n');
    return out.toOwnedSlice(alloc);
}

/// Saves a record, replacing any with the same id. True when the file was rewritten.
pub fn put(
    path: [*:0]const u8,
    kind: annotations.Kind,
    id: []const u8,
    start: u32,
    end: u32,
) bool {
    assert(std.mem.len(path) > 0);
    // Ids are made here or read back from this file a word at a time, so each is one word
    assert(id.len > 0);
    assert(std.mem.indexOfAny(u8, id, " \n") == null);
    return rewrite(path, id, .{ .kind = kind, .start = start, .end = end });
}

/// Removes a record. True when the file was rewritten, even if it wasn't there.
pub fn remove(path: [*:0]const u8, id: []const u8) bool {
    assert(std.mem.len(path) > 0);
    assert(id.len > 0);
    assert(std.mem.indexOfAny(u8, id, " \n") == null);
    return rewrite(path, id, null);
}

/// What a rewrite reads and writes at a time: any number of records stream through.
const chunk_bytes = 4096;
/// The longest line read as a record: a kind, an id and two positions, with room to
/// spare. A longer one is none of ours, and is kept as it is.
const line_bytes_max = 512;

comptime {
    assert(line_bytes_max <= chunk_bytes);
    // The longest kind and two positions leave most of a line for the id
    assert("highlight ".len + 2 * " 4294967295".len < line_bytes_max / 2);
}

const Record = struct { kind: annotations.Kind, start: u32, end: u32 };

/// Writes every record but `id`'s, then `record` if any, into "<path>.new" and renames
/// it over the old file: a crash leaves the old notes whole. Memory is the stack's,
/// however many notes the book has.
fn rewrite(path: [*:0]const u8, id: []const u8, record: ?Record) bool {
    assert(id.len > 0);
    var positions_buffer: [32]u8 = undefined;
    const positions = if (record) |r|
        std.fmt.bufPrint(&positions_buffer, " {d} {d}\n", .{ r.start, r.end }) catch
            return false
    else
        "";
    var new_buffer: [320]u8 = undefined;
    const name = std.mem.span(path);
    const new_path = std.fmt.bufPrintSentinel(&new_buffer, "{s}.new", .{name}, 0) catch
        return false;
    assert(std.mem.endsWith(u8, new_path, ".new")); // Beside the real file, never it
    const rc = linux.open(
        new_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (failed(rc)) return false;
    var out = Out{ .fd = @intCast(rc) };
    copy_others(&out, path, id) catch {
        out.failed = true;
    };
    if (record) |r| {
        out.add(kind_name(r.kind));
        out.add(" ");
        out.add(id);
        out.add(positions);
    }
    // An empty file reads as no notes, as does one blank line, which shows it was written
    if (out.bytes == 0) out.add("\n");
    out.flush();
    const closed = linux.close(out.fd);
    if (out.failed or failed(closed) or failed(linux.rename(new_path, path))) {
        _ = linux.unlink(new_path); // Failed: the old file stays, whole
        return false;
    }
    return true;
}

/// Copies the lines of the file at `path` that aren't `id`'s record to `out`, a chunk
/// at a time. No file is no records.
fn copy_others(out: *Out, path: [*:0]const u8, id: []const u8) !void {
    assert(id.len > 0);
    assert(!out.failed);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Only read: nothing is lost if closing fails
    var lines = Lines{ .id = id };
    var chunk: [chunk_bytes]u8 = undefined;
    // The file's chunks, and the read that finds its end: a count that fits a u32 for
    // any file the Kindle's drive could hold
    const reads_max: u32 = @intCast(@min(file.size_of(path) / chunk_bytes + 2, 1 << 31));
    for (0..reads_max) |_| {
        const count = linux.read(fd, &chunk, chunk.len);
        if (failed(count)) return error.ReadFailed;
        if (count == 0) {
            lines.end(out); // A last line without its newline
            return;
        }
        assert(count <= chunk.len);
        lines.split(out, chunk[0..count]);
    }
    // Grew as it was read: rather than cut it short, the old file stays
    return error.FileGrew;
}

/// The lines of the old file as they're read, each kept or dropped once it ends.
const Lines = struct {
    id: []const u8,
    line: [line_bytes_max]u8 = undefined,
    len: u32 = 0,
    long: bool = false, // Too long to be a record: going out as it comes

    /// A chunk of the file: whole lines, and the start or end of others.
    fn split(lines: *Lines, out: *Out, chunk: []const u8) void {
        assert(chunk.len > 0);
        assert(chunk.len <= chunk_bytes);
        var pieces = std.mem.splitScalar(u8, chunk, '\n');
        var piece = pieces.first();
        while (pieces.next()) |next| {
            lines.add(out, piece);
            lines.end(out);
            piece = next;
        }
        lines.add(out, piece); // Up to the chunk's end: its line goes on in the next
    }

    fn add(lines: *Lines, out: *Out, piece: []const u8) void {
        assert(std.mem.indexOfScalar(u8, piece, '\n') == null);
        assert(lines.len <= line_bytes_max);
        if (lines.long) return out.add(piece);
        if (lines.len + piece.len <= line_bytes_max) {
            @memcpy(lines.line[lines.len..][0..piece.len], piece);
            lines.len += @intCast(piece.len);
            return;
        }
        lines.long = true;
        out.add(lines.line[0..lines.len]);
        out.add(piece);
        lines.len = 0;
    }

    /// A line's end: kept, unless it's `id`'s record or has no id at all.
    fn end(lines: *Lines, out: *Out) void {
        assert(lines.len <= line_bytes_max);
        if (lines.long) assert(lines.len == 0); // Already gone out
        if (lines.long) {
            out.add("\n");
        } else if (keeps(lines.line[0..lines.len], lines.id)) {
            out.add(lines.line[0..lines.len]);
            out.add("\n");
        }
        lines.len = 0;
        lines.long = false;
    }
};

/// Whether a line stays when `id`'s record goes: it has an id, and another one.
fn keeps(line: []const u8, id: []const u8) bool {
    assert(id.len > 0);
    assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    _ = words.next(); // Its kind
    const own = words.next() orelse return false;
    return !std.mem.eql(u8, own, id);
}

/// The new file, written a chunk at a time. A failed write is kept, for the end.
const Out = struct {
    fd: i32,
    buffer: [chunk_bytes]u8 = undefined,
    len: u32 = 0,
    bytes: u64 = 0, // Added so far, written or not
    failed: bool = false,

    fn add(out: *Out, data: []const u8) void {
        assert(out.len < chunk_bytes); // Flushed whenever it fills
        const bytes_before = out.bytes;
        var rest = data;
        for (0..data.len / chunk_bytes + 2) |_| {
            if (rest.len == 0) break;
            const count: u32 = @intCast(@min(rest.len, chunk_bytes - out.len));
            @memcpy(out.buffer[out.len..][0..count], rest[0..count]);
            out.len += count;
            rest = rest[count..];
            if (out.len == chunk_bytes) out.flush();
        }
        assert(rest.len == 0);
        out.bytes = bytes_before + data.len;
    }

    fn flush(out: *Out) void {
        assert(out.len <= chunk_bytes);
        var written: u32 = 0;
        // Each write takes at least a byte, or fails
        for (0..chunk_bytes + 1) |_| {
            if (written == out.len or out.failed) break;
            const count = linux.write(out.fd, out.buffer[written..out.len].ptr, out.len - written);
            if (failed(count) or count == 0) {
                out.failed = true;
            } else {
                written += @intCast(count);
            }
        }
        assert(written == out.len or out.failed);
        out.len = 0;
    }
};

test "records come out by kind, in the database's shape" {
    const alloc = std.testing.allocator;
    const data = "highlight kindle.highlight-5 5 20\nbookmark kindle.bookmark-9 9 9\nbroken line\n";
    const h = try select(alloc, data, .highlight);
    defer alloc.free(h);
    try std.testing.expectEqualStrings("kindle.highlight-5|5|20\n", h);
    const b = try select(alloc, data, .bookmark);
    defer alloc.free(b);
    try std.testing.expectEqualStrings("kindle.bookmark-9|9|9\n", b);
}

/// A notes file for a test, in /tmp, named for this process and `name`.
fn test_path(buffer: []u8, name: []const u8) ![:0]const u8 {
    assert(name.len > 0);
    const format = "/tmp/noface-notes-test-{d}-{s}";
    const path = try std.fmt.bufPrintSentinel(buffer, format, .{ linux.getpid(), name }, 0);
    assert(std.mem.startsWith(u8, path, "/tmp/noface-notes-test-"));
    _ = linux.unlink(path); // Ignored: only a test's own file, left from before
    return path;
}

fn test_write(path: [*:0]const u8, data: []const u8) !void {
    assert(data.len > 0);
    assert(std.mem.startsWith(u8, std.mem.span(path), "/tmp/noface-notes-test-"));
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (failed(rc)) return error.CantWrite;
    defer _ = linux.close(@intCast(rc));
    if (linux.write(@intCast(rc), data.ptr, data.len) != data.len) return error.CantWrite;
}

fn test_expect_file(path: [*:0]const u8, want: []const u8) !void {
    assert(want.len > 0); // A rewrite never leaves the file empty
    const data = try file.map(path);
    defer file.unmap(data);
    try std.testing.expectEqualStrings(want, data);
    // Nothing left beside it
    var buffer: [128]u8 = undefined;
    const new_path = try std.fmt.bufPrintSentinel(&buffer, "{s}.new", .{std.mem.span(path)}, 0);
    try std.testing.expect(!file.exists(new_path));
}

test "replacing and removing keep every other record, however many there are" {
    const alloc = std.testing.allocator;
    var buffer: [96]u8 = undefined;
    const path = try test_path(&buffer, "many");
    defer _ = linux.unlink(path);
    // Many chunks' worth, so lines are cut across reads
    const count = 5000;
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(alloc);
    for (0..count) |i| try old.print(alloc, "highlight id-{d} {d} {d}\n", .{ i, i, i + 5 });
    try std.testing.expect(old.items.len > 20 * chunk_bytes);
    try test_write(path, old.items);
    try std.testing.expect(put(path, .bookmark, "id-2500", 7, 7));
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(alloc);
    for (0..count) |i| {
        if (i != 2500) try want.print(alloc, "highlight id-{d} {d} {d}\n", .{ i, i, i + 5 });
    }
    try want.appendSlice(alloc, "bookmark id-2500 7 7\n");
    try test_expect_file(path, want.items);
    // Removed: only that line goes
    try std.testing.expect(remove(path, "id-0"));
    try test_expect_file(path, want.items["highlight id-0 0 5\n".len..]);
}

test "a new file is made, odd lines are kept or dropped as before, and none is left empty" {
    var buffer: [96]u8 = undefined;
    const path = try test_path(&buffer, "odd");
    defer _ = linux.unlink(path);
    try std.testing.expect(put(path, .highlight, "a", 1, 2)); // No file yet
    try test_expect_file(path, "highlight a 1 2\n");
    // A line longer than any record is kept whole; one with no id, and blank ones, go;
    // the last line needs no newline
    const long = "note " ++ @as([line_bytes_max + 100]u8, @splat('x'));
    try test_write(path, "highlight a 1 2\n" ++ long ++ "\n\nlonely\nbookmark b 3 3");
    try std.testing.expect(remove(path, "a"));
    try test_expect_file(path, long ++ "\nbookmark b 3 3\n");
    try std.testing.expect(remove(path, "b"));
    try test_expect_file(path, long ++ "\n");
    try test_write(path, "bookmark b 3 3\n");
    try std.testing.expect(remove(path, "b"));
    try test_expect_file(path, "\n");
}
