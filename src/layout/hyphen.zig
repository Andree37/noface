//! Where a word may break across lines, by Liang's algorithm (the one TeX uses) with
//! the standard TeX patterns for English and Portuguese, in hyphen/. Also breaks after
//! a dash already in the word, as in "fusion—and".
//!
//! Works on bytes: patterns only ever separate whole characters, and accented
//! Latin letters are two bytes, which counts close enough for the minimum lengths.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../model/book.zig");
const unicode = @import("../text/unicode.zig");

pub const Lang = enum { english, portuguese };

const Source = struct {
    patterns: []const u8,
    exceptions: []const u8,
    left: u32, // The fewest bytes before a break
    right: u32, // The fewest bytes after one
};

fn source(lang: Lang) Source {
    const chosen: Source = switch (lang) {
        // TeX's own minimums for each language
        .english => .{
            .patterns = @embedFile("hyphen/hyph-en-us.pat.txt"),
            .exceptions = @embedFile("hyphen/hyph-en-us.hyp.txt"),
            .left = 2,
            .right = 3,
        },
        .portuguese => .{
            .patterns = @embedFile("hyphen/hyph-pt.pat.txt"),
            .exceptions = "",
            .left = 2,
            .right = 3,
        },
    };
    assert(chosen.patterns.len > 0);
    assert(chosen.left > 0); // A break never leaves a part empty
    assert(chosen.right > 0);
    return chosen;
}

/// The longest word worth hyphenating, in bytes. Longer runs are URLs and the like.
const word_length_max = 48;

/// The longest pattern, in letters, in the files in hyphen/. A word and its two dots
/// hold any of them.
const pattern_length_max = 12;

/// Liang's values for a word and the dots either side: one before, between and after
/// each of its letters.
const Values = [word_length_max + 3]u8;

comptime {
    assert(pattern_length_max <= word_length_max + 2);
    // A break's offset in a word fits the bytes exceptions keep them in
    assert(word_length_max <= std.math.maxInt(u8));
}

pub const Hyphenator = struct {
    arena: std.heap.ArenaAllocator,
    // Letters of a pattern, to the values between and around them: "1b2l" is "bl" -> 1,2,0
    patterns: std.StringHashMapUnmanaged([]const u8) = .empty,
    // A word, to its breaks: "as-so-ciate" is "associate" -> 2,4
    exceptions: std.StringHashMapUnmanaged([]const u8) = .empty,
    longest: u32 = 0, // The most letters in a pattern
    left: u32,
    right: u32,

    pub fn init(child: std.mem.Allocator, lang: Lang) !Hyphenator {
        const chosen = source(lang);
        var h = Hyphenator{
            .arena = std.heap.ArenaAllocator.init(child),
            .left = chosen.left,
            .right = chosen.right,
        };
        errdefer h.arena.deinit();
        try h.init_patterns(chosen.patterns);
        try h.init_exceptions(chosen.exceptions);
        // The patterns are ours, built in: there are some, and none too long
        assert(h.longest > 0);
        assert(h.longest <= pattern_length_max);
        return h;
    }

    fn init_patterns(h: *Hyphenator, text: []const u8) !void {
        assert(text.len > 0);
        assert(h.patterns.count() == 0);
        const alloc = h.arena.allocator();
        var lines = std.mem.tokenizeAny(u8, text, " \n\r\t");
        while (lines.next()) |pattern| {
            const letters = try alloc.alloc(u8, pattern.len);
            const values = try alloc.alloc(u8, pattern.len + 1);
            var count: u32 = 0;
            @memset(values, 0);
            for (pattern) |c| {
                if (c >= '0' and c <= '9') {
                    values[count] = c - '0';
                } else {
                    letters[count] = c;
                    count += 1;
                }
            }
            try h.patterns.put(alloc, letters[0..count], values[0 .. count + 1]);
            h.longest = @max(h.longest, count);
        }
    }

    fn init_exceptions(h: *Hyphenator, text: []const u8) !void {
        assert(h.exceptions.count() == 0);
        const alloc = h.arena.allocator();
        var words = std.mem.tokenizeAny(u8, text, " \n\r\t");
        while (words.next()) |word| {
            const plain = try alloc.alloc(u8, word.len);
            const at = try alloc.alloc(u8, word.len);
            var plain_count: u32 = 0;
            var at_count: u32 = 0;
            for (word) |c| {
                if (c == '-') {
                    at[at_count] = @intCast(plain_count);
                    at_count += 1;
                } else {
                    plain[plain_count] = c;
                    plain_count += 1;
                }
            }
            assert(plain_count + at_count == word.len);
            try h.exceptions.put(alloc, plain[0..plain_count], at[0..at_count]);
        }
    }

    pub fn deinit(h: *Hyphenator) void {
        assert(h.longest > 0); // Made by `init`
        h.arena.deinit();
    }

    /// Fills `out` with the byte offsets in `word` (lowercase letters only) where it
    /// may break, in order, and returns them.
    pub fn points(h: *const Hyphenator, word: []const u8, out: []u32) []u32 {
        assert(out.len > 0);
        if (word.len < h.left + h.right or word.len > word_length_max) return out[0..0];
        var count: u32 = 0;
        if (h.exceptions.get(word)) |at| {
            for (at) |p| {
                if (count == out.len) break;
                out[count] = p;
                count += 1;
            }
            return out[0..count];
        }
        var values: Values = @splat(0);
        h.points_values(word, &values);
        // A break before word[p] is values[p + 1], counting the leading dot
        var p = h.left;
        while (p + h.right <= word.len) : (p += 1) {
            if (values[p + 1] % 2 == 0) continue;
            if (word[p] & 0xc0 == 0x80) continue; // Inside a two-byte letter
            if (count == out.len) break;
            out[count] = p;
            count += 1;
        }
        const found = out[0..count];
        if (found.len > 0) assert(found[0] >= h.left);
        if (found.len > 0) assert(found[found.len - 1] + h.right <= word.len);
        return found;
    }

    /// Liang's values between the letters of `word`, with a dot either side: the
    /// highest any pattern found in it gives each place.
    fn points_values(h: *const Hyphenator, word: []const u8, values: *Values) void {
        assert(word.len <= word_length_max);
        assert(h.longest <= pattern_length_max);
        var padded: [word_length_max + 2]u8 = undefined;
        padded[0] = '.';
        @memcpy(padded[1..][0..word.len], word);
        padded[word.len + 1] = '.';
        const padded_len: u32 = @intCast(word.len + 2);
        for (0..padded_len) |i| {
            var len: u32 = 1;
            while (len <= h.longest and i + len <= padded_len) : (len += 1) {
                const found = h.patterns.get(padded[i .. i + len]) orelse continue;
                for (found, 0..) |v, k| values[i + k] = @max(values[i + k], v);
            }
        }
    }
};

