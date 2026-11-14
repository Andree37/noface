//! Where a word may break across lines, by Liang's algorithm (the one TeX uses) with
//! the standard TeX patterns for English and Portuguese, in hyphen/. Also breaks after
//! a dash already in the word, as in "fusion—and".
//!
//! Works on bytes: patterns only ever separate whole characters, and accented
//! Latin letters are two bytes, which counts close enough for the minimum lengths.
const std = @import("std");
const book_model = @import("../model/book.zig");

pub const Lang = enum { english, portuguese };

const Source = struct { patterns: []const u8, exceptions: []const u8, left: usize, right: usize };

fn source(lang: Lang) Source {
    return switch (lang) {
        // TeX's own minimums for each language
        .english => .{ .patterns = @embedFile("hyphen/hyph-en-us.pat.txt"), .exceptions = @embedFile("hyphen/hyph-en-us.hyp.txt"), .left = 2, .right = 3 },
        .portuguese => .{ .patterns = @embedFile("hyphen/hyph-pt.pat.txt"), .exceptions = "", .left = 2, .right = 3 },
    };
}

/// The longest word worth hyphenating. Longer runs are URLs and the like.
const max_word = 48;

pub const Hyphenator = struct {
    arena: std.heap.ArenaAllocator,
    // Letters of a pattern, to the values between and around them: "1b2l" is "bl" -> 1,2,0
    patterns: std.StringHashMapUnmanaged([]const u8) = .empty,
    // A word, to its breaks: "as-so-ciate" is "associate" -> 2,4
    exceptions: std.StringHashMapUnmanaged([]const u8) = .empty,
    longest: usize = 0,
    left: usize,
    right: usize,

    pub fn init(child: std.mem.Allocator, lang: Lang) !Hyphenator {
        const src = source(lang);
        var h = Hyphenator{ .arena = std.heap.ArenaAllocator.init(child), .left = src.left, .right = src.right };
        errdefer h.arena.deinit();
        const alloc = h.arena.allocator();
        var lines = std.mem.tokenizeAny(u8, src.patterns, " \n\r\t");
        while (lines.next()) |pattern| {
            const letters = try alloc.alloc(u8, pattern.len);
            const values = try alloc.alloc(u8, pattern.len + 1);
            var n: usize = 0;
            @memset(values, 0);
            for (pattern) |c| {
                if (c >= '0' and c <= '9') {
                    values[n] = c - '0';
                } else {
                    letters[n] = c;
                    n += 1;
                }
            }
            try h.patterns.put(alloc, letters[0..n], values[0 .. n + 1]);
            h.longest = @max(h.longest, n);
        }
        var words = std.mem.tokenizeAny(u8, src.exceptions, " \n\r\t");
        while (words.next()) |word| {
            const plain = try alloc.alloc(u8, word.len);
            const at = try alloc.alloc(u8, word.len);
            var n: usize = 0;
            var count: usize = 0;
            for (word) |c| {
                if (c == '-') {
                    at[count] = @intCast(n);
                    count += 1;
                } else {
                    plain[n] = c;
                    n += 1;
                }
            }
            try h.exceptions.put(alloc, plain[0..n], at[0..count]);
        }
        return h;
    }

    pub fn deinit(h: *Hyphenator) void {
        h.arena.deinit();
    }

    /// Fills `out` with the byte offsets in `word` (lowercase letters only) where it
    /// may break, in order, and returns them.
    pub fn points(h: *const Hyphenator, word: []const u8, out: []usize) []usize {
        if (word.len < h.left + h.right or word.len > max_word) return out[0..0];
        var n: usize = 0;
        if (h.exceptions.get(word)) |at| {
            for (at) |p| {
                if (n == out.len) break;
                out[n] = p;
                n += 1;
            }
            return out[0..n];
        }
        var padded: [max_word + 2]u8 = undefined;
        padded[0] = '.';
        @memcpy(padded[1..][0..word.len], word);
        padded[word.len + 1] = '.';
        const m = word.len + 2;
        var values: [max_word + 3]u8 = @splat(0);
        for (0..m) |i| {
            var len: usize = 1;
            while (len <= h.longest and i + len <= m) : (len += 1) {
                const found = h.patterns.get(padded[i .. i + len]) orelse continue;
                for (found, 0..) |v, k| values[i + k] = @max(values[i + k], v);
            }
        }
        // A break before word[p] is values[p + 1], counting the leading dot
        var p = h.left;
        while (p + h.right <= word.len) : (p += 1) {
            if (values[p + 1] % 2 == 0) continue;
            if (word[p] & 0xc0 == 0x80) continue; // Inside a two-byte letter
            if (n == out.len) break;
            out[n] = p;
            n += 1;
        }
        return out[0..n];
    }
};

/// A place a word may break: before byte `at`, adding a hyphen or not.
pub const Break = struct { at: usize, hyphen: bool };

fn is_letter_start(word: []const u8, i: usize) bool {
    const c = word[i];
    if (std.ascii.isAlphabetic(c)) return true;
    // Latin-1 letters are C3 followed by 80..BF, except × and ÷
    return c == 0xc3 and i + 1 < word.len and word[i + 1] != 0x97 and word[i + 1] != 0xb7;
}

fn is_dash_at(word: []const u8, i: usize) usize {
    if (word[i] == '-') return 1;
    // En dash, em dash
    if (i + 2 < word.len + 0 and word[i] == 0xe2 and word[i + 1] == 0x80 and (word[i + 2] == 0x93 or word[i + 2] == 0x94)) return 3;
    return 0;
}

