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
const hidden = @import("../model/hidden.zig");
const memory = @import("../base/memory.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");
const state = @import("../sys/state.zig");
const dir = @import("../sys/dir.zig");
const epub = @import("../epub/epub.zig");
const catalog_db = @import("../kindle/catalog.zig");
const kfx = @import("../kindle/kfx.zig");
const heartbeat = @import("../kindle/heartbeat.zig");
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
    var hidden_buffer: [files.path_bytes_max]u8 = undefined;
    // Likewise: no hidden books to read
    const hidden_facts = if (hidden.file_path(&hidden_buffer, places.state_dir)) |p|
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
        .hidden_size = if (hidden_facts) |f| f.size else 0,
        .hidden_modified = if (hidden_facts) |f| f.modified_s else 0,
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
    last: ?LastBuild, // What the last build kept of each book
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
        .last = if (last) |ix| LastBuild.sort(ix, items) else null,
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
    // A series that can't be set leaves the book as it is: the rest of the index stands,
    // marked built from less than is there, so the next load builds and tries again
    apply_overrides(&ix, buffers, items, places) catch |err| {
        log("library: series set by hand not applied ({s})\n", .{@errorName(err)});
        ix.header.sources = never_matching(sources);
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
    assert(folder.len > 0);
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
    assert(b.places.state_dir.len > 0); // Where the hidden books are listed
    // Read whole first, as the catalog reads through the same buffer
    const hidden_keys = read_hidden(b) catch {
        b.incomplete = true; // Listed as they are, the hidden among them, until next time
        return add_catalog(b, &.{});
    };
    add_catalog(b, hidden_keys);
}

/// The keys of the books hidden, sorted, in the build's scratch: none without a file.
fn read_hidden(b: *Build) ![]const []const u8 {
    var path_buffer: [files.path_bytes_max]u8 = undefined;
    const path = try hidden.file_path(&path_buffer, b.places.state_dir);
    var lines: files.Lines = .{
        .reader = files.Reader.open(path, b.buffers.lines) catch |err| switch (err) {
            error.NotFound => return &.{}, // None hidden
            else => return err,
        },
    };
    defer lines.close();
    assert(lines.at == 0);
    const alloc = b.scratch.allocator();
    var keys: std.ArrayList([]const u8) = .empty;
    // Each line moves on through the file, so there are fewer than it has bytes
    for (0..lines_max(&lines)) |_| {
        const line = (try lines.next()) orelse break;
        const key = hidden.key_of(line) orelse continue;
        try keys.append(alloc, try alloc.dupe(u8, key));
    }
    std.mem.sort([]const u8, keys.items, {}, key_less);
    assert(lines.at <= lines.reader.size);
    return keys.items;
}

fn key_less(_: void, a: []const u8, b: []const u8) bool {
    assert(a.len > 0); // `hidden.key_of` keeps no empty key
    assert(b.len > 0);
    return std.mem.lessThan(u8, a, b);
}

/// Whether book `e`, in the cloud, is hidden: one on the Kindle shows whatever the file
/// says, as it's there to read.
fn is_hidden(e: *const catalog.Entry, hidden_keys: []const []const u8) bool {
    // Sorted, as the search needs (`read_hidden`)
    if (hidden_keys.len > 1) assert(!key_less({}, hidden_keys[1], hidden_keys[0]));
    if (e.availability != .cloud) return false;
    if (e.key.len == 0) return false;
    const found = std.sort.binarySearch([]const u8, hidden_keys, e.key, key_order);
    if (found) |at| assert(std.mem.eql(u8, hidden_keys[at], e.key)); // That book's key
    return found != null;
}

fn key_order(key: []const u8, item: []const u8) std.math.Order {
    assert(key.len > 0); // `is_hidden` looks for none empty
    assert(item.len > 0);
    return std.mem.order(u8, key, item);
}

