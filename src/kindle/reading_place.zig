//! A book's reading places on a Kindle, in its annotation database: where the stock
//! reader left it on this Kindle (`kindle.local_most_recent_read`, kept only here), and
//! where Amazon has it from every device (`kindle.most_recent_read`, the place the
//! Kindle apps open at, and `kindle.last_read`, the furthest read, which only moves
//! forward). Read once as a book opens; kept as noface closes it or locks, queued for
//! Amazon as the stock reader queues them, so the Kindle apps and other devices open
//! where noface left off. A book is named as its highlights are (`annotations.name_of`).
//! (Found on firmware 5.20: docs/DEVELOPING.md.)
const std = @import("std");
const assert = std.debug.assert;
const annotation_db = @import("annotation_db.zig");
const annotations = @import("annotations.zig");
const lipc = @import("lipc.zig");
const safe = @import("safe.zig");
const os = @import("../sys/os.zig");
const book_model = @import("../model/book.zig");
const catalog = @import("../model/catalog.zig");
const highlights = @import("../model/highlights.zig");
const place = @import("../model/place.zig");

/// The records a book's places are, by their dataset in the database and their id.
const Record = enum(u8) {
    most_recent_read = 4,
    local_most_recent_read = 8,
    last_read = 9,

    fn id(r: Record) []const u8 {
        return switch (r) {
            .most_recent_read => "kindle.most_recent_read",
            .local_most_recent_read => "kindle.local_most_recent_read",
            .last_read => "kindle.last_read",
        };
    }
};

/// What Amazon's software calls this Kindle in a place it made here.
const this_device_name = "Local";

/// How long the question as a book opens may take: past it, nothing is known.
const ask_ms_max = 1500;

/// A book as Amazon's records name it, made as it opens: its dataset id and its JSON,
/// copied, so nothing of the library's is borrowed while the book is open.
pub const Book = struct {
    id_bytes: [annotations.book_name_bytes_max]u8 = undefined,
    id_len: u16 = 0,
    data_bytes: [annotations.book_name_bytes_max]u8 = undefined,
    data_len: u16 = 0,
    /// Amazon's furthest read as the book opened: `last_read` moves only past it.
    furthest: ?u32 = null,

    fn id(b: *const Book) []const u8 {
        assert(b.id_len > 0);
        assert(b.id_len <= b.id_bytes.len);
        return b.id_bytes[0..b.id_len];
    }

    /// The book as `name` names it, or null for one whose ids can't go into SQL.
    fn of(name: annotations.BookName) ?Book {
        if (!name.is_safe()) return null;
        var b: Book = .{};
        const named = annotations.book_id(&b.id_bytes, name) catch return null;
        b.id_len = @intCast(named.len);
        const held = annotations.book_data(&b.data_bytes, name) catch return null;
        b.data_len = @intCast(held.len);
        assert(b.id_len > 0);
        return b;
    }

    fn data(b: *const Book) []const u8 {
        assert(b.data_len > 0);
        assert(b.data_len <= b.data_bytes.len);
        return b.data_bytes[0..b.data_len];
    }
};

/// What a book's opening found: its outside place, and the book as named to keep one,
/// or null when nothing may be written (none known, or the answer wasn't whole).
pub const Found = struct { answer: place.Answer, book: ?Book };

/// Asks the database once for `entry`'s places and its name there.
pub fn look(entry: *const catalog.Entry, paragraphs: []const book_model.Paragraph) Found {
    assert(paragraphs.len > 0);
    // An EPUB copied over the cable has no key: the database names nothing for it
    if (!safe.safe_id(entry.key)) return .{ .answer = .none, .book = null };
    var sql_buf: [annotation_db.ask_command_bytes_max]u8 = undefined;
    const sql = question(&sql_buf, entry.key) catch return .{ .answer = .unknown, .book = null };
    var out: [answer_bytes_max]u8 = undefined;
    const deadline = os.now_us() + ask_ms_max * std.time.us_per_ms;
    const lines = annotation_db.ask(sql, &out, deadline) orelse
        return .{ .answer = .unknown, .book = null };
    assert(lines.len <= out.len);
    const rows = parse(lines);
    // Device tests read places but write none (annotation_db.dry_run)
    var book = if (annotation_db.dry_run()) null else Book.of(annotations.name_of(entry));
    if (book) |*b| b.furthest = rows.furthest;
    return .{ .answer = newest(rows, paragraphs), .book = book };
}

