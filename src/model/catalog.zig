//! The library catalog: the books on this Kindle and in the cloud, how they sort,
//! filter, and which one leads the home screen. Plain data, no drawing.
const std = @import("std");
const assert = std.debug.assert;
const search = @import("search.zig");
const unicode = @import("../text/unicode.zig");
const stats = @import("stats.zig");

pub const Availability = enum { local, cloud, downloading };

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
    finished: bool = false,
    seconds_read: u64 = 0, // Time spent reading it in noface
    /// Words from its place to its end, as noface last saved them with the place: null
    /// when not known, or when the place is now the stock reader's.
    words_left: ?u64 = null,
    kindle_percent: u32 = 0,
    kindle_last: u64 = 0,
    thumbnail: ?[:0]const u8 = null, // Its cover's picture, if it has one
    added: u64 = 0,
    availability: Availability = .local,
    key: []const u8 = "",
    kind: []const u8 = "",
    guid: []const u8 = "",
    series: ?Series = null, // The series it belongs to, if known
    /// The name its author sorts under (`surname`), for sorting by author: found once
    /// a book, as a sort compares each book a few dozen times.
    surname: []const u8 = "",

    pub fn is_read(e: Entry) bool {
        return e.finished or e.percent >= finished_percent;
    }

    /// Opened for reading at some point, here or in the stock reader: past the 1% stock
    /// gives a new book, or read in noface. Only then is its last-opened date a reading.
    pub fn was_opened(e: Entry) bool {
        return e.seconds_read > 0 or e.percent > untouched_percent;
    }

    /// Started but not finished, which is what the hero leads with.
    pub fn in_progress(e: Entry) bool {
        const going = !e.is_read() and e.percent > untouched_percent;
        return going;
    }

    /// How long is left to read at `speed`: null for a book read, or when the words
    /// left or the speed aren't known yet.
    pub fn minutes_left(e: Entry, speed: stats.Speed) ?u64 {
        if (e.is_read()) return null;
        const words = e.words_left orelse return null;
        if (words == 0) return null; // At its end: nothing left to say
        return speed.minutes_for(words);
    }

    /// An EPUB copied over the cable, which noface reads itself.
    pub fn is_epub(e: Entry) bool {
        return std.ascii.endsWithIgnoreCase(e.path, ".epub");
    }

    /// On this Kindle and complete, so it can be opened.
    pub fn is_local(e: Entry) bool {
        return e.availability == .local;
    }
};

pub const Filter = enum { all, unread, read };

const finished_percent = 99;

const untouched_percent = 1; // Stock gives new books 1% without them being opened

comptime {
    assert(untouched_percent < finished_percent);
    assert(finished_percent <= 100);
}

pub const Order = enum {
    recent,
    progress,
    title,
    author,
    added,
    series,

    /// Whether books sort in it by their texts (title, author, series), or by their
    /// numbers alone: `before` reads nothing else for these.
    pub fn reads_texts(o: Order) bool {
        return switch (o) {
            .recent, .progress, .added => false,
            .title, .author, .series => true,
        };
    }

    pub fn label(o: Order) []const u8 {
        const text = switch (o) {
            .recent => "Recent",
            .progress => "Progress",
            .title => "A to Z",
            .author => "Author",
            .added => "Newest",
            .series => "Series",
        };
        assert(text.len > 0);
        return text;
    }

    pub fn next(o: Order) Order {
        const following: Order = switch (o) {
            .recent => .progress,
            .progress => .title,
            .title => .author,
            .author => .added,
            .added => .series,
            .series => .recent,
        };
        assert(following != o);
        return following;
    }
};

comptime {
    // The sort button cycles through every order once before it comes back.
    var order: Order = .recent;
    for (0..@typeInfo(Order).@"enum".field_names.len - 1) |_| {
        order = order.next();
        assert(order != .recent);
    }
    assert(order.next() == .recent);
}

// Assertions: a comparison, true or false for any two books; `sort_by` checks the order.
fn before(order: Order, a: Entry, b: Entry) bool {
    // A series stays together, downloaded or not
    if (order == .series) return by_series(a, b);
    // Books on this Kindle always come first: cloud ones can't be opened yet.
    if (a.is_local() != b.is_local()) return a.is_local();
    return switch (order) {
        .recent => a.last > b.last,
        .added => a.added > b.added,
        .title => by_title(a, b),
        .author => by_author(a, b),
        .progress => by_progress(a, b),
        .series => unreachable, // Sorted by series above, before the books here come first
    };
}

/// Series first, the one read most lately at the top, each in its order; then the
/// books outside any series, most recent first.
// Assertions: a comparison, true or false for any two books; `sort_by` checks the order.
fn by_series(a: Entry, b: Entry) bool {
    const sa = a.series orelse {
        if (b.series != null) return false; // A series comes first
        return a.last > b.last;
    };
    const sb = b.series orelse return true;
    const key_a = series_key(sa);
    const key_b = series_key(sb);
    if (!unicode.eql_ignoring_case(key_a, key_b)) {
        if (sa.last != sb.last) return sa.last > sb.last;
        return unicode.less_ignoring_case(key_a, key_b);
    }
    return by_title(a, b); // One series: in its order
}

/// A book's place in its series, for comparing: one that isn't a number (an EPUB can
/// say "nan") goes after every numbered place, so sorting is a strict weak order.
pub fn series_place(s: Series) f32 {
    const place = if (std.math.isNan(s.index)) std.math.inf(f32) else s.index;
    assert(!std.math.isNan(place));
    return place;
}

