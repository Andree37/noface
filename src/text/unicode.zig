//! What a character is, by Unicode's own tables: a letter, a digit, a mark drawn over
//! the letter before, a space; and its plain form, for matching words however a book
//! writes them. Every question about characters goes through here, the only file that
//! imports uucode (github.com/jacobsandlund/uucode, MIT, pinned in build.zig.zon), so
//! the Unicode version and the fields built into its tables (build.zig
//! `unicode_fields`) are one place to look at.
const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");

/// The highest code point Unicode has room for.
pub const code_point_max = 0x10ffff;
/// The curly quotes books are set with, and the plain ones a keyboard types for them.
const plain_quotes = [_]struct { curly: u21, plain: u21 }{
    .{ .curly = 0x2018, .plain = '\'' }, // ‘
    .{ .curly = 0x2019, .plain = '\'' }, // ’, the apostrophe in "don’t"
    .{ .curly = 0x02bc, .plain = '\'' }, // ʼ, the letter apostrophe
    .{ .curly = 0x201c, .plain = '"' }, // “
    .{ .curly = 0x201d, .plain = '"' }, // ”
    .{ .curly = 0x201e, .plain = '"' }, // „
};

/// The code points below this are ASCII, whose properties Unicode keeps as ASCII has
/// them: answered without the tables, as most of a book's characters are ASCII (the
/// tables give the same, as a test checks). In UTF-8 each is a byte of its own.
pub const ascii_end = 0x80;
/// What a byte that starts no character reads as, where text isn't UTF-8.
pub const replacement = 0xfffd;
/// How many times a canonical decomposition is followed to a letter's base: Unicode's
/// deepest (ǖ is ü and a macron, ü is u and a diaeresis) is a few steps.
const decompositions_max = 8;

/// A character in UTF-8 text: its code point, and how many bytes it takes.
pub const Character = struct { cp: u21, len: u32 };

/// The character starting at byte `i` of `text`, or null when none starts there: a
/// byte inside one, or text that isn't UTF-8.
pub fn character_at(text: []const u8, i: u32) ?Character {
    assert(i < text.len);
    if (text[i] < ascii_end) return .{ .cp = text[i], .len = 1 }; // A byte of its own
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
    if (i + len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return null;
    assert(len >= 1);
    assert(len <= 4);
    return .{ .cp = cp, .len = len };
}

/// The character starting at byte `i` of `text`, or where none does (text that isn't
/// UTF-8), that byte read as the replacement character: so a walk over any text goes
/// on a byte at a time past what isn't text.
pub fn character_or_replacement(text: []const u8, i: u32) Character {
    assert(i < text.len);
    return character_at(text, i) orelse .{ .cp = replacement, .len = 1 };
}

/// The characters of `text` one after another, a byte that isn't text read as the
/// replacement character (`character_or_replacement`): so text that isn't all UTF-8
/// still has every byte in some character, and nothing of it disappears.
pub const Characters = struct {
    text: []const u8,
    /// Where the next character starts.
    at: u32 = 0,

    pub fn next(it: *Characters) ?Character {
        assert(it.at <= it.text.len);
        if (it.at == it.text.len) return null;
        const c = character_or_replacement(it.text, it.at);
        it.at += c.len;
        assert(it.at <= it.text.len);
        return c;
    }
};

/// Whether all of `text` is UTF-8.
pub fn is_utf8(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text);
}

/// How many characters `text` has, or null when it isn't all UTF-8.
pub fn count_characters(text: []const u8) ?u32 {
    const count = std.unicode.utf8CountCodepoints(text) catch return null;
    assert(count <= text.len);
    return @intCast(count);
}

