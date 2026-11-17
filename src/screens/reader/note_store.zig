//! Where an open book's highlights and bookmarks are kept, chosen once as it opens:
//! the Kindle's own database for a book Amazon syncs (stock's sync then sends them on),
//! a file of noface's beside the book's state for one it doesn't (an EPUB copied over
//! the cable), or nowhere while device tests switch writes off.
//!
//! The file has a line per note: "<highlight|bookmark> <id> <start> <end>", with
//! character positions like Amazon's.
const std = @import("std");
const assert = std.debug.assert;
const annotations = @import("../../kindle/annotations.zig");
const annotation_db = @import("../../kindle/annotation_db.zig");
const lipc = @import("../../kindle/lipc.zig");
const safe = @import("../../kindle/safe.zig");
const catalog = @import("../../model/catalog.zig");
const state = @import("../../sys/state.zig");
const file = @import("../../sys/file.zig");
const os = @import("../../sys/os.zig");
const files = @import("../../library/files.zig");
const calls = @import("../../sys/calls.zig");

pub const Note = @import("../../model/highlights.zig").Note;

pub const NoteStore = union(enum) {
    /// The Kindle's database, by the book's key, type and GUID.
    amazon: *const catalog.Entry,
    /// The file noface keeps beside the book's state, at this path.
    own_file: [:0]const u8,
    /// Nowhere: writes are switched off (annotation_db.dry_run), and nothing is read.
    off,

    /// The store for `entry`, whose state file is at `state_path`.
    pub fn choose(
        alloc: std.mem.Allocator,
        entry: *const catalog.Entry,
        state_path: []const u8,
    ) !NoteStore {
        assert(state_path.len > 0);
        if (annotation_db.dry_run()) return .off;
        if (!entry.is_epub()) return .{ .amazon = entry };
        var buffer: [files.path_bytes_max]u8 = undefined;
        const path = try state.sibling(&buffer, state_path, "notes");
        assert(path.len > 0);
        return .{ .own_file = try alloc.dupeSentinel(u8, path, 0) };
    }

    /// The notes of one kind, their ids in `alloc`. `stored` holds the database's answer.
    pub fn read(
        store: NoteStore,
        alloc: std.mem.Allocator,
        kind: annotations.Kind,
        stored: []u8,
    ) ![]const Note {
        assert(stored.len > 0);
        const notes = switch (store) {
            .amazon => |entry| try annotation_db.read_notes(alloc, entry.key, kind, stored),
            .own_file => |path| try read_file(alloc, path, kind),
            .off => &.{},
        };
        for (notes) |note| assert(note.id.len > 0); // Both readers keep none without one
        return notes;
    }

    /// Saves a note, replacing any with the same id. True when it was kept.
    pub fn put(
        store: NoteStore,
        kind: annotations.Kind,
        id: []const u8,
        start: annotations.Point,
        end: annotations.Point,
    ) bool {
        if (kind == .bookmark) assert(start.short == end.short); // A bookmark is a point
        assert(id.len > 0);
        return switch (store) {
            .amazon => |entry| put_amazon(entry, kind, id, start, end),
            .own_file => |path| rewrite(path, id, .{
                .kind = kind,
                .start = start.short,
                .end = end.short,
            }),
            .off => true,
        };
    }

    /// Removes a note. True when it's gone, even if it wasn't there.
    pub fn remove(store: NoteStore, kind: annotations.Kind, id: []const u8) bool {
        assert(id.len > 0);
        if (store == .own_file) assert(store.own_file[0] == '/'); // Never relative
        return switch (store) {
            .amazon => |entry| remove_amazon(entry, kind, id),
            .own_file => |path| rewrite(path, id, null),
            .off => true,
        };
    }

    /// Asks Amazon to send what was just written: only the database's notes go anywhere.
    pub fn sync(store: NoteStore) void {
        switch (store) {
            .amazon => lipc.sync_now(),
            .own_file, .off => {},
        }
    }
};

fn put_amazon(
    entry: *const catalog.Entry,
    kind: annotations.Kind,
    id: []const u8,
    start: annotations.Point,
    end: annotations.Point,
) bool {
    assert(!entry.is_epub());
    if (!safe.safe_id(entry.key) or !safe.safe_id(entry.kind)) return false;
    if (!safe.safe_id(id) or !safe.safe_guid(entry.guid)) return false;
    var buffer: [1200]u8 = undefined;
    const sql = annotations.insert_sql(&buffer, .{
        .kind = kind,
        .id = id,
        .key = entry.key,
        .content_type = entry.kind,
        .guid = entry.guid,
        .start = start,
        .end = end,
        .now_ms = os.unix_time() * 1000,
    }) catch return false;
    assert(std.mem.endsWith(u8, sql, ";")); // A whole statement
    return annotation_db.run_annotation_sql(sql);
}