/// Books in a list, for the rules below that look through books: `at(i)` is the `i`th
/// of `count`. The library's index gives its books the same way.
pub const InList = struct {
    entries: []const Entry,

    pub fn count(l: InList) u32 {
        return @intCast(l.entries.len);
    }

    pub fn at(l: InList, i: u32) Entry {
        return l.entries[i];
    }
};

/// The next book of `e`'s series not yet read, by its place in the series: its index
/// among `books`.
pub fn next_in_series(books: anytype, e: *const Entry) ?u32 {
    const mine = e.series orelse return null;
    var best: ?u32 = null;
    var best_place: f32 = 0;
    for (0..books.count()) |i| {
        const o = books.at(@intCast(i));
        const theirs = o.series orelse continue;
        if (!same_series(theirs.name, mine.name)) continue;
        if (series_place(theirs) <= series_place(mine) or o.is_read()) continue;
        if (best == null or series_place(theirs) < best_place) {
            best = @intCast(i);
            best_place = series_place(theirs);
        }
    }
    const found = best orelse return null;
    assert(found < books.count());
    assert(!books.at(found).is_read());
    return found;
}

/// Where a book stands, for sorting by progress: under way first, then not started,
/// then finished.
fn stage(e: Entry) u2 {
    if (e.in_progress()) {
        assert(!e.is_read()); // Under way and finished are told apart
        return 0;
    }
    if (e.is_read()) return 2;
    // Neither under way nor finished: at most stock's 1% of a new book
    assert(e.percent <= untouched_percent);
    return 1;
}

/// Books under way first, furthest along at the top; within the rest, most recent.
fn by_progress(a: Entry, b: Entry) bool {
    if (stage(a) != stage(b)) return stage(a) < stage(b);
    if (stage(a) == 0 and a.percent != b.percent) return a.percent > b.percent;
    return a.last > b.last;
}

/// What a book sorts under alphabetically: its series, so a series stays together,
/// or else its title.
fn title_key(e: Entry) []const u8 {
    const s = e.series orelse return e.title;
    return series_key(s);
}

/// Alphabetical by series or title. Within one key: the books outside a series, then
/// the series in its order, then by title. One key decides everything, so the order
/// holds together however the books are sorted (a comparator that disagrees with
/// itself can crash the sort).
// Assertions: a comparison, true or false for any two books; `sort_by` checks the order.
fn by_title(a: Entry, b: Entry) bool {
    const ka = title_key(a);
    const kb = title_key(b);
    if (!unicode.eql_ignoring_case(ka, kb)) return unicode.less_ignoring_case(ka, kb);
    // The books outside a series first, then the series in its order
    if (a.series) |x| {
        const y = b.series orelse return false;
        if (series_place(x) != series_place(y)) return series_place(x) < series_place(y);
    } else if (b.series != null) return true;
    return unicode.less_ignoring_case(a.title, b.title);
}

/// A book's series: its name, never empty, and the book's place in it, 2 for "#2".
/// `last` is when any book of the series was last read, set only while sorting by
/// series, at most `series_last_max`.
pub const Series = struct { name: []const u8, index: f32, last: u64 = 0 };

/// A series and a book's place in it, from a file name. The third part names it,
/// written as "The Hitchhiker's Guide #2, 1980", "Three-Body, 3, 2016" or "The
/// hitchhiker's guide to the galaxy, bk_ 3"; or the title starts "[Hitchhiker's Guide
/// to the Galaxy 01] • ...".
pub fn series_from_file_name(path: []const u8) ?Series {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    assert(slash < path.len);
    const name_ext = path[slash + 1 ..];
    // Without its extension, so a series named last ("... -- Saga #1.epub") reads as 1
    const dot = std.mem.lastIndexOfScalar(u8, name_ext, '.') orelse name_ext.len;
    assert(dot <= name_ext.len);
    const ext_has_letters = for (name_ext[@min(dot + 1, name_ext.len)..]) |c| {
        if (std.ascii.isAlphabetic(c)) break true;
    } else false;
    const base = if (ext_has_letters) name_ext[0..dot] else name_ext;
    var parts = std.mem.splitSequence(u8, base, " -- ");
    const first = parts.next() orelse return null;
    _ = parts.next();
    const third = parts.next() orelse "";
    // "Name #2, 1980": said outright, so taken as it is (any name, any number)
    if (std.mem.lastIndexOf(u8, third, " #")) |hash| {
        var number = third[hash + 2 ..];
        if (std.mem.indexOfScalar(u8, number, ',')) |comma| number = number[0..comma];
        if (named(third[0..hash], number, .stated)) |found| return found;
    }
    if (bracketed(first)) |found| return found;
    // "Name, 3, 2016" or "Name, bk_ 3, ...": a guess, so held to more
    var fields = std.mem.splitSequence(u8, third, ", ");
    const name = fields.next() orelse return null;
    var number = fields.next() orelse return null;
    for ([_][]const u8{ "bk_", "bk.", "book", "Book", "vol.", "Vol." }) |word| {
        if (std.mem.startsWith(u8, number, word)) number = number[word.len..];
    }
    return named(name, number, .guessed);
}

/// "[Hitchhiker's Guide to the Galaxy 01] • The Hitchhiker's...": the series and number
/// in brackets ahead of a title.
fn bracketed(first: []const u8) ?Series {
    if (!std.mem.startsWith(u8, first, "[")) return null;
    const close = std.mem.indexOfScalar(u8, first, ']') orelse return null;
    assert(close > 0); // The first byte is the opening bracket
    const inside = first[1..close];
    const space = std.mem.lastIndexOfScalar(u8, inside, ' ') orelse return null;
    assert(space < inside.len);
    return named(inside[0..space], inside[space + 1 ..], .guessed);
}

