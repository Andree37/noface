//! The books in the library: the Kindle's own, listed by its catalog, and EPUBs
//! copied over the cable, found here.
//!
//! The library's memory grows with how many books there are, never with how large
//! they are: each EPUB is read in a scratch region emptied after it, and only what the
//! list shows (its title, author, series and paths, each cut to a bound) is kept.
const std = @import("std");
const assert = std.debug.assert;
const memory = @import("../base/memory.zig");
const library_files = @import("../library/files.zig");
const dir = @import("../sys/dir.zig");
const epub = @import("../epub/epub.zig");
const catalog = @import("../model/catalog.zig");
const file = @import("../sys/file.zig");
const kfx = @import("../kindle/kfx.zig");
const state = @import("../sys/state.zig");
const calls = @import("../sys/calls.zig");
const epub_cache = @import("../library/epub_cache.zig");
const paths = @import("../kindle/paths.zig");
const catalog_db = @import("../kindle/catalog.zig");
const app = @import("../app.zig");
const series_screen = @import("series.zig");

/// The most books the library lists: the Kindle's catalog rows first, then EPUBs. Past
/// it, the first that fit are listed and the log says how many were left out.
pub const books_max: u32 = 5000;

/// The longest title, author or series an EPUB's entry keeps: past it, cut at a whole
/// character. A path is any Linux can open: shorter than `path_size_max`.
const text_bytes_max: u32 = 256;
const path_size_max: u32 = library_files.path_bytes_max;
/// What a book's path and its cover's take for the list's room: their usual length,
/// with plenty to spare. Longer ones take more, and a list that runs out says so.
const path_bytes_typical: u32 = 320;

/// The library memory one book takes, its paths at their usual length: its entry, its
/// place in the visible list, its path and its cover's, and its title, author and
/// series. The catalog is read and each EPUB opened in the scratch region; only these
/// are copied into the list.
pub const book_bytes_max: u32 = @sizeOf(catalog.Entry) + @sizeOf(u32) +
    2 * (path_bytes_typical + 1) + 3 * text_bytes_max;

/// What one list takes at most, in whole units: its books, the series set by hand
/// (from a file of 64 KB at most) and the arena's own bookkeeping.
pub const list_bytes_max: u32 =
    std.mem.alignForward(u32, books_max * book_bytes_max + list_slack, memory.unit_bytes);
const list_slack: u32 = 1 << 20;

/// How many times a catalog too large for the scratch region is read again, with half
/// the rows each time, before the library lists only EPUBs.
const catalog_attempts_max: u32 = 16;

comptime {
    assert(book_bytes_max <= 2 << 10); // An entry and its text, not a book's files
    assert(list_bytes_max <= 16 << 20);
    assert(books_max >> catalog_attempts_max == 0); // Halving reaches no rows at all
}

pub const Library = struct {
    arena: std.heap.ArenaAllocator, // On the library's budget, in its region
    data: []const u8,
    entries: []catalog.Entry,
    /// Indexes into `entries`, one place for each, for `catalog.select` to fill.
    visible: []u32,
    /// The Kindle's catalog as it was when this list was read, to tell when it changed.
    catalog_seen: CatalogFacts = .{},

    pub fn deinit(l: *Library) void {
        assert(l.visible.len == l.entries.len);
        l.arena.deinit();
        file.unmap(l.data);
    }

    pub fn downloading_count(l: *const Library) u32 {
        assert(l.visible.len == l.entries.len);
        var count: u32 = 0;
        for (l.entries) |e| {
            if (e.availability == .downloading) count += 1;
        }
        assert(count <= l.entries.len);
        return count;
    }

    pub fn local_count(l: *const Library) u32 {
        assert(l.visible.len == l.entries.len);
        var count: u32 = 0;
        for (l.entries) |e| {
            if (e.is_local()) count += 1;
        }
        assert(count <= l.entries.len);
        return count;
    }
};

/// Where a library is read from, and the memory it's read into.
pub const Sources = struct {
    budget: *memory.Budget, // The list's: outlives it, and holds two during a reload
    scratch: *memory.Region, // Bump: the catalog and each EPUB as they're read
    catalog_path: [*:0]const u8, // The Kindle's catalog, exported
    documents: []const u8, // Where EPUBs are found
    state_dir: []const u8, // Each book's place and cover
};

