//! Series set by hand, for books whose file names don't say (or say wrongly): one line
//! per book, "<path>\t<series>\t<number>", with an empty series for "not in one".
//! They win over what's read from file names and EPUB metadata.
const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("catalog.zig");

pub const Override = struct { path: []const u8, name: []const u8, index: f32 };

/// The overrides in `text`; lines that don't parse are skipped.
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
        assert(index >= 0);
        assert(index <= catalog.max_index);
        try out.append(alloc, .{ .path = path, .name = name, .index = index });
    }
    return out.items;
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
// Assertions: it compares two strings, and every pair of them is valid.
pub fn is_for(text: []const u8, path: []const u8) bool {
    if (text.len <= path.len) return false;
    return std.mem.startsWith(u8, text, path) and text[path.len] == '\t';
}

/// `path`'s line, with its break, in `buffer`.
pub fn format_line(buffer: []u8, path: []const u8, name: []const u8, index: f32) ![]const u8 {
    assert(path.len > 0);
    const text = try std.fmt.bufPrint(buffer, "{s}\t{s}\t{d}\n", .{ path, name, index });
    assert(is_for(text, path));
    return text;
}

/// "three body problem" typed on a lowercase keyboard, as a name: "Three Body Problem".
pub fn title_case(alloc: std.mem.Allocator, typed: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, std.mem.trim(u8, typed, " "));
    var start = true;
    for (out) |*c| {
        if (start) c.* = std.ascii.toUpper(c.*);
        start = c.* == ' ';
    }
    assert(out.len <= typed.len);
    if (out.len > 0) assert(!std.ascii.isLower(out[0]));
    return out;
}

test "a line reads back as written, and is known by its book's path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    const text = try format_line(&buffer, "/b/dark.kfx", "Three-Body", 2);
    const list = try parse(arena.allocator(), text);
    try std.testing.expectEqualStrings("Three-Body", find(list, "/b/dark.kfx").?.name);
    try std.testing.expectEqual(@as(f32, 2), find(list, "/b/dark.kfx").?.index);
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
}
