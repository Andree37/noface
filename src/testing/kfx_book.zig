//! A book in Amazon's KFX format, as Send to Kindle makes one, written for the tests:
//! paragraphs of plain words, each numbered with Amazon's positions, so the scenarios
//! read a book the device's own software knows by name and numbers, as they read an
//! EPUB copied over the cable. Only what noface's parser reads (kindle/kfx.zig) is
//! written: the container, its index, a document with one section, its story, and the
//! tables that give each paragraph its position. The text is our own, made from a
//! seed, the same every run.
const std = @import("std");
const assert = std.debug.assert;
const kfx = @import("../kindle/kfx.zig");

// The symbols of the fields and entity types written, as kindle/kfx.zig reads them.
const f_section_item = 141;
const f_content_ref = 145;
const f_children = 146;
const f_id = 155;
const f_reading_orders = 169;
const f_sections = 170;
const f_section_name = 174;
const f_story = 176;
const f_position_rows = 181;
const f_section_start = 184;
const f_compression = 410;
const f_drm = 411;
const f_index_offset = 413;
const f_index_length = 414;

const t_story = 259;
const t_section = 260;
const t_section_positions = 265;
const t_document = 538;
const t_section_map = 609;

// The ids of the book's own entities, and its first element's.
const id_section = 1000;
const id_story = 1001;
const id_positions = 1002;
const id_document = 1003;
const element_first = 2000;

/// Where the book's first paragraph starts in Amazon's positions: not 0, so a position
/// is never taken for a count of characters from the start.
pub const position_first = 1000;

/// The book's paragraphs and words: enough for a dozen pages on the largest screen.
pub const paragraphs_count = 60;
const words_per_paragraph = 70;
const words = [_][]const u8{
    "long", "river",  "new",   "letter", "morning", "old",   "evening", "turns",
    "a",    "garden", "house", "bright", "the",     "quiet", "green",   "small",
    "page", "light",  "road",  "window", "reader",  "slow",
};
const seed = 0x6b6678;

/// The book's bytes, in `alloc`.
pub fn make(alloc: std.mem.Allocator) ![]u8 {
    const texts = try paragraphs(alloc);
    const bytes = try write(alloc, &texts);
    assert(std.mem.startsWith(u8, bytes, "CONT"));
    assert(bytes.len > paragraphs_count * words_per_paragraph);
    return bytes;
}

/// The book's paragraphs, the same every time: for a test to say where one starts.
pub fn paragraphs(alloc: std.mem.Allocator) ![paragraphs_count][]const u8 {
    var texts: [paragraphs_count][]const u8 = undefined;
    var random = std.Random.DefaultPrng.init(seed);
    for (&texts) |*text| text.* = try paragraph(alloc, random.random());
    assert(texts[0].len > 0);
    return texts;
}

/// A paragraph of words, starting with a capital and ending with a stop.
fn paragraph(alloc: std.mem.Allocator, random: std.Random) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..words_per_paragraph) |i| {
        if (i > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, words[random.uintLessThan(u32, words.len)]);
    }
    try out.append(alloc, '.');
    out.items[0] = std.ascii.toUpper(out.items[0]);
    assert(out.items.len > words_per_paragraph);
    assert(std.ascii.isUpper(out.items[0]));
    return out.items;
}

/// The position of paragraph `i`'s start: each starts where the one before ended, as
/// Amazon counts a paragraph's characters.
pub fn position_of(texts: []const []const u8, i: u32) u32 {
    assert(i < texts.len);
    var position: u32 = position_first;
    for (texts[0..i]) |text| position += @intCast(text.len); // Plain words: a byte a character
    assert(position >= position_first);
    return position;
}

/// The book with paragraphs `texts`.
fn write(alloc: std.mem.Allocator, texts: []const []const u8) ![]u8 {
    assert(texts.len > 0);
    var entities: [5]Entity = .{
        .{ .id = id_document, .kind = t_document, .bytes = try document(alloc) },
        .{ .id = id_section, .kind = t_section, .bytes = try section(alloc) },
        .{ .id = id_story, .kind = t_story, .bytes = try story(alloc, texts) },
        .{ .id = id_positions, .kind = t_section_positions, .bytes = try positions(alloc) },
        .{ .id = id_section, .kind = t_section_map, .bytes = try section_map(alloc, texts) },
    };
    for (entities) |e| assert(e.bytes.len > 0);
    return container(alloc, &entities);
}

const Entity = struct { id: u32, kind: u32, bytes: []const u8 };