pub fn load_library(a: *app.App) !Library {
    assert(a.library_budget.limit > 0);
    assert(a.library_scratch_region.kind == .bump);
    return load(.{
        .budget = a.library_budget,
        .scratch = a.library_scratch_region,
        .catalog_path = a.library_path,
        .documents = a.documents,
        .state_dir = a.state_dir,
    });
}

/// What tells that the Kindle's catalog changed without reading it: the size and change
/// time of its database and of the log its changes go to first.
pub const CatalogFacts = struct {
    database: ?calls.Facts = null,
    log: ?calls.Facts = null,

    pub fn read() CatalogFacts {
        const read_now: CatalogFacts = .{
            .database = file.facts_of(paths.catalog),
            .log = file.facts_of(paths.catalog ++ "-wal"),
        };
        comptime assert(paths.catalog[0] == '/');
        return read_now;
    }
};

/// What a download being watched is up to.
pub const Download = enum {
    /// Its file is still partial, or the catalog hasn't changed since the list was read.
    waiting,
    /// Its file is whole: read the library again to list it.
    arrived,
    /// The catalog changed, and the list says of no book that it's coming: read it
    /// again to learn which, if any.
    catalog_changed,
};

/// Whether a download watched has arrived, looking only at what's downloading: the
/// files the list says are coming, or, when it names none yet (the catalog may not
/// have marked it when the list was read), whether the catalog has changed at all. The
/// whole catalog is exported and read again only once either says so.
pub fn watch_download(l: *const Library) Download {
    assert(l.visible.len == l.entries.len);
    var coming: u32 = 0;
    for (l.entries) |e| {
        if (e.availability != .downloading or e.path.len == 0) continue;
        coming += 1;
        if (is_complete_book(e.path)) return .arrived;
    }
    if (coming > 0) return .waiting;
    const now = CatalogFacts.read();
    if (std.meta.eql(now, l.catalog_seen)) return .waiting;
    assert(coming == 0);
    return .catalog_changed;
}

/// Whether two lists have the same books on the Kindle and the same coming down, so
/// one can stand for the other on screen.
pub fn same_shelf(a: *const Library, b: *const Library) bool {
    assert(a.visible.len == a.entries.len);
    assert(b.visible.len == b.entries.len);
    if (a.local_count() != b.local_count()) return false;
    return a.downloading_count() == b.downloading_count();
}

pub fn load(s: Sources) !Library {
    assert(s.scratch.empty());
    assert(s.state_dir.len > 0);
    // Before the list is read, so a change made while it's read shows next time
    const catalog_seen = CatalogFacts.read();
    var arena = std.heap.ArenaAllocator.init(s.budget.allocator());
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const data = try file.map(s.catalog_path);
    errdefer file.unmap(data);
    var scratch = memory.Budget{
        .name = "library scratch",
        .region = s.scratch,
        .limit = s.scratch.bytes.len,
    };
    defer scratch.reset(.give_back);
    const rows = kindle_books(&scratch, data);
    const saved = list_saved(scratch.allocator(), s.state_dir);
    var folder_buffer: [path_size_max]u8 = undefined;
    const folder = try index_folder(&folder_buffer, s.state_dir);
    const cache_memory = try epub_cache_memory(scratch.allocator());
    var cache = epub_cache.Cache.open(&cache_memory, folder);
    // A folder that can't be read has no EPUBs to list
    const none: []const [:0]u8 = &.{};
    const found = dir.find_files(scratch.allocator(), s.documents, ".epub") catch none;
    // Room for every book that can be listed, so none is moved as the list grows
    const room: u32 = books_max - @as(u32, @intCast(rows.len));
    const capacity = rows.len + @min(found.len, room);
    var list = try std.ArrayList(catalog.Entry).initCapacity(alloc, capacity);
    const visible = try alloc.alloc(u32, capacity);
    for (rows, 0..) |row, i| {
        // An error is the list's memory running out: it keeps the books that fit
        var e = keep_kindle_book(alloc, row) catch {
            log("library: no room for {d} of the Kindle's books\n", .{rows.len - i});
            break;
        };
        place_kindle_book(s, &saved, &e);
        list.appendAssumeCapacity(e);
    }
    const kindle = list.items.len;
    add_epubs(s, .{ .saved = &saved, .cache = &cache }, alloc, &scratch, found, &list);
    cache.finish();
    assert(list.items.len >= kindle);
    assert(list.items.len <= books_max);
    series_screen.apply(alloc, s.state_dir, list.items); // Series set by hand win
    // Allocated before the arena is copied into the result: a block it adds after
    // would be known only to this copy, and never freed
    const count = list.items.len;
    return .{
        .arena = arena,
        .data = data,
        .entries = list.items,
        .visible = visible[0..count],
        .catalog_seen = catalog_seen,
    };
}

