//! Per-book reading state, kept in small text files beside the reader.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("file.zig");
const calls = @import("calls.zig");

pub const State = struct {
    para: u32 = 0,
    byte: u32 = 0,
    percent: ?u32 = null,
    opened: u64 = 0,
    seconds: u64 = 0, // Time spent reading this book
    /// Words from the place to the book's end, for the library to say how long is
    /// left: saved with the place, so null until a noface that counts them opens it.
    words_left: ?u64 = null,
    // Marked read: kept here for EPUBs, which the Kindle's catalog doesn't know
    finished: bool = false,
    // The Back button's place, when a jump left one, and the pages turned since: kept
    // so it's still there when the book is opened again
    back_para: ?u32 = null,
    back_byte: u32 = 0,
    back_turns: u32 = 0,
    /// How the book's paragraphs were numbered when this was saved: a file without it is
    /// 0.2.0's (`numbering_0_2`), whose numbers some EPUBs map (book.zig
    /// `text_index_from_0_2`).
    numbering: u32 = numbering_now,
};

/// The paragraphs as 0.2.0 numbered them, and as noface does since.
pub const numbering_0_2 = 1;
pub const numbering_now = 2;

/// `<dir>/state-<16 hex>`, named by the book's whole path (`key_for`).
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
/// its whole path, as a number, so two books of one file name in two folders are kept
/// apart.
pub fn key_for(book_path: []const u8) u64 {
    assert(book_path.len > 0);
    return md5_key(book_path, "");
}

/// What noface 0.2 and before named a book's files by: the md5 of "basename\n", as
/// `basename | md5sum` did, which two books of one file name shared. Read only to move
/// those files to `key_for`'s names (library/builder.zig `sync_states`, `adopt_by_name`).
pub fn key_by_name(book_path: []const u8) u64 {
    assert(book_path.len > 0);
    return md5_key(std.fs.path.basename(book_path), "\n");
}

/// A book opened before the library moved its files from the names 0.2.0 gave them
/// (a move that failed, or hasn't come yet): its place and notes copied to its own
/// names first, so it opens where it was. The old files stay for the library to move
/// or remove, as a book of the same name may be using them too; one already under the
/// new name is never written over.
pub fn adopt_by_name(state_path: [:0]const u8, book_path: []const u8) void {
    assert(book_path.len > 0);
    const dir = std.fs.path.dirname(state_path) orelse return;
    const old_key = key_by_name(book_path);
    inline for (.{ "notes", "state" }) |kind| {
        var to_buffer: [file.own_path_bytes_max]u8 = undefined;
        var from_buffer: [file.own_path_bytes_max]u8 = undefined;
        const to = sibling(&to_buffer, state_path, kind) catch return;
        const named = .{ dir, kind, old_key };
        const from = std.fmt.bufPrintSentinel(&from_buffer, "{s}/{s}-{x:0>16}", named, 0) catch
            return;
        assert(!std.mem.eql(u8, from, to)); // A whole path's name is never a file name's
        // Only into nothing, from something: an unknown either way is left alone
        if (file.presence(to) == .absent and file.presence(from) == .here) {
            // Not copied, the book opens fresh as before: and the place after the notes
            if (!file.copy_file(from, to)) return;
        }
    }
}

fn md5_key(text: []const u8, ending: []const u8) u64 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(text);
    md5.update(ending);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .big);
}

/// The kinds of file kept about a book, each "<kind>-<key>": its place, its page breaks,
/// its notes and its cover. Every one is named through `sibling`, which takes only these.
pub const kinds = [_][]const u8{ "state", "pages", "notes", "cover" };

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

fn is_kind(kind: []const u8) bool {
    for (kinds) |k| {
        if (std.mem.eql(u8, k, kind)) return true;
    }
    return false;
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
    assert(is_kind(kind)); // So moving a book's files moves every one of them
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
    // None saved (a book never opened): nothing to number
    if (content.len == 0) return .{};
    // A file that doesn't say how it numbers is 0.2.0's
    var s = State{ .numbering = numbering_0_2 };
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
    comptime assert(T == bool or T == ?u32 or T == ?u64 or @typeInfo(T) == .int);
    return switch (T) {
        bool => std.mem.eql(u8, text, "1"),
        ?u32 => std.fmt.parseInt(u32, text, 10) catch null,
        ?u64 => std.fmt.parseInt(u64, text, 10) catch null,
        else => std.fmt.parseInt(T, text, 10) catch null,
    };
}

/// The longest a state file can be: every value at its longest, each "<name> <value>\n".
const file_bytes_max = longest: {
    var total: u32 = 0;
    for (@typeInfo(State).@"struct".field_names, @typeInfo(State).@"struct".field_types) |name, T| {
        const digits_max = switch (T) {
            bool => 1,
            ?u32, u32 => std.fmt.count("{d}", .{std.math.maxInt(u32)}),
            ?u64, u64 => std.fmt.count("{d}", .{std.math.maxInt(u64)}),
            else => @compileError("a kind of value state files don't hold: " ++ @typeName(T)),
        };
        total += name.len + " ".len + digits_max + "\n".len;
    }
    break :longest total;
};

