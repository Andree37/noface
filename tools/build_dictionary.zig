//! Builds a noface dictionary file from a Wiktionary extract.
//!
//! Usage: build_dictionary <kaikki.org-dictionary-LANG.jsonl.gz> <out file>
//! Built for this computer by `zig build host-tools`, into zig-out/bin.
//!
//! The extract comes from https://kaikki.org (Wiktionary, CC BY-SA 4.0 and GFDL).
//! Definitions are in English, so the Portuguese extract gives Portuguese words with
//! English meanings. The output format is described in src/model/dictionary.zig.
//!
//! Each word keeps at most 3 parts of speech with 3 senses each, every sense cut to
//! about 200 characters. Obsolete, archaic and rare senses come after the rest.
//! Inflected forms keep their own short gloss ("simple past of run") and a "=run" line,
//! so noface shows the base word's meaning too. Forms Wiktionary only lists inside the
//! base word's entry (most Portuguese plurals and verb forms) are added the same way,
//! when they have no entry of their own.
//!
//! It replaced a Python script, and writes the file as it did: lengths are counted in
//! characters (code points), and spaces and letters are Python's, read from Unicode's
//! tables as noface reads them (src/text/unicode.zig). Words are folded into keys as
//! noface's search folds them, so a word looked up finds its key.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const search = core.search;
const unicode = core.unicode;
const Value = std.json.Value;

const magic = "NFDICT1\n";
const pos_max = 3;
const senses_max = 3;
/// The longest sense kept, in characters, before "…" ends it.
const gloss_characters_max = 200;
/// The longest word kept, in characters.
const word_characters_max = 40;
/// The longest key kept, in bytes: noface's lookup folds a word into this much.
const key_bytes_max = 64;
/// The longest line of the extract read: the longest entry is a few megabytes.
const line_bytes_max = 1 << 28;
/// The most lines read: an extract has a few million.
const lines_max = 1 << 28;
/// The most gzip members read: kaikki.org's extracts have one, `cat a.gz b.gz` makes two.
const gzip_members_max = 1 << 16;
/// The most chunks read from a member: each is at least a byte, and an extract is a few
/// gigabytes.
const chunks_max: u64 = 1 << 40;
/// The most zeros skipped after a member, as padding.
const gzip_padding_max: u64 = 1 << 32;
const ellipsis = "\u{2026}";

comptime {
    assert(magic.len == 8);
    assert(gloss_characters_max > ellipsis.len);
    assert(word_characters_max * 4 >= key_bytes_max); // A word kept may still be too long a key
}

/// Wiktionary's part of speech, and the name noface shows. Others show as they are.
const pos_names = [_][2][]const u8{
    .{ "noun", "noun" },           .{ "verb", "verb" },
    .{ "adj", "adjective" },       .{ "adv", "adverb" },
    .{ "name", "proper noun" },    .{ "pron", "pronoun" },
    .{ "prep", "preposition" },    .{ "conj", "conjunction" },
    .{ "intj", "interjection" },   .{ "num", "numeral" },
    .{ "det", "determiner" },      .{ "article", "article" },
    .{ "particle", "particle" },   .{ "phrase", "phrase" },
    .{ "prep_phrase", "phrase" },  .{ "contraction", "contraction" },
    .{ "abbrev", "abbreviation" }, .{ "prefix", "prefix" },
    .{ "suffix", "suffix" },
};

/// Senses with any of these tags come after the rest.
const late_tags = [_][]const u8{ "obsolete", "archaic", "rare", "dated" };

/// A listed form with any of these tags is a table's furniture, not a form.
const skip_form_tags = [_][]const u8{
    "table-tags",
    "inflection-template",
    "class",
    "romanization",
};

/// A part of speech of a word, and its senses so far.
const Pos = struct {
    name: []const u8,
    glosses: [senses_max][]const u8 = undefined,
    glosses_count: u32 = 0,
};

const Word = struct {
    word: []const u8, // As written: "Polish", or "polish" once that's seen
    pos: [pos_max]Pos = undefined,
    pos_count: u32 = 0,
    base: ?[]const u8 = null, // The word this one is a form of
};

/// A form listed inside another word's entry, kept in case it has none of its own.
const Form = struct { form: []const u8, gloss: []const u8, base: []const u8 };

