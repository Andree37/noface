//! Running mode's phrases: the book a sentence at a time, for reading while running.
//! A bouncing head loses its line on a page; one sentence, large, at a fixed spot, has
//! few lines and no page to lose them in. A sentence too long for the space is cut at
//! its last clause that fits (a comma, a semicolon, a dash), or failing one, at its
//! last word that does: each piece reads as sense, not a few words cut off mid-thought.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("book.zig");

/// A phrase's time is its words at the pace, a little longer after a sentence or a
/// paragraph, and between these bounds: e-ink takes a moment to change.
pub const phrase_us_min = 1500 * std.time.us_per_ms;
/// About the words a phrase aims at: enough to read as a piece of the story, few
/// enough to take in at a glance from a treadmill.
pub const words_aim = 8;
/// The most words in a phrase: a longer sentence is cut, so a phrase is still taken in
/// a glance or two, not read line by line as a page is.
pub const words_max = 18;
pub const phrase_us_max = 40 * std.time.us_per_s;

comptime {
    assert(phrase_us_min < phrase_us_max);
    assert(words_aim < words_max);
    assert(words_max < words_max_read);
}

/// Whether some text fits the space phrases are shown in, as the caller lays it out.
pub const Fits = struct {
    ctx: *const anyopaque,
    call: *const fn (ctx: *const anyopaque, text: []const u8) bool,

    fn fits(f: Fits, text: []const u8) bool {
        assert(text.len > 0);
        return f.call(f.ctx, text);
    }
};

/// What a phrase ends: the reader takes a breath after each, longer for the larger.
pub const End = enum { word, clause, sentence, paragraph };

/// Bytes `start` to `end` of paragraph `para`'s text.
pub const Phrase = struct {
    para: u32,
    start: u32,
    end: u32,
    words: u32,
    ends: End,

    /// Where the phrase after it is looked for.
    pub fn after(p: Phrase) book_model.Pos {
        return .{ .para = p.para, .byte = p.end };
    }
};

/// The phrase at `from`, or the first after it: paragraphs with no words (a picture,
/// a note's text, kept out of the flow) are passed over. Null past the book's last word.
pub fn at(paras: []const book_model.Paragraph, from: book_model.Pos, fits: Fits) ?Phrase {
    var para = from.para;
    var byte = from.byte;
    // Each turn passes a paragraph
    while (para < paras.len) : ({
        para += 1;
        byte = 0;
    }) {
        const p = paras[para];
        if (p.image != null or p.note) continue;
        assert(byte <= p.text.len);
        const start = skip_spaces(p.text, byte);
        if (start == p.text.len) continue;
        return in_text(p.text, para, start, fits);
    }
    return null;
}

/// The phrase starting at `start` in `text`, a word's first byte: balanced, neither
/// a few words cut off nor a wall of text. A sentence that fits is whole, and a short
/// one takes the sentences after it in its paragraph, whole, until there are about
/// `words_aim` words or no more fit. One too long is cut into pieces about as long as
/// each other, at a clause's end near where an even cut falls, if there is one.
fn in_text(text: []const u8, para: u32, start: u32, fits: Fits) Phrase {
    assert(start < text.len);
    assert(!is_space(text[start]));
    var sentence: Sentence = undefined;
    const n = sentence.read(text, start);
    assert(n > 0);
    // How many of its words fit, found by halving: what fits grows with the words. A
    // word too long by itself is a phrase alone
    var fit: u32 = 1; // Fits, or is the first word, which is taken whatever its length
    var over: u32 = n + 1; // The fewest words known not to fit
    if (fits.fits(text[start..sentence.ends[n - 1]])) fit = n else over = n;
    // Each turn halves the words between the two
    while (over - fit > 1) {
        const middle = fit + (over - fit) / 2;
        if (fits.fits(text[start..sentence.ends[middle - 1]])) fit = middle else over = middle;
    }
    assert(fit >= 1);
    assert(fit <= n);
    fit = @min(fit, words_max);
    if (fit < n) {
        const count = even_cut(&sentence, n, fit);
        assert(count > 0);
        assert(count <= fit);
        return phrase_to(text, para, start, sentence.ends[count - 1], count);
    }
    // Whole: and, while short, the whole sentences after it that fit with it
    var end = sentence.ends[n - 1];
    var words = n;
    // Each turn takes a sentence, at least a word
    while (words < words_aim) {
        const next = skip_spaces(text, end);
        if (next == text.len) break;
        var more: Sentence = undefined;
        const m = more.read(text, next);
        if (words + m > words_max) break; // Too long to take whole
        if (!fits.fits(text[start..more.ends[m - 1]])) break;
        end = more.ends[m - 1];
        words += m;
    }
    return phrase_to(text, para, start, end, words);
}

