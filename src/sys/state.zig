//! Per-book reading state, kept in small text files beside the reader.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("calls.zig");

pub const State = struct {
    para: u32 = 0,
    byte: u32 = 0,
    percent: ?u32 = null,
    opened: u64 = 0,
    seconds: u64 = 0, // Time spent reading this book
    // Marked read: kept here for EPUBs, which the Kindle's catalog doesn't know
    finished: bool = false,
};

const failed = @import("os.zig").failed;

/// The order of the values in files from before they were named.
const old_order = [_][]const u8{ "para", "byte", "percent", "opened", "seconds", "finished" };

comptime {
    // Every value of a state is in the old order, once
    assert(old_order.len == @typeInfo(State).@"struct".field_names.len);
    for (old_order) |name| assert(@hasField(State, name));
}

/// `<dir>/state-<first 16 hex of md5 of "basename\n">`, matching earlier versions
/// that named these files with `basename | md5sum`.
pub fn path_for(buf: []u8, dir: []const u8, book_path: []const u8) ![:0]u8 {
    assert(dir.len > 0);
    assert(book_path.len > 0);
    const name = std.fs.path.basename(book_path);
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(name);
    md5.update("\n");
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/state-{s}", .{ dir, &hex }, 0);
    assert(std.mem.startsWith(u8, path, dir));
    return path;
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
/// Files from before that are numbers in a row, in the order of `old_order`.
pub fn parse(content: []const u8) State {
    const first = std.mem.trimStart(u8, content, " \n");
    if (first.len > 0 and std.ascii.isDigit(first[0])) return parse_old(content);
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

fn parse_old(content: []const u8) State {
    // The two values a file can't be without come first
    comptime assert(std.mem.eql(u8, old_order[0], "para"));
    comptime assert(std.mem.eql(u8, old_order[1], "byte"));
    var it = std.mem.tokenizeAny(u8, content, " \n");
    var s = State{};
    inline for (old_order, 0..) |field, i| {
        const word = it.next() orelse return if (i < 2) .{} else s;
        const value = read_value(@TypeOf(@field(s, field)), word);
        // Place and byte are the least a file holds: without them it's not one
        if (value == null and i < 2) return .{};
        if (value) |v| @field(s, field) = v;
    }
    return s;
}

pub fn load(path: [*:0]const u8) State {
    assert(path[0] != 0);
    var buf: [256]u8 = undefined;
    return parse(read_small(path, &buf));
}

/// A small file's contents, or nothing if it can't be read.
pub fn read_small(path: [*:0]const u8, buf: []u8) []const u8 {
    assert(path[0] != 0);
    assert(buf.len > 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Only read: nothing is lost if closing fails
    const n = linux.read(fd, buf.ptr, buf.len);
    if (failed(n)) return "";
    assert(n <= buf.len);
    return buf[0..n];
}

/// Writes beside the real file and renames, so a crash can't lose the old contents.
pub fn write_small(path: [*:0]const u8, data: []const u8) void {
    assert(path[0] != 0);
    var tmp: [320]u8 = undefined;
    const name = std.mem.sliceTo(path, 0);
    const tmp_path = std.fmt.bufPrintSentinel(&tmp, "{s}.tmp", .{name}, 0) catch return;
    assert(std.mem.endsWith(u8, tmp_path, ".tmp")); // Beside the real file, never it
    const rc = linux.open(
        tmp_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
        0o644,
    );
    if (failed(rc)) return;
    const fd: i32 = @intCast(rc);
    const written = linux.write(fd, data.ptr, data.len);
    _ = linux.close(fd); // A failed write shows in `written`; the rename below needs it whole
    if (failed(written) or written != data.len or data.len == 0) return;
    _ = linux.rename(tmp_path, path); // Failed: the old file stays, whole
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
    write_small(path, w.buffered());
}

test "state file name matches basename piped to md5sum" {
    var buf: [128]u8 = undefined;
    // The output of `printf 'abc\n' | md5sum` starts 0bee89b07a248e27
    const p = try path_for(&buf, "/d", "/books/abc");
    try std.testing.expectEqualStrings("/d/state-0bee89b07a248e27", p);
}

test "old two-field files still load" {
    const s = parse("8 7957\n");
    try std.testing.expectEqual(@as(u32, 8), s.para);
    try std.testing.expectEqual(@as(u32, 7957), s.byte);
    try std.testing.expect(s.percent == null);
}

test "new files keep percent and time" {
    const s = parse("1 2 37 1793990000\n");
    try std.testing.expectEqual(@as(u32, 37), s.percent.?);
    try std.testing.expectEqual(@as(u64, 1793990000), s.opened);
}

test "kindle position wins until we have our own" {
    try std.testing.expect(prefer_kindle(.{}, 100));
    try std.testing.expect(prefer_kindle(.{ .para = 5, .opened = 100 }, 200));
    try std.testing.expect(!prefer_kindle(.{ .para = 5, .opened = 300 }, 200));
    try std.testing.expect(!prefer_kindle(.{ .para = 5 }, 200));
}

test "reading time is kept, and older files read as none" {
    try std.testing.expectEqual(@as(u64, 4200), parse("1 2 37 1793990000 4200\n").seconds);
    try std.testing.expectEqual(@as(u64, 0), parse("1 2 37 1793990000\n").seconds);
}

test "a book's other files sit beside its state file" {
    var buf: [128]u8 = undefined;
    const notes = try sibling(&buf, "/d/state-0bee89b07a248e27", "notes");
    try std.testing.expectEqualStrings("/d/notes-0bee89b07a248e27", notes);
    try std.testing.expectError(error.NotAStateFile, sibling(&buf, "/d/other", "notes"));
}

test "a book marked read stays read, and older files read as not" {
    const s = parse("10 20 55 1793990000 600 1\n");
    try std.testing.expect(s.finished);
    try std.testing.expect(!parse("10 20 55 1793990000 600\n").finished);
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
