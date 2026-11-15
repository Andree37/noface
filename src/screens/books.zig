//! The books in the library: the Kindle's own, listed by its catalog, and EPUBs
//! copied over the cable, found here.
//!
//! They're kept in an index on the user drive (library/index.zig), built when what
//! it's built from changes, and looked through a page at a time: the library's memory
//! is the same for ten books or millions. The screens see a `Library`: an arrangement
//! (order, filter, search), the page shown, the book to continue, and a few books read
//! back for an action, each an entry with its texts beside it.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const memory = @import("../base/memory.zig");
const catalog = @import("../model/catalog.zig");
const search = @import("../model/search.zig");
const journal = @import("../model/journal.zig");
const file = @import("../sys/file.zig");
const calls = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const process = @import("../sys/process.zig");
const state = @import("../sys/state.zig");
const paths = @import("../kindle/paths.zig");
const files = @import("../library/files.zig");
const index = @import("../library/index.zig");
const builder = @import("../library/builder.zig");
const sorter = @import("../library/sorter.zig");
const view = @import("../library/view.zig");
const library_ui = @import("../ui/library.zig");
const covers = @import("../ui/covers.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const app = @import("../app.zig");
const setup = @import("../setup.zig");

/// The most books the library takes: past any Kindle's storage (see index.zig).
pub const books_max = index.books_max;

/// What one library takes of the library's region, beside the shared buffers: its
/// books read back, a page and a few more, each with its texts.
pub const library_bytes = @sizeOf(State);

/// What the shared buffers take of the library's region, at most.
pub const shared_bytes_max: u32 = builder.Work.bytes_max;

/// What every library shares, taken once at startup: the buffers its builds and passes
/// use, and the bits of which books a look lets through.
pub const Shared = struct {
    work: builder.Work,
    bits: view.Bits,

    pub fn init(s: *Shared, budget: *memory.Budget) !void {
        s.work = try builder.Work.init(budget);
        s.bits = .{ .words = s.work.bits };
        assert(s.bits.words.len * 64 >= books_max);
        assert(s.bits.generation == 0);
    }
};

/// Where a library is read from, and the memory it's read into.
pub const Sources = struct {
    shared: *Shared,
    budget: *memory.Budget, // The library's: outlives it, and holds two during a reload
    scratch: *memory.Region, // Bump: each EPUB as it's read, and a walk's folders
    catalog_path: [*:0]const u8, // The Kindle's catalog, exported
    documents: []const u8, // Where EPUBs are found
    state_dir: []const u8, // Each book's place and cover, and the index's folder
};

/// What tells that the Kindle's catalog changed without reading it: the size and change
/// time of its database and of the log its changes go to first.
pub const CatalogFacts = struct {
    database: ?calls.Facts = null,
    log: ?calls.Facts = null,

    pub fn read() CatalogFacts {
        return .{
            .database = file.facts_of(paths.catalog),
            .log = file.facts_of(paths.catalog ++ "-wal"),
        };
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

/// A library's books read back, and its index open: one block of the library's region.
const State = struct {
    ix: index.Index = undefined,
    open: bool = false, // `ix` is open: false for a library whose index won't read
    dir_buffer: [files.path_bytes_max]u8 = undefined,
    dir_len: u32 = 0,
    records_buffer: [4 << 10]u8 = undefined,
    text_buffer: [index.blob_bytes_max]u8 = undefined,
    v: view.View = .{},
    filter: catalog.Filter = .all,
    words: search.Query = .{},
    page_slots: [library_ui.page_books_max]index.Slot = @splat(.{}),
    page_entries: [library_ui.page_books_max]catalog.Entry = undefined,
    page_filled: u32 = 0,
    hero_slot: index.Slot = .{},
    cover_slot: index.Slot = .{},
    next_slots: [2]index.Slot = @splat(.{}), // The book after the one just read, by turns
    next_turn: u1 = 0,
    search_slots: [search_sheet.max_rows]index.Slot = @splat(.{}),
    search_entries: [search_sheet.max_rows]catalog.Entry = undefined,
    search_filled: u32 = 0,
    catalog_seen: CatalogFacts = .{},
    rebuilt: bool = false, // Built again once since loaded, after damage was found

    fn dir(s: *const State) []const u8 {
        assert(s.dir_len > 0);
        assert(s.dir_len <= s.dir_buffer.len);
        return s.dir_buffer[0..s.dir_len];
    }

    fn look(s: *const State) view.Look {
        assert(s.words.len <= s.words.buf.len);
        const words = s.words.words();
        assert(words.len <= s.words.len);
        return .{ .filter = s.filter, .words = words };
    }
};

pub const Library = struct {
    shared: *Shared,
    sources: Sources,
    state: *State, // In the library's region, on its budget

    pub fn deinit(l: *Library) void {
        assert(l.sources.budget.live >= @sizeOf(State));
        assert(l.state.dir_len > 0);
        if (l.state.open) l.state.ix.close();
        l.sources.budget.allocator().destroy(l.state);
    }

    pub fn count(l: *const Library) u32 {
        l.state.v.invariants();
        assert(l.state.v.count <= books_max);
        return l.state.v.count;
    }

    pub fn local_count(l: *const Library) u32 {
        if (!l.state.open) return 0;
        const header = &l.state.ix.header;
        assert(header.count <= books_max);
        assert(header.local <= header.count);
        return header.local;
    }

    pub fn downloading_count(l: *const Library) u32 {
        if (!l.state.open) return 0;
        const header = &l.state.ix.header;
        assert(header.count <= books_max);
        assert(header.downloading <= header.count);
        return header.downloading;
    }

    /// Whether two libraries have the same books on the Kindle and the same coming
    /// down, so one can stand for the other on screen.
    pub fn same_shelf(l: *const Library, other: *const Library) bool {
        assert(l.state != other.state);
        assert(l.shared == other.shared);
        // Built again on the drive: the other's open files are of a build that's gone,
        // and a book it saved would land on another's record
        if (l.state.open != other.state.open) return false;
        if (l.state.open and l.state.ix.header.generation != other.state.ix.header.generation) {
            return false;
        }
        if (l.local_count() != other.local_count()) return false;
        return l.downloading_count() == other.downloading_count();
    }

    /// Whether a download watched has arrived, looking only at what's downloading: the
    /// files the index says are coming, or, when it names none yet (the catalog may not
    /// have marked it when the library was read), whether the catalog changed at all.
    /// The whole catalog is exported and read again only once either says so.
    pub fn watch_download(l: *Library) Download {
        const s = l.state;
        if (!s.open) return .catalog_changed; // Nothing to watch by: read it again
        assert(s.ix.header.count <= books_max);
        assert(s.ix.header.downloading <= s.ix.header.count);
        if (s.ix.header.downloading > 0) {
            const work = &l.shared.work;
            const arrived = view.each_downloading(&s.ix, work, &s.cover_slot, {}, is_whole) catch
                return .arrived; // Can't tell: read it again
            return if (arrived) .arrived else .waiting;
        }
        if (std.meta.eql(CatalogFacts.read(), s.catalog_seen)) return .waiting;
        return .catalog_changed;
    }

    fn is_whole(_: void, e: *const catalog.Entry) bool {
        return e.path.len > 0 and builder.is_complete_book(e.path);
    }

    /// Arranges the books for an order, a filter and a search (`words`, empty for none):
    /// which are let through, how many, and the book to continue.
    pub fn arrange(
        l: *Library,
        order: catalog.Order,
        filter: catalog.Filter,
        words: []const u8,
    ) void {
        assert(words.len <= l.state.words.buf.len);
        const s = l.state;
        s.filter = filter;
        @memcpy(s.words.buf[0..words.len], words);
        s.words.len = @intCast(words.len);
        s.hero_slot.id = std.math.maxInt(u32);
        // An index found damaged (a record torn, a file cut short) is built again now,
        // once: a drive that won't take it leaves the library empty till the next load
        if (!s.open) l.rebuild();
        if (!s.open) return;
        l.arrange_index(order) catch |err| {
            l.broken(err);
            l.rebuild();
            if (!s.open) return;
            l.arrange_index(order) catch |again| l.broken(again);
        };
        s.v.invariants();
    }

    fn arrange_index(l: *Library, order: catalog.Order) !void {
        const s = l.state;
        assert(s.open);
        try view.arrange(&s.ix, &l.shared.work, &l.shared.bits, &s.v, order, s.look());
        if (s.v.hero) |h| try s.ix.read(h, &s.hero_slot);
        s.v.invariants();
    }

    /// Builds the index again, in place of one found damaged, the first time only.
    fn rebuild(l: *Library) void {
        const s = l.state;
        assert(!s.open);
        if (s.rebuilt or !l.sources.scratch.empty()) return;
        s.rebuilt = true;
        var scratch = memory.Budget{
            .name = "library scratch",
            .region = l.sources.scratch,
            .limit = l.sources.scratch.bytes.len,
        };
        defer scratch.reset(.give_back);
        const places = places_of(l.sources, s);
        const work = &l.shared.work;
        const wanted = builder.sources_now(&scratch, places);
        builder.build(work, &scratch, places, wanted) catch |err| {
            log("library: index not built again ({s})\n", .{@errorName(err)});
            return;
        };
        const buffers: index.Buffers = .{ .records = &s.records_buffer, .text = &s.text_buffer };
        s.ix = index.Index.open(s.dir(), buffers) catch return;
        s.open = true;
        builder.merge_states(&s.ix, work, l.sources.state_dir) catch |err| {
            log("library: places not merged ({s})\n", .{@errorName(err)});
        };
        assert(s.rebuilt);
    }

    /// The book to continue, when there is one: always on this Kindle.
    pub fn hero(l: *Library) ?*catalog.Entry {
        const slot = &l.state.hero_slot;
        if (!slot.holds()) return null;
        assert(slot.id < l.state.ix.header.count);
        assert(slot.entry.is_local()); // A cloud book can't be opened from the hero
        return &slot.entry;
    }

    /// The books on library page `page_index` of those let through, read back.
    pub fn page(l: *Library, page_index: u32) []catalog.Entry {
        const s = l.state;
        assert(page_index < library_ui.page_count(s.v.count));
        const range = library_ui.page_range(page_index, s.v.count);
        s.page_filled = l.read_range(range.first, range.end, &s.page_slots) catch |err| blk: {
            l.broken(err);
            break :blk 0;
        };
        for (s.page_slots[0..s.page_filled], s.page_entries[0..s.page_filled]) |*slot, *e| {
            e.* = slot.entry;
        }
        assert(s.page_filled <= range.end - range.first);
        return s.page_entries[0..s.page_filled];
    }

    fn read_range(l: *Library, first: u32, end: u32, slots: []index.Slot) !u32 {
        const s = l.state;
        assert(first <= end);
        assert(end - first <= slots.len);
        if (!s.open) return 0;
        const range: view.Range = .{ .first = first, .end = end };
        return view.page(&s.ix, &l.shared.work, &l.shared.bits, &s.v, s.look(), range, slots);
    }

    /// The books of the page last read, as `page` gave them.
    pub fn page_shown(l: *Library) []catalog.Entry {
        assert(l.state.page_filled <= l.state.page_entries.len);
        assert(l.state.page_filled <= l.state.v.count);
        return l.state.page_entries[0..l.state.page_filled];
    }

    /// The `i`th book of the page last read.
    pub fn book(l: *Library, i: u32) *catalog.Entry {
        assert(i < l.state.page_filled);
        assert(l.state.page_slots[i].holds());
        return &l.state.page_entries[i];
    }

    /// Gets the covers of library page `page_index` ready, so turning to it doesn't wait.
    pub fn prepare_covers(l: *Library, pool: *covers.Pool, page_index: u32) void {
        const s = l.state;
        if (page_index >= library_ui.page_count(s.v.count)) return;
        const range = library_ui.page_range(page_index, s.v.count);
        assert(range.first <= range.end);
        for (range.first..range.end) |i| {
            const one: u32 = @intCast(i);
            const read = l.read_range(one, one + 1, (&s.cover_slot)[0..1]) catch return;
            if (read == 1) _ = pool.grid_cover(s.cover_slot.entry.thumbnail);
        }
        assert(range.end <= s.v.count);
    }

    /// Saves what reading (or marking) a book changed of it, read back from this
    /// library: its record is written in place, and the orders it moves in are sorted
    /// again when next shown.
    pub fn save(l: *Library, e: *const catalog.Entry) void {
        const s = l.state;
        assert(e.is_local()); // Only a book on the Kindle is read or marked
        if (!s.open) return;
        const id = l.id_of(e) orelse return;
        assert(id < s.ix.header.count);
        l.save_record(id, e) catch |err| l.broken(err);
    }

    fn save_record(l: *Library, id: u32, e: *const catalog.Entry) !void {
        const s = l.state;
        assert(id < s.ix.header.count);
        var r = try s.ix.record(id);
        const was_read = builder.record_is_read(&r);
        r.percent = @intCast(@min(e.percent, 100));
        r.last = e.last;
        r.seconds_read = e.seconds_read;
        if (e.finished) r.flags |= index.Record.finished else r.flags &= ~index.Record.finished;
        try s.ix.write_record(id, &r);
        const is_read = builder.record_is_read(&r);
        if (is_read and !was_read) s.ix.header.read += 1;
        if (was_read and !is_read) s.ix.header.read -= 1;
        s.ix.header.stale |= index.reading_orders;
        try s.ix.write_header();
        assert(s.ix.header.read <= s.ix.header.count);
    }

    /// Which record a book read back from this library is, by where it was read into.
    fn id_of(l: *Library, e: *const catalog.Entry) ?u32 {
        const s = l.state;
        assert(s.open);
        for (s.page_entries[0..s.page_filled], s.page_slots[0..s.page_filled]) |*p, *slot| {
            if (p == e) return slot.id;
        }
        for (s.search_entries[0..s.search_filled], s.search_slots[0..s.search_filled]) |*p, *slot| {
            if (p == e) return slot.id;
        }
        if (e == &s.hero_slot.entry and s.hero_slot.holds()) return s.hero_slot.id;
        for (&s.next_slots) |*slot| {
            if (e == &slot.entry and slot.holds()) return slot.id;
        }
        assert(s.page_filled <= s.page_slots.len);
        return null;
    }

    /// The next book of `e`'s series not read yet, read back, or null.
    pub fn next_in_series(l: *Library, e: *const catalog.Entry) ?*catalog.Entry {
        const s = l.state;
        if (!s.open) return null;
        s.next_turn +%= 1;
        const slot = &s.next_slots[s.next_turn];
        assert(&slot.entry != e); // Each next goes in the other slot
        const found = view.next_in_series(&s.ix, &l.shared.work, e, slot) catch |err| {
            l.broken(err);
            return null;
        };
        if (!found) return null;
        assert(!slot.entry.is_read());
        return &slot.entry;
    }

    pub const Matches = struct { entries: []catalog.Entry, more: bool };

    /// The books whose title, author or series has `words`, in the order last arranged:
    /// the first `search_sheet.max_rows`, and whether more matched.
    pub fn matches(l: *Library, words: []const u8) Matches {
        const s = l.state;
        assert(words.len > 0);
        s.search_filled = 0;
        if (!s.open) return .{ .entries = &.{}, .more = false };
        const work = &l.shared.work;
        const bits = &l.shared.bits;
        const slots = &s.search_slots;
        const order = s.v.order;
        const found = view.first_matches(&s.ix, work, bits, order, words, slots) catch |err| {
            l.broken(err);
            return .{ .entries = &.{}, .more = false };
        };
        s.search_filled = @min(found, s.search_slots.len);
        const shown = s.search_filled;
        for (s.search_slots[0..shown], s.search_entries[0..shown]) |*slot, *e| e.* = slot.entry;
        assert(shown <= search_sheet.max_rows);
        return .{ .entries = s.search_entries[0..shown], .more = found > shown };
    }

    /// What the stats screen counts of the library, this year being from `year_start`.
    pub fn totals(l: *Library, year_start: i32, utc_offset: i64) view.Totals {
        const s = l.state;
        if (!s.open) return .{};
        assert(s.ix.header.count <= books_max);
        const work = &l.shared.work;
        const t = view.totals(&s.ix, work, year_start, utc_offset, journal.day_of) catch |err| {
            l.broken(err);
            return .{};
        };
        assert(t.books == s.ix.header.count);
        return t;
    }

    /// The books on this Kindle, each copied into `alloc` with its texts: for the
    /// series screens, which list them. An error when `alloc` runs out of room.
    pub fn local_books(l: *Library, alloc: std.mem.Allocator) ![]catalog.Entry {
        const s = l.state;
        if (!s.open) return &.{};
        assert(s.ix.header.local <= s.ix.header.count);
        var list: std.ArrayList(catalog.Entry) = .empty;
        try list.ensureTotalCapacity(alloc, s.ix.header.local);
        var keep: Keep = .{ .alloc = alloc, .list = &list };
        try view.each_book(&s.ix, &l.shared.work, &keep, Keep.add);
        if (keep.failed) return error.OutOfMemory;
        assert(list.items.len <= s.ix.header.local);
        return list.items;
    }

    /// An index that stops reading as whole while open: built again at the next
    /// load, and empty till then. Nothing worse: the books are where they were.
    fn broken(l: *Library, err: anyerror) void {
        log("library: index unreadable ({s}), rebuilt at the next load\n", .{@errorName(err)});
        const s = l.state;
        if (s.open) {
            s.ix.header.sources.places = 0; // Matches nothing: built again
            s.ix.write_header() catch {}; // Ignored: a header that won't write is rebuilt too
            s.ix.close();
        }
        s.open = false;
        s.v = .{};
        s.page_filled = 0;
        s.search_filled = 0;
        s.hero_slot.id = std.math.maxInt(u32);
        assert(!s.open);
        assert(s.v.count == 0);
    }
};

/// Copies books into memory of their own, for `Library.local_books`.
const Keep = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayList(catalog.Entry),
    failed: bool = false,

    fn add(k: *Keep, e: *const catalog.Entry) void {
        if (!e.is_local() or k.failed) return;
        var copy = e.*;
        copy.path = k.alloc.dupeSentinel(u8, e.path, 0) catch return k.fail();
        copy.title = k.alloc.dupe(u8, e.title) catch return k.fail();
        copy.author = k.alloc.dupe(u8, e.author) catch return k.fail();
        copy.series = k.alloc.dupe(u8, e.series) catch return k.fail();
        copy.thumbnail = "";
        copy.key = "";
        copy.kind = "";
        copy.guid = "";
        k.list.append(k.alloc, copy) catch return k.fail();
        assert(copy.path.len == e.path.len);
        assert(k.list.items.len > 0);
    }

    fn fail(k: *Keep) void {
        assert(!k.failed); // Once: nothing more is copied after
        k.failed = true;
        assert(k.failed);
    }
};

pub fn load_library(a: *app.App) !Library {
    assert(a.library_budget.limit > 0);
    assert(a.library_scratch_region.kind == .bump);
    return load(.{
        .shared = a.library_shared,
        .budget = a.library_budget,
        .scratch = a.library_scratch_region,
        .catalog_path = a.library_path,
        .documents = a.documents,
        .state_dir = a.state_dir,
    });
}

/// The library's index, built again first if what it's built from changed, or it
/// doesn't read as whole; then what noface saved of each book merged in.
pub fn load(sources: Sources) !Library {
    assert(sources.scratch.empty());
    assert(sources.state_dir.len > 0);
    const s = try sources.budget.allocator().create(State);
    errdefer sources.budget.allocator().destroy(s);
    s.* = .{};
    // Before the list is read, so a change made while it's read shows next time
    s.catalog_seen = CatalogFacts.read();
    const format = "{s}/library";
    const folder = try std.fmt.bufPrintSentinel(&s.dir_buffer, format, .{sources.state_dir}, 0);
    _ = calls.mkdir(folder, 0o755); // Ignored: there already, or the build says it can't write
    s.dir_len = @intCast(folder.len);
    var scratch = memory.Budget{
        .name = "library scratch",
        .region = sources.scratch,
        .limit = sources.scratch.bytes.len,
    };
    defer scratch.reset(.give_back);
    const places = places_of(sources, s);
    const work = &sources.shared.work;
    const wanted = builder.sources_now(&scratch, places);
    open_or_build(s, work, &scratch, places, wanted) catch |err| {
        log("library: no index ({s})\n", .{@errorName(err)});
    };
    if (s.open) {
        builder.merge_states(&s.ix, work, sources.state_dir) catch |err| {
            log("library: places not merged ({s})\n", .{@errorName(err)});
        };
    }
    return .{ .shared = sources.shared, .sources = sources, .state = s };
}

/// Where the books are, and where `s`'s index is kept.
fn places_of(sources: Sources, s: *const State) builder.Places {
    assert(sources.state_dir.len > 0);
    const places: builder.Places = .{
        .catalog_path = sources.catalog_path,
        .documents = sources.documents,
        .state_dir = sources.state_dir,
        .dir = s.dir(),
    };
    assert(places.dir.len > sources.state_dir.len);
    return places;
}

fn open_or_build(
    s: *State,
    work: *const builder.Work,
    scratch: *memory.Budget,
    places: builder.Places,
    wanted: index.Sources,
) !void {
    assert(!s.open);
    const buffers: index.Buffers = .{ .records = &s.records_buffer, .text = &s.text_buffer };
    if (index.Index.open(s.dir(), buffers)) |ix| {
        if (std.meta.eql(ix.header.sources, wanted)) {
            s.ix = ix;
            s.open = true;
            return;
        }
        var stale = ix;
        stale.close();
    } else |_| {}
    const t0 = os.now_us();
    try builder.build(work, scratch, places, wanted);
    s.ix = try index.Index.open(s.dir(), buffers);
    s.open = true;
    log("library: index built, {d} books in {d} ms\n", .{
        s.ix.header.count,
        (os.now_us() - t0) / 1000,
    });
    assert(s.ix.header.count <= books_max);
}

/// A line for the log, but not from the tests, where it would read as a failure.
fn log(comptime format: []const u8, args: anytype) void {
    assert(format.len > 0);
    assert(format[format.len - 1] == '\n');
    if (!builtin.is_test) std.debug.print(format, args);
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
    const parts = [_][2][]const u8{
        .{ "mimetype", "application/epub+zip" },
        .{ "META-INF/container.xml", container },
        .{ "OEBPS/content.opf", opf },
        .{ "OEBPS/c1.xhtml", "<html><body><p>Text.</p></body></html>" },
        .{ "OEBPS/cover.jpg", cover },
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var offsets: [parts.len]u32 = undefined;
    for (parts, &offsets) |f, *offset| {
        offset.* = @intCast(out.items.len);
        try test_zip_header(alloc, &out, "PK\x03\x04", f, null);
        try out.appendSlice(alloc, f[1]);
    }
    const directory: u32 = @intCast(out.items.len);
    for (parts, offsets) |f, offset| try test_zip_header(alloc, &out, "PK\x01\x02", f, offset);
    var end: [22]u8 = @splat(0);
    end[0..4].* = "PK\x05\x06".*;
    std.mem.writeInt(u16, end[8..10], parts.len, .little);
    std.mem.writeInt(u16, end[10..12], parts.len, .little);
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
    const rc = calls.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (os.failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    defer _ = calls.close(fd);
    if (calls.write(fd, data.ptr, data.len) != data.len) return error.CantWrite;
}

/// A test library's folder in /tmp: its catalog with `kindle_rows` Kindle books, and
/// `epubs` EPUBs with covers of `cover_bytes`. Removed by `test_folder_remove`.
fn test_folder(buffer: []u8, kindle_rows: u32, epubs: u32, cover_bytes: u32) ![:0]const u8 {
    assert(buffer.len >= 64);
    const alloc = std.testing.allocator;
    const root = try std.fmt.bufPrintSentinel(buffer, "/tmp/noface-library-test-{d}", .{
        calls.getpid(),
    }, 0);
    var path: [320]u8 = undefined;
    _ = calls.mkdir(root, 0o755); // Ignored: the writes below say if it's missing
    _ = calls.mkdir(try std.fmt.bufPrintSentinel(&path, "{s}/documents", .{root}, 0), 0o755);
    _ = calls.mkdir(try std.fmt.bufPrintSentinel(&path, "{s}/state", .{root}, 0), 0o755);
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
    _ = process.run(&argv, &out); // Ignored: only /tmp is left fuller
}

/// A library read from `root`, as `test_folder` made it, in the regions the Kindle has.
const TestLibrary = struct {
    region: memory.Region,
    budget: memory.Budget,
    scratch: memory.Region,
    shared: *Shared,
    paths: [3][320]u8,
    sources: Sources,

    fn init(t: *TestLibrary, root: []const u8) !void {
        assert(root.len > 0);
        t.region = try .reserve("library", .heap, setup.region_bytes.library);
        t.budget = .{ .name = "library", .region = &t.region, .limit = t.region.bytes.len };
        t.scratch = try .reserve("library scratch", .bump, setup.region_bytes.library_scratch);
        t.shared = try t.budget.allocator().create(Shared);
        try t.shared.init(&t.budget);
        t.sources = .{
            .shared = t.shared,
            .budget = &t.budget,
            .scratch = &t.scratch,
            .catalog_path = try std.fmt.bufPrintSentinel(&t.paths[0], "{s}/catalog", .{root}, 0),
            .documents = try std.fmt.bufPrint(&t.paths[1], "{s}/documents", .{root}),
            .state_dir = try std.fmt.bufPrint(&t.paths[2], "{s}/state", .{root}),
        };
        assert(t.budget.live > 0); // The shared buffers, for good
    }

    fn deinit(t: *TestLibrary) void {
        assert(t.scratch.empty());
        assert(t.budget.live >= @sizeOf(Shared));
        t.scratch.release();
        t.region.release();
    }
};

/// Every book of `library` in its arrangement, by title, for the tests.
fn test_titles(library: *Library, alloc: std.mem.Allocator) ![][]const u8 {
    assert(library.state.open);
    var titles: std.ArrayList([]const u8) = .empty;
    for (0..library_ui.page_count(library.count())) |p| {
        for (library.page(@intCast(p))) |e| try titles.append(alloc, try alloc.dupe(u8, e.title));
    }
    assert(titles.items.len == library.count());
    return titles.items;
}

test "hundreds of EPUBs list in memory that doesn't grow with them, read once" {
    const epubs = 300;
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 0, epubs, 256 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    const before = t.budget.live;
    var first = try load(t.sources);
    first.arrange(.title, .all, "");
    const listed = first.count() + @intFromBool(first.hero() != null);
    try std.testing.expectEqual(@as(u32, epubs), listed);
    try std.testing.expect(first.page(0)[0].thumbnail.len > 0); // Its cover saved, and found
    // A library takes the same, whatever it holds
    try std.testing.expectEqual(before + library_bytes, t.budget.live);
    // What each said is kept, a line each, so the next load needn't open them
    var cache_buffer: [320]u8 = undefined;
    const cache_path = try std.fmt.bufPrintSentinel(&cache_buffer, "{s}/library/epubs.tsv", .{
        t.sources.state_dir,
    }, 0);
    const kept = try file.map(cache_path);
    try std.testing.expectEqual(@as(usize, epubs), std.mem.count(u8, kept, "\n"));
    file.unmap(kept);
    // Reloaded beside it, as after a download: two at once, and no more memory each
    var again = try load(t.sources);
    again.arrange(.title, .all, "");
    try std.testing.expectEqual(first.count(), again.count());
    try std.testing.expectEqual(before + 2 * library_bytes, t.budget.live);
    again.deinit();
    first.deinit();
    try std.testing.expectEqual(before, t.budget.live);
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
    library.arrange(.recent, .all, "");
    // The one in progress leads, as the book to continue
    const hero = library.hero().?;
    try std.testing.expectEqualStrings(kindle, hero.path);
    try std.testing.expectEqual(@as(u32, 42), hero.percent);
    for (library.page(0)) |e| try std.testing.expectEqual(@as(u32, 0), e.percent);
}

test "a book read and saved moves up, and keeps its place through a reload" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 30, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var library = try load(t.sources);
    library.arrange(.recent, .all, "");
    _ = library.page(0);
    const e = library.book(5);
    const title = try std.testing.allocator.dupe(u8, e.title);
    defer std.testing.allocator.free(title);
    e.percent = 50;
    e.last = 5000;
    e.seconds_read = 60;
    library.save(e);
    library.arrange(.recent, .all, "");
    try std.testing.expectEqualStrings(title, library.hero().?.title);
    library.deinit();
    var again = try load(t.sources);
    defer again.deinit();
    again.arrange(.progress, .unread, "");
    try std.testing.expectEqualStrings(title, again.hero().?.title);
    try std.testing.expectEqual(@as(u32, 50), again.hero().?.percent);
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
    library.arrange(.recent, .all, "");
    _ = library.page(0);
    const listed = library.hero() orelse library.book(0);
    try std.testing.expectEqualStrings("Long", listed.title);
    try std.testing.expectEqual(@as(usize, 618 + 4), listed.path.len);
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
    try std.testing.expectEqual(Download.waiting, library.watch_download());
    try test_write(book, "not a whole book");
    try std.testing.expectEqual(Download.waiting, library.watch_download());
}

test "a record torn while written in place is found by its checksum, and the index built again" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 40, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var library = try load(t.sources);
    defer library.deinit();
    library.arrange(.recent, .all, "");
    const count = library.count();
    // Half a record written over, as by power lost in the middle of saving a place
    var path_buffer: [320]u8 = undefined;
    const format = "{s}/library/records";
    const path = try std.fmt.bufPrintSentinel(&path_buffer, format, .{t.sources.state_dir}, 0);
    const torn: [32]u8 = @splat(0x55);
    try std.testing.expect(files.write_at(path, index.file_head_bytes + 7 * 64, &torn));
    library.state.ix.records.len = 0; // Read from the drive again, as after a restart
    library.state.ix.header.stale = index.all_orders; // Every record read again
    library.arrange(.title, .all, "");
    try std.testing.expect(library.state.rebuilt);
    try std.testing.expectEqual(count, library.count());
}

test "an index damaged or cut short is built again, and a missing order sorted again" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 50, 3, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var good = try load(t.sources);
    good.arrange(.author, .all, "");
    const count = good.count();
    good.deinit();
    var path_buffer: [320]u8 = undefined;
    const folder = t.sources.state_dir;
    // A header changed by a byte: its checksum no longer matches
    const header_format = "{s}/library/header";
    const header_path = try std.fmt.bufPrintSentinel(&path_buffer, header_format, .{folder}, 0);
    try std.testing.expect(files.write_at(header_path, 20, "x"));
    // Records cut short, as by a crash in the middle of writing them
    var records_buffer: [320]u8 = undefined;
    const records_format = "{s}/library/records";
    const records_path =
        try std.fmt.bufPrintSentinel(&records_buffer, records_format, .{folder}, 0);
    const records = try file.map(records_path);
    const shorter = try std.testing.allocator.dupe(u8, records[0 .. records.len - 10]);
    file.unmap(records);
    defer std.testing.allocator.free(shorter);
    try test_write(records_path, shorter);
    for (0..2) |_| {
        var rebuilt = try load(t.sources);
        defer rebuilt.deinit();
        rebuilt.arrange(.author, .all, "");
        try std.testing.expectEqual(count, rebuilt.count());
        const order_format = "{s}/library/order-author";
        const order_path =
            try std.fmt.bufPrintSentinel(&path_buffer, order_format, .{folder}, 0);
        files.remove(order_path); // Gone: sorted again when next shown
    }
}

test "sorting a library larger than memory, in runs merged on the drive, gives the same order" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 400, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var by_memory: [2][][]const u8 = undefined;
    for (&by_memory, [_]u32{ 2 << 20, sorter_test_bytes }) |*titles, items_bytes| {
        t.shared.work.sort.items = t.shared.work.sort.items[0..items_bytes];
        t.shared.work.sort_second.items = t.shared.work.sort_second.items[0..items_bytes];
        var library = try load(t.sources);
        defer library.deinit();
        library.state.ix.header.stale = index.all_orders; // Sorted again, in this memory
        library.arrange(.author, .all, "");
        titles.* = try test_titles(&library, arena.allocator());
    }
    try std.testing.expectEqual(by_memory[0].len, by_memory[1].len);
    for (by_memory[0], by_memory[1]) |a, b| try std.testing.expectEqualStrings(a, b);
}

