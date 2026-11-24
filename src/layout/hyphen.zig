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

/// The most breaks `breaks` finds in a word: a pattern's points fall between the
/// letters of a word no longer than `word_length_max`, and a word's dashes past that
/// many are a URL's or the like, its first breaks kept.
pub const breaks_max = word_length_max;

/// Liang's values for a word and the dots either side: one before, between and after
/// each of its letters.
const Values = [word_length_max + 3]u8;

comptime {
    assert(pattern_length_max <= word_length_max + 2);
    // A break's offset in a word fits the bytes exceptions keep them in
    assert(word_length_max <= std.math.maxInt(u8));
}

pub const Hyphenator = struct {
    lang: Lang, // Whose patterns: page breaks are kept by it (screens/reader/page_store.zig)
    arena: std.heap.ArenaAllocator,
    patterns: Patterns,
    // A word, to its breaks: "as-so-ciate" is "associate" -> 2,4
    exceptions: std.StringHashMapUnmanaged([]const u8) = .empty,
    left: u32,
    right: u32,

    pub fn init(child: std.mem.Allocator, lang: Lang) !Hyphenator {
        const chosen = source(lang);
        var h = Hyphenator{
            .lang = lang,
            .arena = std.heap.ArenaAllocator.init(child),
            .patterns = undefined, // Read below, into the arena in its place
            .left = chosen.left,
            .right = chosen.right,
        };
        errdefer h.arena.deinit();
        // Through the arena `h` holds, never a copy of it, which `deinit` wouldn't free
        h.patterns = try Patterns.read(h.arena.allocator(), child, chosen.patterns);
        try h.init_exceptions(chosen.exceptions);
        // The patterns are ours, built in: there are some, and none too long
        assert(h.patterns.longest > 0);
        assert(h.patterns.longest <= pattern_length_max);
        return h;
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
        assert(h.patterns.longest > 0); // Made by `init`
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
            if (unicode.inside_character(word[p])) continue; // Inside a two-byte letter
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
        assert(h.patterns.longest <= pattern_length_max);
        var padded: [word_length_max + 2]u8 = undefined;
        padded[0] = '.';
        @memcpy(padded[1..][0..word.len], word);
        padded[word.len + 1] = '.';
        const padded_len: u32 = @intCast(word.len + 2);
        for (0..padded_len) |i| {
            // Along the patterns that start with the letter at `i`, as long as one goes on
            const p = &h.patterns;
            var node: u32 = Patterns.root;
            var end = i;
            while (end < padded_len) : (end += 1) {
                node = p.child_of(node, padded[end]) orelse break;
                for (p.nodes[node].values, 0..) |v, k| values[i + k] = @max(values[i + k], v);
            }
            assert(end - i <= p.longest); // No path is longer than a pattern
        }
    }
};

