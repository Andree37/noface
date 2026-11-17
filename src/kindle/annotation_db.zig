//! The Kindle's annotation database: reading a book's records and queuing changes for sync.
const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const paths = @import("paths.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const failed = os.failed;
const annotations = @import("annotations.zig");
const process = @import("../sys/process.zig");
const safe = @import("safe.zig");
const Note = @import("../model/highlights.zig").Note;

/// Where stock keeps the database: a folder per account, so the shell finds it.
const database_glob = "/mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db";

/// A record's ID and where it starts and ends.
const record_fields = "annotation_id, " ++
    "json_extract(serialized_payload, '$.start_position.shortPosition'), " ++
    "json_extract(serialized_payload, '$.end_position.shortPosition')";

/// A book's records: those Amazon sent that aren't being changed here, and those
/// queued here that aren't deletes.
const read_format = "sqlite3 -separator '|' \"file:$(ls " ++ database_glob ++ ")?mode=ro\" " ++
    "\"select {s} from server_view where dataset={d} and {s} and annotation_id not in " ++
    "(select annotation_id from local_edit where {s}) " ++
    "union select {s} from local_edit where dataset={d} and action != 3 and {s}\"";

comptime {
    // The SQL file's path goes into a shell command unquoted.
    assert(std.mem.indexOfAny(u8, paths.annotation_sql, " '\"$;|&") == null);
    assert(paths.annotation_sql[0] == '/');
    assert(paths.dry_run[0] == '/'); // Found wherever noface was started from
}

/// While this file exists, annotation writes are skipped. Used by device tests.
pub fn dry_run() bool {
    const result = linux.open(paths.dry_run, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(result)) return false;
    // The file was only looked for; closing it can lose nothing.
    _ = linux.close(@intCast(result));
    return true;
}

/// A book's highlights or bookmarks, their ids in `alloc`; `out` holds the database's
/// answer while it's read.
pub fn read_notes(
    alloc: std.mem.Allocator,
    key: []const u8,
    kind: annotations.Kind,
    out: []u8,
) ![]const Note {
    assert(out.len > 0);
    const notes = try parse_notes(alloc, read_lines(key, kind, out));
    for (notes) |note| assert(note.id.len > 0); // parse_notes keeps none without one
    return notes;
}

/// The database's "id|start|end" lines as notes; a line that isn't one is skipped.
pub fn parse_notes(alloc: std.mem.Allocator, lines: []const u8) ![]const Note {
    var notes: std.ArrayList(Note) = .empty;
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        const id = fields.next() orelse continue;
        const start = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const end = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (id.len == 0) continue;
        try notes.append(alloc, .{ .id = try alloc.dupe(u8, id), .start = start, .end = end });
    }
    assert(notes.items.len <= lines.len); // A note takes a line, and a line some bytes
    for (notes.items) |note| assert(note.id.len > 0);
    return notes.toOwnedSlice(alloc);
}

/// Fetches a book's highlights or bookmarks as "id|start|end" lines, as the database
/// answers: the self-test hands them to its pretend Kindle, to open a book with its own.
pub fn read_lines(key: []const u8, kind: annotations.Kind, out: []u8) []const u8 {
    assert(out.len > 0);
    if (!safe.safe_id(key)) return "";
    var match_buf: [128]u8 = undefined;
    const book = annotations.book_match(&match_buf, key) catch return "";
    var buf: [1000]u8 = undefined;
    const dataset = kind.dataset();
    const command = std.fmt.bufPrintSentinel(&buf, read_format, .{
        record_fields, dataset, book, book, record_fields, dataset, book,
    }, 0) catch return "";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const output_size = process.run(&argv, out) orelse return "";
    assert(output_size <= out.len);
    return complete_lines(out[0..output_size], output_size == out.len);
}

/// Output that filled its buffer may end mid-line; that last line is dropped
/// rather than read as a highlight with a wrong end.
pub fn complete_lines(output: []const u8, filled: bool) []const u8 {
    if (!filled) return output;
    if (!builtin.is_test) {
        std.debug.print("highlight list cut off at {d} bytes\n", .{output.len});
    }
    const end = std.mem.lastIndexOfScalar(u8, output, '\n') orelse return "";
    const result = output[0 .. end + 1];
    assert(result.len <= output.len);
    assert(result[result.len - 1] == '\n');
    return result;
}

/// Runs a SQL statement against the annotation database.
pub fn run_annotation_sql(sql: []const u8) bool {
    assert(sql.len > 0);
    const path = paths.annotation_sql;
    const result = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (failed(result)) return false;
    const fd: i32 = @intCast(result);
    const written = linux.write(fd, sql.ptr, sql.len);
    // The statement is written or not, which `written` says; the close adds nothing.
    _ = linux.close(fd);
    if (failed(written) or written != sql.len) return false;
    const command = "sqlite3 -bail -cmd '.timeout 3000' " ++ database_glob ++ " < " ++ path ++
        " && echo ok";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    var out: [8]u8 = undefined;
    const output_size = process.run(&argv, &out) orelse return false;
    assert(output_size <= out.len);
    return std.mem.startsWith(u8, out[0..output_size], "ok");
}

test "a cut-off highlight list loses only its partial line" {
    try std.testing.expectEqualStrings(
        "a|1|2\nb|3|4\n",
        complete_lines("a|1|2\nb|3|4\nc|5|", true),
    );
    try std.testing.expectEqualStrings("a|1|2\nc|5|6", complete_lines("a|1|2\nc|5|6", false));
    try std.testing.expectEqualStrings("", complete_lines("c|5|", true));
}

test "database lines become notes, and lines that aren't are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = "kindle.h-101|101|104\nbad line\n|1|2\nx|7|9\n";
    const notes = try parse_notes(arena.allocator(), lines);
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqualStrings("kindle.h-101", notes[0].id);
    try std.testing.expectEqual(@as(u32, 104), notes[0].end);
    try std.testing.expectEqual(@as(u32, 7), notes[1].start);
}