/// The Kindle's books, as its catalog's first `books_max` rows say, read in `scratch`.
/// A catalog whose rows hold more than `scratch` has room for is read again with half
/// the rows. Their text points into `data`, and into `scratch`.
fn kindle_books(scratch: *memory.Budget, data: []const u8) []catalog.Entry {
    var rows = books_max;
    if (rows_end(data, rows) < data.len) {
        log("library: only the Kindle's first {d} books are listed\n", .{rows});
    }
    const start = scratch.mark();
    for (0..catalog_attempts_max) |_| {
        if (catalog_db.parse(scratch.allocator(), data[0..rows_end(data, rows)])) |entries| {
            assert(entries.len <= rows);
            return entries;
        } else |_| {
            // No room, the one error: drop what was read, and try fewer rows
            scratch.rewind(start);
            rows /= 2;
            log("library: no room for the catalog, trying {d} rows\n", .{rows});
        }
    }
    assert(rows == 0);
    return &.{};
}

/// Where `data`'s first `rows` lines end: past the last one's line break.
fn rows_end(data: []const u8, rows: u32) u32 {
    assert(data.len <= std.math.maxInt(u32));
    assert(rows <= books_max);
    var end: u32 = 0;
    for (0..rows) |_| {
        const line_break = std.mem.indexOfScalarPos(u8, data, end, '\n') orelse
            return @intCast(data.len);
        end = @intCast(line_break + 1);
    }
    assert(end <= data.len);
    return end;
}

/// A Kindle book's entry as the list keeps it: its path, title and cover's path copied
/// into `alloc`. A path is any length the catalog gives: one longer than Linux allows
/// won't open, but the book is still listed.
fn keep_kindle_book(alloc: std.mem.Allocator, row: catalog.Entry) !catalog.Entry {
    assert(row.path.len <= std.math.maxInt(u32));
    var e = row;
    e.path = try alloc.dupeSentinel(u8, row.path, 0);
    e.title = try alloc.dupe(u8, clip(row.title));
    e.thumbnail = try alloc.dupeSentinel(u8, row.thumbnail, 0);
    // A series from the file's name points into it: into the kept copy now
    const series = catalog.series_from_file_name(e.path);
    if (series) |place| e.series = place.name;
    if (series == null) assert(row.series.len == 0);
    assert(e.path.len == row.path.len);
    return e;
}

/// A Kindle book's place: the Kindle's, or noface's when noface read it last.
fn place_kindle_book(s: Sources, listed: *const Saved, e: *catalog.Entry) void {
    assert(s.state_dir.len > 0);
    if (e.availability == .downloading and is_complete_book(e.path)) e.availability = .local;
    if (!e.is_local()) return;
    assert(e.path.len > 0); // The catalog gives every local book its file
    // Most Kindle books were never opened here: no file, and no need to try opening it
    if (!Saved.has(listed.states, state.key_for(e.path))) return;
    var path_buffer: [path_size_max]u8 = undefined;
    const state_path = state.path_for(&path_buffer, s.state_dir, e.path) catch return;
    const saved = state.load(state_path);
    e.seconds_read = saved.seconds;
    if (state.prefer_kindle(saved, e.kindle_last)) return;
    if (saved.percent) |p| e.percent = @min(p, 100);
    e.last = @max(e.last, saved.opened);
}

