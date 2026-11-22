//! Page breaks saved per book, so opening a book doesn't lay out every page again.
//!
//! Breaks depend on the book, the reader's settings, the screen, and the code that
//! sets text. All of that goes into a key; a saved file with another key is ignored
//! and replaced. The code's part is `layout_version`, raised by hand when the layout
//! breaks pages differently. A scenario ("the layout breaks pages where …") lays out
//! the test book and compares where its pages break with those recorded, so a change
//! that moves breaks fails until the version is raised, and one that doesn't (a
//! comment, a test, drawing alone) leaves every reader's saved breaks in place.
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("../../model/settings.zig");
const book_model = @import("../../model/book.zig");
const file = @import("../../sys/file.zig");
const state = @import("../../sys/state.zig");
const app = @import("../../app.zig");

const magic = "NFPG";

/// Raised by hand when the layout breaks pages differently, so saved breaks are laid
/// out again; the scenario that checks the recorded page breaks says when
/// (src/testdata/recorded/<model>/breaks.txt).
/// 4: a note's mark is told by its letters in any script (model/notes.zig `is_mark`),
/// so a book with marks in Cyrillic or Japanese flows otherwise.
const layout_version: u64 = 4;

/// Everything the breaks depend on.
pub fn key(a: *const app.App, book_bytes: u64) u64 {
    assert(a.display.screen.width > 0);
    assert(a.display.screen.height > 0);
    var h = std.hash.Wyhash.init(layout_version);
    const s = a.user.settings;
    const l = a.layout;
    const parts = [_]u64{
        book_bytes,
        a.display.screen.width,
        a.display.screen.height,
        @bitCast(@as(i64, l.margin_top)),
        @bitCast(@as(i64, l.margin_bottom)),
        @as(u32, @bitCast(l.indent)),
    };
    h.update(std.mem.sliceAsBytes(&parts));
    // Every setting that moves breaks, so a new one can't be left out by mistake
    inline for (@typeInfo(settings_model.Settings).@"struct".field_names) |name| {
        if (comptime settings_model.moves_breaks(name)) {
            const value: u64 = key_setting(name, @field(s, name), a.families());
            h.update(std.mem.asBytes(&value));
        }
    }
    return h.final();
}

/// One setting's part of the key: a switch as 0 or 1, a choice by its number.
fn key_setting(comptime name: []const u8, value: anytype, families: settings_model.Families) u64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => @intFromBool(value),
        // The typeface drawn, by its name: a font whose file is gone for now is drawn
        // in the first, and breaks laid out so mustn't serve it once it's back
        .@"struct" => if (@TypeOf(value) == settings_model.Family)
            std.hash.Wyhash.hash(0, families.names[value.index(families)])
        else
            @compileError("page_store.key: say how to key the setting " ++ name),
        .int => |int| blk: {
            if (int.signedness != .unsigned or int.bits > 64) {
                @compileError("page_store.key: say how to key the setting " ++ name);
            }
            break :blk value;
        },
        else => @compileError("page_store.key: say how to key the setting " ++ name),
    };
}

/// "<dir>/pages-<book>", beside the book's state file "<dir>/state-<book>".
pub fn path_for(buf: []u8, state_path: []const u8) ![:0]u8 {
    assert(state_path.len > 0);
    const path = try state.sibling(buf, state_path, "pages");
    assert(path.len < buf.len); // Room for the sentinel too
    return path;
}

/// The magic, the key, then the page count; each page's break follows in 8 bytes.
pub const header_len = magic.len + 8 + 4;
const page_len = 8;

comptime {
    // The header's offsets below are written out by hand
    assert(magic.len == 4);
    assert(header_len == 16);
    assert(page_len == 2 * @sizeOf(u32));
}

/// The saved breaks, or null when there are none for this key.
pub fn load(
    alloc: std.mem.Allocator,
    path: [*:0]const u8,
    want: u64,
    paragraphs: []const book_model.Paragraph,
) ?[]const book_model.Pos {
    assert(std.mem.len(path) > 0);
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    const pages = decode(alloc, data, want, paragraphs) orelse return null;
    assert(pages.len > 0);
    return pages;
}

pub fn save(
    alloc: std.mem.Allocator,
    path: [*:0]const u8,
    k: u64,
    pages: []const book_model.Pos,
) void {
    assert(std.mem.len(path) > 0);
    assert(pages.len > 0);
    // The breaks move forward as they're saved, as `decode` insists when they're read back
    for (pages[1..], pages[0 .. pages.len - 1]) |page, previous| {
        assert(previous.is_before(page));
    }
    // Not saving only costs laying the book out again next time
    const bytes = encode(alloc, k, pages) catch return;
    defer alloc.free(bytes);
    file.write_small(path, bytes);
}

pub fn encode(alloc: std.mem.Allocator, k: u64, pages: []const book_model.Pos) ![]u8 {
    const count: u32 = @intCast(pages.len);
    const out = try alloc.alloc(u8, header_len + pages.len * page_len);
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u64, out[4..12], k, .little);
    std.mem.writeInt(u32, out[12..16], count, .little);
    for (pages, 0..) |p, i| {
        const at = header_len + i * page_len;
        std.mem.writeInt(u32, out[at..][0..4], @intCast(p.para), .little);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(p.byte), .little);
    }
    assert(out.len == header_len + @as(u64, count) * page_len);
    assert(std.mem.readInt(u32, out[12..16], .little) == pages.len);
    return out;
}