/// A sense to keep: its gloss, clipped, and the word it's a form of, if any.
const Sense = struct { gloss: []const u8, base: ?[]const u8 };

const Builder = struct {
    /// Everything kept to the end: words, glosses, the maps' contents.
    keep: std.mem.Allocator,
    /// What one entry needs while it's read, emptied after each.
    scratch: std.mem.Allocator,
    words: std.StringHashMapUnmanaged(Word) = .empty,
    forms: std.StringHashMapUnmanaged(Form) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: build_dictionary <kaikki.org extract .jsonl.gz> <out file>\n", .{});
        std.process.exit(2);
    }
    assert(args.len == 3);
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    var builder: Builder = .{
        .keep = init.arena.allocator(),
        .scratch = scratch_arena.allocator(),
    };
    try read_extract(init.io, args[1], &builder, &scratch_arena);
    const added = try add_forms(&builder);
    var out: [64]u8 = undefined;
    const forms_format = "{d} forms added from inside other entries\n";
    try print_stdout(init.io, try std.fmt.bufPrint(&out, forms_format, .{added}));
    const body_bytes = try write_dictionary(init.io, &builder, args[2]);
    const words_count = builder.words.count();
    assert(words_count >= added);
    var report: [512]u8 = undefined;
    const format = "{s}: {d} words, {d} MB of definitions\n";
    const megabytes = body_bytes >> 20;
    const said = try std.fmt.bufPrint(&report, format, .{ args[2], words_count, megabytes });
    try print_stdout(init.io, said);
}

fn print_stdout(io: std.Io, text: []const u8) !void {
    assert(text.len > 0);
    assert(text[text.len - 1] == '\n');
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

/// Reads every entry of the gzipped extract at `path` into the builder.
fn read_extract(
    io: std.Io,
    path: []const u8,
    b: *Builder,
    scratch_arena: *std.heap.ArenaAllocator,
) !void {
    assert(path.len > 0);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_buffer: [1 << 16]u8 = undefined;
    comptime assert(file_buffer.len >= 10); // Decompress reads the gzip header whole
    var file_reader = file.reader(io, &file_buffer);
    const Reading = struct {
        b: *Builder,
        scratch_arena: *std.heap.ArenaAllocator,

        fn line(r: @This(), number: u32, text: []const u8) anyerror!void {
            assert(number > 0);
            assert(text.len > 0);
            read_line(r.b, text) catch |err| {
                std.debug.print("line {d}: {s}\n", .{ number, @errorName(err) });
                return err;
            };
            _ = r.scratch_arena.reset(.retain_capacity);
        }
    };
    const reading: Reading = .{ .b = b, .scratch_arena = scratch_arena };
    try each_gzip_line(&file_reader.interface, reading, Reading.line);
}

/// Passes each line of the gzip stream `in` to `each`, without its newline, numbered
/// from 1; empty lines are skipped. As Python's gzip module read it: every member of a
/// file made of several (as `cat a.gz b.gz` makes), each member's checksum and size
/// checked, zeros after the last member skipped, and anything else after it an error.
fn each_gzip_line(
    in: *std.Io.Reader,
    context: anytype,
    comptime each: fn (@TypeOf(context), u32, []const u8) anyerror!void,
) !void {
    assert(in.buffer.len >= 10); // Decompress reads a gzip header whole
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var line: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer line.deinit();
    var lines_count: u32 = 0;
    for (0..gzip_members_max) |member_index| {
        if (member_index > 0 and !try skip_gzip_padding(in)) break;
        var gunzip = std.compress.flate.Decompress.init(in, .gzip, &window);
        var crc = std.hash.Crc32.init();
        var size: u32 = 0; // Modulo 2^32, as gzip keeps it
        // Bounded: each turn takes at least one byte of what the member holds
        for (0..chunks_max) |_| {
            const chunk = gunzip.reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return gunzip.err orelse error.ReadFailed,
            };
            assert(chunk.len > 0);
            crc.update(chunk);
            size +%= @truncate(chunk.len);
            lines_count = try split_lines(chunk, &line, lines_count, context, each);
            gunzip.reader.toss(chunk.len);
        } else return error.ExtractTooLarge;
        const footer = gunzip.container_metadata.gzip;
        if (footer.crc != crc.final()) return error.GzipChecksumWrong;
        if (footer.count != size) return error.GzipSizeWrong;
    } else return error.TooManyGzipMembers;
    // The last line, if the extract doesn't end in a newline
    if (line.written().len > 0) try each(context, lines_count + 1, line.written());
    assert(lines_count <= lines_max);
}

