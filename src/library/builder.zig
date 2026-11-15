//! Building the library's index (index.zig) from what's on the Kindle: the catalog the
//! launcher exports, a line per Kindle book; the EPUBs under the documents folder; and
//! the series set by hand. Every book is read and written one at a time, through the
//! fixed buffers of `Work`, so a build takes the same memory for ten books or millions.
//!
//! What noface keeps of each book it has opened (its state file: place, time read) is
//! merged into the records at every load, from one listing of the data folder.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const overrides = @import("../model/series_override.zig");
const memory = @import("../base/memory.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");
const state = @import("../sys/state.zig");
const dir = @import("../sys/dir.zig");
const epub = @import("../epub/epub.zig");
const catalog_db = @import("../kindle/catalog.zig");
const kfx = @import("../kindle/kfx.zig");
const files = @import("files.zig");
const sorter = @import("sorter.zig");
const epub_cache = @import("epub_cache.zig");
const index = @import("index.zig");

/// The buffers a build, a merge and the library's passes over the index use: taken
/// once, at startup, and the same for any number of books.
pub const Work = struct {
    sort: sorter.Memory,
    sort_second: sorter.Memory, // The second pass by series, beside the first
    epubs: epub_cache.Memory,
    out_records: []u8,
    out_text: []u8,
    out_keys: []u8,
    lines: []u8, // The catalog and the series file, a line at a time
    row: []u8, // One catalog row's texts, as parsed
    in_records: []u8,
    in_text: []u8,
    in_keys: []u8,
    in_order: []u8,
    /// A bit per book: which the filter and search let through.
    bits: []u64,
    slot: *index.Slot, // One book being built, merged or sorted
    blob: *[index.blob_bytes_max]u8,

    const stream_bytes: u32 = 64 << 10;
    const sort_items_bytes: u32 = 2 << 20;
    const sort_inputs: u32 = 8;

    /// What `init` takes, at most, its blocks rounded up to whole units of the region.
    pub const bytes_max: u64 = 2 * (sort_items_bytes + sort_items_bytes / 16 +
        (sort_inputs + 1) * stream_bytes) + (1 << 20) + 13 * stream_bytes +
        index.books_max / 8 + 2 * @sizeOf(index.Slot) + (64 << 10) * 48;

    pub fn init(budget: *memory.Budget) !Work {
        const work: Work = .{
            .sort = try sort_memory(budget, sort_items_bytes),
            .sort_second = try sort_memory(budget, sort_items_bytes),
            .epubs = try epub_memory(budget),
            .out_records = try budget.untouched(u8, stream_bytes),
            .out_text = try budget.untouched(u8, stream_bytes),
            .out_keys = try budget.untouched(u8, stream_bytes),
            .lines = try budget.untouched(u8, stream_bytes),
            .row = try budget.untouched(u8, 4 * stream_bytes),
            .in_records = try budget.untouched(u8, stream_bytes),
            .in_text = try budget.untouched(u8, stream_bytes),
            .in_keys = try budget.untouched(u8, 4 << 10),
            .in_order = try budget.untouched(u8, stream_bytes),
            .bits = try budget.untouched(u64, index.books_max / 64),
            .slot = try budget.untouched_one(index.Slot),
            .blob = try budget.untouched_one([index.blob_bytes_max]u8),
        };
        work.epubs.invariants();
        assert(work.in_text.len >= index.blob_bytes_max);
        return work;
    }

    fn sort_memory(budget: *memory.Budget, items_bytes: u32) !sorter.Memory {
        const alloc = budget.allocator(); // Only for the list of inputs
        assert(items_bytes >= sorter.key_bytes_max + 10);
        const inputs = try alloc.alloc([]u8, sort_inputs);
        for (inputs) |*input| input.* = try budget.untouched(u8, stream_bytes);
        const result: sorter.Memory = .{
            .items = try budget.untouched(u8, items_bytes),
            .offsets = try budget.untouched(u32, items_bytes / 64),
            .inputs = inputs,
            .output = try budget.untouched(u8, stream_bytes),
        };
        assert(result.inputs.len == sort_inputs);
        return result;
    }

    fn epub_memory(budget: *memory.Budget) !epub_cache.Memory {
        const result: epub_cache.Memory = .{
            .sort = try sort_memory(budget, 1 << 20),
            .lines_out = try budget.untouched(u8, stream_bytes),
            .index_in = try budget.untouched(u8, 4 << 10),
            .lines_in = try budget.untouched(u8, epub_cache.line_bytes_max),
        };
        result.invariants();
        assert(result.sort.items.len == 1 << 20);
        return result;
    }
};

