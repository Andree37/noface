//! Per-book reading state, kept in small text files beside the reader.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("file.zig");
const calls = @import("calls.zig");
const os = @import("os.zig");

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
    return file_path(buf, dir, .state, key_for(book_path));
}

/// A book's file of `kind`: "<dir>/<kind>-<16 hex>", the one way every name is written.
pub fn file_path(buf: []u8, dir: []const u8, kind: Kind, key: u64) ![:0]u8 {
    assert(dir.len > 0);
    const named = .{ dir, kind.name(), key };
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/{s}-{x:0>16}", named, 0);
    assert(std.mem.startsWith(u8, path, dir));
    assert(key_of_name(std.fs.path.basename(path), kind) == key); // Read back as written
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
/// new name is never written over. Which of 0.2.0's are settled, kind by kind: not one
/// there but unreadable, or not copied, and then the book's own of that kind, missing
/// in its stead, mustn't be written, as the library would then remove the old one for it.
pub fn adopt_by_name(state_path: [:0]const u8, book_path: []const u8) Adopted {
    assert(book_path.len > 0);
    var adopted: Adopted = .{};
    const dir = std.fs.path.dirname(state_path) orelse return .none;
    const old_key = key_by_name(book_path);
    // The reader's own files, in `Kind`'s order: the place after the notes
    for (std.enums.values(Kind)) |kind| {
        if (kind.remade()) continue; // Made again from the book: nothing of the reader's
        var to_buffer: [file.own_path_bytes_max]u8 = undefined;
        var from_buffer: [file.own_path_bytes_max]u8 = undefined;
        const to = sibling(&to_buffer, state_path, kind) catch return .none;
        const from = file_path(&from_buffer, dir, kind, old_key) catch return .none;
        assert(!std.mem.eql(u8, from, to)); // A whole path's name is never a file name's
        // Only into nothing: its own there, or maybe there (its read will say), is newer
        switch (file.presence(to)) {
            .here, .unknown => continue,
            .absent => {},
        }
        switch (file.presence(from)) {
            .absent => {},
            .unknown => adopted.unsettled.insert(kind),
            .here => if (!file.copy_file(from, to)) adopted.unsettled.insert(kind),
        }
    }
    return adopted;
}

/// A book's own place: its file, never written while it's unreadable or 0.2.0's isn't
/// settled, and what it held, as a book opening it reads it.
pub const Own = struct { kept: file.Kept, saved: State };

/// Opens and reads a book's own place at `path`, `adopted` saying whether 0.2.0's is
/// settled: the one way a place is opened, by the reader and by a mark from the library.
pub fn open_own(path: [*:0]const u8, adopted: Adopted) Own {
    var kept = adopted.kept(.state, path);
    assert(kept.path == path);
    const saved = load(&kept);
    if (!adopted.settled(.state)) assert(!kept.known); // Still unwritable, however it read
    return .{ .kept = kept, .saved = saved };
}

/// Which of a book's files 0.2.0 named are settled (`adopt_by_name`).
pub const Adopted = struct {
    unsettled: std.EnumSet(Kind) = .empty,

    /// None settled: the book's own paths couldn't even be named.
    pub const none: Adopted = .{ .unsettled = .full };

    pub fn settled(a: Adopted, kind: Kind) bool {
        assert(!kind.remade()); // Only the reader's own are adopted
        return !a.unsettled.contains(kind);
    }

    /// The book's own file of `kind` at `path`, never written while 0.2.0's of that
    /// kind isn't settled.
    pub fn kept(a: Adopted, kind: Kind, path: [*:0]const u8) file.Kept {
        var k = file.Kept.at(path);
        if (!a.settled(kind)) k.known = false;
        assert(k.known == a.settled(kind));
        return k;
    }
};

fn md5_key(text: []const u8, ending: []const u8) u64 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(text);
    md5.update(ending);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .big);
}

/// The kinds of file kept about a book, each "<kind>-<key>" (`file_path`). Declared in
/// the order a book's files are moved (library/builder.zig): those remade first, then
/// the notes, the place last, so a move cut short never leaves a place without its notes.
pub const Kind = enum {
    pages,
    cover,
    notes,
    state,

    /// The kind's word in its files' names: the drive's, so never a tag's name.
    pub fn name(k: Kind) []const u8 {
        const word = switch (k) {
            .pages => "pages",
            .cover => "cover",
            .notes => "notes",
            .state => "state",
        };
        // A file's name in the data folder, never a path
        assert(word.len > 0);
        assert(std.mem.indexOfScalar(u8, word, '/') == null);
        return word;
    }

    /// Made again from the book when it's missing: nothing of the reader's, so never
    /// adopted or copied to another book, only removed.
    pub fn remade(k: Kind) bool {
        return switch (k) {
            .pages, .cover => true,
            .notes, .state => false,
        };
    }
};