/// Adds `chunk` to the line so far, passing on each line a newline ends. Returns the
/// count of lines read now, empty ones included.
fn split_lines(
    chunk: []const u8,
    line: *std.Io.Writer.Allocating,
    lines_before: u32,
    context: anytype,
    comptime each: fn (@TypeOf(context), u32, []const u8) anyerror!void,
) !u32 {
    assert(chunk.len > 0);
    assert(lines_before <= lines_max);
    var lines_count = lines_before;
    var rest = chunk;
    // Bounded: each turn takes a newline off `rest`, or ends
    for (0..chunk.len + 1) |_| {
        const newline = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        try line.writer.writeAll(rest[0..newline]);
        rest = rest[newline + 1 ..];
        if (lines_count == lines_max) return error.TooManyLines;
        lines_count += 1;
        if (line.written().len > 0) try each(context, lines_count, line.written());
        line.clearRetainingCapacity();
    }
    if (line.written().len + rest.len > line_bytes_max) return error.LineTooLong;
    try line.writer.writeAll(rest);
    assert(lines_count >= lines_before);
    return lines_count;
}

/// Skips the zeros that may pad a gzip file after a member. False at the end of the
/// file; true when another member starts.
fn skip_gzip_padding(in: *std.Io.Reader) !bool {
    assert(in.buffer.len > 0);
    // Bounded: each turn skips one zero, and a file's padding is at most what it holds
    for (0..gzip_padding_max) |_| {
        const byte = in.peekByte() catch |err| switch (err) {
            error.EndOfStream => return false,
            error.ReadFailed => return error.ReadFailed,
        };
        if (byte != 0) return true;
        in.toss(1);
    }
    return error.GzipPaddingTooLong;
}

/// One entry of the extract, a JSON object, into the builder.
fn read_line(b: *Builder, line: []const u8) !void {
    assert(line.len > 0);
    assert(line[line.len - 1] != '\n'); // The newline is the reader's
    const options: std.json.ParseOptions = .{
        .duplicate_field_behavior = .use_last,
        .allocate = .alloc_always,
    };
    assert(options.duplicate_field_behavior == .use_last); // As Python's json keeps the last
    const entry = try std.json.parseFromSliceLeaky(Value, b.scratch, line, options);
    try add_entry(b, entry);
}

/// One entry: its listed forms, and its senses under its word.
fn add_entry(b: *Builder, entry: Value) !void {
    const word = string_field(entry, "word") orelse "";
    if (!usable_word(word)) return;
    assert(word.len > 0);
    const senses = try senses_of(b.scratch, entry);
    if (senses.len == 0) return;
    try add_listed_forms(b, entry, word);
    const key = try fold(b.scratch, word);
    if (key.len > key_bytes_max) return;
    const slot = try b.words.getOrPut(std.heap.smp_allocator, key);
    if (!slot.found_existing) {
        slot.key_ptr.* = try b.keep.dupe(u8, key);
        slot.value_ptr.* = .{ .word = try b.keep.dupe(u8, word) };
    }
    const w = slot.value_ptr;
    // Prefer the lowercase spelling as the headword: "polish" over "Polish"
    if (std.mem.eql(u8, word, key) and !std.mem.eql(u8, w.word, key)) {
        w.word = try b.keep.dupe(u8, word);
    }
    const pos_raw = string_field(entry, "pos") orelse "";
    try add_senses(b, w, key, pos_name(pos_raw), senses);
    assert(w.pos_count <= pos_max);
}

/// A word worth an entry: one word, not too long, with a letter in it.
fn usable_word(word: []const u8) bool {
    if (word.len == 0) return false;
    if (std.mem.indexOfScalar(u8, word, ' ') != null) return false;
    const view = std.unicode.Utf8View.init(word) catch return false;
    var characters = view.iterator();
    var count: u32 = 0;
    while (characters.nextCodepoint()) |_| count += 1;
    assert(count > 0);
    assert(count <= word.len);
    return count <= word_characters_max and unicode.has_letter(word);
}

