//! Reading files out of a zip archive held in memory, as an EPUB is.
//! Only what EPUBs use: stored and deflated files, no encryption, no zip64.
const std = @import("std");

pub const Entry = struct {
    name: []const u8,
    method: u16, // 0 stored, 8 deflated
    data: []const u8, // The file's bytes as stored in the archive
    size: u32, // Its size once read
};

const method_stored = 0;
const method_deflated = 8;
const max_size = 64 << 20; // Larger than any file a book should carry

/// The end-of-archive record: 22 bytes, maybe followed by a comment of up to 64 KB,
/// so it's searched for from the end. (Zig 0.17's own std.zip.findBuffer doesn't compile.)
fn end_record(data: []const u8) ?*const [22]u8 {
    if (data.len < 22) return null;
    var at = data.len - 22;
    const lowest = data.len -| (22 + 0xffff);
    while (true) : (at -= 1) {
        if (std.mem.eql(u8, data[at..][0..4], &std.zip.end_record_sig)) return data[at..][0..22];
        if (at == lowest) return null;
    }
}

/// Every file in the archive, from its central directory.
pub fn entries(alloc: std.mem.Allocator, data: []const u8) ![]Entry {
    const end = end_record(data) orelse return error.NotZip;
    const count: usize = std.mem.readInt(u16, end[10..12], .little);
    const dir_size: usize = std.mem.readInt(u32, end[12..16], .little);
    const dir_start: usize = std.mem.readInt(u32, end[16..20], .little);
    if (dir_start > data.len or dir_size > data.len - dir_start) return error.Truncated;
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(alloc);
    var at = dir_start;
    for (0..count) |_| {
        if (at + 46 > data.len or !std.mem.eql(u8, data[at..][0..4], &std.zip.central_file_header_sig)) return error.Truncated;
        const h = data[at..];
        const method = std.mem.readInt(u16, h[10..12], .little);
        const flags = std.mem.readInt(u16, h[8..10], .little);
        const compressed: usize = std.mem.readInt(u32, h[20..24], .little);
        const size = std.mem.readInt(u32, h[24..28], .little);
        const name_len: usize = std.mem.readInt(u16, h[28..30], .little);
        const extra_len: usize = std.mem.readInt(u16, h[30..32], .little);
        const comment_len: usize = std.mem.readInt(u16, h[32..34], .little);
        const local: usize = std.mem.readInt(u32, h[42..46], .little);
        if (at + 46 + name_len > data.len) return error.Truncated;
        const name = data[at + 46 ..][0..name_len];
        at += 46 + name_len + extra_len + comment_len;
        if (flags & 1 != 0) continue; // Encrypted
        // The data starts after the local header, whose own name and extra lengths can differ.
        if (local + 30 > data.len or !std.mem.eql(u8, data[local..][0..4], &std.zip.local_file_header_sig)) continue;
        const l = data[local..];
        const start = local + 30 + @as(usize, std.mem.readInt(u16, l[26..28], .little)) + std.mem.readInt(u16, l[28..30], .little);
        if (start > data.len or compressed > data.len - start) continue;
        try out.append(alloc, .{ .name = name, .method = method, .data = data[start..][0..compressed], .size = size });
    }
    return out.toOwnedSlice(alloc);
}

pub fn find(list: []const Entry, name: []const u8) ?Entry {
    for (list) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// A file's contents, inflated if it was deflated.
pub fn read(alloc: std.mem.Allocator, e: Entry) ![]u8 {
    if (e.size > max_size) return error.TooLarge;
    switch (e.method) {
        method_stored => {
            if (e.data.len != e.size) return error.Corrupt;
            return alloc.dupe(u8, e.data);
        },
        method_deflated => {
            const out = try alloc.alloc(u8, e.size);
            errdefer alloc.free(out);
            var in: std.Io.Reader = .fixed(e.data);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var inflate: std.compress.flate.Decompress = .init(&in, .raw, &window);
            var w: std.Io.Writer = .fixed(out);
            const n = inflate.reader.streamRemaining(&w) catch return error.Corrupt;
            if (n != e.size) return error.Corrupt;
            return out;
        },
        else => return error.Unsupported,
    }
}

const sample = @embedFile("testdata/sample.zip");

test "stored and deflated files come out whole" {
    const alloc = std.testing.allocator;
    const list = try entries(alloc, sample);
    defer alloc.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    const mime = try read(alloc, find(list, "mimetype").?);
    defer alloc.free(mime);
    try std.testing.expectEqualStrings("application/epub+zip", mime);
    const text = try read(alloc, find(list, "OEBPS/a.txt").?);
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
            const got = read(alloc, e) catch continue;
            alloc.free(got);
        }
    }
}
