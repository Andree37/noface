//! The books in the library: the Kindle's own, listed by its catalog, and EPUBs
//! copied over the cable, found here.
//!
//! They're kept in an index on the user drive (library/index.zig), built when what
//! it's built from changes, and mapped; their ids are sorted in memory, 8 bytes a book,
//! so there's no number of books the library won't list. The screens see a `Library`:
//! an arrangement (order, filter, search), the page shown, the book to continue, and a
//! few books read back for an action, each an entry with its texts beside it.
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
const view = @import("../library/view.zig");
const library_ui = @import("../ui/library.zig");
const covers = @import("../ui/covers.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const app = @import("../app.zig");
const setup = @import("../setup.zig");

/// The most books the library takes: past any Kindle's storage (see index.zig).
pub const books_max = index.books_max;

/// What the library takes of the library's region, beside the shared buffers: its
/// books read back, a page and a few more, each with its texts.
pub const library_bytes = @sizeOf(State);

/// What the shared buffers take of the library's region, at most.
pub const shared_bytes_max: u64 = view.Shared.bytes_max;

/// Where a library is read from, and the memory it's read into.
pub const Sources = struct {
    shared: *view.Shared,
    budget: *memory.Budget, // The library's: outlives it
    scratch: *memory.Region, // Bump: each EPUB as it's read, and a walk's folders
    catalog_path: [*:0]const u8, // The Kindle's catalog, exported
    documents: []const u8, // Where EPUBs are found
    state_dir: []const u8, // Each book's place and cover, and the index's folder
    heartbeat: ?[*:0]const u8, // As `builder.Places.heartbeat`: null in the tests
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

/// What tells two readings of the library apart on screen: the build, and how many
/// books are on the Kindle and coming down.
pub const Shelf = struct { generation: u64, local: u32, downloading: u32 };

/// A library's index open, its arrangement, and its books read back: one block of the
/// library's region.
const State = struct {
    ix: ?index.Index = null, // Null for a library whose index won't read
    dir_buffer: [files.path_bytes_max]u8 = undefined,
    dir_len: u32 = 0,
    catalog_seen: CatalogFacts = .{},
    order: catalog.Order = .recent,
    filter: catalog.Filter = .all,
    words: search.Query = .{},
    /// The shared items hold every book in `order`: false once they're sorted otherwise,
    /// or a book saved may have moved.
    sorted: bool = false,
    count: u32 = 0, // Books let through
    hero_slot: index.Slot = .{},
    page_slots: [library_ui.page_books_max]index.Slot = @splat(.{}),
    page_entries: [library_ui.page_books_max]catalog.Entry = undefined,
    page_filled: u32 = 0,
    page_read: ?u32 = null, // The page last read, read again after a reload
    next_slots: [2]index.Slot = @splat(.{}), // The book after the one just read, by turns
    next_turn: u1 = 0,
    search_slots: [search_sheet.max_rows]index.Slot = @splat(.{}),
    search_entries: [search_sheet.max_rows]catalog.Entry = undefined,
    search_filled: u32 = 0,

    fn dir(s: *const State) []const u8 {
        assert(s.dir_len > 0);
        assert(s.dir_len <= s.dir_buffer.len);
        return s.dir_buffer[0..s.dir_len];
    }

    /// The index, when one is open.
    fn opened(s: *State) ?*index.Index {
        if (s.ix) |*ix| return ix;
        return null;
    }

    fn look(s: *const State) view.Look {
        assert(s.words.len <= s.words.buf.len);
        return .{ .filter = s.filter, .words = s.words.words() };
    }
};

pub const Library = struct {
    shared: *view.Shared,
    sources: Sources,
    state: *State, // In the library's region, on its budget

    pub fn deinit(l: *Library) void {
        assert(l.sources.budget.live >= @sizeOf(State));
        assert(l.shared.in_use);
        if (l.state.opened()) |ix| ix.close();
        l.sources.budget.allocator().destroy(l.state);
        l.shared.in_use = false;
    }

    pub fn count(l: *const Library) u32 {
        assert(l.state.count <= books_max);
        return l.state.count;
    }

    pub fn local_count(l: *const Library) u32 {
        return l.shelf().local;
    }

    pub fn downloading_count(l: *const Library) u32 {
        return l.shelf().downloading;
    }

    pub fn shelf(l: *const Library) Shelf {
        const ix = l.state.ix orelse return .{ .generation = 0, .local = 0, .downloading = 0 };
        const header = &ix.header;
        assert(header.local <= header.count);
        assert(header.downloading <= header.count);
        return .{
            .generation = header.generation,
            .local = header.local,
            .downloading = header.downloading,
        };
    }

    /// Whether a download watched has arrived, looking only at what's downloading: the
    /// files the index says are coming, or, when it names none yet (the catalog may not
    /// have marked it when the library was read), whether the catalog changed at all.
    /// The whole catalog is exported and read again only once either says so.
    pub fn watch_download(l: *Library) Download {
        const s = l.state;
        assert(l.shared.in_use);
        // No index: it was tried as the library was read, and a timer doesn't build again
        // what failed; the next reload (an action, a wake) tries once more
        const ix = s.opened() orelse return .waiting;
        assert(ix.header.downloading <= ix.header.count);
        if (ix.header.downloading > 0) {
            for (0..ix.header.count) |id| {
                const e = ix.entry(@intCast(id));
                if (e.availability != .downloading) continue;
                if (builder.is_complete_book(e.path)) return .arrived;
            }
            return .waiting;
        }
        if (std.meta.eql(CatalogFacts.read(), s.catalog_seen)) return .waiting;
        return .catalog_changed;
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
        assert(l.shared.in_use);
        const s = l.state;
        // Another filter or search lets other books through, in the same order
        if (order != s.order) s.sorted = false;
        s.order = order;
        s.filter = filter;
        @memcpy(s.words.buf[0..words.len], words);
        s.words.len = @intCast(words.len);
        l.lay_out();
    }

    /// Sorts the books, unless they are already, and counts those the look lets through,
    /// for the arrangement kept.
    fn lay_out(l: *Library) void {
        const s = l.state;
        s.count = 0;
        s.hero_slot.id = null;
        // No index: loading or reloading tried to build one, and a drive that won't
        // take it leaves the library empty till the next reload
        const ix = s.opened() orelse return;
        const all = l.shared.items[0..ix.header.count];
        const in_order = if (s.sorted) all else view.sort(ix, l.shared.items, s.order);
        const hero_id = catalog.pick_hero(view.ById{ .ix = ix });
        if (hero_id) |h| ix.read(h, &s.hero_slot);
        // While searching, every match is listed, the hero too
        const leave_out = if (s.words.len == 0) hero_id else null;
        s.count = view.count_through(ix, in_order, s.look(), leave_out);
        s.sorted = true;
        assert(s.count <= in_order.len);
        // The hero leads, ahead of the list, unless a search lists every match
        if (leave_out != null) assert(s.count < in_order.len);
    }

    /// The shared items sorted and counted for this library's arrangement: again, if a
    /// book saved since may have moved.
    fn sorted(l: *Library, ix: *const index.Index) []const index.Item {
        const s = l.state;
        assert(&s.ix.? == ix); // This library's own index, open
        if (!s.sorted) l.lay_out();
        assert(s.sorted);
        return l.shared.items[0..ix.header.count];
    }

    /// The book to continue, when there is one: always on this Kindle.
    pub fn hero(l: *Library) ?*catalog.Entry {
        const slot = &l.state.hero_slot;
        if (!slot.holds()) return null;
        assert(slot.entry.is_local()); // A cloud book can't be opened from the hero
        return &slot.entry;
    }

    /// The books on library page `page_index` of those let through, read back.
    pub fn page(l: *Library, page_index: u32) []catalog.Entry {
        const s = l.state;
        assert(page_index < library_ui.page_count(s.count));
        s.page_read = page_index;
        s.page_filled = 0;
        const ix = s.opened() orelse return &.{};
        const range = library_ui.page_range(page_index, s.count);
        var ids: [library_ui.page_books_max]u32 = undefined;
        const filled = view.page(l.sorted(ix), range.first, range.end, &ids);
        for (ids[0..filled], s.page_slots[0..filled], s.page_entries[0..filled]) |id, *slot, *e| {
            ix.read(id, slot);
            e.* = slot.entry;
        }
        s.page_filled = filled;
        assert(filled == range.end - range.first);
        return s.page_entries[0..filled];
    }

    /// The books of the page last read, as `page` gave them.
    pub fn page_shown(l: *Library) []catalog.Entry {
        assert(l.state.page_filled <= l.state.page_entries.len);
        assert(l.state.page_read != null); // Read since loaded
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
        const ix = s.opened() orelse return;
        if (page_index >= library_ui.page_count(s.count)) return; // Past the last page
        const range = library_ui.page_range(page_index, s.count);
        var ids: [library_ui.page_books_max]u32 = undefined;
        const filled = view.page(l.sorted(ix), range.first, range.end, &ids);
        assert(filled == range.end - range.first);
        for (ids[0..filled]) |id| _ = pool.grid_cover(ix.entry(id).thumbnail);
        assert(range.end <= s.count);
    }

    /// Saves what reading (or marking) a book changed of it, read back from this
    /// library: its record is written in place, and the books sorted again when next
    /// looked through.
    pub fn save(l: *Library, e: *const catalog.Entry) void {
        const s = l.state;
        assert(e.is_local()); // Only a book on the Kindle is read or marked
        const ix = s.opened() orelse return;
        const id = l.id_of(e) orelse return;
        assert(id < ix.header.count);
        var r = ix.record(id);
        r.percent = @intCast(@min(e.percent, 100));
        r.last = e.last;
        r.seconds_read = e.seconds_read;
        if (e.finished) r.flags |= index.Record.finished else r.flags &= ~index.Record.finished;
        ix.write_record(id, &r) catch |err| {
            // What reading changed is in its state file too, saved as the book closed:
            // every load merges those into the index (`builder.merge_states`), so the
            // next one puts it right, the index and every EPUB it has read kept as is
            log("library: place not saved ({s}), merged at the next load\n", .{@errorName(err)});
            return;
        };
        s.sorted = false;
    }

    /// Which record a book read back from this library is, by where it was read into.
    fn id_of(l: *Library, e: *const catalog.Entry) ?u32 {
        const s = l.state;
        assert(s.ix != null); // Books are read back only from an open index
        for (s.page_entries[0..s.page_filled], s.page_slots[0..s.page_filled]) |*p, *slot| {
            if (p == e) return slot.id;
        }
        for (s.search_entries[0..s.search_filled], s.search_slots[0..s.search_filled]) |*p, *slot| {
            if (p == e) return slot.id;
        }
        if (e == &s.hero_slot.entry) return s.hero_slot.id;
        for (&s.next_slots) |*slot| {
            if (e == &slot.entry) return slot.id;
        }
        assert(s.page_filled <= s.page_slots.len);
        return null;
    }

    /// The next book of `e`'s series not read yet, read back, or null.
    pub fn next_in_series(l: *Library, e: *const catalog.Entry) ?*catalog.Entry {
        const s = l.state;
        const ix = s.opened() orelse return null;
        s.next_turn +%= 1;
        const slot = &s.next_slots[s.next_turn];
        assert(&slot.entry != e); // Each next goes in the other slot
        const id = catalog.next_in_series(view.ById{ .ix = ix }, e) orelse return null;
        ix.read(id, slot);
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
        const ix = s.opened() orelse return .{ .entries = &.{}, .more = false };
        var ids: [search_sheet.max_rows]u32 = undefined;
        const found = view.first_matches(ix, l.sorted(ix), words, &ids);
        const shown = @min(found, ids.len);
        for (ids[0..shown], s.search_slots[0..shown], s.search_entries[0..shown]) |id, *slot, *e| {
            ix.read(id, slot);
            e.* = slot.entry;
        }
        s.search_filled = shown;
        assert(shown <= search_sheet.max_rows);
        return .{ .entries = s.search_entries[0..shown], .more = found > shown };
    }

    /// What the stats screen counts of the library, this year being from `year_start`.
    pub fn totals(l: *Library, year_start: i32, utc_offset: i64) view.Totals {
        const s = l.state;
        const ix = s.opened() orelse return .{};
        const t = view.totals(ix, year_start, utc_offset, journal.day_of);
        assert(t.books == ix.header.count);
        return t;
    }

    /// The books on this Kindle, each copied into `alloc` with its texts: for the
    /// series screens, which list them. An error when `alloc` runs out of room.
    pub fn local_books(l: *Library, alloc: std.mem.Allocator) ![]catalog.Entry {
        const s = l.state;
        const ix = s.opened() orelse return &.{};
        assert(ix.header.local <= ix.header.count);
        var list: std.ArrayList(catalog.Entry) = .empty;
        try list.ensureTotalCapacity(alloc, ix.header.local);
        for (0..ix.header.count) |id| {
            const e = ix.entry(@intCast(id));
            if (!e.is_local()) continue;
            var copy = e;
            copy.path = try alloc.dupeSentinel(u8, e.path, 0);
            copy.title = try alloc.dupe(u8, e.title);
            copy.author = try alloc.dupe(u8, e.author);
            if (e.series) |series| {
                copy.series = .{ .name = try alloc.dupe(u8, series.name), .index = series.index };
            }
            copy.thumbnail = null;
            copy.key = "";
            copy.kind = "";
            copy.guid = "";
            list.appendAssumeCapacity(copy);
        }
        assert(list.items.len == ix.header.local);
        return list.items;
    }

    /// Reads the library again, in place: its index built again first if what it's
    /// built from changed; then arranged as it was, and the page last read read again.
    pub fn reload(l: *Library) void {
        const s = l.state;
        assert(l.shared.in_use);
        if (s.opened()) |ix| ix.close();
        s.ix = null;
        s.sorted = false;
        open_index(l.sources, s);
        l.lay_out();
        assert(s.sorted == (s.ix != null)); // Laid out once there's an index to lay out
        // The page last read, if it's still a page: the library may have fewer now
        if (s.page_read) |read| {
            if (read < library_ui.page_count(s.count)) _ = l.page(read);
        }
    }
};

pub fn load_library(a: *app.App) !Library {
    assert(a.regions.library_budget.limit > 0);
    assert(a.regions.library_scratch.kind == .bump);
    return load(.{
        .shared = &a.regions.library_shared,
        .budget = &a.regions.library_budget,
        .scratch = &a.regions.library_scratch,
        .catalog_path = a.library_path,
        .documents = a.documents,
        .state_dir = a.state_dir,
        .heartbeat = paths.heartbeat,
    });
}

/// The library: its index, built again first if what it's built from changed, or it
/// doesn't read as whole; then what noface saved of each book merged in.
pub fn load(sources: Sources) !Library {
    assert(sources.scratch.empty());
    assert(sources.state_dir.len > 0);
    assert(!sources.shared.in_use); // One library at a time: they share the items
    const s = try sources.budget.allocator().create(State);
    errdefer sources.budget.allocator().destroy(s);
    s.* = .{};
    const format = "{s}/library";
    const folder = try std.fmt.bufPrintSentinel(&s.dir_buffer, format, .{sources.state_dir}, 0);
    _ = calls.mkdir(folder, 0o755); // Ignored: there already, or the build says it can't write
    s.dir_len = @intCast(folder.len);
    sources.shared.in_use = true;
    open_index(sources, s);
    return .{ .shared = sources.shared, .sources = sources, .state = s };
}

/// Opens `s`'s index, built again first if what it's built from changed, or it doesn't
/// read as whole; then merges in what noface saved of each book.
fn open_index(sources: Sources, s: *State) void {
    assert(s.ix == null);
    assert(sources.scratch.empty());
    // Before the list is read, so a change made while it's read shows next time
    s.catalog_seen = CatalogFacts.read();
    var scratch = memory.Budget{
        .name = "library scratch",
        .region = sources.scratch,
        .limit = sources.scratch.bytes.len,
    };
    defer scratch.reset(.give_back);
    const places: builder.Places = .{
        .catalog_path = sources.catalog_path,
        .documents = sources.documents,
        .state_dir = sources.state_dir,
        .dir = s.dir(),
        .heartbeat = sources.heartbeat,
    };
    const items = sources.shared.items;
    const wanted = builder.sources_now(&scratch, places);
    var last: ?index.Index = index.Index.open(places.dir) catch null;
    if (last) |*ix| {
        if (std.meta.eql(ix.header.sources, wanted)) s.ix = ix.*;
    }
    if (s.ix == null) {
        const t0 = os.now_us();
        const buffers = &sources.shared.buffers;
        const was = if (last) |*ix| ix else null;
        const built = builder.build(buffers, items, &scratch, places, wanted, was) catch |err| {
            log("library: no index ({s})\n", .{@errorName(err)});
            return;
        };
        s.ix = built;
        const ms = (os.now_us() - t0) / 1000;
        log("library: index built, {d} books in {d} ms\n", .{ built.header.count, ms });
    }
    const ix = s.opened().?; // Opened as it was, or just built
    builder.merge_states(ix, items, places) catch |err| {
        log("library: places not merged ({s})\n", .{@errorName(err)});
    };
    s.sorted = false; // The items were sorted by state key
    assert(ix.header.count <= books_max);
}

/// A line for the log, but not from the tests, where it would read as a failure.
fn log(comptime format: []const u8, args: anytype) void {
    assert(format.len > 0);
    assert(format[format.len - 1] == '\n');
    if (!builtin.is_test) std.debug.print(format, args);
}

/// An EPUB titled `title` with a cover of `cover_bytes`, in Calibre's `series` if one
/// is given, its files stored as they are.
fn test_epub(
    alloc: std.mem.Allocator,
    title: []const u8,
    cover_bytes: u32,
    series: ?[]const u8,
) ![]u8 {
    assert(title.len > 0);
    assert(cover_bytes > 0);
    var meta_buffer: [128]u8 = undefined;
    const meta_format = "<meta name=\"calibre:series\" content=\"{s}\"/>";
    const meta = if (series) |s| try std.fmt.bufPrint(&meta_buffer, meta_format, .{s}) else "";
    const opf = try std.fmt.allocPrint(alloc,
        \\<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        \\<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{s}</dc:title>
        \\<dc:creator>Test Author</dc:creator>{s}</metadata><manifest>
        \\<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
        \\<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
        \\</manifest><spine><itemref idref="c1"/></spine></package>
    , .{ title, meta });
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
        const data = try test_epub(alloc, name, cover_bytes, null);
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
    shared: *view.Shared,
    paths: [3][320]u8,
    sources: Sources,

    fn init(t: *TestLibrary, root: []const u8) !void {
        assert(root.len > 0);
        t.region = try .reserve("library", .heap, setup.region_bytes.library);
        t.budget = .{ .name = "library", .region = &t.region, .limit = t.region.bytes.len };
        t.scratch = try .reserve("library scratch", .bump, setup.region_bytes.library_scratch);
        t.shared = try t.budget.allocator().create(view.Shared);
        try t.shared.init(&t.budget);
        t.sources = .{
            .shared = t.shared,
            .budget = &t.budget,
            .scratch = &t.scratch,
            .catalog_path = try std.fmt.bufPrintSentinel(&t.paths[0], "{s}/catalog", .{root}, 0),
            .documents = try std.fmt.bufPrint(&t.paths[1], "{s}/documents", .{root}),
            .state_dir = try std.fmt.bufPrint(&t.paths[2], "{s}/state", .{root}),
            .heartbeat = null,
        };
        assert(t.budget.live > 0); // The shared buffers, for good
    }

    fn deinit(t: *TestLibrary) void {
        assert(t.scratch.empty());
        assert(!t.shared.in_use);
        t.scratch.release();
        t.region.release();
    }

    /// A path in the test library's data folder.
    fn data_path(t: *const TestLibrary, buffer: []u8, name: []const u8) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buffer, "{s}/{s}", .{ t.sources.state_dir, name }, 0);
    }
};

