//! The Kindle's book catalog: exported by device/export.sh into library.tsv, and read
//! back into the library model.
const std = @import("std");
const paths = @import("paths.zig");
const library = @import("../model/catalog.zig");
const process = @import("../sys/process.zig");

const read_state_finished = 2; // Kindle's own "finished" mark

/// Converted filenames look like "Title -- Author -- Year -- junk".
pub fn cleanTitle(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " -- ") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
}

/// Rebuilds library.tsv from the catalog.
pub fn exportLibrary() void {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", paths.export_script };
    var out: [16]u8 = undefined;
    _ = process.run(&argv, &out);
}

/// Filename conversion turned ":" into "_", and some titles carry a series prefix
/// like "[Bobiverse 01] \u{2022} We Are Legion".
pub fn fixTitle(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var t = cleanTitle(raw);
    const bullet = "\u{2022} ";
    if (t.len > 0 and t[0] == '[') {
        if (std.mem.indexOf(u8, t, bullet)) |at| t = t[at + bullet.len ..];
    }
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        if (std.mem.startsWith(u8, t[i..], " _ ")) {
            try out.appendSlice(alloc, ": ");
            i += 3;
        } else if (std.mem.startsWith(u8, t[i..], "_ ")) {
            try out.appendSlice(alloc, ": ");
            i += 2;
        } else {
            try out.append(alloc, t[i]);
            i += 1;
        }
    }
    return std.mem.trimEnd(u8, out.items, "_ ");
}

/// Authors can repeat as "Liu, Cixin [Liu, Cixin]".
pub fn cleanAuthor(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " [") orelse raw.len;
    return std.mem.trim(u8, raw[0..end], " ");
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) ![]library.Entry {
    var out: std.ArrayList(library.Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = fields.next() orelse continue;
        const title = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const percent = std.fmt.parseFloat(f32, fields.next() orelse "0") catch 0;
        const last = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const read_state = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
        const thumbnail = fields.next() orelse "";
        const added = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
        const availability: library.Availability = switch (std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0) {
            1 => .cloud,
            2 => .downloading,
            else => .local,
        };
        const key = fields.next() orelse "";
        const kind = fields.next() orelse "";
        const guid = fields.next() orelse "";
        if (path.len == 0 and availability == .local) continue;
        try out.append(alloc, .{
            .path = try alloc.dupeSentinel(u8, path, 0),
            .title = try fixTitle(alloc, title),
            .author = cleanAuthor(author),
            .percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .last = last,
            // The Kindle's own mark, which marking as unread clears.
            .finished = read_state == read_state_finished,
            .kindle_percent = @intFromFloat(std.math.clamp(percent, 0, 100)),
            .kindle_last = last,
            .thumbnail = try alloc.dupeSentinel(u8, thumbnail, 0),
            .added = added,
            .availability = availability,
            .key = key,
            .kind = kind,
            .guid = guid,
            .series = if (library.seriesFromFileName(path)) |s| s.name else "",
            .series_index = if (library.seriesFromFileName(path)) |s| s.index else 0,
        });
    }
    return out.toOwnedSlice(alloc);
}

test "titles lose filename junk" {
    try std.testing.expectEqualStrings("Snow Crash", cleanTitle("Snow Crash -- Stephenson, Neal -- 2010"));
    try std.testing.expectEqualStrings("Prisoners of Geography", cleanTitle("Prisoners of Geography"));
}

test "authors lose repeated names" {
    try std.testing.expectEqualStrings("Liu, Cixin", cleanAuthor("Liu, Cixin [Liu, Cixin]"));
}

test "rows parse and library.sort newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "/a.kfx\tOld -- x\tA\t12.7\t100\n/b.kfx\tNew\tB\t\t200\n\n";
    const rows = try parse(arena.allocator(), data);
    library.sort(rows, .recent);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("New", rows[0].title);
    try std.testing.expectEqual(@as(u32, 12), rows[1].percent);
    try std.testing.expectEqualStrings("Old", rows[1].title);
}

test "finished stays read after our progress replaces the percent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "/a\tA\tx\t99.1\t1\t1\n/b\tB\tx\t40\t1\t2\n/c\tC\tx\t40\t1\t1\n/d\tD\tx\t0\t1\t0\n");
    try std.testing.expect(rows[0].isRead());
    rows[0].percent = 3; // Read again from the start, or marked as unread
    try std.testing.expect(!rows[0].isRead());
    try std.testing.expect(rows[1].isRead());
    try std.testing.expect(!rows[2].isRead());
    try std.testing.expect(rows[2].inProgress());
    try std.testing.expect(!rows[3].inProgress());
}

test "cloud books list without a path and never lead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "\tCloud\tx\t50\t9\t0\t\t1\t1\n/b\tHere\tx\t20\t1\t0\t\t1\t0\n/c\tGetting\tx\t0\t2\t0\t\t1\t2\n\tNoPath\tx\t0\t2\t0\t\t1\t0\n");
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(library.Availability.cloud, rows[0].availability);
    try std.testing.expectEqual(library.Availability.downloading, rows[2].availability);
    try std.testing.expectEqual(@as(usize, 1), library.pickHero(rows).?);
}