/// The phrase from `start` to `end`, and what it ends there.
fn phrase_to(text: []const u8, para: u32, start: u32, end: u32, words: u32) Phrase {
    assert(start < end);
    assert(end <= text.len);
    var word_start = end;
    while (word_start > start and !is_space(text[word_start - 1])) word_start -= 1;
    var ends = ending(text[word_start..end]);
    if (skip_spaces(text, end) == text.len) ends = .paragraph;
    return .{ .para = para, .start = start, .end = end, .words = words, .ends = ends };
}

/// Where to cut a sentence of `n` words, `fit` of which fit: after the clause end
/// nearest an even cut, from half that on, or at the even cut itself.
fn even_cut(sentence: *const Sentence, n: u32, fit: u32) u32 {
    assert(fit < n);
    assert(fit > 0);
    const pieces = (n + fit - 1) / fit;
    const even = (n + pieces - 1) / pieces;
    assert(even <= fit);
    var best = even;
    var best_distance: u32 = std.math.maxInt(u32);
    for (@max(even / 2, 1)..fit + 1) |count| {
        if (sentence.marks[count - 1] != .clause) continue;
        const words: u32 = @intCast(count);
        const distance = if (words > even) words - even else even - words;
        if (distance < best_distance) {
            best = words;
            best_distance = distance;
        }
    }
    return best;
}

/// The most words of a sentence looked at: one longer is cut where these end.
const words_max_read = 256;

/// A sentence's words, from a word's start: where each ends, and what it ends.
const Sentence = struct {
    ends: [words_max_read]u32,
    marks: [words_max_read]End,

    /// Reads to the sentence's end, the paragraph's, or `words_max_read` words.
    /// Returns how many words.
    fn read(sentence: *Sentence, text: []const u8, start: u32) u32 {
        assert(start < text.len);
        var at_byte = start;
        var count: u32 = 0;
        while (count < words_max_read) {
            const word_start = skip_spaces(text, at_byte);
            if (word_start == text.len) break;
            const word_end = word_end_at(text, word_start);
            sentence.ends[count] = word_end;
            sentence.marks[count] = ending(text[word_start..word_end]);
            count += 1;
            at_byte = word_end;
            if (sentence.marks[count - 1] == .sentence) break;
        }
        assert(count > 0); // `start` is a word's first byte
        return count;
    }
};

/// What a word ends, by its last mark before any closing quote or bracket.
fn ending(word: []const u8) End {
    assert(word.len > 0);
    var trimmed = word;
    // Closing quotes and brackets, in ASCII or UTF-8, come after the mark that counts
    const closers = [_][]const u8{ "\"", "'", ")", "]", "\u{201D}", "\u{2019}", "\u{00BB}" };
    for (0..4) |_| {
        var cut = false;
        for (closers) |c| {
            if (trimmed.len > c.len and std.mem.endsWith(u8, trimmed, c)) {
                trimmed = trimmed[0 .. trimmed.len - c.len];
                cut = true;
            }
        }
        if (!cut) break;
    }
    const sentence = [_][]const u8{ ".", "!", "?", "\u{2026}" };
    for (sentence) |m| if (std.mem.endsWith(u8, trimmed, m)) return .sentence;
    const clause = [_][]const u8{ ",", ";", ":", "\u{2014}", "\u{2013}" };
    for (clause) |m| if (std.mem.endsWith(u8, trimmed, m)) return .clause;
    return .word;
}

/// How long a phrase stays up at `wpm`.
pub fn phrase_us(wpm: f64, p: Phrase) u64 {
    assert(wpm > 0);
    assert(p.words > 0);
    const breath: f64 = switch (p.ends) {
        .word, .clause => 1,
        .sentence => 1.1,
        .paragraph => 1.25,
    };
    const us = @as(f64, @floatFromInt(p.words)) * 60 / wpm * breath * std.time.us_per_s;
    const capped = @min(us, @as(f64, phrase_us_max));
    const result = std.math.clamp(@as(u64, @intFromFloat(capped)), phrase_us_min, phrase_us_max);
    assert(result >= phrase_us_min);
    return result;
}

fn is_space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skip_spaces(text: []const u8, from: u32) u32 {
    var at_byte = from;
    while (at_byte < text.len and is_space(text[at_byte])) at_byte += 1;
    return at_byte;
}

