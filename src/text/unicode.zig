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
/// The code points below this are ASCII, whose properties Unicode keeps as ASCII has
/// them: answered without the tables, as most of a book's characters are ASCII (the
/// tables give the same, as a test checks).
const ascii_end = 0x80;
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

/// `cp` as words are matched, ignoring case and accents: its base letter (its
/// canonical decomposition's first code point, as Unicode gives it) case-folded, so "Ação"
/// and "acao" match. One code point for one, so a match's place in the text is where it
/// starts; a letter with no base of its own (æ, ß, ø) is only case-folded.
pub fn fold(cp: u21) u21 {
    assert(cp <= code_point_max);
    if (cp < ascii_end) return std.ascii.toLower(@intCast(cp));
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
        .{ '1', '1' }, .{ ' ', ' ' }, .{ 0x2019, 0x2019 }, // ’ is no letter
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
    for ([_]u21{ ' ', '\t', '\n', 0xa0, 0x3000, 0x2029 }) |cp| try std.testing.expect(is_space(cp));
    for ([_]u21{ 'a', 0x200b, '-' }) |cp| try std.testing.expect(!is_space(cp));
    try std.testing.expectEqual(@as(u21, 0xe9), lowercase(0xc9)); // É
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
        const folded = uucode.get(.case_folding_simple, base(uucode.get(.case_folding_simple, cp)));
        try std.testing.expectEqual(folded, fold(cp));
    }
}