/// Keeps `at` as the book's place on this Kindle and queues it for Amazon, stamped
/// `when_s`, the time noface saved it with. True when the database took it.
pub fn keep(
    book: *const Book,
    paragraphs: []const book_model.Paragraph,
    at: book_model.Pos,
    when_s: u64,
) bool {
    assert(at.para < paragraphs.len);
    assert(when_s > 0); // A save's time
    const short = short_before(paragraphs, at) orelse return false;
    var buf: [keep_sql_bytes_max]u8 = undefined;
    const sql = keep_sql(&buf, book, short, when_s * std.time.ms_per_s) catch return false;
    return annotation_db.run_annotation_sql(sql);
}

/// The book's place outside noface back at its start, stamped `when_s`, the time of
/// the mark that started it over: Amazon's furthest read stays, as it only moves on.
/// True when the database took it, or there's no place outside noface to start over.
pub fn start_over(entry: *const catalog.Entry, when_s: u64) bool {
    assert(when_s > 0); // A save's time
    // An EPUB copied over the cable has no key: no place of it is kept outside noface
    if (!safe.safe_id(entry.key)) return true;
    if (annotation_db.dry_run()) return true; // Device tests write none
    var book = Book.of(annotations.name_of(entry)) orelse return false;
    book.furthest = std.math.maxInt(u32); // Never moved back
    var buf: [keep_sql_bytes_max]u8 = undefined;
    const sql = keep_sql(&buf, &book, book_start, when_s * std.time.ms_per_s) catch return false;
    assert(std.mem.indexOf(u8, sql, Record.last_read.id()) == null);
    return annotation_db.run_annotation_sql(sql);
}

/// Where the book ends in Amazon's positions: the end of the last paragraph it numbers,
/// or null for a book it numbers none of (an EPUB copied over the cable).
pub fn end(paragraphs: []const book_model.Paragraph) ?u32 {
    var para = paragraphs.len;
    while (para > 0) { // Bounded by the paragraph count
        para -= 1;
        const p = &paragraphs[para];
        if (highlights.short_at(p, @intCast(p.text.len))) |short| return short;
    }
    return null;
}

/// Amazon's position for a book's start.
const book_start = 0;

/// Asks the Kindle to send what was queued: once, as a book closes.
pub fn send() void {
    lipc.sync_now();
}

/// Amazon's position for `at`, or for the start of the nearest paragraph before it that
/// Amazon numbers: a place in one it doesn't number goes by that.
fn short_before(paragraphs: []const book_model.Paragraph, at: book_model.Pos) ?u32 {
    assert(at.para < paragraphs.len);
    assert(at.byte <= paragraphs[at.para].text.len);
    if (highlights.short_at(&paragraphs[at.para], at.byte)) |short| return short;
    var para = at.para;
    while (para > 0) { // Bounded by the paragraph count
        para -= 1;
        if (highlights.short_at(&paragraphs[para], 0)) |short| return short;
    }
    return null;
}

// The question

/// One line a place: `<dataset>|<short>|<time ms>|<device>`, in any order.
const question_format = "select dataset, " ++
    "json_extract(serialized_payload, '$.position.shortPosition'), " ++
    "modified_time, json_extract(serialized_payload, '$.device_name') " ++
    "from server_view where {[match]s} and dataset in (4, 9) " ++
    "union all select dataset, json_extract(start_position, '$.shortPosition'), " ++
    "modified_time, '" ++ this_device_name ++ "' " ++
    "from nonsyncable_annotations where {[book]s} and dataset = 8;";
/// A book's rows, by the column naming the book: its key and the dash after it.
const match_format = "substr({s}, 1, {d}) = '{s}-'";
const match_bytes_max = match_format.len + 16 + safe.id_size_max;

comptime {
    // The datasets the question names are the records'
    assert(@backingInt(Record.most_recent_read) == 4);
    assert(@backingInt(Record.last_read) == 9);
    assert(@backingInt(Record.local_most_recent_read) == 8);
}

