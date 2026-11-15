//! Writing and deleting highlights and bookmarks for an open book: synced through
//! Amazon for Kindle books, kept on the Kindle for books Amazon doesn't know.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const annotations = @import("../../kindle/annotations.zig");
const catalog = @import("../../model/catalog.zig");
const os = @import("../../sys/os.zig");
const annotation_db = @import("../../kindle/annotation_db.zig");
const safe = @import("../../kindle/safe.zig");
const sess = @import("session.zig");
const local_notes = @import("local_notes.zig");
const lipc = @import("../../kindle/lipc.zig");

/// Amazon's position for a place in the text. Null for paragraphs it doesn't number,
/// and for a place past the largest position a record can hold, which only a damaged
/// book has: such a place can't be saved.
pub fn point_for(s: *sess.Session, para: u32, byte: u32) ?annotations.Point {
    assert(para < s.paragraphs.len);
    assert(byte <= s.paragraphs[para].text.len);
    return point_in(&s.paragraphs[para], byte);
}

fn point_in(p: *const book_model.Paragraph, byte: u32) ?annotations.Point {
    assert(byte <= p.text.len);
    if (p.position == 0) return null;
    const chars = book_model.char_offset(p.text, byte);
    assert(chars <= byte); // A character takes at least a byte
    // A KFX's positions are sums of its own numbers, which stop at the largest
    const short = std.math.add(u32, p.position, chars) catch return null;
    assert(short >= p.position);
    return .{ .element = p.element, .offset = chars, .short = short };
}

/// Asks Amazon to sync the notes just written: only those of a book Amazon keeps notes
/// for (an EPUB's stay in noface's own file, which no sync sends anywhere), and not
/// while writes are off for testing.
pub fn sync(s: *const sess.Session) void {
    assert(s.pages.len > 0); // A book is open
    if (s.notes_path.len > 0) return;
    if (!annotation_db.dry_run()) lipc.sync_now();
}

/// Queues a record for sync. True when it was written (or writes are off for testing).
pub fn write(
    s: *const sess.Session,
    entry: *const catalog.Entry,
    kind: annotations.Kind,
    id: []const u8,
    start: annotations.Point,
    end: annotations.Point,
) bool {
    if (kind == .bookmark) assert(start.short == end.short); // A bookmark is a point
    // Books Amazon doesn't sync keep their notes beside their state, and only they do
    assert((s.notes_path.len > 0) == entry.is_epub());
    if (annotation_db.dry_run()) return true;
    if (s.notes_path.len > 0) {
        return local_notes.put(s.notes_path, kind, id, start.short, end.short);
    }
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

/// Queues a record's deletion. True when it was written (or writes are off for testing).
pub fn delete(
    s: *const sess.Session,
    entry: *const catalog.Entry,
    kind: annotations.Kind,
    id: []const u8,
) bool {
    assert((s.notes_path.len > 0) == entry.is_epub());
    if (annotation_db.dry_run()) return true;
    if (s.notes_path.len > 0) return local_notes.remove(s.notes_path, id);
    if (!safe.safe_id(id) or !safe.safe_id(entry.key)) return false;
    var buffer: [900]u8 = undefined;
    const now_ms = os.unix_time() * 1000;
    const sql = annotations.delete_sql(&buffer, kind, id, entry.key, now_ms) catch return false;
    assert(std.mem.endsWith(u8, sql, ";")); // A whole transaction, through its commit
    return annotation_db.run_annotation_sql(sql);
}

test "a place past the largest position can't be saved, and never overflows" {
    const max = std.math.maxInt(u32);
    var p = book_model.Paragraph{ .text = "a damaged paragraph", .position = max };
    try std.testing.expectEqual(@as(u32, max), point_in(&p, 0).?.short);
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 1));
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 19));
    p.position = max - 5;
    try std.testing.expectEqual(@as(u32, max), point_in(&p, 5).?.short);
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 6));
    p.position = 0; // Not numbered at all
    try std.testing.expectEqual(@as(?annotations.Point, null), point_in(&p, 0));
}
