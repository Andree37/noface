//! Per-book reading state, kept in small text files beside the reader.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("file.zig");

pub const State = struct {
    para: u32 = 0,
    byte: u32 = 0,
    percent: ?u32 = null,
    opened: u64 = 0,
    seconds: u64 = 0, // Time spent reading this book
    // Marked read: kept here for EPUBs, which the Kindle's catalog doesn't know
    finished: bool = false,
    // The Back button's place, when a jump left one, and the pages turned since: kept
    // so it's still there when the book is opened again
    back_para: ?u32 = null,
    back_byte: u32 = 0,
    back_turns: u32 = 0,
};

/// `<dir>/state-<first 16 hex of md5 of "basename\n">`, matching earlier versions
/// that named these files with `basename | md5sum`.
pub fn path_for(buf: []u8, dir: []const u8, book_path: []const u8) ![:0]u8 {
    assert(dir.len > 0);
    assert(book_path.len > 0);
    const key = key_for(book_path);
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/state-{x:0>16}", .{ dir, key }, 0);
    assert(std.mem.startsWith(u8, path, dir));
    assert(key_of_name(std.fs.path.basename(path), "state") == key);
    return path;
}

/// What a book's files beside its state are named by: the first 16 hex of the md5 of
/// "basename\n", as a number.
pub fn key_for(book_path: []const u8) u64 {
    assert(book_path.len > 0);
    const name = std.fs.path.basename(book_path);
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(name);
    md5.update("\n");
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const key = std.mem.readInt(u64, digest[0..8], .big);
    assert(std.mem.readInt(u64, digest[0..8], .big) == key);
    return key;
}

/// The book's key in a file name "<kind>-<16 hex>", as `path_for` and `sibling` write
/// them; null for any other name.
// Assertions: it reads a file's name from a folder: outside data.
pub fn key_of_name(name: []const u8, kind: []const u8) ?u64 {
    const hex_len = 16;
    if (name.len != kind.len + 1 + hex_len) return null;
    if (!std.mem.startsWith(u8, name, kind) or name[kind.len] != '-') return null;
    const hex = name[kind.len + 1 ..];
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return null;
    }
    return std.fmt.parseInt(u64, hex, 16) catch null;
}

/// True when the Kindle's own position should win over ours: we have nothing
/// saved, or the stock reader had the book open more recently.
pub fn prefer_kindle(saved: State, kindle_last: u64) bool {
    // Older files have no time, so only an empty one gives way.
    if (saved.opened == 0) return saved.para == 0 and saved.byte == 0;
    return kindle_last > saved.opened;
}

/// Another file about the same book, beside its state file: "<dir>/<kind>-<book>" for
/// "<dir>/state-<book>". Used for saved page breaks, covers and local notes.
pub fn sibling(buf: []u8, state_path: []const u8, kind: []const u8) ![:0]u8 {
    assert(kind.len > 0);
    const dir = std.fs.path.dirname(state_path) orelse ".";
    const name = std.fs.path.basename(state_path);
    if (!std.mem.startsWith(u8, name, "state-")) return error.NotAStateFile;
    const book = name["state-".len..];
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/{s}-{s}", .{ dir, kind, book }, 0);
    assert(std.mem.endsWith(u8, path, book)); // The same book's
    return path;
}

/// Reads a state file. Each value is on a line of its own, by name ("percent 37"), so a
/// value added later is simply missing from older files and reads as its default.
// Assertions: it reads a state file, which is outside data.
pub fn parse(content: []const u8) State {
    var s = State{};
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const name = words.next() orelse continue;
        const value = words.next() orelse continue;
        inline for (@typeInfo(State).@"struct".field_names) |field| {
            if (std.mem.eql(u8, name, field)) {
                const T = @TypeOf(@field(s, field));
                @field(s, field) = read_value(T, value) orelse @field(s, field);
            }
        }
    }
    return s;
}