/// "CONT", its version, the header's size and its info's offset and size; then the
/// entities, each "ENTY" with its own header, then their index, then the info.
fn container(alloc: std.mem.Allocator, entities: []Entity) ![]u8 {
    assert(entities.len > 0);
    const header_size = 18;
    var body: std.ArrayList(u8) = .empty;
    var index: std.ArrayList(u8) = .empty;
    for (entities) |e| {
        const offset = body.items.len;
        try body.appendSlice(alloc, "ENTY");
        try append_int(alloc, &body, u16, 1);
        try append_int(alloc, &body, u32, 10); // Its header's size
        try body.appendSlice(alloc, e.bytes);
        try append_int(alloc, &index, u32, e.id);
        try append_int(alloc, &index, u32, e.kind);
        try append_int(alloc, &index, u64, offset);
        try append_int(alloc, &index, u64, body.items.len - offset);
    }
    const index_offset = header_size + body.items.len;
    var info: Ion = .{ .alloc = alloc };
    try info.structure(&.{
        .{ f_compression, try info.uint(0) },
        .{ f_drm, try info.uint(0) },
        .{ f_index_offset, try info.uint(index_offset) },
        .{ f_index_length, try info.uint(index.items.len) },
    });
    const info_bytes = info.done();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "CONT");
    try append_int(alloc, &out, u16, 2);
    try append_int(alloc, &out, u32, header_size);
    try append_int(alloc, &out, u32, @intCast(index_offset + index.items.len));
    try append_int(alloc, &out, u32, @intCast(info_bytes.len));
    assert(out.items.len == header_size);
    try out.appendSlice(alloc, body.items);
    try out.appendSlice(alloc, index.items);
    try out.appendSlice(alloc, info_bytes);
    assert(out.items.len == index_offset + index.items.len + info_bytes.len);
    return out.items;
}

fn append_int(alloc: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, n: u64) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, @intCast(n), .little);
    try out.appendSlice(alloc, &bytes);
}

/// The reading order: one section.
// Assertions: a fixed entity, checked by the parse-back test.
fn document(alloc: std.mem.Allocator) ![]const u8 {
    var ion: Ion = .{ .alloc = alloc };
    const order = try ion.structure_value(&.{
        .{ f_sections, try ion.list(&.{try ion.symbol(id_section)}) },
    });
    try ion.structure(&.{.{ f_reading_orders, try ion.list(&.{order}) }});
    return ion.done();
}

/// The section: its first template, the story.
fn section(alloc: std.mem.Allocator) ![]const u8 {
    var ion: Ion = .{ .alloc = alloc };
    const template = try ion.structure_value(&.{.{ f_story, try ion.symbol(id_story) }});
    try ion.structure(&.{.{ f_section_item, try ion.list(&.{template}) }});
    return ion.done();
}

/// The story: a paragraph a child, each an element with its text.
fn story(alloc: std.mem.Allocator, texts: []const []const u8) ![]const u8 {
    assert(texts.len > 0);
    var ion: Ion = .{ .alloc = alloc };
    var children: std.ArrayList([]const u8) = .empty;
    for (texts, 0..) |text, i| {
        try children.append(alloc, try ion.structure_value(&.{
            .{ f_id, try ion.uint(element_first + i) },
            .{ f_content_ref, try ion.string(text) },
        }));
    }
    assert(children.items.len == texts.len);
    try ion.structure(&.{.{ f_children, try ion.list(children.items) }});
    return ion.done();
}

/// Where the section starts in the book's positions.
// Assertions: a fixed entity, checked by the parse-back test.
fn positions(alloc: std.mem.Allocator) ![]const u8 {
    var ion: Ion = .{ .alloc = alloc };
    const row = try ion.structure_value(&.{
        .{ f_section_name, try ion.symbol(id_section) },
        .{ f_section_start, try ion.uint(position_first) },
    });
    try ion.structure(&.{.{ f_position_rows, try ion.list(&.{row}) }});
    return ion.done();
}

/// Where each element starts after the one before: its distance from the last, and
/// its id.
fn section_map(alloc: std.mem.Allocator, texts: []const []const u8) ![]const u8 {
    assert(texts.len > 0);
    var ion: Ion = .{ .alloc = alloc };
    var rows: std.ArrayList([]const u8) = .empty;
    for (texts, 0..) |_, i| {
        const delta = if (i == 0) 0 else texts[i - 1].len;
        try rows.append(alloc, try ion.list(&.{
            try ion.uint(delta),
            try ion.uint(element_first + i),
        }));
    }
    assert(rows.items.len == texts.len);
    try ion.structure(&.{.{ f_position_rows, try ion.list(rows.items) }});
    return ion.done();
}

