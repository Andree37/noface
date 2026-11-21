//! Finding words in a book. Matching ignores case and accents, so "acao" finds
//! "Ação", the way people type on a small keyboard.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("book.zig");
const unicode = @import("../text/unicode.zig");

pub const Match = struct { para: u32, byte: u32 };

/// What's typed into a search box.
pub const Query = struct {
    buf: [64]u8 = undefined,
    len: u32 = 0,

    pub fn slice(q: *const Query) []const u8 {
        assert(q.len <= q.buf.len);
        return q.buf[0..q.len];
    }

    pub fn push(q: *Query, c: u8) void {
        assert(q.len <= q.buf.len);
        if (q.len < q.buf.len) {
            q.buf[q.len] = c;
            q.len += 1;
        }
        assert(q.len > 0);
    }

    pub fn pop(q: *Query) void {
        assert(q.len <= q.buf.len);
        q.len -|= 1;
        assert(q.len < q.buf.len);
    }

    /// What's typed, without spaces at either end: what's searched for.
    pub fn words(q: *const Query) []const u8 {
        const result = words_of(q.slice());
        assert(result.len <= q.len);
        return result;
    }
};

/// `typed` without spaces at either end: what's searched for when that's typed.
pub fn words_of(typed: []const u8) []const u8 {
    const result = std.mem.trim(u8, typed, " ");
    assert(result.len <= typed.len);
    return result;
}

const Folded = unicode.Character;

/// The character at `i`, as words are matched (`unicode.fold`): a byte that starts no
/// character stands for itself.
fn fold_at(s: []const u8, i: u32) Folded {
    assert(i < s.len);
    const c = unicode.character_at(s, i) orelse return .{ .cp = s[i], .len = 1 };
    const folded: Folded = .{ .cp = unicode.fold(c.cp), .len = c.len };
    assert(folded.len >= 1);
    assert(i + folded.len <= s.len);
    return folded;
}

/// A character as words are matched, ignoring case and accents (`unicode.fold`): the
/// search's, and a dictionary's keys'.
pub const fold = unicode.fold;

/// Every place `query` appears, in reading order, up to `limit`. Notes are skipped,
/// as they aren't part of the flow.
pub fn find(
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    query: []const u8,
    limit: u32,
) ![]Match {
    assert(limit > 0);
    var wanted: std.ArrayList(u21) = .empty;
    defer wanted.deinit(alloc);
    var q: u32 = 0;
    while (q < query.len) {
        const f = fold_at(query, q);
        try wanted.append(alloc, f.cp);
        q += f.len;
    }
    assert(wanted.items.len <= query.len); // A character takes a byte at least
    var out: std.ArrayList(Match) = .empty;
    if (wanted.items.len == 0) return out.toOwnedSlice(alloc);
    for (paragraphs, 0..) |p, para| {
        if (p.note) continue;
        const s = p.text;
        var i: u32 = 0;
        while (i < s.len) {
            const first = fold_at(s, i);
            if (first.cp == wanted.items[0] and matches_at(s, i, wanted.items)) {
                try out.append(alloc, .{ .para = @intCast(para), .byte = i });
                if (out.items.len >= limit) return out.toOwnedSlice(alloc);
            }
            i += first.len;
        }
    }
    assert(out.items.len < limit);
    return out.toOwnedSlice(alloc);
}

/// Whether `query` appears anywhere in `s`, ignoring case and accents. For short
/// texts like titles; queries past 64 characters never match.
pub fn contains(s: []const u8, query: []const u8) bool {
    var wanted: [64]u21 = undefined;
    var n: u32 = 0;
    var q: u32 = 0;
    while (q < query.len) {
        if (n == wanted.len) return false;
        const f = fold_at(query, q);
        wanted[n] = f.cp;
        n += 1;
        q += f.len;
    }
    assert(q == query.len);
    assert(n <= wanted.len);
    if (n == 0) return true;
    var i: u32 = 0;
    while (i < s.len) {
        if (matches_at(s, i, wanted[0..n])) return true;
        i += fold_at(s, i).len;
    }
    return false;
}

