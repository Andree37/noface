//! Writes highlights and bookmarks into the Kindle's annotation outbox, in the exact
//! format its own reader uses. Stock's sync service then sends them to Amazon.
const std = @import("std");
const check = @import("../base/check.zig");
const safe = @import("safe.zig");

/// Amazon's long position: a version byte, element ID and character offset, in base64.
pub fn long_position(buf: *[12]u8, element: u32, offset: u32) []const u8 {
    var raw: [9]u8 = undefined;
    raw[0] = 1;
    std.mem.writeInt(u32, raw[1..5], element, .little);
    std.mem.writeInt(u32, raw[5..9], offset, .little);
    return std.base64.standard.Encoder.encode(buf, &raw);
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

/// The statement that queues a record for sync.
pub fn insert_sql(buf: []u8, h: Record) ![]const u8 {
    check.that(safe.safe_id(h.id) and safe.safe_id(h.key) and safe.safe_id(h.content_type) and safe.safe_guid(h.guid), "record ids were checked before they reach SQL");
    var start_buf: [12]u8 = undefined;
    var end_buf: [12]u8 = undefined;
    const start = long_position(&start_buf, h.start.element, h.start.offset);
    const end = long_position(&end_buf, h.end.element, h.end.offset);
    return std.fmt.bufPrint(buf,
        \\insert or replace into local_edit (annotation_id, action, dataset, dataset_id, serialized_payload, dirty_flag, created_time, modified_time, retry_count, expiration_timestamp) values ('{s}',1,{d},'{s}-{s}-{s}-1','{{"book_data":{{"asin":"{s}","contentType":"{s}","guid":"{s}","isOwnedByCustomer":1,"isSample":0}},"created_time":{d},"end_position":{{"long_position":"{s}","shortPosition":{d}}},"json_metadata":"{s}","last_modified":{d},"position_type":0,"start_position":{{"long_position":"{s}","shortPosition":{d}}},"type":"{s}"}}',0,{d},{d},0,'');
    , .{ h.id, h.kind.dataset(), h.key, h.content_type, h.guid, h.key, h.content_type, h.guid, h.now_ms, end, h.end.short, h.kind.metadata(), h.now_ms, start, h.start.short, h.kind.label(), h.now_ms, h.now_ms });
}

const action_delete = 3;

/// SQL that is true for rows of one book. Its records are named "<key>-<type>-<guid>-1".
/// An exact prefix compare, since LIKE would read `_` in a key as a wildcard.
pub fn book_match(buf: []u8, key: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "substr(dataset_id, 1, {d}) = '{s}-'", .{ key.len + 1, key });
}

/// Deletes a record the way stock does. An unsent one just loses its row. A
/// sent one gets a delete row: Amazon's own record, with a new modified time.
pub fn delete_sql(buf: []u8, kind: Kind, id: []const u8, key: []const u8, now_ms: u64) ![]const u8 {
    var match_buf: [128]u8 = undefined;
    const book = try book_match(&match_buf, key);
    return std.fmt.bufPrint(buf,
        \\begin;
        \\delete from local_edit where annotation_id='{s}' and {s};
        \\insert into local_edit (annotation_id, action, dataset, dataset_id, serialized_payload, dirty_flag, created_time, modified_time, retry_count, expiration_timestamp) select annotation_id, {d}, dataset, dataset_id, json_set(serialized_payload, '$.last_modified', {d}), 0, created_time, {d}, 0, '' from server_view where annotation_id='{s}' and {s} and dataset={d};
        \\commit;
    , .{ id, book, action_delete, now_ms, now_ms, id, book, kind.dataset() });
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
    try std.testing.expect(has(sql, "'kindle.highlight-381908',1,1,'0123456789ABCDEF0123456789ABCDEF-PDOC-CR!0000000000000000000000000000-1'"));
    try std.testing.expect(has(sql, "\"end_position\":{\"long_position\":\"AVAAAABhEgAA\",\"shortPosition\":382043}"));
    try std.testing.expect(has(sql, "\"start_position\":{\"long_position\":\"AVAAAADaEQAA\",\"shortPosition\":381908}"));
    try std.testing.expect(has(sql, "\"json_metadata\":\"{}\""));
    try std.testing.expect(has(sql, "\"type\":\"HIGHLIGHT\"}'"));
}

test "delete clears any unsent row, then queues Amazon's record" {
    var buf: [900]u8 = undefined;
    const sql = try delete_sql(&buf, .highlight, "kindle.highlight-382334", "BOOKKEY", 1794053974114);
    const first = std.mem.indexOf(u8, sql, "delete from local_edit where annotation_id='kindle.highlight-382334' and substr(dataset_id, 1, 8) = 'BOOKKEY-';").?;
    const second = std.mem.indexOf(u8, sql, "select annotation_id, 3, dataset").?;
    try std.testing.expect(first < second);
    try std.testing.expect(std.mem.indexOf(u8, sql, "json_set(serialized_payload, '$.last_modified', 1794053974114)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from server_view where annotation_id='kindle.highlight-382334' and substr(dataset_id, 1, 8) = 'BOOKKEY-' and dataset=1;") != null);
}

test "a book matches by exact key, never by wildcard" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("substr(dataset_id, 1, 6) = 'AB_CD-'", try book_match(&buf, "AB_CD"));
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
    try std.testing.expect(has(sql, "values ('kindle.bookmark-381741',1,2,'0123456789ABCDEF0123456789ABCDEF-PDOC-"));
    try std.testing.expect(has(sql, "\"end_position\":{\"long_position\":\"AVAAAAAzEQAA\",\"shortPosition\":381741}"));
    try std.testing.expect(has(sql, "\"json_metadata\":\"{\\\"mchl_color\\\":\\\"dark_blue\\\"}\""));
    try std.testing.expect(has(sql, "\"type\":\"BOOKMARK\"}'"));
}

test "deleting a bookmark looks in the bookmark dataset" {
    var buf: [900]u8 = undefined;
    const sql = try delete_sql(&buf, .bookmark, "kindle.bookmark-5", "BOOKKEY", 1);
    try std.testing.expect(std.mem.indexOf(u8, sql, "and dataset=2;") != null);
}
