//! Finding words in a book. Matching ignores case and accents, so "acao" finds
//! "Ação", the way people type on a small keyboard.
const std = @import("std");
const book_model = @import("book.zig");

pub const Match = struct { para: u32, byte: u32 };

/// What's typed into a search box.
pub const Query = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn slice(q: *const Query) []const u8 {
        return q.buf[0..q.len];
    }

    pub fn push(q: *Query, c: u8) void {
        if (q.len < q.buf.len) {
            q.buf[q.len] = c;
            q.len += 1;
        }
    }

    pub fn pop(q: *Query) void {
        q.len -|= 1;
    }

    /// What's typed, without spaces at either end.
    pub fn words(q: *const Query) []const u8 {
        return std.mem.trim(u8, q.slice(), " ");
    }
};

const Folded = struct { cp: u32, len: usize };

/// The character at `i`, lowercased and without its accent where that's simple.
fn fold_at(s: []const u8, i: usize) Folded {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + len > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = fold(cp), .len = len };
}

pub fn fold(cp: u32) u32 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp < 0xc0 or cp > 0x17f) return cp;
    // Latin-1 and Latin Extended-A letters, mapped to their plain letter (from
    // Unicode's decompositions). '*' marks the ones without one, like æ and ß.
    const plain = "aaaaaa*ceeeeiiii*nooooo**uuuuy**aaaaaa*ceeeeiiii*nooooo**uuuuy*yaaaaaaccccccccdd**eeeeeeeeeegggggggghh**iiiiiiiii***jjkk*llllll****nnnnnn***oooooo**rrrrrrsssssssstttt**uuuuuuuuuuuuwwyyyzzzzzz*";
    const c = plain[cp - 0xc0];
    return if (c == '*') cp else c;
}

/// Every place `query` appears, in reading order, up to `limit`. Notes are skipped,
/// as they aren't part of the flow.
pub fn find(alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, query: []const u8, limit: usize) ![]Match {
    var wanted: std.ArrayList(u32) = .empty;
    defer wanted.deinit(alloc);
    var q: usize = 0;
    while (q < query.len) {
        const f = fold_at(query, q);
        try wanted.append(alloc, f.cp);
        q += f.len;
    }
    var out: std.ArrayList(Match) = .empty;
    if (wanted.items.len == 0) return out.toOwnedSlice(alloc);
    for (paragraphs, 0..) |p, para| {
        if (p.note) continue;
        const s = p.text;
        var i: usize = 0;
        while (i < s.len) {
            const first = fold_at(s, i);
            if (first.cp == wanted.items[0] and matches_at(s, i, wanted.items)) {
                try out.append(alloc, .{ .para = @intCast(para), .byte = @intCast(i) });
                if (out.items.len >= limit) return out.toOwnedSlice(alloc);
            }
            i += first.len;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Whether `query` appears anywhere in `s`, ignoring case and accents. For short
/// texts like titles; queries past 64 characters never match.
pub fn contains(s: []const u8, query: []const u8) bool {
    var wanted: [64]u32 = undefined;
    var n: usize = 0;
    var q: usize = 0;
    while (q < query.len) {
        if (n == wanted.len) return false;
        const f = fold_at(query, q);
        wanted[n] = f.cp;
        n += 1;
        q += f.len;
    }
    if (n == 0) return true;
    var i: usize = 0;
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

fn matches_at(s: []const u8, start: usize, wanted: []const u32) bool {
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
pub fn snippet(s: []const u8, byte: usize, max: usize) []const u8 {
    const lead = 48;
    var start: usize = if (byte > lead) byte - lead else 0;
    if (start > 0) {
        if (std.mem.indexOfScalarPos(u8, s, start, ' ')) |space| {
            if (space < byte) start = space + 1;
        }
    }
    var end = @min(s.len, start + max);
    while (end < s.len and end > start and s[end] & 0xc0 == 0x80) end -= 1; // Inside a character
    return s[start..end];
}

fn sample(t: []const u8) book_model.Paragraph {
    return .{ .text = t, .style = 0 };
}

test "matching ignores case and accents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{ sample("A Ação começa."), sample("Nothing here"), sample("acao e ACAO") };
    const found = try find(arena.allocator(), &paras, "acao", 10);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqual(@as(u32, 0), found[0].para);
    try std.testing.expectEqual(@as(u32, 2), found[0].byte);
    try std.testing.expectEqual(@as(u32, 2), found[1].para);
    try std.testing.expectEqual(@as(usize, 1), (try find(arena.allocator(), &paras, "COMEÇA", 10)).len);
    try std.testing.expectEqual(@as(usize, 0), (try find(arena.allocator(), &paras, "", 10)).len);
}

test "notes are skipped and the limit holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var note = sample("word word");
    note.note = true;
    const paras = [_]book_model.Paragraph{ sample("word word word"), note };
    try std.testing.expectEqual(@as(usize, 2), (try find(arena.allocator(), &paras, "word", 2)).len);
    try std.testing.expectEqual(@as(usize, 3), (try find(arena.allocator(), &paras, "word", 99)).len);
}

test "snippets start at a word before the match" {
    const s = "The first part of a long sentence leads up to the word we wanted to find here.";
    const at = std.mem.indexOf(u8, s, "wanted").?;
    const line = snippet(s, at, 60);
    try std.testing.expect(std.mem.indexOf(u8, line, "wanted") != null);
    try std.testing.expect(line[0] != ' ');
}
