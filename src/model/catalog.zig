//! The library catalog: the books on this Kindle and in the cloud, how they sort,
//! filter, and which one leads the home screen. Plain data, no drawing.
const std = @import("std");
const search = @import("search.zig");

pub const Availability = enum { local, cloud, downloading };

pub const Entry = struct {
    path: [:0]const u8,
    title: []const u8,
    author: []const u8,
    percent: u32,
    last: u64,
    finished: bool = false,
    seconds_read: u64 = 0, // Time spent reading it in noface
    kindle_percent: u32 = 0,
    kindle_last: u64 = 0,
    thumbnail: [:0]const u8 = "",
    added: u64 = 0,
    availability: Availability = .local,
    key: []const u8 = "",
    kind: []const u8 = "",
    guid: []const u8 = "",
    cover: ?[]u8 = null,
    cover_tried: bool = false,
    hero: ?[]u8 = null,
    hero_tried: bool = false,
    series: []const u8 = "", // The series it belongs to, if known
    series_index: f32 = 0, // Its place in that series: 2 for "#2"
    series_last: u64 = 0, // When any book of its series was last read, for sorting by series

    pub fn isRead(e: Entry) bool {
        return e.finished or e.percent >= finished_percent;
    }

    /// Opened for reading at some point, here or in the stock reader: past the 1% stock
    /// gives a new book, or read in noface. Only then is its last-opened date a reading.
    pub fn wasOpened(e: Entry) bool {
        return e.seconds_read > 0 or e.percent > untouched_percent;
    }

    /// Started but not finished, which is what the hero leads with.
    pub fn inProgress(e: Entry) bool {
        return !e.isRead() and e.percent > untouched_percent;
    }

    /// An EPUB copied over the cable, which noface reads itself.
    pub fn isEpub(e: Entry) bool {
        return std.ascii.endsWithIgnoreCase(e.path, ".epub");
    }

    /// On this Kindle and complete, so it can be opened.
    pub fn isLocal(e: Entry) bool {
        return e.availability == .local;
    }
};

pub const Filter = enum { all, unread, read };

const finished_percent = 99;

const untouched_percent = 1; // Stock gives new books 1% without them being opened

pub const Order = enum {
    recent,
    progress,
    title,
    author,
    added,
    series,

    pub fn label(o: Order) []const u8 {
        return switch (o) {
            .recent => "Recent",
            .progress => "Progress",
            .title => "A to Z",
            .author => "Author",
            .added => "Newest",
            .series => "Series",
        };
    }

    pub fn next(o: Order) Order {
        return switch (o) {
            .recent => .progress,
            .progress => .title,
            .title => .author,
            .author => .added,
            .added => .series,
            .series => .recent,
        };
    }
};

fn before(order: Order, a: Entry, b: Entry) bool {
    // A series stays together, downloaded or not
    if (order == .series) return bySeries(a, b);
    // Books on this Kindle always come first: cloud ones can't be opened yet.
    if (a.isLocal() != b.isLocal()) return a.isLocal();
    return switch (order) {
        .recent => a.last > b.last,
        .added => a.added > b.added,
        .title => byTitle(a, b),
        .author => byAuthor(a, b),
        .progress => byProgress(a, b),
        .series => unreachable,
    };
}

/// Series first, the one read most lately at the top, each in its order; then the
/// books outside any series, most recent first.
fn bySeries(a: Entry, b: Entry) bool {
    const in_a = a.series.len > 0;
    const in_b = b.series.len > 0;
    if (in_a != in_b) return in_a;
    if (!in_a) return a.last > b.last;
    if (!sameSeries(a.series, b.series)) {
        if (a.series_last != b.series_last) return a.series_last > b.series_last;
        return std.ascii.lessThanIgnoreCase(withoutThe(a.series), withoutThe(b.series));
    }
    if (a.series_index != b.series_index) return a.series_index < b.series_index;
    return byTitle(a, b);
}

/// The next book of `e`'s series not yet read, by its place in the series.
pub fn nextInSeries(entries: []const Entry, e: *const Entry) ?usize {
    if (e.series.len == 0) return null;
    var best: ?usize = null;
    for (entries, 0..) |o, i| {
        if (!sameSeries(o.series, e.series) or o.series_index <= e.series_index or o.isRead()) continue;
        if (best == null or o.series_index < entries[best.?].series_index) best = i;
    }
    return best;
}

