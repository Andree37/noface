//! Highlights in a book: where they sit in the text, and how they map to a page.
const std = @import("std");
const assert = std.debug.assert;
const unicode = @import("../text/unicode.zig");
const check = @import("../base/check.zig");
const book_model = @import("book.zig");
const Pos = book_model.Pos;

/// A highlight, plus the Amazon ID that keeps edits on the same record.
pub const Highlight = struct { mark: book_model.Mark, id: []const u8 };

/// Where a highlight starts and ends, which may be on other pages.
pub const Span = struct {
    first_para: u32,
    first_byte: u32,
    last_para: u32,
    last_byte: u32,

    pub fn of(lo: book_model.Word, hi: book_model.Word) Span {
        // Layout never makes a word that ends before it starts.
        assert(lo.start <= lo.end);
        assert(hi.start <= hi.end);
        return .{
            .first_para = lo.para,
            .first_byte = lo.start,
            .last_para = hi.para,
            .last_byte = hi.end,
        };
    }
};

/// A highlight's whole range, from all its marks.
pub fn extent(list: []const Highlight, id: []const u8) ?Span {
    var out: ?Span = null;
    for (list) |h| {
        if (!std.mem.eql(u8, h.id, id)) continue;
        const m = h.mark;
        if (out) |*s| {
            const mark_start: Pos = .{ .para = m.para, .byte = m.start };
            if (mark_start.is_before(.{ .para = s.first_para, .byte = s.first_byte })) {
                s.first_para = m.para;
                s.first_byte = m.start;
            }
            assert(s.first_para <= m.para);
            const mark_end: Pos = .{ .para = m.para, .byte = m.end };
            if ((Pos{ .para = s.last_para, .byte = s.last_byte }).is_before(mark_end)) {
                s.last_para = m.para;
                s.last_byte = m.end;
            }
            assert(s.last_para >= m.para);
        } else {
            out = .{
                .first_para = m.para,
                .first_byte = m.start,
                .last_para = m.para,
                .last_byte = m.end,
            };
        }
    }
    if (out) |s| assert(s.first_para <= s.last_para);
    return out;
}

/// The range after dragging one end to `head`. The other end stays where it
/// was, even off this page, unless the drag crossed `fixed`, the on-page word
/// that end sits on.
pub fn dragged(
    whole: Span,
    fixed: book_model.Word,
    head: book_model.Word,
    grab_start: bool,
    crossed: bool,
) Span {
    assert(fixed.start <= fixed.end);
    assert(head.start <= head.end);
    if (crossed) return if (grab_start) Span.of(fixed, head) else Span.of(head, fixed);
    var out = whole;
    if (grab_start) {
        out.first_para = head.para;
        out.first_byte = head.start;
        assert(out.last_byte == whole.last_byte); // The other end stays where it was
    } else {
        out.last_para = head.para;
        out.last_byte = head.end;
        assert(out.first_byte == whole.first_byte);
    }
    return out;
}

/// The start of `s`, at most `max` bytes, ending at a word and never inside a
/// character, for showing a highlight or bookmark in a list.
pub fn excerpt(s: []const u8, max: u32) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " ");
    if (trimmed.len <= max) return trimmed;
    var end = max;
    end = unicode.start_at_or_before(trimmed, end); // Never inside a character
    if (std.mem.lastIndexOfScalar(u8, trimmed[0..end], ' ')) |space| {
        if (space > max / 2) end = @intCast(space); // Before `end`, so below `max`
    }
    assert(end <= max);
    // Before a character, never inside one: in text that isn't UTF-8, a stray byte is
    // a character of its own, so no byte is asserted on here (`start_at_or_before`)
    assert(end <= trimmed.len);
    return trimmed[0..end];
}