/// A place a word may break: before byte `at`, adding a hyphen or not.
pub const Break = struct { at: u32, hyphen: bool };

/// Whether a letter, in any script, starts at byte `i` of `word`.
fn is_letter_start(word: []const u8, i: u32) bool {
    assert(i < word.len);
    const c = unicode.character_at(word, i) orelse return false;
    return unicode.is_letter(c.cp);
}

/// How many bytes the dash at `word[i]` takes, or 0 when there's none there.
fn is_dash_at(word: []const u8, i: u32) u32 {
    assert(i < word.len);
    if (word[i] == '-') return 1;
    // En dash, em dash
    if (i + 2 < word.len and word[i] == 0xe2 and word[i + 1] == 0x80) {
        if (word[i + 2] == 0x93 or word[i + 2] == 0x94) return 3;
    }
    return 0;
}

/// Every place `word`, as it stands in the text, may break, shortest first. After a
/// dash it breaks as it is; inside the letters of a word it takes a hyphen. Leading
/// and trailing punctuation stay with the word.
pub fn breaks(h: ?*const Hyphenator, word: []const u8, out: []Break) []Break {
    assert(out.len > 0);
    var count: u32 = 0;
    // After dashes already in the word, keeping at least two bytes either side
    var has_dash = false;
    var i: u32 = 0;
    while (i < word.len) {
        const dash = is_dash_at(word, i);
        if (dash > 0) {
            has_dash = true;
            const at = i + dash;
            if (at >= 2 and at + 2 <= word.len and count < out.len) {
                out[count] = .{ .at = at, .hyphen = false };
                count += 1;
            }
            i = at;
        } else i += 1;
    }
    const hyphenator = h orelse return out[0..count];
    if (has_dash) return out[0..count];
    // The letters in the middle, between any quotes or punctuation
    var start: u32 = 0;
    while (start < word.len and !is_letter_start(word, start)) start += 1;
    var end: u32 = @intCast(word.len);
    while (end > start) {
        // Back to where the last character starts, over its continuation bytes
        var lead = end - 1;
        while (lead > start and word[lead] & 0xc0 == 0x80) lead -= 1;
        assert(end - lead <= 4); // A character takes four bytes at most
        if (is_letter_start(word, lead)) break;
        end = lead;
    }
    const core = word[start..end];
    if (core.len == 0 or core.len > word_length_max) return out[0..count];
    var lower: [word_length_max]u8 = undefined;
    if (!breaks_lowered(core, &lower)) return out[0..count]; // Left whole
    var at: [word_length_max]u32 = undefined;
    for (hyphenator.points(lower[0..core.len], &at)) |p| {
        if (count == out.len) break;
        out[count] = .{ .at = start + p, .hyphen = true };
        count += 1;
    }
    // Every break leaves something on either side
    for (out[0..count]) |b| assert(b.at > 0);
    for (out[0..count]) |b| assert(b.at < word.len);
    return out[0..count];
}

