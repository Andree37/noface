//! The library's index: every book as a record of fixed size and its texts, kept on the
//! user drive in the data folder's "library" folder and mapped whole. The index is a
//! cache, never the truth: it's built from the Kindle's catalog, the EPUBs found and the
//! series set by hand (builder.zig), and built again whenever they change or any of its
//! files doesn't read as whole.
//!
//! Files, each starting with a head naming the build it belongs to:
//!   records   one `Record` per book, by id (the order the builder found them in)
//!   text      each book's texts, which its record points to
//!   header    the build's number, its counts, what it was built from, and a checksum:
//!             written last, so a build cut short leaves the old header, or none
//!
//! A file is checked whole once, as it's mapped; after that only noface writes it, a
//! record at a time and sealed. None mapped is ever replaced: the user drive's FUSE
//! file system faults on a mapped file renamed over, so the index is closed first.
const std = @import("std");
const assert = std.debug.assert;
const unicode = @import("../text/unicode.zig");
const catalog = @import("../model/catalog.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const files = @import("files.zig");

/// The most books the library takes: past what a Kindle holds, not a limit on the
/// reader. Its catalog is a database on a 500 MB partition, and a row takes more than
/// 125 bytes; an EPUB is a file, 4 KB at the least, on a drive of 12 GB. The index is
/// mapped whole, and this many books' records and texts take at most 1.3 GB of the 3 GB
/// a program has. A build that finds more stops there and says so in the log.
pub const books_max: u32 = 1 << 22;

/// A text field kept: a title, author or series is cut to this, at a whole character.
pub const text_bytes_max: u32 = 256;
/// The texts of a book: two paths, six other texts, their lengths, and a 0 after each.
pub const blob_bytes_max: u32 = 8 * 2 + 2 * (files.path_bytes_max + 1) + 6 * (text_bytes_max + 1);
/// How long the text file may grow, mapped whole beside the records.
pub const text_file_bytes_max: u64 = 1 << 30;

pub const Record = extern struct {
    last: u64,
    added: u64,
    kindle_last: u64,
    seconds_read: u64,
    words_left: u64, // Read only with `words_known`
    text_offset: u64, // Where its texts start in the text file
    /// An EPUB's file as it was read, so the next build needn't open it again; 0 for a
    /// Kindle book, which the catalog describes.
    file_size: u64,
    file_modified: i64,
    text_len: u32,
    series_index: f32,
    percent: u8,
    kindle_percent: u8,
    availability: u8, // A `catalog.Availability`
    flags: u8,
    /// Of every byte before it: a record torn by a crash while written in place
    /// doesn't read as whole, and the index is built again.
    checksum: u32 = 0,

    pub const finished: u8 = 1;
    pub const epub: u8 = 2;
    /// Its series was set by hand: what the book itself says is no longer kept.
    pub const series_by_hand: u8 = 4;
    /// `words_left` is known.
    pub const words_known: u8 = 8;

    /// The words left from the book's place, or that they aren't known.
    pub fn set_words_left(r: *Record, words: ?u64) void {
        r.words_left = words orelse 0;
        if (words != null) r.flags |= words_known else r.flags &= ~words_known;
        assert((r.flags & words_known != 0) == (words != null));
    }

    /// Sets the checksum, as the record is now: last, before it's written.
    pub fn seal(r: *Record) void {
        r.invariants();
        r.checksum = r.checksum_now();
    }

    /// Whether the checksum matches what the record holds.
    pub fn sound(r: *const Record) bool {
        comptime assert(@offsetOf(Record, "checksum") == @sizeOf(Record) - 4);
        return r.checksum == r.checksum_now();
    }

    fn checksum_now(r: *const Record) u32 {
        const bytes = std.mem.asBytes(r)[0..@offsetOf(Record, "checksum")];
        assert(bytes.len == @sizeOf(Record) - 4);
        return @truncate(std.hash.Wyhash.hash(0x7265, bytes));
    }

    pub fn invariants(r: *const Record) void {
        assert(r.percent <= 100);
        assert(r.availability <= @backingInt(catalog.Availability.downloading));
        assert(r.text_len <= blob_bytes_max);
    }
};

comptime {
    assert(@sizeOf(Record) == 80);
    assert(@as(u64, books_max) * @sizeOf(Record) + text_file_bytes_max <= 1400 << 20);
    assert(blob_bytes_max < std.math.maxInt(u16) * 8);
}

/// The texts of a book, as kept in its blob, in this order.
const Field = enum(u3) { path, title, author, series, thumbnail, key, kind, guid };

pub const file_magic = "NFLIBDAT".*;
/// What starts every file but the header: which build it's part of.
pub const FileHead = extern struct { magic: [8]u8 = file_magic, generation: u64 };
pub const file_head_bytes: u32 = @sizeOf(FileHead);

/// Its version: an index written by a noface that wrote records differently is built
/// again.
pub const header_magic = "NFLIB004".*;

pub const Header = extern struct {
    magic: [8]u8 = header_magic,
    generation: u64,
    count: u32,
    local: u32,
    downloading: u32,
    reserved: u32 = 0,
    sources: Sources,
    text_size: u64,
    checksum: u64 = 0, // Of every byte before it

    /// Sets the checksum, as the header is now: last, before it's written, and only
    /// to a header that reads back as valid.
    pub fn seal(h: *Header) void {
        h.checksum = checksum_of(h);
        assert(h.valid());
    }

    /// Whether the header reads as whole and of this format: a damaged one, or one from
    /// another version of noface, means building again.
    pub fn valid(h: *const Header) bool {
        if (!std.mem.eql(u8, &h.magic, &header_magic)) return false;
        if (h.checksum != checksum_of(h)) return false;
        if (h.count > books_max or h.text_size > text_file_bytes_max) return false;
        return h.local <= h.count and h.downloading <= h.count;
    }

    fn checksum_of(h: *const Header) u64 {
        comptime assert(@offsetOf(Header, "checksum") == @sizeOf(Header) - 8);
        const bytes = std.mem.asBytes(h)[0..@offsetOf(Header, "checksum")];
        assert(bytes.len == @sizeOf(Header) - 8);
        return std.hash.Wyhash.hash(0x6e66, bytes);
    }
};

/// What an index was built from: when any differs, it's built again.
pub const Sources = extern struct {
    catalog_size: u64 = 0,
    catalog_modified: i64 = 0,
    overrides_size: u64 = 0,
    overrides_modified: i64 = 0,
    epubs: u64 = 0, // The EPUBs found, by path
    places: u64 = 0, // Where the books are, and this format
};

/// A book of the index, by id, with a number to sort it by: what the library sorts in
/// memory, 8 bytes a book, for an order or to find books by a key.
pub const Item = struct { id: u32, key: u32 };

/// A book read back: its entry, with its texts in `text`, and which record it is.
pub const Slot = struct {
    entry: catalog.Entry = undefined,
    id: ?u32 = null, // Null while it holds none
    text: [blob_bytes_max]u8 = undefined,

    pub fn holds(s: *const Slot) bool {
        const id = s.id orelse return false;
        assert(id < books_max);
        return true;
    }
};

/// An index open: its header, and its records and texts mapped.
pub const Index = struct {
    dir: []const u8,
    header: Header,
    records_file: []const u8,
    text_file: []const u8,

    /// The index in `dir`, or an error when it's missing or doesn't read as whole.
    pub fn open(dir: []const u8) !Index {
        return open_as(dir, try read_header(dir));
    }

    /// The index in `dir` as `header` says it is: for a build, before its header is
    /// written.
    pub fn open_as(dir: []const u8, header: Header) !Index {
        assert(header.count <= books_max);
        const records_file = try map_data(dir, "records", header.generation);
        errdefer file.unmap(records_file);
        const text_file = try map_data(dir, "text", header.generation);
        errdefer file.unmap(text_file);
        const ix: Index = .{
            .dir = dir,
            .header = header,
            .records_file = records_file,
            .text_file = text_file,
        };
        if (records_file.len != file_head_bytes + @as(u64, header.count) * @sizeOf(Record)) {
            return error.Damaged;
        }
        if (text_file.len != header.text_size) return error.Damaged;
        for (0..header.count) |id| try ix.check(@intCast(id));
        assert(ix.records_file.len >= file_head_bytes);
        return ix;
    }

    pub fn close(ix: *Index) void {
        assert(ix.records_file.len >= file_head_bytes);
        assert(ix.text_file.len == ix.header.text_size);
        file.unmap(ix.records_file);
        file.unmap(ix.text_file);
    }

    /// Whether book `id`'s record and texts read as whole: once, as it's opened.
    fn check(ix: *const Index, id: u32) !void {
        const r = ix.record_unchecked(id);
        if (!r.sound()) return error.Damaged;
        if (r.percent > 100 or r.kindle_percent > 100) return error.Damaged;
        if (r.availability > @backingInt(catalog.Availability.downloading)) {
            return error.Damaged;
        }
        if (r.text_len > blob_bytes_max) return error.Damaged;
        if (r.text_offset < file_head_bytes) return error.Damaged;
        if (r.text_offset + r.text_len > ix.text_file.len) return error.Damaged;
        var texts: [8][:0]const u8 = undefined;
        if (!split_blob(ix.blob(&r), &texts)) return error.Damaged;
    }

    fn record_unchecked(ix: *const Index, id: u32) Record {
        assert(id < ix.header.count);
        const offset = file_head_bytes + @as(u64, id) * @sizeOf(Record);
        // usize: a slice's index, which the records' size, mapped, fits
        const at: usize = @intCast(offset);
        return std.mem.bytesToValue(Record, ix.records_file[at..][0..@sizeOf(Record)]);
    }

    /// Book `id`'s record. Not hashed again: every one was as the index opened
    /// (`check`), and each write since is sealed and read back (`write_record`), so
    /// a sort, reading each record a few dozen times, needn't.
    pub fn record(ix: *const Index, id: u32) Record {
        const r = ix.record_unchecked(id);
        r.invariants();
        return r;
    }

    fn blob(ix: *const Index, r: *const Record) []const u8 {
        assert(r.text_offset + r.text_len <= ix.text_file.len);
        const at: usize = @intCast(r.text_offset); // usize: as the text file, mapped, fits
        return ix.text_file[at..][0..r.text_len];
    }

    /// Book `id`, its texts in the mapping: valid while the index is open.
    pub fn entry(ix: *const Index, id: u32) catalog.Entry {
        const r = ix.record(id);
        var texts: [8][:0]const u8 = undefined;
        const whole = split_blob(ix.blob(&r), &texts);
        assert(whole); // Checked as opened, and never written since
        return entry_of(&r, &texts);
    }

    /// Book `id` without its texts, all empty: for sorting by an order that reads
    /// only numbers, which needn't find them.
    pub fn numbers(ix: *const Index, id: u32) catalog.Entry {
        const r = ix.record(id);
        const none: [8][:0]const u8 = @splat("");
        const e = entry_of(&r, &none);
        assert(e.title.len == 0);
        return e;
    }

    /// Book `id` read into `slot`, its texts copied: valid after the index is closed.
    pub fn read(ix: *const Index, id: u32, slot: *Slot) void {
        const r = ix.record(id);
        const bytes = ix.blob(&r);
        assert(bytes.len <= slot.text.len);
        @memcpy(slot.text[0..bytes.len], bytes);
        var texts: [8][:0]const u8 = undefined;
        const whole = split_blob(slot.text[0..bytes.len], &texts);
        assert(whole); // Checked as opened, and never written since
        slot.entry = entry_of(&r, &texts);
        slot.id = id;
        assert(slot.holds());
    }

    /// Writes book `id`'s record over the old one, in place: the mapping sees it.
    pub fn write_record(ix: *const Index, id: u32, r: *Record) !void {
        assert(id < ix.header.count);
        assert(ix.dir.len > 0);
        r.seal();
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try files.path_in(&path_buffer, ix.dir, "records");
        const offset = file_head_bytes + @as(u64, id) * @sizeOf(Record);
        if (!files.write_at(path, offset, std.mem.asBytes(r))) return error.CantWrite;
        assert(std.meta.eql(ix.record(id), r.*));
    }

    /// The text file mapped again, grown to `size` by texts written at its end: for a
    /// build, before its header is written.
    pub fn grow_text(ix: *Index, size: u64) !void {
        assert(size >= ix.text_file.len);
        const text_file = try map_data(ix.dir, "text", ix.header.generation);
        // Checked before the old mapping is let go of: on an error the index is left as
        // it was, its mapping and size alike, so it still closes as whole
        errdefer file.unmap(text_file);
        if (text_file.len != size) return error.Damaged;
        if (size > text_file_bytes_max) return error.TooLarge;
        file.unmap(ix.text_file);
        ix.text_file = text_file;
        ix.header.text_size = size;
        assert(ix.text_file.len == ix.header.text_size);
    }

    /// Writes the header afresh, beside the old one and then over it.
    pub fn write_header(ix: *Index) !void {
        assert(ix.dir.len > 0);
        try write_header_to(ix.dir, &ix.header);
    }
};

pub fn write_header_to(dir: []const u8, header: *Header) !void {
    assert(dir.len > 0);
    header.seal();
    var new_buffer: [files.path_bytes_max]u8 = undefined;
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    const new = try files.path_in(&new_buffer, dir, "header.new");
    const path = try files.path_in(&path_buffer, dir, "header");
    var buffer: [@sizeOf(Header)]u8 = undefined;
    var w = try files.Writer.create(new, &buffer);
    w.write(std.mem.asBytes(header));
    const size = w.finish() catch |err| {
        files.remove(new);
        return err;
    };
    assert(size == @sizeOf(Header));
    try files.replace(new, path);
}

fn read_header(dir: []const u8) !Header {
    assert(dir.len > 0);
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    const path = try files.path_in(&path_buffer, dir, "header");
    var buffer: [@sizeOf(Header) + 1]u8 = undefined;
    const bytes = file.read_system(path, &buffer);
    if (bytes.len != @sizeOf(Header)) return error.Damaged;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    if (!header.valid()) return error.Damaged;
    return header;
}

/// A data file of the index mapped whole, checked to be of the build `generation`.
fn map_data(dir: []const u8, name: []const u8, generation: u64) ![]const u8 {
    assert(generation != 0);
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    const data = try file.map(try files.path_in(&path_buffer, dir, name));
    errdefer file.unmap(data);
    if (data.len < file_head_bytes) return error.Damaged;
    const head = std.mem.bytesToValue(FileHead, data[0..file_head_bytes]);
    if (!std.mem.eql(u8, &head.magic, &file_magic)) return error.Damaged;
    if (head.generation != generation) return error.Damaged; // Another build's
    assert(data.len >= file_head_bytes);
    return data;
}

/// The entry of a book whose record is `r` and texts `texts`.
fn entry_of(r: *const Record, texts: *const [8][:0]const u8) catalog.Entry {
    r.invariants();
    const e: catalog.Entry = .{
        .path = texts[@backingInt(Field.path)],
        .title = texts[@backingInt(Field.title)],
        .author = texts[@backingInt(Field.author)],
        .percent = r.percent,
        .last = r.last,
        .finished = r.flags & Record.finished != 0,
        .seconds_read = r.seconds_read,
        .words_left = if (r.flags & Record.words_known != 0) r.words_left else null,
        .kindle_percent = r.kindle_percent,
        .kindle_last = r.kindle_last,
        // An empty path in the file: no cover
        .thumbnail = if (texts[@backingInt(Field.thumbnail)].len > 0)
            texts[@backingInt(Field.thumbnail)]
        else
            null,
        .added = r.added,
        .availability = @fromBackingInt(@intCast(r.availability)),
        .key = texts[@backingInt(Field.key)],
        .kind = texts[@backingInt(Field.kind)],
        .guid = texts[@backingInt(Field.guid)],
        // An empty name in the file: not in a series
        .series = if (texts[@backingInt(Field.series)].len > 0)
            .{ .name = texts[@backingInt(Field.series)], .index = r.series_index }
        else
            null,
    };
    assert(e.percent <= 100);
    return e;
}

/// The eight texts of a blob (their lengths, u16 each, then each followed by a 0) into
/// `out`: false when it doesn't read as whole, or as `write_blob` would have written it.
fn split_blob(bytes: []const u8, out: *[8][:0]const u8) bool {
    assert(bytes.len <= blob_bytes_max);
    if (bytes.len < 16) return false;
    var at: u32 = 16;
    for (out, 0..) |*text, i| {
        const len = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
        // The text file is outside data: a text longer than `write_blob` keeps is damage
        if (len > field_bytes_max(@fromBackingInt(@intCast(i)))) return false;
        if (at + len + 1 > bytes.len or bytes[at + len] != 0) return false;
        text.* = bytes[at .. at + len :0];
        at += len + 1;
    }
    assert(at <= bytes.len);
    return at == bytes.len;
}

/// The longest text a blob keeps in `field`: a path as Linux opens one, any other text
/// cut to `text_bytes_max` (`clip`).
fn field_bytes_max(field: Field) u32 {
    return switch (field) {
        .path, .thumbnail => files.path_bytes_max,
        .title, .author, .series, .key, .kind, .guid => text_bytes_max,
    };
}

/// Writes `e`'s texts as a blob into `out`, each cut to what's kept: its length.
pub fn write_blob(out: *[blob_bytes_max]u8, e: *const catalog.Entry) u32 {
    var texts: [8][]const u8 = undefined;
    texts[@backingInt(Field.path)] = cut(e.path, field_bytes_max(.path));
    texts[@backingInt(Field.thumbnail)] = cut(e.thumbnail orelse "", field_bytes_max(.thumbnail));
    texts[@backingInt(Field.title)] = clip(e.title);
    texts[@backingInt(Field.author)] = clip(e.author);
    texts[@backingInt(Field.series)] = if (e.series) |s| clip(s.name) else "";
    texts[@backingInt(Field.key)] = clip(e.key);
    texts[@backingInt(Field.kind)] = clip(e.kind);
    texts[@backingInt(Field.guid)] = clip(e.guid);
    var at: u32 = 16;
    for (texts, 0..) |text, i| {
        std.mem.writeInt(u16, out[i * 2 ..][0..2], @intCast(text.len), .little);
        @memcpy(out[at..][0..text.len], text);
        // A 0 inside (outside data) would end the text early: it reads as a space
        for (out[at..][0..text.len]) |*c| {
            if (c.* == 0) c.* = ' ';
        }
        out[at + text.len] = 0;
        at += @intCast(text.len + 1);
    }
    assert(at <= blob_bytes_max);
    assert(at >= 16 + 8);
    return at;
}

/// A path cut to what Linux opens: one longer can't be opened, but is still listed.
fn cut(text: []const u8, max: u32) []const u8 {
    assert(max > 0);
    const result = text[0..@min(text.len, max)];
    assert(result.len <= max);
    return result;
}

/// `text` cut to `text_bytes_max` bytes, at a whole UTF-8 character.
pub fn clip(text: []const u8) []const u8 {
    if (text.len <= text_bytes_max) return text;
    const end = unicode.start_at_or_before(text, text_bytes_max);
    assert(end <= text_bytes_max);
    assert(end + 3 >= text_bytes_max);
    return text[0..end];
}

/// The record of entry `e`, its texts at `text_offset` (`text_len` long).
pub fn record_of(e: *const catalog.Entry, text_offset: u64, text_len: u32) Record {
    assert(text_len <= blob_bytes_max);
    const series_index = if (e.series) |s| s.index else 0;
    // A number to keep, or NaN, a place none was given (kept so); infinity is none of them
    const storable = std.math.isFinite(series_index) or std.math.isNan(series_index);
    var r: Record = .{
        .last = e.last,
        .added = e.added,
        .kindle_last = e.kindle_last,
        .seconds_read = e.seconds_read,
        .words_left = 0,
        .text_offset = text_offset,
        .file_size = 0,
        .file_modified = 0,
        .text_len = text_len,
        .series_index = if (storable) series_index else 0,
        .percent = @intCast(@min(e.percent, 100)),
        .kindle_percent = @intCast(@min(e.kindle_percent, 100)),
        .availability = @backingInt(e.availability),
        .flags = (if (e.finished) Record.finished else 0) | (if (e.is_epub()) Record.epub else 0),
    };
    r.set_words_left(e.words_left);
    r.seal();
    assert(r.text_offset == text_offset);
    return r;
}

test "a book's record and texts read back as the entry they were made from" {
    const e: catalog.Entry = .{
        .path = "/mnt/us/documents/Dune.kfx",
        .title = "Dune",
        .author = "Herbert, Frank",
        .percent = 40,
        .last = 99,
        .finished = true,
        .seconds_read = 600,
        .words_left = 12000,
        .kindle_percent = 30,
        .kindle_last = 98,
        .thumbnail = "/t/dune.jpg",
        .added = 5,
        .availability = .downloading,
        .key = "B000",
        .kind = "EBOK",
        .guid = "g",
        .series = .{ .name = "The Dune Saga", .index = 1.5 },
    };
    var bytes: [blob_bytes_max]u8 = undefined;
    const len = write_blob(&bytes, &e);
    const r = record_of(&e, 0, len);
    var texts: [8][:0]const u8 = undefined;
    try std.testing.expect(split_blob(bytes[0..len], &texts));
    const back = entry_of(&r, &texts);
    const info = @typeInfo(catalog.Entry).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (T == []const u8 or T == [:0]const u8) {
            try std.testing.expectEqualStrings(@field(e, name), @field(back, name));
        } else if (T == ?[:0]const u8) {
            try std.testing.expectEqualStrings(@field(e, name).?, @field(back, name).?);
        } else if (T == ?catalog.Series) {
            try std.testing.expectEqualStrings(e.series.?.name, back.series.?.name);
            try std.testing.expectEqual(e.series.?.index, back.series.?.index);
        } else {
            try std.testing.expectEqual(@field(e, name), @field(back, name));
        }
    }
    try std.testing.expect(!split_blob(bytes[0 .. len - 1], &texts));
    // Words left not known read back as not known, not as none left
    var unknown = e;
    unknown.words_left = null;
    const r_unknown = record_of(&unknown, 0, len);
    try std.testing.expect(r_unknown.sound());
    try std.testing.expectEqual(@as(?u64, null), entry_of(&r_unknown, &texts).words_left);
    var none_left = e;
    none_left.words_left = 0;
    const r_none = record_of(&none_left, 0, len);
    try std.testing.expectEqual(@as(?u64, 0), entry_of(&r_none, &texts).words_left);
}