/// Finds the paragraph and byte for one of Amazon's short positions.
pub fn locate(
    paragraphs: []const book_model.Paragraph,
    short: u32,
) ?struct { para: u32, byte: u32 } {
    var found: ?struct { para: u32, position: u32 } = null;
    for (paragraphs, 0..) |p, i| {
        const position = p.position orelse continue; // Not numbered
        if (position > short) break;
        found = .{ .para = @intCast(i), .position = position };
    }
    const f = found orelse return null;
    assert(f.para < paragraphs.len);
    assert(f.position <= short);
    const text = paragraphs[f.para].text;
    const byte = book_model.byte_offset(text, short - f.position);
    assert(byte <= text.len);
    return .{ .para = f.para, .byte = byte };
}

/// A highlight or bookmark as it's stored: its id and Amazon's character positions,
/// the Kindle's database's and noface's own file's alike.
pub const Note = struct { id: []const u8, start: u32, end: u32 };

/// Reads "id|start|end" lines from the annotation database: each laid on the book as
/// `add` lays a highlight made here, its id copied once into `alloc`.
pub fn parse(
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    notes: []const Note,
) ![]Highlight {
    var out: std.ArrayList(Highlight) = .empty;
    for (notes) |note| {
        const from = locate(paragraphs, note.start) orelse continue;
        const to = locate(paragraphs, note.end) orelse continue;
        assert(from.para < paragraphs.len);
        assert(to.para < paragraphs.len);
        const span: Span = .{
            .first_para = from.para,
            .first_byte = from.byte,
            .last_para = to.para,
            .last_byte = to.byte,
        };
        try add(&out, alloc, paragraphs, try alloc.dupe(u8, note.id), span);
    }
    return out.toOwnedSlice(alloc);
}

/// A highlight's mark in paragraph `para`, from byte `start` to `end`, or null where it
/// covers no letter: the part in the last paragraph of one that ends where that
/// paragraph starts, an empty paragraph it crosses, or a Kindle's note whose positions
/// end where (or before) they start. Every mark covers a letter at least.
fn piece(para: u32, start: u32, end: u32) ?book_model.Mark {
    if (end <= start) return null;
    return .{ .para = para, .start = start, .end = end };
}

fn overlaps(m: book_model.Mark, w: book_model.Word) bool {
    assert(w.start <= w.end);
    return w.para == m.para and w.start < m.end and w.end > m.start;
}

/// An ID for a highlight starting at `short`, taken by none in `list` nor in `stored`:
/// the IDs of every highlight the book's notes held as it opened, those `parse` could
/// not place on its text too, as saving under one would write over it. Moving a
/// highlight's start keeps its ID, so that spot can already be taken by a highlight
/// elsewhere. A damaged book's positions can reach the largest number, past which
/// there's no ID to give: `error.PositionTooLarge`, and the highlight can't be saved.
/// The model can't name the Kindle's prefix itself: the reader checks the two agree.
pub const id_format = "kindle.highlight-{d}";
/// The longest highlight id: its prefix and the largest u32.
const id_bytes_max = std.fmt.count(id_format, .{std.math.maxInt(u32)});

pub fn free_id(
    alloc: std.mem.Allocator,
    list: []const Highlight,
    stored: []const []const u8,
    short: u32,
) ![]const u8 {
    assert(list.len < std.math.maxInt(u32));
    assert(stored.len < std.math.maxInt(u32) - list.len);
    // Of `list.len + stored.len + 1` IDs in a row, the two can't hold them all: one is free
    next: for (0..list.len + stored.len + 1) |offset| {
        const candidate = std.math.add(u32, short, @intCast(offset)) catch
            return error.PositionTooLarge;
        // Each candidate written on the stack: only the free one is kept, in `alloc`
        var id_buffer: [id_bytes_max]u8 = undefined;
        const written = std.fmt.bufPrint(&id_buffer, id_format, .{candidate});
        const id = written catch unreachable; // Ignored: sized for the largest (id_bytes_max)
        for (list) |h| {
            if (std.mem.eql(u8, h.id, id)) continue :next;
        }
        for (stored) |taken| {
            if (std.mem.eql(u8, taken, id)) continue :next;
        }
        return alloc.dupe(u8, id);
    }
    unreachable;
}