fn read_value(comptime T: type, text: []const u8) ?T {
    // The kinds of value a state holds
    comptime assert(T == bool or T == ?u32 or @typeInfo(T) == .int);
    return switch (T) {
        bool => std.mem.eql(u8, text, "1"),
        ?u32 => std.fmt.parseInt(u32, text, 10) catch null,
        else => std.fmt.parseInt(T, text, 10) catch null,
    };
}

pub fn load(path: [*:0]const u8) State {
    assert(path[0] != 0);
    var buf: [256]u8 = undefined;
    return parse(file.read_small(path, &buf));
}

/// Writes every value of `s`, by name, one a line.
pub fn save(path: [*:0]const u8, s: State) void {
    assert(path[0] != 0);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    inline for (@typeInfo(State).@"struct".field_names) |field| {
        const value = @field(s, field);
        switch (@TypeOf(value)) {
            bool => w.print(field ++ " {d}\n", .{@intFromBool(value)}) catch return,
            ?u32 => if (value) |v| w.print(field ++ " {d}\n", .{v}) catch return,
            else => w.print(field ++ " {d}\n", .{value}) catch return,
        }
    }
    // What's written reads back as the same state
    assert(std.meta.eql(parse(w.buffered()), s));
    file.write_small(path, w.buffered());
}

test "state file name matches basename piped to md5sum" {
    var buf: [128]u8 = undefined;
    // The output of `printf 'abc\n' | md5sum` starts 0bee89b07a248e27
    const p = try path_for(&buf, "/d", "/books/abc");
    try std.testing.expectEqualStrings("/d/state-0bee89b07a248e27", p);
    const key = key_of_name("state-0bee89b07a248e27", "state");
    try std.testing.expectEqual(@as(?u64, 0x0bee89b07a248e27), key);
    try std.testing.expectEqual(@as(?u64, null), key_of_name("state-0bee89b07a248e2", "state"));
    try std.testing.expectEqual(@as(?u64, null), key_of_name("cover-0bee89b07a248e27", "state"));
    try std.testing.expectEqual(@as(?u64, null), key_of_name("state-0BEE89B07A248E27", "state"));
}

test "kindle position wins until we have our own" {
    try std.testing.expect(prefer_kindle(.{}, 100));
    try std.testing.expect(prefer_kindle(.{ .para = 5, .opened = 100 }, 200));
    try std.testing.expect(!prefer_kindle(.{ .para = 5, .opened = 300 }, 200));
    try std.testing.expect(!prefer_kindle(.{ .para = 5 }, 200));
}

test "a value a file doesn't have reads as its default" {
    try std.testing.expectEqual(@as(u64, 4200), parse("para 1\nseconds 4200\n").seconds);
    try std.testing.expectEqual(@as(u64, 0), parse("para 1\n").seconds);
    try std.testing.expect(parse("para 10\nfinished 1\n").finished);
    try std.testing.expect(!parse("para 10\n").finished);
}

test "a book's other files sit beside its state file" {
    var buf: [128]u8 = undefined;
    const notes = try sibling(&buf, "/d/state-0bee89b07a248e27", "notes");
    try std.testing.expectEqualStrings("/d/notes-0bee89b07a248e27", notes);
    try std.testing.expectError(error.NotAStateFile, sibling(&buf, "/d/other", "notes"));
}

test "files are written by name and read back" {
    const want = State{
        .para = 12,
        .byte = 5,
        .percent = 37,
        .opened = 1793990000,
        .seconds = 4200,
        .finished = true,
    };
    const text = "para 12\nbyte 5\npercent 37\nopened 1793990000\nseconds 4200\nfinished 1\n";
    try std.testing.expectEqual(want, parse(text));
    // A value an older version didn't write reads as its default
    try std.testing.expectEqual(@as(u64, 0), parse("para 1\nbyte 2\n").seconds);
    // One it doesn't know is passed over
    try std.testing.expectEqual(@as(u32, 1), parse("para 1\nshiny 9\n").para);
}
