//! Reading files out of a zip archive held in memory, as an EPUB is.
//! Only what EPUBs use: stored and deflated files, no encryption, no zip64.
const std = @import("std");

/// A zip entry's general-purpose flag bit 0: the entry is encrypted, unreadable here.
const flag_encrypted = 1;
const assert = std.debug.assert;

pub const Entry = struct {
    name: []const u8,
    method: u16, // 0 stored, 8 deflated
    data: []const u8, // The file's bytes as stored in the archive
    size: u32, // Its size once read
};

const method_stored = 0;
const method_deflated = 8;
/// An entry's size is 32 bits in a zip without zip64: the only limit on a file in a book.
pub const size_max = std.math.maxInt(u32);
/// Offsets in a zip without zip64 are 32 bits: an archive past them isn't one noface reads.
const archive_size_max = std.math.maxInt(u32);

const end_record_size = 22;
const end_comment_size_max = std.math.maxInt(u16);
const central_header_size = 46;
const local_header_size = 30;

comptime {
    assert(size_max <= std.math.maxInt(u32)); // An entry's size is a u32
    assert(std.zip.end_record_sig.len == 4);
    assert(std.zip.central_file_header_sig.len == 4);
    assert(std.zip.local_file_header_sig.len == 4);
    // Each record holds its signature and every field read from it
    assert(end_record_size >= 20);
    assert(central_header_size >= 46);
    assert(local_header_size >= 30);
}

/// The end-of-archive record: 22 bytes, maybe followed by a comment of up to 64 KB,
/// so it's searched for from the end. (Zig 0.17's own std.zip.findBuffer doesn't compile.)
fn end_record(data: []const u8) ?*const [end_record_size]u8 {
    if (data.len < end_record_size) return null;
    const highest = data.len - end_record_size;
    const lowest = data.len -| (end_record_size + end_comment_size_max);
    assert(lowest <= highest);
    for (0..highest - lowest + 1) |back| {
        const at = highest - back;
        assert(at >= lowest);
        if (std.mem.eql(u8, data[at..][0..4], &std.zip.end_record_sig)) {
            return data[at..][0..end_record_size];
        }
    }
    return null;
}

/// Every file in the archive, from its central directory.
pub fn entries(alloc: std.mem.Allocator, data: []const u8) ![]Entry {
    if (data.len > archive_size_max) return error.NotZip;
    const end = end_record(data) orelse return error.NotZip;
    const count = std.mem.readInt(u16, end[10..12], .little);
    const directory_size = std.mem.readInt(u32, end[12..16], .little);
    const directory_start = std.mem.readInt(u32, end[16..20], .little);
    if (directory_start > data.len) return error.Truncated;
    if (directory_size > data.len - directory_start) return error.Truncated;
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(alloc);
    // In 64 bits: the lengths after each header can carry it past the archive's end
    var at: u64 = directory_start;
    for (0..count) |_| {
        if (at + central_header_size > data.len) return error.Truncated;
        const header = data[@intCast(at)..];
        if (!std.mem.eql(u8, header[0..4], &std.zip.central_file_header_sig)) {
            return error.Truncated;
        }
        const name_length = std.mem.readInt(u16, header[28..30], .little);
        const extra_length = std.mem.readInt(u16, header[30..32], .little);
        const comment_length = std.mem.readInt(u16, header[32..34], .little);
        if (at + central_header_size + name_length > data.len) return error.Truncated;
        at += central_header_size + @as(u64, name_length) + extra_length + comment_length;
        const flags = std.mem.readInt(u16, header[8..10], .little);
        if (flags & flag_encrypted != 0) continue;
        const compressed = std.mem.readInt(u32, header[20..24], .little);
        const local = std.mem.readInt(u32, header[42..46], .little);
        const stored = entries_stored(data, local, compressed) orelse continue;
        try out.append(alloc, .{
            .name = header[central_header_size..][0..name_length],
            .method = std.mem.readInt(u16, header[10..12], .little),
            .data = stored,
            .size = std.mem.readInt(u32, header[24..28], .little),
        });
    }
    assert(out.items.len <= count);
    return out.toOwnedSlice(alloc);
}