/// Whether `byte` is inside a character written in more than one byte: none starts at it.
pub fn inside_character(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// The nearest place at or before `at` that's no character's inside: `at` itself, or
/// the start of the character it's inside. `text.len` is such a place. In text that
/// isn't UTF-8, a run of continuation bytes longer than a character is stepped back
/// over three bytes at most: each stray byte is a character of its own there, read
/// as `replacement`, so any place in the run is one between characters.
pub fn start_at_or_before(text: []const u8, at: u32) u32 {
    assert(at <= text.len);
    var start = at;
    // A character is at most four bytes: at most three to step back over
    for (0..3) |_| {
        if (start == 0 or start == text.len or !inside_character(text[start])) break;
        start -= 1;
    }
    assert(start <= at);
    return start;
}

/// The nearest place at or after `at` that's no character's inside: `at` itself, or
/// the start of the next character. `text.len` is such a place.
pub fn start_at_or_after(text: []const u8, at: u32) u32 {
    assert(at <= text.len);
    var start = at;
    for (0..3) |_| {
        if (start == text.len or !inside_character(text[start])) break;
        start += 1;
    }
    assert(start >= at);
    return start;
}

/// `cp` in UTF-8, in `out`, or null for a code point UTF-8 can't hold (a surrogate).
pub fn encode(cp: u21, out: *[4]u8) ?[]const u8 {
    assert(cp <= code_point_max);
    const length = std.unicode.utf8Encode(cp, out) catch return null;
    return out[0..length];
}

/// `cp` as words are matched, ignoring case and accents: its base letter (its
/// canonical decomposition's first code point, as Unicode gives it) case-folded, so "Ação"
/// and "acao" match. One code point for one, so a match's place in the text is where it
/// starts; a letter with no base of its own (æ, ß, ø) is only case-folded.
pub fn fold(cp: u21) u21 {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.toLower(@intCast(cp));
    // Typographic quotes are the keyboard's plain ones: "don't" finds “don’t”
    for (plain_quotes) |q| {
        if (q.curly == cp) return q.plain;
    }
    const folded = uucode.get(.case_folding_simple, base(uucode.get(.case_folding_simple, cp)));
    // Folding again changes nothing: a key folded once is found by its folded word
    assert(uucode.get(.case_folding_simple, folded) == folded);
    return folded;
}

/// The letter `cp` is made from, without the accents its canonical decomposition puts
/// on it: `cp` itself when it has none.
fn base(cp: u21) u21 {
    assert(cp <= code_point_max);
    var at = cp;
    for (0..decompositions_max) |_| {
        if (uucode.get(.decomposition_type, at) != .canonical) return at;
        var buffer: [1]u21 = undefined;
        const parts = uucode.get(.decomposition_mapping, at).with(&buffer, at);
        assert(parts.len > 0); // A canonical decomposition decomposes into something
        assert(parts[0] != at); // Into something else, so following it ends
        at = parts[0];
    }
    unreachable; // See `decompositions_max`
}

/// `cp` with its case folded, as text is compared ignoring case: unlike `fold`, its
/// accents kept ("Âmes" is "âmes", not "ames").
pub fn fold_case(cp: u21) u21 {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.toLower(@intCast(cp));
    return uucode.get(.case_folding_simple, cp);
}

/// How `a` and `b` are ordered ignoring case, character by character in any script; a
/// byte that starts no character is compared as it is.
pub fn order_ignoring_case(a: []const u8, b: []const u8) std.math.Order {
    var i: u32 = 0;
    var j: u32 = 0;
    // Bounded by the shorter text: each pass moves both on by a character or a byte
    while (i < a.len and j < b.len) {
        const ka = order_key(a, i);
        const kb = order_key(b, j);
        const order = std.math.order(ka.key, kb.key);
        if (order != .eq) return order;
        i += ka.len;
        j += kb.len;
    }
    assert(i >= a.len or j >= b.len);
    return std.math.order(a.len - i, b.len - j);
}

/// What the character at `i` sorts by, ignoring case: its case-folded code point, or
/// for a byte that starts none, a key past every code point, the byte's own, so stray
/// bytes sort after text and apart from each other, never as a letter (0xE3 isn't ã).
fn order_key(text: []const u8, i: u32) struct { key: u32, len: u32 } {
    assert(i < text.len);
    if (character_at(text, i)) |c| return .{ .key = fold_case(c.cp), .len = c.len };
    return .{ .key = code_point_max + 1 + @as(u32, text[i]), .len = 1 };
}

/// Whether `a` and `b` are the same text ignoring case, in any script.
pub fn eql_ignoring_case(a: []const u8, b: []const u8) bool {
    return order_ignoring_case(a, b) == .eq;
}

/// Whether `a` comes before `b` ignoring case, in any script: for sorting names.
pub fn less_ignoring_case(a: []const u8, b: []const u8) bool {
    return order_ignoring_case(a, b) == .lt;
}

/// `cp` in lowercase, by Unicode's simple mapping: one code point for one.
pub fn lowercase(cp: u21) u21 {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.toLower(@intCast(cp));
    return uucode.get(.simple_lowercase_mapping, cp);
}

const Category = uucode.TypeOf(.general_category);
const Bidi = uucode.TypeOf(.bidi_class);

const letters = [_]Category{
    .letter_uppercase, .letter_lowercase, .letter_titlecase, .letter_modifier, .letter_other,
};
const numbers = [_]Category{ .number_decimal_digit, .number_letter, .number_other };
/// Marks that take no room: a nonspacing one (an accent), an enclosing one (a circle).
const combining = [_]Category{ .mark_nonspacing, .mark_enclosing };
/// What Python's `str.isspace` takes for a space besides a space separator: a
/// character that's bidirectionally a space, a segment break or a paragraph break.
const spacing = [_]Bidi{ .whitespace, .segment_separator, .paragraph_separator };

/// Whether `value` is one of `set`.
fn one_of(comptime T: type, value: T, comptime set: []const T) bool {
    inline for (set) |member| {
        if (value == member) return true;
    }
    return false;
}

/// `cp` in uppercase, by Unicode's simple mapping: one code point for one.
pub fn uppercase(cp: u21) u21 {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.toUpper(@intCast(cp));
    return uucode.get(.simple_uppercase_mapping, cp);
}

/// Whether `cp` is a letter, in any script.
pub fn is_letter(cp: u21) bool {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.isAlphabetic(@intCast(cp));
    return one_of(Category, uucode.get(.general_category, cp), &letters);
}

/// Whether `text` has a letter in it, in any script: a name, not a number or a year.
pub fn has_letter(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32)); // A name or a word, counted in a u32
    var i: u32 = 0;
    while (i < text.len) {
        const c = character_at(text, i) orelse {
            i += 1; // Not UTF-8 here: no letter
            continue;
        };
        if (is_letter(c.cp)) return true;
        i += c.len;
    }
    assert(i >= text.len);
    return false;
}