/// Adds a highlight, one mark per paragraph it crosses.
pub fn add(
    list: *std.ArrayList(Highlight),
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    id: []const u8,
    span_given: Span,
) !void {
    // A damaged record from the annotation database can end before it starts, and
    // dragging one end of it keeps the other: that's outside data, so it's put in
    // order rather than stopping the reader.
    const span = ordered(span_given);
    assert(span.first_para <= span.last_para);
    check.that(span.last_para < paragraphs.len, "highlight ends inside the book");
    const count_before = list.items.len;
    var index = span.first_para;
    while (index <= span.last_para) : (index += 1) {
        const first = if (index == span.first_para) span.first_byte else 0;
        const para_len: u32 = @intCast(paragraphs[index].text.len);
        const last = if (index == span.last_para) span.last_byte else para_len;
        const mark = piece(index, first, last) orelse continue;
        try list.append(alloc, .{ .mark = mark, .id = id });
    }
    // A mark for each paragraph the highlight covers a letter of, at most one each
    assert(list.items.len - count_before <= span.last_para - span.first_para + 1);
}

/// `span` with its ends swapped if it ends before it starts.
fn ordered(span: Span) Span {
    const last: Pos = .{ .para = span.last_para, .byte = span.last_byte };
    const in_order = !last.is_before(.{ .para = span.first_para, .byte = span.first_byte });
    if (in_order) return span;
    const swapped: Span = .{
        .first_para = span.last_para,
        .first_byte = span.last_byte,
        .last_para = span.first_para,
        .last_byte = span.first_byte,
    };
    assert(swapped.first_para <= swapped.last_para);
    if (swapped.first_para == swapped.last_para) assert(swapped.first_byte < swapped.last_byte);
    return swapped;
}

/// Whether `list[i]` is the first mark of its highlight. A highlight keeps a mark per
/// paragraph it covers; this lists or counts each one once.
pub fn first_of_id(list: []const Highlight, i: u32) bool {
    assert(i < list.len);
    for (list[0..i]) |earlier| {
        if (std.mem.eql(u8, earlier.id, list[i].id)) {
            assert(i > 0);
            return false;
        }
    }
    return true;
}

/// How many highlights there are, each counted once however many paragraphs it covers.
pub fn count(list: []const Highlight) u32 {
    assert(list.len <= std.math.maxInt(u32));
    var highlights: u32 = 0;
    for (0..list.len) |i| highlights += @intFromBool(first_of_id(list, @intCast(i)));
    assert(highlights <= list.len);
    // The first mark is always the first of its highlight.
    if (list.len > 0) assert(highlights > 0);
    return highlights;
}

/// Removes every mark of a highlight.
pub fn remove(list: *std.ArrayList(Highlight), id: []const u8) void {
    const count_before = list.items.len;
    var i: u32 = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].id, id)) {
            _ = list.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    assert(list.items.len <= count_before);
    for (list.items) |h| assert(!std.mem.eql(u8, h.id, id));
}

/// First and last word of a highlight on this page.
pub fn word_range(
    words: []const book_model.Word,
    list: []const Highlight,
    id: []const u8,
) ?struct { lo: u32, hi: u32 } {
    var lo: ?u32 = null;
    var hi: u32 = 0;
    for (words, 0..) |w, i| {
        for (list) |h| {
            if (!std.mem.eql(u8, h.id, id) or !overlaps(h.mark, w)) continue;
            if (lo == null) lo = @intCast(i);
            hi = @intCast(i);
            break;
        }
    }
    const first = lo orelse return null;
    assert(first <= hi);
    assert(hi < words.len);
    return .{ .lo = first, .hi = hi };
}