comptime {
    const all = std.enums.values(Kind);
    // Remade ones first, and the place last: the order a book's files move in
    for (all[1..], 1..) |k, i| assert(!(k.remade() and !all[i - 1].remade()));
    assert(all[all.len - 1] == .state);
}

/// The book's key in a file name "<kind>-<16 hex>", as `file_path` writes them; null
/// for any other name.
// Assertions: it reads a file's name from a folder: outside data.
pub fn key_of_name(name: []const u8, kind: Kind) ?u64 {
    const hex_len = 16;
    const word = kind.name();
    if (name.len != word.len + 1 + hex_len) return null;
    if (!std.mem.startsWith(u8, name, word) or name[word.len] != '-') return null;
    const hex = name[word.len + 1 ..];
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return null;
    }
    return std.fmt.parseInt(u64, hex, 16) catch null;
}

/// A place marked finished, or not. Unread, it's the book's beginning, numbered as now,
/// dated just after the last time it was opened anywhere: newer than stock's place and
/// percent, so ours win, without moving it up in recent order.
// Assertions: the place it marks was read from a file: only what it makes is its own.
pub fn mark(saved: *State, done: bool, kindle_last: u64) void {
    saved.finished = done;
    if (done) return;
    saved.para = 0;
    saved.byte = 0;
    saved.percent = 0;
    saved.words_left = null;
    saved.back_para = null; // Nowhere to go back to from a fresh start
    // The start is the start however 0.2.0 numbered the rest
    saved.numbering = numbering_now;
    // Saturating: both times come from files, and a broken one mustn't stop this
    saved.opened = @max(saved.opened, kindle_last) +| 1;
    assert(!prefer_kindle(saved.*, kindle_last));
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
pub fn sibling(buf: []u8, state_path: []const u8, kind: Kind) ![:0]u8 {
    const dir = std.fs.path.dirname(state_path) orelse ".";
    const name = std.fs.path.basename(state_path);
    const key = key_of_name(name, .state) orelse return error.NotAStateFile;
    const path = try file_path(buf, dir, kind, key);
    assert(std.mem.endsWith(u8, path, name[Kind.state.name().len..])); // The same book's
    assert(std.mem.startsWith(u8, path, dir));
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

/// The state in `kept`: a fresh one when none is saved yet, or when it's there but
/// unreadable, which leaves `kept` never to be saved over (`file.Kept`).
pub fn load(kept: *file.Kept) State {
    var buf: [file_bytes_max]u8 = undefined;
    return parse(kept.read(&buf));
}

/// The state saved at `path`, only looked at, never saved back from it.
pub fn look(path: [*:0]const u8) State {
    var kept = file.Kept.at(path);
    return load(&kept);
}

/// Writes every value of `s`, by name, one a line, unless what `kept` holds is unknown.
/// Whether it was written.
pub fn save(kept: *const file.Kept, s: State) bool {
    // Sized for the longest state, so every one is written whole
    var buf: [file_bytes_max]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    inline for (@typeInfo(State).@"struct".field_names) |field| {
        const value = @field(s, field);
        switch (@TypeOf(value)) {
            bool => w.print(field ++ " {d}\n", .{@intFromBool(value)}) catch return false,
            ?u32, ?u64 => if (value) |v| w.print(field ++ " {d}\n", .{v}) catch return false,
            else => w.print(field ++ " {d}\n", .{value}) catch return false,
        }
    }
    // What's written reads back as the same state
    assert(std.meta.eql(parse(w.buffered()), s));
    return kept.write(&.{w.buffered()});
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
    const key = key_of_name("state-0bee89b07a248e27", .state);
    try std.testing.expectEqual(@as(?u64, 0x0bee89b07a248e27), key);
    try std.testing.expectEqual(@as(?u64, null), key_of_name("state-0bee89b07a248e2", .state));
    try std.testing.expectEqual(@as(?u64, null), key_of_name("cover-0bee89b07a248e27", .state));
    try std.testing.expectEqual(@as(?u64, null), key_of_name("state-0BEE89B07A248E27", .state));
}

test "a book's files keep the names they have on the drive" {
    var buf: [128]u8 = undefined;
    // Each kind's name, pinned: a different one would leave every reader's files behind
    const want = [_][]const u8{
        "/d/pages-0bee89b07a248e27",
        "/d/cover-0bee89b07a248e27",
        "/d/notes-0bee89b07a248e27",
        "/d/state-0bee89b07a248e27",
    };
    for (std.enums.values(Kind), want) |kind, path| {
        const written = try file_path(&buf, "/d", kind, 0x0bee89b07a248e27);
        try std.testing.expectEqualStrings(path, written);
    }
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
    const notes = try sibling(&buf, "/d/state-0bee89b07a248e27", .notes);
    try std.testing.expectEqualStrings("/d/notes-0bee89b07a248e27", notes);
    try std.testing.expectError(error.NotAStateFile, sibling(&buf, "/d/other", .notes));
    const not_state = "/d/notes-0bee89b07a248e27";
    try std.testing.expectError(error.NotAStateFile, sibling(&buf, not_state, .notes));
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
    try std.testing.expect(save(&file.Kept.at(path), longest));
    try std.testing.expectEqual(longest, look(path));
}

test "a book opened before its files moved takes its notes and place, never over its own" {
    // In /tmp, by a book named for this run, so runs side by side don't meet
    const dir = "/tmp";
    var book_buffer: [64]u8 = undefined;
    const book_format = "/mnt/us/documents/Dune-{d}.epub";
    const book = try std.fmt.bufPrint(&book_buffer, book_format, .{calls.getpid()});
    var own_buffer: [file.own_path_bytes_max]u8 = undefined;
    const own = try path_for(&own_buffer, dir, book);
    // Every kind of the reader's own, as 0.2.0 named it, the kind's name its content
    for (std.enums.values(Kind)) |kind| {
        if (kind.remade()) continue;
        var old_buffer: [file.own_path_bytes_max]u8 = undefined;
        const old = try file_path(&old_buffer, dir, kind, key_by_name(book));
        try std.testing.expect(file.write_small(old, kind.name()));
    }
    defer for (std.enums.values(Kind)) |kind| {
        var old_buffer: [file.own_path_bytes_max]u8 = undefined;
        var own_kind_buffer: [file.own_path_bytes_max]u8 = undefined;
        const old = file_path(&old_buffer, dir, kind, key_by_name(book)) catch continue;
        const own_kind = sibling(&own_kind_buffer, own, kind) catch continue;
        _ = calls.unlink(old); // Ignored: only /tmp is left fuller
        _ = calls.unlink(own_kind); // Ignored: only /tmp is left fuller
    };
    try std.testing.expect(adopt_by_name(own, book).unsettled.count() == 0);
    for (std.enums.values(Kind)) |kind| {
        var own_kind_buffer: [file.own_path_bytes_max]u8 = undefined;
        var old_buffer: [file.own_path_bytes_max]u8 = undefined;
        var read_buffer: [16]u8 = undefined;
        const own_kind = try sibling(&own_kind_buffer, own, kind);
        const old = try file_path(&old_buffer, dir, kind, key_by_name(book));
        if (kind.remade()) {
            try std.testing.expect(!file.exists(own_kind)); // Made again, never adopted
        } else {
            const adopted = try file.read_small(own_kind, &read_buffer);
            try std.testing.expectEqualStrings(kind.name(), adopted);
            try std.testing.expect(file.exists(old)); // Kept for its twins
        }
    }
    // Its own, once there, is never written over
    try std.testing.expect(save(&file.Kept.at(own), .{ .para = 9, .percent = 70 }));
    try std.testing.expect(adopt_by_name(own, book).unsettled.count() == 0);
    try std.testing.expectEqual(@as(?u32, 70), look(own).percent);
}

test "an old place there but unreadable leaves a book's files unsettled" {
    const dir = "/tmp";
    var book_buffer: [64]u8 = undefined;
    const book_format = "/mnt/us/documents/Unread-{d}.epub";
    const book = try std.fmt.bufPrint(&book_buffer, book_format, .{calls.getpid()});
    var own_buffer: [file.own_path_bytes_max]u8 = undefined;
    const own = try path_for(&own_buffer, dir, book);
    var old_buffer: [file.own_path_bytes_max]u8 = undefined;
    const old = try file_path(&old_buffer, dir, .state, key_by_name(book));
    // A link to itself: there, and never opened
    try std.testing.expect(!os.failed(calls.symlink(old, old)));
    defer _ = calls.unlink(old); // Ignored: only /tmp is left fuller
    const adopted = adopt_by_name(own, book);
    try std.testing.expect(!adopted.settled(.state));
    try std.testing.expect(adopted.settled(.notes)); // Its notes, another kind, are
    try std.testing.expect(!file.exists(own)); // Nothing written in its stead
}
