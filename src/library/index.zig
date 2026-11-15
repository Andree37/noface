//! The library's index: every book as a record of fixed size and its text, kept on the
//! user drive in the data folder's "library" folder, read through fixed buffers. The
//! index is a cache, never the truth: it's built from the Kindle's catalog, the EPUBs
//! found and the series set by hand (builder.zig), and built again whenever they change
//! or any of its files doesn't read as whole.
//!
//! Files, each starting with a head naming the build it belongs to:
//!   records   one `Record` per book, by id (the order the builder found them in)
//!   text      each book's texts, which its record points to
//!   keys      (state key, id) for every local book, sorted: finds a book's record by
//!             the files kept beside its state
//!   order-*   the ids in each order, sorted when first shown after a change
//!   header    the build's number, its counts, what it was built from, and a checksum:
//!             written last, so a build cut short leaves the old header, or none
//!
//! No file in use is ever cut short: each is written beside, then renamed over it.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const files = @import("files.zig");
const keys = @import("keys.zig");

/// The most books the library takes: a statement about the hardware, not a limit on
/// the reader. Each is a file on the user drive (32 GB holds 2^24 files of 2 KB, less
/// than any book) or a row of the Kindle's catalog on its small system partition. Ids
/// stay u32, and the records file stays under 1 GB, as FAT32 needs. A build that finds
/// more stops there and says so in the log.
pub const books_max: u32 = 1 << 24;

/// A text field kept: a title, author or series is cut to this, at a whole character.
pub const text_bytes_max: u32 = keys.text_bytes_max;
/// The texts of a book: two paths, six other texts, their lengths, and a 0 after each.
pub const blob_bytes_max: u32 = 8 * 2 + 2 * (files.path_bytes_max + 1) + 6 * (text_bytes_max + 1);
/// How long the text file may grow: under FAT32's 4 GB a file.
pub const text_file_bytes_max: u64 = (4 << 30) - 1;

pub const Record = extern struct {
    last: u64,
    added: u64,
    kindle_last: u64,
    seconds_read: u64,
    text_offset: u64, // Where its texts start in the text file
    text_len: u32,
    series_index: f32,
    series_hash: u32, // `series_hash` of its series, 0 for none
    percent: u8,
    kindle_percent: u8,
    availability: u8, // A `catalog.Availability`
    flags: u8,
    /// Of every byte before it: a record torn by a crash while written in place
    /// doesn't read as whole, and the index is built again.
    checksum: u32 = 0,
    reserved: [4]u8 = @splat(0),

    pub const finished: u8 = 1;
    pub const epub: u8 = 2;

    /// Sets the checksum, as the record is now: last, before it's written.
    pub fn seal(r: *Record) void {
        r.invariants();
        r.checksum = r.checksum_now();
        assert(r.sound());
    }

    /// Whether the checksum matches what the record holds.
    pub fn sound(r: *const Record) bool {
        comptime assert(@offsetOf(Record, "checksum") == 56);
        comptime assert(@offsetOf(Record, "reserved") == 60);
        return r.checksum == r.checksum_now();
    }

    fn checksum_now(r: *const Record) u32 {
        const bytes = std.mem.asBytes(r)[0..@offsetOf(Record, "checksum")];
        assert(bytes.len == 56);
        assert(bytes.len < @sizeOf(Record)); // Never over itself
        return @truncate(std.hash.Wyhash.hash(0x7265, bytes));
    }

    /// The record in `bytes`, read from the drive: an error when it doesn't read as
    /// whole (torn, or damaged), which means building the index again.
    pub fn decode(bytes: []const u8) !Record {
        assert(bytes.len == @sizeOf(Record));
        const r = std.mem.bytesToValue(Record, bytes);
        if (!r.sound()) return error.Damaged;
        if (r.percent > 100 or r.text_len > blob_bytes_max) return error.Damaged;
        if (r.availability > @backingInt(catalog.Availability.downloading)) {
            return error.Damaged;
        }
        r.invariants();
        return r;
    }

    pub fn invariants(r: *const Record) void {
        assert(r.percent <= 100);
        assert(r.availability <= @backingInt(catalog.Availability.downloading));
        assert(r.text_len <= blob_bytes_max);
    }
};