/// Where a book stands, for sorting by progress: under way first, then not started,
/// then finished.
fn stage(e: Entry) u2 {
    if (e.inProgress()) return 0;
    if (e.isRead()) return 2;
    return 1;
}

/// Books under way first, furthest along at the top; within the rest, most recent.
fn byProgress(a: Entry, b: Entry) bool {
    if (stage(a) != stage(b)) return stage(a) < stage(b);
    if (stage(a) == 0 and a.percent != b.percent) return a.percent > b.percent;
    return a.last > b.last;
}

/// What a book sorts under alphabetically: its series, so a series stays together,
/// or else its title.
fn titleKey(e: Entry) []const u8 {
    return if (e.series.len > 0) withoutThe(e.series) else e.title;
}

/// Alphabetical by series or title. Within one key: the books outside a series, then
/// the series in its order, then by title. One key decides everything, so the order
/// holds together however the books are sorted (a comparator that disagrees with
/// itself can crash the sort).
fn byTitle(a: Entry, b: Entry) bool {
    const ka = titleKey(a);
    const kb = titleKey(b);
    if (!std.ascii.eqlIgnoreCase(ka, kb)) return std.ascii.lessThanIgnoreCase(ka, kb);
    const in_a = a.series.len > 0;
    const in_b = b.series.len > 0;
    if (in_a != in_b) return in_b;
    if (in_a and a.series_index != b.series_index) return a.series_index < b.series_index;
    return std.ascii.lessThanIgnoreCase(a.title, b.title);
}

/// A series and a book's place in it, from a file name. The third part names it,
/// written as "The Hitchhiker's Guide #2, 1980", "Three-Body, 3, 2016" or "The
/// hitchhiker's guide to the galaxy, bk_ 3"; or the title starts "[Hitchhiker's Guide
/// to the Galaxy 01] • ...".
pub const SeriesPlace = struct { name: []const u8, index: f32 };

pub fn seriesFromFileName(path: []const u8) ?SeriesPlace {
    const name_ext = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1 ..];
    // Without its extension, so a series named last ("... -- Saga #1.epub") reads as 1
    const dot = std.mem.lastIndexOfScalar(u8, name_ext, '.') orelse name_ext.len;
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
fn bracketed(first: []const u8) ?SeriesPlace {
    if (!std.mem.startsWith(u8, first, "[")) return null;
    const close = std.mem.indexOfScalar(u8, first, ']') orelse return null;
    const inside = first[1..close];
    const space = std.mem.lastIndexOfScalar(u8, inside, ' ') orelse return null;
    return named(inside[0..space], inside[space + 1 ..], .guessed);
}

const Sureness = enum { stated, guessed };

/// The highest place in a series noface believes.
pub const max_index = 9999;

/// Words that make a guessed name not a series when they end it ("Penguin Edition") or
/// a number follows them ("Volume 2", "Vol. 1", "Part 3"). Inside a name they're fine:
/// "Malazan Book of the Fallen", "Book of the New Sun".
const not_series = [_][]const u8{ "edition", "reprint", "printing", "impression", "book", "part", "volume", "vol" };

fn named(name_part: []const u8, number_part: []const u8, sureness: Sureness) ?SeriesPlace {
    const name = std.mem.trim(u8, name_part, " ");
    const index = std.fmt.parseFloat(f32, std.mem.trim(u8, number_part, " _")) catch return null;
    // A place in a series, never an ISBN or a year: kept small enough to show as a number
    if (name.len == 0 or std.math.isNan(index) or std.math.isInf(index) or index < 0 or index > max_index) return null;
    if (sureness == .guessed) {
        // A name has letters, in any script (not a year), and a place in a series is
        // a small number
        var letters = false;
        for (name) |c| letters = letters or std.ascii.isAlphabetic(c) or c >= 0x80;
        if (!letters or index > 200) return null;
        var words = std.mem.tokenizeScalar(u8, name, ' ');
        while (words.next()) |w| {
            const bare = std.mem.trimEnd(u8, w, ".,");
            const is_bad = for (not_series) |bad| {
                if (std.ascii.eqlIgnoreCase(bare, bad)) break true;
            } else false;
            if (!is_bad) continue;
            const after = words.peek() orelse return null; // The last word
            if (std.ascii.isDigit(after[0])) return null; // "Volume 2"
        }
    }
    return .{ .name = name, .index = index };
}