/// The senses of `w` under part of speech `pos`, as many as fit.
fn add_senses(
    b: *Builder,
    w: *Word,
    key: []const u8,
    pos: []const u8,
    senses: []const Sense,
) !void {
    assert(senses.len > 0);
    assert(w.pos_count <= pos_max);
    const found: ?*Pos = for (w.pos[0..w.pos_count]) |*p| {
        if (std.mem.eql(u8, p.name, pos)) break p;
    } else null;
    const p: *Pos = found orelse new: {
        if (w.pos_count >= pos_max) return;
        w.pos[w.pos_count] = .{ .name = try b.keep.dupe(u8, pos) };
        w.pos_count += 1;
        break :new &w.pos[w.pos_count - 1];
    };
    for (senses) |sense| {
        if (p.glosses_count >= senses_max) break;
        const known = for (p.glosses[0..p.glosses_count]) |g| {
            if (std.mem.eql(u8, g, sense.gloss)) break true;
        } else false;
        if (!known) {
            p.glosses[p.glosses_count] = try b.keep.dupe(u8, sense.gloss);
            p.glosses_count += 1;
        }
        const base = sense.base orelse continue;
        if (base.len == 0 or w.base != null) continue;
        if (!std.mem.eql(u8, try fold(b.scratch, base), key)) w.base = try b.keep.dupe(u8, base);
    }
    assert(p.glosses_count <= senses_max);
}

/// The name noface shows for a part of speech.
fn pos_name(raw: []const u8) []const u8 {
    for (pos_names) |pair| {
        assert(pair[0].len > 0);
        if (std.mem.eql(u8, pair[0], raw)) return pair[1];
    }
    return raw;
}

/// The usable senses of an entry, the obsolete, archaic, rare and dated ones last.
fn senses_of(scratch: std.mem.Allocator, entry: Value) ![]const Sense {
    assert(late_tags.len > 0);
    var good: std.ArrayList(Sense) = .empty;
    var late: std.ArrayList(Sense) = .empty;
    for (array_field(entry, "senses")) |s| {
        const glosses = array_field(s, "glosses");
        if (glosses.len == 0) continue;
        const last = switch (glosses[glosses.len - 1]) {
            .string => |text| text,
            else => continue,
        };
        var base: ?[]const u8 = null;
        const form_of = array_field(s, "form_of");
        if (form_of.len > 0) base = string_field(form_of[0], "word");
        const sense: Sense = .{ .gloss = try clip(scratch, last), .base = base };
        if (has_any_tag(s, &late_tags)) {
            try late.append(scratch, sense);
        } else {
            try good.append(scratch, sense);
        }
    }
    try good.appendSlice(scratch, late.items);
    assert(good.items.len >= late.items.len);
    return good.items;
}

/// Whether a JSON object's "tags" hold any of `tags`.
fn has_any_tag(object: Value, tags: []const []const u8) bool {
    assert(tags.len > 0);
    for (array_field(object, "tags")) |tag| {
        const name = switch (tag) {
            .string => |text| text,
            else => continue,
        };
        for (tags) |wanted| {
            assert(wanted.len > 0);
            if (std.mem.eql(u8, name, wanted)) return true;
        }
    }
    return false;
}

