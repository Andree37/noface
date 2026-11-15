//! Each library order as a key of bytes: the books sort as their keys compare, byte by
//! byte, which is what lets the sorter sort them on the drive. Each key says, in order
//! of weight, what the order's comparison in `model/catalog.zig` looks at: a number
//! big-endian (inverted for newest first), text lowercased as ASCII and ended by a 0.
//! The tests check every order against the comparisons, so the two can't drift apart.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("../model/catalog.zig");
const sorter = @import("sorter.zig");

/// The longest text a key holds of a title, author or series: what the library keeps.
pub const text_bytes_max: u32 = 256;

comptime {
    // The longest key: by author, then title as by title
    const author_key = 1 + 1 + 2 * (text_bytes_max + 1);
    const title_key = 2 * (text_bytes_max + 1) + 1 + 4;
    assert(author_key + title_key <= sorter.key_bytes_max);
}

/// Builds a key in a buffer of `sorter.key_bytes_max`.
pub const Key = struct {
    buffer: *[sorter.key_bytes_max]u8,
    len: u32 = 0,

    pub fn bytes(k: *const Key) []const u8 {
        assert(k.len <= k.buffer.len);
        assert(k.len > 0); // Built before it's read
        return k.buffer[0..k.len];
    }

    fn byte(k: *Key, value: u8) void {
        assert(k.len < k.buffer.len);
        k.buffer[k.len] = value;
        k.len += 1;
        assert(k.buffer[k.len - 1] == value);
    }

    fn number(k: *Key, comptime T: type, value: T) void {
        comptime assert(@typeInfo(T) == .int);
        assert(k.len + @sizeOf(T) <= k.buffer.len);
        std.mem.writeInt(T, k.buffer[k.len..][0..@sizeOf(T)], value, .big);
        k.len += @sizeOf(T);
    }

    /// Text compared ignoring ASCII case, as `std.ascii.lessThanIgnoreCase` does: each
    /// byte lowered, then a 0, so a text sorts before any it begins. A 0 inside (outside
    /// data) is written as a 1, so the text still ends where its 0 is.
    fn text(k: *Key, value: []const u8) void {
        const kept = value[0..@min(value.len, text_bytes_max)];
        assert(k.len + kept.len + 1 <= k.buffer.len);
        for (kept) |c| k.byte(if (c == 0) 1 else std.ascii.toLower(c));
        k.byte(0);
        assert(std.mem.indexOfScalar(u8, k.buffer[k.len - kept.len - 1 .. k.len], 0).? == kept.len);
    }

    /// A place in a series, or after every number when it isn't one: an f32 that isn't
    /// negative sorts as its bits.
    fn place(k: *Key, e: *const catalog.Entry) void {
        const value = catalog.series_place(e.*);
        assert(!std.math.isNan(value)); // Not a number sorts as after every number
        assert(value >= 0); // A place is never below 0, as read
        k.number(u32, @bitCast(@abs(value)));
    }

    /// The books on this Kindle first, as every order but by series has it.
    fn local_first(k: *Key, e: *const catalog.Entry) void {
        assert(k.len == 0);
        k.byte(if (e.is_local()) 0 else 1);
        assert(k.len == 1);
    }
};

/// `e`'s key for `order`, but by series, which takes two passes (`series_first`, then
/// `series_second`): each series sorts by when any of it was last read.
pub fn of(k: *Key, order: catalog.Order, e: *const catalog.Entry) void {
    assert(order != .series);
    assert(k.len == 0);
    k.local_first(e);
    switch (order) {
        .recent => k.number(u64, ~e.last),
        .added => k.number(u64, ~e.added),
        .progress => {
            const stage = catalog.stage(e.*);
            k.byte(stage);
            k.byte(if (stage == 0) ~@as(u8, @intCast(@min(e.percent, 255))) else 0);
            k.number(u64, ~e.last);
        },
        .title => title_part(k, e),
        .author => {
            const surname = catalog.surname(e.author);
            k.byte(if (surname.len == 0) 1 else 0); // No author last
            k.text(surname);
            k.text(e.author);
            title_part(k, e);
        },
        .series => unreachable,
    }
    assert(k.len > 1);
}

/// By title: the series or title it sorts under, the books outside a series first, then
/// the series in its order, then by title.
fn title_part(k: *Key, e: *const catalog.Entry) void {
    const start = k.len;
    k.text(catalog.title_key(e.*));
    k.byte(if (e.series.len > 0) 1 else 0);
    if (e.series.len > 0) k.place(e) else k.number(u32, 0);
    k.text(e.title);
    assert(k.len > start + 5);
    assert(k.buffer[k.len - 1] == 0); // Ended by its title's 0
}

/// The first pass by series, for a book in one: its series, when it was last read (a
/// book opened, else never), then its place and title. Sorted, each series is one run,
/// its latest reading first: what `series_second` puts ahead of each of its books.
pub fn series_first(k: *Key, e: *const catalog.Entry) void {
    assert(e.series.len > 0);
    assert(k.len == 0);
    k.text(catalog.series_key(e.*));
    k.number(u64, ~(if (e.was_opened()) e.last else 0));
    k.place(e);
    k.text(e.title);
}

/// The length of the series' name at the start of a `series_first` key, its 0 included:
/// keys with the same name are the same series.
pub fn series_name_len(first: []const u8) u32 {
    const end = std.mem.indexOfScalar(u8, first, 0).?; // `series_first` ended it with one
    assert(end + 1 + 8 <= first.len);
    assert(end <= text_bytes_max);
    return @intCast(end + 1);
}

