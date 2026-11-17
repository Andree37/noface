//! Telling footnotes from body text, so notes leave the flow and open from their mark.
const std = @import("std");
const assert = std.debug.assert;
const book = @import("book.zig");

const max_reference_bytes = 12;

const max_label_bytes = 8;

const max_note_gap = 3;

pub const max_note_parts = 8;

comptime {
    assert(max_label_bytes <= max_reference_bytes);
    assert(max_note_gap < max_note_parts);
}

/// Paragraphs a note spans, starting at its target.
pub fn note_length(paragraphs: []const book.Paragraph, target: u32) u32 {
    assert(target < paragraphs.len);
    var n: u32 = 1;
    while (n < max_note_parts and target + n < paragraphs.len) : (n += 1) {
        const p = paragraphs[target + n];
        if (!p.note or p.note_start) break;
    }
    assert(n >= 1);
    assert(n <= max_note_parts);
    assert(target + n <= paragraphs.len);
    return n;
}

fn has_note_reference(p: *const book.Paragraph, paragraphs: []const book.Paragraph) bool {
    assert(paragraphs.len > 0); // `p` is one of them
    for (p.links) |l| {
        if (l.target < paragraphs.len and paragraphs[l.target].note_start) return true;
    }
    return false;
}

/// Note marks are numbers or symbols. A word in a link is an ordinary cross-reference.
pub fn is_mark(s: []const u8) bool {
    var letters: u32 = 0;
    var it = (std.unicode.Utf8View.init(s) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        const latin = cp >= 0xc0 and cp <= 0x24f;
        if (latin or (cp < 0x80 and std.ascii.isAlphabetic(@intCast(cp)))) letters += 1;
    }
    assert(letters <= s.len); // A letter takes a byte at least
    return letters <= 1;
}

/// Whether `text` begins with the letters and digits of `mark`, ignoring brackets and
/// spaces around either: "[12] See…" opens with "12", as does "12. See…".
fn opens_with(text: []const u8, mark: []const u8) bool {
    const core = std.mem.trim(u8, mark, " []().*\u{a0}");
    if (core.len == 0) return true; // An asterisk or dagger: nothing to compare
    const start = std.mem.trimStart(u8, text, " [(\u{a0}");
    if (!std.mem.startsWith(u8, start, core)) return false;
    assert(start.len >= core.len);
    // "1" opens "1 The note", not "12 Another"
    return start.len == core.len or !std.ascii.isDigit(start[core.len]);
}

/// A short link inside longer text pointing forward is a note reference.
/// That leaves out contents pages, where the link is the whole line, and
/// back-links inside notes, which point backward.
pub fn mark_notes(paragraphs: []book.Paragraph) void {
    for (paragraphs, 0..) |p, i| {
        for (p.links) |l| {
            // Forward only, to a paragraph of the book
            if (l.target <= i or l.target >= paragraphs.len) continue;
            // A page marker partway into a paragraph, a heading or a picture: body, not a
            // note. (A list of illustrations links its page numbers to such places.)
            // Notes themselves are often set smaller than the text, so only larger counts.
            const t = paragraphs[l.target];
            if (l.inside or t.image != null or t.look.size > book.normal_size) continue;
            // A link comes from the book: one not over this paragraph's text is no mark
            if (l.start >= l.end or l.end > p.text.len) continue;
            const span = l.end - l.start;
            if (span > max_reference_bytes or span * 2 > p.text.len) continue;
            const mark = p.text[l.start..l.end];
            if (!is_mark(mark)) continue;
            // Smaller than the text: a note only if it opens with the same mark, as
            // notes do ("1 The…"); a caption a list of pictures links to doesn't
            if (t.look.size < book.normal_size and !opens_with(t.text, mark)) continue;
            paragraphs[l.target].note = true;
            paragraphs[l.target].note_start = true;
        }
    }

    // Some books put the number in its own paragraph, with the text in the next.
    for (paragraphs, 0..) |p, i| {
        const label_only = p.note_start and p.text.len <= max_label_bytes;
        if (label_only and i + 1 < paragraphs.len) paragraphs[i + 1].note = true;
    }

    // Short gaps between two notes of a section are the rest of the first note,
    // unless a gap paragraph itself references a note, which makes it body text.
    var previous: ?u32 = null;
    for (paragraphs, 0..) |p, i| {
        if (!p.note_start) continue;
        defer previous = @intCast(i);
        const from = previous orelse continue;
        assert(from < i);
        assert(paragraphs[from].note_start);
        if (paragraphs[from].section != p.section or i - from - 1 > max_note_gap) continue;
        const gap = paragraphs[from + 1 .. i];
        var is_body = false;
        for (gap) |*g| {
            if (has_note_reference(g, paragraphs)) is_body = true;
        }
        if (is_body) continue;
        for (gap) |*g| g.note = true;
    }
}

test "short forward references mark their target as a note" {
    var paras = [_]book.Paragraph{
        .{
            .text = "body text with a reference in it",
            .links = &.{.{ .start = 10, .end = 11, .target = 2 }},
        },
        .{ .text = "more body" },
        .{ .text = "the note", .links = &.{.{ .start = 0, .end = 1, .target = 0 }} },
    };
    mark_notes(&paras);
    try std.testing.expect(paras[2].note);
    try std.testing.expect(!paras[0].note); // Back-link from the note
    try std.testing.expect(!paras[1].note);
}

