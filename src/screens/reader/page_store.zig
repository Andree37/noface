//! Page breaks saved per book, so opening a book doesn't lay out every page again.
//!
//! Breaks depend on the book, the reader's settings, the screen, and the code that
//! sets text. All of that goes into a key; a saved file with another key is ignored
//! and replaced. The code part is a fingerprint of the source files themselves, taken
//! at compile time, so an update that changes layout can never serve stale pages.
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("../../model/settings.zig");
const book_model = @import("../../model/book.zig");
const file = @import("../../sys/file.zig");
const state = @import("../../sys/state.zig");
const check = @import("../../base/check.zig");
const app = @import("../../app.zig");

const magic = "NFPG";

/// Raised by hand when breaks change for a reason no source file below shows (a font
/// table read differently by a file not listed, say), so old saved breaks are dropped.
const layout_version: u64 = 1;

/// The source of everything that decides where a page breaks, under `src/`: setting
/// text, the fonts' advances, kerning and character maps, and reading the books.
/// Every file these import is here or in `not_layout` (a test checks).
const layout_sources = [_][]const u8{
    "layout/text.zig",
    "layout/hyphen.zig",
    "layout/hyphen/hyph-en-us.pat.txt",
    "layout/hyphen/hyph-en-us.hyp.txt",
    "layout/hyphen/hyph-pt.pat.txt",
    "gfx/font.zig",
    "gfx/glyph_cache.zig",
    "gfx/truetype.zig",
    "gfx/cff.zig",
    "gfx/outline.zig",
    "gfx/raster.zig",
    "kindle/kfx.zig",
    "kindle/ion.zig",
    "model/book.zig",
    "model/notes.zig",
    "model/settings.zig",
    "epub/epub.zig",
    "epub/xml.zig",
    "epub/zip.zig",
    "epub/picture.zig",
    "app.zig",
    "screens/reader/paginate.zig",
};

/// Files the layout sources import that don't move a break: checks, the pixels a page
/// is drawn into, the memory fonts and decoders take, the memory a chapter's markup is
/// read in and the budgets it's counted by, and the library's series numbers.
const not_layout = [_][]const u8{
    "base/check.zig",
    "base/memory.zig",
    "gfx/page.zig",
    "gfx/decoder_memory.zig",
    "model/catalog.zig",
};

const code_fingerprint: u64 = blk: {
    @setEvalBranchQuota(100_000_000);
    var h = std.hash.Wyhash.init(layout_version);
    for (layout_sources) |source| h.update(@embedFile("../../" ++ source));
    break :blk h.final();
};

/// Everything the breaks depend on, besides the code.
pub fn key(a: *const app.App, book_bytes: u64) u64 {
    assert(a.screen.width > 0);
    assert(a.screen.height > 0);
    var h = std.hash.Wyhash.init(code_fingerprint);
    const s = a.settings;
    const l = a.layout;
    const parts = [_]u64{
        book_bytes,
        a.screen.width,
        a.screen.height,
        @bitCast(@as(i64, l.margin_top)),
        @bitCast(@as(i64, l.margin_bottom)),
        @as(u32, @bitCast(l.indent)),
    };
    h.update(std.mem.sliceAsBytes(&parts));
    // Every setting that moves breaks, so a new one can't be left out by mistake
    inline for (@typeInfo(settings_model.Settings).@"struct".field_names) |name| {
        if (comptime settings_model.moves_breaks(name)) {
            const value: u64 = key_setting(name, @field(s, name));
            h.update(std.mem.asBytes(&value));
        }
    }
    // The typeface by name: the reader's own take their places in the list from the
    // fonts folder at each start, so a place can pass to another font
    h.update(settings_model.families[s.font]);
    return h.final();
}

/// One setting's part of the key: a switch as 0 or 1, a choice by its number.
fn key_setting(comptime name: []const u8, value: anytype) u64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => @intFromBool(value),
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
const header_len = magic.len + 8 + 4;
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
    paragraph_count: u32,
) ?[]const book_model.Pos {
    assert(std.mem.len(path) > 0);
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    const pages = decode(alloc, data, want, paragraph_count) orelse return null;
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
        assert(is_before(previous, page));
    }
    // Not saving only costs laying the book out again next time
    const bytes = encode(alloc, k, pages) catch return;
    defer alloc.free(bytes);
    state.write_small(path, bytes);
}

/// Whether `first` comes strictly before `second` in the book.
fn is_before(first: book_model.Pos, second: book_model.Pos) bool {
    if (first.para != second.para) return first.para < second.para;
    return first.byte < second.byte;
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

/// Reads saved breaks. The file comes from disk, so anything off means "not saved",
/// including a break past the book's last paragraph.
pub fn decode(
    alloc: std.mem.Allocator,
    data: []const u8,
    want: u64,
    paragraph_count: u32,
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
        if (p.para >= paragraph_count) {
            alloc.free(pages);
            return null;
        }
        // Breaks only move forward; anything else is a damaged file.
        if (i > 0) {
            if (!is_before(pages[i - 1], p.*)) {
                alloc.free(pages);
                return null;
            }
        }
    }
    // What the checks above let through: a page on every break, all inside the book
    assert(pages.len == count);
    assert(pages[pages.len - 1].para < paragraph_count);
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
    // The book has fewer paragraphs now
    try std.testing.expect(decode(alloc, bytes, 42, 9) == null);
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
    const path = try path_for(&buf, "/d/state-0bee89b07a248e27");
    try std.testing.expectEqualStrings("/d/pages-0bee89b07a248e27", path);
}

/// The files under `src/` that `source` (a path under `src/`) imports, resolved.
fn imports_of(comptime source: []const u8) []const []const u8 {
    const text = @embedFile("../../" ++ source);
    const opening = "@import(\"";
    const folder = source[0..(std.mem.lastIndexOfScalar(u8, source, '/') orelse 0)];
    var found: []const []const u8 = &.{};
    var at: u32 = 0;
    for (0..text.len) |_| {
        const start = std.mem.indexOfPos(u8, text, at, opening) orelse break;
        const name_start = start + opening.len;
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '"').?;
        at = @intCast(name_end);
        const name = text[name_start..name_end];
        if (!std.mem.endsWith(u8, name, ".zig")) continue; // std and build options
        // Each "../" climbs a folder from the importing file's own
        var base: []const u8 = folder;
        var rest: []const u8 = name;
        for (0..name.len) |_| {
            if (!std.mem.startsWith(u8, rest, "../")) break;
            rest = rest[3..];
            base = base[0 .. std.mem.lastIndexOfScalar(u8, base, '/') orelse 0];
        }
        const path = if (base.len == 0) rest else base ++ "/" ++ rest;
        found = found ++ [_][]const u8{path};
    }
    return found;
}

test "every file the layout sources import is in the fingerprint, or doesn't move breaks" {
    comptime var missing: []const []const u8 = &.{};
    comptime {
        @setEvalBranchQuota(100_000_000);
        for (layout_sources) |source| {
            // The App's other imports are its screens and devices, not layout
            if (!std.mem.endsWith(u8, source, ".zig") or std.mem.eql(u8, source, "app.zig")) {
                continue;
            }
            for (imports_of(source)) |path| {
                const listed = for (layout_sources ++ not_layout) |known| {
                    if (std.mem.eql(u8, known, path)) break true;
                } else false;
                if (!listed) missing = missing ++ [_][]const u8{path};
            }
        }
    }
    for (missing) |path| std.debug.print("not fingerprinted: {s}\n", .{path});
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}