/// The patterns as a trie: each a path of letters from the root to the node holding
/// the values between and around them ("1b2l" is b, l -> 1,2,0). A word is matched
/// from each of its letters along the path its letters take, so a start no pattern
/// begins with ends at once. The nodes are laid out level by level, each one's
/// children side by side and in order of their byte, so finding one reads a few
/// neighbours; the root's, which every walk starts from and which are the most, by
/// their byte directly.
const Patterns = struct {
    nodes: []const Node,
    starts: [256]u32, // The root's children by their byte: `none` for no pattern's start
    longest: u32, // The most letters in a pattern

    /// A letter on a pattern's path: the values of the pattern that ends with it, if
    /// one does, and where the letters that can follow it are.
    const Node = struct { values: []const u8 = &.{}, first: u32 = 0, count: u32 = 0, byte: u8 };
    const root = 0;
    const none = 0; // The root is no one's child

    /// The node for `byte` after `node`, or null when no pattern goes on that way.
    fn child_of(p: *const Patterns, node: u32, byte: u8) ?u32 {
        assert(node < p.nodes.len);
        if (node == root) {
            const start = p.starts[byte];
            return if (start == none) null else start;
        }
        const n = p.nodes[node];
        // In order of their byte: past it, it isn't there
        for (p.nodes[n.first..][0..n.count], n.first..) |c, at| {
            if (c.byte == byte) return @intCast(at);
            if (c.byte > byte) return null;
        }
        return null;
    }

    /// The patterns in `text` ("1b2l" and the like, one a line), in `arena`; `scratch`
    /// holds the trie as it's read, given back once it's laid out.
    fn read(arena: std.mem.Allocator, scratch: std.mem.Allocator, text: []const u8) !Patterns {
        assert(text.len > 0);
        var reading = std.heap.ArenaAllocator.init(scratch);
        defer reading.deinit();
        var tree = Tree{};
        try tree.links.append(reading.allocator(), .{ .byte = 0 }); // The root
        var longest: u32 = 0;
        var lines = std.mem.tokenizeAny(u8, text, " \n\r\t");
        while (lines.next()) |pattern| {
            // A pattern's letters and digits: twice its letters, which fit a word
            if (pattern.len > 2 * pattern_length_max + 1) return error.PatternTooLong;
            var letters: [2 * pattern_length_max + 1]u8 = undefined;
            const values = try arena.alloc(u8, pattern.len + 1);
            @memset(values, 0);
            var count: u32 = 0;
            for (pattern) |c| {
                if (c >= '0' and c <= '9') {
                    values[count] = c - '0';
                } else {
                    letters[count] = c;
                    count += 1;
                }
            }
            try tree.add(reading.allocator(), letters[0..count], values[0 .. count + 1]);
            longest = @max(longest, count);
        }
        return tree.laid_out(arena, reading.allocator(), longest);
    }

    /// The trie as it's read: each node linked to its first child and its next sibling.
    const Tree = struct {
        links: std.ArrayList(Link) = .empty,
        starts: [256]u32 = @splat(none), // The root's children by their byte, as read

        const Link = struct {
            byte: u8,
            child: u32 = none,
            sibling: u32 = none,
            values: []const u8 = &.{},
        };

        fn find(t: *const Tree, node: u32, byte: u8) ?u32 {
            assert(node < t.links.items.len);
            if (node == root) return if (t.starts[byte] == none) null else t.starts[byte];
            var at = t.links.items[node].child;
            // Bounded by the letters that can follow one
            while (at != none) : (at = t.links.items[at].sibling) {
                if (t.links.items[at].byte == byte) return at;
            }
            return null;
        }

        fn add(t: *Tree, gpa: std.mem.Allocator, letters: []const u8, values: []const u8) !void {
            assert(letters.len > 0);
            assert(values.len == letters.len + 1);
            var node: u32 = root;
            for (letters) |byte| {
                node = t.find(node, byte) orelse added: {
                    const new: u32 = @intCast(t.links.items.len);
                    if (node == root) t.starts[byte] = new;
                    const first = t.links.items[node].child;
                    t.links.items[node].child = new;
                    try t.links.append(gpa, .{ .byte = byte, .sibling = first });
                    break :added new;
                };
            }
            assert(node != root);
            t.links.items[node].values = values;
        }

        /// The trie level by level, in `arena`, each node's children side by side.
        fn laid_out(
            t: *const Tree,
            arena: std.mem.Allocator,
            gpa: std.mem.Allocator,
            longest: u32,
        ) !Patterns {
            const total = t.links.items.len;
            assert(total > 1); // A root and a pattern at least
            const nodes = try arena.alloc(Node, total);
            const of = try gpa.alloc(u32, total); // Each laid-out node's link
            nodes[root] = .{ .byte = 0 };
            of[root] = root;
            var placed: u32 = 1;
            var next: u32 = 0; // The next laid-out node whose children to place
            while (next < placed) : (next += 1) {
                var children: [256]u32 = undefined; // At most one per byte
                var count: u32 = 0;
                var at = t.links.items[of[next]].child;
                while (at != none) : (at = t.links.items[at].sibling) {
                    children[count] = at;
                    count += 1;
                }
                const sorted = children[0..count];
                std.mem.sortUnstable(u32, sorted, t, by_byte);
                nodes[next].first = placed;
                nodes[next].count = count;
                for (sorted) |link| {
                    const l = t.links.items[link];
                    nodes[placed] = .{ .byte = l.byte, .values = l.values };
                    of[placed] = link;
                    placed += 1;
                }
            }
            assert(placed == total); // Every node placed once
            var starts: [256]u32 = @splat(none);
            const r = nodes[root];
            for (nodes[r.first..][0..r.count], r.first..) |c, at| starts[c.byte] = @intCast(at);
            return .{ .nodes = nodes, .starts = starts, .longest = longest };
        }

        fn by_byte(t: *const Tree, a: u32, b: u32) bool {
            return t.links.items[a].byte < t.links.items[b].byte;
        }
    };
};

