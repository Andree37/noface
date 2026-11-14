//! Page breaks saved per book, so opening a book doesn't lay out every page again.
//!
//! Breaks depend on the book, the reader's settings, the screen, and the code that
//! sets text. All of that goes into a key; a saved file with another key is ignored
//! and replaced. The code part is a fingerprint of the source files themselves, taken
//! at compile time, so an update that changes layout can never serve stale pages.
const std = @import("std");
const settings_model = @import("../../model/settings.zig");
const book_model = @import("../../model/book.zig");
const file = @import("../../sys/file.zig");
const state = @import("../../sys/state.zig");
const check = @import("../../base/check.zig");
const app = @import("../../app.zig");

const magic = "NFPG";

/// The source of everything that decides where a page breaks.
const code_fingerprint: u64 = blk: {
    @setEvalBranchQuota(50_000_000);
    var h = std.hash.Wyhash.init(0);
    for (.{
        @embedFile("../../layout/text.zig"),
        @embedFile("../../layout/hyphen.zig"),
        @embedFile("../../layout/hyphen/hyph-en-us.pat.txt"),
        @embedFile("../../layout/hyphen/hyph-en-us.hyp.txt"),
        @embedFile("../../layout/hyphen/hyph-pt.pat.txt"),
        @embedFile("../../gfx/font.zig"),
        @embedFile("../../kindle/kfx.zig"),
        @embedFile("../../kindle/ion.zig"),
        @embedFile("../../model/book.zig"),
        @embedFile("../../model/notes.zig"),
        @embedFile("../../model/settings.zig"),
        @embedFile("../../epub/epub.zig"),
        @embedFile("../../epub/xml.zig"),
        @embedFile("../../app.zig"),
        @embedFile("paginate.zig"),
    }) |source| h.update(source);
    break :blk h.final();
};

/// Everything the breaks depend on, besides the code.
pub fn key(a: *const app.App, book_bytes: usize) u64 {
    var h = std.hash.Wyhash.init(code_fingerprint);
    const s = a.settings;
    const l = a.layout;
    const parts = [_]u64{
        book_bytes,                       a.screen.width,                      a.screen.height,
        @bitCast(@as(i64, l.margin_top)), @bitCast(@as(i64, l.margin_bottom)), @as(u32, @bitCast(l.indent)),
    };
    h.update(std.mem.sliceAsBytes(&parts));
    // Every setting that moves breaks, so a new one can't be left out by mistake
    inline for (@typeInfo(settings_model.Settings).@"struct".field_names) |name| {
        if (comptime settings_model.moves_breaks(name)) {
            const value: u64 = switch (@TypeOf(@field(s, name))) {
                bool => @intFromBool(@field(s, name)),
                usize => @field(s, name),
                else => @compileError("page_store.key: say how to key the setting " ++ name),
            };
            h.update(std.mem.asBytes(&value));
        }
    }
    // The typeface by name: the reader's own take their places in the list from the
    // fonts folder at each start, so a place can pass to another font
    h.update(settings_model.families[s.font]);
    return h.final();
}

/// "<dir>/pages-<book>", beside the book's state file "<dir>/state-<book>".
pub fn path_for(buf: []u8, state_path: []const u8) ![:0]u8 {
    return state.sibling(buf, state_path, "pages");
}

const header_len = magic.len + 8 + 4;

/// The saved breaks, or null when there are none for this key.
pub fn load(alloc: std.mem.Allocator, path: [*:0]const u8, want: u64, paragraphs: usize) ?[]const book_model.Pos {
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    return decode(alloc, data, want, paragraphs);
}

pub fn save(alloc: std.mem.Allocator, path: [*:0]const u8, k: u64, pages: []const book_model.Pos) void {
    const bytes = encode(alloc, k, pages) catch return;
    defer alloc.free(bytes);
    state.write_small(path, bytes);
}

pub fn encode(alloc: std.mem.Allocator, k: u64, pages: []const book_model.Pos) ![]u8 {
    const out = try alloc.alloc(u8, header_len + pages.len * 8);
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u64, out[4..12], k, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(pages.len), .little);
    for (pages, 0..) |p, i| {
        const at = header_len + i * 8;
        std.mem.writeInt(u32, out[at..][0..4], @intCast(p.para), .little);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(p.byte), .little);
    }
    return out;
}

/// Reads saved breaks. The file comes from disk, so anything off means "not saved",
/// including a break past the book's last paragraph.
pub fn decode(alloc: std.mem.Allocator, data: []const u8, want: u64, paragraphs: usize) ?[]const book_model.Pos {
    if (data.len < header_len or !std.mem.eql(u8, data[0..magic.len], magic)) return null;
    if (std.mem.readInt(u64, data[4..12], .little) != want) return null;
    const count = std.mem.readInt(u32, data[12..16], .little);
    if (count == 0 or data.len != header_len + @as(usize, count) * 8) return null;
    const pages = alloc.alloc(book_model.Pos, count) catch return null;
    for (pages, 0..) |*p, i| {
        const at = header_len + i * 8;
        p.* = .{ .para = std.mem.readInt(u32, data[at..][0..4], .little), .byte = std.mem.readInt(u32, data[at + 4 ..][0..4], .little) };
        if (p.para >= paragraphs) {
            alloc.free(pages);
            return null;
        }
        // Breaks only move forward; anything else is a damaged file.
        if (i > 0) {
            const prev = pages[i - 1];
            if (p.para < prev.para or (p.para == prev.para and p.byte <= prev.byte)) {
                alloc.free(pages);
                return null;
            }
        }
    }
    return pages;
}

test "saved breaks come back only for the same key" {
    const alloc = std.testing.allocator;
    const pages = [_]book_model.Pos{ .{}, .{ .para = 3, .byte = 40 }, .{ .para = 9, .byte = 0 } };
    const bytes = try encode(alloc, 42, &pages);
    defer alloc.free(bytes);
    const back = decode(alloc, bytes, 42, 10).?;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(book_model.Pos, &pages, back);
    try std.testing.expect(decode(alloc, bytes, 43, 10) == null);
    try std.testing.expect(decode(alloc, bytes, 42, 9) == null); // The book has fewer paragraphs now
    try std.testing.expect(decode(alloc, bytes[0 .. bytes.len - 1], 42, 10) == null);
}

test "damaged files read as not saved" {
    const alloc = std.testing.allocator;
    const backwards = [_]book_model.Pos{ .{ .para = 5 }, .{ .para = 2 } };
    const bytes = try encode(alloc, 7, &backwards);
    defer alloc.free(bytes);
    try std.testing.expect(decode(alloc, bytes, 7, 10) == null);
    try std.testing.expect(decode(alloc, "NFPGjunk", 7, 10) == null);
}

test "pages files sit beside state files" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/d/pages-0bee89b07a248e27", try path_for(&buf, "/d/state-0bee89b07a248e27"));
}
