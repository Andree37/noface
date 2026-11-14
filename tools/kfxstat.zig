//! Parses a KFX file and prints counts only, never book text.
const std = @import("std");
const book_model = core.book;
const note_rules = core.note_rules;
const core = @import("core");
const linux = std.os.linux;
const file = core.file;
const kfx = core.kfx;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 2) return error.Usage;
    const data = try file.map(argv[1]);

    var ts0: linux.timespec = undefined;
    var ts1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts0);
    std.debug.print("complete {}\n", .{kfx.is_complete(data)});
    const book = try kfx.parse(std.heap.page_allocator, data);
    var deepest: u8 = 0;
    var ordered = true;
    for (book.chapters, 0..) |c, i| {
        deepest = @max(deepest, c.depth);
        if (i > 0 and c.para < book.chapters[i - 1].para) ordered = false;
    }
    std.debug.print("chapters {d}, deepest {d}, in reading order {}\n", .{ book.chapters.len, deepest, ordered });
    var bold: usize = 0;
    var italic: usize = 0;
    var headings: usize = 0;
    var centred: usize = 0;
    var runs: usize = 0;
    for (book.paragraphs) |p| {
        if (p.look.bold) bold += 1;
        if (p.look.italic) italic += 1;
        if (p.look.size > book_model.normal_size) headings += 1;
        if (p.look.alignment == .center) centred += 1;
        runs += p.runs.len;
    }
    var pictures: usize = 0;
    var decodable: usize = 0;
    var first_picture: ?usize = null;
    for (book.paragraphs, 0..) |p, i| {
        const img = p.image orelse continue;
        pictures += 1;
        if (first_picture == null and img.width > 200) first_picture = book_model.text_index(book.paragraphs, i);
        const jpeg = img.data.len > 2 and img.data[0] == 0xff and img.data[1] == 0xd8;
        const png = img.data.len > 8 and std.mem.eql(u8, img.data[1..4], "PNG");
        if (jpeg or png) decodable += 1;
    }
    std.debug.print("pictures {d}, jpeg or png {d}, first large at text paragraph {?d}\n", .{ pictures, decodable, first_picture });
    std.debug.print("looks: bold {d}, italic {d}, larger {d}, centred {d}, inline runs {d}\n", .{ bold, italic, headings, centred, runs });
    _ = linux.clock_gettime(.MONOTONIC, &ts1);

    var bytes: usize = 0;
    var non_ascii: usize = 0;
    var longest: usize = 0;
    var valid: usize = 0;
    var links: usize = 0;
    var notes: usize = 0;
    var note_bytes: usize = 0;
    for (book.paragraphs) |p| {
        bytes += p.text.len;
        links += p.links.len;
        if (p.note) {
            notes += 1;
            note_bytes += p.text.len;
        }
        longest = @max(longest, p.text.len);
        if (std.unicode.utf8ValidateSlice(p.text)) valid += 1;
        for (p.text) |c| {
            if (c >= 0x80) non_ascii += 1;
        }
    }
    // Are references number-like marks, or words that shouldn't be references?
    var refs_mark: usize = 0;
    var refs_word: usize = 0;
    var starts: usize = 0;
    var multi: usize = 0;
    var capped: usize = 0;
    var longest_note: usize = 0;
    var first_refs: [3]usize = undefined;
    var first_refs_len: usize = 0;
    for (book.paragraphs, 0..) |p, i| {
        for (p.links) |l| {
            if (l.target >= book.paragraphs.len or !book.paragraphs[l.target].note_start) continue;
            if (note_rules.is_mark(p.text[l.start..l.end])) refs_mark += 1 else refs_word += 1;
            if (first_refs_len < first_refs.len) {
                first_refs[first_refs_len] = i;
                first_refs_len += 1;
            }
        }
        if (!p.note_start) continue;
        starts += 1;
        const parts = note_rules.note_length(book.paragraphs, i);
        if (parts > 1) multi += 1;
        if (parts == note_rules.max_note_parts) capped += 1;
        var size: usize = 0;
        for (book.paragraphs[i..][0..parts]) |part| size += part.text.len;
        longest_note = @max(longest_note, size);
    }
    std.debug.print("refs mark {d} word {d}, notes {d}, multi {d}, capped {d}, longest {d}\n", .{ refs_mark, refs_word, starts, multi, capped, longest_note });
    std.debug.print("first refs {any}\n", .{first_refs[0..first_refs_len]});
    var placed: usize = 0;
    for (book.paragraphs) |p| {
        if (p.position != 0) placed += 1;
    }
    std.debug.print("paragraphs with positions {d} of {d}\n", .{ placed, book.paragraphs.len });
    for (book.paragraphs) |p| {
        if (p.element == 80) std.debug.print("element 80 position {d}\n", .{p.position});
    }

    const us = (ts1.sec - ts0.sec) * 1_000_000 + @divTrunc(ts1.nsec - ts0.nsec, 1000);
    std.debug.print(
        "sections {d}, paragraphs {d}, text bytes {d}, non-ascii bytes {d}, valid utf8 {d}, longest {d}, missing refs {d}, links {d}, notes {d}, note bytes {d}, parse {d} us\n",
        .{ book.sections, book.paragraphs.len, bytes, non_ascii, valid, longest, book.missing_refs, links, notes, note_bytes, us },
    );
}
