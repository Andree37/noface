//! Parses a KFX file and prints counts only, never book text.
const std = @import("std");
const assert = std.debug.assert;
const book_model = core.book;
const note_rules = core.note_rules;
const core = @import("core");
const linux = std.os.linux;
const file = core.file;
const kfx = core.kfx;

const Book = book_model.Book;

/// A picture wider than this is a large one, not a decoration.
const picture_large_width_min = 200;
/// How many paragraphs with note references are listed by number.
const first_refs_max = 3;
/// The element whose position is printed, to check the position map.
const element_traced = 80;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 2) return error.Usage;
    const data = try file.map(argv[1]);

    var parse_start: linux.timespec = undefined;
    var parse_end: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &parse_start);
    std.debug.print("complete {}\n", .{kfx.is_complete(data)});
    const book = try kfx.parse(std.heap.page_allocator, data);
    print_chapters(&book);
    print_pictures(&book);
    print_looks(&book);
    _ = linux.clock_gettime(.MONOTONIC, &parse_end);

    const counts = count_text(&book);
    print_references(&book);
    print_positions(&book);

    const parse_us = (parse_end.sec - parse_start.sec) * 1_000_000 +
        @divTrunc(parse_end.nsec - parse_start.nsec, 1000);
    std.debug.print(
        "sections {d}, paragraphs {d}, text bytes {d}, non-ascii bytes {d}, " ++
            "valid utf8 {d}, longest {d}, missing refs {d}, links {d}, notes {d}, " ++
            "note bytes {d}, parse {d} us\n",
        .{
            book.sections,          book.paragraphs.len, counts.bytes,
            counts.bytes_non_ascii, counts.valid,        counts.longest,
            book.missing_refs,      counts.links,        counts.notes,
            counts.note_bytes,      parse_us,
        },
    );
}

fn print_chapters(book: *const Book) void {
    var deepest: u8 = 0;
    var ordered = true;
    for (book.chapters, 0..) |chapter, index| {
        deepest = @max(deepest, chapter.depth);
        if (index > 0 and chapter.para < book.chapters[index - 1].para) ordered = false;
    }
    if (book.chapters.len == 0) assert(deepest == 0);
    if (book.chapters.len <= 1) assert(ordered);
    std.debug.print("chapters {d}, deepest {d}, in reading order {}\n", .{
        book.chapters.len,
        deepest,
        ordered,
    });
}

fn print_pictures(book: *const Book) void {
    var pictures: u32 = 0;
    var decodable: u32 = 0;
    var first_large: ?u64 = null;
    for (book.paragraphs, 0..) |paragraph, index| {
        const image = paragraph.image orelse continue;
        pictures += 1;
        if (first_large == null and image.width > picture_large_width_min) {
            first_large = book_model.text_index(book.paragraphs, index);
        }
        const jpeg = image.data.len > 2 and image.data[0] == 0xff and image.data[1] == 0xd8;
        const png = image.data.len > 8 and std.mem.eql(u8, image.data[1..4], "PNG");
        if (jpeg or png) decodable += 1;
    }
    assert(pictures <= book.paragraphs.len);
    assert(decodable <= pictures);
    std.debug.print("pictures {d}, jpeg or png {d}, first large at text paragraph {?d}\n", .{
        pictures,
        decodable,
        first_large,
    });
}

fn print_looks(book: *const Book) void {
    var bold: u32 = 0;
    var italic: u32 = 0;
    var headings: u32 = 0;
    var centred: u32 = 0;
    var runs: u64 = 0;
    for (book.paragraphs) |paragraph| {
        if (paragraph.look.bold) bold += 1;
        if (paragraph.look.italic) italic += 1;
        if (paragraph.look.size > book_model.normal_size) headings += 1;
        if (paragraph.look.alignment == .center) centred += 1;
        runs += paragraph.runs.len;
    }
    assert(bold <= book.paragraphs.len);
    assert(headings <= book.paragraphs.len);
    std.debug.print("looks: bold {d}, italic {d}, larger {d}, centred {d}, inline runs {d}\n", .{
        bold,
        italic,
        headings,
        centred,
        runs,
    });
}

const TextCounts = struct {
    bytes: u64 = 0,
    bytes_non_ascii: u64 = 0,
    longest: u64 = 0,
    /// Paragraphs whose text is valid UTF-8.
    valid: u32 = 0,
    links: u64 = 0,
    notes: u32 = 0,
    note_bytes: u64 = 0,
};

fn count_text(book: *const Book) TextCounts {
    var counts: TextCounts = .{};
    for (book.paragraphs) |paragraph| {
        counts.bytes += paragraph.text.len;
        counts.links += paragraph.links.len;
        if (paragraph.note) {
            counts.notes += 1;
            counts.note_bytes += paragraph.text.len;
        }
        counts.longest = @max(counts.longest, paragraph.text.len);
        if (std.unicode.utf8ValidateSlice(paragraph.text)) counts.valid += 1;
        for (paragraph.text) |c| {
            if (c >= 0x80) counts.bytes_non_ascii += 1;
        }
    }
    assert(counts.bytes_non_ascii <= counts.bytes);
    assert(counts.note_bytes <= counts.bytes);
    assert(counts.longest <= counts.bytes);
    assert(counts.notes <= book.paragraphs.len);
    assert(counts.valid <= book.paragraphs.len);
    return counts;
}

/// Are references number-like marks, or words that shouldn't be references?
fn print_references(book: *const Book) void {
    var refs_mark: u32 = 0;
    var refs_word: u32 = 0;
    var starts: u32 = 0;
    var multi: u32 = 0;
    var capped: u32 = 0;
    var longest_note: u64 = 0;
    var first_refs: [first_refs_max]u32 = undefined;
    var first_refs_count: u32 = 0;
    for (book.paragraphs, 0..) |paragraph, index| {
        for (paragraph.links) |link| {
            if (link.target >= book.paragraphs.len) continue;
            if (!book.paragraphs[link.target].note_start) continue;
            if (note_rules.is_mark(paragraph.text[link.start..link.end])) {
                refs_mark += 1;
            } else {
                refs_word += 1;
            }
            if (first_refs_count < first_refs.len) {
                first_refs[first_refs_count] = @intCast(index);
                first_refs_count += 1;
            }
        }
        if (!paragraph.note_start) continue;
        starts += 1;
        const parts = note_rules.note_length(book.paragraphs, index);
        if (parts > 1) multi += 1;
        if (parts == note_rules.max_note_parts) capped += 1;
        var size: u64 = 0;
        for (book.paragraphs[index..][0..parts]) |part| size += part.text.len;
        longest_note = @max(longest_note, size);
    }
    assert(first_refs_count <= first_refs.len);
    assert(multi <= starts);
    assert(capped <= starts);
    std.debug.print("refs mark {d} word {d}, notes {d}, multi {d}, capped {d}, longest {d}\n", .{
        refs_mark,
        refs_word,
        starts,
        multi,
        capped,
        longest_note,
    });
    std.debug.print("first refs {any}\n", .{first_refs[0..first_refs_count]});
}

fn print_positions(book: *const Book) void {
    var placed: u32 = 0;
    for (book.paragraphs) |paragraph| {
        if (paragraph.position != 0) placed += 1;
    }
    assert(placed <= book.paragraphs.len);
    std.debug.print("paragraphs with positions {d} of {d}\n", .{ placed, book.paragraphs.len });
    for (book.paragraphs) |paragraph| {
        if (paragraph.element == element_traced) {
            std.debug.print("element 80 position {d}\n", .{paragraph.position});
        }
    }
}