/// Where the books are, and where their index is kept.
pub const Places = struct {
    catalog_path: [*:0]const u8, // The Kindle's catalog, exported
    documents: []const u8, // Where EPUBs are found
    state_dir: []const u8, // Each book's place and cover, and the series set by hand
    dir: []const u8, // The index's folder
};

/// What an index built now would be built from: the catalog's and the series file's
/// size and change time, and the EPUBs found (by their paths: one listing of the
/// folders, no file opened).
pub fn sources_now(scratch: *memory.Budget, places: Places) index.Sources {
    assert(places.dir.len > 0);
    const start = scratch.mark();
    defer scratch.rewind(start);
    const catalog_facts = file.facts_of(places.catalog_path);
    var series_buffer: [files.path_bytes_max]u8 = undefined;
    const series_path = files.path_in(&series_buffer, places.state_dir, "series") catch "";
    const series_facts = if (series_path.len > 0) file.facts_of(series_path) else null;
    var hash: EpubHash = .{};
    const documents = places.documents;
    const walked = dir.walk(scratch.allocator(), documents, ".epub", &hash, EpubHash.add) catch
        dir.Walked{ .cut_short = true };
    // A folder not wholly listed never matches, so the next build tries again
    if (walked.cut_short) hash.sum +%= os.now_us();
    const sources: index.Sources = .{
        .catalog_size = if (catalog_facts) |f| f.size else 0,
        .catalog_modified = if (catalog_facts) |f| f.modified_s else 0,
        .overrides_size = if (series_facts) |f| f.size else 0,
        .overrides_modified = if (series_facts) |f| f.modified_s else 0,
        .epubs = hash.sum,
        .places = places_hash(places),
    };
    assert(sources.places != 0);
    return sources;
}

/// The EPUBs found, as one number however they're listed: a sum of their paths' hashes.
const EpubHash = struct {
    sum: u64 = 0,

    fn add(h: *EpubHash, path: [:0]const u8) void {
        assert(path.len > 0);
        h.sum +%= std.hash.Wyhash.hash(0x65, path);
        assert(@sizeOf(@TypeOf(h.sum)) == 8);
    }
};

/// Where the books are, and the index's format: a different folder, or a noface that
/// writes the index differently, builds it again.
fn places_hash(places: Places) u64 {
    assert(places.documents.len > 0);
    var hasher = std.hash.Wyhash.init(@sizeOf(index.Record) + @sizeOf(index.Header));
    hasher.update(std.mem.span(places.catalog_path));
    hasher.update("\x00");
    hasher.update(places.documents);
    const hash = hasher.final() | 1; // Never 0, which no index has
    assert(hash != 0);
    return hash;
}

/// A build under way: its files, and what it has counted.
const Build = struct {
    work: *const Work,
    scratch: *memory.Budget,
    places: Places,
    generation: u64,
    records: files.Writer,
    text: files.Writer,
    keys: sorter.Sorter,
    cache: epub_cache.Cache,
    count: u32 = 0,
    local: u32 = 0,
    read: u32 = 0,
    downloading: u32 = 0,
    left_out: u32 = 0, // Past `index.books_max`, or the text file's most
    epubs: u64 = 0, // The EPUBs found, as `EpubHash` adds them

    /// Adds book `e` to the index, as the next id.
    fn add(b: *Build, e: *const catalog.Entry) void {
        assert(b.count <= index.books_max);
        if (b.count == index.books_max) {
            b.left_out += 1;
            return;
        }
        const len = index.write_blob(b.work.blob, e);
        if (b.text.size + len > index.text_file_bytes_max) {
            b.left_out += 1;
            return;
        }
        const r = index.record_of(e, b.text.size, len);
        b.text.write(b.work.blob[0..len]);
        b.records.write(std.mem.asBytes(&r));
        if (e.is_local() and e.path.len > 0) {
            var key: [8]u8 = undefined;
            std.mem.writeInt(u64, &key, state.key_for(e.path), .big);
            b.keys.add(&key, b.count) catch {
                b.records.broken = true; // The build fails at its end, and is tried again
            };
        }
        b.count += 1;
        if (e.is_local()) b.local += 1;
        if (e.is_read()) b.read += 1;
        if (e.availability == .downloading) b.downloading += 1;
        assert(b.local <= b.count);
    }
};

