//! Highlights and bookmarks of books Amazon doesn't sync, like EPUBs copied over the
//! cable, kept in a file beside the book's state. One line per record:
//! "<highlight|bookmark> <id> <start> <end>", with character positions like Amazon's.
const std = @import("std");
const assert = std.debug.assert;
const annotations = @import("../../kindle/annotations.zig");
const file = @import("../../sys/file.zig");
const state = @import("../../sys/state.zig");

fn kind_name(kind: annotations.Kind) []const u8 {
    const name = switch (kind) {
        .highlight => "highlight",
        .bookmark => "bookmark",
    };
    // The first word of a line, so it can't hold the space between words
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, ' ') == null);
    return name;
}

/// The records of one kind as "id|start|end" lines, the shape the Kindle's database
/// gives, so highlights.parse and bookmarks.parse read both alike.
pub fn read(alloc: std.mem.Allocator, path: [*:0]const u8, kind: annotations.Kind) ![]const u8 {
    assert(std.mem.len(path) > 0);
    const data = file.map(path) catch return "";
    defer file.unmap(data);
    const lines = try select(alloc, data, kind);
    if (lines.len > 0) assert(lines[lines.len - 1] == '\n');
    return lines;
}

pub fn select(alloc: std.mem.Allocator, data: []const u8, kind: annotations.Kind) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, words.next() orelse continue, kind_name(kind))) continue;
        const id = words.next() orelse continue;
        const start = words.next() orelse continue;
        const end = words.next() orelse continue;
        try out.print(alloc, "{s}|{s}|{s}\n", .{ id, start, end });
    }
    // Each line loses its kind and keeps its id, positions and one separator per word
    assert(out.items.len <= data.len);
    if (out.items.len > 0) assert(out.items[out.items.len - 1] == '\n');
    return out.toOwnedSlice(alloc);
}

/// Saves a record, replacing any with the same id.
pub fn put(
    alloc: std.mem.Allocator,
    path: [*:0]const u8,
    kind: annotations.Kind,
    id: []const u8,
    start: u32,
    end: u32,
) bool {
    assert(std.mem.len(path) > 0);
    // Ids are made here or read back from this file a word at a time, so each is one word
    assert(std.mem.indexOfAny(u8, id, " \n") == null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    keep_others(alloc, path, id, &out) catch return false;
    out.print(alloc, "{s} {s} {d} {d}\n", .{ kind_name(kind), id, start, end }) catch return false;
    state.write_small(path, out.items);
    return true;
}

/// Removes a record. True when the file was rewritten, even if it wasn't there.
pub fn remove(alloc: std.mem.Allocator, path: [*:0]const u8, id: []const u8) bool {
    assert(std.mem.len(path) > 0);
    assert(std.mem.indexOfAny(u8, id, " \n") == null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    keep_others(alloc, path, id, &out) catch return false;
    if (out.items.len == 0) {
        // An empty file can't be written atomically
        out.appendSlice(alloc, "\n") catch return false;
    }
    state.write_small(path, out.items);
    return true;
}

fn keep_others(
    alloc: std.mem.Allocator,
    path: [*:0]const u8,
    id: []const u8,
    out: *std.ArrayList(u8),
) !void {
    assert(out.items.len == 0);
    assert(std.mem.len(path) > 0);
    const data = file.map(path) catch return;
    defer file.unmap(data);
    try others(alloc, data, id, out);
}

fn others(
    alloc: std.mem.Allocator,
    data: []const u8,
    id: []const u8,
    out: *std.ArrayList(u8),
) !void {
    assert(std.mem.indexOfAny(u8, id, " \n") == null);
    const kept_before = out.items.len;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        _ = words.next();
        if (std.mem.eql(u8, words.next() orelse continue, id)) continue;
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    // Lines are kept whole, each with its newline, and never more than were there
    assert(out.items.len - kept_before <= data.len + 1);
    if (out.items.len > 0) assert(out.items[out.items.len - 1] == '\n');
}

test "records come out by kind, in the database's shape" {
    const alloc = std.testing.allocator;
    const data = "highlight kindle.highlight-5 5 20\nbookmark kindle.bookmark-9 9 9\nbroken line\n";
    const h = try select(alloc, data, .highlight);
    defer alloc.free(h);
    try std.testing.expectEqualStrings("kindle.highlight-5|5|20\n", h);
    const b = try select(alloc, data, .bookmark);
    defer alloc.free(b);
    try std.testing.expectEqualStrings("kindle.bookmark-9|9|9\n", b);
}

test "replacing keeps every other record" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try others(alloc, "highlight a 1 2\nbookmark b 3 3\n", "a", &out);
    try std.testing.expectEqualStrings("bookmark b 3 3\n", out.items);
}
