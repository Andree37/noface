//! The Kindle's annotation database: reading a book's records and queuing changes for sync.
const std = @import("std");
const paths = @import("paths.zig");
const linux = @import("../sys/calls.zig");
const os = @import("../sys/os.zig");
const failed = os.failed;
const annotations = @import("annotations.zig");
const process = @import("../sys/process.zig");
const safe = @import("safe.zig");

/// While this file exists, annotation writes are skipped. Used by device tests.
pub fn dryRun() bool {
    const rc = linux.open(paths.dry_run, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(rc)) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

/// Fetches a book's highlights or bookmarks as "id|start|end" lines.
pub fn readAnnotations(key: []const u8, kind: annotations.Kind, out: []u8) []const u8 {
    if (!safe.safeId(key)) return "";
    var match_buf: [128]u8 = undefined;
    const book = annotations.bookMatch(&match_buf, key) catch return "";
    var buf: [1000]u8 = undefined;
    const fields = "annotation_id, json_extract(serialized_payload, '$.start_position.shortPosition'), json_extract(serialized_payload, '$.end_position.shortPosition')";
    const command = std.fmt.bufPrintSentinel(&buf,
        \\sqlite3 -separator '|' "file:$(ls /mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db)?mode=ro" "select {s} from server_view where dataset={d} and {s} and annotation_id not in (select annotation_id from local_edit where {s}) union select {s} from local_edit where dataset={d} and action != 3 and {s}"
    , .{ fields, kind.dataset(), book, book, fields, kind.dataset(), book }, 0) catch return "";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    const n = process.run(&argv, out) orelse return "";
    return completeLines(out[0..n], n == out.len);
}

/// Output that filled its buffer may end mid-line; that last line is dropped
/// rather than read as a highlight with a wrong end.
pub fn completeLines(output: []const u8, filled: bool) []const u8 {
    if (!filled) return output;
    std.debug.print("highlight list cut off at {d} bytes\n", .{output.len});
    const end = std.mem.lastIndexOfScalar(u8, output, '\n') orelse return "";
    return output[0 .. end + 1];
}

/// Runs a SQL statement against the annotation database.
pub fn runAnnotationSql(sql: []const u8) bool {
    const path = paths.annotation_sql;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (failed(rc)) return false;
    const fd: i32 = @intCast(rc);
    const written = linux.write(fd, sql.ptr, sql.len);
    _ = linux.close(fd);
    if (failed(written) or written != sql.len) return false;
    const command = "sqlite3 -bail -cmd '.timeout 3000' /mnt/us/system/ksdk/.annotations/*/ksdk_annotation_v1.db < " ++ path ++ " && echo ok";
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    var out: [8]u8 = undefined;
    const n = process.run(&argv, &out) orelse return false;
    return std.mem.startsWith(u8, out[0..n], "ok");
}

test "a cut-off highlight list loses only its partial line" {
    try std.testing.expectEqualStrings("a|1|2\nb|3|4\n", completeLines("a|1|2\nb|3|4\nc|5|", true));
    try std.testing.expectEqualStrings("a|1|2\nc|5|6", completeLines("a|1|2\nc|5|6", false));
    try std.testing.expectEqualStrings("", completeLines("c|5|", true));
}
