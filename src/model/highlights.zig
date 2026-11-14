//! Highlights in a book: where they sit in the text, and how they map to a page.
const std = @import("std");
const check = @import("../base/check.zig");
const book_model = @import("book.zig");

/// A highlight, plus the Amazon ID that keeps edits on the same record.
pub const Highlight = struct { mark: book_model.Mark, id: []const u8 };

/// Where a highlight starts and ends, which may be on other pages.
pub const Span = struct {
    first_para: u32,
    first_byte: u32,
    last_para: u32,
    last_byte: u32,

    pub fn of(lo: book_model.Word, hi: book_model.Word) Span {
        return .{ .first_para = lo.para, .first_byte = lo.start, .last_para = hi.para, .last_byte = hi.end };
    }
};

/// A highlight's whole range, from all its marks.
pub fn extent(list: []const Highlight, id: []const u8) ?Span {
    var out: ?Span = null;
    for (list) |h| {
        if (!std.mem.eql(u8, h.id, id)) continue;
        const m = h.mark;
        if (out) |*s| {
            if (m.para < s.first_para or (m.para == s.first_para and m.start < s.first_byte)) {
                s.first_para = m.para;
                s.first_byte = m.start;
            }
            if (m.para > s.last_para or (m.para == s.last_para and m.end > s.last_byte)) {
                s.last_para = m.para;
                s.last_byte = m.end;
            }
        } else out = .{ .first_para = m.para, .first_byte = m.start, .last_para = m.para, .last_byte = m.end };
    }
    return out;
}

/// The range after dragging one end to `head`. The other end stays where it
/// was, even off this page, unless the drag crossed `fixed`, the on-page word
/// that end sits on.
pub fn dragged(whole: Span, fixed: book_model.Word, head: book_model.Word, grab_start: bool, crossed: bool) Span {
    if (crossed) return if (grab_start) Span.of(fixed, head) else Span.of(head, fixed);
    var out = whole;
    if (grab_start) {
        out.first_para = head.para;
        out.first_byte = head.start;
    } else {
        out.last_para = head.para;
        out.last_byte = head.end;
    }
    return out;
}

/// The start of `s`, at most `max` bytes, ending at a word and never inside a
/// character, for showing a highlight or bookmark in a list.
pub fn excerpt(s: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trimStart(u8, s, " ");
    if (trimmed.len <= max) return trimmed;
    var end = max;
    while (end > 0 and trimmed[end] & 0xc0 == 0x80) end -= 1; // Inside a UTF-8 character
    if (std.mem.lastIndexOfScalar(u8, trimmed[0..end], ' ')) |space| {
        if (space > max / 2) end = space;
    }
    return trimmed[0..end];
}

/// Finds the paragraph and byte for one of Amazon's short positions.
pub fn locate(paragraphs: []const book_model.Paragraph, short: u32) ?struct { para: u32, byte: u32 } {
    var found: ?usize = null;
    for (paragraphs, 0..) |p, i| {
        if (p.position == 0) continue;
        if (p.position <= short) found = i else break;
    }
    const i = found orelse return null;
    const p = paragraphs[i];
    return .{ .para = @intCast(i), .byte = @intCast(book_model.byteOffset(p.text, short - p.position)) };
}

/// Reads "id|start|end" lines from the annotation database.
pub fn parse(alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, lines: []const u8) ![]Highlight {
    var out: std.ArrayList(Highlight) = .empty;
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        const id = fields.next() orelse continue;
        const start = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const end = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const from = locate(paragraphs, start) orelse continue;
        const to = locate(paragraphs, end) orelse continue;
        if (from.para != to.para) {
            // One mark per paragraph, so every paragraph it crosses is drawn.
            var para = from.para;
            while (para <= to.para) : (para += 1) {
                const first = if (para == from.para) from.byte else 0;
                const last: u32 = if (para == to.para) to.byte else @intCast(paragraphs[para].text.len);
                try out.append(alloc, .{ .mark = .{ .para = para, .start = first, .end = last }, .id = try alloc.dupe(u8, id) });
            }
            continue;
        }
        try out.append(alloc, .{ .mark = .{ .para = from.para, .start = from.byte, .end = to.byte }, .id = try alloc.dupe(u8, id) });
    }
    return out.toOwnedSlice(alloc);
}

