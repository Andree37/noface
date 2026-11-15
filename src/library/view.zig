//! Looking through the library's index (index.zig): every book's id sorted in memory,
//! 8 bytes a book, by the same comparisons `model/catalog.zig` sorts a list with; then,
//! beside each, how many of the books up to it the filter and search let through, so
//! the page shown is found by halves. The rest (the book to continue, a series' next,
//! the totals for the stats) are each one pass over the records.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const memory = @import("../base/memory.zig");
const index = @import("index.zig");
const builder = @import("builder.zig");

const Item = index.Item;

/// What the library uses beside its books read back, taken once at startup: an item for
/// every book it can hold, and the buffers a build writes through. One library uses
/// them at a time.
pub const Shared = struct {
    items: []Item,
    buffers: builder.Buffers,
    in_use: bool = false,

    /// What `init` takes, at most, its blocks rounded up to whole units of the region.
    pub const bytes_max: u64 = @as(u64, index.books_max) * @sizeOf(Item) +
        builder.Buffers.bytes_max + memory.unit_bytes;

    pub fn init(s: *Shared, budget: *memory.Budget) !void {
        s.* = .{
            .items = try budget.untouched(Item, index.books_max),
            .buffers = try builder.Buffers.init(budget),
        };
        assert(s.items.len == index.books_max);
        assert(!s.in_use);
    }
};

/// What a filter and a search let through.
pub const Look = struct {
    filter: catalog.Filter,
    words: []const u8, // Empty: no search
};

/// Every book of `ix` in `items`, sorted by `order`: the first `count` of them.
pub fn sort(ix: *const index.Index, items: []Item, order: catalog.Order) []Item {
    assert(items.len >= ix.header.count);
    const sorted = items[0..ix.header.count];
    for (sorted, 0..) |*item, id| item.* = .{ .id = @intCast(id), .key = 0 };
    catalog.sort_by(Item, sorted, order, Books{ .ix = ix });
    return sorted;
}

/// The books of an index, for `catalog.sort_by`: an item's key is when its series was
/// last read, in seconds since 1970, which a u32 holds until 2106.
const Books = struct {
    ix: *const index.Index,

    pub fn entry(b: Books, item: Item) catalog.Entry {
        var e = b.ix.entry(item.id);
        e.series_last = item.key;
        return e;
    }

    pub fn set_series_last(_: Books, item: *Item, last: u64) void {
        item.key = @intCast(@min(last, std.math.maxInt(u32)));
        assert(item.key <= last);
    }
};

/// Sets each item's key to how many of the books up to it `look` lets through, but
/// `leave_out`: how many in all.
pub fn count_through(
    ix: *const index.Index,
    sorted: []Item,
    look: Look,
    leave_out: ?u32,
) u32 {
    assert(sorted.len == ix.header.count);
    var through: u32 = 0;
    for (sorted) |*item| {
        if (item.id != leave_out and lets_through(ix.entry(item.id), look)) through += 1;
        item.key = through;
    }
    assert(through <= sorted.len);
    return through;
}

fn lets_through(e: catalog.Entry, look: Look) bool {
    assert(e.percent <= 100);
    const by_filter = switch (look.filter) {
        .all => true,
        .read => e.is_read(),
        .unread => !e.is_read(),
    };
    return by_filter and (look.words.len == 0 or catalog.matches_query(e, look.words));
}

/// The ids of the books let through from the `first`th to before the `end`th, in order,
/// into `ids`: how many. `sorted` holds their counts, as `count_through` set them.
pub fn page(sorted: []const Item, first: u32, end: u32, ids: []u32) u32 {
    assert(first <= end);
    assert(end - first <= ids.len);
    // The first book let through after `first` others: its count is `first + 1`
    var at = std.sort.lowerBound(Item, sorted, first + 1, struct {
        fn order(through: u32, item: Item) std.math.Order {
            return std.math.order(through, item.key);
        }
    }.order);
    var filled: u32 = 0;
    var before: u32 = first;
    for (sorted[at..]) |item| {
        if (filled == end - first) break;
        at += 1;
        if (item.key == before) continue; // Not let through: its count is the last one's
        assert(item.key == before + 1);
        ids[filled] = item.id;
        filled += 1;
        before = item.key;
    }
    assert(filled <= end - first);
    return filled;
}