/// Every book of `library` in its arrangement, by title, for the tests.
fn test_titles(library: *Library, alloc: std.mem.Allocator) ![][]const u8 {
    assert(library.shared.in_use);
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
    var library = try load(t.sources);
    defer library.deinit();
    library.arrange(.title, .all, "");
    const listed = library.count() + @intFromBool(library.hero() != null);
    try std.testing.expectEqual(@as(u32, epubs), listed);
    try std.testing.expect(library.page(0)[0].thumbnail != null); // Its cover saved, and found
    // A library takes the same, whatever it holds
    try std.testing.expectEqual(before + library_bytes, t.budget.live);
    // Built again (an EPUB more), with every book read before now unreadable: what the
    // last build read of each is kept, so none is opened again
    var path_buffer: [320]u8 = undefined;
    var name_buffer: [32]u8 = undefined;
    for (0..epubs) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "documents/Book {d}.epub", .{i});
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/{s}", .{ root, name }, 0);
        _ = std.c.chmod(path, 0); // Ignored: a book still readable is read again, and listed
    }
    const extra = try test_epub(std.testing.allocator, "Extra", 1 << 10, null);
    defer std.testing.allocator.free(extra);
    const extra_path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/documents/Extra.epub", .{
        root,
    }, 0);
    try test_write(extra_path, extra);
    library.reload();
    library.arrange(.title, .all, "");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const titles = try test_titles(&library, arena.allocator());
    try std.testing.expectEqual(@as(u32, epubs + 1), library.count() + 1); // The hero too
    for (titles) |title| try std.testing.expect(std.mem.startsWith(u8, title, "Book ") or
        std.mem.eql(u8, title, "Extra"));
}