const Sureness = enum { stated, guessed };

/// The highest place in a series noface believes: the largest whole number an f32 holds
/// exactly, past any series (Perry Rhodan is past 3000), short of an ISBN or a date
/// written as one number. A stated place is any whole number up to it.
pub const max_index = (1 << 24) - 1;

/// Words that make a guessed name not a series when they end it ("Penguin Edition") or
/// a number follows them ("Volume 2", "Vol. 1", "Part 3"). Inside a name they're fine:
/// "Malazan Book of the Fallen", "Book of the New Sun".
const not_series = [_][]const u8{
    "edition",
    "reprint",
    "printing",
    "impression",
    "book",
    "part",
    "volume",
    "vol",
};

/// The highest place in a series believed when it's only guessed from a file name.
const guessed_index_max = 200;

comptime {
    assert(guessed_index_max < max_index);
    // Matched ignoring case, so written in lowercase.
    for (not_series) |word| {
        for (word) |c| assert(std.ascii.isLower(c) or c == '.');
    }
}

fn named(name_part: []const u8, number_part: []const u8, sureness: Sureness) ?Series {
    const name = std.mem.trim(u8, name_part, " ");
    const index = std.fmt.parseFloat(f32, std.mem.trim(u8, number_part, " _")) catch return null;
    // A place in a series, never an ISBN or a year: kept small enough to show as a number
    if (name.len == 0 or std.math.isNan(index) or std.math.isInf(index)) return null;
    if (index < 0 or index > max_index) return null;
    if (sureness == .guessed) {
        // A name has letters, in any script (not a year), and a place in a series is
        // a small number
        if (!unicode.has_letter(name) or index > guessed_index_max) return null;
        var words = std.mem.tokenizeScalar(u8, name, ' ');
        while (words.next()) |w| {
            const bare = std.mem.trimEnd(u8, w, ".,");
            const is_bad = for (not_series) |bad| {
                if (unicode.eql_ignoring_case(bare, bad)) break true;
            } else false;
            if (!is_bad) continue;
            const after = words.peek() orelse return null; // The last word
            if (std.ascii.isDigit(after[0])) return null; // "Volume 2"
        }
    }
    // What `series_label` and the overrides file rely on.
    assert(name.len > 0);
    assert(index >= 0);
    assert(index <= max_index);
    return .{ .name = name, .index = index };
}

/// Whether two series names are the same series: "The Hitchhiker's Guide to the
/// Galaxy" and "hitchhiker's guide to the galaxy" are.
pub fn same_series(a: []const u8, b: []const u8) bool {
    assert(a.len > 0); // A series always has a name
    assert(b.len > 0);
    return unicode.eql_ignoring_case(without_the(a), without_the(b));
}

pub fn without_the(name: []const u8) []const u8 {
    const has_the = name.len > 4 and unicode.eql_ignoring_case(name[0..4], "the ");
    const bare = if (has_the) name[4..] else name;
    assert(bare.len > 0 or name.len == 0);
    return bare;
}

/// "Dune #1" for a line under a title, or null outside a series.
pub fn series_label(buf: []u8, e: Entry) ?[]const u8 {
    const s = e.series orelse return null;
    if (@floor(s.index) == s.index) {
        const index: u32 = @intFromFloat(@min(@max(s.index, 0), max_index));
        assert(index <= max_index);
        return std.fmt.bufPrint(buf, "{s} #{d}", .{ s.name, index }) catch s.name;
    }
    return std.fmt.bufPrint(buf, "{s} #{d:.1}", .{ s.name, s.index }) catch s.name;
}

/// The name an author sorts under: the part before the comma in "Adams, Douglas",
/// else the last word of "Andy Weir".
pub fn surname(author: []const u8) []const u8 {
    const name = std.mem.trim(u8, author, " ");
    assert(name.len <= author.len);
    if (std.mem.indexOfScalar(u8, name, ',')) |comma| {
        return std.mem.trim(u8, name[0..comma], " ");
    }
    const space = std.mem.lastIndexOfScalar(u8, name, ' ') orelse return name;
    assert(space + 1 <= name.len);
    return name[space + 1 ..];
}

/// By surname, then the rest of the name, then title. Books with no author go last.
// Assertions: a comparison, true or false for any two books; `sort_by` checks the order.
fn by_author(a: Entry, b: Entry) bool {
    // An author's series in order, among their other books. First, as a sort compares
    // books of one author most: their surnames needn't be found
    if (unicode.eql_ignoring_case(a.author, b.author)) return by_title(a, b);
    const sa = a.surname;
    const sb = b.surname;
    if ((sa.len == 0) != (sb.len == 0)) return sb.len == 0;
    if (!unicode.eql_ignoring_case(sa, sb)) return unicode.less_ignoring_case(sa, sb);
    return unicode.less_ignoring_case(a.author, b.author);
}

pub fn sort(entries: []Entry, order: Order) void {
    sort_by(Entry, entries, order, Listed{});
}

/// A list of entries, for `sort_by`: each item is its own book.
const Listed = struct {
    pub fn entry(_: Listed, e: Entry) Entry {
        return e;
    }

    pub fn set_series_last(_: Listed, e: *Entry, last: u64) void {
        e.series.?.last = last; // Only a book in a series is given one
    }

    pub fn set_surname(_: Listed, e: *Entry) void {
        e.surname = surname(e.author);
    }
};