/// Builds the index in `places.dir` from the sources, afresh: every file written beside
/// the old, and put in its place only once all are whole, the header last.
pub fn build(
    work: *const Work,
    scratch: *memory.Budget,
    places: Places,
    sources: index.Sources,
) !void {
    assert(scratch.region.?.kind == .bump);
    assert(places.dir.len > 0);
    var b: Build = .{
        .work = work,
        .scratch = scratch,
        .places = places,
        .generation = std.hash.Wyhash.hash(os.now_us(), std.mem.asBytes(&sources)) | 1,
        .records = undefined,
        .text = undefined,
        .keys = .init(&work.sort, places.dir, "keys"),
        .cache = .open(&work.epubs, places.dir),
    };
    b.records = try create_data(places.dir, "records.new", b.generation, work.out_records);
    errdefer b.records.abandon();
    b.text = try create_data(places.dir, "text.new", b.generation, work.out_text);
    errdefer b.text.abandon();
    add_kindle_books(&b);
    add_epubs(&b);
    b.cache.finish();
    if (b.left_out > 0) log("library: {d} books past the most kept\n", .{b.left_out});
    try finish_build(&b, sources);
}

fn finish_build(b: *Build, sources: index.Sources) !void {
    assert(b.count <= index.books_max);
    _ = try b.records.finish();
    _ = try b.text.finish();
    try write_keys(b);
    var header: index.Header = .{
        .generation = b.generation,
        .count = b.count,
        .local = b.local,
        .read = b.read,
        .downloading = b.downloading,
        .stale = index.all_orders, // Sorted when first shown
        .sources = sources,
        .text_size = b.text.size,
    };
    try apply_overrides(b, &header);
    for ([_][]const u8{ "records", "text", "keys" }) |name| {
        var from: [files.path_bytes_max]u8 = undefined;
        var to: [files.path_bytes_max]u8 = undefined;
        const new = try std.fmt.bufPrintSentinel(&from, "{s}/{s}.new", .{ b.places.dir, name }, 0);
        try files.replace(new, try files.path_in(&to, b.places.dir, name));
    }
    try index.write_header_to(b.places.dir, &header);
    assert(header.valid());
}

fn write_keys(b: *Build) !void {
    assert(b.records.fd < 0); // Finished
    var w = try create_data(b.places.dir, "keys.new", b.generation, b.work.out_keys);
    b.keys.finish(&w, write_key) catch |err| {
        w.abandon();
        return err;
    };
    const size = try w.finish();
    assert(size == index.file_head_bytes + @as(u64, b.keys.items_total) * key_entry_bytes);
}

/// An entry of the keys file: a state key, then the id of a book with it.
const key_entry_bytes: u32 = 16;

fn write_key(w: *files.Writer, key: []const u8, id: u64) !void {
    assert(key.len == 8);
    assert(id < index.books_max);
    w.write_int(u64, std.mem.readInt(u64, key[0..8], .big));
    w.write_int(u32, @intCast(id));
    w.write_int(u32, 0);
}

/// A new data file, its head written.
fn create_data(folder: []const u8, name: []const u8, generation: u64, buffer: []u8) !files.Writer {
    assert(generation != 0);
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    var w = try files.Writer.create(try files.path_in(&path_buffer, folder, name), buffer);
    const head: index.FileHead = .{ .generation = generation };
    w.write(std.mem.asBytes(&head));
    assert(w.size == index.file_head_bytes);
    return w;
}

