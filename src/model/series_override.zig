//! Series set by hand, for books whose file names don't say (or say wrongly): one line
//! per book, "<path>\t<series>\t<number>", with an empty series for "not in one".
//! They win over what's read from file names and EPUB metadata.
const std = @import("std");

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
        if (path.len == 0 or std.math.isNan(index) or index < 0 or index > @import("catalog.zig").max_index) continue;
        try out.append(alloc, .{ .path = path, .name = name, .index = index });
    }
    return out.items;
}

pub fn find(list: []const Override, path: []const u8) ?Override {
    for (list) |o| {
        if (std.mem.eql(u8, o.path, path)) return o;
    }
    return null;
}

/// The file's new contents: `list` with `path` set to `name` and `index`.
pub fn format(alloc: std.mem.Allocator, list: []const Override, path: []const u8, name: []const u8, index: f32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list) |o| {
        if (std.mem.eql(u8, o.path, path)) continue;
        try out.print(alloc, "{s}\t{s}\t{d}\n", .{ o.path, o.name, o.index });
    }
    try out.print(alloc, "{s}\t{s}\t{d}\n", .{ path, name, index });
    return out.items;
}

/// "three body problem" typed on a lowercase keyboard, as a name: "Three Body Problem".
pub fn title_case(alloc: std.mem.Allocator, typed: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, std.mem.trim(u8, typed, " "));
    var start = true;
    for (out) |*c| {
        if (start) c.* = std.ascii.toUpper(c.*);
        start = c.* == ' ';
    }
    return out;
}

test "overrides read back as written, the newest winning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const first = try format(alloc, &.{}, "/b/dark.kfx", "Three-Body", 2);
    const list = try parse(alloc, first);
    try std.testing.expectEqualStrings("Three-Body", find(list, "/b/dark.kfx").?.name);
    try std.testing.expectEqual(@as(f32, 2), find(list, "/b/dark.kfx").?.index);
    const second = try format(alloc, list, "/b/dark.kfx", "", 0); // Taken out of a series
    const again = try parse(alloc, second);
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqualStrings("", find(again, "/b/dark.kfx").?.name);
    try std.testing.expect(find(again, "/b/other.kfx") == null);
}

test "typed names are capitalised" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("Three Body Problem", try title_case(arena.allocator(), " three body problem "));
}