fn word_end_at(text: []const u8, from: u32) u32 {
    assert(from < text.len);
    var at_byte = from;
    while (at_byte < text.len and !is_space(text[at_byte])) at_byte += 1;
    assert(at_byte > from);
    return at_byte;
}

/// Fits text of up to `bytes` bytes: a stand-in for a font's measure.
fn test_fits(bytes: *const u32) Fits {
    const Measure = struct {
        fn call(ctx: *const anyopaque, text: []const u8) bool {
            const most: *const u32 = @ptrCast(@alignCast(ctx));
            return text.len <= most.*;
        }
    };
    return .{ .ctx = bytes, .call = Measure.call };
}

fn test_phrases(paras: []const book_model.Paragraph, bytes: u32, out: [][]const u8) !u32 {
    var pos: book_model.Pos = .{};
    var count: u32 = 0;
    const room = bytes;
    while (at(paras, pos, test_fits(&room))) |p| : (pos = p.after()) {
        if (count == out.len) return error.TooMany;
        out[count] = paras[p.para].text[p.start..p.end];
        count += 1;
    }
    return count;
}

test "short sentences join, long ones are cut evenly at a clause, and pictures are skipped" {
    const paras = [_]book_model.Paragraph{
        .{ .text = "He sat. She stood. They waited by the old gate for an hour or more." },
        .{ .text = "", .image = .{ .data = "", .width = 1, .height = 1 } },
        .{ .text = "  \u{201C}Wait!\u{201D} she said.  " },
        .{ .text = "A footnote", .note = true },
        .{ .text = "one two three four five six, seven eight nine ten eleven twelve" },
    };
    var out: [16][]const u8 = undefined;
    const count = try test_phrases(&paras, 80, &out);
    const expected = [_][]const u8{
        // Two short sentences take the third, as all fit
        "He sat. She stood. They waited by the old gate for an hour or more.",
        "\u{201C}Wait!\u{201D} she said.",
        "one two three four five six, seven eight nine ten eleven twelve",
    };
    try std.testing.expectEqual(@as(u32, expected.len), count);
    for (expected, out[0..count]) |e, got| try std.testing.expectEqualStrings(e, got);
    // With less room: two pieces of six at its comma, not nine and a leftover three
    const short = try test_phrases(paras[4..], 50, &out);
    try std.testing.expectEqual(@as(u32, 2), short);
    try std.testing.expectEqualStrings("one two three four five six,", out[0]);
    // Short sentences join only while they fit
    const tight = try test_phrases(paras[0..1], 20, &out);
    try std.testing.expectEqualStrings("He sat. She stood.", out[0]);
    try std.testing.expect(tight > 2);
}

test "a long sentence is cut into even pieces of at most the most words, however wide the space" {
    const paras = [_]book_model.Paragraph{
        .{ .text = "a b c d e f g h i j k l m n o p q r s t u v w x y z a b c d e f g h i j k" },
    };
    var out: [8][]const u8 = undefined;
    const count = try test_phrases(&paras, 1000, &out);
    // 37 words: three pieces of 13, 13 and 11, not 18, 18 and 1
    try std.testing.expectEqual(@as(u32, 3), count);
    for (out[0..count]) |piece| {
        const words = std.mem.count(u8, piece, " ") + 1;
        try std.testing.expect(words >= 11);
        try std.testing.expect(words <= words_max);
    }
}

test "a word too long for the space is a phrase by itself" {
    const paras = [_]book_model.Paragraph{.{ .text = "Incomprehensibilities notwithstanding a" }};
    var out: [8][]const u8 = undefined;
    _ = try test_phrases(&paras, 10, &out);
    try std.testing.expectEqualStrings("Incomprehensibilities", out[0]);
}

test "a phrase's time grows with its words and what it ends, within bounds" {
    const word: Phrase = .{ .para = 0, .start = 0, .end = 4, .words = 10, .ends = .word };
    var sentence = word;
    sentence.ends = .sentence;
    try std.testing.expectEqual(@as(u64, 4_000_000), phrase_us(150, word));
    try std.testing.expect(phrase_us(150, sentence) > phrase_us(150, word));
    var one = word;
    one.words = 1;
    try std.testing.expectEqual(phrase_us_min, phrase_us(600, one));
    var long = sentence;
    long.words = 400;
    try std.testing.expectEqual(phrase_us_max, phrase_us(60, long));
}
