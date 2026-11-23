//! Building the library's index (index.zig) from what's on the Kindle: the catalog the
//! launcher exports, a line per Kindle book; the EPUBs under the documents folder; and
//! the series set by hand. Every book is written one at a time, through fixed buffers,
//! so a build takes the same memory for ten books or millions; finding books again (an
//! EPUB in the last build, a book by its state file) sorts their ids in memory, 8 bytes
//! a book, and looks them up by halves.
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
const watchers = @import("../kindle/input/watchers.zig");
const files = @import("files.zig");
const index = @import("index.zig");

const Item = index.Item;

/// The buffers a build writes and reads its files through: taken once, at startup, and
/// the same for any number of books.
pub const Buffers = struct {
    records: []u8,
    text: []u8,
    lines: []u8, // The catalog and the series file, a line at a time
    row: []u8, // One catalog row's texts, as parsed
    blob: *[index.blob_bytes_max]u8, // One book's texts, as written

    const stream_bytes: u32 = 64 << 10;

    /// What `init` takes, at most, its blocks rounded up to whole units of the region.
    pub const bytes_max: u64 = 7 * stream_bytes + index.blob_bytes_max + 5 * memory.unit_bytes;

    // Assertions: it takes blocks of the budget, each of a size fixed above.
    pub fn init(budget: *memory.Budget) !Buffers {
        const buffers: Buffers = .{
            .records = try budget.untouched(u8, stream_bytes),
            .text = try budget.untouched(u8, stream_bytes),
            .lines = try budget.untouched(u8, stream_bytes),
            .row = try budget.untouched(u8, 4 * stream_bytes),
            .blob = try budget.untouched_one([index.blob_bytes_max]u8),
        };
        assert(buffers.row.len > buffers.lines.len); // A row's texts, from a line
        return buffers;
    }
};

/// Where the books are, and where their index is kept.
pub const Places = struct {
    catalog_path: [*:0]const u8, // The Kindle's catalog, exported
    documents: []const u8, // Where EPUBs are found
    state_dir: []const u8, // Each book's place and cover, and the series set by hand
    dir: []const u8, // The index's folder
    /// The launcher's watchdog's heartbeat, beaten as books are added and merged: a
    /// build of thousands outlasts its two minutes before noface's loop first turns.
    /// Null in the tests, which leave the watchdog's file alone.
    heartbeat: ?[*:0]const u8,
};

/// What an index built now would be built from: the catalog's and the series file's
/// size and change time, and the EPUBs found (by their paths: one listing of the
/// folders, no file opened).
pub fn sources_now(scratch: *memory.Budget, places: Places) index.Sources {
    assert(places.dir.len > 0);
    assert(scratch.region.?.kind == .bump); // Its listing goes, rewound, as it ends
    const start = scratch.mark();
    defer scratch.rewind(start);
    const catalog_facts = file.facts_of(places.catalog_path);
    var series_buffer: [files.path_bytes_max]u8 = undefined;
    // A path too long to make: no overrides file to read
    const series_facts = if (overrides.file_path(&series_buffer, places.state_dir)) |p|
        file.facts_of(p)
    else |_|
        null;
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
    return sources;
}

/// The EPUBs found, as one number however they're listed: a sum of their paths' hashes.
const EpubHash = struct {
    sum: u64 = 0,

    fn add(h: *EpubHash, path: [:0]const u8) void {
        assert(path.len > 0);
        const before = h.sum;
        h.sum +%= std.hash.Wyhash.hash(0x65, path);
        assert(h.sum != before or std.hash.Wyhash.hash(0x65, path) == 0); // Counted
    }
};

/// Where the books are, and the index's format: a different folder, or a noface that
/// writes the index differently, builds it again.
fn places_hash(places: Places) u64 {
    assert(places.documents.len > 0);
    assert(places.catalog_path[0] == '/'); // Never relative to where noface runs
    var hasher = std.hash.Wyhash.init(@sizeOf(index.Record) + @sizeOf(index.Header));
    hasher.update(std.mem.span(places.catalog_path));
    hasher.update("\x00");
    hasher.update(places.documents);
    return hasher.final();
}