/// EPUBs copied over the cable. The Kindle's catalog doesn't list them, so noface finds
/// them itself, reading title and author from each book, and its cover once into a file
/// beside the book's state. Each is read in `scratch`, emptied after it.
fn add_epubs(
    s: Sources,
    known: Known,
    alloc: std.mem.Allocator,
    scratch: *memory.Budget,
    found: []const [:0]u8,
    list: *std.ArrayList(catalog.Entry),
) void {
    assert(list.items.len <= books_max);
    // The catalog lists no EPUB (`catalog_db.parse` leaves them out), so no book found
    // here is listed twice
    for (list.items) |e| assert(!e.is_epub());
    const each_book = scratch.mark(); // The catalog and the folder's list stay
    var left_out: u32 = 0;
    for (found) |path| {
        assert(std.ascii.endsWithIgnoreCase(path, ".epub"));
        if (list.items.len == list.capacity) {
            left_out += 1;
            continue;
        }
        scratch.rewind(each_book);
        // An error is the list's memory running out: it keeps the books that fit
        const entry = read_epub(s, known, alloc, scratch, path) catch {
            left_out += 1;
            continue;
        } orelse continue;
        list.appendAssumeCapacity(entry);
        // Found on the Kindle, so it opens as an EPUB
        assert(list.items[list.items.len - 1].is_epub());
        assert(list.items[list.items.len - 1].is_local());
    }
    if (left_out > 0) {
        log("library: {d} EPUBs left out, past {d} books\n", .{ left_out, books_max });
    }
    assert(list.items.len <= list.capacity);
}

/// A line for the log, but not from the tests, where it would read as a failure.
fn log(comptime format: []const u8, args: anytype) void {
    assert(format.len > 0);
    assert(format[format.len - 1] == '\n');
    if (!@import("builtin").is_test) std.debug.print(format, args);
}

/// An EPUB's entry, its text kept in `alloc`, the book read in `scratch`. Null for a
/// book that won't read; an error only when `alloc` has no room.
fn read_epub(
    s: Sources,
    known: Known,
    alloc: std.mem.Allocator,
    scratch: *memory.Budget,
    path: [:0]const u8,
) !?catalog.Entry {
    assert(path.len > 0);
    assert(path.len < path_size_max); // The folder's walk finds none longer than Linux opens
    const facts = file.facts_of(path) orelse return null;
    var path_buffer: [path_size_max]u8 = undefined;
    var cover_buffer: [path_size_max]u8 = undefined;
    const state_path = state.path_for(&path_buffer, s.state_dir, path) catch return null;
    const cover_path = state.sibling(&cover_buffer, state_path, "cover") catch return null;
    const key = state.key_for(path);
    const have_cover = Saved.has(known.saved.covers, key);
    const saved_state = if (Saved.has(known.saved.states, key))
        state.load(state_path)
    else
        state.State{};
    // Read before, and unchanged since: what was kept of it, without opening it. Read
    // again only to save its cover, should that file have gone
    if (known.cache.find(path, facts)) |kept| {
        if (have_cover or !kept.has_cover) {
            known.cache.add(path, facts, kept);
            const about: epub.Info = .{
                .title = kept.title,
                .author = kept.author,
                .series = kept.series,
                .series_index = kept.series_index,
            };
            const thumbnail = if (have_cover) cover_path else "";
            return try keep_epub(alloc, path, about, saved_state, thumbnail);
        }
    }
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    const about = read_about(scratch, data, !have_cover) orelse return null;
    if (about.cover) |bytes| state.write_small(cover_path, bytes);
    const has_cover = have_cover or about.cover != null;
    if (about.cover != null) assert(!have_cover); // Read only for a book without one
    known.cache.add(path, facts, .{
        .title = about.title,
        .author = about.author,
        .series = about.series,
        .series_index = about.series_index,
        .has_cover = has_cover,
    });
    const thumbnail = if (has_cover) cover_path else "";
    return try keep_epub(alloc, path, about, saved_state, thumbnail);
}

/// What's known of the books before any is opened: the files noface keeps for them,
/// and what each EPUB said when last read.
const Known = struct { saved: *const Saved, cache: *epub_cache.Cache };

/// The folder in the data folder the library keeps its own files in, made if missing.
fn index_folder(buffer: []u8, state_dir: []const u8) ![]const u8 {
    assert(state_dir.len > 0);
    const folder = try std.fmt.bufPrintSentinel(buffer, "{s}/library", .{state_dir}, 0);
    _ = calls.mkdir(folder, 0o755); // Ignored: there already, or the cache can't be kept
    assert(std.mem.endsWith(u8, folder, "/library"));
    return folder;
}

