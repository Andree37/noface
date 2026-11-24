//! Writes highlights and bookmarks into the Kindle's annotation outbox, in the exact
//! format its own reader uses. Stock's sync service then sends them to Amazon.
const std = @import("std");
const assert = std.debug.assert;
const check = @import("../base/check.zig");
const safe = @import("safe.zig");

/// The bytes of a long position, and their size in base64.
const long_position_raw_size = 9;
const long_position_size = 12;

comptime {
    assert(long_position_raw_size == 1 + 4 + 4); // Version, element, offset
    assert(std.base64.standard.Encoder.calcSize(long_position_raw_size) == long_position_size);
    // Each kind has its own dataset, its record IDs their own prefix, and its own word
    // in the reader's notes file.
    assert(Kind.highlight.dataset() != Kind.bookmark.dataset());
    assert(!std.mem.eql(u8, Kind.highlight.file_word(), Kind.bookmark.file_word()));
    assert(!std.mem.startsWith(u8, Kind.highlight.prefix(), Kind.bookmark.prefix()));
    assert(!std.mem.startsWith(u8, Kind.bookmark.prefix(), Kind.highlight.prefix()));
    assert(!std.mem.eql(u8, Kind.highlight.label(), Kind.bookmark.label()));
}

/// The most a book's match in SQL takes (`book_match`): shared with annotation_db.zig.
pub const book_match_bytes_max = 128;

/// Amazon's long position: a version byte, element ID and character offset, in base64.
pub fn long_position(buf: *[long_position_size]u8, element: u32, offset: u32) []const u8 {
    var raw: [long_position_raw_size]u8 = undefined;
    raw[0] = 1;
    std.mem.writeInt(u32, raw[1..5], element, .little);
    std.mem.writeInt(u32, raw[5..9], offset, .little);
    const result = std.base64.standard.Encoder.encode(buf, &raw);
    assert(result.len == long_position_size);
    assert(result.ptr == buf);
    return result;
}

pub const Point = struct { element: u32, offset: u32, short: u32 };

/// What a record is. Each kind has its own dataset in the database.
pub const Kind = enum {
    highlight,
    bookmark,

    pub fn dataset(k: Kind) u8 {
        return switch (k) {
            .highlight => 1,
            .bookmark => 2,
        };
    }

    /// Record IDs are this plus the start's short position.
    pub fn prefix(k: Kind) []const u8 {
        return switch (k) {
            .highlight => "kindle.highlight-",
            .bookmark => "kindle.bookmark-",
        };
    }

    /// The kind's word in the reader's own notes file (screens/reader/note_store.zig):
    /// the format's, kept here so renaming a tag never changes what's on the drive.
    pub fn file_word(k: Kind) []const u8 {
        return switch (k) {
            .highlight => "highlight",
            .bookmark => "bookmark",
        };
    }

    /// The kind a notes file's word names, or null for a word that names none.
    pub fn from_file_word(word: []const u8) ?Kind {
        for (std.enums.values(Kind)) |k| {
            if (std.mem.eql(u8, word, k.file_word())) return k;
        }
        return null;
    }

    fn label(k: Kind) []const u8 {
        return switch (k) {
            .highlight => "HIGHLIGHT",
            .bookmark => "BOOKMARK",
        };
    }

    /// Stock gives bookmarks a colour; highlights carry nothing.
    fn metadata(k: Kind) []const u8 {
        return switch (k) {
            .highlight => "{}",
            .bookmark => "{\\\"mchl_color\\\":\\\"dark_blue\\\"}",
        };
    }
};

pub const Record = struct {
    kind: Kind = .highlight,
    id: []const u8,
    key: []const u8,
    content_type: []const u8, // PDOC, EBOK and so on
    guid: []const u8,
    start: Point,
    end: Point,
    now_ms: u64,
};

/// The columns of a row in the outbox, in the order stock writes them.
const local_edit_columns = "(annotation_id, action, dataset, dataset_id, serialized_payload, " ++
    "dirty_flag, created_time, modified_time, retry_count, expiration_timestamp)";

/// A record as stock queues it: its row, with the record itself as JSON.
const insert_format = "insert or replace into local_edit " ++ local_edit_columns ++
    " values ('{s}',1,{d},'{s}-{s}-{s}-1','" ++
    "{{\"book_data\":{{\"asin\":\"{s}\",\"contentType\":\"{s}\",\"guid\":\"{s}\"," ++
    "\"isOwnedByCustomer\":1,\"isSample\":0}}," ++
    "\"created_time\":{d}," ++
    "\"end_position\":{{\"longPosition\":\"{s}\",\"shortPosition\":{d}}}," ++
    "\"json_metadata\":\"{s}\",\"last_modified\":{d},\"position_type\":0," ++
    "\"start_position\":{{\"longPosition\":\"{s}\",\"shortPosition\":{d}}}," ++
    "\"type\":\"{s}\"}}',0,{d},{d},0,'');";

