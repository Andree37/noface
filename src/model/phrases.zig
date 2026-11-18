//! Running mode's phrases: the book a few words at a time, for reading while running.
//! A bouncing head loses its line on a page; one short phrase at a fixed spot has no
//! line to lose. Phrases end at a clause's or a sentence's end where they can, so each
//! reads as a piece of sense, and the pause after one grows with what it ends.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("book.zig");

/// The most words in a phrase: as many as the eye takes in at a glance.
pub const words_max = 4;
/// The most bytes a phrase of more than one word spans: about two lines at running's
/// phrase size. A single longer word is a phrase by itself.
pub const bytes_max = 32;
/// A phrase's time is its words at the pace, longer after a clause, a sentence or a
/// paragraph, and between these bounds: e-ink takes a moment to change, and a word
/// can't be read faster than that.
pub const phrase_us_min = 700 * std.time.us_per_ms;
pub const phrase_us_max = 6 * std.time.us_per_s;

comptime {
    assert(words_max > 1);
    assert(phrase_us_min < phrase_us_max);
}

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
pub fn at(paras: []const book_model.Paragraph, from: book_model.Pos) ?Phrase {
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
        return in_text(p.text, para, start);
    }
    return null;
}

/// The phrase starting at `start` in `text`, a word's first byte.
fn in_text(text: []const u8, para: u32, start: u32) Phrase {
    assert(start < text.len);
    assert(!is_space(text[start]));
    var end = start;
    var words: u32 = 0;
    var ends: End = .word;
    // Each turn takes a word
    while (words < words_max) {
        const word_start = skip_spaces(text, end);
        if (word_start == text.len) break;
        const word_end = word_end_at(text, word_start);
        // Another word would run past two lines: it starts the next phrase
        if (words > 0 and word_end - start > bytes_max) break;
        end = word_end;
        words += 1;
        ends = ending(text[word_start..word_end]);
        if (ends != .word) break;
    }
    if (skip_spaces(text, end) == text.len) ends = .paragraph;
    assert(words > 0);
    assert(end > start);
    return .{ .para = para, .start = start, .end = end, .words = words, .ends = ends };
}

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
        .word => 1,
        .clause => 1.3,
        .sentence => 1.7,
        .paragraph => 2.2,
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

fn test_phrases(paras: []const book_model.Paragraph, out: [][]const u8) !u32 {
    var pos: book_model.Pos = .{};
    var count: u32 = 0;
    while (at(paras, pos)) |p| : (pos = p.after()) {
        if (count == out.len) return error.TooMany;
        out[count] = paras[p.para].text[p.start..p.end];
        count += 1;
    }
    return count;
}

test "phrases end at a clause or a sentence, run to four words at most, and skip pictures" {
    const paras = [_]book_model.Paragraph{
        .{ .text = "The old man was walking slowly down the road, and then he stopped." },
        .{ .text = "", .image = .{ .data = "", .width = 1, .height = 1 } },
        .{ .text = "  \u{201C}Wait!\u{201D} she said.  " },
        .{ .text = "A footnote", .note = true },
    };
    var out: [16][]const u8 = undefined;
    const count = try test_phrases(&paras, &out);
    const expected = [_][]const u8{
        "The old man was",
        "walking slowly down the",
        "road,",
        "and then he stopped.",
        "\u{201C}Wait!\u{201D}",
        "she said.",
    };
    try std.testing.expectEqual(@as(u32, expected.len), count);
    for (expected, out[0..count]) |e, got| try std.testing.expectEqualStrings(e, got);
}

test "a phrase never runs past two lines but for a single long word" {
    const paras = [_]book_model.Paragraph{
        .{ .text = "Incomprehensibilities notwithstanding characteristically a b" },
    };
    var out: [8][]const u8 = undefined;
    const count = try test_phrases(&paras, &out);
    try std.testing.expectEqualStrings("Incomprehensibilities", out[0]);
    for (out[0..count]) |p| {
        if (std.mem.indexOfScalar(u8, p, ' ') != null) try std.testing.expect(p.len <= bytes_max);
    }
}

test "a phrase's time grows with its words and what it ends, within bounds" {
    const word: Phrase = .{ .para = 0, .start = 0, .end = 4, .words = 4, .ends = .word };
    var sentence = word;
    sentence.ends = .sentence;
    try std.testing.expectEqual(@as(u64, 1_600_000), phrase_us(150, word));
    try std.testing.expect(phrase_us(150, sentence) > phrase_us(150, word));
    var one = word;
    one.words = 1;
    try std.testing.expectEqual(phrase_us_min, phrase_us(600, one));
    try std.testing.expectEqual(phrase_us_max, phrase_us(60, sentence));
}