/// The inflected forms an entry lists, kept for those without an entry of their own.
fn add_listed_forms(b: *Builder, entry: Value, word: []const u8) !void {
    assert(word.len > 0);
    for (array_field(entry, "forms")) |f| {
        const form = string_field(f, "form") orelse "";
        if (form.len == 0 or std.mem.eql(u8, form, word)) continue;
        if (std.mem.indexOfScalar(u8, form, ' ') != null) continue;
        if (has_any_tag(f, &skip_form_tags)) continue;
        // "plural of casa", "first person singular present indicative of ser"
        var description: std.ArrayList(u8) = .empty;
        var tags_count: u32 = 0;
        for (array_field(f, "tags")) |tag| {
            const name = switch (tag) {
                .string => |text| text,
                else => continue,
            };
            if (tags_count > 0) try description.append(b.scratch, ' ');
            try description.appendSlice(b.scratch, name);
            tags_count += 1;
        }
        if (tags_count == 0) continue;
        std.mem.replaceScalar(u8, description.items, '-', ' ');
        try description.print(b.scratch, " of {s}", .{word});
        const key = try fold(b.scratch, form);
        if (key.len > key_bytes_max) continue;
        const slot = try b.forms.getOrPut(std.heap.smp_allocator, key);
        if (slot.found_existing) continue;
        slot.key_ptr.* = try b.keep.dupe(u8, key);
        slot.value_ptr.* = .{
            .form = try b.keep.dupe(u8, form),
            .gloss = try b.keep.dupe(u8, try clip(b.scratch, description.items)),
            .base = try b.keep.dupe(u8, word),
        };
    }
    assert(b.forms.count() <= std.math.maxInt(u32));
}

/// The listed forms without an entry of their own, as words. Returns how many.
fn add_forms(b: *Builder) !u32 {
    const words_before = b.words.count();
    var added: u32 = 0;
    var forms = b.forms.iterator();
    while (forms.next()) |form| {
        const slot = try b.words.getOrPut(std.heap.smp_allocator, form.key_ptr.*);
        if (slot.found_existing) continue;
        slot.value_ptr.* = .{ .word = form.value_ptr.form, .base = form.value_ptr.base };
        slot.value_ptr.pos[0] = .{ .name = "form", .glosses_count = 1 };
        slot.value_ptr.pos[0].glosses[0] = form.value_ptr.gloss;
        slot.value_ptr.pos_count = 1;
        added += 1;
    }
    assert(b.words.count() == words_before + added);
    assert(added <= b.forms.count());
    return added;
}

/// Writes the dictionary to `path`. Returns the size of its entries, in bytes.
fn write_dictionary(io: std.Io, b: *const Builder, path: []const u8) !u64 {
    assert(path.len > 0);
    const gpa = std.heap.smp_allocator;
    const keys = try gpa.alloc([]const u8, b.words.count());
    var key_iterator = b.words.keyIterator();
    for (keys) |*key| key.* = key_iterator.next().?.*;
    assert(key_iterator.next() == null); // Every key, once
    std.mem.sort([]const u8, keys, {}, struct {
        fn before(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.before);
    var body: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(u8) = .empty;
    for (keys) |key| {
        try append_u32(gpa, &offsets, body.items.len);
        try append_entry(gpa, &body, key, b.words.getPtr(key).?);
    }
    try append_u32(gpa, &offsets, body.items.len);
    assert(offsets.items.len == (keys.len + 1) * 4);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(magic);
    try writer.interface.writeInt(u32, @intCast(keys.len), .little);
    try writer.interface.writeAll(offsets.items);
    try writer.interface.writeAll(body.items);
    try writer.interface.flush();
    return body.items.len;
}

/// Appends `value` as a little-endian u32: the file's offsets and count are u32s.
fn append_u32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    if (value > std.math.maxInt(u32)) return error.DictionaryTooLarge;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(value), .little);
    try out.appendSlice(gpa, &bytes);
    assert(out.items.len % 4 == 0);
}

/// One entry: its key, the word, and its definition lines.
fn append_entry(
    gpa: std.mem.Allocator,
    body: *std.ArrayList(u8),
    key: []const u8,
    w: *const Word,
) !void {
    assert(key.len > 0);
    assert(w.pos_count <= pos_max);
    try body.print(gpa, "{s}\x00{s}\x00", .{ key, w.word });
    var first = true;
    for (w.pos[0..w.pos_count]) |p| {
        if (!first) try body.append(gpa, '\n');
        first = false;
        try body.appendSlice(gpa, p.name);
        for (p.glosses[0..p.glosses_count], 1..) |gloss, number| {
            try body.print(gpa, "\n{d} {s}", .{ number, gloss });
        }
    }
    if (w.base) |base| {
        assert(base.len > 0); // Only a word is kept as a base
        if (!first) try body.append(gpa, '\n');
        try body.print(gpa, "={s}", .{base});
    }
}