/// The latest `Series.last`, in seconds since 1970: 2106, which a u32 holds, so the
/// library can keep it in 4 bytes. A later time can only come from a broken file, and
/// sorts as this one.
pub const series_last_max: u64 = std.math.maxInt(u32);

/// Sorts `items`, each standing for a book, as `order` has the books: entries, or ids
/// of books kept elsewhere. `books.entry(item)` is an item's book, its series' `last`
/// as `books.set_series_last(&item, last)` last set it (only for a book in a series),
/// never past `series_last_max`, and its `surname` as `books.set_surname(&item)` set it.
pub fn sort_by(comptime T: type, items: []T, order: Order, books: anytype) void {
    assert(items.len <= std.math.maxInt(u32)); // A book's place in them is a u32
    if (order == .series) series_last_set(T, items, books);
    if (order == .author) {
        for (items) |*item| books.set_surname(item);
    }
    const Books = @TypeOf(books);
    const by = struct {
        books: Books,
        order: Order,

        fn less(c: @This(), a: T, b: T) bool {
            return before(c.order, c.books.entry(a), c.books.entry(b));
        }
    }{ .books = books, .order = order };
    std.mem.sort(T, items, by, @TypeOf(by).less);
    assert(std.sort.isSorted(T, items, by, @TypeOf(by).less));
}

/// Gives each book of a series when any book of it was last read, for `by_series`.
/// Sorted by series name first, so each series is one run of books, read in one pass:
/// N log N, where comparing every book with every other took N squared.
fn series_last_set(comptime T: type, items: []T, books: anytype) void {
    const Books = @TypeOf(books);
    const by_name = struct {
        fn less(b: Books, x: T, y: T) bool {
            return unicode.less_ignoring_case(group_key(b.entry(x)), group_key(b.entry(y)));
        }
    }.less;
    std.mem.sort(T, items, books, by_name);
    var run_first: u32 = 0;
    // A run ends where the next book's series differs, or the books do
    for (1..items.len + 1) |i| {
        const first = books.entry(items[run_first]);
        const ends = i == items.len or
            !unicode.eql_ignoring_case(group_key(books.entry(items[i])), group_key(first));
        if (!ends) continue;
        defer run_first = @intCast(i);
        // The books outside any series are one run, with nothing to set
        if (first.series == null) continue;
        var latest: u64 = 0;
        // Only books opened: a download's date isn't reading
        for (items[run_first..i]) |item| {
            const e = books.entry(item);
            if (e.was_opened()) latest = @max(latest, @min(e.last, series_last_max));
        }
        for (items[run_first..i]) |*item| books.set_series_last(item, latest);
    }
    assert(run_first == items.len);
}

/// What `series_last_set` groups a book under: its series' key, or nothing (sorting
/// first) for one outside any.
fn group_key(e: Entry) []const u8 {
    const s = e.series orelse return "";
    const key = series_key(s);
    assert(key.len > 0); // A series' run never mixes with the books outside any
    return key;
}

/// The name a series is grouped under: without its "The", ignoring case.
fn series_key(s: Series) []const u8 {
    assert(s.name.len > 0);
    const key = without_the(s.name);
    assert(key.len > 0);
    return key;
}

/// The book for the hero, as its index among `books`: the latest one in progress on
/// this Kindle, or else the latest opened. One pass, either way.
pub fn pick_hero(books: anytype) ?u32 {
    var going: ?u32 = null;
    var going_last: u64 = 0;
    var latest: ?u32 = null;
    var latest_last: u64 = 0;
    for (0..books.count()) |i| {
        const e = books.at(@intCast(i));
        if (!e.is_local()) continue;
        if (e.in_progress() and (going == null or e.last > going_last)) {
            going = @intCast(i);
            going_last = e.last;
        }
        if (latest == null or e.last > latest_last) {
            latest = @intCast(i);
            latest_last = e.last;
        }
    }
    const hero = going orelse latest orelse return null;
    assert(hero < books.count());
    assert(books.at(hero).is_local()); // A cloud book can't be opened from the hero
    return hero;
}

/// Whether `filter` and a search for `query` (empty for none) let book `e` through.
pub fn lets_through(e: Entry, filter: Filter, query: []const u8) bool {
    const by_filter = filter == .all or (filter == .read) == e.is_read();
    return by_filter and (query.len == 0 or matches_query(e, query));
}

/// Fills `out` with indexes of matching entries, leaving out the hero, and returns how
/// many, stopping when `out` is full. A non-empty `query` keeps only books whose title,
/// author or series has it in.
pub fn select(
    entries: []const Entry,
    filter: Filter,
    hero: ?u32,
    query: []const u8,
    out: []u32,
) u32 {
    if (hero) |h| assert(h < entries.len);
    assert(entries.len <= std.math.maxInt(u32));
    var n: u32 = 0;
    for (entries, 0..) |e, i| {
        if (hero) |h| {
            if (i == h) continue;
        }
        if (lets_through(e, filter, query)) {
            if (n == out.len) break;
            out[n] = @intCast(i);
            n += 1;
        }
    }
    assert(n <= out.len);
    assert(n <= entries.len);
    return n;
}

/// Whether a book's title, author or series has `query` in it.
pub fn matches_query(e: Entry, query: []const u8) bool {
    assert(query.len > 0);
    const in_series = if (e.series) |s| search.contains(s.name, query) else false;
    return search.contains(e.title, query) or search.contains(e.author, query) or in_series;
}