pub fn load(path: [*:0]const u8) State {
    assert(path[0] != 0);
    var buf: [file_bytes_max]u8 = undefined;
    return parse(file.read_small(path, &buf));
}

/// Writes every value of `s`, by name, one a line.
pub fn save(path: [*:0]const u8, s: State) void {
    assert(path[0] != 0);
    // Sized for the longest state, so every one is written whole
    var buf: [file_bytes_max]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    inline for (@typeInfo(State).@"struct".field_names) |field| {
        const value = @field(s, field);
        switch (@TypeOf(value)) {
            bool => w.print(field ++ " {d}\n", .{@intFromBool(value)}) catch return,
            ?u32, ?u64 => if (value) |v| w.print(field ++ " {d}\n", .{v}) catch return,
            else => w.print(field ++ " {d}\n", .{value}) catch return,
        }
    }
    // What's written reads back as the same state
    assert(std.meta.eql(parse(w.buffered()), s));
    file.write_small(path, w.buffered());
}

test "a book's files are named by its whole path, as they were by its file name" {
    var buf: [128]u8 = undefined;
    // The output of `printf '/books/abc' | md5sum` starts 4396dc83c45ebceb
    const p = try path_for(&buf, "/d", "/books/abc");
    try std.testing.expectEqualStrings("/d/state-4396dc83c45ebceb", p);
    // Two books of one name in two folders: apart now, one before
    try std.testing.expect(key_for("/books/abc") != key_for("/old/abc"));
    try std.testing.expectEqual(key_by_name("/books/abc"), key_by_name("/old/abc"));
    // As 0.2 named them: `printf 'abc\n' | md5sum` starts 0bee89b07a248e27
    try std.testing.expectEqual(@as(u64, 0x0bee89b07a248e27), key_by_name("/books/abc"));
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
    // 0.2.0 didn't say how it numbered; noface does, and none saved is now's
    try std.testing.expectEqual(@as(u32, numbering_0_2), parse("para 1\n").numbering);
    try std.testing.expectEqual(@as(u32, numbering_now), parse("para 1\nnumbering 2\n").numbering);
    try std.testing.expectEqual(@as(u32, numbering_now), parse("").numbering);
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
        .words_left = 51000,
        .finished = true,
    };
    const text = "para 12\nbyte 5\npercent 37\nopened 1793990000\nseconds 4200\n" ++
        "words_left 51000\nfinished 1\nnumbering 2\n";
    try std.testing.expectEqual(want, parse(text));
    // A value an older version didn't write reads as its default
    try std.testing.expectEqual(@as(u64, 0), parse("para 1\nbyte 2\n").seconds);
    try std.testing.expectEqual(@as(?u64, null), parse("para 1\nbyte 2\n").words_left);
    // One it doesn't know is passed over
    try std.testing.expectEqual(@as(u32, 1), parse("para 1\nshiny 9\n").para);
}

test "the longest state there can be is saved whole" {
    var buf: [file.own_path_bytes_max]u8 = undefined;
    const format = "/tmp/noface-state-test-{d}";
    const path = try std.fmt.bufPrintSentinel(&buf, format, .{calls.getpid()}, 0);
    defer _ = calls.unlink(path); // Ignored: only /tmp is left fuller
    // Every value at its longest, whatever values a state has
    var longest: State = .{};
    const info = @typeInfo(State).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        @field(longest, name) = switch (T) {
            bool => true,
            ?u32, u32 => std.math.maxInt(u32),
            ?u64, u64 => std.math.maxInt(u64),
            else => @compileError("a kind of value state files don't hold"),
        };
    }
    save(path, longest);
    try std.testing.expectEqual(longest, load(path));
}

test "a book opened before its files were moved takes a copy of its old place, never over one" {
    // In /tmp, by a book named for this run, so runs side by side don't meet
    const dir = "/tmp";
    var book_buffer: [64]u8 = undefined;
    const book_format = "/mnt/us/documents/Dune-{d}.epub";
    const book = try std.fmt.bufPrint(&book_buffer, book_format, .{calls.getpid()});
    var old_buffer: [file.own_path_bytes_max]u8 = undefined;
    const old_format = "{s}/state-{x:0>16}";
    const old_named = .{ dir, key_by_name(book) };
    const old = try std.fmt.bufPrintSentinel(&old_buffer, old_format, old_named, 0);
    defer _ = calls.unlink(old); // Ignored: only /tmp is left fuller
    var own_buffer: [file.own_path_bytes_max]u8 = undefined;
    const own = try path_for(&own_buffer, dir, book);
    defer _ = calls.unlink(own); // Ignored: only /tmp is left fuller
    save(old, .{ .para = 7, .percent = 60 });
    adopt_by_name(own, book);
    try std.testing.expectEqual(@as(?u32, 60), load(own).percent);
    try std.testing.expectEqual(@as(?u32, 60), load(old).percent); // Kept for its twins
    // Its own, once there, is never written over
    save(own, .{ .para = 9, .percent = 70 });
    adopt_by_name(own, book);
    try std.testing.expectEqual(@as(?u32, 70), load(own).percent);
}
