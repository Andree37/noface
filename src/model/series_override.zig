//! Series set by hand, for books whose file names don't say (or say wrongly): one line
//! per book, "<path>\t<series>\t<number>", with an empty series for "not in one".
//! They win over what's read from file names and EPUB metadata.
const std = @import("std");
const unicode = @import("../text/unicode.zig");
const assert = std.debug.assert;
const catalog = @import("catalog.zig");

/// The overrides file in the data folder `state_dir`. Its name is said only here, so the
/// series screen that writes it and the library build that reads it never part ways.
pub fn file_path(buffer: []u8, state_dir: []const u8) ![:0]u8 {
    assert(state_dir.len > 0);
    const p = try std.fmt.bufPrintSentinel(buffer, "{s}/series", .{state_dir}, 0);
    assert(std.mem.endsWith(u8, p, "/series"));
    return p;
}

/// A book's series set by hand: null for "not in one".
pub const Override = struct { path: []const u8, series: ?catalog.Series };

/// The overrides in `text`, in `alloc`; lines that don't parse are skipped. Their paths
/// and names borrow `text`, kept as long as they are.
// Assertions: it reads the overrides file, which is outside data.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) ![]Override {
    var out: std.ArrayList(Override) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const index = std.fmt.parseFloat(f32, fields.next() orelse continue) catch continue;
        if (path.len == 0 or std.math.isNan(index)) continue;
        if (index < 0 or index > catalog.max_index) continue;
        // An empty name in the file: not in a series
        const series: ?catalog.Series =
            if (name.len > 0) .{ .name = name, .index = index } else null;
        try out.append(alloc, .{ .path = path, .series = series });
    }
    return out.toOwnedSlice(alloc);
}

pub fn find(list: []const Override, path: []const u8) ?Override {
    assert(path.len > 0); // A book is always known by a path
    for (list) |o| {
        assert(o.path.len > 0); // `parse` keeps no line without a path
        if (std.mem.eql(u8, o.path, path)) return o;
    }
    return null;
}

/// Whether `text`, a line of the file, is `path`'s.
pub fn is_for(text: []const u8, path: []const u8) bool {
    if (text.len <= path.len) return false;
    return std.mem.startsWith(u8, text, path) and text[path.len] == '\t';
}

/// `path`'s line, with its break, in `buffer`: an empty name and 0 for no series.
pub fn format_line(buffer: []u8, path: []const u8, series: ?catalog.Series) ![]const u8 {
    assert(path.len > 0);
    const name = if (series) |s| s.name else "";
    const index = if (series) |s| s.index else 0;
    const text = try std.fmt.bufPrint(buffer, "{s}\t{s}\t{d}\n", .{ path, name, index });
    assert(is_for(text, path));
    return text;
}

/// A typed name as a series' name: "three body problem" typed all in small letters is
/// "Three Body Problem", each word's first letter a capital, accented or not; a name
/// with a capital in it is as the reader typed it ("iZombie").
pub fn title_case(alloc: std.mem.Allocator, typed: []const u8) ![]const u8 {
    const name = std.mem.trim(u8, typed, " ");
    assert(name.len > 0); // A name was typed, not only spaces
    const out = try alloc.dupe(u8, name);
    if (has_capital(name)) return out;
    var start = true;
    var i: u32 = 0;
    while (i < out.len) {
        // Not UTF-8 here: the replacement character, which has no capital, left as it is
        const c = unicode.character_or_replacement(out, i);
        if (start) capitalise_at(out, i, c);
        start = c.cp == ' ';
        i += c.len;
    }
    assert(out.len == name.len); // Each letter's capital is as long as it is
    return out;
}

/// Whether `text` has a capital letter in it.
fn has_capital(text: []const u8) bool {
    assert(text.len > 0);
    var i: u32 = 0;
    while (i < text.len) {
        const c = unicode.character_or_replacement(text, i);
        if (unicode.lowercase(c.cp) != c.cp) return true;
        i += c.len;
    }
    assert(i >= text.len);
    return false;
}

/// Writes the capital of `c`, at `at` in `text`, where its capital takes as many bytes.
fn capitalise_at(text: []u8, at: u32, c: unicode.Character) void {
    assert(at + c.len <= text.len);
    assert(c.len >= 1);
    var bytes: [4]u8 = undefined;
    const capital = unicode.encode(unicode.uppercase(c.cp), &bytes) orelse return;
    if (capital.len != c.len) return; // A capital of another length: left as typed
    @memcpy(text[at..][0..capital.len], capital);
}

test "a line reads back as written, and is known by its book's path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    const text = try format_line(&buffer, "/b/dark.kfx", .{ .name = "Three-Body", .index = 2 });
    const list = try parse(arena.allocator(), text);
    const series = find(list, "/b/dark.kfx").?.series.?;
    try std.testing.expectEqualStrings("Three-Body", series.name);
    try std.testing.expectEqual(@as(f32, 2), series.index);
    try std.testing.expect(is_for(text, "/b/dark.kfx"));
    // A path that only begins the same is another book's
    try std.testing.expect(!is_for(text, "/b/dark"));
    try std.testing.expect(!is_for(text, "/b/other.kfx"));
}

test "typed names are capitalised" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const typed = try title_case(arena.allocator(), " three body problem ");
    try std.testing.expectEqualStrings("Three Body Problem", typed);
    const accented = try title_case(arena.allocator(), "\u{e9}cole des \u{e2}mes");
    try std.testing.expectEqualStrings("\u{c9}cole Des \u{c2}mes", accented);
    // Capitals typed are the reader's: kept as they are
    try std.testing.expectEqualStrings("iZombie", try title_case(arena.allocator(), "iZombie"));
}