test "sort orders by title and by date added" {
    var rows = [_]Entry{
        .{ .path = "/a", .title = "banana", .author = "", .percent = 0, .last = 1, .added = 5 },
        .{ .path = "/b", .title = "Apple", .author = "", .percent = 0, .last = 2, .added = 9 },
        .{ .path = "/c", .title = "cherry", .author = "", .percent = 0, .last = 3, .added = 1 },
    };
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Apple", rows[0].title);
    try std.testing.expectEqualStrings("cherry", rows[2].title);
    sort(&rows, .added);
    try std.testing.expectEqualStrings("Apple", rows[0].title);
    try std.testing.expectEqualStrings("cherry", rows[2].title);
    sort(&rows, .recent);
    try std.testing.expectEqualStrings("cherry", rows[0].title);
}

test "authors sort by surname, whichever way the name is written" {
    try std.testing.expectEqualStrings("Adams", surname("Adams, Douglas"));
    try std.testing.expectEqualStrings("Weir", surname("Andy Weir"));
    try std.testing.expectEqualStrings("Plato", surname(" Plato "));
    try std.testing.expectEqualStrings("", surname(""));
    var rows = [_]Entry{
        .{ .path = "/a", .title = "Nameless", .author = "", .percent = 0, .last = 1 },
        .{
            .path = "/b",
            .title = "Project Hail Mary",
            .author = "Andy Weir",
            .percent = 0,
            .last = 1,
        },
        .{
            .path = "/c",
            .title = "Skeleton Crew",
            .author = "King, Stephen",
            .percent = 0,
            .last = 1,
        },
        .{ .path = "/d", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{
            .path = "/e",
            .title = "Restaurant",
            .author = "Adams, Douglas",
            .percent = 0,
            .last = 1,
        },
    };
    sort(&rows, .author);
    try std.testing.expectEqualStrings("Restaurant", rows[0].title);
    try std.testing.expectEqualStrings("Skeleton Crew", rows[1].title);
    try std.testing.expectEqualStrings("Artemis", rows[2].title);
    try std.testing.expectEqualStrings("Project Hail Mary", rows[3].title);
    try std.testing.expectEqualStrings("Nameless", rows[4].title);
}

test "progress puts books under way first, furthest along at the top" {
    var rows = [_]Entry{
        .{ .path = "/a", .title = "Done", .author = "", .percent = 100, .last = 9 },
        .{ .path = "/b", .title = "New", .author = "", .percent = 0, .last = 5 },
        .{ .path = "/c", .title = "Early", .author = "", .percent = 12, .last = 8 },
        .{ .path = "/d", .title = "Late", .author = "", .percent = 80, .last = 1 },
        .{ .path = "/e", .title = "Newer", .author = "", .percent = 1, .last = 7 },
    };
    sort(&rows, .progress);
    try std.testing.expectEqualStrings("Late", rows[0].title);
    try std.testing.expectEqualStrings("Early", rows[1].title);
    try std.testing.expectEqualStrings("Newer", rows[2].title); // 1% is stock's "new"
    try std.testing.expectEqualStrings("New", rows[3].title);
    try std.testing.expectEqualStrings("Done", rows[4].title);
}

test "series come from file names" {
    const restaurant = "/mnt/us/documents/Restaurant -- Adams, Douglas -- " ++
        "The Hitchhiker's Guide To The Galaxy #2, 1980 -- Del Rey -- 2cf4.kfx";
    const s = series_from_file_name(restaurant).?;
    try std.testing.expectEqualStrings("The Hitchhiker's Guide To The Galaxy", s.name);
    try std.testing.expectEqual(@as(f32, 2), s.index);
    const half = series_from_file_name("/d/X -- Y -- Saga #1.5 -- Z.kfx").?;
    try std.testing.expectEqual(@as(f32, 1.5), half.index);
    const none = [_][]const u8{
        "/d/Snow Crash -- Stephenson, Neal -- 2010 -- Penguin.kfx",
        "/d/Plain title.kfx",
        // A publisher's name with a year isn't a series, nor is an edition
        "/d/X -- Y -- Penguin, 2010 -- Z.kfx",
        "/d/X -- Y -- Kindle Edition, 1 -- Z.kfx",
        "/d/X -- Y -- Revised edition, 2, 2009 -- Z.kfx",
        "/d/X -- Y -- Saga, nan -- Z.kfx",
        "/d/X -- Y -- MIT Electrical Engineering and -- Z.kfx",
    };
    for (none) |path| try std.testing.expect(series_from_file_name(path) == null);
    const death = "/d/Death's End (US) -- Liu Cixin -- Three-Body, 3, 2016 -- Tor.kfx";
    const comma = series_from_file_name(death).?;
    try std.testing.expectEqualStrings("Three-Body", comma.name);
    try std.testing.expectEqual(@as(f32, 3), comma.index);
    const life = "/d/Life -- Douglas Adams -- " ++
        "The hitchhiker's guide to the galaxy, bk_ 3, New -- x.kfx";
    const bk = series_from_file_name(life).?;
    try std.testing.expectEqual(@as(f32, 3), bk.index);
    try std.testing.expect(same_series(bk.name, s.name));
    const pan = "/d/[Hitchhiker's Guide to the Galaxy 01] \u{2022} The Hitchhiker's -- " ++
        "Adams -- 1992 -- Pan.kfx";
    const br = series_from_file_name(pan).?;
    try std.testing.expectEqualStrings("Hitchhiker's Guide to the Galaxy", br.name);
    try std.testing.expectEqual(@as(f32, 1), br.index);
    try std.testing.expect(same_series(br.name, s.name));
    // Said with "#", any name and number counts, and wins over brackets
    const chinese = series_from_file_name("/d/X -- Y -- \u{4e09}\u{4f53} #2 -- Z.kfx").?;
    try std.testing.expectEqualStrings("\u{4e09}\u{4f53}", chinese.name);
    const year = series_from_file_name("/d/X -- Y -- 1632 #2 -- Z.kfx").?;
    try std.testing.expectEqualStrings("1632", year.name);
    const perry = series_from_file_name("/d/X -- Y -- Perry Rhodan #2500 -- Z.kfx").?;
    try std.testing.expectEqual(@as(f32, 2500), perry.index);
    // Past the 9999 once believed
    const long = series_from_file_name("/d/X -- Y -- Long Saga #12000 -- Z.kfx").?;
    try std.testing.expectEqual(@as(f32, 12000), long.index);
    var label: [64]u8 = undefined;
    const e: Entry = .{
        .path = "/a",
        .title = "T",
        .author = "",
        .percent = 0,
        .last = 0,
        .series = .{ .name = "S", .index = max_index },
    };
    try std.testing.expectEqualStrings("S #16777215", series_label(&label, e).?);
    // The series named last, right before the extension
    const scarlet = "/d/A Study in Scarlet -- Arthur Conan Doyle -- Sherlock Holmes #1.epub";
    const last = series_from_file_name(scarlet).?;
    try std.testing.expectEqualStrings("Sherlock Holmes", last.name);
    try std.testing.expectEqual(@as(f32, 1), last.index);
    const epub_half = series_from_file_name("/d/X -- Y -- Saga #1.5.epub").?;
    try std.testing.expectEqual(@as(f32, 1.5), epub_half.index);
    const odyssey = "/d/[Book 2] Odyssey -- Homer -- Real Saga #5, 2003 -- Z.kfx";
    try std.testing.expectEqualStrings("Real Saga", series_from_file_name(odyssey).?.name);
}

test "a series stays together and in order when sorted" {
    var rows = [_]Entry{
        .{
            .path = "/a",
            .title = "Mostly Harmless",
            .author = "Adams, Douglas",
            .percent = 0,
            .last = 1,
            .series = .{ .name = "Hitchhiker's Guide", .index = 5 },
        },
        .{ .path = "/b", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{
            .path = "/c",
            .title = "The Restaurant",
            .author = "Adams, Douglas",
            .percent = 0,
            .last = 1,
            .series = .{ .name = "hitchhiker's guide", .index = 2 },
        },
        .{ .path = "/d", .title = "Zed", .author = "", .percent = 0, .last = 1 },
    };
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Artemis", rows[0].title);
    try std.testing.expectEqualStrings("The Restaurant", rows[1].title);
    try std.testing.expectEqualStrings("Mostly Harmless", rows[2].title);
    sort(&rows, .author);
    try std.testing.expectEqualStrings("The Restaurant", rows[0].title);
    try std.testing.expectEqualStrings("Mostly Harmless", rows[1].title);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Hitchhiker's Guide #5", series_label(&buf, rows[1]).?);
}

test "a series place that isn't a number sorts last and keeps the sort whole" {
    var rows: [9]Entry = undefined;
    const titles = [_][]const u8{ "One", "Two", "Three", "Four", "Five", "Six", "Seven" };
    var prng = std.Random.DefaultPrng.init(42);
    for (0..200) |_| {
        for (&rows, 0..) |*row, i| {
            const in_series = i < titles.len;
            row.* = .{
                .path = "/b",
                .title = if (in_series) titles[i] else "Loose",
                .author = "Same Author",
                .percent = 0,
                .last = 1,
                .series = if (in_series) .{
                    .name = "Saga",
                    .index = if (i == 3) std.math.nan(f32) else @floatFromInt(i + 1),
                } else null,
            };
        }
        prng.random().shuffle(Entry, &rows);
        for ([_]Order{ .title, .author, .series }) |order| {
            sort(&rows, order);
            var places: [9]f32 = undefined;
            var count: u32 = 0;
            for (rows) |row| {
                const s = row.series orelse continue;
                places[count] = s.index;
                count += 1;
            }
            try std.testing.expectEqual(@as(u32, titles.len), count);
            try std.testing.expect(std.math.isNan(places[count - 1]));
            for (1..count - 1) |i| try std.testing.expect(places[i - 1] < places[i]);
        }
    }
}

test "sort button cycles" {
    try std.testing.expectEqual(Order.progress, Order.recent.next());
    try std.testing.expectEqual(Order.title, Order.progress.next());
    try std.testing.expectEqual(Order.author, Order.title.next());
    try std.testing.expectEqual(Order.added, Order.author.next());
    try std.testing.expectEqual(Order.series, Order.added.next());
    try std.testing.expectEqual(Order.recent, Order.series.next());
}

test "hero is the latest book in progress, and leaves the grid" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Done", .author = "", .percent = 99, .last = 3 },
        .{ .path = "/b", .title = "Fresh", .author = "", .percent = 0, .last = 2 },
        .{ .path = "/c", .title = "Now", .author = "", .percent = 34, .last = 1 },
    };
    const hero = pick_hero(InList{ .entries = &rows });
    try std.testing.expectEqual(@as(u32, 2), hero.?);
    var out: [3]u32 = undefined;
    try std.testing.expectEqual(@as(u32, 2), select(&rows, .all, hero, "", &out));
    try std.testing.expectEqual(@as(u32, 1), select(&rows, .unread, hero, "", &out));
    try std.testing.expectEqual(@as(u32, 1), out[0]);
    try std.testing.expectEqual(@as(u32, 1), select(&rows, .read, hero, "", &out));
    try std.testing.expectEqual(@as(u32, 0), out[0]);
}

