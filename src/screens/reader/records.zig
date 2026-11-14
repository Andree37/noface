//! Writing and deleting highlights and bookmarks for an open book: synced through
//! Amazon for Kindle books, kept on the Kindle for books Amazon doesn't know.
const std = @import("std");
const book_model = @import("../../model/book.zig");
const annotations = @import("../../kindle/annotations.zig");
const catalog = @import("../../model/catalog.zig");
const os = @import("../../sys/os.zig");
const annotation_db = @import("../../kindle/annotation_db.zig");
const safe = @import("../../kindle/safe.zig");
const sess = @import("session.zig");
const local_notes = @import("local_notes.zig");
const lipc = @import("../../kindle/lipc.zig");

/// Amazon's position for a place in the text. Null for paragraphs it doesn't number.
pub fn pointFor(s: *sess.Session, para: u32, byte: u32) ?annotations.Point {
    const p = s.paragraphs[para];
    if (p.position == 0) return null;
    const chars = book_model.charOffset(p.text, byte);
    return .{ .element = p.element, .offset = chars, .short = p.position + chars };
}

/// Asks Amazon to sync the notes just written (not while writes are off for testing).
pub fn sync() void {
    if (!annotation_db.dryRun()) lipc.syncNow();
}

/// Queues a record for sync. True when it was written (or writes are off for testing).
pub fn write(s: *const sess.Session, entry: *const catalog.Entry, kind: annotations.Kind, id: []const u8, start: annotations.Point, end: annotations.Point) bool {
    if (annotation_db.dryRun()) return true;
    if (s.notes_path.len > 0) return local_notes.put(std.heap.smp_allocator, s.notes_path, kind, id, start.short, end.short);
    if (!safe.safeId(entry.key) or !safe.safeId(entry.kind) or !safe.safeId(id) or !safe.safeGuid(entry.guid)) return false;
    var buf: [1200]u8 = undefined;
    const sql = annotations.insertSql(&buf, .{
        .kind = kind,
        .id = id,
        .key = entry.key,
        .content_type = entry.kind,
        .guid = entry.guid,
        .start = start,
        .end = end,
        .now_ms = os.unixTime() * 1000,
    }) catch return false;
    return annotation_db.runAnnotationSql(sql);
}

/// Queues a record's deletion. True when it was written (or writes are off for testing).
pub fn delete(s: *const sess.Session, entry: *const catalog.Entry, kind: annotations.Kind, id: []const u8) bool {
    if (annotation_db.dryRun()) return true;
    if (s.notes_path.len > 0) return local_notes.remove(std.heap.smp_allocator, s.notes_path, id);
    if (!safe.safeId(id) or !safe.safeId(entry.key)) return false;
    var buf: [900]u8 = undefined;
    const sql = annotations.deleteSql(&buf, kind, id, entry.key, os.unixTime() * 1000) catch return false;
    return annotation_db.runAnnotationSql(sql);
}