/// The EPUB cache's buffers, in `alloc`: about 2 MB.
fn epub_cache_memory(alloc: std.mem.Allocator) !epub_cache.Memory {
    const inputs = try alloc.alloc([]u8, 4);
    for (inputs) |*input| input.* = try alloc.alloc(u8, 64 << 10);
    const result: epub_cache.Memory = .{
        .sort = .{
            .items = try alloc.alloc(u8, 1 << 20),
            .offsets = try alloc.alloc(u32, 32 << 10),
            .inputs = inputs,
            .output = try alloc.alloc(u8, 64 << 10),
        },
        .lines_out = try alloc.alloc(u8, 64 << 10),
        .index_in = try alloc.alloc(u8, 4 << 10),
        .lines_in = try alloc.alloc(u8, epub_cache.line_bytes_max),
    };
    result.invariants();
    assert(result.sort.inputs.len == 4);
    return result;
}

/// The books noface keeps files for in the data folder, read from one listing of it, so
/// a book with none (most of a Kindle's) costs no open() on the slow user drive. Each
/// list is the books' keys (`state.key_for`), sorted.
const Saved = struct {
    states: []u64 = &.{},
    covers: []u64 = &.{},

    fn has(keys: []const u64, key: u64) bool {
        const found = std.sort.binarySearch(u64, keys, key, Saved.order) != null;
        if (keys.len == 0) assert(!found);
        if (found) assert(keys.len > 0);
        return found;
    }

    fn order(key: u64, item: u64) std.math.Order {
        return std.math.order(key, item);
    }
};

/// The state and cover files in `state_dir`, in `alloc`. A folder that can't be read,
/// or no room to list it, is as if it held none: every book is then new.
fn list_saved(alloc: std.mem.Allocator, state_dir: []const u8) Saved {
    assert(state_dir.len > 0);
    var path_buffer: [path_size_max]u8 = undefined;
    const folder = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{state_dir}, 0) catch
        return .{};
    var listing = SavedListing{ .alloc = alloc };
    calls.each_entry(folder.ptr, &listing, SavedListing.add);
    if (listing.failed) return .{};
    std.mem.sort(u64, listing.states.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, listing.covers.items, {}, std.sort.asc(u64));
    const result: Saved = .{ .states = listing.states.items, .covers = listing.covers.items };
    assert(std.sort.isSorted(u64, result.states, {}, std.sort.asc(u64)));
    assert(std.sort.isSorted(u64, result.covers, {}, std.sort.asc(u64)));
    return result;
}

const SavedListing = struct {
    alloc: std.mem.Allocator,
    states: std.ArrayList(u64) = .empty,
    covers: std.ArrayList(u64) = .empty,
    failed: bool = false,

    fn add(listing: *SavedListing, name: []const u8, is_dir: bool) void {
        assert(name.len > 0);
        if (is_dir) return;
        const list = if (std.mem.startsWith(u8, name, "state-"))
            &listing.states
        else if (std.mem.startsWith(u8, name, "cover-")) &listing.covers else return;
        const key = state.key_of_name(name, name[0.."state".len]) orelse return;
        list.append(listing.alloc, key) catch {
            listing.failed = true;
            return;
        };
        assert(list.items[list.items.len - 1] == key);
    }
};

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