/// The ID of the highlight containing a word, if any.
pub fn at_word(list: []const Highlight, w: book_model.Word) ?[]const u8 {
    assert(w.start <= w.end);
    for (list) |h| {
        if (overlaps(h.mark, w)) {
            assert(h.mark.para == w.para);
            return h.id;
        }
    }
    return null;
}

fn sample(content: []const u8, position: u32) book_model.Paragraph {
    return .{ .text = content, .position = position };
}

test "short positions find paragraph and byte" {
    const paras = [_]book_model.Paragraph{ sample("abcdef", 100), sample("\u{e1}bcd", 106) };
    const a = locate(&paras, 102).?;
    try std.testing.expectEqual(@as(u32, 0), a.para);
    try std.testing.expectEqual(@as(u32, 2), a.byte);
    const b = locate(&paras, 107).?;
    try std.testing.expectEqual(@as(u32, 1), b.para);
    try std.testing.expectEqual(@as(u32, 2), b.byte); // The accent takes two bytes
    try std.testing.expect(locate(&paras, 50) == null);
}

test "notes become marks, split across paragraphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{ sample("abcdef", 100), sample("ghijkl", 106) };
    const notes = [_]Note{
        .{ .id = "kindle.highlight-101", .start = 101, .end = 104 },
        .{ .id = "kindle.highlight-104", .start = 104, .end = 108 },
        .{ .id = "outside", .start = 1, .end = 2 }, // Before the book's first position
    };
    const list = try parse(arena.allocator(), &paras, &notes);
    try std.testing.expectEqual(@as(u32, 3), list.len);
    try std.testing.expectEqual(@as(u32, 1), list[0].mark.start);
    try std.testing.expectEqual(@as(u32, 4), list[0].mark.end);
    try std.testing.expectEqual(@as(u32, 1), list[2].mark.para);
    try std.testing.expectEqual(@as(u32, 2), list[2].mark.end);
}

test "words map to a highlight" {
    const words = [_]book_model.Word{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .para = 0, .start = 0, .end = 3 },
        .{ .x = 20, .y = 0, .w = 10, .h = 10, .para = 0, .start = 4, .end = 7 },
        .{ .x = 40, .y = 0, .w = 10, .h = 10, .para = 0, .start = 8, .end = 11 },
    };
    const list = [_]Highlight{.{ .mark = .{ .para = 0, .start = 4, .end = 11 }, .id = "x" }};
    const r = word_range(&words, &list, "x").?;
    try std.testing.expectEqual(@as(u32, 1), r.lo);
    try std.testing.expectEqual(@as(u32, 2), r.hi);
    try std.testing.expect(word_range(&words, &list, "y") == null);
    try std.testing.expectEqualStrings("x", at_word(&list, words[1]).?);
    try std.testing.expect(at_word(&list, words[0]) == null);
}

test "a highlight crossing paragraphs covers both and stays one highlight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const paras = [_]book_model.Paragraph{
        sample("first para text here", 100),
        sample("second para", 121),
    };
    const words = [_]book_model.Word{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .para = 0, .start = 11, .end = 15 },
        .{ .x = 0, .y = 20, .w = 10, .h = 10, .para = 0, .start = 16, .end = 20 },
        .{ .x = 0, .y = 40, .w = 10, .h = 10, .para = 1, .start = 0, .end = 6 },
    };
    var list: std.ArrayList(Highlight) = .empty;
    try add(&list, alloc, &paras, "h", Span.of(words[0], words[2]));
    try std.testing.expectEqual(@as(u32, 2), list.items.len);
    try std.testing.expectEqual(@as(u32, 20), list.items[0].mark.end);
    try std.testing.expectEqual(@as(u32, 0), list.items[1].mark.start);
    const r = word_range(&words, list.items, "h").?;
    try std.testing.expectEqual(@as(u32, 0), r.lo);
    try std.testing.expectEqual(@as(u32, 2), r.hi);
    remove(&list, "h");
    try std.testing.expectEqual(@as(u32, 0), list.items.len);
}