/// Whether two series names are the same series: "The Hitchhiker's Guide to the
/// Galaxy" and "hitchhiker's guide to the galaxy" are.
pub fn sameSeries(a: []const u8, b: []const u8) bool {
    return a.len > 0 and std.ascii.eqlIgnoreCase(withoutThe(a), withoutThe(b));
}

fn withoutThe(name: []const u8) []const u8 {
    return if (name.len > 4 and std.ascii.eqlIgnoreCase(name[0..4], "the ")) name[4..] else name;
}

/// "Dune #1" for a line under a title, or "" outside a series.
pub fn seriesLabel(buf: []u8, e: Entry) []const u8 {
    if (e.series.len == 0) return "";
    if (@floor(e.series_index) == e.series_index) {
        return std.fmt.bufPrint(buf, "{s} #{d}", .{ e.series, @as(u32, @intFromFloat(@min(@max(e.series_index, 0), max_index))) }) catch e.series;
    }
    return std.fmt.bufPrint(buf, "{s} #{d:.1}", .{ e.series, e.series_index }) catch e.series;
}

/// The name an author sorts under: the part before the comma in "Adams, Douglas",
/// else the last word of "Andy Weir".
pub fn surname(author: []const u8) []const u8 {
    const name = std.mem.trim(u8, author, " ");
    if (std.mem.indexOfScalar(u8, name, ',')) |comma| return std.mem.trim(u8, name[0..comma], " ");
    const space = std.mem.lastIndexOfScalar(u8, name, ' ') orelse return name;
    return name[space + 1 ..];
}

/// By surname, then the rest of the name, then title. Books with no author go last.
fn byAuthor(a: Entry, b: Entry) bool {
    const sa = surname(a.author);
    const sb = surname(b.author);
    if ((sa.len == 0) != (sb.len == 0)) return sb.len == 0;
    if (!std.ascii.eqlIgnoreCase(sa, sb)) return std.ascii.lessThanIgnoreCase(sa, sb);
    if (!std.ascii.eqlIgnoreCase(a.author, b.author)) return std.ascii.lessThanIgnoreCase(a.author, b.author);
    return byTitle(a, b); // An author's series in order, among their other books
}

pub fn sort(entries: []Entry, order: Order) void {
    if (order == .series) {
        for (entries) |*e| {
            e.series_last = 0;
            if (e.series.len == 0) continue;
            for (entries) |o| {
                // Only books opened: a download's date isn't reading
                if (sameSeries(o.series, e.series) and o.wasOpened()) e.series_last = @max(e.series_last, o.last);
            }
        }
    }
    std.mem.sort(Entry, entries, order, before);
}

/// The book for the hero: the latest one in progress, or else the latest opened.
pub fn pickHero(entries: []const Entry) ?usize {
    var best: ?usize = null;
    for (entries, 0..) |e, i| {
        if (!e.inProgress() or !e.isLocal()) continue;
        if (best == null or e.last > entries[best.?].last) best = i;
    }
    if (best != null) return best;
    for (entries, 0..) |e, i| {
        if (!e.isLocal()) continue;
        if (best == null or e.last > entries[best.?].last) best = i;
    }
    return best;
}