/// A file's bytes as stored, after its local header, whose own name and extra lengths
/// can differ from the central directory's. Null when they don't lie in the archive.
fn entries_stored(data: []const u8, local: u32, compressed: u32) ?[]const u8 {
    assert(data.len <= archive_size_max);
    // In 64 bits: `local` comes from the file, and on the Kindle's 32-bit CPU an offset
    // near 4 GB plus the header would overflow
    if (@as(u64, local) + local_header_size > data.len) return null;
    const header = data[local..];
    if (!std.mem.eql(u8, header[0..4], &std.zip.local_file_header_sig)) return null;
    const name_length = std.mem.readInt(u16, header[26..28], .little);
    const extra_length = std.mem.readInt(u16, header[28..30], .little);
    const start = @as(u64, local) + local_header_size + name_length + extra_length;
    if (start > data.len) return null;
    if (compressed > data.len - start) return null;
    const stored = data[@intCast(start)..][0..compressed];
    assert(stored.len == compressed);
    return stored;
}

/// The file named `name`, if the archive holds one.
pub fn find(list: []const Entry, name: []const u8) ?Entry {
    for (list) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Whether the file is kept deflated, for `inflate`; else it's stored.
pub fn deflated(e: *const Entry) bool {
    assert(e.size <= size_max);
    assert(e.data.len <= archive_size_max);
    return e.method == method_deflated;
}

/// A stored file's bytes, in the archive itself: nothing is copied. Null for a file
/// deflated or kept some other way, or whose sizes don't agree.
pub fn stored_bytes(e: *const Entry) ?[]const u8 {
    assert(e.size <= size_max);
    assert(e.data.len <= archive_size_max);
    if (e.method != method_stored) return null;
    if (e.data.len != e.size) return null;
    return e.data;
}

/// A file's contents: a stored one's bytes in the archive, not a copy, or a deflated
/// one inflated into `alloc`.
pub fn read(alloc: std.mem.Allocator, e: *const Entry) ![]const u8 {
    assert(e.size <= size_max);
    const contents = switch (e.method) {
        method_stored => stored_bytes(e) orelse return error.Corrupt,
        method_deflated => try read_deflated(alloc, e),
        else => return error.Unsupported,
    };
    assert(contents.len == e.size);
    return contents;
}

fn read_deflated(alloc: std.mem.Allocator, e: *const Entry) ![]u8 {
    assert(e.method == method_deflated);
    assert(e.size <= size_max);
    const out = try alloc.alloc(u8, e.size);
    errdefer alloc.free(out);
    try inflate(e.data, out);
    return out;
}

/// Inflates raw deflate data that makes exactly `out.len` bytes, as a deflated file's
/// contents do: data that makes more or fewer is corrupt.
pub fn inflate(data: []const u8, out: []u8) !void {
    assert(data.len <= archive_size_max);
    assert(out.len <= size_max);
    var in: std.Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&in, .raw, &window);
    var writer: std.Io.Writer = .fixed(out);
    const inflated_size = decompress.reader.streamRemaining(&writer) catch return error.Corrupt;
    if (inflated_size != out.len) return error.Corrupt;
}

const sample = @embedFile("testdata/sample.zip");

test "stored and deflated files come out whole" {
    const alloc = std.testing.allocator;
    const list = try entries(alloc, sample);
    defer alloc.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    const mime = try read(alloc, &find(list, "mimetype").?);
    // Stored: the archive's own bytes, not a copy
    try std.testing.expect(mime.ptr == stored_bytes(&find(list, "mimetype").?).?.ptr);
    try std.testing.expectEqualStrings("application/epub+zip", mime);
    const text = try read(alloc, &find(list, "OEBPS/a.txt").?);
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "hello hello"));
    try std.testing.expectEqual(@as(usize, 35 * 3), text.len);
    try std.testing.expect(find(list, "nothing") == null);
}

test "random and broken archives are refused, never crash" {
    var prng = std.Random.DefaultPrng.init(0x7a6970);
    const random = prng.random();
    var buf: [1024]u8 = undefined;
    const alloc = std.testing.allocator;
    for (0..3000) |round| {
        const len = @min(sample.len, buf.len);
        @memcpy(buf[0..len], sample[0..len]);
        // Damage a few bytes of a real archive, so parsing gets deep before it breaks.
        for (0..1 + round % 6) |_| buf[random.uintLessThan(usize, len)] = random.int(u8);
        const list = entries(alloc, buf[0..len]) catch continue;
        defer alloc.free(list);
        for (list) |e| {
            const got = read(alloc, &e) catch continue;
            if (deflated(&e)) alloc.free(got);
        }
    }
}
