//! Looking words up in noface's own dictionary files, built from Wiktionary by
//! tools/build_dictionary.py. A file is:
//!
//!   "NFDICT1\n", then the entry count as u32, then count + 1 offsets as u32 (all
//!   little-endian), then the entries back to back. Entry i runs from offsets[i] to
//!   offsets[i + 1] in the part after the offsets: its key, a zero byte, the word as
//!   written, a zero byte, then lines of definition.
//!
//! Keys are folded (lowercase, accents off, as search folds them) and sorted, so a
//! lookup is a binary search. A definition line is a part of speech ("noun"), a
//! numbered sense ("1 a large house"), or "=run", meaning "see run too".
const std = @import("std");
const search = @import("search.zig");

pub const magic = "NFDICT1\n";

pub const Entry = struct {
    word: []const u8, // As the dictionary writes it, like "Polish"
    text: []const u8, // Its definition lines

    /// The word this one is a form of, from a "=run" line, if any.
    pub fn base_form(e: Entry) ?[]const u8 {
        var lines = std.mem.tokenizeScalar(u8, e.text, '\n');
        while (lines.next()) |l| {
            if (l.len > 1 and l[0] == '=') return l[1..];
        }
        return null;
    }
};

pub const Dictionary = struct {
    data: []const u8,
    count: u32,

    /// Checks the header of a mapped file. Null when it isn't a dictionary.
    pub fn open(data: []const u8) ?Dictionary {
        if (data.len < magic.len + 4 or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
        const count = std.mem.readInt(u32, data[magic.len..][0..4], .little);
        const body = magic.len + 4 + (@as(usize, count) + 1) * 4;
        if (body > data.len) return null;
        const d = Dictionary{ .data = data, .count = count };
        if (d.offset(count) > data.len - body) return null;
        return d;
    }

    fn offset(d: Dictionary, i: u32) usize {
        return std.mem.readInt(u32, d.data[magic.len + 4 + @as(usize, i) * 4 ..][0..4], .little);
    }

    fn entry_bytes(d: Dictionary, i: u32) []const u8 {
        const body = magic.len + 4 + (@as(usize, d.count) + 1) * 4;
        const from = d.offset(i);
        const to = d.offset(i + 1);
        if (to < from or body + to > d.data.len) return "";
        return d.data[body + from .. body + to];
    }

    fn key(d: Dictionary, i: u32) []const u8 {
        const bytes = d.entry_bytes(i);
        return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
    }

    fn entry(d: Dictionary, i: u32) Entry {
        const bytes = d.entry_bytes(i);
        const k = std.mem.indexOfScalar(u8, bytes, 0) orelse return .{ .word = "", .text = "" };
        const rest = bytes[k + 1 ..];
        const w = std.mem.indexOfScalar(u8, rest, 0) orelse return .{ .word = rest, .text = "" };
        return .{ .word = rest[0..w], .text = rest[w + 1 ..] };
    }

    /// The entry for a key already folded with `fold`, if there is one.
    pub fn find_key(d: Dictionary, wanted: []const u8) ?Entry {
        var lo: u32 = 0;
        var hi: u32 = d.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, d.key(mid), wanted)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return d.entry(mid),
            }
        }
        return null;
    }

    /// The entry for a word as it stands in a book: punctuation around it trimmed,
    /// folded, then tried again without an "'s" on the end.
    pub fn lookup(d: Dictionary, word: []const u8) ?Entry {
        var buf: [max_key]u8 = undefined;
        const k = fold(&buf, trimmed(word)) orelse return null;
        if (d.find_key(k)) |e| return e;
        if (std.mem.endsWith(u8, k, "'s")) return d.find_key(k[0 .. k.len - 2]);
        return null;
    }
};

pub const max_key = 64;

/// The letters of a word without what surrounds it: quotes, commas, dashes.
pub fn trimmed(word: []const u8) []const u8 {
    var start: usize = 0;
    var end = word.len;
    while (start < end and !is_word_byte(word, start)) start += 1;
    while (end > start and !is_word_byte(word, last_start(word, end))) end = last_start(word, end);
    return word[start..end];
}