test "search keeps books whose title or author match" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{
            .path = "/b",
            .title = "Skeleton Crew",
            .author = "King, Stephen",
            .percent = 0,
            .last = 1,
        },
        .{
            .path = "/c",
            .title = "Project Hail Mary",
            .author = "Andy Weir",
            .percent = 100,
            .last = 1,
        },
    };
    var out: [3]u32 = undefined;
    try std.testing.expectEqual(@as(u32, 2), select(&rows, .all, null, "weir", &out));
    try std.testing.expectEqual(@as(u32, 1), select(&rows, .all, null, "SKELETON", &out));
    try std.testing.expectEqual(@as(u32, 1), out[0]);
    try std.testing.expectEqual(@as(u32, 1), select(&rows, .read, null, "weir", &out));
    try std.testing.expectEqual(@as(u32, 0), select(&rows, .all, null, "tolkien", &out));
    var one: [1]u32 = undefined;
    try std.testing.expectEqual(@as(u32, 1), select(&rows, .all, null, "weir", &one));
}

test "with nothing in progress the hero is the latest opened" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Old", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "New", .author = "", .percent = 0, .last = 5 },
    };
    try std.testing.expectEqual(@as(u32, 1), pick_hero(InList{ .entries = &rows }).?);
}

test "cloud books sort after local ones" {
    var rows = [_]Entry{
        .{
            .path = "",
            .title = "A cloud book",
            .author = "",
            .percent = 0,
            .last = 9,
            .availability = .cloud,
        },
        .{ .path = "/b", .title = "Zed", .author = "", .percent = 0, .last = 1 },
    };
    sort(&rows, .recent);
    try std.testing.expectEqualStrings("Zed", rows[0].title);
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Zed", rows[0].title);
}