/// The catalog's books, but for those hidden.
fn add_catalog(b: *Build, hidden_keys: []const []const u8) void {
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
        if (b.places.heartbeat) |path| heartbeat.beat_when_due(path, &b.beat_us);
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
        if (is_hidden(&e, hidden_keys)) continue; // The reader's, from the book's card
        if (b.last) |*last| {
            if (has_path(e)) {
                if (last.find(e.path)) |id| kept_reading(&e, last.reading(id));
            }
        }
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
    if (b.places.heartbeat) |beat_path| heartbeat.beat_when_due(beat_path, &b.beat_us);
    // Listed, then not there to look at: gone meanwhile, or the drive failed
    const facts = file.facts_of(path) orelse {
        b.incomplete = true;
        return;
    };
    var state_buffer: [files.path_bytes_max]u8 = undefined;
    var cover_buffer: [files.path_bytes_max]u8 = undefined;
    const state_path = state.path_for(&state_buffer, b.places.state_dir, path) catch return;
    const cover_path = state.sibling(&cover_buffer, state_path, .cover) catch return;
    const each = b.scratch.mark();
    defer b.scratch.rewind(each);
    // The last build's record of it: what the book says of itself, if its file is as it
    // was, and how far the reader is, whatever: kept, so a place that can't be read as
    // it's merged leaves the book as it was, never shown unread
    var known: ?About = null;
    var reading: catalog.Progress = .none;
    if (b.last) |*last| {
        if (last.find(path)) |id| {
            known = last.about_if(id, facts);
            reading = last.reading(id).progress;
        }
    }
    const about = known orelse read_epub(b, path, cover_path) orelse return;
    const e = epub_entry(path, &about, if (about.has_cover) cover_path else null, reading);
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
    if (about.cover) |bytes| {
        // Unwritten, the book has no cover file, and its cover is read again next build
        if (!file.write_small(cover_path, bytes)) log("library: a cover not saved\n", .{});
    }
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

/// A Kindle book's row with how far noface had it, as the last build kept it: its time
/// read, and its percent, date and time left while they were noface's and the stock
/// reader hasn't read it since. A place merged after replaces them all; one that can't
/// be read leaves them, never the book shown unread.
fn kept_reading(e: *catalog.Entry, last: Kept) void {
    assert(!e.is_epub());
    assert(last.progress.percent <= 100);
    e.seconds_read = last.progress.seconds_read;
    // The record's date the Kindle's own then: the catalog's numbers are the newer
    if (!state.outside_newer(last.progress.last, last.kindle_last)) return;
    // The stock reader read it since
    if (state.outside_newer(e.kindle_last, last.progress.last)) return;
    e.percent = last.progress.percent;
    e.last = last.progress.last;
    e.words_left = last.progress.words_left;
}

/// What the last build's record kept of a book: how far the reader was, and the
/// Kindle's own date then, to tell whose that was.
const Kept = struct { progress: catalog.Progress, kindle_last: u64 };

/// An EPUB's entry: the book's own title and series, else its file name's.
fn epub_entry(
    path: [:0]const u8,
    about: *const About,
    cover: ?[:0]const u8,
    reading: catalog.Progress,
) catalog.Entry {
    assert(path.len > 0);
    assert(reading.percent <= 100);
    const e: catalog.Entry = .{
        .path = path,
        .title = if (about.title.len > 0) about.title else std.fs.path.stem(path),
        .author = about.author,
        .percent = reading.percent,
        .last = reading.last,
        .finished = reading.finished,
        .seconds_read = reading.seconds_read,
        .words_left = reading.words_left,
        .thumbnail = cover,
        .kind = "EPUB",
        .series = about.series orelse catalog.series_from_file_name(path),
    };
    assert(e.is_epub());
    return e;
}

/// The books of the last build, their ids sorted by their path's hash, to find each by
/// halves: what was read of an EPUB whose file hasn't changed needn't be read again, and
/// how far the reader is in every book is kept, should their place not merge.
const LastBuild = struct {
    ix: *const index.Index,
    sorted: []Item,

    fn sort(ix: *const index.Index, items: []Item) LastBuild {
        assert(items.len >= ix.header.count);
        var count: u32 = 0;
        for (0..ix.header.count) |i| {
            const id: u32 = @intCast(i);
            const e = ix.entry(id);
            if (!has_path(e)) continue;
            items[count] = .{ .id = id, .key = path_key(e.path) };
            count += 1;
        }
        assert(count <= ix.header.count);
        const sorted = items[0..count];
        std.mem.sort(Item, sorted, {}, by_key);
        assert(std.sort.isSorted(Item, sorted, {}, by_key));
        return .{ .ix = ix, .sorted = sorted };
    }

    /// The last build's record of the book at `path`, if it had one.
    fn find(read: *const LastBuild, path: []const u8) ?u32 {
        assert(path.len > 0);
        assert(read.sorted.len <= read.ix.header.count);
        const key = path_key(path);
        for (read.sorted[first_with(read.sorted, key)..]) |item| {
            if (item.key != key) return null;
            if (std.mem.eql(u8, read.ix.entry(item.id).path, path)) return item.id;
        }
        return null;
    }

    /// What record `id` read of its EPUB, if the file is as it was then, and its series
    /// is the book's own, not one set by hand.
    fn about_if(read: *const LastBuild, id: u32, facts: calls.Facts) ?About {
        assert(id < read.ix.header.count);
        const r = read.ix.record(id);
        if (r.flags & index.Record.epub == 0) return null; // Not an EPUB then
        if (r.file_size != facts.size or r.file_modified != facts.modified_s) return null;
        if (r.flags & index.Record.series_by_hand != 0) return null;
        const e = read.ix.entry(id);
        return .{
            .title = e.title,
            .author = e.author,
            .series = e.series,
            .has_cover = e.thumbnail != null,
        };
    }

    /// What record `id` kept of its book's reading.
    fn reading(read: *const LastBuild, id: u32) Kept {
        assert(id < read.ix.header.count);
        const e = read.ix.entry(id);
        assert(e.percent <= 100); // The record's, checked as the index opened
        return .{ .progress = .of(e), .kindle_last = e.kindle_last };
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

/// Whether book `e` has a path to be found by: a book in the cloud has none.
fn has_path(e: catalog.Entry) bool {
    return e.path.len > 0;
}

/// The books on this Kindle, their ids sorted by `key_of` their path (a key's high half),
/// to find each by halves: by the names their files have now, or had before.
fn sorted_by(ix: *const index.Index, items: []Item, comptime key_of: fn ([]const u8) u64) []Item {
    assert(items.len >= ix.header.count);
    var count: u32 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const e = ix.entry(id);
        if (!e.is_local() or !has_path(e)) continue;
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

/// What noface keeps of each book, from one walk of the data folder a load: each place
/// is merged into its book's record as it's found, only the books with a state file
/// read and nothing kept of them, so the memory is the books', however many files there
/// are; and the files an older noface named by a book's file name (`state.key_by_name`)
/// are noted, to go to the names its whole path gives (`state.key_for`) once the walk
/// is over (`rename_key`). Every load looks, so a move cut short goes on at the next.
/// `complete` is whether the index holds every book on the Kindle.
pub fn sync_states(
    ix: *const index.Index,
    items: []Item,
    places: Places,
    scratch: *memory.Budget,
    complete: bool,
) !void {
    assert(places.state_dir.len > 0);
    assert(items.len >= ix.header.count); // Room to sort every book
    var walk: Walk = .{
        .merge = .{ .ix = ix, .sorted = by_state_key(ix, items), .state_dir = places.state_dir },
        .named = try name_keys(scratch.allocator(), ix),
        .alloc = scratch.allocator(),
        .heartbeat = places.heartbeat,
        .beat_us = os.now_us(),
    };
    var folder_buffer: [files.path_bytes_max]u8 = undefined;
    const state_dir = places.state_dir;
    const folder = try std.fmt.bufPrintSentinel(&folder_buffer, "{s}", .{state_dir}, 0);
    // What's listed is merged and moved; a book missed is, at the next load
    const whole = calls.each_entry(folder.ptr, &walk, Walk.entry);
    if (walk.failed) return error.OutOfMemory;
    // Each key once, whichever of its kinds were listed
    std.mem.sort(u64, walk.old.items, {}, std.sort.asc(u64));
    const keys = unique(walk.old.items);
    // The merge's order no longer needed: a place copied now is merged by its book
    const by_name = sorted_by_name(ix, items);
    walk.merge.sorted = &.{};
    var first_error: ?anyerror = null;
    for (keys) |key| {
        if (places.heartbeat) |path| heartbeat.beat_when_due(path, &walk.beat_us);
        // One key's files failing to move leaves the others to move
        rename_key(ix, state_dir, key, by_name, complete, &walk.merge) catch |err| {
            log("library: files of {x:0>16} not moved ({s})\n", .{ key, @errorName(err) });
            if (first_error == null) first_error = err;
        };
    }
    if (walk.merge_failed) return error.CantMerge;
    if (first_error) |err| return err;
    if (!whole) return error.CantList;
}

/// The data folder walked once: each place merged, each file named by a book's file
/// name noted.
const Walk = struct {
    merge: Merge,
    named: []const u64, // Every book's file-name key, sorted
    alloc: std.mem.Allocator,
    old: std.ArrayList(u64) = .empty,
    heartbeat: ?[*:0]const u8, // As `Places.heartbeat`: thousands of files are slow
    beat_us: u64, // When it last beat, or started
    failed: bool = false, // Out of memory: what was noted isn't all
    merge_failed: bool = false,

    fn entry(w: *Walk, name: []const u8, is_dir: bool) void {
        assert(name.len > 0);
        if (w.heartbeat) |path| heartbeat.beat_when_due(path, &w.beat_us);
        if (is_dir or w.failed) return;
        for (std.enums.values(state.Kind)) |kind| {
            const key = state.key_of_name(name, kind) orelse continue;
            if (kind == .state) {
                w.merge.merge_key(key) catch {
                    w.merge_failed = true;
                };
            }
            if (std.sort.binarySearch(u64, w.named, key, order_u64) != null) {
                const before = w.old.items.len;
                w.old.append(w.alloc, key) catch {
                    w.failed = true;
                    return;
                };
                assert(w.old.items.len == before + 1);
            }
            return;
        }
    }
};

fn order_u64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

/// Every book's file-name key (`state.key_by_name`), sorted, each once: of a book on
/// the Kindle or downloading, which has a path.
fn name_keys(alloc: std.mem.Allocator, ix: *const index.Index) ![]const u64 {
    assert(ix.header.count <= index.books_max);
    var keys: std.ArrayList(u64) = .empty;
    for (0..ix.header.count) |i| {
        const e = ix.entry(@intCast(i));
        if (e.path.len == 0) continue;
        try keys.append(alloc, state.key_by_name(e.path));
    }
    std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));
    const once = unique(keys.items);
    assert(once.len <= ix.header.count);
    return once;
}

/// The books with a path, on the Kindle or downloading, their ids sorted by their
/// file-name key's high half, at `items`' start.
fn sorted_by_name(ix: *const index.Index, items: []Item) []Item {
    assert(items.len >= ix.header.count);
    var count: u32 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const e = ix.entry(id);
        if (!has_path(e)) continue;
        items[count] = .{ .id = id, .key = @truncate(state.key_by_name(e.path) >> 32) };
        count += 1;
    }
    const sorted = items[0..count];
    std.mem.sort(Item, sorted, {}, by_key);
    assert(count <= ix.header.count);
    return sorted;
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

/// The files named by file-name key `key` given to the books of that name: each on the
/// Kindle gets a copy of each kind, never over one it has, its place merged; a cover or
/// page breaks, made again anyway, just go. The old files go once every book of that
/// name is here, from an index that's `complete`: till then, one downloading or not yet
/// listed finds them. Its place last, so while it's there, so is the key.
fn rename_key(
    ix: *const index.Index,
    state_dir: []const u8,
    key: u64,
    by_name: []const Item,
    complete: bool,
    merge: *Merge,
) !void {
    const high: u32 = @truncate(key >> 32);
    var twins: u32 = 0;
    var here: u32 = 0;
    for (by_name[first_with(by_name, high)..]) |item| {
        if (item.key != high) break;
        const e = ix.entry(item.id);
        if (state.key_by_name(e.path) != key) continue; // Same high half, another name
        twins += 1;
        if (e.is_local()) here += 1;
    }
    assert(here <= twins);
    if (here == 0) return; // None of its books here: kept till one is
    const done = complete and here == twins;
    // In `state.Kind`'s order: remade ones, then the notes, then the place
    for (std.enums.values(state.Kind)) |kind| {
        var from_buffer: [files.path_bytes_max]u8 = undefined;
        const from = try state.file_path(&from_buffer, state_dir, kind, key);
        switch (file.presence(from)) {
            .absent => {},
            .unknown => return error.CantRead, // Tried again at the next load
            .here => {
                const remade = kind.remade();
                if (!remade) try copy_to_twins(ix, state_dir, kind, from, key, by_name, merge);
                if (remade or done) {
                    if (os.failed(calls.unlink(from))) return error.CantRemove;
                }
            },
        }
    }
}

/// `from` (of `kind`, named by file-name key `key`) copied to each book of that name on
/// the Kindle that hasn't one, a place merged into the book's record as it lands.
fn copy_to_twins(
    ix: *const index.Index,
    state_dir: []const u8,
    kind: state.Kind,
    from: [:0]const u8,
    key: u64,
    by_name: []const Item,
    merge: *Merge,
) !void {
    assert(state_dir.len > 0);
    assert(by_name.len <= ix.header.count);
    const high: u32 = @truncate(key >> 32);
    for (by_name[first_with(by_name, high)..]) |item| {
        if (item.key != high) break;
        const e = ix.entry(item.id);
        if (state.key_by_name(e.path) != key or !e.is_local()) continue;
        var state_buffer: [files.path_bytes_max]u8 = undefined;
        const own_state = try state.path_for(&state_buffer, state_dir, e.path);
        var to_buffer: [files.path_bytes_max]u8 = undefined;
        const to = try state.sibling(&to_buffer, own_state, kind);
        assert(!std.mem.eql(u8, from, to)); // A whole path's name is never a file name's
        switch (file.presence(to)) {
            .here => continue, // Saved under its new name already: newer
            .unknown => return error.CantRead, // Maybe there: never written over
            .absent => {},
        }
        if (!file.copy_file(from, to)) return error.CantCopy;
        // Merged now: the walk listed the folder before it was there
        if (kind == .state) try merge.merge_at(item.id, to);
    }
}

const Merge = struct {
    ix: *const index.Index,
    sorted: []const Item,
    state_dir: []const u8,

    fn merge_key(m: *Merge, key: u64) !void {
        assert(m.state_dir.len > 0);
        var path_buffer: [files.path_bytes_max]u8 = undefined;
        const path = try state.file_path(&path_buffer, m.state_dir, .state, key);
        // Read only for a book here: the drive is slow, and a file may be a deleted book's
        const high: u32 = @truncate(key >> 32);
        // Books whose keys share a high half: only the one with the whole key is merged
        for (m.sorted[first_with(m.sorted, high)..]) |item| {
            if (item.key != high) return;
            if (state.key_for(m.ix.entry(item.id).path) != key) continue; // Same high half
            try m.merge_at(item.id, path);
        }
    }

    /// The place at `path` merged into book `id`'s record. One there but unreadable is
    /// left out: merged as a fresh place, the record would show the book unread.
    fn merge_at(m: *Merge, id: u32, path: [:0]const u8) !void {
        assert(id < m.ix.header.count);
        assert(path.len > 0);
        var kept = file.Kept.at(path);
        const saved = state.load(&kept);
        if (kept.known) try m.write_merged(id, saved);
    }

    fn write_merged(m: *Merge, id: u32, saved: state.State) !void {
        assert(id < m.ix.header.count);
        var r = m.ix.record(id);
        const before = r;
        merged(&r, saved);
        if (!std.meta.eql(before, r)) try m.ix.write_record(id, &r);
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
    // Read on another device since the stock reader here: as far in as its place is
    if (outside_percent(r, saved)) |percent| {
        r.percent = percent;
        r.last = r.outside_last;
    }
    if (state.prefer_outside(saved, r.last)) {
        // The place is the stock reader's, so what noface counted from its own is old
        r.set_words_left(null);
        return;
    }
    if (saved.percent) |p| r.percent = @intCast(@min(p, 100));
    r.last = @max(r.last, saved.opened);
    assert(r.percent <= 100);
}

/// How far in the device's latest place from any device is, when it's later than the
/// stock reader's own and noface saved where the book ends in the device's numbering.
fn outside_percent(r: *const index.Record, saved: state.State) ?u8 {
    assert(r.flags & index.Record.epub == 0); // A Kindle book's
    if (r.outside_last <= r.kindle_last) return null; // The stock reader's is as new
    const end = saved.outside_end orelse return null;
    if (end == 0) return null; // A book of one place: nothing to say how far
    const percent = @min(@as(u64, r.outside_short) * 100 / end, 100);
    assert(percent <= 100);
    return @intCast(percent);
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

test "a place read on another device since shows how far in it is, by the book's end noface saved" {
    const book: catalog.Entry = .{
        .path = "/mnt/us/documents/Dune.kfx",
        .title = "Dune",
        .author = "",
        .percent = 10,
        .last = 0,
        .kindle_percent = 10,
        .kindle_last = 1_700_000_000,
        .outside = .{ .short = 6000, .last = 1_900_000_000 },
    };
    const saved: state.State = .{
        .para = 4,
        .percent = 40,
        .opened = 1_800_000_000,
        .words_left = 9000,
        .outside_end = 10_000,
    };
    // The phone read it last: its place, 60% in, and no words left from noface's
    var r = index.record_of(&book, 0, 0);
    merged(&r, saved);
    try std.testing.expectEqual(@as(u8, 60), r.percent);
    try std.testing.expectEqual(@as(u64, 1_900_000_000), r.last);
    try std.testing.expect(r.flags & index.Record.words_known == 0);
    // Without the book's end there's no saying how far: the stock reader's or noface's
    var no_end = saved;
    no_end.outside_end = null;
    r = index.record_of(&book, 0, 0);
    merged(&r, no_end);
    try std.testing.expectEqual(@as(u8, 40), r.percent);
    // The place noface kept outside, with its own save's time, is noface's
    var kept = book;
    kept.outside = .{ .short = 6000, .last = 1_800_000_000 };
    r = index.record_of(&kept, 0, 0);
    merged(&r, saved);
    try std.testing.expectEqual(@as(u8, 40), r.percent);
    try std.testing.expect(r.flags & index.Record.words_known != 0);
}