comptime {
    assert(@sizeOf(Record) == 64);
    assert(@as(u64, books_max) * @sizeOf(Record) <= 1 << 30);
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
pub const header_magic = "NFLIB002".*;

pub const Header = extern struct {
    magic: [8]u8 = header_magic,
    generation: u64,
    count: u32,
    local: u32,
    read: u32,
    downloading: u32,
    stale: u32, // A bit per order whose file is out of date
    reserved: u32 = 0,
    sources: Sources,
    text_size: u64,
    checksum: u64 = 0, // Of every byte before it

    pub fn seal(h: *Header) void {
        h.checksum = checksum_of(h);
        assert(h.checksum == checksum_of(h));
        assert(h.count <= books_max);
    }

    /// Whether the header reads as whole and of this format: a damaged one, or one from
    /// another version of noface, means building again.
    pub fn valid(h: *const Header) bool {
        if (!std.mem.eql(u8, &h.magic, &header_magic)) return false;
        if (h.checksum != checksum_of(h)) return false;
        if (h.count > books_max) return false;
        if (h.local > h.count or h.read > h.count or h.downloading > h.count) return false;
        return h.stale < 1 << order_count;
    }

    fn checksum_of(h: *const Header) u64 {
        comptime assert(@offsetOf(Header, "checksum") == @sizeOf(Header) - 8);
        const bytes = std.mem.asBytes(h)[0..@offsetOf(Header, "checksum")];
        assert(bytes.len == @sizeOf(Header) - 8);
        return std.hash.Wyhash.hash(0x6e66, bytes);
    }

    pub fn is_stale(h: *const Header, order: catalog.Order) bool {
        assert(h.count <= books_max);
        assert(h.stale < 1 << order_count);
        return h.stale & order_bit(order) != 0;
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

pub const order_count: u32 = @typeInfo(catalog.Order).@"enum".field_names.len;

pub fn order_bit(order: catalog.Order) u32 {
    const bit = @as(u32, 1) << @intCast(@backingInt(order));
    assert(bit < 1 << order_count);
    assert(bit != 0);
    return bit;
}

/// The orders that change when a book's place or reading time does.
pub const reading_orders: u32 =
    order_bit_comptime(.recent) | order_bit_comptime(.progress) | order_bit_comptime(.series);
pub const all_orders: u32 = (1 << order_count) - 1;

fn order_bit_comptime(comptime order: catalog.Order) u32 {
    comptime assert(@backingInt(order) < order_count);
    comptime assert(order_count <= 32);
    return @as(u32, 1) << @backingInt(order);
}

pub fn order_name(buffer: []u8, order: catalog.Order) ![]const u8 {
    const name = try std.fmt.bufPrint(buffer, "order-{s}", .{@tagName(order)});
    assert(name.len > "order-".len);
    assert(std.mem.startsWith(u8, name, "order-"));
    return name;
}

/// A book read back: its entry, with its texts in `text`, and which record it is.
pub const Slot = struct {
    entry: catalog.Entry = undefined,
    id: u32 = std.math.maxInt(u32), // None
    text: [blob_bytes_max]u8 = undefined,

    pub fn holds(s: *const Slot) bool {
        assert(s.id == std.math.maxInt(u32) or s.id < books_max);
        return s.id != std.math.maxInt(u32);
    }
};

/// Buffers for reading an index's records and texts one at a time.
pub const Buffers = struct {
    records: []u8, // A record at least
    text: []u8, // A blob at least
};

/// An index open for reading: its header, and its records and texts.
pub const Index = struct {
    dir: []const u8,
    header: Header,
    records: files.Reader,
    text: files.Reader,

    /// The index in `dir`, or an error when it's missing or doesn't read as whole.
    pub fn open(dir: []const u8, buffers: Buffers) !Index {
        assert(buffers.records.len >= @sizeOf(Record));
        assert(buffers.text.len >= blob_bytes_max);
        const header = try read_header(dir);
        var records = try open_data(dir, "records", header.generation, buffers.records);
        errdefer records.close();
        if (records.size != file_head_bytes + @as(u64, header.count) * @sizeOf(Record)) {
            return error.Damaged;
        }
        var text = try open_data(dir, "text", header.generation, buffers.text);
        errdefer text.close();
        if (text.size != header.text_size) return error.Damaged;
        return .{ .dir = dir, .header = header, .records = records, .text = text };
    }

    pub fn close(ix: *Index) void {
        assert(ix.records.fd >= 0);
        ix.records.close();
        ix.text.close();
        assert(ix.text.fd < 0);
    }

    pub fn record(ix: *Index, id: u32) !Record {
        assert(id < ix.header.count);
        assert(ix.records.fd >= 0);
        const offset = file_head_bytes + @as(u64, id) * @sizeOf(Record);
        return Record.decode(try ix.records.read_at(offset, @sizeOf(Record)));
    }

    /// Book `id` read into `slot`: its record and its texts.
    pub fn read(ix: *Index, id: u32, slot: *Slot) !void {
        assert(id < ix.header.count);
        const r = try ix.record(id);
        const blob = try ix.text.read_at(r.text_offset, r.text_len);
        @memcpy(slot.text[0..blob.len], blob);
        slot.entry = try entry_of(&r, slot.text[0..blob.len]);
        slot.id = id;
        assert(slot.holds());
    }

    /// Writes book `id`'s record over the old one, in place.
    pub fn write_record(ix: *Index, id: u32, r: *Record) !void {
        assert(id < ix.header.count);
        assert(ix.dir.len > 0);
        r.seal();
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try files.path_in(&path_buffer, ix.dir, "records");
        const offset = file_head_bytes + @as(u64, id) * @sizeOf(Record);
        if (!files.write_at(path, offset, std.mem.asBytes(r))) return error.CantWrite;
        ix.records.len = 0; // What it holds may be from before
    }

    /// Writes the header afresh, beside the old one and then over it.
    pub fn write_header(ix: *Index) !void {
        assert(ix.header.count <= books_max);
        try write_header_to(ix.dir, &ix.header);
        assert(ix.header.valid());
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
    var buffer: [@sizeOf(Header)]u8 = undefined;
    var r = try files.Reader.open(path, &buffer);
    defer r.close();
    if (r.size != @sizeOf(Header)) return error.Damaged;
    const header = std.mem.bytesToValue(Header, try r.read_at(0, @sizeOf(Header)));
    if (!header.valid()) return error.Damaged;
    assert(header.count <= books_max);
    return header;
}

/// A data file of the index, checked to be of the build `generation`.
pub fn open_data(dir: []const u8, name: []const u8, generation: u64, buffer: []u8) !files.Reader {
    assert(buffer.len >= file_head_bytes);
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    var r = try files.Reader.open(try files.path_in(&path_buffer, dir, name), buffer);
    errdefer r.close();
    const head = std.mem.bytesToValue(FileHead, try r.read_at(0, file_head_bytes));
    if (!std.mem.eql(u8, &head.magic, &file_magic)) return error.Damaged;
    if (head.generation != generation) return error.Damaged; // Another build's
    assert(r.size >= file_head_bytes);
    return r;
}

/// The entry of a book whose record is `r` and texts `blob` (which it points into).
pub fn entry_of(r: *const Record, blob: []const u8) !catalog.Entry {
    r.invariants();
    var texts: [8][:0]const u8 = undefined;
    try split_blob(blob, &texts);
    const t = struct {
        fn get(all: *const [8][:0]const u8, field: Field) [:0]const u8 {
            return all[@backingInt(field)];
        }
    };
    const e: catalog.Entry = .{
        .path = t.get(&texts, .path),
        .title = t.get(&texts, .title),
        .author = t.get(&texts, .author),
        .percent = r.percent,
        .last = r.last,
        .finished = r.flags & Record.finished != 0,
        .seconds_read = r.seconds_read,
        .kindle_percent = r.kindle_percent,
        .kindle_last = r.kindle_last,
        .thumbnail = t.get(&texts, .thumbnail),
        .added = r.added,
        .availability = @fromBackingInt(@intCast(r.availability)),
        .key = t.get(&texts, .key),
        .kind = t.get(&texts, .kind),
        .guid = t.get(&texts, .guid),
        .series = t.get(&texts, .series),
        .series_index = r.series_index,
    };
    assert(e.percent <= 100);
    return e;
}

/// The eight texts of a blob: their lengths (u16 each), then each followed by a 0.
fn split_blob(blob: []const u8, out: *[8][:0]const u8) !void {
    assert(blob.len <= blob_bytes_max);
    if (blob.len < 16) return error.Damaged;
    var at: u32 = 16;
    for (out, 0..) |*text, i| {
        const len = std.mem.readInt(u16, blob[i * 2 ..][0..2], .little);
        if (at + len + 1 > blob.len or blob[at + len] != 0) return error.Damaged;
        text.* = blob[at .. at + len :0];
        at += len + 1;
    }
    if (at != blob.len) return error.Damaged;
    assert(at == blob.len);
}

/// Writes `e`'s texts as a blob into `out`, each cut to what's kept: its length.
pub fn write_blob(out: *[blob_bytes_max]u8, e: *const catalog.Entry) u32 {
    var texts: [8][]const u8 = undefined;
    texts[@backingInt(Field.path)] = cut(e.path, files.path_bytes_max);
    texts[@backingInt(Field.thumbnail)] = cut(e.thumbnail, files.path_bytes_max);
    texts[@backingInt(Field.title)] = clip(e.title);
    texts[@backingInt(Field.author)] = clip(e.author);
    texts[@backingInt(Field.series)] = clip(e.series);
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
    var end = text_bytes_max;
    // A character is at most four bytes: at most three to step back over
    for (0..3) |_| {
        if (text[end] & 0xc0 != 0x80) break; // Not a character's continuation
        end -= 1;
    }
    assert(end <= text_bytes_max);
    assert(end + 3 >= text_bytes_max);
    return text[0..end];
}

/// A series' name as a number, the same for every way of writing it that
/// `catalog.same_series` takes as one; 0 for none.
pub fn series_hash(series: []const u8) u32 {
    assert(series.len <= std.math.maxInt(u32));
    if (series.len == 0) return 0;
    const name = catalog.without_the(series);
    var hasher = std.hash.Wyhash.init(0x7365);
    for (name) |c| hasher.update(&.{std.ascii.toLower(c)});
    const hash: u32 = @truncate(hasher.final() | 1); // Never 0, which is none
    assert(hash != 0);
    return hash;
}

/// The record of entry `e`, its texts at `text_offset` (`text_len` long).
pub fn record_of(e: *const catalog.Entry, text_offset: u64, text_len: u32) Record {
    assert(text_len <= blob_bytes_max);
    const finite = std.math.isFinite(e.series_index) or std.math.isNan(e.series_index);
    var r: Record = .{
        .last = e.last,
        .added = e.added,
        .kindle_last = e.kindle_last,
        .seconds_read = e.seconds_read,
        .text_offset = text_offset,
        .text_len = text_len,
        .series_index = if (finite) e.series_index else 0,
        .series_hash = series_hash(e.series),
        .percent = @intCast(@min(e.percent, 100)),
        .kindle_percent = @intCast(@min(e.kindle_percent, 100)),
        .availability = @backingInt(e.availability),
        .flags = (if (e.finished) Record.finished else 0) | (if (e.is_epub()) Record.epub else 0),
    };
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
        .kindle_percent = 30,
        .kindle_last = 98,
        .thumbnail = "/t/dune.jpg",
        .added = 5,
        .availability = .downloading,
        .key = "B000",
        .kind = "EBOK",
        .guid = "g",
        .series = "The Dune Saga",
        .series_index = 1.5,
    };
    var blob: [blob_bytes_max]u8 = undefined;
    const len = write_blob(&blob, &e);
    const r = record_of(&e, 0, len);
    const back = try entry_of(&r, blob[0..len]);
    const info = @typeInfo(catalog.Entry).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (T == []const u8 or T == [:0]const u8) {
            try std.testing.expectEqualStrings(@field(e, name), @field(back, name));
        } else if (comptime !std.mem.eql(u8, name, "series_last")) {
            try std.testing.expectEqual(@field(e, name), @field(back, name));
        }
    }
    try std.testing.expectEqual(series_hash("dune saga"), r.series_hash);
    try std.testing.expectError(error.Damaged, entry_of(&r, blob[0 .. len - 1]));
}

test "a header that changed after it was sealed doesn't read as whole" {
    var h: Header = .{
        .generation = 7,
        .count = 3,
        .local = 2,
        .read = 1,
        .downloading = 0,
        .stale = all_orders,
        .sources = .{},
        .text_size = 100,
    };
    h.seal();
    try std.testing.expect(h.valid());
    h.count = 4;
    try std.testing.expect(!h.valid());
    h.seal();
    try std.testing.expect(h.valid());
    try std.testing.expect(h.is_stale(.series));
}
