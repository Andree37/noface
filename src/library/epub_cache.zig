//! What the library shows of each EPUB (title, author, series), read from the book once
//! and kept in the data folder, so the library doesn't open and parse every EPUB each
//! time it loads (tens of milliseconds each, minutes for thousands). An EPUB is known by
//! its path, size and change time: change any, and it's read again.
//!
//! Two files, written afresh at each load from what was found, so books gone are
//! dropped: `epubs.tsv`, one line per EPUB, and `epubs.idx`, a header and then each
//! line's (path hash, place) sorted by hash, looked up by binary search. Both are read
//! and written through fixed buffers; the index is sorted in runs on the drive when
//! it's larger than memory.
const std = @import("std");
const assert = std.debug.assert;
const files = @import("files.zig");
const sorter = @import("sorter.zig");
const calls = @import("../sys/calls.zig");

/// What the library keeps of an EPUB. Its text points into the cache's buffers, valid
/// until the next `find`.
pub const About = struct {
    title: []const u8,
    author: []const u8,
    series: []const u8,
    series_index: f32,
    has_cover: bool, // Its cover was saved beside its state once
};

/// The longest title, author or series kept: the library cuts them to this anyway.
pub const text_bytes_max: u32 = 256;
/// The longest line: a path, three texts, four numbers, seven tabs and a line break.
pub const line_bytes_max: u32 = files.path_bytes_max + 3 * text_bytes_max + 4 * 24 + 8;

/// The highest place in a series kept: the largest whole number an f32 holds exactly.
const index_max: f32 = 1 << 24;

const lines_name = "epubs.tsv";
const index_name = "epubs.idx";
const magic = "NFEPUB01";
const header_bytes: u32 = 24; // The magic, the count of lines, the lines file's size
const entry_bytes: u32 = 16; // A path's hash, then where its line is and how long

comptime {
    assert(magic.len == 8);
    assert(line_bytes_max < 1 << 16); // A line's length fits in an entry's low 16 bits
}

/// The cache's buffers: the caller's, reused.
pub const Memory = struct {
    sort: sorter.Memory,
    lines_out: []u8, // For writing lines
    index_in: []u8, // For the binary search: a few entries at a time
    lines_in: []u8, // One line at least

    pub fn invariants(m: *const Memory) void {
        assert(m.lines_in.len >= line_bytes_max);
        assert(m.index_in.len >= entry_bytes);
        assert(m.lines_out.len > 0);
    }
};

