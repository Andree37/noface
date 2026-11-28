//! Books hidden from the library: books in the cloud the reader no longer wants listed,
//! one a line, "<key>\t<kind>", as the device's own software names them (a sample and
//! the book bought have one key, but not one kind). Hidden here only: they stay in the
//! reader's store library, and on their other devices; deleting one for good is done in
//! the device's own screens. A book hidden comes back once it's on the device again,
//! and its line is let go of then.
const std = @import("std");
const assert = std.debug.assert;

/// The hidden books' file in the data folder `state_dir`. Its name is said only here,
/// so the card that writes it and the library build that reads it never part ways.
pub fn file_path(buffer: []u8, state_dir: []const u8) ![:0]u8 {
    assert(state_dir.len > 0);
    const p = try std.fmt.bufPrintSentinel(buffer, "{s}/hidden", .{state_dir}, 0);
    assert(std.mem.endsWith(u8, p, "/hidden"));
    return p;
}

/// A book's line, without its end: what a line of the file is matched by.
pub fn name(buffer: []u8, key: []const u8, kind: []const u8) ![]const u8 {
    assert(key.len > 0);
    const line = try std.fmt.bufPrint(buffer, "{s}\t{s}", .{ key, kind });
    assert(line.len > key.len);
    return line;
}

/// The longest name kept: a key and a kind, each as long as the catalog's ids go.
pub fn name_bytes_max(comptime id_bytes_max: u32) u32 {
    return 2 * id_bytes_max + 1;
}

/// What a line of the file names, trimmed, or null for a line that names no book.
pub fn named(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \r");
    if (std.mem.indexOfScalar(u8, trimmed, '\t') == null) return null; // Not "<key>\t<kind>"
    assert(trimmed.len > 0);
    assert(trimmed.len <= line.len);
    return trimmed;
}

test "a line names a book by key and kind; one without both names none" {
    var buffer: [64]u8 = undefined;
    const book = try name(&buffer, "B0ABC", "EBOK");
    try std.testing.expectEqualStrings("B0ABC\tEBOK", book);
    try std.testing.expectEqualStrings(book, named(" B0ABC\tEBOK\r").?);
    try std.testing.expect(named("B0ABC") == null);
    try std.testing.expect(named("  ") == null);
}