/// Reads saved breaks. The file comes from disk, so anything off means "not saved":
/// a break past the book's last paragraph or past its paragraph's text, or a first
/// page that isn't the book's start.
pub fn decode(
    alloc: std.mem.Allocator,
    data: []const u8,
    want: u64,
    paragraphs: []const book_model.Paragraph,
) ?[]const book_model.Pos {
    if (data.len < header_len) return null;
    if (!std.mem.eql(u8, data[0..magic.len], magic)) return null;
    if (std.mem.readInt(u64, data[4..12], .little) != want) return null;
    const count = std.mem.readInt(u32, data[12..16], .little);
    if (count == 0) return null;
    if (data.len != header_len + @as(u64, count) * page_len) return null;
    const pages = alloc.alloc(book_model.Pos, count) catch return null;
    for (pages, 0..) |*p, i| {
        const at = header_len + i * page_len;
        p.* = .{
            .para = std.mem.readInt(u32, data[at..][0..4], .little),
            .byte = std.mem.readInt(u32, data[at + 4 ..][0..4], .little),
        };
        const previous = if (i > 0) pages[i - 1] else null;
        if (!decode_fits(paragraphs, previous, p.*)) {
            alloc.free(pages);
            return null;
        }
    }
    // What the checks above let through: a page on every break, all inside the book
    assert(pages.len == count);
    assert(pages[pages.len - 1].para < paragraphs.len);
    return pages;
}

/// Whether a break read back can follow `previous` (null for the first page): inside
/// the book's text, and moving forward from the book's start.
fn decode_fits(
    paragraphs: []const book_model.Paragraph,
    previous: ?book_model.Pos,
    p: book_model.Pos,
) bool {
    if (p.para >= paragraphs.len) return false;
    // At most the paragraph's end: an empty paragraph breaks at its byte 0
    if (p.byte > paragraphs[p.para].text.len) return false;
    const after = previous orelse return std.meta.eql(p, book_model.Pos{});
    return after.is_before(p);
}

/// A book of ten paragraphs of 64 letters, for reading breaks back against.
const test_letters: [64]u8 = @splat('a');
const test_book: [10]book_model.Paragraph = @splat(.{ .text = &test_letters });

test "saved breaks come back only for the same key" {
    const alloc = std.testing.allocator;
    const pages = [_]book_model.Pos{ .{}, .{ .para = 3, .byte = 40 }, .{ .para = 9, .byte = 0 } };
    const bytes = try encode(alloc, 42, &pages);
    defer alloc.free(bytes);
    const back = decode(alloc, bytes, 42, &test_book).?;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(book_model.Pos, &pages, back);
    try std.testing.expect(decode(alloc, bytes, 43, &test_book) == null);
    // The book has fewer paragraphs now
    try std.testing.expect(decode(alloc, bytes, 42, test_book[0..9]) == null);
    try std.testing.expect(decode(alloc, bytes[0 .. bytes.len - 1], 42, &test_book) == null);
}

test "damaged files read as not saved" {
    const alloc = std.testing.allocator;
    const backwards = [_]book_model.Pos{ .{}, .{ .para = 5 }, .{ .para = 2 } };
    const bytes = try encode(alloc, 7, &backwards);
    defer alloc.free(bytes);
    try std.testing.expect(decode(alloc, bytes, 7, &test_book) == null);
    try std.testing.expect(decode(alloc, "NFPGjunk", 7, &test_book) == null);
}

test "a break past its paragraph's text, or a first page not at the start, reads as not saved" {
    // Bookmarks and notes assert on these breaks' bytes, so a damaged file stops here
    const alloc = std.testing.allocator;
    const at_end = [_]book_model.Pos{ .{}, .{ .para = 3, .byte = 64 } };
    const fits = try encode(alloc, 7, &at_end);
    defer alloc.free(fits);
    const back = decode(alloc, fits, 7, &test_book).?;
    defer alloc.free(back);
    try std.testing.expectEqualSlices(book_model.Pos, &at_end, back);
    const past_end = [_]book_model.Pos{ .{}, .{ .para = 3, .byte = 65 } };
    const past = try encode(alloc, 7, &past_end);
    defer alloc.free(past);
    try std.testing.expect(decode(alloc, past, 7, &test_book) == null);
    const late_start = [_]book_model.Pos{ .{ .para = 1 }, .{ .para = 3 } };
    const late = try encode(alloc, 7, &late_start);
    defer alloc.free(late);
    try std.testing.expect(decode(alloc, late, 7, &test_book) == null);
}

test "pages files sit beside state files" {
    var buf: [128]u8 = undefined;
    const path = try path_for(&buf, "/d/state-0bee89b07a248e27");
    try std.testing.expectEqualStrings("/d/pages-0bee89b07a248e27", path);
}
