//! The Kindle's annotation database: reading a book's records and queuing changes for sync.
const std = @import("std");
const assert = std.debug.assert;
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

/// Starts a command with the one database it works on in `$db`: the one changed last,
/// the current account's, where an earlier account's folder can be there too and the
/// glob would name two. With none there the command stops here and prints nothing.
const find_database = "db=\"$(ls -t " ++ database_glob ++ " 2>/dev/null | head -n 1)\" && " ++
    "[ -n \"$db\" ] && ";

/// A record's ID and where it starts and ends.
const record_fields = "annotation_id, " ++
    "json_extract(serialized_payload, '$.start_position.shortPosition'), " ++
    "json_extract(serialized_payload, '$.end_position.shortPosition')";

/// A book's records: those Amazon sent that aren't being changed here, and those
/// queued here that aren't deletes; a page of them at a time, in the ids' order, so
/// any number are read through one page's room (`read_page`). Waits a moment for a
/// database busy with a write, as the write does, and says `end_mark` once sqlite3 has
/// answered whole: an answer without it, locked, missing, cut short or slow, is no answer.
const read_format = find_database ++ "sqlite3 -separator '|' -cmd '.timeout 3000' " ++
    "\"file:$db?mode=ro\" " ++
    "\"select * from (select {s} from server_view where dataset={d} and {s} and " ++
    "annotation_id not in (select annotation_id from local_edit where {s}) " ++
    "union select {s} from local_edit where dataset={d} and action != 3 and {s}) " ++
    "order by 1 limit {d} offset {d}\" && echo " ++ end_mark;
/// The line after a whole answer, never a record's: one has two '|' in it.
pub const end_mark = "end";
/// Room for `read_format` filled in: two record fields, four book matches (each fits
/// `read_lines`'s buffer for it), two dataset numbers, and a page's limit and offset.
const read_command_bytes_max = 1600;

/// The longest line the database answers: an id, two positions, two '|' and its end.
const line_bytes_max = safe.id_size_max + 2 * std.fmt.count("{d}", .{std.math.maxInt(u32)}) + 3;
/// A page of the answer: as many records as it holds at their longest, and the end mark.
pub const Page = [64 * 1024]u8;
pub const page_rows = (@sizeOf(Page) - end_line.len) / line_bytes_max;
const end_line = end_mark ++ "\n";
/// Pages read at most for one book, one kind: more than any book's notes, a bound on
/// the loop, never met by a real Kindle's.
const pages_max = std.math.maxInt(u32) / page_rows;
const book_match_bytes_max = annotations.book_match_bytes_max;

/// Runs the SQL in `paths.annotation_sql` on the database, saying "ok" if it all took.
const write_command = find_database ++ "sqlite3 -bail -cmd '.timeout 3000' \"$db\" < " ++
    paths.annotation_sql ++ " && echo ok";

comptime {
    assert(read_format.len + 2 * record_fields.len + 4 * book_match_bytes_max + 4 * 10 <
        read_command_bytes_max);
    assert(page_rows > 0);
    // The SQL file's path goes into a shell command unquoted.
    assert(std.mem.indexOfAny(u8, paths.annotation_sql, " '\"$;|&") == null);
    assert(paths.annotation_sql[0] == '/');
    assert(paths.dry_run[0] == '/'); // Found wherever noface was started from
    assert(std.mem.indexOfScalar(u8, end_mark, '|') == null); // Never read as a record
}

/// While this file exists, annotation writes are skipped. Used by device tests.
pub fn dry_run() bool {
    const result = linux.open(paths.dry_run, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(result)) return false;
    // Ignored: the file was only looked for; closing it can lose nothing.
    _ = linux.close(@intCast(result));
    return true;
}

/// A book's highlights or bookmarks, their ids in `alloc`, or null when the database
/// gave no whole answer: never taken for none, which would show the book without them.
pub fn read_notes(
    alloc: std.mem.Allocator,
    key: []const u8,
    kind: annotations.Kind,
) !?[]const Note {
    var page: Page = undefined;
    var notes: std.ArrayList(Note) = .empty;
    // A page at a time, until one isn't full: however many a book has, all are read
    for (0..pages_max) |index| {
        const read = read_page(key, kind, &page, index * page_rows) orelse return null;
        try parse_notes(alloc, read.lines, &notes);
        if (read.rows < page_rows) break;
    }
    for (notes.items) |note| assert(note.id.len > 0); // parse_notes keeps none without one
    const all: []const Note = try notes.toOwnedSlice(alloc);
    return all;
}