test "a link reaching past its paragraph's text is skipped, never read" {
    var paras = [_]book.Paragraph{
        .{
            .text = "Some text, with a note.1",
            .links = &.{
                .{ .start = 23, .end = 25, .target = 1 },
                .{ .start = 30, .end = 31, .target = 1 },
                .{ .start = 5, .end = 5, .target = 1 },
            },
        },
        .{ .text = "1 The note." },
    };
    mark_notes(&paras);
    try std.testing.expect(!paras[1].note);
    try std.testing.expect(!paras[0].note);
}

test "page numbers that point at headings or into paragraphs hide nothing" {
    var paras = [_]book.Paragraph{
        .{ .text = "The efforts of his aunt 448", .links = &.{
            .{ .start = 24, .end = 27, .target = 1 },
            .{ .start = 24, .end = 27, .target = 2, .inside = true },
        } },
        .{ .text = "Chapter I.", .look = .{ .size = book.normal_size + 1 } },
        .{ .text = "It is a truth universally acknowledged" },
    };
    mark_notes(&paras);
    try std.testing.expect(!paras[1].note);
    try std.testing.expect(!paras[2].note);
}

test "a contents line does not hide its chapter" {
    var paras = [_]book.Paragraph{
        .{
            .text = "book.Chapter 1",
            .links = &.{.{ .start = 0, .end = 9, .target = 1 }},
        },
        .{ .text = "book.Chapter 1 begins" },
    };
    mark_notes(&paras);
    try std.testing.expect(!paras[1].note);
}

test "a number on its own takes the next paragraph with it" {
    var paras = [_]book.Paragraph{
        .{
            .text = "body text with a reference in it",
            .links = &.{.{ .start = 10, .end = 11, .target = 1 }},
        },
        .{ .text = "12" },
        .{ .text = "the note text itself, which is much longer" },
        .{ .text = "body continues here" },
    };
    mark_notes(&paras);
    try std.testing.expect(paras[1].note);
    try std.testing.expect(paras[2].note);
    try std.testing.expect(!paras[3].note);
}

test "paragraphs between notes stay with their note" {
    var paras = [_]book.Paragraph{
        .{ .text = "body text with a reference and another one", .links = &.{
            .{ .start = 5, .end = 6, .target = 1 },
            .{ .start = 9, .end = 10, .target = 3 },
        } },
        .{ .text = "first note", .section = 1 },
        .{ .text = "second paragraph of the first note", .section = 1 },
        .{ .text = "second note", .section = 1 },
        .{ .text = "next chapter", .section = 2 },
    };
    mark_notes(&paras);
    try std.testing.expect(paras[2].note);
    try std.testing.expectEqual(@as(u32, 2), note_length(&paras, 1));
    try std.testing.expectEqual(@as(u32, 1), note_length(&paras, 3));
    try std.testing.expect(!paras[4].note);
}

test "inline notes do not swallow body text with references" {
    var paras = [_]book.Paragraph{
        .{
            .text = "body text with a reference in it",
            .links = &.{.{ .start = 5, .end = 6, .target = 1 }},
        },
        .{ .text = "inline note" },
        .{
            .text = "more body text with its own reference",
            .links = &.{.{ .start = 5, .end = 6, .target = 3 }},
        },
        .{ .text = "another inline note" },
    };
    mark_notes(&paras);
    try std.testing.expect(!paras[2].note);
}

test "marks are numbers and symbols, not words" {
    try std.testing.expect(is_mark("12"));
    try std.testing.expect(is_mark("[3]"));
    try std.testing.expect(is_mark("*"));
    try std.testing.expect(is_mark("\u{2020}"));
    try std.testing.expect(is_mark("a"));
    try std.testing.expect(!is_mark("Taleb"));
    try std.testing.expect(!is_mark("\u{e9}t\u{e9}"));
}

test "a linked word does not hide its target" {
    var paras = [_]book.Paragraph{
        .{
            .text = "as argued by Popper in the earlier chapter",
            .links = &.{.{ .start = 13, .end = 19, .target = 1 }},
        },
        .{ .text = "a heading that must stay visible" },
    };
    mark_notes(&paras);
    try std.testing.expect(!paras[1].note);
}

test "a note set smaller than the text is still a note" {
    var paras = [_]book.Paragraph{
        .{
            .text = "See the note.1",
            .links = &.{.{ .start = 13, .end = 14, .target = 1 }},
        },
        .{ .text = "1 The note itself.", .look = .{ .size = 0 } },
    };
    mark_notes(&paras);
    try std.testing.expect(paras[1].note_start);
}

test "a smaller caption a list of pictures links to stays in the text" {
    var paras = [_]book.Paragraph{
        .{
            .text = "The castle at dawn 21",
            .links = &.{.{ .start = 19, .end = 21, .target = 1 }},
        },
        .{ .text = "Plate 3. The castle at dawn.", .look = .{ .size = 0 } },
    };
    mark_notes(&paras);
    try std.testing.expect(!paras[1].note_start);
}