/// Fills `out` with indexes of matching entries, leaving out the hero, and returns how
/// many, stopping when `out` is full. A non-empty `query` keeps only books whose title,
/// author or series has it in.
pub fn select(entries: []const Entry, filter: Filter, hero: ?usize, query: []const u8, out: []usize) usize {
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (i == hero) continue;
        if (query.len > 0 and !search.contains(e.title, query) and !search.contains(e.author, query) and !search.contains(e.series, query)) continue;
        const matches = switch (filter) {
            .all => true,
            .read => e.isRead(),
            .unread => !e.isRead(),
        };
        if (matches) {
            if (n == out.len) break;
            out[n] = i;
            n += 1;
        }
    }
    return n;
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
        .{ .path = "/b", .title = "Project Hail Mary", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/c", .title = "Skeleton Crew", .author = "King, Stephen", .percent = 0, .last = 1 },
        .{ .path = "/d", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/e", .title = "Restaurant", .author = "Adams, Douglas", .percent = 0, .last = 1 },
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
    const s = seriesFromFileName("/mnt/us/documents/Restaurant -- Adams, Douglas -- The Hitchhiker's Guide To The Galaxy #2, 1980 -- Del Rey -- 2cf4.kfx").?;
    try std.testing.expectEqualStrings("The Hitchhiker's Guide To The Galaxy", s.name);
    try std.testing.expectEqual(@as(f32, 2), s.index);
    try std.testing.expectEqual(@as(f32, 1.5), seriesFromFileName("/d/X -- Y -- Saga #1.5 -- Z.kfx").?.index);
    try std.testing.expect(seriesFromFileName("/d/Snow Crash -- Stephenson, Neal -- 2010 -- Penguin.kfx") == null);
    try std.testing.expect(seriesFromFileName("/d/Plain title.kfx") == null);
    const comma = seriesFromFileName("/d/Death's End (US) -- Liu Cixin -- Three-Body, 3, 2016 -- Tor.kfx").?;
    try std.testing.expectEqualStrings("Three-Body", comma.name);
    try std.testing.expectEqual(@as(f32, 3), comma.index);
    const bk = seriesFromFileName("/d/Life -- Douglas Adams -- The hitchhiker's guide to the galaxy, bk_ 3, New -- x.kfx").?;
    try std.testing.expectEqual(@as(f32, 3), bk.index);
    try std.testing.expect(sameSeries(bk.name, s.name));
    const br = seriesFromFileName("/d/[Hitchhiker's Guide to the Galaxy 01] \u{2022} The Hitchhiker's -- Adams -- 1992 -- Pan.kfx").?;
    try std.testing.expectEqualStrings("Hitchhiker's Guide to the Galaxy", br.name);
    try std.testing.expectEqual(@as(f32, 1), br.index);
    try std.testing.expect(sameSeries(br.name, s.name));
    // A publisher's name with a year isn't a series, nor is an edition
    try std.testing.expect(seriesFromFileName("/d/X -- Y -- Penguin, 2010 -- Z.kfx") == null);
    try std.testing.expect(seriesFromFileName("/d/X -- Y -- Kindle Edition, 1 -- Z.kfx") == null);
    try std.testing.expect(seriesFromFileName("/d/X -- Y -- Revised edition, 2, 2009 -- Z.kfx") == null);
    try std.testing.expect(seriesFromFileName("/d/X -- Y -- Saga, nan -- Z.kfx") == null);
    // Said with "#", any name and number counts, and wins over brackets
    try std.testing.expectEqualStrings("\u{4e09}\u{4f53}", seriesFromFileName("/d/X -- Y -- \u{4e09}\u{4f53} #2 -- Z.kfx").?.name);
    try std.testing.expectEqualStrings("1632", seriesFromFileName("/d/X -- Y -- 1632 #2 -- Z.kfx").?.name);
    try std.testing.expectEqual(@as(f32, 2500), seriesFromFileName("/d/X -- Y -- Perry Rhodan #2500 -- Z.kfx").?.index);
    // The series named last, right before the extension
    const last = seriesFromFileName("/d/A Study in Scarlet -- Arthur Conan Doyle -- Sherlock Holmes #1.epub").?;
    try std.testing.expectEqualStrings("Sherlock Holmes", last.name);
    try std.testing.expectEqual(@as(f32, 1), last.index);
    try std.testing.expectEqual(@as(f32, 1.5), seriesFromFileName("/d/X -- Y -- Saga #1.5.epub").?.index);
    try std.testing.expectEqualStrings("Real Saga", seriesFromFileName("/d/[Book 2] Odyssey -- Homer -- Real Saga #5, 2003 -- Z.kfx").?.name);
    try std.testing.expect(seriesFromFileName("/d/X -- Y -- MIT Electrical Engineering and -- Z.kfx") == null);
}

test "a series stays together and in order when sorted" {
    var rows = [_]Entry{
        .{ .path = "/a", .title = "Mostly Harmless", .author = "Adams, Douglas", .percent = 0, .last = 1, .series = "Hitchhiker's Guide", .series_index = 5 },
        .{ .path = "/b", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/c", .title = "The Restaurant", .author = "Adams, Douglas", .percent = 0, .last = 1, .series = "hitchhiker's guide", .series_index = 2 },
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
    try std.testing.expectEqualStrings("Hitchhiker's Guide #5", seriesLabel(&buf, rows[1]));
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
    const hero = pickHero(&rows);
    try std.testing.expectEqual(@as(usize, 2), hero.?);
    var out: [3]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), select(&rows, .all, hero, "", &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .unread, hero, "", &out));
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, hero, "", &out));
    try std.testing.expectEqual(@as(usize, 0), out[0]);
}