/// The database's "id|start|end" lines as notes, onto `notes`; a line that isn't one
/// is skipped.
pub fn parse_notes(alloc: std.mem.Allocator, lines: []const u8, notes: *std.ArrayList(Note)) !void {
    const before = notes.items.len;
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        const id = fields.next() orelse continue;
        const start = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const end = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        if (id.len == 0) continue;
        try notes.append(alloc, .{ .id = try alloc.dupe(u8, id), .start = start, .end = end });
    }
    // A note takes a line, and a line some bytes
    assert(notes.items.len - before <= lines.len);
}

/// One page of the database's answer: its "id|start|end" lines, and how many rows the
/// database gave, so a page holding fewer than `page_rows` is the last.
pub const Read = struct { lines: []const u8, rows: u64 };

/// Fetches page rows `first_row` on of a book's highlights or bookmarks as the database
/// answers them: the self-test hands them to its pretend Kindle, to open a book with its
/// own. Null when there's no whole answer: the database couldn't be asked, or didn't
/// say its end mark (locked, missing, cut short, too slow).
pub fn read_page(key: []const u8, kind: annotations.Kind, page: *Page, first_row: u64) ?Read {
    if (!safe.safe_id(key)) return null; // Not a book this database could name
    var match_buf: [book_match_bytes_max]u8 = undefined;
    const book = annotations.book_match(&match_buf, key) catch return null;
    var buf: [read_command_bytes_max]u8 = undefined;
    const dataset = kind.dataset();
    const command = std.fmt.bufPrintSentinel(&buf, read_format, .{
        record_fields, dataset, book, book, record_fields, dataset, book, page_rows, first_row,
    }, 0) catch return null;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const output_size = process.run(&argv, page) orelse return null;
    assert(output_size <= page.len);
    // Whole only when it ends with the mark sqlite3's success adds: then the rows are
    // all there, `page_rows` of them at their longest fitting a page
    const answer = page[0..output_size];
    if (!std.mem.endsWith(u8, answer, end_line)) return null;
    const lines = answer[0 .. answer.len - end_line.len];
    const rows = std.mem.count(u8, lines, "\n");
    // More than it asked for is no answer of the database's: taken for none at all
    if (rows > page_rows) return null;
    return .{ .lines = lines, .rows = rows };
}

/// Runs a SQL statement against the annotation database.
pub fn run_annotation_sql(sql: []const u8) bool {
    assert(sql.len > 0);
    const path = paths.annotation_sql;
    const result = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (failed(result)) return false;
    const fd: i32 = @intCast(result);
    const written = linux.write(fd, sql.ptr, sql.len);
    // Ignored: the statement is written or not, which `written` says; the close adds nothing.
    _ = linux.close(fd);
    if (failed(written) or written != sql.len) return false;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", write_command };
    var out: [8]u8 = undefined;
    const output_size = process.run(&argv, &out) orelse return false;
    assert(output_size <= out.len);
    return std.mem.startsWith(u8, out[0..output_size], "ok");
}

test "reads and writes each work on one database, the newest, and none when there's none" {
    for ([_][]const u8{ read_format, write_command }) |command| {
        try std.testing.expect(std.mem.startsWith(u8, command, find_database));
        // The glob is expanded once, by `ls`, never handed to sqlite3 as many files
        try std.testing.expectEqual(1, std.mem.count(u8, command, database_glob));
        try std.testing.expectEqual(1, std.mem.count(u8, command, "$(ls -t "));
        try std.testing.expect(std.mem.indexOf(u8, command, "| head -n 1)") != null);
        try std.testing.expect(std.mem.indexOf(u8, command, "[ -n \"$db\" ] && sqlite3") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, read_format, "\"file:$db?mode=ro\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_command, "'.timeout 3000' \"$db\" <") != null);
}

comptime {
    // A page's rows at their longest fit it, so no answer is ever cut mid-line
    assert(page_rows * line_bytes_max <= @sizeOf(Page));
}

test "database lines become notes, and lines that aren't are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = "kindle.h-101|101|104\nbad line\n|1|2\nx|7|9\n";
    var list: std.ArrayList(Note) = .empty;
    try parse_notes(arena.allocator(), lines, &list);
    const notes = list.items;
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqualStrings("kindle.h-101", notes[0].id);
    try std.testing.expectEqual(@as(u32, 104), notes[0].end);
    try std.testing.expectEqual(@as(u32, 7), notes[1].start);
}