/// A word as noface looks it up: lowercase, accents off (as src/model/search.zig folds
/// them), and the typographic apostrophe a plain one.
fn fold(scratch: std.mem.Allocator, word: []const u8) ![]const u8 {
    const view = try std.unicode.Utf8View.init(word);
    var characters = view.iterator();
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(scratch, word.len);
    while (characters.nextCodepoint()) |code_point| {
        const plain: u21 = if (code_point == 0x2019) '\'' else search.fold(code_point);
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(plain, &bytes);
        try out.appendSlice(scratch, bytes[0..length]);
    }
    // A character folds to one character, of up to as many bytes again
    assert(out.items.len <= word.len * 2);
    assert(word.len == 0 or out.items.len > 0);
    return out.items;
}

/// A gloss on one line, its spaces single, cut at a space near 200 characters with
/// "…" when longer, as the Python tool had it.
fn clip(scratch: std.mem.Allocator, text: []const u8) ![]const u8 {
    const view = try std.unicode.Utf8View.init(text);
    var characters = view.iterator();
    var out: std.ArrayList(u8) = .empty;
    var space_pending = false;
    var count: u32 = 0;
    var cut_end: u32 = 0; // Where the 200th character ends
    while (characters.nextCodepoint()) |code_point| {
        if (unicode.is_space(code_point)) {
            space_pending = out.items.len > 0;
            continue;
        }
        if (space_pending) {
            try out.append(scratch, ' ');
            count += 1;
            if (count == gloss_characters_max) cut_end = @intCast(out.items.len);
        }
        space_pending = false;
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(code_point, &bytes);
        try out.appendSlice(scratch, bytes[0..length]);
        count += 1;
        if (count == gloss_characters_max) cut_end = @intCast(out.items.len);
    }
    if (count <= gloss_characters_max) return out.items;
    assert(cut_end > 0);
    assert(cut_end < out.items.len);
    // The last space within the first 200 characters, unless that's the first
    const space = std.mem.lastIndexOfScalar(u8, out.items[0..cut_end], ' ') orelse 0;
    const end = if (space > 0) space else cut_end;
    out.shrinkRetainingCapacity(end);
    try out.appendSlice(scratch, ellipsis);
    return out.items;
}

/// A JSON object's text field, if it has one.
fn string_field(object: Value, name: []const u8) ?[]const u8 {
    assert(name.len > 0);
    const fields = switch (object) {
        .object => |map| map,
        else => return null,
    };
    return switch (fields.get(name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

/// A JSON object's list field, or an empty one.
fn array_field(object: Value, name: []const u8) []const Value {
    assert(name.len > 0);
    const fields = switch (object) {
        .object => |map| map,
        else => return &.{},
    };
    return switch (fields.get(name) orelse return &.{}) {
        .array => |list| list.items,
        else => &.{},
    };
}

/// `text` `times` over, for the tests.
fn repeated(comptime text: []const u8, comptime times: u32) []const u8 {
    comptime assert(text.len > 0);
    comptime assert(times > 0);
    @setEvalBranchQuota(10 * times);
    comptime var out: []const u8 = "";
    inline for (0..times) |_| out = out ++ text;
    return out;
}

test "a gloss is put on one line and cut near 200 characters at a space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a b c", try clip(a, "  a \t b\u{A0}\n c  "));
    const long = repeated("word ", 50);
    const clipped = try clip(a, long);
    try std.testing.expect(std.mem.endsWith(u8, clipped, "word" ++ ellipsis));
    try std.testing.expectEqual(@as(usize, 39 * 5 + 4 + ellipsis.len), clipped.len);
    // No space to cut at: exactly 200 characters, then the ellipsis
    const solid = repeated("\u{E9}", 250);
    const expected = comptime repeated("\u{E9}", 200) ++ ellipsis;
    try std.testing.expectEqualStrings(expected, try clip(a, solid));
}

test "a word is folded as noface looks it up" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("cafe", try fold(a, "Caf\u{E9}"));
    try std.testing.expectEqualStrings("don't", try fold(a, "Don\u{2019}t"));
    try std.testing.expectEqualStrings("stra\u{DF}e", try fold(a, "Stra\u{DF}e"));
}

