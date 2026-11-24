//! The last few pictures drawn, decoded, scaled and dithered, so drawing a page
//! again doesn't decode them again: the App keeps one for the open book.
const std = @import("std");
const assert = std.debug.assert;

/// The last few pictures drawn, decoded, scaled and dithered, so drawing a page
/// again doesn't decode them again. Keyed by where the picture's bytes sit in the
/// open book, so it must be cleared when the book closes.
pub const Pictures = struct {
    entries: [slots]?Entry = @splat(null), // Null until a picture is put there
    next: u32 = 0, // Which entry to replace next

    pub const slots = 8;
    const Entry = struct { key: [*]const u8, w: u32, h: u32, pixels: []u8 };

    pub fn get(p: *const Pictures, data: [*]const u8, w: u32, h: u32) ?[]const u8 {
        assert(p.next < slots);
        for (p.entries) |entry| {
            const e = entry orelse continue;
            if (e.key == data and e.w == w and e.h == h) {
                assert(e.pixels.len == @as(u64, w) * h); // As put
                return e.pixels;
            }
        }
        return null;
    }

    pub fn put(
        p: *Pictures,
        alloc: std.mem.Allocator,
        data: [*]const u8,
        w: u32,
        h: u32,
        pixels: []u8,
    ) void {
        // Layout draws no picture without room for it
        assert(w > 0);
        assert(h > 0);
        assert(pixels.len == @as(u64, w) * h); // A whole picture at its size
        assert(p.next < slots);
        const slot = &p.entries[p.next];
        if (slot.*) |e| alloc.free(e.pixels);
        slot.* = .{ .key = data, .w = w, .h = h, .pixels = pixels };
        p.next = (p.next + 1) % slots;
        assert(p.get(data, w, h).?.ptr == pixels.ptr);
    }

    pub fn clear(p: *Pictures, alloc: std.mem.Allocator) void {
        assert(p.next < slots);
        for (&p.entries) |*slot| {
            if (slot.*) |e| alloc.free(e.pixels);
            slot.* = null;
        }
        p.next = 0;
    }
};

test "pictures are kept until replaced or cleared" {
    const alloc = std.testing.allocator;
    var p = Pictures{};
    defer p.clear(alloc);
    const key = "abc";
    p.put(alloc, key.ptr, 2, 1, try alloc.dupe(u8, "xy"));
    try std.testing.expectEqualStrings("xy", p.get(key.ptr, 2, 1).?);
    try std.testing.expect(p.get(key.ptr, 4, 2) == null); // Another size
    for (0..Pictures.slots) |i| {
        p.put(alloc, @ptrFromInt(0x1000 + i), 1, 1, try alloc.dupe(u8, "z"));
    }
    try std.testing.expect(p.get(key.ptr, 2, 1) == null); // Pushed out
}