/// The entry kept for an EPUB: copies in `alloc` of its path and cover's path, and of
/// its title, author and series cut to `text_bytes_max`.
fn keep_epub(
    alloc: std.mem.Allocator,
    path: []const u8,
    about: epub.Info,
    saved: state.State,
    cover_path: []const u8,
) !catalog.Entry {
    assert(path.len < path_size_max);
    assert(cover_path.len < path_size_max);
    const kept_path = try alloc.dupeSentinel(u8, path, 0);
    // The book's own metadata first, else its file name, as for Kindle books
    const from_file_name = catalog.series_from_file_name(kept_path);
    const from_book = about.series.len > 0;
    const index_from_file_name = if (from_file_name) |f| f.index else 0;
    const title = if (about.title.len > 0)
        try alloc.dupe(u8, clip(about.title))
    else
        std.fs.path.stem(kept_path);
    return .{
        .path = kept_path,
        .title = title,
        .author = try alloc.dupe(u8, clip(about.author)),
        .percent = @min(saved.percent orelse 0, 100),
        .finished = saved.finished,
        .last = saved.opened,
        .seconds_read = saved.seconds,
        .thumbnail = if (cover_path.len > 0) try alloc.dupeSentinel(u8, cover_path, 0) else "",
        .kind = "EPUB",
        .series = if (from_book)
            try alloc.dupe(u8, clip(about.series))
        else if (from_file_name) |f| f.name else "",
        .series_index = if (from_book) about.series_index else index_from_file_name,
    };
}