fn overlaps(m: book_model.Mark, w: book_model.Word) bool {
    return w.para == m.para and w.start < m.end and w.end > m.start;
}

/// An ID for a highlight starting at `short`. Moving a highlight's start keeps
/// its ID, so that spot can already be taken by a highlight elsewhere.
pub fn freeId(alloc: std.mem.Allocator, list: []const Highlight, short: u32) ![]const u8 {
    var n = short;
    next: while (true) : (n += 1) {
        const id = try std.fmt.allocPrint(alloc, "kindle.highlight-{d}", .{n});
        for (list) |h| {
            if (std.mem.eql(u8, h.id, id)) continue :next;
        }
        return id;
    }
}

/// Adds a highlight, one mark per paragraph it crosses.
pub fn add(list: *std.ArrayList(Highlight), alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, id: []const u8, span: Span) !void {
    check.thatf(span.first_para < span.last_para or (span.first_para == span.last_para and span.first_byte <= span.last_byte), "highlight {s} starts before it ends", .{id});
    check.that(span.last_para < paragraphs.len, "highlight ends inside the book");
    var index = span.first_para;
    while (index <= span.last_para) : (index += 1) {
        const first = if (index == span.first_para) span.first_byte else 0;
        const last: u32 = if (index == span.last_para) span.last_byte else @intCast(paragraphs[index].text.len);
        try list.append(alloc, .{ .mark = .{ .para = index, .start = first, .end = last }, .id = id });
    }
}

/// Removes every mark of a highlight.
/// Whether `list[i]` is the first mark of its highlight. A highlight keeps a mark per
/// paragraph it covers; this lists or counts each one once.
pub fn firstOfId(list: []const Highlight, i: usize) bool {
    for (list[0..i]) |earlier| {
        if (std.mem.eql(u8, earlier.id, list[i].id)) return false;
    }
    return true;
}

/// How many highlights there are, each counted once however many paragraphs it covers.
pub fn count(list: []const Highlight) usize {
    var n: usize = 0;
    for (0..list.len) |i| n += @intFromBool(firstOfId(list, i));
    return n;
}

pub fn remove(list: *std.ArrayList(Highlight), id: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (std.mem.eql(u8, list.items[i].id, id)) {
            _ = list.orderedRemove(i);
        } else i += 1;
    }
}

/// First and last word of a highlight on this page.
pub fn wordRange(words: []const book_model.Word, list: []const Highlight, id: []const u8) ?struct { lo: usize, hi: usize } {
    var lo: ?usize = null;
    var hi: usize = 0;
    for (words, 0..) |w, i| {
        for (list) |h| {
            if (!std.mem.eql(u8, h.id, id) or !overlaps(h.mark, w)) continue;
            if (lo == null) lo = i;
            hi = i;
            break;
        }
    }
    return if (lo) |l| .{ .lo = l, .hi = hi } else null;
}

/// The ID of the highlight containing a word, if any.
pub fn atWord(list: []const Highlight, w: book_model.Word) ?[]const u8 {
    for (list) |h| {
        if (overlaps(h.mark, w)) return h.id;
    }
    return null;
}

fn sample(content: []const u8, position: u32) book_model.Paragraph {
    return .{ .text = content, .style = 0, .position = position };
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

test "database lines become marks, split across paragraphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paras = [_]book_model.Paragraph{ sample("abcdef", 100), sample("ghijkl", 106) };
    const list = try parse(arena.allocator(), &paras, "kindle.highlight-101|101|104\nkindle.highlight-104|104|108\nbad line\n");
    try std.testing.expectEqual(@as(usize, 3), list.len);
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
    const r = wordRange(&words, &list, "x").?;
    try std.testing.expectEqual(@as(usize, 1), r.lo);
    try std.testing.expectEqual(@as(usize, 2), r.hi);
    try std.testing.expect(wordRange(&words, &list, "y") == null);
    try std.testing.expectEqualStrings("x", atWord(&list, words[1]).?);
    try std.testing.expect(atWord(&list, words[0]) == null);
}