/// The statement that queues a record for sync.
pub fn insert_sql(buf: []u8, h: Record) ![]const u8 {
    check.that(safe.safe_id(h.id), "record ids were checked before they reach SQL");
    check.that(safe.safe_id(h.key), "record keys were checked before they reach SQL");
    check.that(safe.safe_id(h.content_type), "record types were checked before they reach SQL");
    check.that(safe.safe_guid(h.guid), "record guids were checked before they reach SQL");
    var start_buf: [long_position_size]u8 = undefined;
    var end_buf: [long_position_size]u8 = undefined;
    const start = long_position(&start_buf, h.start.element, h.start.offset);
    const end = long_position(&end_buf, h.end.element, h.end.offset);
    const result = try std.fmt.bufPrint(buf, insert_format, .{
        h.id,     h.kind.dataset(), h.key,          h.content_type,
        h.guid,   h.key,            h.content_type, h.guid,
        h.now_ms, end,              h.end.short,    h.kind.metadata(),
        h.now_ms, start,            h.start.short,  h.kind.label(),
        h.now_ms, h.now_ms,
    });
    assert(std.mem.endsWith(u8, result, ";"));
    return result;
}

const action_delete = 3;

/// SQL that is true for rows of one book. Its records are named "<key>-<type>-<guid>-1".
/// An exact prefix compare, since LIKE would read `_` in a key as a wildcard.
pub fn book_match(buf: []u8, key: []const u8) ![]const u8 {
    check.that(safe.safe_id(key), "book keys were checked before they reach SQL");
    const format = "substr(dataset_id, 1, {d}) = '{s}-'";
    const result = try std.fmt.bufPrint(buf, format, .{ key.len + 1, key });
    assert(std.mem.endsWith(u8, result, "-'"));
    return result;
}

/// Drops an unsent record's row, then queues a delete row for a sent one.
const delete_format = "begin;\n" ++
    "delete from local_edit where annotation_id='{s}' and {s};\n" ++
    "insert into local_edit " ++ local_edit_columns ++
    " select annotation_id, {d}, dataset, dataset_id, " ++
    "json_set(serialized_payload, '$.last_modified', {d}), 0, created_time, {d}, 0, '' " ++
    "from server_view where annotation_id='{s}' and {s} and dataset={d};\n" ++
    "commit;";

/// Deletes a record the way stock does. An unsent one just loses its row. A
/// sent one gets a delete row: Amazon's own record, with a new modified time.
pub fn delete_sql(
    buf: []u8,
    kind: Kind,
    id: []const u8,
    key: []const u8,
    now_ms: u64,
) ![]const u8 {
    check.that(safe.safe_id(id), "record ids were checked before they reach SQL");
    var match_buf: [book_match_bytes_max]u8 = undefined;
    const book = try book_match(&match_buf, key);
    const result = try std.fmt.bufPrint(buf, delete_format, .{
        id, book, action_delete, now_ms, now_ms, id, book, kind.dataset(),
    });
    assert(std.mem.endsWith(u8, result, "commit;"));
    return result;
}

test "long positions match what the Kindle stores" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("AVAAAADaEQAA", long_position(&buf, 80, 4570));
    try std.testing.expectEqualStrings("AVAAAABhEgAA", long_position(&buf, 80, 4705));
}

test "row matches the one the stock reader wrote" {
    var buf: [1024]u8 = undefined;
    const sql = try insert_sql(&buf, .{
        .id = "kindle.highlight-381908",
        .key = "0123456789ABCDEF0123456789ABCDEF",
        .content_type = "PDOC",
        .guid = "CR!0000000000000000000000000000",
        .start = .{ .element = 80, .offset = 4570, .short = 381908 },
        .end = .{ .element = 80, .offset = 4705, .short = 382043 },
        .now_ms = 1794005896131,
    });
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try std.testing.expect(has(sql, "'kindle.highlight-381908',1,1," ++
        "'0123456789ABCDEF0123456789ABCDEF-PDOC-CR!0000000000000000000000000000-1'"));
    try std.testing.expect(has(sql, "\"end_position\":" ++
        "{\"longPosition\":\"AVAAAABhEgAA\",\"shortPosition\":382043}"));
    try std.testing.expect(has(sql, "\"start_position\":" ++
        "{\"longPosition\":\"AVAAAADaEQAA\",\"shortPosition\":381908}"));
    try std.testing.expect(has(sql, "\"json_metadata\":\"{}\""));
    try std.testing.expect(has(sql, "\"type\":\"HIGHLIGHT\"}'"));
}

/// Every key of the JSON the stock reader queues, in its order and its spelling: a
/// key spelled any other way is a record its sync doesn't know.
const stock_payload_keys = [_][]const u8{
    "book_data",         "asin",           "contentType",   "guid",
    "isOwnedByCustomer", "isSample",       "created_time",  "end_position",
    "longPosition",      "shortPosition",  "json_metadata", "last_modified",
    "position_type",     "start_position", "longPosition",  "shortPosition",
    "type",
};