test "dragging keeps an end that sits on another page" {
    const whole = Span{ .first_para = 3, .first_byte = 10, .last_para = 8, .last_byte = 40 };
    const list = [_]Highlight{
        .{ .mark = .{ .para = 3, .start = 10, .end = 90 }, .id = "h" },
        .{ .mark = .{ .para = 8, .start = 0, .end = 40 }, .id = "h" },
        .{ .mark = .{ .para = 1, .start = 0, .end = 9 }, .id = "other" },
    };
    try std.testing.expectEqual(whole, extent(&list, "h").?);
    try std.testing.expect(extent(&list, "none") == null);

    const fixed = book_model.Word{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .para = 7,
        .start = 0,
        .end = 4,
    };
    const head = book_model.Word{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .para = 8,
        .start = 50,
        .end = 55,
    };
    const longer = dragged(whole, fixed, head, false, false);
    try std.testing.expectEqual(@as(u32, 3), longer.first_para);
    try std.testing.expectEqual(@as(u32, 10), longer.first_byte);
    try std.testing.expectEqual(@as(u32, 55), longer.last_byte);
}

test "dragging past the other end swaps the ends" {
    const whole = Span{ .first_para = 2, .first_byte = 10, .last_para = 2, .last_byte = 20 };
    const fixed = book_model.Word{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .para = 2,
        .start = 10,
        .end = 14,
    };
    const head = book_model.Word{ .x = 0, .y = 0, .w = 1, .h = 1, .para = 2, .start = 2, .end = 6 };
    const swapped = dragged(whole, fixed, head, false, true);
    try std.testing.expectEqual(@as(u32, 2), swapped.first_byte);
    try std.testing.expectEqual(@as(u32, 14), swapped.last_byte);
}

test "a new highlight never takes an ID in use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mark = book_model.Mark{ .para = 0, .start = 0, .end = 1 };
    const list = [_]Highlight{
        .{ .mark = mark, .id = "kindle.highlight-100" },
        .{ .mark = mark, .id = "kindle.highlight-101" },
    };
    const before = try free_id(arena.allocator(), &list, &.{}, 99);
    try std.testing.expectEqualStrings("kindle.highlight-99", before);
    const after = try free_id(arena.allocator(), &list, &.{}, 100);
    try std.testing.expectEqualStrings("kindle.highlight-102", after);
}

test "a new highlight never takes the ID of a stored one that wasn't placed" {
    // A Kindle note ending where it starts covers no letter, so `parse` skipped it;
    // it's still stored under its ID
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paragraphs = [_]book_model.Paragraph{.{ .text = "Some text.", .position = 10 }};
    const notes = [_]Note{
        .{ .id = "kindle.highlight-12", .start = 12, .end = 12 },
        .{ .id = "kindle.highlight-14", .start = 14, .end = 17 },
    };
    const placed = try parse(arena.allocator(), &paragraphs, &notes);
    try std.testing.expect(placed.len == 1);
    try std.testing.expectEqualStrings("kindle.highlight-12", try free_id(
        arena.allocator(),
        placed,
        &.{},
        12,
    ));
    const stored = [_][]const u8{ notes[0].id, notes[1].id };
    const id = try free_id(arena.allocator(), placed, &stored, 12);
    try std.testing.expectEqualStrings("kindle.highlight-13", id);
}

test "a highlight at the largest position has no ID to take, and never overflows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const max = std.math.maxInt(u32);
    const mark = book_model.Mark{ .para = 0, .start = 0, .end = 1 };
    const list = [_]Highlight{.{ .mark = mark, .id = "kindle.highlight-4294967295" }};
    const free = try free_id(arena.allocator(), &.{}, &.{}, max);
    try std.testing.expectEqualStrings("kindle.highlight-4294967295", free);
    const none = free_id(arena.allocator(), &list, &.{}, max);
    try std.testing.expectError(error.PositionTooLarge, none);
}