/// Whether `cp` is a letter or a digit, or any other number (a Roman numeral, ½).
pub fn is_letter_or_number(cp: u21) bool {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.isAlphanumeric(@intCast(cp));
    const category = uucode.get(.general_category, cp);
    return one_of(Category, category, &letters) or one_of(Category, category, &numbers);
}

/// Whether `cp` is a mark drawn on the character before it, taking no room of its own:
/// an accent written apart from its letter, a vowel sign over a consonant.
pub fn is_combining(cp: u21) bool {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return false;
    return one_of(Category, uucode.get(.general_category, cp), &combining);
}

/// Whether `cp` is drawn as nothing at all, taking no room: a variation selector (the
/// one asking ❤ to show as a picture), a zero-width joiner or space, a word joiner.
pub fn is_invisible(cp: u21) bool {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return false;
    return uucode.get(.is_default_ignorable, cp);
}

/// Scripts written without spaces between words, whose every character is counted as
/// a word, as word counters count Chinese and Japanese.
const word_per_character = [_]Script{ .han, .hiragana, .katakana };
const Script = uucode.TypeOf(.script);

/// Whether `cp` is read as a word by itself: a character of Chinese or Japanese, which
/// put no spaces between words.
pub fn is_word_by_itself(cp: u21) bool {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return false;
    return one_of(Script, uucode.get(.script, cp), &word_per_character);
}

/// Where words start, the one rule every counter of words reads text by: running's
/// phrases and the words left alike, so the two always agree. What came before a
/// character: a space (or the text's start), a word, or a word by itself and what
/// stays with it (its punctuation and marks).
pub const WordState = enum { space, word, by_itself };

/// Whether `cp` starts a word after `before`, and what it leaves for the next: a word
/// starts at a word by itself, and at anything but a space after a space; after a word
/// by itself, a letter or a number starts the next, as '。' stays with its sentence.
pub fn word_step(before: WordState, cp: u21) struct { starts: bool, after: WordState } {
    assert(cp <= code_point_max);
    if (is_space(cp)) return .{ .starts = false, .after = .space };
    if (is_word_by_itself(cp)) return .{ .starts = true, .after = .by_itself };
    return switch (before) {
        .space => .{ .starts = true, .after = .word },
        .word => .{ .starts = false, .after = .word },
        .by_itself => if (is_letter_or_number(cp))
            .{ .starts = true, .after = .word }
        else
            .{ .starts = false, .after = .by_itself },
    };
}

/// Whether `cp` is a space of any width, a line or paragraph break, or a tab, as
/// Python's `str.isspace` has it.
pub fn is_space(cp: u21) bool {
    assert(cp <= code_point_max);
    if (uucode.get(.general_category, cp) == .separator_space) return true;
    return one_of(Bidi, uucode.get(.bidi_class, cp), &spacing);
}

test "a character is read where one starts, and nowhere else" {
    const text = "a\u{e9}\u{201c}";
    try std.testing.expectEqual(Character{ .cp = 'a', .len = 1 }, character_at(text, 0).?);
    try std.testing.expectEqual(Character{ .cp = 0xe9, .len = 2 }, character_at(text, 1).?);
    try std.testing.expect(character_at(text, 2) == null); // Inside é
    try std.testing.expectEqual(Character{ .cp = 0x201c, .len = 3 }, character_at(text, 3).?);
    try std.testing.expect(character_at(text[0..4], 3) == null); // Cut short
}