pub const Cache = struct {
    memory: *const Memory,
    dir: []const u8,
    old_index: ?files.Reader = null,
    old_lines: ?files.Reader = null,
    old_count: u32 = 0,
    new_lines: ?files.Writer = null, // Null when the new cache can't be written
    sort: sorter.Sorter,

    /// The cache in `dir`, the old one read and a new one begun. Never fails: an old
    /// cache missing or damaged is an empty one, and a new one that can't be written
    /// leaves the old as it was.
    pub fn open(memory: *const Memory, dir: []const u8) Cache {
        memory.invariants();
        assert(dir.len > 0);
        var c: Cache = .{ .memory = memory, .dir = dir, .sort = .init(&memory.sort, dir, "epubs") };
        c.open_old();
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        if (files.path_in(&path_buffer, dir, lines_name ++ ".new")) |path| {
            c.new_lines = files.Writer.create(path, memory.lines_out) catch null;
        } else |_| {}
        if (c.old_index == null) assert(c.old_count == 0);
        return c;
    }

    fn open_old(c: *Cache) void {
        assert(c.old_index == null);
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const index_path = files.path_in(&path_buffer, c.dir, index_name) catch return;
        var index = files.Reader.open(index_path, c.memory.index_in) catch return;
        const lines_path = files.path_in(&path_buffer, c.dir, lines_name) catch {
            index.close();
            return;
        };
        var lines = files.Reader.open(lines_path, c.memory.lines_in) catch {
            index.close();
            return;
        };
        const count = old_count_checked(&index, lines.size) orelse {
            index.close();
            lines.close();
            return;
        };
        c.old_index = index;
        c.old_lines = lines;
        c.old_count = count;
        assert(c.old_index.?.size == header_bytes + count * entry_bytes);
    }

    /// The old cache's count of lines, or null when its index doesn't belong with its
    /// lines (a crash between writing the two, or a damaged file).
    // Assertions: it reads the cache's header, from a file on the user drive: outside data.
    fn old_count_checked(index: *files.Reader, lines_size: u64) ?u32 {
        assert(index.fd >= 0);
        const header = index.read_at(0, header_bytes) catch return null;
        if (!std.mem.eql(u8, header[0..8], magic)) return null;
        const count = std.mem.readInt(u64, header[8..16], .little);
        const size = std.mem.readInt(u64, header[16..24], .little);
        if (size != lines_size) return null;
        if (count > (index.size - header_bytes) / entry_bytes) return null;
        if (index.size != header_bytes + count * entry_bytes) return null;
        if (count > sorter.items_max) return null; // More than this cache ever writes
        return @intCast(count);
    }

    /// What the old cache knows of the EPUB at `path` with these `facts`, or null when
    /// it doesn't, or the book changed since.
    pub fn find(c: *Cache, path: []const u8, facts: calls.Facts) ?About {
        assert(path.len > 0);
        const index = if (c.old_index) |*i| i else return null;
        const key = key_of(path);
        var low: u32 = 0;
        var high: u32 = c.old_count;
        // The first entry whose hash isn't below the key: halves each time round
        for (0..64) |_| {
            if (low == high) break;
            const middle = low + (high - low) / 2;
            const entry = c.entry_at(index, middle) orelse return null;
            if (entry.key < key) low = middle + 1 else high = middle;
        }
        assert(low <= c.old_count);
        // Paths can share a hash: each with it is looked at, and at most every entry
        for (low..c.old_count) |at| {
            const entry = c.entry_at(index, @intCast(at)) orelse return null;
            if (entry.key != key) return null;
            const line = c.old_line(entry.place) orelse return null;
            if (!std.mem.eql(u8, line.path, path)) continue;
            if (line.size != facts.size or line.modified_s != facts.modified_s) return null;
            return line.about;
        }
        return null;
    }

    const Entry = struct { key: u64, place: u64 };

    fn entry_at(c: *Cache, index: *files.Reader, at: u32) ?Entry {
        assert(at < c.old_count);
        const offset = header_bytes + @as(u64, at) * entry_bytes;
        const bytes = index.read_at(offset, entry_bytes) catch
            return null;
        const result: Entry = .{
            .key = std.mem.readInt(u64, bytes[0..8], .little),
            .place = std.mem.readInt(u64, bytes[8..16], .little),
        };
        assert(result.place == std.mem.readInt(u64, bytes[8..16], .little));
        return result;
    }

    fn old_line(c: *Cache, place: u64) ?Line {
        const lines = if (c.old_lines) |*l| l else return null;
        assert(c.old_count > 0);
        const len: u32 = @intCast(place & 0xffff);
        if (len == 0 or len > line_bytes_max) return null;
        const bytes = lines.read_at(place >> 16, len) catch return null;
        assert(bytes.len == len);
        return parse_line(bytes);
    }

    /// Keeps `about` for the EPUB at `path` in the new cache.
    pub fn add(c: *Cache, path: []const u8, facts: calls.Facts, about: About) void {
        assert(path.len > 0);
        const w = if (c.new_lines) |*w| w else return;
        const start = w.size;
        write_field(w, path);
        var numbers: [64]u8 = undefined;
        // Two numbers of 20 characters at most, then a float under 2^24 and a digit:
        // the buffer holds either
        const sizes = std.fmt.bufPrint(&numbers, "\t{d}\t{d}\t", .{
            facts.size,
            facts.modified_s,
        }) catch return;
        w.write(sizes);
        write_field(w, clip(about.title));
        w.write("\t");
        write_field(w, clip(about.author));
        w.write("\t");
        write_field(w, clip(about.series));
        const finite = std.math.isFinite(about.series_index);
        const index = if (finite) std.math.clamp(about.series_index, 0, index_max) else 0;
        const tail = std.fmt.bufPrint(&numbers, "\t{d}\t{d}\n", .{
            index,
            @intFromBool(about.has_cover),
        }) catch return;
        w.write(tail);
        const len = w.size - start;
        assert(len > path.len); // The path, and the fields after it
        if (len > line_bytes_max) return; // A path longer than any Linux allows: not kept
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, key_of(path), .big);
        c.sort.add(&key, start << 16 | len) catch {
            c.drop_new();
        };
    }

    /// Writes the new cache's index and puts both files in place of the old ones.
    pub fn finish(c: *Cache) void {
        c.close_old();
        assert(c.old_index == null); // Read no more: the new one replaces it
        const w = if (c.new_lines) |*w| w else return;
        const lines_size = w.finish() catch {
            c.new_lines = null;
            c.drop_new();
            return;
        };
        c.new_lines = null;
        c.write_index(lines_size) catch {
            c.drop_new();
            return;
        };
        var from: [files.path_bytes_max]u8 = undefined;
        var to: [files.path_bytes_max]u8 = undefined;
        // The lines first: an index that doesn't match them is found out, and ignored
        for ([_][]const u8{ lines_name, index_name }) |name| {
            const new = std.fmt.bufPrintSentinel(&from, "{s}/{s}.new", .{ c.dir, name }, 0) catch
                return;
            const target = files.path_in(&to, c.dir, name) catch return;
            files.replace(new, target) catch return;
        }
        assert(c.new_lines == null);
    }

    fn write_index(c: *Cache, lines_size: u64) !void {
        assert(c.new_lines == null);
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try files.path_in(&path_buffer, c.dir, index_name ++ ".new");
        var w = try files.Writer.create(path, c.memory.lines_out);
        w.write(magic);
        w.write_int(u64, c.sort.items_total);
        w.write_int(u64, lines_size);
        c.sort.finish(&w, write_entry) catch |err| {
            w.abandon();
            return err;
        };
        const size = try w.finish();
        assert(size == header_bytes + c.sort.items_total * entry_bytes);
    }

    fn write_entry(w: *files.Writer, key: []const u8, value: u64) !void {
        assert(key.len == 8);
        assert(value & 0xffff > 0); // Every line has a length
        w.write_int(u64, std.mem.readInt(u64, key[0..8], .big));
        w.write_int(u64, value);
    }

    /// Gives up on the new cache: the old one stays as it was.
    fn drop_new(c: *Cache) void {
        if (c.new_lines) |*w| w.abandon();
        c.new_lines = null;
        c.sort.discard();
        assert(c.sort.runs_first == c.sort.runs_end); // No run left behind
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        for ([_][]const u8{ lines_name ++ ".new", index_name ++ ".new" }) |name| {
            files.remove(files.path_in(&path_buffer, c.dir, name) catch continue);
        }
        assert(c.new_lines == null);
    }

    fn close_old(c: *Cache) void {
        if (c.old_index) |*i| i.close();
        if (c.old_lines) |*l| l.close();
        c.old_index = null;
        c.old_lines = null;
        assert(c.old_index == null);
        assert(c.old_lines == null);
    }
};