test "every key of the queued record is spelled as the stock reader spells it" {
    var buf: [1200]u8 = undefined;
    for ([_]Kind{ .highlight, .bookmark }) |kind| {
        const sql = try insert_sql(&buf, .{
            .kind = kind,
            .id = "kindle.highlight-381908",
            .key = "0123456789ABCDEF0123456789ABCDEF",
            .content_type = "PDOC",
            .guid = "CR!0000000000000000000000000000",
            .start = .{ .element = 80, .offset = 4570, .short = 381908 },
            .end = .{ .element = 80, .offset = 4705, .short = 382043 },
            .now_ms = 1794005896131,
        });
        // A key is a quoted name before a colon; the metadata's own keys are escaped
        var keys: [stock_payload_keys.len + 1][]const u8 = undefined;
        var count: u32 = 0;
        for (1..sql.len - 1) |i| {
            if (sql[i] != '"' or sql[i + 1] != ':' or sql[i - 1] == '\\') continue;
            const start = std.mem.lastIndexOfScalar(u8, sql[0..i], '"').?;
            try std.testing.expect(count < keys.len);
            keys[count] = sql[start + 1 .. i];
            count += 1;
        }
        try std.testing.expectEqual(@as(u32, stock_payload_keys.len), count);
        for (stock_payload_keys, keys[0..count]) |want, got| {
            try std.testing.expectEqualStrings(want, got);
        }
    }
}

test "delete clears any unsent row, then queues Amazon's record" {
    var buf: [900]u8 = undefined;
    const id = "kindle.highlight-382334";
    const sql = try delete_sql(&buf, .highlight, id, "BOOKKEY", 1794053974114);
    const first = std.mem.indexOf(u8, sql, "delete from local_edit where annotation_id='" ++
        id ++ "' and substr(dataset_id, 1, 8) = 'BOOKKEY-';").?;
    const second = std.mem.indexOf(u8, sql, "select annotation_id, 3, dataset").?;
    try std.testing.expect(first < second);
    const modified = "json_set(serialized_payload, '$.last_modified', 1794053974114)";
    try std.testing.expect(std.mem.indexOf(u8, sql, modified) != null);
    const source = "from server_view where annotation_id='" ++ id ++
        "' and substr(dataset_id, 1, 8) = 'BOOKKEY-' and dataset=1;";
    try std.testing.expect(std.mem.indexOf(u8, sql, source) != null);
}

test "a book matches by exact key, never by wildcard" {
    var buf: [128]u8 = undefined;
    const match = try book_match(&buf, "AB_CD");
    try std.testing.expectEqualStrings("substr(dataset_id, 1, 6) = 'AB_CD-'", match);
}

test "bookmark row matches the one the stock reader wrote" {
    var buf: [1200]u8 = undefined;
    const sql = try insert_sql(&buf, .{
        .kind = .bookmark,
        .id = "kindle.bookmark-381741",
        .key = "0123456789ABCDEF0123456789ABCDEF",
        .content_type = "PDOC",
        .guid = "CR!0000000000000000000000000000",
        .start = .{ .element = 80, .offset = 4403, .short = 381741 },
        .end = .{ .element = 80, .offset = 4403, .short = 381741 },
        .now_ms = 1793991983543,
    });
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    try std.testing.expect(has(sql, "values ('kindle.bookmark-381741',1,2," ++
        "'0123456789ABCDEF0123456789ABCDEF-PDOC-"));
    try std.testing.expect(has(sql, "\"end_position\":" ++
        "{\"longPosition\":\"AVAAAAAzEQAA\",\"shortPosition\":381741}"));
    try std.testing.expect(has(sql, "\"json_metadata\":" ++
        "\"{\\\"mchl_color\\\":\\\"dark_blue\\\"}\""));
    try std.testing.expect(has(sql, "\"type\":\"BOOKMARK\"}'"));
}

test "deleting a bookmark looks in the bookmark dataset" {
    var buf: [900]u8 = undefined;
    const sql = try delete_sql(&buf, .bookmark, "kindle.bookmark-5", "BOOKKEY", 1);
    try std.testing.expect(std.mem.indexOf(u8, sql, "and dataset=2;") != null);
}

test "a notes file's word names its kind, and no other word does" {
    for (std.enums.values(Kind)) |k| {
        try std.testing.expectEqual(@as(?Kind, k), Kind.from_file_word(k.file_word()));
    }
    // The numbering line the notes file starts with is never a note
    try std.testing.expectEqual(@as(?Kind, null), Kind.from_file_word("numbering-5"));
    try std.testing.expectEqual(@as(?Kind, null), Kind.from_file_word(""));
}