test "a build beats the watchdog only once a beat's interval has passed since it started" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 20, 3, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var beat_buffer: [320]u8 = undefined;
    const beat_path = try t.data_path(&beat_buffer, "alive");
    t.sources.heartbeat = beat_path;
    // Its clock starts with the build, not at 0: a build quicker than a beat's interval
    // (every one in the tests) never writes it, so the scenarios leave the Kindle's alone
    var library = try load(t.sources);
    defer library.deinit();
    library.arrange(.title, .all, "");
    try std.testing.expectEqual(23, library.count() + @intFromBool(library.hero() != null));
    try std.testing.expect(!file.exists(beat_path));
}

test "an EPUB whose cover couldn't be saved is listed without one, not with a missing file" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 0, 1, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    // A folder where the cover's new file goes: writing it fails, as on a full drive
    var book_buffer: [320]u8 = undefined;
    var state_buffer: [320]u8 = undefined;
    var cover_buffer: [320]u8 = undefined;
    var tmp_buffer: [320]u8 = undefined;
    const book = try std.fmt.bufPrint(&book_buffer, "{s}/documents/Book 0.epub", .{root});
    const state_path = try state.path_for(&state_buffer, t.sources.state_dir, book);
    const cover = try state.sibling(&cover_buffer, state_path, "cover");
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buffer, "{s}.tmp", .{cover}, 0);
    try std.testing.expect(!os.failed(calls.mkdir(tmp, 0o755)));
    var library = try load(t.sources);
    defer library.deinit();
    library.arrange(.title, .all, "");
    const listed = library.hero() orelse &library.page(0)[0];
    try std.testing.expectEqualStrings("Book 0", listed.title);
    try std.testing.expect(!file.exists(cover));
    try std.testing.expectEqual(null, listed.thumbnail);
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