fn question(buf: []u8, key: []const u8) ![]const u8 {
    assert(safe.safe_id(key));
    var match_buf: [match_bytes_max]u8 = undefined;
    const prefix = key.len + 1; // The key and the dash after it
    const match = try std.fmt.bufPrint(&match_buf, match_format, .{ "dataset_id", prefix, key });
    var book_buf: [match_bytes_max]u8 = undefined;
    const book = try std.fmt.bufPrint(&book_buf, match_format, .{ "book_id", prefix, key });
    const sql = try std.fmt.bufPrint(buf, question_format, .{ .match = match, .book = book });
    assert(std.mem.endsWith(u8, sql, ";"));
    return sql;
}

/// A few lines of names and places: the database keeps one row per record and book.
const answer_bytes_max = 4096;

const Place = struct { short: u32, when_ms: u64, from: place.From };

/// What the database's lines said: each place found.
const Rows = struct {
    local: ?Place = null,
    recent: ?Place = null,
    furthest: ?u32 = null,
};

// Assertions: the lines are the database's, outside data: a line that isn't what it
// should be is passed over, never asserted on.
fn parse(lines: []const u8) Rows {
    var rows: Rows = .{};
    var it = std.mem.tokenizeScalar(u8, lines, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '|');
        const first = fields.next() orelse continue;
        const dataset = std.fmt.parseInt(u8, first, 10) catch continue;
        const record = std.enums.fromInt(Record, dataset) orelse continue;
        const short = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const when_ms = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        const found: Place = .{ .short = short, .when_ms = when_ms, .from = from(fields.rest()) };
        switch (record) {
            .local_most_recent_read => rows.local = found,
            .most_recent_read => rows.recent = found,
            .last_read => rows.furthest = short,
        }
    }
    return rows;
}

fn from(device: []const u8) place.From {
    if (std.mem.eql(u8, device, this_device_name)) return .this_device;
    return .{ .elsewhere = place.Name.of(device) };
}

/// The newer of this Kindle's own place and Amazon's, found in the text.
fn newest(rows: Rows, paragraphs: []const book_model.Paragraph) place.Answer {
    assert(paragraphs.len > 0);
    const local = outside(rows.local, paragraphs);
    const recent = outside(rows.recent, paragraphs);
    const l = local orelse return if (recent) |r| .{ .found = r } else .none;
    const r = recent orelse return .{ .found = l };
    const pick = if (r.when_s > l.when_s) r else l;
    assert(pick.when_s >= l.when_s);
    return .{ .found = pick };
}

fn outside(found: ?Place, paragraphs: []const book_model.Paragraph) ?place.Outside {
    assert(paragraphs.len > 0);
    const p = found orelse return null;
    const at = highlights.locate(paragraphs, p.short) orelse return null;
    assert(at.para < paragraphs.len);
    return .{
        .at = .{ .para = at.para, .byte = at.byte },
        .when_s = p.when_ms / std.time.ms_per_s,
        .from = p.from,
    };
}

// Keeping

/// The place as the stock reader keeps it on this Kindle, and as it queues it for
/// Amazon: the most recent read, and the furthest only when this is past it.
const keep_format = "begin;\n" ++
    "insert or replace into nonsyncable_annotations (annotation_id, book_id, dataset, " ++
    "start_position, end_position, created_time, modified_time, serialized_payload) " ++
    "values ('{[local_id]s}', '{[book]s}', {[local]d}, '{[pos]s}', '{[pos]s}', " ++
    "{[ms]d}, {[ms]d}, " ++
    "'{{\"book_data\":{[data]s},\"device_name\":\"" ++ this_device_name ++
    "\",\"state\":\"\"}}');\n" ++
    "{[recent_row]s}" ++
    "{[furthest_row]s}" ++
    "commit;";
const queue_format = "insert or replace into local_edit (annotation_id, action, dataset, " ++
    "dataset_id, serialized_payload, dirty_flag, created_time, modified_time, retry_count, " ++
    "expiration_timestamp) values ('{[id]s}', 1, {[dataset]d}, '{[book]s}', " ++
    "'{{\"book_data\":{[data]s},\"device_name\":\"" ++ this_device_name ++
    "\",\"position\":{[pos]s}}}', 0, {[ms]d}, {[ms]d}, 0, '');\n";
const position_format = "{{\"longPosition\":\"\",\"shortPosition\":{d}}}";
const position_bytes_max = std.fmt.count(position_format, .{std.math.maxInt(u32)});
/// Room for the numbers each row holds: a dataset, and a time twice.
const numbers_bytes_max = 3 * std.fmt.count("{d}", .{std.math.maxInt(u64)});
const queue_bytes_max = queue_format.len + 32 + 2 * annotations.book_name_bytes_max +
    position_bytes_max + numbers_bytes_max;