const Line = struct { path: []const u8, size: u64, modified_s: i64, about: About };

/// A line of the cache, or null when it isn't one (a damaged file).
// Assertions: it reads a line of a file on the user drive: outside data.
fn parse_line(bytes: []const u8) ?Line {
    assert(bytes.len > 0);
    if (bytes[bytes.len - 1] != '\n') return null;
    var fields = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], '\t');
    const path = fields.next() orelse return null;
    const size = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    const modified = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch
        return null;
    const title = fields.next() orelse return null;
    const author = fields.next() orelse return null;
    const series = fields.next() orelse return null;
    const index = std.fmt.parseFloat(f32, fields.next() orelse return null) catch return null;
    const cover = fields.next() orelse return null;
    if (fields.next() != null or path.len == 0 or !std.math.isFinite(index)) return null;
    const about: About = .{
        .title = title,
        .author = author,
        .series = series,
        .series_index = index,
        .has_cover = std.mem.eql(u8, cover, "1"),
    };
    return .{ .path = path, .size = size, .modified_s = modified, .about = about };
}

/// Writes `text` as one field: a tab or line break in it (outside data) becomes a space.
fn write_field(w: *files.Writer, text: []const u8) void {
    assert(text.len <= files.path_bytes_max);
    var start: u32 = 0;
    for (text, 0..) |c, i| {
        if (c != '\t' and c != '\n' and c != '\r') continue;
        w.write(text[start..i]);
        w.write(" ");
        start = @intCast(i + 1);
    }
    w.write(text[start..]);
    assert(start <= text.len);
}