test "a header that changed after it was sealed doesn't read as whole" {
    var h: Header = .{
        .generation = 7,
        .count = 3,
        .local = 2,
        .downloading = 0,
        .sources = .{},
        .text_size = 100,
    };
    h.seal();
    try std.testing.expect(h.valid());
    h.count = 4;
    try std.testing.expect(!h.valid());
    h.seal();
    try std.testing.expect(h.valid());
}

/// Whether book 0 of an index whose one blob has a path `path_len` bytes long, and
/// every other text empty, reads as whole: the index made in memory, as if mapped.
fn test_check_path(path_len: u16) !void {
    var text: [file_head_bytes + blob_bytes_max]u8 = @splat(0);
    const blob = text[file_head_bytes..];
    std.mem.writeInt(u16, blob[0..2], path_len, .little);
    @memset(blob[16..][0..path_len], 'x');
    const blob_len: u32 = 16 + @as(u32, path_len) + 8;
    var r: Record = .{
        .last = 0,
        .added = 0,
        .kindle_last = 0,
        .seconds_read = 0,
        .words_left = 0,
        .text_offset = file_head_bytes,
        .file_size = 0,
        .file_modified = 0,
        .text_len = blob_len,
        .series_index = 0,
        .percent = 0,
        .kindle_percent = 0,
        .availability = 0,
        .flags = 0,
    };
    r.seal();
    var records: [file_head_bytes + @sizeOf(Record)]u8 = undefined;
    @memcpy(records[file_head_bytes..], std.mem.asBytes(&r));
    const ix: Index = .{
        .dir = "/tmp",
        .header = .{
            .generation = 1,
            .count = 1,
            .local = 0,
            .downloading = 0,
            .sources = .{},
            .text_size = file_head_bytes + blob_len,
        },
        .records_file = &records,
        .text_file = text[0 .. file_head_bytes + blob_len],
    };
    try ix.check(0);
}

