//! The Kindle's book catalog: exported by `noface-launch export` into library.tsv, and read
//! back into the library model.
//!
//! The catalog is outside data: a row it can't read is skipped or read as empty, never
//! asserted.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const library = @import("../model/catalog.zig");
const process = @import("../sys/process.zig");
const os = @import("../sys/os.zig");
const catalog_export = @import("catalog_export.zig");

const read_state_finished = 2; // Kindle's own "finished" mark

const percent_max = 100;

/// Converted filenames look like "Title -- Author -- Year -- junk".
pub fn clean_title(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " -- ") orelse raw.len;
    const result = std.mem.trim(u8, raw[0..end], " ");
    assert(result.len <= raw.len);
    return result;
}

/// Rebuilds library.tsv from the catalog.
pub fn export_library() void {
    // By the launcher, which writes it the same way before noface starts
    // (src/kindle/catalog_export.zig).
    comptime assert(std.mem.endsWith(u8, paths.launcher, "/noface-launch"));
    comptime assert(paths.launcher[0] == '/');
    const argv = [_:null]?[*:0]const u8{ paths.launcher, "export" };
    var out: [16]u8 = undefined;
    // It prints nothing worth reading: library.tsv is what it makes. Given time past
    // its own limit, so it's never stopped before removing its copy of the catalog
    const grace_ms = 5_000;
    const deadline = os.now_us() + (catalog_export.time_max_ms + grace_ms) * std.time.us_per_ms;
    _ = process.run_until(&argv, &out, deadline);
}

/// Filename conversion turned ":" into "_", and some titles carry a series prefix
/// like "[Bobiverse 01] \u{2022} We Are Legion".
pub fn fix_title(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var title = clean_title(raw);
    const bullet = "\u{2022} ";
    if (title.len > 0 and title[0] == '[') {
        if (std.mem.indexOf(u8, title, bullet)) |at| title = title[at + bullet.len ..];
    }
    var out: std.ArrayList(u8) = .empty;
    var rest = title;
    // Bounded: every step takes at least a byte off what's left.
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, " _ ")) {
            try out.appendSlice(alloc, ": ");
            rest = rest[3..];
        } else if (std.mem.startsWith(u8, rest, "_ ")) {
            try out.appendSlice(alloc, ": ");
            rest = rest[2..];
        } else {
            try out.append(alloc, rest[0]);
            rest = rest[1..];
        }
    }
    // A colon is never longer than what it replaces.
    assert(out.items.len <= title.len);
    const result = std.mem.trimEnd(u8, out.items, "_ ");
    return result;
}

/// Authors can repeat as "Liu, Cixin [Liu, Cixin]".
pub fn clean_author(raw: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, raw, " [") orelse raw.len;
    const result = std.mem.trim(u8, raw[0..end], " ");
    assert(result.len <= raw.len);
    return result;
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) ![]library.Entry {
    var out: std.ArrayList(library.Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const entry = try parse_line(alloc, line) orelse continue;
        try out.append(alloc, entry);
    }
    for (out.items) |entry| {
        if (entry.availability == .local) assert(entry.path.len > 0);
        assert(entry.percent <= percent_max);
    }
    return out.toOwnedSlice(alloc);
}

/// One book's row: its fields, tab separated. Null for a row that names no book.
pub fn parse_line(alloc: std.mem.Allocator, line: []const u8) !?library.Entry {
    assert(line.len > 0);
    assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    var fields = std.mem.splitScalar(u8, line, '\t');
    const path = fields.next() orelse return null;
    const title = fields.next() orelse return null;
    const author = fields.next() orelse return null;
    // A percent that isn't a number counts as none, as one that isn't there does
    const percent_read = std.fmt.parseFloat(f32, fields.next() orelse "0") catch 0;
    const percent = if (std.math.isFinite(percent_read)) percent_read else 0;
    const last = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
    const read_state = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
    const thumbnail = fields.next() orelse "";
    const added = std.fmt.parseInt(u64, fields.next() orelse "0", 10) catch 0;
    const availability_code = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
    const availability: library.Availability = switch (availability_code) {
        1 => .cloud,
        2 => .downloading,
        else => .local,
    };
    const key = fields.next() orelse "";
    const kind = fields.next() orelse "";
    const guid = fields.next() orelse "";
    if (path.len == 0 and availability == .local) return null;
    // The export lists only KFX files and cloud books, so never an EPUB; one that came
    // anyway is left to the library's own walk of the folder, which lists every EPUB
    if (std.ascii.endsWithIgnoreCase(path, ".epub")) return null;
    const series = library.series_from_file_name(path);
    // A place in a series is a number the library can sort by
    if (series) |s| assert(std.math.isFinite(s.index));
    const percent_whole: u32 = @intFromFloat(std.math.clamp(percent, 0, percent_max));
    return .{
        .path = try alloc.dupeSentinel(u8, path, 0),
        .title = try fix_title(alloc, title),
        .author = clean_author(author),
        .percent = percent_whole,
        .last = last,
        // The Kindle's own mark, which marking as unread clears.
        .finished = read_state == read_state_finished,
        .kindle_percent = percent_whole,
        .kindle_last = last,
        .thumbnail = try alloc.dupeSentinel(u8, thumbnail, 0),
        .added = added,
        .availability = availability,
        .key = key,
        .kind = kind,
        .guid = guid,
        .series = if (series) |s| s.name else "",
        .series_index = if (series) |s| s.index else 0,
    };
}