test "excerpts end at a word and never split a character" {
    try std.testing.expectEqualStrings("short", excerpt("short", 20));
    try std.testing.expectEqualStrings("one two", excerpt("one two three", 10));
    try std.testing.expectEqualStrings("caf", excerpt("caf\u{e9}", 4)); // The accent is two bytes
    try std.testing.expectEqualStrings("lead", excerpt("  lead", 20));
    // Text that isn't UTF-8 is cut where it's asked, without stopping noface: a run of
    // cp1252 dashes (0x97), and Shift-JIS kana, whose second bytes look like UTF-8's
    const dashes = "a" ++ @as([12]u8, @splat(0x97));
    try std.testing.expect(excerpt(dashes, 8).len <= 8);
    const kana_pair = [_]u8{ 0x83, 0x41, 0x83, 0x43, 0x83, 0x45 };
    const kana = kana_pair ++ kana_pair ++ kana_pair ++ kana_pair;
    try std.testing.expect(excerpt(&kana, 10).len <= 10);
}

test "a highlight over several paragraphs counts once" {
    const list = [_]Highlight{
        .{ .id = "a", .mark = .{ .para = 0, .start = 0, .end = 3 } },
        .{ .id = "a", .mark = .{ .para = 1, .start = 0, .end = 3 } },
        .{ .id = "b", .mark = .{ .para = 2, .start = 0, .end = 3 } },
    };
    try std.testing.expectEqual(@as(u32, 2), count(&list));
    try std.testing.expect(first_of_id(&list, 0));
    try std.testing.expect(!first_of_id(&list, 1));
    try std.testing.expect(first_of_id(&list, 2));
}

test "a highlight that ends before it starts is added in order, not refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{ sample("first para", 100), sample("second", 111) };
    var list: std.ArrayList(Highlight) = .empty;
    const backwards = Span{ .first_para = 1, .first_byte = 3, .last_para = 0, .last_byte = 6 };
    try add(&list, arena.allocator(), &paras, "h", backwards);
    try std.testing.expectEqual(@as(u32, 2), list.items.len);
    try std.testing.expectEqual(@as(u32, 6), list.items[0].mark.start);
    try std.testing.expectEqual(@as(u32, 3), list.items[1].mark.end);
    const reversed = Span{ .first_para = 0, .first_byte = 5, .last_para = 0, .last_byte = 2 };
    try add(&list, arena.allocator(), &paras, "g", reversed);
    try std.testing.expectEqual(@as(u32, 2), list.items[2].mark.start);
    try std.testing.expectEqual(@as(u32, 5), list.items[2].mark.end);
}

test "a highlight's pieces that cover no letter are no marks" {
    const paragraphs = [_]book_model.Paragraph{
        .{ .text = "First paragraph." },
        .{ .text = "" },
        .{ .text = "Third." },
    };
    var list: std.ArrayList(Highlight) = .empty;
    defer list.deinit(std.testing.allocator);
    // From the first paragraph's middle to where the third begins: the empty second
    // and the third's nothing make no marks
    const span: Span = .{ .first_para = 0, .first_byte = 6, .last_para = 2, .last_byte = 0 };
    try add(&list, std.testing.allocator, &paragraphs, "h", span);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u32, 0), list.items[0].mark.para);
    for (list.items) |h| try std.testing.expect(h.mark.start < h.mark.end);
}

test "finding a free id keeps only the one it gives" {
    // Ids 12 to 14 taken: 15 is given, and nothing else is left allocated
    const stored = [_][]const u8{
        "kindle.highlight-12",
        "kindle.highlight-13",
        "kindle.highlight-14",
    };
    const id = try free_id(std.testing.allocator, &.{}, &stored, 12);
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("kindle.highlight-15", id);
}