test "words without a letter, with a space or too long are left out" {
    try std.testing.expect(usable_word("run"));
    try std.testing.expect(usable_word("x2"));
    try std.testing.expect(!usable_word("42"));
    try std.testing.expect(!usable_word("\u{20AC}"));
    try std.testing.expect(!usable_word("ice cream"));
    try std.testing.expect(!usable_word(repeated("a", 41)));
    try std.testing.expect(usable_word(repeated("\u{E9}", 40)));
}

test "an entry's senses, forms and base word come out as noface reads them" {
    var keep_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer keep_arena.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    var b: Builder = .{ .keep = keep_arena.allocator(), .scratch = scratch_arena.allocator() };
    defer b.words.deinit(std.heap.smp_allocator);
    defer b.forms.deinit(std.heap.smp_allocator);
    try read_line(&b,
        \\{"word": "Ran", "pos": "verb", "senses": [{"glosses": ["x", "simple past of run"],
        \\ "form_of": [{"word": "run"}]}, {"glosses": ["old", "an old use"], "tags": ["archaic"]},
        \\ {"glosses": ["sprinted"]}], "forms": [{"form": "rans", "tags": ["plural"]},
        \\ {"form": "ran-x", "tags": ["table-tags"]}]}
    );
    try std.testing.expectEqual(@as(u32, 1), try add_forms(&b));
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    try append_entry(std.testing.allocator, &body, "ran", b.words.getPtr("ran").?);
    const expected = "ran\x00Ran\x00verb\n1 simple past of run\n2 sprinted\n3 an old use\n=run";
    try std.testing.expectEqualStrings(expected, body.items);
    body.clearRetainingCapacity();
    try append_entry(std.testing.allocator, &body, "rans", b.words.getPtr("rans").?);
    try std.testing.expectEqualStrings("rans\x00rans\x00form\n1 plural of Ran\n=Ran", body.items);
}

/// `text` as one gzip member, for the tests.
fn gzipped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    assert(text.len > 0);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 10);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    var compress = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .level_6);
    try compress.writer.writeAll(text);
    try compress.finish();
    assert(out.written().len > 18); // A header and a footer, at least
    return out.written();
}

/// The lines `each_gzip_line` reads from `data`, joined by "|", for the tests.
fn gzip_lines(gpa: std.mem.Allocator, data: []const u8) ![]const u8 {
    const Lines = struct {
        list: *std.ArrayList(u8),
        gpa: std.mem.Allocator,

        fn add(lines: @This(), number: u32, text: []const u8) anyerror!void {
            assert(number > 0);
            assert(text.len > 0);
            if (lines.list.items.len > 0) try lines.list.append(lines.gpa, '|');
            try lines.list.appendSlice(lines.gpa, text);
        }
    };
    var list: std.ArrayList(u8) = .empty;
    var in: std.Io.Reader = .fixed(data);
    try each_gzip_line(&in, Lines{ .list = &list, .gpa = gpa }, Lines.add);
    return list.items;
}

test "an extract in several gzip members is read whole, as Python's gzip read it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const first = try gzipped(gpa, "{\"a\": 1}\n{\"b\": ");
    const second = try gzipped(gpa, "2}\n\n{\"c\": 3}");
    // One member alone: its last line ends with the file
    try std.testing.expectEqualStrings("{\"a\": 1}|{\"b\": ", try gzip_lines(gpa, first));
    // Two members, as `cat a.gz b.gz` makes, then zeros padding the file
    const zeros: [8]u8 = @splat(0);
    const joined = try std.mem.concat(gpa, u8, &.{ first, second, &zeros });
    const expected = "{\"a\": 1}|{\"b\": 2}|{\"c\": 3}";
    try std.testing.expectEqualStrings(expected, try gzip_lines(gpa, joined));
    // Something else after the last member is an error, as is a checksum that's wrong
    const trailing = try std.mem.concat(gpa, u8, &.{ first, "junk after" });
    try std.testing.expectError(error.BadGzipHeader, gzip_lines(gpa, trailing));
    const damaged = try gpa.dupe(u8, first);
    damaged[damaged.len - 8] ^= 1; // The footer's checksum
    try std.testing.expectError(error.GzipChecksumWrong, gzip_lines(gpa, damaged));
}
