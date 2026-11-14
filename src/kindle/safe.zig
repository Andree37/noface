//! Checks on catalog values before they go into a shell command or SQL.
const std = @import("std");

/// Catalog IDs go into a shell command, so only plain ones are accepted.
pub fn safe_id(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// Book GUIDs look like "CR!0123ABC". Empty is fine: sideloaded books have none.
pub fn safe_guid(guid: []const u8) bool {
    if (guid.len > 64) return false;
    for (guid) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '!' and c != '-' and c != '_' and c != '.') return false;
    }
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