test "contains ignores case and accents" {
    try std.testing.expect(contains("As intermitências da morte", "intermitencias"));
    try std.testing.expect(contains("Project Hail Mary", "hail"));
    try std.testing.expect(contains("anything", ""));
    try std.testing.expect(!contains("Artemis", "weir"));
    try std.testing.expect(!contains("ab", "abc"));
}

fn matches_at(s: []const u8, start: u32, wanted: []const u21) bool {
    assert(start < s.len);
    assert(wanted.len > 0);
    var i = start;
    for (wanted) |cp| {
        if (i >= s.len) return false;
        const f = fold_at(s, i);
        if (f.cp != cp) return false;
        i += f.len;
    }
    return true;
}

/// A line of text around a match, starting at a word a little before it.
pub fn snippet(s: []const u8, byte: u32, max: u32) []const u8 {
    assert(byte <= s.len); // A match `find` made in this text
    const lead = 48;
    var start: u32 = if (byte > lead) byte - lead else 0;
    if (start > 0) {
        if (std.mem.indexOfScalarPos(u8, s, start, ' ')) |space| {
            if (space < byte) start = @intCast(space + 1);
        }
    }
    // With no space before the match (Chinese, Japanese, a long address), the lead
    // may land inside a character, and a line that starts there draws as nothing.
    // The match starts on a character, so this stops there at the latest.
    while (start < byte and s[start] & 0xc0 == 0x80) start += 1;
    var end = @min(s.len, start + max);
    // Inside a character
    while (end < s.len and end > start and s[end] & 0xc0 == 0x80) end -= 1;
    assert(start <= end);
    assert(end <= s.len);
    return s[start..end];
}

fn sample(t: []const u8) book_model.Paragraph {
    return .{ .text = t };
}

test "matching ignores case and accents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{
        sample("A Ação começa."),
        sample("Nothing here"),
        sample("acao e ACAO"),
    };
    const found = try find(arena.allocator(), &paras, "acao", 10);
    try std.testing.expectEqual(@as(u32, 3), found.len);
    try std.testing.expectEqual(@as(u32, 0), found[0].para);
    try std.testing.expectEqual(@as(u32, 2), found[0].byte);
    try std.testing.expectEqual(@as(u32, 2), found[1].para);
    const capitals = try find(arena.allocator(), &paras, "COMEÇA", 10);
    try std.testing.expectEqual(@as(u32, 1), capitals.len);
    try std.testing.expectEqual(@as(u32, 0), (try find(arena.allocator(), &paras, "", 10)).len);
}

test "notes are skipped and the limit holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var note = sample("word word");
    note.note = true;
    const paras = [_]book_model.Paragraph{ sample("word word word"), note };
    const limited = try find(arena.allocator(), &paras, "word", 2);
    try std.testing.expectEqual(@as(u32, 2), limited.len);
    const all = try find(arena.allocator(), &paras, "word", 99);
    try std.testing.expectEqual(@as(u32, 3), all.len);
}

test "snippets start at a word before the match" {
    const s = "The first part of a long sentence leads up to the word we wanted to find here.";
    const at = std.mem.indexOf(u8, s, "wanted").?;
    const line = snippet(s, @intCast(at), 60);
    try std.testing.expect(std.mem.indexOf(u8, line, "wanted") != null);
    try std.testing.expect(line[0] != ' ');
}

test "snippets of text without spaces start on a whole character" {
    // Three-byte characters, then one ASCII digit, so 48 bytes back lands mid-character
    const sentence = "日本語の文章です。";
    const s = sentence ++ sentence ++ sentence ++ sentence ++ "1探す言葉";
    const at = std.mem.indexOf(u8, s, "探す").?;
    try std.testing.expect(s[at - 48] & 0xc0 == 0x80);
    const line = snippet(s, @intCast(at), 120);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(std.mem.indexOf(u8, line, "探す") != null);
}