fn last_start(word: []const u8, end: usize) usize {
    var i = end - 1;
    while (i > 0 and word[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

fn is_word_byte(word: []const u8, i: usize) bool {
    const c = word[i];
    if (std.ascii.isAlphanumeric(c)) return true;
    // Letters beyond ASCII start with C3..C5 (Latin-1 and Extended-A)
    return c >= 0xc3 and c <= 0xc5;
}

/// A dictionary key: lowercase, accents off, curly apostrophes made straight. Null
/// when it won't fit or isn't text.
pub fn fold(buf: []u8, word: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < word.len) {
        const len = std.unicode.utf8ByteSequenceLength(word[i]) catch return null;
        if (i + len > word.len) return null;
        var cp: u32 = std.unicode.utf8Decode(word[i..][0..len]) catch return null;
        i += len;
        if (cp == 0x2019) cp = '\'';
        cp = search.fold(cp);
        var out: [4]u8 = undefined;
        const m = std.unicode.utf8Encode(@intCast(cp), &out) catch return null;
        if (n + m > buf.len) return null;
        @memcpy(buf[n..][0..m], out[0..m]);
        n += m;
    }
    return buf[0..n];
}

/// Builds a dictionary file in memory, for tests. `entries` must be sorted by key.
fn build(alloc: std.mem.Allocator, entries: []const [3][]const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(alloc);
    for (entries) |e| {
        try offsets.append(alloc, @intCast(body.items.len));
        try body.appendSlice(alloc, e[0]);
        try body.append(alloc, 0);
        try body.appendSlice(alloc, e[1]);
        try body.append(alloc, 0);
        try body.appendSlice(alloc, e[2]);
    }
    try offsets.append(alloc, @intCast(body.items.len));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, magic);
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, @intCast(entries.len), .little);
    try out.appendSlice(alloc, &b4);
    for (offsets.items) |o| {
        std.mem.writeInt(u32, &b4, o, .little);
        try out.appendSlice(alloc, &b4);
    }
    try out.appendSlice(alloc, body.items);
    return out.toOwnedSlice(alloc);
}

test "words are found however the book writes them" {
    const alloc = std.testing.allocator;
    const file = try build(alloc, &.{
        .{ "acao", "ação", "noun\n1 action" },
        .{ "polish", "Polish", "adjective\n1 of Poland" },
        .{ "ran", "ran", "verb\n1 simple past of run\n=run" },
        .{ "run", "run", "verb\n1 to move fast on foot" },
    });
    defer alloc.free(file);
    const d = Dictionary.open(file).?;
    try std.testing.expectEqualStrings("Polish", d.lookup("Polish,").?.word);
    try std.testing.expectEqualStrings("ação", d.lookup("\u{201c}Ação").?.word);
    try std.testing.expectEqualStrings("run", d.lookup("Run\u{2019}s").?.word);
    try std.testing.expectEqualStrings("run", d.lookup("ran").?.base_form().?);
    try std.testing.expect(d.lookup("ran").?.base_form() != null);
    try std.testing.expect(d.lookup("run").?.base_form() == null);
    try std.testing.expect(d.lookup("walk") == null);
    try std.testing.expect(d.lookup("\u{2014}") == null);
}

test "a damaged file is refused, not read past its end" {
    try std.testing.expect(Dictionary.open("NFDICT1\n") == null);
    try std.testing.expect(Dictionary.open("something else entirely") == null);
    // Claims a million entries in a few bytes
    try std.testing.expect(Dictionary.open("NFDICT1\n\x40\x42\x0f\x00") == null);
}

test "trimming keeps the letters and digits of a word" {
    try std.testing.expectEqualStrings("hello", trimmed("\u{201c}hello,\u{201d}"));
    try std.testing.expectEqualStrings("ação", trimmed("(ação)"));
    try std.testing.expectEqualStrings("", trimmed("\u{2014}"));
}