const keep_sql_bytes_max = keep_format.len + 32 + 2 * annotations.book_name_bytes_max +
    2 * position_bytes_max + numbers_bytes_max + 2 * queue_bytes_max;

fn keep_sql(buf: []u8, book: *const Book, short: u32, when_ms: u64) ![]const u8 {
    assert(when_ms > 0);
    var pos_buf: [position_bytes_max]u8 = undefined;
    const pos = try std.fmt.bufPrint(&pos_buf, position_format, .{short});
    var recent_buf: [queue_bytes_max]u8 = undefined;
    const recent = try queued(&recent_buf, .most_recent_read, book, pos, when_ms);
    var furthest_buf: [queue_bytes_max]u8 = undefined;
    const past = if (book.furthest) |f| short > f else true;
    const furthest = if (past) try queued(&furthest_buf, .last_read, book, pos, when_ms) else "";
    const sql = try std.fmt.bufPrint(buf, keep_format, .{
        .local_id = Record.local_most_recent_read.id(),
        .book = book.id(),
        .local = @backingInt(Record.local_most_recent_read),
        .pos = pos,
        .ms = when_ms,
        .data = book.data(),
        .recent_row = recent,
        .furthest_row = furthest,
    });
    assert(std.mem.endsWith(u8, sql, "commit;")); // One transaction, whole
    return sql;
}

fn queued(buf: []u8, record: Record, book: *const Book, pos: []const u8, when_ms: u64) ![]const u8 {
    assert(record != .local_most_recent_read); // Kept only here, never queued
    const row = try std.fmt.bufPrint(buf, queue_format, .{
        .id = record.id(),
        .dataset = @backingInt(record),
        .book = book.id(),
        .data = book.data(),
        .pos = pos,
        .ms = when_ms,
    });
    assert(std.mem.endsWith(u8, row, ");\n"));
    return row;
}

const test_book: annotations.BookName = .{
    .key = "277DAA321EC04D398AE2F6993A2A915E",
    .content_type = "PDOC",
    .guid = "CR!RFGXBF45VX5DZ0S2TNGG49EM146Z",
    .owned = true,
};

test "the database's rows give the book's newest place, and its furthest" {
    const lines = "9|340000|1795788283288|Local\n" ++
        "4|321375|1795788453912|Andre's iPhone\n" ++
        "8|321000|1795788400000|Local\n" ++
        "a line that isn't one\n";
    const rows = parse(lines);
    try std.testing.expectEqual(@as(?u32, 340000), rows.furthest);
    try std.testing.expectEqual(@as(u32, 321375), rows.recent.?.short);
    try std.testing.expectEqualStrings("Andre's iPhone", rows.recent.?.from.elsewhere.text());
    try std.testing.expect(rows.local.?.from == .this_device);
}

test "keeping writes this Kindle's place and queues Amazon's, the furthest only past it" {
    var book = Book.of(test_book).?;
    book.furthest = 340000;
    var buf: [keep_sql_bytes_max]u8 = undefined;
    const behind = try keep_sql(&buf, &book, 321375, 1795788453000);
    try std.testing.expect(std.mem.startsWith(u8, behind, "begin;"));
    try std.testing.expect(std.mem.indexOf(u8, behind, "kindle.local_most_recent_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, behind, "'kindle.most_recent_read'") != null);
    try std.testing.expect(std.mem.indexOf(u8, behind, "kindle.last_read") == null);
    try std.testing.expect(std.mem.indexOf(u8, behind, "\"shortPosition\":321375") != null);
    const ahead = try keep_sql(&buf, &book, 350000, 1795788453000);
    try std.testing.expect(std.mem.indexOf(u8, ahead, "kindle.last_read") != null);
}

test "every question about a book is one the shell leaves as it is" {
    var buf: [annotation_db.ask_command_bytes_max]u8 = undefined;
    const sql = try question(&buf, "277DAA321EC04D398AE2F6993A2A915E");
    try std.testing.expect(annotation_db.shell_leaves(sql));
    try std.testing.expect(sql.len < annotation_db.ask_command_bytes_max);
}