/// Every place `word`, as it stands in the text, may break, shortest first. After a
/// dash it breaks as it is; inside the letters of a word it takes a hyphen. Leading
/// and trailing punctuation stay with the word.
pub fn breaks(h: ?*const Hyphenator, word: []const u8, out: []Break) []Break {
    var n: usize = 0;
    // After dashes already in the word, keeping at least two bytes either side
    var has_dash = false;
    var i: usize = 0;
    while (i < word.len) {
        const dash = is_dash_at(word, i);
        if (dash > 0) {
            has_dash = true;
            const at = i + dash;
            if (at >= 2 and at + 2 <= word.len and n < out.len) {
                out[n] = .{ .at = at, .hyphen = false };
                n += 1;
            }
            i = at;
        } else i += 1;
    }
    const hyph = h orelse return out[0..n];
    if (has_dash) return out[0..n];
    // The letters in the middle, between any quotes or punctuation
    var start: usize = 0;
    while (start < word.len and !is_letter_start(word, start)) start += 1;
    var end = word.len;
    while (end > start) {
        const last = end - 1;
        const lead = if (last > start and word[last] & 0xc0 == 0x80) last - 1 else last;
        if (is_letter_start(word, lead)) break;
        end = lead;
    }
    const core = word[start..end];
    if (core.len == 0 or core.len > max_word) return out[0..n];
    var lower: [max_word]u8 = undefined;
    var k: usize = 0;
    while (k < core.len) : (k += 1) {
        const c = core[k];
        if (std.ascii.isAlphabetic(c)) {
            lower[k] = std.ascii.toLower(c);
        } else if (c == 0xc3 and k + 1 < core.len) {
            lower[k] = c;
            const next = core[k + 1];
            // Uppercase Latin-1 letters sit 0x20 below their lowercase ones
            lower[k + 1] = if (next >= 0x80 and next <= 0x9e and next != 0x97) next + 0x20 else next;
            k += 1;
        } else return out[0..n]; // Digits, apostrophes and the like: leave it whole
    }
    var at: [max_word]usize = undefined;
    for (hyph.points(lower[0..core.len], &at)) |p| {
        if (n == out.len) break;
        out[n] = .{ .at = start + p, .hyphen = true };
        n += 1;
    }
    return out[0..n];
}

/// The language most of a book is in, from how often a few common words turn up in
/// its first paragraphs. Null when neither is clear, and then nothing hyphenates.
pub fn detect(paragraphs: []const book_model.Paragraph) ?Lang {
    const english = [_][]const u8{ "the", "and", "of", "was", "that" };
    const portuguese = [_][]const u8{ "que", "não", "uma", "de", "os" };
    var en: usize = 0;
    var pt: usize = 0;
    var seen: usize = 0;
    for (paragraphs) |p| {
        if (p.note or p.image != null) continue;
        var words = std.mem.tokenizeAny(u8, p.text, " \n,.;:!?\"'()");
        while (words.next()) |w| {
            for (english) |e| {
                if (std.ascii.eqlIgnoreCase(w, e)) en += 1;
            }
            for (portuguese) |e| {
                if (std.ascii.eqlIgnoreCase(w, e)) pt += 1;
            }
        }
        seen += 1;
        if (seen >= 300) break;
    }
    if (en < 20 and pt < 20) return null;
    if (en > 2 * pt) return .english;
    if (pt > 2 * en) return .portuguese;
    return null;
}

fn joined(h: *const Hyphenator, word: []const u8, buf: []u8) []const u8 {
    var at: [16]Break = undefined;
    const found = breaks(h, word, &at);
    var n: usize = 0;
    var last: usize = 0;
    for (found) |b| {
        @memcpy(buf[n..][0 .. b.at - last], word[last..b.at]);
        n += b.at - last;
        buf[n] = if (b.hyphen) '-' else '|';
        n += 1;
        last = b.at;
    }
    @memcpy(buf[n..][0 .. word.len - last], word[last..]);
    return buf[0 .. n + word.len - last];
}

test "English words break where TeX breaks them" {
    var h = try Hyphenator.init(std.testing.allocator, .english);
    defer h.deinit();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("hy-phen-ation", joined(&h, "hyphenation", &buf));
    try std.testing.expectEqualStrings("De-part-ment,", joined(&h, "Department,", &buf));
    try std.testing.expectEqualStrings("as-so-ciate", joined(&h, "associate", &buf));
    try std.testing.expectEqualStrings("\u{201c}Com-man-der,", joined(&h, "\u{201c}Commander,", &buf));
    try std.testing.expectEqualStrings("the", joined(&h, "the", &buf));
    try std.testing.expectEqualStrings("we\u{2019}ve", joined(&h, "we\u{2019}ve", &buf)); // Left whole
}

test "words break after a dash, without another hyphen" {
    var h = try Hyphenator.init(std.testing.allocator, .english);
    defer h.deinit();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("fusion\u{2014}|and", joined(&h, "fusion\u{2014}and", &buf));
    try std.testing.expectEqualStrings("well-|known", joined(&h, "well-known", &buf));
}

test "Portuguese words break, accents and all" {
    var h = try Hyphenator.init(std.testing.allocator, .portuguese);
    defer h.deinit();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("in-ter-mi-tên-cias", joined(&h, "intermitências", &buf));
}

test "language comes from common words" {
    var en: [30]book_model.Paragraph = undefined;
    for (&en) |*p| p.* = .{ .text = "the cat and the dog of the house", .style = 0 };
    try std.testing.expectEqual(Lang.english, detect(&en).?);
    var pt: [30]book_model.Paragraph = undefined;
    for (&pt) |*p| p.* = .{ .text = "o gato que não tem uma casa de os", .style = 0 };
    try std.testing.expectEqual(Lang.portuguese, detect(&pt).?);
    const none = [_]book_model.Paragraph{.{ .text = "hello", .style = 0 }};
    try std.testing.expect(detect(&none) == null);
}