test "a text whose path is longer than any kept reads as damage, built again, not a crash" {
    // A record is checksummed, but the texts it points to are not: lengths that add up,
    // the path's past what Linux opens, are damage in a file on the user drive
    try test_check_path(@intCast(files.path_bytes_max));
    try std.testing.expectError(error.Damaged, test_check_path(files.path_bytes_max + 1));
    try std.testing.expectError(error.Damaged, test_check_path(4200));
}

test "a text file that didn't grow as written leaves the index as it was, and it closes" {
    var dir_buffer: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buffer, "/tmp/noface-index-{d}", .{
        calls.getpid(),
    }, 0);
    _ = calls.mkdir(dir, 0o755); // Ignored: the files written below say if it's missing
    defer _ = std.c.rmdir(dir); // Ignored: only /tmp is left fuller
    const generation = 7;
    var buffers: [2][80]u8 = undefined;
    var paths: [2][:0]const u8 = undefined;
    for ([_][]const u8{ "records", "text" }, &buffers, &paths) |name, *buffer, *path| {
        path.* = try files.path_in(buffer, dir, name);
        var head_buffer: [file_head_bytes]u8 = undefined;
        var w = try files.Writer.create(path.*, &head_buffer);
        w.write(std.mem.asBytes(&FileHead{ .generation = generation }));
        _ = try w.finish();
    }
    defer for (paths) |path| files.remove(path);
    const text_path = paths[1];
    var ix = try Index.open_as(dir, .{
        .generation = generation,
        .count = 0,
        .local = 0,
        .downloading = 0,
        .sources = .{},
        .text_size = file_head_bytes,
    });
    defer ix.close();
    // Told it grew by 5 bytes that were never written: the file mapped again is shorter
    try std.testing.expectError(error.Damaged, ix.grow_text(file_head_bytes + 5));
    try std.testing.expectEqual(@as(u64, file_head_bytes), ix.header.text_size);
    try std.testing.expectEqual(@as(usize, file_head_bytes), ix.text_file.len);
    // Grown as written, it's mapped at its new size
    var append_buffer: [8]u8 = undefined;
    var w = try files.Writer.append(text_path, &append_buffer);
    w.write("12345");
    const size = try w.finish();
    try ix.grow_text(size);
    try std.testing.expectEqual(@as(u64, file_head_bytes + 5), ix.header.text_size);
}