/// The key by series of a book whose `series_first` key is `first`, its series last
/// read at `series_last`: the series read most lately first, then by name, then each
/// book by place and title.
pub fn series_second(k: *Key, first: []const u8, series_last: u64) void {
    assert(k.len == 0);
    const name_len = series_name_len(first);
    k.byte(0); // Books in a series before those outside one
    k.number(u64, ~series_last);
    const rest = first[name_len + 8 ..]; // Without its own reading time
    assert(k.len + name_len + rest.len <= k.buffer.len);
    @memcpy(k.buffer[k.len..][0..name_len], first[0..name_len]);
    k.len += name_len;
    @memcpy(k.buffer[k.len..][0..rest.len], rest);
    k.len += @intCast(rest.len);
}

/// The key by series of a book outside any: after every series, most recent first.
pub fn series_none(k: *Key, e: *const catalog.Entry) void {
    assert(e.series.len == 0);
    assert(k.len == 0);
    k.byte(1);
    k.number(u64, ~e.last);
}

/// Whether, by keys, `a` sorts no later than `b` (index order breaking ties, as the
/// sorter does), for the tests.
fn test_keys_sort(entries: []catalog.Entry, order: catalog.Order, out: []u32) !void {
    const alloc = std.testing.allocator;
    assert(out.len == entries.len);
    assert(entries.len > 0);
    const keys = try alloc.alloc([sorter.key_bytes_max]u8, entries.len);
    defer alloc.free(keys);
    const lens = try alloc.alloc(u32, entries.len);
    defer alloc.free(lens);
    if (order == .series) {
        // Each book's series' latest reading, as the sorter's first pass finds it
        for (entries, keys, lens) |*e, *buffer, *len| {
            var k: Key = .{ .buffer = buffer };
            if (e.series.len == 0) {
                series_none(&k, e);
            } else {
                var latest: u64 = 0;
                for (entries) |o| {
                    if (catalog.same_series(o.series, e.series) and o.was_opened()) {
                        latest = @max(latest, o.last);
                    }
                }
                var first_buffer: [sorter.key_bytes_max]u8 = undefined;
                var first: Key = .{ .buffer = &first_buffer };
                series_first(&first, e);
                series_second(&k, first.bytes(), latest);
            }
            len.* = k.len;
        }
    } else {
        for (entries, keys, lens) |*e, *buffer, *len| {
            var k: Key = .{ .buffer = buffer };
            of(&k, order, e);
            len.* = k.len;
        }
    }
    for (out, 0..) |*o, i| o.* = @intCast(i);
    const Context = struct {
        keys: [][sorter.key_bytes_max]u8,
        lens: []u32,
        fn less(c: @This(), a: u32, b: u32) bool {
            assert(a < c.lens.len);
            assert(b < c.lens.len);
            const order_ab = std.mem.order(u8, c.keys[a][0..c.lens[a]], c.keys[b][0..c.lens[b]]);
            return order_ab == .lt or (order_ab == .eq and a < b);
        }
    };
    std.mem.sort(u32, out, Context{ .keys = keys, .lens = lens }, Context.less);
}

test "every order's keys sort the books as the library's comparisons do" {
    const alloc = std.testing.allocator;
    const titles = [_][]const u8{ "Dune", "dune", "The Hobbit", "Artemis", "zed", "", "Ünder" };
    const authors = [_][]const u8{ "", "Andy Weir", "Weir, Andy", "Adams, Douglas", "Plato" };
    const series = [_][]const u8{ "", "", "Saga", "the saga", "Dune", "Other" };
    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    var entries: [200]catalog.Entry = undefined;
    for (&entries) |*e| {
        e.* = .{
            .path = "/b",
            .title = titles[random.uintLessThan(u32, titles.len)],
            .author = authors[random.uintLessThan(u32, authors.len)],
            .percent = random.uintLessThan(u32, 101),
            .last = random.uintLessThan(u64, 50),
            .added = random.uintLessThan(u64, 50),
            .seconds_read = if (random.boolean()) 10 else 0,
            .availability = if (random.uintLessThan(u32, 4) == 0) .cloud else .local,
            .series = series[random.uintLessThan(u32, series.len)],
            .series_index = if (random.uintLessThan(u32, 9) == 0)
                std.math.nan(f32)
            else
                @floatFromInt(random.uintLessThan(u32, 5)),
        };
    }
    const order_by_keys = try alloc.alloc(u32, entries.len);
    defer alloc.free(order_by_keys);
    for (std.enums.values(catalog.Order)) |order| {
        var sorted = entries;
        catalog.sort(&sorted, order);
        try test_keys_sort(&entries, order, order_by_keys);
        // The same order, but for books the comparison finds equal, which either may
        // put first: each by keys never comes before one the comparison puts first
        for (order_by_keys, 0..) |id, i| {
            const by_keys = entries[id];
            const by_sort = sorted[i];
            var copy = sorted;
            const tie = !catalog_before(order, &copy, by_keys, by_sort) and
                !catalog_before(order, &copy, by_sort, by_keys);
            try std.testing.expect(tie);
        }
    }
}

/// The library's comparison of two books in `order`, its series times set from `all`.
fn catalog_before(
    order: catalog.Order,
    all: []catalog.Entry,
    a: catalog.Entry,
    b: catalog.Entry,
) bool {
    assert(all.len > 0);
    assert(a.path.len > 0);
    var pair = [_]catalog.Entry{ a, b };
    if (order == .series) {
        for (&pair) |*p| {
            p.series_last = 0;
            if (p.series.len == 0) continue;
            for (all) |o| {
                if (catalog.same_series(o.series, p.series) and o.was_opened()) {
                    p.series_last = @max(p.series_last, o.last);
                }
            }
        }
    }
    return catalog.before_in(order, pair[0], pair[1]);
}