test "a book counts as opened once read past stock's 1% or read in noface" {
    const fresh = Entry{ .path = "/a", .title = "New", .author = "", .percent = 1, .last = 9 };
    try std.testing.expect(!fresh.was_opened());
    try std.testing.expect((Entry{
        .path = "/b",
        .title = "B",
        .author = "",
        .percent = 1,
        .last = 9,
        .seconds_read = 30,
    }).was_opened());
    try std.testing.expect((Entry{
        .path = "/c",
        .title = "C",
        .author = "",
        .percent = 5,
        .last = 9,
    }).was_opened());
}

test "a new book at one percent is not in progress" {
    const fresh = Entry{ .path = "/a", .title = "New", .author = "", .percent = 1, .last = 9 };
    const going = Entry{ .path = "/b", .title = "Going", .author = "", .percent = 2, .last = 1 };
    try std.testing.expect(!fresh.in_progress());
    try std.testing.expect(going.in_progress());
    const rows = [_]Entry{ fresh, going };
    try std.testing.expectEqual(@as(u32, 1), pick_hero(InList{ .entries = &rows }).?);
}

test "by series: the latest series first, each in order, then the rest" {
    var entries = [_]Entry{
        .{ .path = "/a", .title = "Loose", .author = "", .percent = 0, .last = 50 },
        .{
            .path = "/b",
            .title = "Dune 2",
            .author = "",
            .percent = 0,
            .last = 1,
            .series = .{ .name = "Dune", .index = 2 },
        },
        .{
            .path = "/c",
            .title = "TBP 1",
            .author = "",
            .percent = 100,
            .last = 30,
            .series = .{ .name = "Three-Body", .index = 1 },
        },
        .{
            .path = "/d",
            .title = "Dune 1",
            .author = "",
            .percent = 100,
            .last = 5,
            .series = .{ .name = "Dune", .index = 1 },
        },
        .{
            .path = "/e",
            .title = "TBP 2",
            .author = "",
            .percent = 40,
            .last = 40,
            .series = .{ .name = "Three-Body", .index = 2 },
            .availability = .cloud,
        },
    };
    sort(&entries, .series);
    const want = [_][]const u8{ "TBP 1", "TBP 2", "Dune 1", "Dune 2", "Loose" };
    for (want, entries) |w, e| try std.testing.expectEqualStrings(w, e.title);
}

test "next in a series skips what's read" {
    const entries = [_]Entry{
        .{
            .path = "/a",
            .title = "One",
            .author = "",
            .percent = 100,
            .last = 0,
            .series = .{ .name = "S", .index = 1 },
        },
        .{
            .path = "/b",
            .title = "Three",
            .author = "",
            .percent = 0,
            .last = 0,
            .series = .{ .name = "S", .index = 3 },
        },
        .{
            .path = "/c",
            .title = "Two",
            .author = "",
            .percent = 100,
            .last = 0,
            .series = .{ .name = "S", .index = 2 },
        },
        .{
            .path = "/d",
            .title = "Other",
            .author = "",
            .percent = 0,
            .last = 0,
            .series = .{ .name = "T", .index = 2 },
        },
    };
    const listed: InList = .{ .entries = &entries };
    try std.testing.expectEqual(@as(u32, 1), next_in_series(listed, &entries[0]).?);
    try std.testing.expect(next_in_series(listed, &entries[1]) == null);
}

