//! Books hidden from the library: books in the cloud the reader no longer wants listed,
//! by the key the device's own software names them by, one a line. Hidden here only:
//! they stay in the reader's store library, and on their other devices; deleting one
//! for good is done in the device's own screens. A book hidden comes back once it's
//! on the device again.
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

/// The key a line of the file names, or null for a line that names none.
pub fn key_of(line: []const u8) ?[]const u8 {
    const key = std.mem.trim(u8, line, " \t\r");
    if (key.len == 0) return null;
    assert(key.len <= line.len);
    assert(std.mem.indexOf(u8, line, key) != null); // A part of the line
    return key;
}

test "a line names a key, trimmed; an empty one names none" {
    try std.testing.expectEqualStrings("B0ABC", key_of(" B0ABC\r").?);
    try std.testing.expect(key_of("  ") == null);
}