/// `core` in lowercase, into `lower`, byte for byte where `core` has it, so a break
/// found in `lower` is one in `core`. False for a word with digits, apostrophes and the
/// like, or a letter whose lowercase takes another number of bytes: left whole.
fn breaks_lowered(core: []const u8, lower: *[word_length_max]u8) bool {
    assert(core.len > 0);
    assert(core.len <= lower.len);
    var k: u32 = 0;
    while (k < core.len) {
        const c = unicode.character_at(core, k) orelse return false;
        if (!unicode.is_letter(c.cp)) return false;
        const lowered = unicode.lowercase(c.cp);
        const len = std.unicode.utf8CodepointSequenceLength(lowered) catch return false;
        if (len != c.len) return false;
        _ = std.unicode.utf8Encode(lowered, lower[k..][0..len]) catch return false;
        k += c.len;
    }
    assert(k == core.len);
    return true;
}

/// How many of a book's first paragraphs `detect` looks at.
const detect_paragraphs_max = 300;
/// How many common words of a language make a book clearly in it.
const detect_words_min = 20;

/// The language most of a book is in, from how often a few common words turn up in
/// its first paragraphs. Null when neither is clear, and then nothing hyphenates.
pub fn detect(paragraphs: []const book_model.Paragraph) ?Lang {
    const english = [_][]const u8{ "the", "and", "of", "was", "that" };
    const portuguese = [_][]const u8{ "que", "não", "uma", "de", "os" };
    // As many words each, so neither language is favoured
    comptime assert(english.len == portuguese.len);
    var en: u32 = 0;
    var pt: u32 = 0;
    var seen: u32 = 0;
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
        if (seen >= detect_paragraphs_max) break;
    }
    assert(seen <= detect_paragraphs_max);
    if (en < detect_words_min and pt < detect_words_min) return null;
    if (en > 2 * pt) return .english;
    if (pt > 2 * en) return .portuguese;
    return null;
}

/// `word` with its breaks marked, '-' for a hyphen and '|' for none: for the tests.
fn joined(h: *const Hyphenator, word: []const u8, buf: []u8) []const u8 {
    var at: [16]Break = undefined;
    const found = breaks(h, word, &at);
    assert(buf.len >= word.len + found.len);
    var n: u32 = 0;
    var last: u32 = 0;
    for (found) |b| {
        @memcpy(buf[n..][0 .. b.at - last], word[last..b.at]);
        n += b.at - last;
        buf[n] = if (b.hyphen) '-' else '|';
        n += 1;
        last = b.at;
    }
    @memcpy(buf[n..][0 .. word.len - last], word[last..]);
    const result = buf[0 .. n + word.len - last];
    assert(result.len == word.len + found.len);
    return result;
}

test "English words break where TeX breaks them" {
    var h = try Hyphenator.init(std.testing.allocator, .english);
    defer h.deinit();
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("hy-phen-ation", joined(&h, "hyphenation", &buf));
    try std.testing.expectEqualStrings("De-part-ment,", joined(&h, "Department,", &buf));
    try std.testing.expectEqualStrings("as-so-ciate", joined(&h, "associate", &buf));
    const commander = joined(&h, "\u{201c}Commander,", &buf);
    try std.testing.expectEqualStrings("\u{201c}Com-man-der,", commander);
    try std.testing.expectEqualStrings("the", joined(&h, "the", &buf));
    // Left whole
    try std.testing.expectEqualStrings("we\u{2019}ve", joined(&h, "we\u{2019}ve", &buf));
}

test "words break after a dash, without another hyphen" {
    var h = try Hyphenator.init(std.testing.allocator, .english);
    defer h.deinit();
    var buf: [96]u8 = undefined;
    const fusion = joined(&h, "fusion\u{2014}and", &buf);
    try std.testing.expectEqualStrings("fusion\u{2014}|and", fusion);
    try std.testing.expectEqualStrings("well-|known", joined(&h, "well-known", &buf));
}

test "Portuguese words break, accents and all" {
    var h = try Hyphenator.init(std.testing.allocator, .portuguese);
    defer h.deinit();
    var buf: [96]u8 = undefined;
    const word = joined(&h, "intermitências", &buf);
    try std.testing.expectEqualStrings("in-ter-mi-tên-cias", word);
}

test "language comes from common words" {
    var en: [30]book_model.Paragraph = undefined;
    for (&en) |*p| p.* = .{ .text = "the cat and the dog of the house" };
    try std.testing.expectEqual(Lang.english, detect(&en).?);
    var pt: [30]book_model.Paragraph = undefined;
    for (&pt) |*p| p.* = .{ .text = "o gato que não tem uma casa de os" };
    try std.testing.expectEqual(Lang.portuguese, detect(&pt).?);
    const none = [_]book_model.Paragraph{.{ .text = "hello" }};
    try std.testing.expect(detect(&none) == null);
}
