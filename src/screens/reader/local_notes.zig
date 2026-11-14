//! Highlights and bookmarks of books Amazon doesn't sync, like EPUBs copied over the
//! cable, kept in a file beside the book's state. One line per record:
//! "<highlight|bookmark> <id> <start> <end>", with character positions like Amazon's.
const std = @import("std");
const annotations = @import("../../kindle/annotations.zig");
const file = @import("../../sys/file.zig");
const state = @import("../../sys/state.zig");

fn kind_name(kind: annotations.Kind) []const u8 {
    return switch (kind) {
        .highlight => "highlight",
        .bookmark => "bookmark",
    };
}

/// The records of one kind as "id|start|end" lines, the shape the Kindle's database
/// gives, so highlights.parse and bookmarks.parse read both alike.
pub fn read(alloc: std.mem.Allocator, path: [*:0]const u8, kind: annotations.Kind) ![]const u8 {
    const data = file.map(path) catch return "";
    defer file.unmap(data);
    return select(alloc, data, kind);
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
    return out.toOwnedSlice(alloc);
}

/// Saves a record, replacing any with the same id.
pub fn put(alloc: std.mem.Allocator, path: [*:0]const u8, kind: annotations.Kind, id: []const u8, start: u32, end: u32) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    keep_others(alloc, path, id, &out) catch return false;
    out.print(alloc, "{s} {s} {d} {d}\n", .{ kind_name(kind), id, start, end }) catch return false;
    state.write_small(path, out.items);
    return true;
}

/// Removes a record. True when the file was rewritten, even if it wasn't there.
pub fn remove(alloc: std.mem.Allocator, path: [*:0]const u8, id: []const u8) bool {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    keep_others(alloc, path, id, &out) catch return false;
    if (out.items.len == 0) out.appendSlice(alloc, "\n") catch return false; // An empty file can't be written atomically
    state.write_small(path, out.items);
    return true;
}

fn keep_others(alloc: std.mem.Allocator, path: [*:0]const u8, id: []const u8, out: *std.ArrayList(u8)) !void {
    const data = file.map(path) catch return;
    defer file.unmap(data);
    try others(alloc, data, id, out);
}

fn others(alloc: std.mem.Allocator, data: []const u8, id: []const u8, out: *std.ArrayList(u8)) !void {
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        _ = words.next();
        if (std.mem.eql(u8, words.next() orelse continue, id)) continue;
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
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