test "search keeps books whose title or author match" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Artemis", .author = "Andy Weir", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "Skeleton Crew", .author = "King, Stephen", .percent = 0, .last = 1 },
        .{ .path = "/c", .title = "Project Hail Mary", .author = "Andy Weir", .percent = 100, .last = 1 },
    };
    var out: [3]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), select(&rows, .all, null, "weir", &out));
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .all, null, "SKELETON", &out));
    try std.testing.expectEqual(@as(usize, 1), out[0]);
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .read, null, "weir", &out));
    try std.testing.expectEqual(@as(usize, 0), select(&rows, .all, null, "tolkien", &out));
    var one: [1]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), select(&rows, .all, null, "weir", &one));
}

test "with nothing in progress the hero is the latest opened" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Old", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/b", .title = "New", .author = "", .percent = 0, .last = 5 },
    };
    try std.testing.expectEqual(@as(usize, 1), pickHero(&rows).?);
}

test "cloud books sort after local ones" {
    var rows = [_]Entry{
        .{ .path = "", .title = "A cloud book", .author = "", .percent = 0, .last = 9, .availability = .cloud },
        .{ .path = "/b", .title = "Zed", .author = "", .percent = 0, .last = 1 },
    };
    sort(&rows, .recent);
    try std.testing.expectEqualStrings("Zed", rows[0].title);
    sort(&rows, .title);
    try std.testing.expectEqualStrings("Zed", rows[0].title);
}

test "a book counts as opened once read past stock's 1% or read in noface" {
    const fresh = Entry{ .path = "/a", .title = "New", .author = "", .percent = 1, .last = 9 };
    try std.testing.expect(!fresh.wasOpened());
    try std.testing.expect((Entry{ .path = "/b", .title = "B", .author = "", .percent = 1, .last = 9, .seconds_read = 30 }).wasOpened());
    try std.testing.expect((Entry{ .path = "/c", .title = "C", .author = "", .percent = 5, .last = 9 }).wasOpened());
}

test "a new book at one percent is not in progress" {
    const fresh = Entry{ .path = "/a", .title = "New", .author = "", .percent = 1, .last = 9 };
    const going = Entry{ .path = "/b", .title = "Going", .author = "", .percent = 2, .last = 1 };
    try std.testing.expect(!fresh.inProgress());
    try std.testing.expect(going.inProgress());
    const rows = [_]Entry{ fresh, going };
    try std.testing.expectEqual(@as(usize, 1), pickHero(&rows).?);
}

test "by series: the latest series first, each in order, then the rest" {
    var entries = [_]Entry{
        .{ .path = "/a", .title = "Loose", .author = "", .percent = 0, .last = 50 },
        .{ .path = "/b", .title = "Dune 2", .author = "", .percent = 0, .last = 1, .series = "Dune", .series_index = 2 },
        .{ .path = "/c", .title = "TBP 1", .author = "", .percent = 100, .last = 30, .series = "Three-Body", .series_index = 1 },
        .{ .path = "/d", .title = "Dune 1", .author = "", .percent = 100, .last = 5, .series = "Dune", .series_index = 1 },
        .{ .path = "/e", .title = "TBP 2", .author = "", .percent = 40, .last = 40, .series = "Three-Body", .series_index = 2, .availability = .cloud },
    };
    sort(&entries, .series);
    const want = [_][]const u8{ "TBP 1", "TBP 2", "Dune 1", "Dune 2", "Loose" };
    for (want, entries) |w, e| try std.testing.expectEqualStrings(w, e.title);
}