/// `text` cut to `text_bytes_max` bytes, at a whole UTF-8 character.
pub fn clip(text: []const u8) []const u8 {
    if (text.len <= text_bytes_max) return text;
    var end = text_bytes_max;
    // A character is at most four bytes: at most three to step back over
    for (0..3) |_| {
        if (text[end] & 0xc0 != 0x80) break; // Not a character's continuation
        end -= 1;
    }
    assert(end <= text_bytes_max);
    assert(end + 3 >= text_bytes_max);
    return text[0..end];
}

/// A path as a number, for finding its line.
fn key_of(path: []const u8) u64 {
    assert(path.len > 0);
    const key = std.hash.Wyhash.hash(0x65707562, path);
    assert(std.hash.Wyhash.hash(0x65707562, path) == key);
    return key;
}

/// Buffers for a cache, from `alloc`, for the tests.
fn test_memory(alloc: std.mem.Allocator, items_bytes: u32) !Memory {
    assert(items_bytes >= sorter.key_bytes_max + 10);
    const inputs = try alloc.alloc([]u8, 2);
    for (inputs) |*input| input.* = try alloc.alloc(u8, 4096);
    assert(inputs.len == 2);
    return .{
        .sort = .{
            .items = try alloc.alloc(u8, items_bytes),
            .offsets = try alloc.alloc(u32, 1024),
            .inputs = inputs,
            .output = try alloc.alloc(u8, 4096),
        },
        .lines_out = try alloc.alloc(u8, 4096),
        .index_in = try alloc.alloc(u8, 256),
        .lines_in = try alloc.alloc(u8, line_bytes_max),
    };
}

test "an EPUB read once is found again by its path, size and change time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory = try test_memory(arena.allocator(), sorter.key_bytes_max + 100);
    var dir_buffer: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buffer, "/tmp/noface-epub-cache-{d}", .{
        calls.getpid(),
    }, 0);
    _ = calls.mkdir(dir, 0o755); // Ignored: a folder that can't be made fails the test below
    var names: [300][40]u8 = undefined;
    var c = Cache.open(&memory, dir);
    for (&names, 0..) |*name, i| {
        const path = try std.fmt.bufPrint(name, "/d/Book {d}.epub", .{i});
        const facts: calls.Facts = .{ .size = i, .modified_s = @intCast(1000 + i) };
        c.add(path, facts, .{
            .title = "A\ttitle",
            .author = "An Author",
            .series = if (i % 2 == 0) "Saga" else "",
            .series_index = @floatFromInt(i),
            .has_cover = i % 3 == 0,
        });
    }
    c.finish();
    var again = Cache.open(&memory, dir);
    for (0..300) |i| {
        const path = std.mem.sliceTo(&names[i], '.');
        const facts: calls.Facts = .{ .size = i, .modified_s = @intCast(1000 + i) };
        const full = names[i][0 .. path.len + ".epub".len];
        const about = again.find(full, facts) orelse return error.NotFound;
        try std.testing.expectEqualStrings("An Author", about.author);
        try std.testing.expectEqualStrings("A title", about.title); // Its tab a space
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), about.series_index);
        try std.testing.expectEqual(i % 3 == 0, about.has_cover);
        // A book changed since is read again
        try std.testing.expect(again.find(full, .{ .size = i + 1, .modified_s = 0 }) == null);
    }
    try std.testing.expect(again.find("/d/none.epub", .{ .size = 0, .modified_s = 0 }) == null);
    again.finish(); // Nothing added: the next cache is empty
    var empty = Cache.open(&memory, dir);
    try std.testing.expectEqual(@as(u64, 0), empty.old_count);
    empty.finish();
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", dir };
    var out: [64]u8 = undefined;
    _ = @import("../sys/process.zig").run(&argv, &out); // Ignored: only /tmp is left fuller
}
