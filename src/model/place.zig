//! A reading place kept outside noface, by the device's own software: where its reader,
//! or another device it syncs with, last had a book. Each device family finds and keeps
//! these its own way (src/platform.zig picks which); the reader only sees what's here,
//! in its own numbering.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("book.zig");
const unicode = @import("../text/unicode.zig");

/// The longest device name kept, in bytes: enough for "Go to 62% from <name>?" on a line.
pub const name_bytes_max = 40;

/// A device's name as its software gives it ("Andre's iPhone"), cut to `name_bytes_max`
/// before a character, never inside one.
pub const Name = struct {
    bytes: [name_bytes_max]u8 = undefined,
    len: u8 = 0,

    pub fn of(raw: []const u8) Name {
        var n: Name = .{};
        const cut: u32 = @intCast(@min(raw.len, name_bytes_max));
        const end = if (cut < raw.len) unicode.start_at_or_before(raw, cut) else cut;
        assert(end <= name_bytes_max);
        @memcpy(n.bytes[0..end], raw[0..end]);
        n.len = @intCast(end);
        assert(n.len == end);
        return n;
    }

    pub fn text(n: *const Name) []const u8 {
        assert(n.len <= name_bytes_max);
        assert(n.len <= n.bytes.len);
        return n.bytes[0..n.len];
    }
};

/// Where an outside place was made: by this device's own reader, or on another device,
/// which has a name to ask about it by.
pub const From = union(enum) {
    this_device,
    elsewhere: Name,
};

/// A place in the book, when it was made there, and where.
pub const Outside = struct {
    at: book_model.Pos,
    when_s: u64,
    from: From,
};

/// What asking the device for a book's outside place gave.
pub const Answer = union(enum) {
    /// The newest place it has, found in the book's text.
    found: Outside,
    /// None: the device keeps no place for the book, or none that lands in its text.
    none,
    /// The device couldn't say (busy, unreadable, too slow). Nothing is known of what
    /// it keeps, so this opening writes nothing over it.
    unknown,
};

test "a name is cut before a character, never inside one" {
    const long = "Telemóvel do André com um nome muito comprido";
    const n = Name.of(long);
    try std.testing.expect(n.len <= name_bytes_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(n.text()));
    try std.testing.expectEqualStrings("Kindle", Name.of("Kindle").text());
}