test "next in a series skips what's read" {
    const entries = [_]Entry{
        .{ .path = "/a", .title = "One", .author = "", .percent = 100, .last = 0, .series = "S", .series_index = 1 },
        .{ .path = "/b", .title = "Three", .author = "", .percent = 0, .last = 0, .series = "S", .series_index = 3 },
        .{ .path = "/c", .title = "Two", .author = "", .percent = 100, .last = 0, .series = "S", .series_index = 2 },
        .{ .path = "/d", .title = "Other", .author = "", .percent = 0, .last = 0, .series = "T", .series_index = 2 },
    };
    try std.testing.expectEqual(@as(usize, 1), nextInSeries(&entries, &entries[0]).?);
    try std.testing.expect(nextInSeries(&entries, &entries[1]) == null);
}

test "sorting by title holds together when one series is named with and without The" {
    const rows = [_]Entry{
        .{ .path = "/a", .title = "Hitchhiker", .author = "", .percent = 0, .last = 1, .series = "The Hitchhiker's Guide", .series_index = 1 },
        .{ .path = "/b", .title = "Restaurant", .author = "", .percent = 0, .last = 1, .series = "Hitchhiker's Guide", .series_index = 2 },
        .{ .path = "/c", .title = "Last Chance to See", .author = "", .percent = 0, .last = 1 },
        .{ .path = "/d", .title = "Hitchhiker's Guide", .author = "", .percent = 0, .last = 1 },
    };
    // Every starting order gives the same result
    const want = [_][]const u8{ "Hitchhiker's Guide", "Hitchhiker", "Restaurant", "Last Chance to See" };
    var perm = [_]usize{ 0, 1, 2, 3 };
    for (0..24) |_| {
        var shuffled: [4]Entry = undefined;
        for (perm, &shuffled) |p, *e| e.* = rows[p];
        sort(&shuffled, .title);
        for (want, shuffled) |w, e| try std.testing.expectEqualStrings(w, e.title);
        std.mem.reverse(usize, perm[1..]);
        std.mem.rotate(usize, &perm, 1);
    }
    for (0..rows.len) |i| for (0..rows.len) |j| {
        // Never both before the other
        try std.testing.expect(!(byTitle(rows[i], rows[j]) and byTitle(rows[j], rows[i])));
    };
}

test "volumes and parts aren't series" {
    try std.testing.expect(seriesFromFileName("/mnt/us/documents/Works -- Author -- Volume 2, 2, 1969 -- Pub.epub") == null);
    try std.testing.expect(seriesFromFileName("/mnt/us/documents/Works -- Author -- Vol. 1, 3, 1997 -- Pub.epub") == null);
    try std.testing.expect(seriesFromFileName("/mnt/us/documents/Works -- Author -- Part 2, 1, 2001 -- Pub.epub") == null);
    const sun = seriesFromFileName("/mnt/us/documents/[Book of the New Sun 01] The Shadow of the Torturer -- Gene Wolfe.kfx").?;
    try std.testing.expectEqualStrings("Book of the New Sun", sun.name);
}

test "series with Book inside the name are found, ISBNs after # aren't numbers" {
    const malazan = seriesFromFileName("/mnt/us/documents/Gardens of the Moon -- Steven Erikson -- Malazan Book of the Fallen, 1, 2004 -- Tor.kfx").?;
    try std.testing.expectEqualStrings("Malazan Book of the Fallen", malazan.name);
    try std.testing.expectEqual(@as(f32, 1), malazan.index);
    try std.testing.expect(seriesFromFileName("/mnt/us/documents/Title -- Author -- Saga #5000000000.kfx") == null);
    try std.testing.expect(seriesFromFileName("/mnt/us/documents/Title -- Author -- Saga #9780141439518.kfx") == null);
}