/// A build under way: its files, and what it has counted.
const Build = struct {
    buffers: *const Buffers,
    scratch: *memory.Budget,
    places: Places,
    records: files.Writer,
    text: files.Writer,
    last: ?EpubsRead, // What the last build read of each EPUB
    beat_us: u64, // When it last beat, or started
    count: u32 = 0,
    local: u32 = 0,
    downloading: u32 = 0,
    left_out: u32 = 0, // Past `index.books_max`, or the text file's most
    /// Something there couldn't be read this time (not a book that isn't one): the
    /// index is kept, but built again at the next load (`build`).
    incomplete: bool = false,

    /// Adds book `e` to the index, as the next id. An EPUB read whole comes with its
    /// file's `facts`, so the next build reads it only if its file changed; without
    /// them (a Kindle book, the catalog's; an EPUB whose cover couldn't be saved), the
    /// next build reads it again.
    fn add(b: *Build, e: *const catalog.Entry, facts: ?calls.Facts) void {
        assert(b.count <= index.books_max);
        if (b.count == index.books_max) {
            b.left_out += 1;
            return;
        }
        const len = index.write_blob(b.buffers.blob, e);
        if (b.text.size + len > index.text_file_bytes_max) {
            b.left_out += 1;
            return;
        }
        var r = index.record_of(e, b.text.size, len);
        if (facts) |f| {
            r.file_size = f.size;
            r.file_modified = f.modified_s;
            r.seal();
        }
        b.text.write(b.buffers.blob[0..len]);
        b.records.write(std.mem.asBytes(&r));
        b.count += 1;
        if (e.is_local()) b.local += 1;
        if (e.availability == .downloading) b.downloading += 1;
        assert(b.local <= b.count);
    }
};

/// Builds the index in `places.dir` from the sources, afresh, and opens it: every file
/// written beside the old, and put in its place only once all are whole, the header
/// last. `last`, the index built before, is read for the EPUBs it has, then closed.
pub fn build(
    buffers: *const Buffers,
    items: []Item,
    scratch: *memory.Budget,
    places: Places,
    sources: index.Sources,
    last: ?*index.Index,
) !index.Index {
    assert(scratch.region.?.kind == .bump);
    assert(places.dir.len > 0);
    const generation = std.hash.Wyhash.hash(os.now_us(), std.mem.asBytes(&sources)) | 1;
    var b: Build = .{
        .buffers = buffers,
        .scratch = scratch,
        .places = places,
        .records = undefined,
        .text = undefined,
        .last = if (last) |ix| EpubsRead.sort(ix, items) else null,
        .beat_us = os.now_us(),
    };
    // Closed before the new files are put in place (a mapped file renamed over faults),
    // or on the way out if the build fails first: null once closed
    var last_open = last;
    defer if (last_open) |ix| ix.close();
    b.records = try create_data(places.dir, "records.new", generation, buffers.records);
    errdefer abandon_data(places.dir, "records.new", &b.records);
    b.text = try create_data(places.dir, "text.new", generation, buffers.text);
    errdefer abandon_data(places.dir, "text.new", &b.text);
    add_kindle_books(&b);
    add_epubs(&b);
    if (b.left_out > 0) log("library: {d} books past the most kept\n", .{b.left_out});
    _ = try b.records.finish();
    _ = try b.text.finish();
    if (last_open) |ix| ix.close();
    last_open = null;
    for ([_][]const u8{ "records", "text" }) |name| {
        var from: [files.path_bytes_max]u8 = undefined;
        var to: [files.path_bytes_max]u8 = undefined;
        const new = try std.fmt.bufPrintSentinel(&from, "{s}/{s}.new", .{ places.dir, name }, 0);
        try files.replace(new, try files.path_in(&to, places.dir, name));
    }
    var ix = try index.Index.open_as(places.dir, .{
        .generation = generation,
        .count = b.count,
        .local = b.local,
        .downloading = b.downloading,
        // Built from less than is there: never matches, so the next load builds again
        .sources = if (b.incomplete) never_matching(sources) else sources,
        .text_size = b.text.size,
    });
    errdefer ix.close();
    // A series that can't be set leaves the book as it is: the rest of the index stands
    apply_overrides(&ix, buffers, items, places) catch |err| {
        log("library: series set by hand not applied ({s})\n", .{@errorName(err)});
    };
    try ix.write_header();
    return ix;
}

/// `sources` changed so no index built from what's there matches it: the next load
/// builds again, as `sources_now` does for a folder not wholly listed.
fn never_matching(sources: index.Sources) index.Sources {
    var changed = sources;
    changed.epubs +%= os.now_us() | 1; // Never 0: always another sum
    assert(!std.meta.eql(changed, sources));
    return changed;
}