test "a highlight crossing paragraphs covers both and stays one highlight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const paras = [_]book_model.Paragraph{ sample("first para text here", 100), sample("second para", 121) };
    const words = [_]book_model.Word{
        .{ .x = 0, .y = 0, .w = 10, .h = 10, .para = 0, .start = 11, .end = 15 },
        .{ .x = 0, .y = 20, .w = 10, .h = 10, .para = 0, .start = 16, .end = 20 },
        .{ .x = 0, .y = 40, .w = 10, .h = 10, .para = 1, .start = 0, .end = 6 },
    };
    var list: std.ArrayList(Highlight) = .empty;
    try add(&list, alloc, &paras, "h", Span.of(words[0], words[2]));
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u32, 20), list.items[0].mark.end);
    try std.testing.expectEqual(@as(u32, 0), list.items[1].mark.start);
    const r = wordRange(&words, list.items, "h").?;
    try std.testing.expectEqual(@as(usize, 0), r.lo);
    try std.testing.expectEqual(@as(usize, 2), r.hi);
    remove(&list, "h");
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
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

    const fixed = book_model.Word{ .x = 0, .y = 0, .w = 1, .h = 1, .para = 7, .start = 0, .end = 4 };
    const head = book_model.Word{ .x = 0, .y = 0, .w = 1, .h = 1, .para = 8, .start = 50, .end = 55 };
    const longer = dragged(whole, fixed, head, false, false);
    try std.testing.expectEqual(@as(u32, 3), longer.first_para);
    try std.testing.expectEqual(@as(u32, 10), longer.first_byte);
    try std.testing.expectEqual(@as(u32, 55), longer.last_byte);
}

test "dragging past the other end swaps the ends" {
    const whole = Span{ .first_para = 2, .first_byte = 10, .last_para = 2, .last_byte = 20 };
    const fixed = book_model.Word{ .x = 0, .y = 0, .w = 1, .h = 1, .para = 2, .start = 10, .end = 14 };
    const head = book_model.Word{ .x = 0, .y = 0, .w = 1, .h = 1, .para = 2, .start = 2, .end = 6 };
    const swapped = dragged(whole, fixed, head, false, true);
    try std.testing.expectEqual(@as(u32, 2), swapped.first_byte);
    try std.testing.expectEqual(@as(u32, 14), swapped.last_byte);
}

test "a new highlight never takes an ID in use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mark = book_model.Mark{ .para = 0, .start = 0, .end = 1 };
    const list = [_]Highlight{ .{ .mark = mark, .id = "kindle.highlight-100" }, .{ .mark = mark, .id = "kindle.highlight-101" } };
    try std.testing.expectEqualStrings("kindle.highlight-99", try freeId(arena.allocator(), &list, 99));
    try std.testing.expectEqualStrings("kindle.highlight-102", try freeId(arena.allocator(), &list, 100));
}

test "excerpts end at a word and never split a character" {
    try std.testing.expectEqualStrings("short", excerpt("short", 20));
    try std.testing.expectEqualStrings("one two", excerpt("one two three", 10));
    try std.testing.expectEqualStrings("caf", excerpt("caf\u{e9}", 4)); // The accent is two bytes
    try std.testing.expectEqualStrings("lead", excerpt("  lead", 20));
}

test "a highlight over several paragraphs counts once" {
    const list = [_]Highlight{
        .{ .id = "a", .mark = .{ .para = 0, .start = 0, .end = 3 } },
        .{ .id = "a", .mark = .{ .para = 1, .start = 0, .end = 3 } },
        .{ .id = "b", .mark = .{ .para = 2, .start = 0, .end = 3 } },
    };
    try std.testing.expectEqual(@as(usize, 2), count(&list));
    try std.testing.expect(firstOfId(&list, 0) and !firstOfId(&list, 1) and firstOfId(&list, 2));
}