/// A sort buffer of a few items: most of a library's sort is then runs merged on the drive.
const sorter_test_bytes: u32 = sorter.key_bytes_max + 2048;

test "a large library takes the same memory as a small one, and is looked through quickly" {
    var sizes: [2]u64 = undefined;
    for ([_]u32{ 1000, 20_000 }, &sizes) |books, *live| {
        var buffer: [64]u8 = undefined;
        const root = try test_folder(&buffer, books, 0, 1 << 10);
        defer test_folder_remove(root);
        var t: TestLibrary = undefined;
        try t.init(root);
        defer t.deinit();
        const t0 = os.now_us();
        var library = try load(t.sources);
        defer library.deinit();
        const t1 = os.now_us();
        library.arrange(.title, .unread, "");
        const t2 = os.now_us();
        library.arrange(.title, .unread, "17");
        const t3 = os.now_us();
        _ = library.page(library_ui.page_count(library.count()) - 1);
        const t4 = os.now_us();
        live.* = t.budget.peak;
        try std.testing.expect(library.count() > 0);
        if (std.c.getenv("NOFACE_BENCH") != null) {
            const format = "{d} books: load {d} ms, sort {d} ms, search {d} ms, page {d} ms\n";
            std.debug.print(format, .{
                books,
                (t1 - t0) / 1000,
                (t2 - t1) / 1000,
                (t3 - t2) / 1000,
                (t4 - t3) / 1000,
            });
        }
    }
    try std.testing.expectEqual(sizes[0], sizes[1]);
}