test "sorting by title holds together when one series is named with and without The" {
    const rows = [_]Entry{
        .{
            .path = "/a",
            .title = "Hitchhiker",
            .author = "",
            .percent = 0,
            .last = 1,
            .series = .{ .name = "The Hitchhiker's Guide", .index = 1 },
        },
        .{
            .path = "/b",
            .title = "Restaurant",
            .author = "",
            .percent = 0,
            .last = 1,
            .series = .{ .name = "Hitchhiker's Guide", .index = 2 },
        },
        .{ .path = "/c", .title = "Last Chance to See", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/d", .title = "Hitchhiker's Guide", .author = "", .percent = 0, .last = 1 },
    };
    // Every starting order gives the same result
    const want = [_][]const u8{
        "Hitchhiker's Guide",
        "Hitchhiker",
        "Restaurant",
        "Last Chance to See",
    };
    var seen: std.StaticBitSet(256) = .empty;
    for (0..24) |n| {
        // The nth order: Fisher-Yates, its choices the digits of n, base 4, 3, 2, 1
        var perm = [_]usize{ 0, 1, 2, 3 };
        var digits = n;
        for (0..perm.len) |i| {
            std.mem.swap(usize, &perm[i], &perm[i + digits % (perm.len - i)]);
            digits /= perm.len - i;
        }
        seen.set(perm[0] << 6 | perm[1] << 4 | perm[2] << 2 | perm[3]);
        var shuffled: [4]Entry = undefined;
        for (perm, &shuffled) |p, *e| e.* = rows[p];
        sort(&shuffled, .title);
        for (want, shuffled) |w, e| try std.testing.expectEqualStrings(w, e.title);
    }
    try std.testing.expectEqual(24, seen.count()); // Each order once
    for (0..rows.len) |i| for (0..rows.len) |j| {
        // Never both before the other
        try std.testing.expect(!(by_title(rows[i], rows[j]) and by_title(rows[j], rows[i])));
    };
}

test "volumes and parts aren't series" {
    const none = [_][]const u8{
        "/mnt/us/documents/Works -- Author -- Volume 2, 2, 1969 -- Pub.epub",
        "/mnt/us/documents/Works -- Author -- Vol. 1, 3, 1997 -- Pub.epub",
        "/mnt/us/documents/Works -- Author -- Part 2, 1, 2001 -- Pub.epub",
    };
    for (none) |path| try std.testing.expect(series_from_file_name(path) == null);
    const torturer = "/mnt/us/documents/[Book of the New Sun 01] The Shadow of the Torturer" ++
        " -- Gene Wolfe.kfx";
    const sun = series_from_file_name(torturer).?;
    try std.testing.expectEqualStrings("Book of the New Sun", sun.name);
}

test "series with Book inside the name are found, ISBNs after # aren't numbers" {
    const gardens = "/mnt/us/documents/Gardens of the Moon -- Steven Erikson -- " ++
        "Malazan Book of the Fallen, 1, 2004 -- Tor.kfx";
    const malazan = series_from_file_name(gardens).?;
    try std.testing.expectEqualStrings("Malazan Book of the Fallen", malazan.name);
    try std.testing.expectEqual(@as(f32, 1), malazan.index);
    const too_big = "/mnt/us/documents/Title -- Author -- Saga #5000000000.kfx";
    try std.testing.expect(series_from_file_name(too_big) == null);
    const isbn = "/mnt/us/documents/Title -- Author -- Saga #9780141439518.kfx";
    try std.testing.expect(series_from_file_name(isbn) == null);
}

test "series order gives each book its series' latest reading, as comparing all pairs did" {
    const names = [_]?[]const u8{ null, "Dune", "the dune", "Saga", "THE SAGA", "Other" };
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var rows: [300]Entry = undefined;
    for (&rows, 0..) |*row, i| {
        row.* = .{
            .path = "/b",
            .title = "T",
            .author = "",
            .percent = random.uintLessThan(u32, 101),
            .last = random.uintLessThan(u64, 1000),
            .seconds_read = if (i % 3 == 0) 10 else 0,
            .series = if (names[random.uintLessThan(u32, names.len)]) |name| .{
                .name = name,
                .index = @floatFromInt(random.uintLessThan(u32, 9)),
            } else null,
        };
    }
    sort(&rows, .series);
    for (rows) |e| {
        const s = e.series orelse continue;
        var latest: u64 = 0;
        for (rows) |o| {
            const theirs = o.series orelse continue;
            if (same_series(theirs.name, s.name) and o.was_opened()) latest = @max(latest, o.last);
        }
        try std.testing.expectEqual(latest, s.last);
    }
}

test "a series is the same whatever the case of its accented letters" {
    // "les âmes" typed is saved as "Les Âmes": the series the books' own say "Les âmes"
    try std.testing.expect(same_series("Les \u{e2}mes", "Les \u{c2}mes"));
    try std.testing.expect(same_series("The Hobbit", "the hobbit"));
    try std.testing.expect(!same_series("Les \u{e2}mes", "Les ames"));
}

test "time left is shown only for a book being read, its words and the speed known" {
    const speed: stats.Speed = .{ .pages = 10, .words = 3000, .seconds = 600 }; // 300 a minute
    var e: Entry = .{ .path = "/b.epub", .title = "B", .author = "", .percent = 40, .last = 1 };
    try std.testing.expectEqual(@as(?u64, null), e.minutes_left(speed)); // Not counted yet
    e.words_left = 60000;
    try std.testing.expectEqual(@as(?u64, 200), e.minutes_left(speed));
    try std.testing.expectEqual(@as(?u64, null), e.minutes_left(.{})); // Still learning
    e.words_left = 0;
    try std.testing.expectEqual(@as(?u64, null), e.minutes_left(speed));
    e.words_left = 60000;
    e.finished = true;
    try std.testing.expectEqual(@as(?u64, null), e.minutes_left(speed));
}