/// A new data file given up on, and removed: a build that failed leaves no part of
/// one (up to a gigabyte and more) on the drive.
fn abandon_data(folder: []const u8, name: []const u8, w: *files.Writer) void {
    assert(name.len > 0);
    w.abandon();
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    // Ignored: a path that can't be made is one that was never made either
    const path = files.path_in(&path_buffer, folder, name) catch return;
    files.remove(path);
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
    const reader = files.Reader.open(b.places.catalog_path, b.buffers.lines) catch |err| {
        // No catalog: no Kindle books. One that's there but can't be read: some, later
        if (err != error.NotFound) b.incomplete = true;
        return;
    };
    var lines: files.Lines = .{ .reader = reader };
    defer lines.close();
    // Each line moves on through the file, so there are fewer than it has bytes
    for (0..lines_max(&lines)) |_| {
        if (b.places.heartbeat) |path| watchers.beat_when_due(path, &b.beat_us);
        const line = (lines.next() catch {
            b.incomplete = true; // The rest of the catalog, next time
            break;
        }) orelse break;
        if (line.len == 0) continue;
        var row_memory = std.heap.FixedBufferAllocator.init(b.buffers.row);
        // A row whose texts don't fit (longer than the line, many times over) is passed
        var e = (catalog_db.parse_line(row_memory.allocator(), line) catch continue) orelse
            continue;
        // The catalog's flag can stay set long after a download ended: the file decides
        if (e.availability == .downloading and is_complete_book(e.path)) e.availability = .local;
        b.add(&e, null);
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
/// documents folder, and read (or what the last build read of them kept) one at a time.
fn add_epubs(b: *Build) void {
    assert(b.places.documents.len > 0);
    const start = b.scratch.mark();
    defer b.scratch.rewind(start);
    const walked = dir.walk(b.scratch.allocator(), b.places.documents, ".epub", b, add_epub) catch
        dir.Walked{ .cut_short = true };
    if (walked.cut_short) {
        log("library: {s} only partly listed\n", .{b.places.documents});
        b.incomplete = true;
    }
    assert(b.count <= index.books_max);
}

fn add_epub(b: *Build, path: [:0]const u8) void {
    assert(b.count <= index.books_max);
    assert(path.len > 0);
    // Each EPUB, read or not: thousands, or a few slow to read, outlast the watchdog
    if (b.places.heartbeat) |heartbeat| watchers.beat_when_due(heartbeat, &b.beat_us);
    // Listed, then not there to look at: gone meanwhile, or the drive failed
    const facts = file.facts_of(path) orelse {
        b.incomplete = true;
        return;
    };
    var state_buffer: [files.path_bytes_max]u8 = undefined;
    var cover_buffer: [files.path_bytes_max]u8 = undefined;
    const state_path = state.path_for(&state_buffer, b.places.state_dir, path) catch return;
    const cover_path = state.sibling(&cover_buffer, state_path, "cover") catch return;
    const each = b.scratch.mark();
    defer b.scratch.rewind(each);
    const known = if (b.last) |*last| last.find(path, facts) else null;
    const about = known orelse read_epub(b, path, cover_path) orelse return;
    const e = epub_entry(path, &about, if (about.has_cover) cover_path else null);
    // A cover that couldn't be saved (a full drive) is tried again by the next build
    b.add(&e, if (about.cover_unsaved) null else facts);
}

/// What the library keeps of an EPUB, read from the book or from the last build.
const About = struct {
    title: []const u8,
    author: []const u8,
    series: ?catalog.Series,
    has_cover: bool, // Its cover was saved beside its state once
    /// The book has a cover, but saving it failed: none is shown for now.
    cover_unsaved: bool = false,
};

/// What an EPUB says of itself, read from the book, its cover saved the first time.
fn read_epub(b: *Build, path: [:0]const u8, cover_path: [:0]const u8) ?About {
    assert(path.len > 0);
    const data = file.map(path) catch |err| {
        // Not read this time (gone since listed, or the drive failed): read at the next
        // load. An empty file or one too big to map stays so, and is passed for good
        switch (err) {
            error.NotFound, error.OpenFailed, error.SeekFailed => b.incomplete = true,
            error.EmptyFile, error.MmapFailed => {},
        }
        return null;
    };
    defer file.unmap(data);
    const have_cover = file.exists(cover_path);
    const about = read_about(b.scratch, data, !have_cover) orelse return null;
    if (about.cover) |bytes| file.write_small(cover_path, bytes);
    if (about.cover != null) assert(!have_cover); // Read only for a book without one
    return .{
        .title = about.title,
        .author = about.author,
        .series = about.series,
        // Whether it's there now: a cover whose write failed (a full drive) is none,
        // for now
        .has_cover = file.exists(cover_path),
        .cover_unsaved = about.cover != null and !file.exists(cover_path),
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
fn epub_entry(path: [:0]const u8, about: *const About, cover: ?[:0]const u8) catalog.Entry {
    assert(path.len > 0);
    const e: catalog.Entry = .{
        .path = path,
        .title = if (about.title.len > 0) about.title else std.fs.path.stem(path),
        .author = about.author,
        .percent = 0,
        .last = 0,
        .thumbnail = cover,
        .kind = "EPUB",
        .series = about.series orelse catalog.series_from_file_name(path),
    };
    assert(e.is_epub());
    return e;
}

/// The EPUBs of the last build, their ids sorted by their path's hash, to find each by
/// halves: what was read of a book whose file hasn't changed needn't be read again.
const EpubsRead = struct {
    ix: *const index.Index,
    sorted: []Item,

    fn sort(ix: *const index.Index, items: []Item) EpubsRead {
        assert(items.len >= ix.header.count);
        var count: u32 = 0;
        for (0..ix.header.count) |i| {
            const id: u32 = @intCast(i);
            const r = ix.record(id);
            // One whose series was set by hand no longer says what the book does
            if (r.flags & index.Record.epub == 0 or r.flags & index.Record.series_by_hand != 0) {
                continue;
            }
            items[count] = .{ .id = id, .key = path_key(ix.entry(id).path) };
            count += 1;
        }
        assert(count <= ix.header.count);
        const sorted = items[0..count];
        std.mem.sort(Item, sorted, {}, by_key);
        assert(std.sort.isSorted(Item, sorted, {}, by_key));
        return .{ .ix = ix, .sorted = sorted };
    }

    /// What the last build read of the EPUB at `path`, if its file is as it was then.
    fn find(read: *const EpubsRead, path: []const u8, facts: calls.Facts) ?About {
        assert(path.len > 0);
        assert(read.sorted.len <= read.ix.header.count);
        const key = path_key(path);
        for (read.sorted[first_with(read.sorted, key)..]) |item| {
            if (item.key != key) return null;
            const r = read.ix.record(item.id);
            const e = read.ix.entry(item.id);
            if (!std.mem.eql(u8, e.path, path)) continue; // Another path, the same hash
            if (r.file_size != facts.size or r.file_modified != facts.modified_s) return null;
            return .{
                .title = e.title,
                .author = e.author,
                .series = e.series,
                .has_cover = e.thumbnail != null,
            };
        }
        return null;
    }

    fn path_key(path: []const u8) u32 {
        assert(path.len > 0);
        return @truncate(std.hash.Wyhash.hash(0x70, path));
    }
};

fn by_key(_: void, a: Item, b: Item) bool {
    return a.key < b.key;
}

/// The first of `sorted` (by key) whose key isn't below `key`.
fn first_with(sorted: []const Item, key: u32) u32 {
    assert(sorted.len <= index.books_max); // A place among them fits a u32
    const at = std.sort.lowerBound(Item, sorted, key, struct {
        fn order(k: u32, item: Item) std.math.Order {
            return std.math.order(k, item.key);
        }
    }.order);
    assert(at <= sorted.len);
    return @intCast(at);
}

/// The books on this Kindle, their ids sorted by their state file's key, to find each
/// by halves.
fn by_state_key(ix: *const index.Index, items: []Item) []Item {
    return sorted_by(ix, items, state.key_for);
}

/// The books on this Kindle, their ids sorted by `key_of` their path (a key's high half),
/// to find each by halves: by the names their files have now, or had before.
fn sorted_by(ix: *const index.Index, items: []Item, comptime key_of: fn ([]const u8) u64) []Item {
    assert(items.len >= ix.header.count);
    var count: u32 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const e = ix.entry(id);
        if (!e.is_local() or e.path.len == 0) continue;
        items[count] = .{ .id = id, .key = @truncate(key_of(e.path) >> 32) };
        count += 1;
    }
    const sorted = items[0..count];
    std.mem.sort(Item, sorted, {}, by_key);
    assert(count <= ix.header.local);
    return sorted;
}

/// The series set by hand, each over the book it names: its texts again with the
/// series, at the text file's end, and its record pointing to them.
fn apply_overrides(
    ix: *index.Index,
    buffers: *const Buffers,
    items: []Item,
    places: Places,
) !void {
    var series_buffer: [files.path_bytes_max]u8 = undefined;
    const series_path = try overrides.file_path(&series_buffer, places.state_dir);
    var lines: files.Lines = .{
        .reader = files.Reader.open(series_path, buffers.lines) catch return, // None set
    };
    defer lines.close();
    const sorted = by_state_key(ix, items);
    assert(sorted.len <= ix.header.local);
    // Each line moves on through the file, so there are fewer than it has bytes
    for (0..lines_max(&lines)) |_| {
        const line = (try lines.next()) orelse break;
        var one = std.heap.FixedBufferAllocator.init(buffers.row);
        const list = overrides.parse(one.allocator(), line) catch continue;
        if (list.len != 1) continue; // Not a line of the file's
        try set_series(ix, buffers, sorted, list[0]);
    }
    assert(ix.text_file.len == ix.header.text_size); // Mapped again for each one set
}

/// Sets the series of the book at the override's path, if it's here: its texts written
/// again at the text file's end, mapped, and then its record pointed at them.
fn set_series(
    ix: *index.Index,
    buffers: *const Buffers,
    sorted: []const Item,
    o: overrides.Override,
) !void {
    assert(o.path.len > 0);
    const key = state.key_for(o.path);
    const high: u32 = @truncate(key >> 32);
    for (sorted[first_with(sorted, high)..]) |item| {
        if (item.key != high) return;
        var e = ix.entry(item.id);
        if (!std.mem.eql(u8, e.path, o.path)) continue;
        e.series = o.series;
        const len = index.write_blob(buffers.blob, &e);
        // The text file keeps to its most here as in `Build.add`: past it the book keeps
        // the series it has, where growing past it would fail the whole build
        if (ix.header.text_size + len > index.text_file_bytes_max) {
            log("library: series of {s} not set, the index is full\n", .{o.path});
            return;
        }
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        var text = try files.Writer.append(
            try files.path_in(&path_buffer, ix.dir, "text"),
            buffers.text,
        );
        const offset = text.size;
        text.write(buffers.blob[0..len]);
        try ix.grow_text(try text.finish());
        var r = ix.record(item.id);
        r.text_offset = offset;
        r.text_len = len;
        r.series_index = if (o.series) |s| s.index else 0;
        r.flags |= index.Record.series_by_hand;
        try ix.write_record(item.id, &r);
        // Reads back as set: in a series, or not
        assert((ix.entry(item.id).series == null) == (o.series == null));
    }
}

/// Moves each book's files from the names noface 0.2 and before gave them, by the
/// book's file name, to the names its whole path gives (`state.key_for`), before any
/// are read. Two books of one name shared those files: each gets a copy, as each
/// showed that place before. A file already under its new name is never written over,
/// and one of a book not here (deleted, or still downloading) keeps its old name until
/// the book is. Every load looks, so a move cut short goes on at the next, from any of
/// the files left: the place moves last, the others before it.
pub fn rename_by_path(
    ix: *const index.Index,
    items: []Item,
    places: Places,
    scratch: *memory.Budget,
) !void {
    assert(places.state_dir.len > 0);
    assert(items.len >= ix.header.count); // Room to sort every book
    // Listed first, then moved: a folder renamed in while it's listed can list a name twice
    var old = Listed{ .alloc = scratch.allocator() };
    var folder_buffer: [files.path_bytes_max]u8 = undefined;
    const folder = try std.fmt.bufPrintSentinel(&folder_buffer, "{s}", .{places.state_dir}, 0);
    // Every name, or none acted on: the files of a book missed now are moved next time
    if (!calls.each_entry(folder.ptr, &old, Listed.entry)) return error.CantList;
    if (old.failed) return error.CantList;
    if (old.keys.items.len == 0) return;
    // Each key once, whichever of its kinds were listed
    std.mem.sort(u64, old.keys.items, {}, std.sort.asc(u64));
    const keys = unique(old.keys.items);
    const sorted = sorted_by(ix, items, state.key_by_name);
    for (keys) |key| {
        const high: u32 = @truncate(key >> 32);
        const first = first_with(sorted, high);
        // The books whose file name gave this key: those of `sorted` from `first` on
        var count: u32 = 0;
        for (sorted[first..]) |item| {
            if (item.key != high) break;
            if (state.key_by_name(ix.entry(item.id).path) == key) count += 1;
        }
        if (count > 0) try move_files(ix, places.state_dir, key, sorted[first..], count);
    }
}

/// `sorted`'s values each once, in place: the start of it.
fn unique(sorted: []u64) []u64 {
    if (sorted.len == 0) return sorted;
    var kept: u32 = 1;
    for (sorted[1..]) |value| {
        assert(value >= sorted[kept - 1]); // Sorted, so a repeat is beside its first
        if (value == sorted[kept - 1]) continue;
        sorted[kept] = value;
        kept += 1;
    }
    assert(kept <= sorted.len);
    return sorted[0..kept];
}

/// The keys of the files named by a key in the data folder, as listed: of every kind.
const Listed = struct {
    alloc: std.mem.Allocator,
    keys: std.ArrayList(u64) = .empty,
    failed: bool = false,

    fn entry(l: *Listed, name: []const u8, is_dir: bool) void {
        assert(name.len > 0);
        if (is_dir or l.failed) return;
        for (state.kinds) |kind| {
            const key = state.key_of_name(name, kind) orelse continue;
            const before = l.keys.items.len;
            l.keys.append(l.alloc, key) catch {
                l.failed = true;
                return;
            };
            assert(l.keys.items.len == before + 1);
            return;
        }
    }
};

/// Each kind of file named by `key` copied to the names of the `count` books of
/// `sorted` (from the first with its high half) whose file name gave it, and moved to
/// the last one's: the place last of all, so while it's there, so is the key.
fn move_files(
    ix: *const index.Index,
    state_dir: []const u8,
    key: u64,
    sorted: []const Item,
    count: u32,
) !void {
    assert(count > 0);
    // Every kind but the place, then the place
    comptime assert(std.mem.eql(u8, state.kinds[0], "state"));
    const order = state.kinds[1..] ++ state.kinds[0..1];
    inline for (order) |kind| {
        var from_buffer: [files.path_bytes_max]u8 = undefined;
        const named = .{ state_dir, kind, key };
        const from = try std.fmt.bufPrintSentinel(&from_buffer, "{s}/{s}-{x:0>16}", named, 0);
        switch (file.presence(from)) {
            .absent => {},
            .unknown => return error.CantRead, // Tried again at the next load
            .here => try move_file(ix, state_dir, kind, from, key, sorted, count),
        }
    }
}

/// The file `from` (of `kind`, named by `key`) copied to each of the `count` books but
/// the last, and renamed to the last's: never over a file already there.
fn move_file(
    ix: *const index.Index,
    state_dir: []const u8,
    comptime kind: []const u8,
    from: [:0]const u8,
    key: u64,
    sorted: []const Item,
    count: u32,
) !void {
    var done: u32 = 0;
    for (sorted) |item| {
        if (done == count) break;
        const path = ix.entry(item.id).path;
        if (state.key_by_name(path) != key) continue; // Same high half, another name
        done += 1;
        var state_buffer: [files.path_bytes_max]u8 = undefined;
        const own_state = try state.path_for(&state_buffer, state_dir, path);
        var to_buffer: [files.path_bytes_max]u8 = undefined;
        const to = try state.sibling(&to_buffer, own_state, kind);
        assert(!std.mem.eql(u8, from, to)); // A whole path's name is never a file name's
        switch (file.presence(to)) {
            .here => continue, // Saved under its new name already: newer
            .unknown => return error.CantRead, // Maybe there: never written over
            .absent => {},
        }
        if (done < count) {
            if (!file.copy_file(from, to)) return error.CantCopy;
        } else {
            if (os.failed(calls.rename(from, to))) return error.CantRename;
        }
    }
    assert(done == count);
}

/// Merges what noface keeps of each book it opened (place, time read, marked read) into
/// the index's records, from one listing of the data folder: only the books with a
/// state file are read.
pub fn merge_states(ix: *const index.Index, items: []Item, places: Places) !void {
    assert(places.state_dir.len > 0);
    var merge: Merge = .{
        .ix = ix,
        .sorted = by_state_key(ix, items),
        .state_dir = places.state_dir,
        .heartbeat = places.heartbeat,
        .beat_us = os.now_us(),
    };
    var folder_buffer: [files.path_bytes_max]u8 = undefined;
    const folder = try std.fmt.bufPrintSentinel(&folder_buffer, "{s}", .{places.state_dir}, 0);
    const whole = calls.each_entry(folder.ptr, &merge, Merge.entry);
    if (merge.failed) return error.CantMerge;
    // What was listed is merged; a book whose state wasn't is merged at the next load
    if (!whole) return error.CantList;
    assert(merge.sorted.len <= ix.header.local);
}

const Merge = struct {
    ix: *const index.Index,
    sorted: []const Item,
    state_dir: []const u8,
    heartbeat: ?[*:0]const u8, // As `Places.heartbeat`: thousands of state files are slow
    beat_us: u64, // When it last beat, or started
    failed: bool = false,

    fn entry(m: *Merge, name: []const u8, is_dir: bool) void {
        assert(name.len > 0);
        assert(m.sorted.len <= m.ix.header.local);
        if (m.heartbeat) |path| watchers.beat_when_due(path, &m.beat_us);
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
        // Read only for a book here: the drive is slow, and a file may be a deleted book's
        var saved: ?state.State = null;
        const high: u32 = @truncate(key >> 32);
        // Books whose keys share a high half: only the one with the whole key is merged
        for (m.sorted[first_with(m.sorted, high)..]) |item| {
            if (item.key != high) return;
            if (state.key_for(m.ix.entry(item.id).path) != key) continue; // Same high half
            if (saved == null) saved = state.load(path);
            var r = m.ix.record(item.id);
            const before = r;
            merged(&r, saved.?);
            if (!std.meta.eql(before, r)) try m.ix.write_record(item.id, &r);
        }
    }
};

/// A local book's record with what noface saved of it, as the library has always
/// merged them: an EPUB's place is noface's; a Kindle book's is the Kindle's unless
/// noface read it since.
fn merged(r: *index.Record, saved: state.State) void {
    r.invariants();
    if (r.availability != @backingInt(catalog.Availability.local)) return;
    r.seconds_read = saved.seconds;
    r.set_words_left(saved.words_left);
    if (r.flags & index.Record.epub != 0) {
        r.percent = @intCast(@min(saved.percent orelse 0, 100));
        r.last = saved.opened;
        if (saved.finished) r.flags |= index.Record.finished else r.flags &= ~index.Record.finished;
        return;
    }
    r.percent = r.kindle_percent;
    r.last = r.kindle_last;
    if (state.prefer_kindle(saved, r.kindle_last)) {
        // The place is the stock reader's, so what noface counted from its own is old
        r.set_words_left(null);
        return;
    }
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

test "a saved place's words left are kept, unless the stock reader read the book since" {
    const book: catalog.Entry = .{
        .path = "/mnt/us/documents/Dune.kfx",
        .title = "Dune",
        .author = "",
        .percent = 10,
        .last = 0,
        .kindle_percent = 10,
        .kindle_last = 1_800_000_000,
    };
    const saved: state.State = .{
        .para = 4,
        .percent = 40,
        .opened = 1_700_000_000,
        .words_left = 9000,
    };
    // The stock reader read it last: its place, and no words left from noface's
    var r = index.record_of(&book, 0, 0);
    merged(&r, saved);
    try std.testing.expectEqual(@as(u8, 10), r.percent);
    try std.testing.expect(r.flags & index.Record.words_known == 0);
    // Read in noface last: noface's place, and the words left from it
    var newer = saved;
    newer.opened = 1_900_000_000;
    r = index.record_of(&book, 0, 0);
    merged(&r, newer);
    try std.testing.expectEqual(@as(u8, 40), r.percent);
    try std.testing.expect(r.flags & index.Record.words_known != 0);
    try std.testing.expectEqual(@as(u64, 9000), r.words_left);
    // An EPUB's place is always noface's
    var an_epub = book;
    an_epub.path = "/mnt/us/documents/Dune.epub";
    r = index.record_of(&an_epub, 0, 0);
    merged(&r, saved);
    try std.testing.expectEqual(@as(u64, 9000), r.words_left);
}