/// The book to continue: the latest one in progress on this Kindle, or else the latest
/// opened, as `catalog.pick_hero` picks from a list.
pub fn hero(ix: *const index.Index) ?u32 {
    assert(ix.header.local <= ix.header.count);
    var going: ?u32 = null;
    var going_last: u64 = 0;
    var latest: ?u32 = null;
    var latest_last: u64 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const e = ix.entry(id);
        if (!e.is_local()) continue;
        if (e.in_progress() and (going == null or e.last > going_last)) {
            going = id;
            going_last = e.last;
        }
        if (latest == null or e.last > latest_last) {
            latest = id;
            latest_last = e.last;
        }
    }
    const found = going orelse latest orelse return null;
    assert(ix.entry(found).is_local()); // A cloud book can't be opened from the hero
    if (going) |g| assert(ix.entry(g).in_progress());
    return found;
}

/// The ids of the first `ids.len` books of `sorted` whose title, author or series has
/// `words`: how many there are, up to one more than fit.
pub fn first_matches(
    ix: *const index.Index,
    sorted: []const Item,
    words: []const u8,
    ids: []u32,
) u32 {
    assert(words.len > 0);
    assert(ids.len > 0);
    var found: u32 = 0;
    for (sorted) |item| {
        if (!catalog.matches_query(ix.entry(item.id), words)) continue;
        if (found == ids.len) return found + 1; // More than fit
        ids[found] = item.id;
        found += 1;
    }
    assert(found <= ids.len);
    return found;
}

/// What the stats screen counts of the library, in one pass over the records.
pub const Totals = struct {
    books: u32 = 0,
    finished: u32 = 0,
    in_progress: u32 = 0,
    finished_this_year: u32 = 0,
    seconds_this_year: u64 = 0,
};

/// The library's totals; "this year" is from `year_start`, a day as the journal counts
/// them, by `day_of`.
pub fn totals(
    ix: *const index.Index,
    year_start: i32,
    utc_offset: i64,
    comptime day_of: fn (u64, i64) i32,
) Totals {
    var t: Totals = .{};
    for (0..ix.header.count) |i| {
        const e = ix.entry(@intCast(i));
        t.books += 1;
        if (e.is_read()) t.finished += 1;
        if (e.in_progress()) t.in_progress += 1;
        if (e.last == 0 or day_of(e.last, utc_offset) < year_start) continue;
        if (e.is_read()) t.finished_this_year += 1;
        t.seconds_this_year += e.seconds_read;
    }
    assert(t.books == ix.header.count);
    assert(t.finished + t.in_progress <= t.books);
    return t;
}

/// The next book of `e`'s series not yet read, by its place in the series, as
/// `catalog.next_in_series` finds it in a list.
pub fn next_in_series(ix: *const index.Index, e: *const catalog.Entry) ?u32 {
    assert(ix.header.count <= index.books_max);
    if (e.series.len == 0) return null;
    const place = catalog.series_place(e.*);
    var best: ?u32 = null;
    var best_place: f32 = 0;
    for (0..ix.header.count) |i| {
        const id: u32 = @intCast(i);
        const o = ix.entry(id);
        if (!catalog.same_series(o.series, e.series)) continue;
        const o_place = catalog.series_place(o);
        if (o_place <= place or o.is_read()) continue;
        if (best == null or o_place < best_place) {
            best = id;
            best_place = o_place;
        }
    }
    const found = best orelse return null;
    assert(!ix.entry(found).is_read());
    return found;
}
