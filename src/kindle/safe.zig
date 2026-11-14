//! Checks on catalog values before they go into a shell command or SQL.
const std = @import("std");
const assert = std.debug.assert;

/// The longest ID or GUID accepted, so commands built from them fit their buffers.
pub const id_size_max = 64;

/// Besides letters and digits, the characters an ID or a GUID may hold.
const id_extra = "-_.";
const guid_extra = "!-_.";

comptime {
    // Nothing that could end a quoted string or start another command gets through.
    for ("'\"`$;|&<>()\\ \t\n*?[]{}~#=%") |c| {
        assert(std.mem.indexOfScalar(u8, id_extra, c) == null);
        assert(std.mem.indexOfScalar(u8, guid_extra, c) == null);
    }
}

/// Catalog IDs go into a shell command, so only plain ones are accepted.
pub fn safe_id(id: []const u8) bool {
    if (id.len == 0 or id.len > id_size_max) return false;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, id_extra, c) == null) return false;
    }
    assert(id.len > 0);
    assert(id.len <= id_size_max);
    return true;
}

/// Book GUIDs look like "CR!0123ABC". Empty is fine: sideloaded books have none.
pub fn safe_guid(guid: []const u8) bool {
    if (guid.len > id_size_max) return false;
    for (guid) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (std.mem.indexOfScalar(u8, guid_extra, c) == null) return false;
    }
    assert(guid.len <= id_size_max);
    return true;
}

test "ids that could break out of the shell command are refused" {
    try std.testing.expect(safe_id("FEDCBA9876543210FEDCBA9876543210"));
    try std.testing.expect(safe_id("PDOC"));
    try std.testing.expect(!safe_id(""));
    try std.testing.expect(!safe_id("a'; rm -rf /"));
    try std.testing.expect(!safe_id("a b"));
}

test "guids are checked before they reach SQL" {
    try std.testing.expect(safe_guid("CR!0000000000000000000000000000"));
    try std.testing.expect(safe_guid(""));
    try std.testing.expect(!safe_guid("CR!1' or 1=1 --"));
    try std.testing.expect(!safe_guid("a\"b"));
}