/// The Kindle's books, a line of the exported catalog each.
fn add_kindle_books(b: *Build) void {
    assert(b.count == 0);
    var lines: files.Lines = .{
        .reader = files.Reader.open(b.places.catalog_path, b.work.lines) catch return,
    };
    defer lines.close();
    // Each line moves on through the file, so there are fewer than it has bytes
    for (0..lines_max(&lines)) |_| {
        const line = (lines.next() catch break) orelse break;
        if (line.len == 0) continue;
        var row_memory = std.heap.FixedBufferAllocator.init(b.work.row);
        // A row whose texts don't fit (longer than the line, many times over) is passed
        var e = (catalog_db.parse_line(row_memory.allocator(), line) catch continue) orelse
            continue;
        // The catalog's flag can stay set long after a download ended: the file decides
        if (e.availability == .downloading and is_complete_book(e.path)) e.availability = .local;
        b.add(&e);
    }
    if (lines.skipped > 0) log("library: {d} catalog lines too long\n", .{lines.skipped});
    assert(lines.at <= lines.reader.size);
}

/// More than the lines a file can have: one a byte, and one more for the end.
fn lines_max(lines: *const files.Lines) u32 {
    const most: u32 = @intCast(@min(lines.reader.size + 1, std.math.maxInt(u32)));
    assert(most > 0);
    assert(lines.at <= lines.reader.size);
    return most;
}

/// The catalog's downloading flag can stay set long after a download ended, so
/// the file decides: a partial book points past its own end.
pub fn is_complete_book(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    const data = file.map(path) catch return false;
    defer file.unmap(data);
    return kfx.is_complete(data);
}

/// EPUBs copied over the cable, which the Kindle's catalog doesn't list: found under the
/// documents folder, and read (or what was read of them kept) one at a time.
fn add_epubs(b: *Build) void {
    assert(b.places.documents.len > 0);
    const start = b.scratch.mark();
    defer b.scratch.rewind(start);
    const walked = dir.walk(b.scratch.allocator(), b.places.documents, ".epub", b, add_epub) catch
        dir.Walked{ .cut_short = true };
    if (walked.cut_short) log("library: {s} only partly listed\n", .{b.places.documents});
    assert(b.count <= index.books_max);
}

fn add_epub(b: *Build, path: [:0]const u8) void {
    assert(b.count <= index.books_max);
    assert(path.len > 0);
    b.epubs +%= std.hash.Wyhash.hash(0x65, path); // As `EpubHash` adds it
    const facts = file.facts_of(path) orelse return;
    var state_buffer: [files.path_bytes_max]u8 = undefined;
    var cover_buffer: [files.path_bytes_max]u8 = undefined;
    const state_path = state.path_for(&state_buffer, b.places.state_dir, path) catch return;
    const cover_path = state.sibling(&cover_buffer, state_path, "cover") catch return;
    const each = b.scratch.mark();
    defer b.scratch.rewind(each);
    const about = b.cache.find(path, facts) orelse read_epub(b, path, cover_path) orelse return;
    b.cache.add(path, facts, about);
    const e = epub_entry(path, &about, if (about.has_cover) cover_path else "");
    b.add(&e);
}

/// What an EPUB says of itself, read from the book, its cover saved the first time.
fn read_epub(b: *Build, path: [:0]const u8, cover_path: [:0]const u8) ?epub_cache.About {
    assert(path.len > 0);
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    const have_cover = file.exists(cover_path);
    const about = read_about(b.scratch, data, !have_cover) orelse return null;
    if (about.cover) |bytes| file.write_small(cover_path, bytes);
    if (about.cover != null) assert(!have_cover); // Read only for a book without one
    return .{
        .title = about.title,
        .author = about.author,
        .series = about.series,
        .series_index = about.series_index,
        .has_cover = have_cover or about.cover != null,
    };
}