test "words match however their letters are accented or cased" {
    const pairs = [_][2]u21{
        .{ 'A', 'a' }, .{ 'a', 'a' }, .{ 0xc7, 'c' }, // Ç
        .{ 0xe3, 'a' }, // ã
        .{ 0x1d6, 'u' }, // ǖ, two accents deep
        .{ 0x130, 'i' }, // İ
        .{ 0x386, 0x3b1 }, // Ά, Greek
        .{ 0x419, 0x438 }, // Й, Cyrillic
        .{ 0xc6, 0xe6 }, // Æ: no base of its own, only lowercased
        .{ 0xd8, 0xf8 }, // Ø
        .{ 0xdf, 0xdf }, // ß: one code point for one
        .{ '1', '1' }, .{ ' ', ' ' }, .{ 0x2019, '\'' }, .{ 0x201c, '"' }, // Quotes plain
    };
    for (pairs) |pair| try std.testing.expectEqual(pair[1], fold(pair[0]));
}

test "letters are told from digits, marks, spaces and punctuation in any script" {
    for ([_]u21{ 'a', 'Z', 0xe9, 0x3b1, 0x4e2d, 0x5d0 }) |cp| try std.testing.expect(is_letter(cp));
    for ([_]u21{ '1', '.', ' ', 0x301, 0x2019, 0x2014 }) |cp| {
        try std.testing.expect(!is_letter(cp));
    }
    try std.testing.expect(has_letter("1984 \u{4e2d}"));
    try std.testing.expect(!has_letter("1984, \u{2014}"));
    try std.testing.expect(is_letter_or_number('7'));
    try std.testing.expect(is_letter_or_number(0xbd)); // ½
    try std.testing.expect(!is_letter_or_number(0x201c)); // “
    try std.testing.expect(is_combining(0x301)); // A combining acute accent
    try std.testing.expect(!is_combining(0x93f)); // A vowel sign that takes room
    try std.testing.expect(is_combining(0x941)); // One that doesn't
    try std.testing.expect(!is_combining('e'));
    for ([_]u21{ 0xfe0f, 0xe0100, 0x34f, 0x200d, 0x200b }) |cp| {
        try std.testing.expect(is_invisible(cp));
    }
    for ([_]u21{ 'a', ' ', 0x301, 0x2764 }) |cp| try std.testing.expect(!is_invisible(cp));
    for ([_]u21{ ' ', '\t', '\n', 0xa0, 0x3000, 0x2029 }) |cp| try std.testing.expect(is_space(cp));
    for ([_]u21{ 'a', 0x200b, '-' }) |cp| try std.testing.expect(!is_space(cp));
    try std.testing.expectEqual(@as(u21, 0xe9), lowercase(0xc9)); // É
    try std.testing.expectEqual(@as(u21, 0xc7), uppercase(0xe7)); // ç to Ç
    try std.testing.expectEqual(@as(u21, 0xdf), uppercase(0xdf)); // ß: no one letter for it
}

test "a word folded once folds to itself again, in every script" {
    // A dictionary's keys are folded words: a word looked up folds to its key only if
    // folding its key changes nothing
    var cp: u21 = 0;
    while (cp <= code_point_max) : (cp += 1) {
        const surrogate = cp >= 0xd800 and cp <= 0xdfff; // Never in UTF-8
        if (surrogate) continue;
        const folded = fold(cp);
        try std.testing.expectEqual(folded, fold(folded));
    }
}

test "names compare ignoring case in any script, accents kept" {
    try std.testing.expect(eql_ignoring_case("Les \u{e2}mes", "les \u{c2}MES"));
    try std.testing.expect(!eql_ignoring_case("Les \u{e2}mes", "Les ames"));
    try std.testing.expect(eql_ignoring_case("\u{3a3}\u{3bf}", "\u{3c3}\u{3bf}")); // Σο, σο
    try std.testing.expect(less_ignoring_case("apple", "Banana"));
    try std.testing.expect(less_ignoring_case("The", "the end")); // A start before more
    try std.testing.expect(!less_ignoring_case("b", "B"));
}

test "the spaces are exactly those Python's str.split() splits on" {
    // As the Python script the dictionary builder replaced had them
    const python_spaces = [_]u21{
        0x09,   0x0A,   0x0B,   0x0C,   0x0D,   0x1C,   0x1D,   0x1E,   0x1F,   0x20,
        0x85,   0xA0,   0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
        0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    };
    var count: u32 = 0;
    var cp: u21 = 0;
    while (cp <= code_point_max) : (cp += 1) {
        if (!is_space(cp)) continue;
        count += 1;
        try std.testing.expect(std.mem.indexOfScalar(u21, &python_spaces, cp) != null);
    }
    try std.testing.expectEqual(@as(u32, python_spaces.len), count);
}