fn remove_amazon(entry: *const catalog.Entry, kind: annotations.Kind, id: []const u8) bool {
    assert(!entry.is_epub());
    if (!safe.safe_id(id) or !safe.safe_id(entry.key)) return false;
    var buffer: [900]u8 = undefined;
    const now_ms = os.unix_time() * 1000;
    const sql = annotations.delete_sql(&buffer, kind, id, entry.key, now_ms) catch return false;
    assert(std.mem.endsWith(u8, sql, ";")); // A whole transaction, through its commit
    return annotation_db.run_annotation_sql(sql);
}

/// A note as the file keeps it.
const Line = struct { kind: annotations.Kind, start: u32, end: u32 };

/// The file's notes of `kind`. An error when the file is there but can't be read: taken
/// for none, the book would open without them, and the next note saved could take one's
/// id and write over it.
fn read_file(
    alloc: std.mem.Allocator,
    path: [*:0]const u8,
    kind: annotations.Kind,
) ![]const Note {
    assert(path[0] == '/');
    const data = file.map(path) catch |err| switch (err) {
        // None written yet, or every one removed (which leaves the file empty)
        error.NotFound, error.EmptyFile => return &.{},
        error.OpenFailed, error.SeekFailed, error.MmapFailed => return err,
    };
    defer file.unmap(data);
    var out: std.ArrayList(Note) = .empty;
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |text| {
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        const named = std.meta.stringToEnum(annotations.Kind, words.next() orelse continue);
        if (named != kind) continue;
        const id = words.next() orelse continue;
        const start = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        const end = std.fmt.parseInt(u32, words.next() orelse continue, 10) catch continue;
        try out.append(alloc, .{ .id = try alloc.dupe(u8, id), .start = start, .end = end });
    }
    assert(out.items.len <= data.len); // A note takes a line, and a line some bytes
    return out.toOwnedSlice(alloc);
}

/// Writes every note but `id`'s, then `line` if any, into "<path>.new" and renames it
/// over the old file, so a crash leaves the old notes whole. False, and nothing written,
/// when the old file is there but can't be read: written over, its notes would be lost.
fn rewrite(path: [:0]const u8, id: []const u8, line: ?Line) bool {
    // Ids are made here or read back from this file a word at a time: each is one word
    assert(std.mem.indexOfAny(u8, id, " \n") == null);
    var fresh_buffer: [files.path_bytes_max + 4]u8 = undefined;
    const fresh = std.fmt.bufPrintSentinel(&fresh_buffer, "{s}.new", .{path}, 0) catch
        return false;
    assert(std.mem.endsWith(u8, fresh, ".new")); // Beside the real file, never over it
    const old: ?[]const u8 = file.map(path) catch |err| switch (err) {
        // None written yet, or every one removed (which leaves the file empty)
        error.NotFound, error.EmptyFile => null,
        error.OpenFailed, error.SeekFailed, error.MmapFailed => return false,
    };
    defer if (old) |o| file.unmap(o);
    var write_buffer: [4096]u8 = undefined;
    var out = files.Writer.create(fresh, &write_buffer) catch return false;
    if (old) |o| copy_others(&out, o, id);
    if (line) |l| {
        var text: [64 + safe.id_size_max]u8 = undefined;
        const kind_name = @tagName(l.kind);
        const format = "{s} {s} {d} {d}\n";
        out.write(std.fmt.bufPrint(&text, format, .{ kind_name, id, l.start, l.end }) catch {
            out.abandon();
            files.remove(fresh);
            return false;
        });
    }
    _ = out.finish() catch {
        files.remove(fresh);
        return false;
    };
    files.replace(fresh, path) catch {
        files.remove(fresh);
        return false;
    };
    return true;
}

/// Copies `old`'s lines but `id`'s note into `out`.
fn copy_others(out: *files.Writer, old: []const u8, id: []const u8) void {
    assert(id.len > 0);
    assert(old.len > 0); // file.map maps no empty file
    var lines = std.mem.tokenizeScalar(u8, old, '\n');
    while (lines.next()) |text| {
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        _ = words.next(); // Its kind
        const its_id = words.next() orelse continue; // Not a note: dropped
        if (std.mem.eql(u8, its_id, id)) continue;
        out.write(text);
        out.write("\n");
    }
}