test "an EPUB's own series is listed when its package is stored, not deflated" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 0, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    // Its package read in the book's file itself, which is let go of before it's listed
    const data = try test_epub(std.testing.allocator, "Dune", 1 << 10, "The Dune Saga");
    defer std.testing.allocator.free(data);
    var path_buffer: [320]u8 = undefined;
    try test_write(try std.fmt.bufPrintSentinel(&path_buffer, "{s}/documents/Dune.epub", .{
        root,
    }, 0), data);
    var library = try load(t.sources);
    defer library.deinit();
    library.arrange(.title, .all, "");
    _ = library.page(0);
    const listed = library.hero() orelse library.book(0);
    try std.testing.expectEqualStrings("Dune", listed.title);
    try std.testing.expectEqualStrings("The Dune Saga", listed.series.?.name);
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

test "an index torn, damaged or cut short is built again as it's loaded" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 50, 3, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var good = try load(t.sources);
    good.arrange(.author, .all, "");
    const count = good.count();
    const generation = good.shelf().generation;
    good.deinit();
    var records_buffer: [320]u8 = undefined;
    var header_buffer: [320]u8 = undefined;
    const records_path = try t.data_path(&records_buffer, "library/records");
    const header_path = try t.data_path(&header_buffer, "library/header");
    // Half a record written over, as by power lost in the middle of saving a place; a
    // header changed by a byte; records cut short, as by a crash writing them
    const torn: [32]u8 = @splat(0x55);
    const record_bytes = @sizeOf(index.Record);
    const damage = [_]struct { path: [:0]const u8, at: u64, bytes: []const u8 }{
        .{ .path = records_path, .at = index.file_head_bytes + 7 * record_bytes, .bytes = &torn },
        .{ .path = header_path, .at = 20, .bytes = "x" },
    };
    var last = generation;
    for (damage) |d| {
        try std.testing.expect(files.write_at(d.path, d.at, d.bytes));
        var rebuilt = try load(t.sources);
        defer rebuilt.deinit();
        rebuilt.arrange(.author, .all, "");
        try std.testing.expectEqual(count, rebuilt.count());
        try std.testing.expect(rebuilt.shelf().generation != last);
        last = rebuilt.shelf().generation;
    }
    const records = try file.map(records_path);
    const shorter = try std.testing.allocator.dupe(u8, records[0 .. records.len - 10]);
    file.unmap(records);
    defer std.testing.allocator.free(shorter);
    try test_write(records_path, shorter);
    var rebuilt = try load(t.sources);
    defer rebuilt.deinit();
    rebuilt.arrange(.author, .all, "");
    try std.testing.expectEqual(count, rebuilt.count());
}

