//! Where a control that moves with the page was put: a footnote's mark, a picture, a
//! highlight's Delete bubble. Unlike the controls `places.zig` names, these sit where
//! the text puts them, which differs with the font, so noface says in its log where it
//! drew each ("placed note at 412,318"), and a test taps where the log says: it follows
//! the layout, and never taps blind. The device tests read it from noface's log
//! (tools/e2e.zig), and the scenarios from theirs.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("../ui/style.zig");
/// Lines for noface's log, which the tests keep quiet (main.zig's `std_options`).
const log = std.log.scoped(.placed);

/// What's logged as placed, by the name a test asks for it by.
pub const What = enum { note, picture, delete };

const prefix = "placed ";
const middle = " at ";

/// Says in the log that `what` was drawn with its middle at `point`.
pub fn note(what: What, point: style.Point) void {
    assert(point.x >= 0);
    assert(point.y >= 0);
    log.info(prefix ++ "{s}" ++ middle ++ "{d},{d}", .{ @tagName(what), point.x, point.y });
}

/// Where `what` was last placed, in a log's text, or null when it never was.
pub fn find(text: []const u8, what: []const u8) ?style.Point {
    assert(what.len > 0);
    assert(std.mem.indexOf(u8, what, middle) == null); // A name, never its line's rest
    var found: ?style.Point = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    // Bounded by the log's lines
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, prefix) orelse continue;
        const rest = line[start + prefix.len ..];
        if (!std.mem.startsWith(u8, rest, what)) continue;
        const after = rest[what.len..];
        if (!std.mem.startsWith(u8, after, middle)) continue;
        found = parse_point(after[middle.len..]) orelse found;
    }
    return found;
}

/// "412,318" as a point; null for anything else.
// Assertions: it reads a log's text, which is outside data
fn parse_point(text: []const u8) ?style.Point {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const x = std.fmt.parseInt(i32, text[0..comma], 10) catch return null;
    const y = std.fmt.parseInt(i32, std.mem.trimEnd(u8, text[comma + 1 ..], "\r"), 10) catch
        return null;
    if (x < 0 or y < 0) return null;
    return .{ .x = x, .y = y };
}

test "the last place logged for a name is found, and no other name's" {
    const text =
        \\turn to 2
        \\placed note at 412,318
        \\placed picture at 636,900
        \\placed note at 100,200
        \\placed noted at 1,1
        \\placed delete at bad
    ;
    try std.testing.expectEqual(style.Point{ .x = 100, .y = 200 }, find(text, "note").?);
    try std.testing.expectEqual(style.Point{ .x = 636, .y = 900 }, find(text, "picture").?);
    try std.testing.expectEqual(@as(?style.Point, null), find(text, "delete"));
    try std.testing.expectEqual(@as(?style.Point, null), find(text, "lock"));
}