/// `text` cut to `text_bytes_max` bytes, at a whole UTF-8 character.
fn clip(text: []const u8) []const u8 {
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

/// The catalog's downloading flag can stay set long after a download ended, so
/// the file decides: a partial book points past its own end.
pub fn is_complete_book(path: [:0]const u8) bool {
    if (path.len == 0) return false;
    const data = file.map(path) catch return false;
    defer file.unmap(data);
    return kfx.is_complete(data);
}

/// An EPUB titled `title` with a cover of `cover_bytes`, its files stored as they are.
fn test_epub(alloc: std.mem.Allocator, title: []const u8, cover_bytes: u32) ![]u8 {
    assert(title.len > 0);
    assert(cover_bytes > 0);
    const opf = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        \\<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{s}</dc:title>
        \\<dc:creator>Test Author</dc:creator></metadata><manifest>
        \\<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
        \\<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
        \\</manifest><spine><itemref idref="c1"/></spine></package>
    , .{title});
    defer alloc.free(opf);
    const cover = try alloc.alloc(u8, cover_bytes);
    defer alloc.free(cover);
    @memset(cover, 0x5a);
    const container = "<?xml version=\"1.0\"?><container version=\"1.0\" " ++
        "xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles>" ++
        "<rootfile full-path=\"OEBPS/content.opf\"/></rootfiles></container>";
    const files = [_][2][]const u8{
        .{ "mimetype", "application/epub+zip" },
        .{ "META-INF/container.xml", container },
        .{ "OEBPS/content.opf", opf },
        .{ "OEBPS/c1.xhtml", "<html><body><p>Text.</p></body></html>" },
        .{ "OEBPS/cover.jpg", cover },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var offsets: [files.len]u32 = undefined;
    for (files, &offsets) |f, *offset| {
        offset.* = @intCast(out.items.len);
        try test_zip_header(alloc, &out, "PK\x03\x04", f, null);
        try out.appendSlice(alloc, f[1]);
    }
    const directory: u32 = @intCast(out.items.len);
    for (files, offsets) |f, offset| try test_zip_header(alloc, &out, "PK\x01\x02", f, offset);
    var end: [22]u8 = @splat(0);
    end[0..4].* = "PK\x05\x06".*;
    std.mem.writeInt(u16, end[8..10], files.len, .little);
    std.mem.writeInt(u16, end[10..12], files.len, .little);
    std.mem.writeInt(u32, end[12..16], @as(u32, @intCast(out.items.len)) - directory, .little);
    std.mem.writeInt(u32, end[16..20], directory, .little);
    try out.appendSlice(alloc, &end);
    return out.toOwnedSlice(alloc);
}

/// A zip file's local header (`offset` null) or its central directory record.
fn test_zip_header(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    signature: *const [4]u8,
    f: [2][]const u8,
    offset: ?u32,
) !void {
    assert(f[0].len > 0);
    assert(signature[0] == 'P');
    const size: u32 = @intCast(f[1].len);
    var header: [46]u8 = @splat(0);
    header[0..4].* = signature.*;
    // From the version needed (or made by) on, the central record is two bytes on
    const at: u32 = if (offset == null) 4 else 6;
    std.mem.writeInt(u16, header[at..][0..2], 20, .little); // Version needed
    std.mem.writeInt(u32, header[at + 14 ..][0..4], size, .little); // Stored as it is
    std.mem.writeInt(u32, header[at + 18 ..][0..4], size, .little);
    std.mem.writeInt(u16, header[at + 22 ..][0..2], @intCast(f[0].len), .little);
    if (offset) |o| std.mem.writeInt(u32, header[42..46], o, .little);
    try out.appendSlice(alloc, header[0..if (offset == null) 30 else 46]);
    try out.appendSlice(alloc, f[0]);
}

fn test_write(path: [*:0]const u8, data: []const u8) !void {
    assert(data.len > 0);
    const linux = @import("../sys/calls.zig");
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (@import("../sys/os.zig").failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.CantWrite;
}

/// A test library's folder in /tmp: its catalog with `kindle_rows` Kindle books, and
/// `epubs` EPUBs with covers of `cover_bytes`. Removed by `test_folder_remove`.
fn test_folder(buffer: []u8, kindle_rows: u32, epubs: u32, cover_bytes: u32) ![:0]const u8 {
    assert(buffer.len >= 64);
    const linux = @import("../sys/calls.zig");
    const alloc = std.testing.allocator;
    const root = try std.fmt.bufPrintSentinel(buffer, "/tmp/noface-library-test-{d}", .{
        linux.getpid(),
    }, 0);
    var path: [320]u8 = undefined;
    _ = linux.mkdir(root, 0o755); // Ignored: the writes below say if it's missing
    _ = linux.mkdir(try std.fmt.bufPrintSentinel(&path, "{s}/documents", .{root}, 0), 0o755);
    _ = linux.mkdir(try std.fmt.bufPrintSentinel(&path, "{s}/state", .{root}, 0), 0o755);
    var rows: std.ArrayList(u8) = .empty;
    defer rows.deinit(alloc);
    try rows.appendSlice(alloc, "\n");
    for (0..kindle_rows) |i| {
        const row = "/mnt/us/documents/Kindle {d}.azw3\tKindle {d}\tAn Author\t0\t0\t0\t\t0\t0\n";
        try rows.print(alloc, row, .{ i, i });
    }
    try test_write(try std.fmt.bufPrintSentinel(&path, "{s}/catalog", .{root}, 0), rows.items);
    for (0..epubs) |i| {
        var title: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&title, "Book {d}", .{i});
        const data = try test_epub(alloc, name, cover_bytes);
        defer alloc.free(data);
        const format = "{s}/documents/{s}.epub";
        const at = try std.fmt.bufPrintSentinel(&path, format, .{ root, name }, 0);
        try test_write(at, data);
    }
    assert(std.mem.startsWith(u8, root, "/tmp/noface-library-test-"));
    return root;
}

fn test_folder_remove(root: [:0]const u8) void {
    // Never anything but a test library's own folder: this removes it whole
    assert(std.mem.startsWith(u8, root, "/tmp/noface-library-test-"));
    assert(std.mem.indexOf(u8, root, "..") == null);
    var out: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", root };
    _ = @import("../sys/process.zig").run(&argv, &out); // Ignored: only /tmp is left fuller
}

/// A library read from `root`, as `test_folder` made it, in the regions the Kindle has.
const TestLibrary = struct {
    region: memory.Region,
    budget: memory.Budget,
    scratch: memory.Region,
    paths: [3][320]u8,
    sources: Sources,

    fn init(t: *TestLibrary, root: []const u8) !void {
        assert(root.len > 0);
        const setup = @import("../setup.zig");
        t.region = try .reserve("library", .heap, setup.region_bytes.library);
        t.budget = .{ .name = "library", .region = &t.region, .limit = t.region.bytes.len };
        t.scratch = try .reserve("library scratch", .bump, setup.region_bytes.library_scratch);
        t.sources = .{
            .budget = &t.budget,
            .scratch = &t.scratch,
            .catalog_path = try std.fmt.bufPrintSentinel(&t.paths[0], "{s}/catalog", .{root}, 0),
            .documents = try std.fmt.bufPrint(&t.paths[1], "{s}/documents", .{root}),
            .state_dir = try std.fmt.bufPrint(&t.paths[2], "{s}/state", .{root}),
        };
        assert(t.budget.live == 0);
    }

    fn deinit(t: *TestLibrary) void {
        assert(t.budget.live == 0); // Every list let go of
        assert(t.scratch.empty());
        t.scratch.release();
        t.region.release();
    }
};

test "hundreds of EPUBs list in memory that grows with their count, not their files" {
    const epubs = 300;
    var buffer: [64]u8 = undefined;
    // Covers of 256 KB: kept, as they once were, 300 would take 75 MB
    const root = try test_folder(&buffer, 0, epubs, 256 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    // The first look reads every cover, and saves it beside the book's state
    var first = try load(t.sources);
    try std.testing.expectEqual(@as(usize, epubs), first.entries.len);
    try std.testing.expect(first.entries[0].thumbnail.len > 0);
    try std.testing.expect(t.budget.live <= epubs * book_bytes_max);
    // What each said is kept, a line each, so the next load needn't open them
    var cache_buffer: [320]u8 = undefined;
    const cache_path = try std.fmt.bufPrintSentinel(&cache_buffer, "{s}/library/epubs.tsv", .{
        t.sources.state_dir,
    }, 0);
    const kept = try file.map(cache_path);
    try std.testing.expectEqual(@as(usize, epubs), std.mem.count(u8, kept, "\n"));
    file.unmap(kept);
    // Reloaded beside it, as after a download: two lists at once
    var again = try load(t.sources);
    try std.testing.expectEqual(@as(usize, epubs), again.entries.len);
    for (first.entries, again.entries) |a, b| try std.testing.expectEqualStrings(a.title, b.title);
    try std.testing.expect(t.budget.peak <= 2 * epubs * book_bytes_max + list_slack);
    again.deinit();
    first.deinit();
}

test "a book's place is read from its state file, found by one listing of the folder" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 3, 2, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var path_buffer: [320]u8 = undefined;
    const kindle = "/mnt/us/documents/Kindle 1.azw3";
    state.save(try state.path_for(&path_buffer, t.sources.state_dir, kindle), .{
        .para = 3,
        .percent = 42,
        .opened = 1000,
    });
    var library = try load(t.sources);
    defer library.deinit();
    var placed: u32 = 0;
    for (library.entries) |e| {
        if (std.mem.eql(u8, e.path, kindle)) {
            try std.testing.expectEqual(@as(u32, 42), e.percent);
            placed += 1;
        } else {
            try std.testing.expectEqual(@as(u32, 0), e.percent);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), placed);
}

test "a book with a long path is listed, where one past 320 bytes was silently dropped" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 0, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    const name: [600]u8 = @splat('x');
    var row_buffer: [800]u8 = undefined;
    const row = try std.fmt.bufPrint(&row_buffer, "/mnt/us/documents/{s}.kfx\tLong\tx\n", .{
        &name,
    });
    try test_write(t.sources.catalog_path, row);
    var library = try load(t.sources);
    defer library.deinit();
    try std.testing.expectEqual(@as(usize, 1), library.entries.len);
    try std.testing.expectEqualStrings("Long", library.entries[0].title);
}