test "ASCII is answered as Unicode's tables answer it" {
    var cp: u21 = 0;
    while (cp < ascii_end) : (cp += 1) {
        const category = uucode.get(.general_category, cp);
        const letter = one_of(Category, category, &letters);
        const number = one_of(Category, category, &numbers);
        try std.testing.expectEqual(letter, is_letter(cp));
        try std.testing.expectEqual(letter or number, is_letter_or_number(cp));
        try std.testing.expectEqual(one_of(Category, category, &combining), is_combining(cp));
        try std.testing.expectEqual(uucode.get(.simple_lowercase_mapping, cp), lowercase(cp));
        try std.testing.expectEqual(uucode.get(.simple_uppercase_mapping, cp), uppercase(cp));
        const folded = uucode.get(.case_folding_simple, base(uucode.get(.case_folding_simple, cp)));
        try std.testing.expectEqual(folded, fold(cp));
    }
}

test "Chinese and Japanese characters are words by themselves, and other scripts' aren't" {
    try std.testing.expect(is_word_by_itself(0x732b)); // 猫, Han
    try std.testing.expect(is_word_by_itself(0x306f)); // は, Hiragana
    try std.testing.expect(is_word_by_itself(0x30cd)); // ネ, Katakana
    try std.testing.expect(!is_word_by_itself('a'));
    try std.testing.expect(!is_word_by_itself(0xe9)); // é
    try std.testing.expect(!is_word_by_itself(0xd55c)); // 한, Korean puts spaces between words
    try std.testing.expect(!is_word_by_itself(0x0e01)); // ก, Thai
}

test "places in text are moved to a character's start, back or on" {
    const text = "a\u{e7}\u{20ac}b"; // a, ç (2 bytes), € (3), b
    try std.testing.expectEqual(@as(u32, 1), start_at_or_before(text, 2)); // Inside ç
    try std.testing.expectEqual(@as(u32, 3), start_at_or_before(text, 5)); // Inside €
    try std.testing.expectEqual(@as(u32, 6), start_at_or_before(text, 6)); // b
    try std.testing.expectEqual(@as(u32, 7), start_at_or_before(text, 7)); // The end
    try std.testing.expectEqual(@as(u32, 3), start_at_or_after(text, 2));
    try std.testing.expectEqual(@as(u32, 6), start_at_or_after(text, 4));
    try std.testing.expectEqual(@as(u32, 0), start_at_or_after(text, 0));
    // A run of bytes inside characters longer than any is never walked past bounds
    const broken = "\x80\x80\x80\x80\x80";
    try std.testing.expect(start_at_or_before(broken, 4) <= 4);
    try std.testing.expect(start_at_or_after(broken, 0) <= broken.len);
}

test "a code point is encoded, and a byte no character starts reads as the replacement" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\u{20ac}", encode(0x20ac, &out).?);
    try std.testing.expect(encode(0xd800, &out) == null); // A surrogate
    const not_utf8 = character_or_replacement("\xa0", 0);
    try std.testing.expectEqual(Character{ .cp = replacement, .len = 1 }, not_utf8);
    const no_break_space = character_or_replacement("\u{a0}", 0);
    try std.testing.expectEqual(Character{ .cp = 0xa0, .len = 2 }, no_break_space);
}

test "a walk over characters reads every byte, one that isn't text as the replacement" {
    var it = Characters{ .text = "a\xffb\u{e9}" };
    try std.testing.expectEqual(@as(u21, 'a'), it.next().?.cp);
    try std.testing.expectEqual(@as(u21, replacement), it.next().?.cp);
    try std.testing.expectEqual(@as(u21, 'b'), it.next().?.cp);
    try std.testing.expectEqual(Character{ .cp = 0xe9, .len = 2 }, it.next().?);
    try std.testing.expect(it.next() == null);
}

test "a byte that isn't text is never taken for a letter, when sorting or matching" {
    try std.testing.expect(!eql_ignoring_case("\xc3", "\u{e3}")); // Not ã
    try std.testing.expect(!eql_ignoring_case("\xc3", "\xc4")); // Two stray bytes differ
    try std.testing.expect(eql_ignoring_case("\xc3", "\xc3"));
    try std.testing.expect(less_ignoring_case("zebra", "\xc3")); // After every letter
}