fn test_store(buffer: []u8, name: []const u8) !NoteStore {
    const pid = calls.getpid();
    const format = "/tmp/noface-notes-{d}-{s}";
    const path = try std.fmt.bufPrintSentinel(buffer, format, .{ pid, name }, 0);
    assert(std.mem.startsWith(u8, path, "/tmp/noface-notes-"));
    assert(std.mem.endsWith(u8, path, name)); // Each test its own file
    files.remove(path);
    return .{ .own_file = path };
}

fn point(short: u32) annotations.Point {
    return .{ .element = 1, .offset = 0, .short = short };
}

test "notes come back by kind, put replaces by id, and remove keeps the others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buffer: [128]u8 = undefined;
    const store = try test_store(&buffer, "kinds");
    defer files.remove(store.own_file);
    var stored: [16]u8 = undefined;
    // None yet: no file
    try std.testing.expectEqual(@as(usize, 0), (try store.read(alloc, .highlight, &stored)).len);
    try std.testing.expect(store.put(.highlight, "h1", point(10), point(20)));
    try std.testing.expect(store.put(.bookmark, "b1", point(30), point(30)));
    try std.testing.expect(store.put(.highlight, "h2", point(40), point(50)));
    try std.testing.expect(store.put(.highlight, "h1", point(11), point(21))); // Moved
    const marks = try store.read(alloc, .highlight, &stored);
    try std.testing.expectEqual(@as(usize, 2), marks.len);
    try std.testing.expectEqualStrings("h2", marks[0].id);
    try std.testing.expectEqual(@as(u32, 11), marks[1].start);
    try std.testing.expect(store.remove(.highlight, "h2"));
    try std.testing.expect(store.remove(.highlight, "never-there"));
    try std.testing.expectEqual(@as(usize, 1), (try store.read(alloc, .highlight, &stored)).len);
    try std.testing.expectEqual(@as(usize, 1), (try store.read(alloc, .bookmark, &stored)).len);
}

test "many notes are kept, however many there are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    const store = try test_store(&buffer, "many");
    defer files.remove(store.own_file);
    var id_buffer: [16]u8 = undefined;
    for (0..2000) |i| {
        const id = try std.fmt.bufPrint(&id_buffer, "h{d}", .{i});
        const at: u32 = @intCast(i * 10);
        try std.testing.expect(store.put(.highlight, id, point(at), point(at + 5)));
    }
    var stored: [16]u8 = undefined;
    const notes = try store.read(arena.allocator(), .highlight, &stored);
    try std.testing.expectEqual(@as(usize, 2000), notes.len);
}

test "notes that are there but can't be read are never written over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    const store = try test_store(&buffer, "unreadable");
    defer files.remove(store.own_file);
    try std.testing.expect(store.put(.highlight, "h1", point(10), point(20)));
    try std.testing.expect(store.put(.highlight, "h2", point(30), point(40)));
    // A link to itself is there but can't be opened, as on a drive that fails a read
    files.remove(store.own_file);
    const linked = calls.symlink(store.own_file, store.own_file);
    try std.testing.expect(!os.failed(linked));
    try std.testing.expect(!store.put(.highlight, "h3", point(50), point(60)));
    try std.testing.expect(!store.remove(.highlight, "h1"));
    var stored: [16]u8 = undefined;
    const read = store.read(arena.allocator(), .highlight, &stored);
    try std.testing.expectError(error.OpenFailed, read);
    // Still the link: nothing was renamed over it
    try std.testing.expectError(error.OpenFailed, file.map(store.own_file));
    var fresh_buffer: [160]u8 = undefined;
    const fresh = try std.fmt.bufPrintSentinel(&fresh_buffer, "{s}.new", .{store.own_file}, 0);
    try std.testing.expect(!file.exists(fresh));
}

test "the last note removed leaves an empty file, which takes the next" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    const store = try test_store(&buffer, "emptied");
    defer files.remove(store.own_file);
    try std.testing.expect(store.put(.bookmark, "b1", point(5), point(5)));
    try std.testing.expect(store.remove(.bookmark, "b1"));
    try std.testing.expectError(error.EmptyFile, file.map(store.own_file));
    var stored: [16]u8 = undefined;
    try std.testing.expectEqual(0, (try store.read(arena.allocator(), .bookmark, &stored)).len);
    try std.testing.expect(store.put(.bookmark, "b2", point(7), point(7)));
    const marks = try store.read(arena.allocator(), .bookmark, &stored);
    try std.testing.expectEqual(1, marks.len);
}

test "a store that's off keeps nothing and reads nothing" {
    const store: NoteStore = .off;
    try std.testing.expect(store.put(.highlight, "h1", point(1), point(2)));
    var stored: [16]u8 = undefined;
    const notes = try store.read(std.testing.allocator, .highlight, &stored);
    try std.testing.expectEqual(@as(usize, 0), notes.len);
}