test "a download is watched by its own file, not by reading the whole catalog again" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 0, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var book_buffer: [320]u8 = undefined;
    const book = try std.fmt.bufPrintSentinel(&book_buffer, "{s}/documents/B.kfx", .{root}, 0);
    var row_buffer: [400]u8 = undefined;
    const row = try std.fmt.bufPrint(&row_buffer, "{s}\tB\tx\t0\t0\t0\t\t0\t2\n", .{book});
    try test_write(t.sources.catalog_path, row);
    var library = try load(t.sources);
    defer library.deinit();
    try std.testing.expectEqual(@as(u32, 1), library.downloading_count());
    // Its file not there yet, or partial: still coming, and nothing else is read
    try std.testing.expectEqual(Download.waiting, watch_download(&library));
    try test_write(book, "not a whole book");
    try std.testing.expectEqual(Download.waiting, watch_download(&library));
}

test "a library past its most books lists the first that fit" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, books_max - 10, 30, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var library = try load(t.sources);
    defer library.deinit();
    try std.testing.expectEqual(@as(usize, books_max), library.entries.len);
    try std.testing.expectEqual(library.entries.len, library.visible.len);
    try std.testing.expect(library.entries[books_max - 1].is_epub()); // The EPUBs that fit
    try std.testing.expect(t.budget.peak <= books_max * book_bytes_max);
}