/// What the library shows of an EPUB, read in `scratch`. With no room there for the
/// cover's bytes, read again without them: the book is listed with a cover of type.
fn read_about(scratch: *memory.Budget, data: []const u8, with_cover: bool) ?epub.Info {
    assert(scratch.region.?.kind == .bump);
    const start = scratch.mark();
    if (epub.info(scratch.allocator(), data, with_cover)) |about| {
        return about;
    } else |err| {
        if (err != error.OutOfMemory or !with_cover) return null;
    }
    scratch.rewind(start);
    const about = epub.info(scratch.allocator(), data, false) catch return null;
    assert(about.cover == null);
    return about;
}

/// An EPUB's entry: the book's own title and series, else its file name's.
fn epub_entry(
    path: [:0]const u8,
    about: *const epub_cache.About,
    cover: [:0]const u8,
) catalog.Entry {
    assert(path.len > 0);
    const from_file_name = catalog.series_from_file_name(path);
    const from_book = about.series.len > 0;
    const e: catalog.Entry = .{
        .path = path,
        .title = if (about.title.len > 0) about.title else std.fs.path.stem(path),
        .author = about.author,
        .percent = 0,
        .last = 0,
        .thumbnail = cover,
        .kind = "EPUB",
        .series = if (from_book) about.series else if (from_file_name) |f| f.name else "",
        .series_index = if (from_book)
            about.series_index
        else if (from_file_name) |f| f.index else 0,
    };
    assert(e.is_epub());
    return e;
}

/// The series set by hand, each over the book it names: its texts again with the
/// series, at the text file's end, and its record pointing to them.
fn apply_overrides(b: *Build, header: *index.Header) !void {
    assert(b.text.fd < 0); // Finished, so it reads whole
    var series_buffer: [files.path_bytes_max]u8 = undefined;
    const series_path = try files.path_in(&series_buffer, b.places.state_dir, "series");
    var lines: files.Lines = .{
        .reader = files.Reader.open(series_path, b.work.lines) catch return, // None set
    };
    defer lines.close();
    var found = try Found.open(b.places.dir, b.generation, b.work, true);
    defer found.close();
    var text = try files.Writer.append(try found.text_path(), b.work.out_text);
    errdefer text.abandon();
    // Each line moves on through the file, so there are fewer than it has bytes
    for (0..lines_max(&lines)) |_| {
        const line = (try lines.next()) orelse break;
        var one = std.heap.FixedBufferAllocator.init(b.work.row);
        const list = overrides.parse(one.allocator(), line) catch continue;
        if (list.len != 1) continue; // Not a line of the file's
        try found.set_series(&text, list[0]);
    }
    header.text_size = try text.finish();
    assert(header.text_size >= b.text.size);
}

