//! Where a control that moves with the page was put: a footnote's mark, a picture, a
//! highlight's Delete bubble, and the words a test holds or drags across: the page's
//! first below its top edge's strip, and the first and last of the first line of the
//! next paragraph after it. Unlike the controls `places.zig` names, these sit where
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
pub const What = enum {
    note, // A footnote's mark, the page's first
    picture, // The page's first
    delete, // A selected highlight's Delete bubble
    word, // The page's first word a touch reaches, below the top edge's strip
    paragraph, // The first word of the next paragraph after it
    paragraph_end, // The last word on that paragraph's first line
};

const prefix = "placed ";
const middle = " at ";
/// Starts what a page shown placed: what was placed before it was another page's.
const page_marker = prefix ++ "on page ";

/// Says in the log that page `index` was shown: what's placed after it is its own.
pub fn shown(index: u32) void {
    log.info(page_marker ++ "{d}", .{index + 1});
}

/// Says in the log that `what` was drawn with its middle at `point`.
pub fn note(what: What, point: style.Point) void {
    assert(point.x >= 0);
    assert(point.y >= 0);
    log.info(prefix ++ "{s}" ++ middle ++ "{d},{d}", .{ @tagName(what), point.x, point.y });
}

/// Where `what` was last placed on the page shown last, in a log's text, or null when
/// it wasn't: what an earlier page placed is never taken for this one's.
pub fn find(log_text: []const u8, what: []const u8) ?style.Point {
    assert(what.len > 0);
    const page_start = std.mem.lastIndexOf(u8, log_text, page_marker) orelse 0;
    const text = log_text[page_start..];
    assert(std.mem.indexOf(u8, what, middle) == null); // A name, never its line's rest
    assert(std.mem.indexOfScalar(u8, what, ' ') == null); // One word, as names are
    var found: ?style.Point = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    // Bounded by the log's lines
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, prefix) orelse continue;
        const rest = line[start + prefix.len ..];
        if (!std.mem.startsWith(u8, rest, what)) continue;
        const after = rest[what.len..];
        // "paragraph" is the start of "paragraph_end": a name ends where " at " starts
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

test "what an earlier page placed isn't found once another page is shown" {
    const text =
        \\placed on page 1
        \\placed paragraph at 210,568
        \\placed word at 160,318
        \\placed on page 2
        \\placed word at 300,400
        \\placed delete at 636,714
    ;
    try std.testing.expectEqual(style.Point{ .x = 300, .y = 400 }, find(text, "word").?);
    try std.testing.expectEqual(style.Point{ .x = 636, .y = 714 }, find(text, "delete").?);
    try std.testing.expectEqual(@as(?style.Point, null), find(text, "paragraph"));
}

test "the last place logged for a name is found, and no other name's" {
    const text =
        \\turn to 2
        \\placed note at 412,318
        \\placed picture at 636,900
        \\placed note at 100,200
        \\placed noted at 1,1
        \\placed paragraph_end at 1150,568
        \\placed delete at bad
    ;
    try std.testing.expectEqual(style.Point{ .x = 100, .y = 200 }, find(text, "note").?);
    try std.testing.expectEqual(style.Point{ .x = 636, .y = 900 }, find(text, "picture").?);
    try std.testing.expectEqual(@as(?style.Point, null), find(text, "delete"));
    try std.testing.expectEqual(@as(?style.Point, null), find(text, "lock"));
    try std.testing.expectEqual(@as(?style.Point, null), find(text, "paragraph"));
    const end = find(text, "paragraph_end").?;
    try std.testing.expectEqual(style.Point{ .x = 1150, .y = 568 }, end);
}