/// Amazon's binary Ion, as much of it as a book needs: each value made on its own, its
/// bytes kept, and put together into the next. The top value's bytes are the stream.
const Ion = struct {
    alloc: std.mem.Allocator,
    top: []const u8 = &.{},

    const type_uint = 2;
    const type_symbol = 7;
    const type_string = 8;
    const type_list = 11;
    const type_struct = 13;
    /// The length follows the descriptor, when it's too long for its low four bits.
    const length_follows = 14;

    fn uint(ion: *Ion, n: u64) ![]const u8 {
        const b = be_bytes(n);
        return ion.value(type_uint, b.buffer[0..b.len], b.len);
    }

    fn symbol(ion: *Ion, id: u32) ![]const u8 {
        assert(id > 0); // Symbol 0 is no symbol
        const b = be_bytes(id);
        return ion.value(type_symbol, b.buffer[0..b.len], b.len);
    }

    fn string(ion: *Ion, text: []const u8) ![]const u8 {
        return ion.value(type_string, text, text.len);
    }

    fn list(ion: *Ion, items: []const []const u8) ![]const u8 {
        const body = try std.mem.concat(ion.alloc, u8, items);
        return ion.value(type_list, body, body.len);
    }

    /// A struct's bytes: each field's symbol, then its value.
    fn structure_value(ion: *Ion, fields: []const struct { u32, []const u8 }) ![]const u8 {
        var body: std.ArrayList(u8) = .empty;
        for (fields) |field| {
            try append_var_uint(ion.alloc, &body, field[0]);
            try body.appendSlice(ion.alloc, field[1]);
        }
        return ion.value(type_struct, body.items, body.items.len);
    }

    /// The stream's one value, a struct.
    fn structure(ion: *Ion, fields: []const struct { u32, []const u8 }) !void {
        ion.top = try ion.structure_value(fields);
    }

    fn done(ion: *const Ion) []const u8 {
        assert(ion.top.len > 0);
        return ion.top;
    }

    fn value(ion: *Ion, type_code: u8, body: []const u8, len: u64) ![]const u8 {
        assert(len == body.len);
        assert(type_code <= type_struct);
        var out: std.ArrayList(u8) = .empty;
        if (len < length_follows) {
            try out.append(ion.alloc, (type_code << 4) | @as(u8, @intCast(len)));
        } else {
            try out.append(ion.alloc, (type_code << 4) | length_follows);
            try append_var_uint(ion.alloc, &out, len);
        }
        try out.appendSlice(ion.alloc, body);
        assert(out.items.len > body.len); // Its descriptor, then its body
        return out.items;
    }
};

/// A number big-endian in as few bytes as it takes, none for 0.
const BeBytes = struct { buffer: [8]u8, len: u32 };

fn be_bytes(n: u64) BeBytes {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, n, .big);
    const len: u32 = 8 - @as(u32, @clz(n)) / 8;
    var result: BeBytes = .{ .buffer = undefined, .len = len };
    @memcpy(result.buffer[0..len], buffer[8 - len ..]);
    assert(len <= 8);
    if (n == 0) assert(len == 0);
    return result;
}

/// Seven bits a byte, the last byte flagged by its high bit.
fn append_var_uint(alloc: std.mem.Allocator, out: *std.ArrayList(u8), n: u64) !void {
    var groups: [10]u8 = undefined; // 64 bits, seven a byte
    var count: u32 = 0;
    var rest = n;
    for (&groups) |*group| {
        group.* = @intCast(rest & 0x7f);
        count += 1;
        rest >>= 7;
        if (rest == 0) break;
    }
    assert(rest == 0);
    assert(count > 0);
    var i = count;
    while (i > 0) { // Bounded by `count`
        i -= 1;
        const last: u8 = if (i == 0) 0x80 else 0;
        try out.append(alloc, groups[i] | last);
    }
}

test "noface's parser reads the book back, each paragraph at the position written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try make(alloc);
    const parsed = try kfx.parse(alloc, bytes);
    try std.testing.expectEqual(@as(usize, paragraphs_count), parsed.paragraphs.len);
    var texts: [paragraphs_count][]const u8 = undefined;
    for (parsed.paragraphs, &texts) |p, *text| text.* = p.text;
    for (parsed.paragraphs, 0..) |p, i| {
        try std.testing.expectEqual(position_of(&texts, @intCast(i)), p.position.?);
    }
    try std.testing.expect(std.mem.endsWith(u8, texts[0], "."));
}