test "a build whose files can't be put in place leaves the library empty, not crashed" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 5, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    // A folder where the records go: renaming the new ones over it fails, as on a
    // drive that's full, after both new files were written and closed
    var dir_buffer: [320]u8 = undefined;
    var records_buffer: [320]u8 = undefined;
    _ = calls.mkdir(try t.data_path(&dir_buffer, "library"), 0o755);
    const records_path = try t.data_path(&records_buffer, "library/records");
    _ = calls.mkdir(records_path, 0o755);
    var library = try load(t.sources);
    defer library.deinit();
    try std.testing.expect(library.state.ix == null);
    try std.testing.expectEqual(0, library.count());
    // Built once as it loaded: arranging it, or watching a download by a timer, doesn't
    // build again what failed, though now it would take
    try std.testing.expectEqual(0, std.c.rmdir(records_path));
    library.arrange(.title, .all, "");
    try std.testing.expect(library.state.ix == null);
    try std.testing.expectEqual(Download.waiting, library.watch_download());
    try std.testing.expect(library.state.ix == null);
    // A reload, as an action or a wake makes, tries once more
    library.reload();
    try std.testing.expect(library.state.ix != null);
    try std.testing.expectEqual(5, library.count() + @intFromBool(library.hero() != null));
}

test "every order lists the books as the catalog sorts the same books in a list" {
    var buffer: [64]u8 = undefined;
    const root = try test_folder(&buffer, 0, 0, 1 << 10);
    defer test_folder_remove(root);
    var t: TestLibrary = undefined;
    try t.init(root);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Series by file name, authors, places and dates mixed, some on the cloud
    var rows: std.ArrayList(u8) = .empty;
    for (0..120) |i| {
        const row = "{s}/documents/T{d} -- A -- Saga {d} #{d} -- Z.kfx\tTitle {d}\t" ++
            "Author{d}, Some\t{d}\t{d}\t0\t\t{d}\t{d}\n";
        const percent = (i * 37) % 120;
        const series = .{ i % 7, i % 5 + 1 };
        const cloud = @intFromBool(i % 9 == 0);
        // Some read past 2106, as only a broken catalog says: they sort alike either way
        const last: u64 = if (i % 13 == 0) (1 << 32) + @as(u64, i) else i * 997 % 5000;
        try rows.print(alloc, row, .{
            root, i, series[0], series[1], i, i % 11, percent, last, i * 31, cloud,
        });
    }
    try test_write(t.sources.catalog_path, rows.items);
    var library = try load(t.sources);
    defer library.deinit();
    const entries = blk: {
        library.arrange(.recent, .all, "");
        var all: std.ArrayList(catalog.Entry) = .empty;
        const ix = library.state.ix.?;
        for (0..ix.header.count) |id| {
            const e = ix.entry(@intCast(id));
            var copy = e;
            copy.title = try alloc.dupe(u8, e.title);
            copy.path = try alloc.dupeSentinel(u8, e.path, 0);
            copy.author = try alloc.dupe(u8, e.author);
            if (e.series) |series| {
                copy.series = .{ .name = try alloc.dupe(u8, series.name), .index = series.index };
            }
            try all.append(alloc, copy);
        }
        break :blk all.items;
    };
    for (std.enums.values(catalog.Order)) |order| {
        library.arrange(order, .all, "");
        const listed = try test_titles(&library, alloc);
        catalog.sort(entries, order);
        const hero_title = library.hero().?.title;
        var at: u32 = 0;
        for (entries) |e| {
            if (std.mem.eql(u8, e.title, hero_title)) continue; // The hero, ahead of them
            try std.testing.expectEqualStrings(e.title, listed[at]);
            at += 1;
        }
        try std.testing.expectEqual(listed.len, at);
    }
}

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