/// A place a word may break: before byte `at`, adding a hyphen or not.
pub const Break = struct { at: u32, hyphen: bool };

/// Whether a letter, in any script, starts at byte `i` of `word`.
fn is_letter_start(word: []const u8, i: u32) bool {
    assert(i < word.len);
    const c = unicode.character_at(word, i) orelse return false;
    return unicode.is_letter(c.cp);
}

const en_dash = 0x2013;
const em_dash = 0x2014;

/// How many bytes the dash at `word[i]` takes, or 0 when there's none there.
fn is_dash_at(word: []const u8, i: u32) u32 {
    assert(i < word.len);
    if (word[i] == '-') return 1;
    const c = unicode.character_at(word, i) orelse return 0;
    const dash = c.cp == en_dash or c.cp == em_dash;
    // With something after it to break before
    if (dash and i + c.len < word.len) return c.len;
    return 0;
}

/// Every place `word`, as it stands in the text, may break, shortest first. After a
/// dash it breaks as it is; inside the letters of a word it takes a hyphen. Leading
/// and trailing punctuation stay with the word.
pub fn breaks(h: ?*const Hyphenator, word: []const u8, out: *[breaks_max]Break) []Break {
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
        const lead = @max(start, unicode.start_at_or_before(word, end - 1));
        assert(end - lead <= 4); // A character takes four bytes at most
        if (is_letter_start(word, lead)) break;
        end = lead;
    }
    const core = word[start..end];
    if (core.len == 0 or core.len > word_length_max) return out[0..count];
    var lower: [word_length_max]u8 = undefined;
    if (!breaks_lowered(core, &lower)) return out[0..count]; // Left whole
    var at: [word_length_max]u32 = undefined;
    const points = hyphenator.points(lower[0..core.len], &at);
    assert(count == 0); // A word with a dash has returned already
    assert(points.len <= out.len); // Points fall between a word's letters, as many at most
    for (points) |p| {
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
        var bytes: [4]u8 = undefined;
        const encoded = unicode.encode(lowered, &bytes) orelse return false;
        if (encoded.len != c.len) return false;
        @memcpy(lower[k..][0..encoded.len], encoded);
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
            // By Unicode's case, so "NÃO" in a heading counts as "não"
            for (english) |e| {
                if (unicode.eql_ignoring_case(w, e)) en += 1;
            }
            for (portuguese) |e| {
                if (unicode.eql_ignoring_case(w, e)) pt += 1;
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
    var at: [breaks_max]Break = undefined;
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

test "every pattern is found again along its letters, with its values" {
    for ([_]Lang{ .english, .portuguese }) |lang| {
        var h = try Hyphenator.init(std.testing.allocator, lang);
        defer h.deinit();
        var lines = std.mem.tokenizeAny(u8, source(lang).patterns, " \n\r\t");
        var count: u32 = 0;
        while (lines.next()) |pattern| : (count += 1) {
            var node: u32 = Patterns.root;
            var values: [2 * pattern_length_max + 2]u8 = @splat(0);
            var letters: u32 = 0;
            for (pattern) |c| {
                if (c >= '0' and c <= '9') {
                    values[letters] = c - '0';
                } else {
                    node = h.patterns.child_of(node, c) orelse return error.PatternLost;
                    letters += 1;
                }
            }
            const found = h.patterns.nodes[node].values;
            try std.testing.expectEqualSlices(u8, values[0 .. letters + 1], found);
        }
        try std.testing.expect(count > 0);
    }
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
    // In capitals, its accented letters too: no other common word to go by
    for (&pt) |*p| p.* = .{ .text = "NÃO, NÃO" };
    try std.testing.expectEqual(Lang.portuguese, detect(&pt).?);
    const none = [_]book_model.Paragraph{.{ .text = "hello" }};
    try std.testing.expect(detect(&none) == null);
}