test "titles lose filename junk" {
    const title = clean_title("Snow Crash -- Stephenson, Neal -- 2010");
    try std.testing.expectEqualStrings("Snow Crash", title);
    const plain = "Prisoners of Geography";
    try std.testing.expectEqualStrings(plain, clean_title(plain));
}

test "authors lose repeated names" {
    try std.testing.expectEqualStrings("Liu, Cixin", clean_author("Liu, Cixin [Liu, Cixin]"));
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
    const data = "/a\tA\tx\t99.1\t1\t1\n/b\tB\tx\t40\t1\t2\n" ++
        "/c\tC\tx\t40\t1\t1\n/d\tD\tx\t0\t1\t0\n";
    const rows = try parse(arena.allocator(), data);
    try std.testing.expect(rows[0].is_read());
    rows[0].percent = 3; // Read again from the start, or marked as unread
    try std.testing.expect(!rows[0].is_read());
    try std.testing.expect(rows[1].is_read());
    try std.testing.expect(!rows[2].is_read());
    try std.testing.expect(rows[2].in_progress());
    try std.testing.expect(!rows[3].in_progress());
}

test "cloud books list without a path and never lead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "\tCloud\tx\t50\t9\t0\t\t1\t1\n/b\tHere\tx\t20\t1\t0\t\t1\t0\n" ++
        "/c\tGetting\tx\t0\t2\t0\t\t1\t2\n\tNoPath\tx\t0\t2\t0\t\t1\t0\n";
    const rows = try parse(arena.allocator(), data);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(library.Availability.cloud, rows[0].availability);
    try std.testing.expectEqual(library.Availability.downloading, rows[2].availability);
    const listed: library.InList = .{ .entries = rows };
    try std.testing.expectEqual(@as(u32, 1), library.pick_hero(listed).?);
}

test "a series place or percent that isn't a number counts as none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = "/d/A -- x -- Saga #nan.kfx\tA\tx\tnan\t1\n" ++
        "/d/B -- x -- Saga #inf.kfx\tB\tx\tinf\t1\n" ++
        "/d/C -- x -- Saga #2.kfx\tC\tx\t-inf\t1\n";
    const rows = try parse(arena.allocator(), data);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    for (rows) |row| {
        try std.testing.expect(std.math.isFinite(row.series_index));
        try std.testing.expectEqual(@as(u32, 0), row.percent);
    }
    try std.testing.expectEqualStrings("", rows[0].series);
    try std.testing.expectEqualStrings("", rows[1].series);
    try std.testing.expectEqual(@as(f32, 2), rows[2].series_index);
    for ([_]library.Order{ .title, .author, .series }) |order| library.sort(rows, order);
}

test "an EPUB in the catalog is left to the library's walk of the folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = try parse(arena.allocator(), "/d/a.EPUB\tA\tx\n/d/b.kfx\tB\tx\n");
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("/d/b.kfx", rows[0].path);
}

test "titles get their colons back and lose a series prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = "[Bobiverse 01] \u{2022} We Are Legion _ We Are Bob_ Book_ ";
    const title = try fix_title(arena.allocator(), raw);
    try std.testing.expectEqualStrings("We Are Legion: We Are Bob: Book", title);
}