/// A new index's files, open to find books by their state key and change them, while
/// it's built: records and texts read and written in place.
const Found = struct {
    work: *const Work,
    folder: []const u8,
    keys: files.Reader,
    records: files.Reader,
    text: files.Reader,
    keys_count: u32,
    suffix: []const u8, // ".new" while built
    path_buffer: [files.path_bytes_max]u8 = undefined,

    fn open(folder: []const u8, generation: u64, work: *const Work, new: bool) !Found {
        assert(folder.len > 0);
        const suffix: []const u8 = if (new) ".new" else "";
        var name_buffer: [32]u8 = undefined;
        const keys_name = try std.fmt.bufPrint(&name_buffer, "keys{s}", .{suffix});
        var keys_reader = try index.open_data(folder, keys_name, generation, work.in_keys);
        errdefer keys_reader.close();
        const records_name = try std.fmt.bufPrint(&name_buffer, "records{s}", .{suffix});
        var records = try index.open_data(folder, records_name, generation, work.in_records);
        errdefer records.close();
        const text_name = try std.fmt.bufPrint(&name_buffer, "text{s}", .{suffix});
        const text = try index.open_data(folder, text_name, generation, work.in_text);
        const entries = (keys_reader.size - index.file_head_bytes) / key_entry_bytes;
        assert(entries <= index.books_max);
        return .{
            .work = work,
            .folder = folder,
            .keys = keys_reader,
            .records = records,
            .text = text,
            .keys_count = @intCast(entries),
            .suffix = suffix,
        };
    }

    fn close(f: *Found) void {
        assert(f.keys.fd >= 0);
        f.keys.close();
        f.records.close();
        f.text.close();
        assert(f.text.fd < 0);
    }

    fn text_path(f: *Found) ![:0]const u8 {
        assert(f.folder.len > 0);
        const path = try std.fmt.bufPrintSentinel(&f.path_buffer, "{s}/text{s}", .{
            f.folder,
            f.suffix,
        }, 0);
        assert(std.mem.endsWith(u8, path, f.suffix));
        return path;
    }

    /// The first entry of the keys file whose key isn't below `key`.
    fn first_at_least(f: *Found, key: u64) !u32 {
        var low: u32 = 0;
        var high: u32 = f.keys_count;
        // Halves the range each time round
        for (0..64) |_| {
            if (low == high) break;
            const middle = low + (high - low) / 2;
            if (try f.key_at(middle) < key) low = middle + 1 else high = middle;
        }
        assert(low == high);
        assert(low <= f.keys_count);
        return low;
    }

    fn key_at(f: *Found, at: u32) !u64 {
        assert(f.keys.fd >= 0);
        assert(at < f.keys_count);
        const offset = index.file_head_bytes + @as(u64, at) * key_entry_bytes;
        const bytes = try f.keys.read_at(offset, key_entry_bytes);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn id_at(f: *Found, at: u32) !u32 {
        assert(f.keys.fd >= 0);
        assert(at < f.keys_count);
        const offset = index.file_head_bytes + @as(u64, at) * key_entry_bytes;
        const bytes = try f.keys.read_at(offset, key_entry_bytes);
        const id = std.mem.readInt(u32, bytes[8..12], .little);
        if (id >= index.books_max) return error.Damaged;
        return id;
    }

    fn record(f: *Found, id: u32) !index.Record {
        assert(id < index.books_max);
        assert(f.records.fd >= 0);
        const offset = index.file_head_bytes + @as(u64, id) * @sizeOf(index.Record);
        return index.Record.decode(try f.records.read_at(offset, @sizeOf(index.Record)));
    }

    fn write_record(f: *Found, id: u32, r: *index.Record) !void {
        assert(id < index.books_max);
        assert(f.folder.len > 0);
        r.seal();
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/records{s}", .{
            f.folder,
            f.suffix,
        }, 0);
        const offset = index.file_head_bytes + @as(u64, id) * @sizeOf(index.Record);
        if (!files.write_at(path, offset, std.mem.asBytes(r))) return error.CantWrite;
        f.records.len = 0; // What it holds may be from before
    }

    /// Sets the series of the book at the override's path, if there is one.
    fn set_series(f: *Found, text: *files.Writer, o: overrides.Override) !void {
        assert(f.keys_count <= index.books_max);
        assert(o.path.len > 0);
        const key = state.key_for(o.path);
        var at = try f.first_at_least(key);
        // Books with the same file name share a key: each is looked at
        for (0..f.keys_count) |_| {
            if (at == f.keys_count or try f.key_at(at) != key) return;
            const id = try f.id_at(at);
            at += 1;
            var r = try f.record(id);
            const slot = f.work.slot;
            const blob = try f.text.read_at(r.text_offset, r.text_len);
            @memcpy(slot.text[0..blob.len], blob);
            var e = try index.entry_of(&r, slot.text[0..blob.len]);
            if (!std.mem.eql(u8, e.path, o.path)) continue;
            e.series = o.name;
            e.series_index = o.index;
            const len = index.write_blob(f.work.blob, &e);
            const offset = text.size;
            text.write(f.work.blob[0..len]);
            r.text_offset = offset;
            r.text_len = len;
            r.series_index = o.index;
            r.series_hash = index.series_hash(o.name);
            try f.write_record(id, &r);
        }
    }
};

/// Merges what noface keeps of each book it opened (place, time read, marked read) into
/// the index's records, from one listing of the data folder: only the books with a
/// state file are read. A record that changes marks the orders it moves as stale.
pub fn merge_states(ix: *index.Index, work: *const Work, state_dir: []const u8) !void {
    assert(state_dir.len > 0);
    var found = try Found.open(ix.dir, ix.header.generation, work, false);
    defer found.close();
    var merge: Merge = .{ .ix = ix, .found = &found, .state_dir = state_dir };
    var folder_buffer: [files.path_bytes_max]u8 = undefined;
    const folder = try std.fmt.bufPrintSentinel(&folder_buffer, "{s}", .{state_dir}, 0);
    calls.each_entry(folder.ptr, &merge, Merge.entry);
    if (merge.failed) return error.CantMerge;
    if (merge.changed > 0) try ix.write_header();
    assert(ix.header.valid());
}

const Merge = struct {
    ix: *index.Index,
    found: *Found,
    state_dir: []const u8,
    changed: u32 = 0,
    failed: bool = false,

    fn entry(m: *Merge, name: []const u8, is_dir: bool) void {
        assert(m.changed <= m.ix.header.count);
        assert(name.len > 0);
        if (is_dir or m.failed) return;
        const key = state.key_of_name(name, "state") orelse return;
        m.merge_key(key, name) catch {
            m.failed = true;
        };
    }

    fn merge_key(m: *Merge, key: u64, name: []const u8) !void {
        assert(name.len > 0);
        assert(m.state_dir.len > 0);
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const format = "{s}/{s}";
        const path = try std.fmt.bufPrintSentinel(&path_buffer, format, .{ m.state_dir, name }, 0);
        const saved = state.load(path);
        var at = try m.found.first_at_least(key);
        // Books with the same file name share a state file: each is merged
        for (0..m.found.keys_count) |_| {
            if (at == m.found.keys_count or try m.found.key_at(at) != key) return;
            const id = try m.found.id_at(at);
            at += 1;
            var r = try m.ix.record(id);
            const before = r;
            merged(&r, saved);
            if (std.meta.eql(before, r)) continue;
            try m.ix.write_record(id, &r);
            m.note_change(&before, &r);
        }
    }

    fn note_change(m: *Merge, before: *const index.Record, after: *const index.Record) void {
        assert(!std.meta.eql(before.*, after.*));
        const h = &m.ix.header;
        const was_read = record_is_read(before);
        const is_read = record_is_read(after);
        if (is_read and !was_read) h.read += 1;
        if (was_read and !is_read) h.read -= 1;
        h.stale |= index.reading_orders;
        m.changed += 1;
        assert(h.read <= h.count);
    }
};

// Assertions: it reads a record from the drive: outside data, checked by `invariants`.
pub fn record_is_read(r: *const index.Record) bool {
    r.invariants();
    const e: catalog.Entry = .{
        .path = "",
        .title = "",
        .author = "",
        .percent = r.percent,
        .last = r.last,
        .finished = r.flags & index.Record.finished != 0,
    };
    return e.is_read();
}

/// A local book's record with what noface saved of it, as the library has always
/// merged them: an EPUB's place is noface's; a Kindle book's is the Kindle's unless
/// noface read it since.
fn merged(r: *index.Record, saved: state.State) void {
    r.invariants();
    if (r.availability != @backingInt(catalog.Availability.local)) return;
    r.seconds_read = saved.seconds;
    if (r.flags & index.Record.epub != 0) {
        r.percent = @intCast(@min(saved.percent orelse 0, 100));
        r.last = saved.opened;
        if (saved.finished) r.flags |= index.Record.finished else r.flags &= ~index.Record.finished;
        return;
    }
    r.percent = r.kindle_percent;
    r.last = r.kindle_last;
    if (state.prefer_kindle(saved, r.kindle_last)) return;
    if (saved.percent) |p| r.percent = @intCast(@min(p, 100));
    r.last = @max(r.last, saved.opened);
    assert(r.percent <= 100);
}

/// A line for the log, but not from the tests, where it would read as a failure.
fn log(comptime format: []const u8, args: anytype) void {
    assert(format.len > 0);
    assert(format[format.len - 1] == '\n');
    if (!builtin.is_test) std.debug.print(format, args);
}
