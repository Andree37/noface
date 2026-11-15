//! EPUB books, read into the same model.Book as Kindle books: paragraphs with their
//! look, bold and italic runs, pictures, links between them, and the contents.
//! Only what a reader needs from the markup is kept; CSS is not read, so headings
//! and emphasis come from the tags themselves.
const std = @import("std");
const assert = std.debug.assert;
const book = @import("../model/book.zig");
const notes = @import("../model/notes.zig");
const catalog = @import("../model/catalog.zig");
const zip = @import("zip.zig");
const xml = @import("xml.zig");
const picture = @import("picture.zig");

/// What the library shows, read without opening the whole book.
pub const Info = struct {
    title: []const u8,
    author: []const u8,
    cover: ?[]const u8 = null,
    series: []const u8 = "",
    series_index: f32 = 0,
};

/// The package document: metadata, every file it lists, and the reading order.
const Package = struct {
    dir: []const u8, // Folder of the package file; hrefs are relative to it
    title: []const u8 = "",
    author: []const u8 = "",
    items: []Item,
    spine: []const []const u8, // Item ids, in reading order
    toc_ncx: ?[]const u8 = null, // EPUB 2 contents, an item id
    cover_id: ?[]const u8 = null,
    series: []const u8 = "", // From Calibre's metadata, which most EPUBs carry
    series_index: f32 = 0,

    const Item = struct {
        id: []const u8,
        href: []const u8,
        media: []const u8,
        properties: []const u8,
    };

    fn item(p: *const Package, id: []const u8) ?Item {
        // `read_package` refuses a book without a reading order
        assert(p.spine.len > 0);
        for (p.items) |i| {
            if (std.mem.eql(u8, i.id, id)) return i;
        }
        return null;
    }
};

/// Paragraph by "file#id", or by "file" for its first paragraph.
const Anchors = std.StringHashMapUnmanaged(u32);

/// Headings' looks, h1 to h4; h5 and h6 look like h4. Sizes index `book.size_scales`.
const heading_looks = [_]book.Look{
    .{ .bold = true, .size = 4, .alignment = .center, .space_before = 10, .space_after = 6 },
    .{ .bold = true, .size = 3, .space_before = 8, .space_after = 4 },
    .{ .bold = true, .size = 2, .space_before = 6, .space_after = 3 },
    .{ .bold = true, .space_before = 4, .space_after = 2 },
};
const heading_levels = 6;

/// Tags that end a paragraph and start the next, besides the headings.
const block_names = [_][]const u8{
    "p",          "div", "li",      "blockquote", "br",    "tr",
    "dt",         "dd",  "section", "article",    "aside", "figure",
    "figcaption", "hr",  "pre",     "table",      "ul",    "ol",
    "body",
};
const bold_names = [_][]const u8{ "b", "strong" };
const italic_names = [_][]const u8{ "i", "em", "cite" };
/// Tags whose text isn't the book's.
const skipped_names = [_][]const u8{ "style", "script", "head" };
const picture_names = [_][]const u8{ "img", "image" };

comptime {
    assert(heading_looks.len <= heading_levels);
    for (heading_looks) |look| {
        assert(look.bold);
        // A heading is never set smaller than the text around it
        assert(look.size >= book.normal_size);
        assert(look.size < book.size_scales.len);
    }
    // A line break is a block, which `start_block` keeps in its block's look
    assert(eql_any("br", &block_names));
    // A tag styles text or makes a block, never both: closing it does one thing
    for (bold_names ++ italic_names ++ skipped_names) |name| {
        assert(!eql_any(name, &block_names));
    }
    for (bold_names) |name| {
        assert(!eql_any(name, &italic_names));
    }
}

fn read_file(alloc: std.mem.Allocator, files: []const zip.Entry, name: []const u8) ![]const u8 {
    // An archive's count of files is 16 bits
    assert(files.len <= std.math.maxInt(u16));
    const e = zip.find(files, name) orelse return error.MissingFile;
    const contents = try zip.read(alloc, &e);
    assert(contents.len == e.size);
    return contents;
}

/// Joins a relative href onto a folder, resolving "..", and drops any "#fragment".
fn resolve(alloc: std.mem.Allocator, dir: []const u8, href: []const u8) ![]const u8 {
    const plain = href[0 .. std.mem.indexOfScalar(u8, href, '#') orelse href.len];
    assert(std.mem.indexOfScalar(u8, plain, '#') == null);
    var parts: std.ArrayList([]const u8) = .empty;
    var dirs = std.mem.tokenizeScalar(u8, dir, '/');
    while (dirs.next()) |d| try parts.append(alloc, d);
    var it = std.mem.tokenizeScalar(u8, plain, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
        } else if (!std.mem.eql(u8, part, ".")) {
            try parts.append(alloc, try unescape(alloc, part));
        }
    }
    // Every part is a whole, non-empty piece of `dir` or `href`
    assert(parts.items.len <= dir.len + plain.len);
    return std.mem.join(alloc, "/", parts.items);
}

/// "%20" and friends, as hrefs are URL-encoded.
fn unescape(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    // A part of an href, from a file inside the book's zip
    assert(text.len <= zip.size_max);
    if (std.mem.indexOfScalar(u8, text, '%') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var index: u32 = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '%' and index + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[index + 1 .. index + 3], 16)) |byte| {
                try out.append(alloc, byte);
                index += 2;
                continue;
            } else |_| {}
        }
        try out.append(alloc, text[index]);
    }
    // Each escape is three bytes for one, and anything else is kept as it is
    assert(out.items.len > 0);
    assert(out.items.len <= text.len);
    return out.items;
}

/// The text up to where `closing` closes, decoded and trimmed: a title, say.
fn text_of(alloc: std.mem.Allocator, t: *xml.Tokenizer, closing: []const u8) ![]const u8 {
    assert(closing.len > 0);
    var out: std.ArrayList(u8) = .empty;
    while (t.next()) |tok| switch (tok) {
        .text => |s| try xml.decode(&out, alloc, s),
        .close => |name| if (std.mem.eql(u8, name, closing)) break,
        .open => {},
    };
    const text = std.mem.trim(u8, out.items, " \t\r\n");
    assert(text.len <= out.items.len);
    return text;
}

fn read_package(alloc: std.mem.Allocator, files: []const zip.Entry) !Package {
    const container = try read_file(alloc, files, "META-INF/container.xml");
    var path: ?[]const u8 = null;
    var t = xml.Tokenizer{ .data = container };
    while (t.next()) |tok| {
        if (tok == .open and std.mem.eql(u8, tok.open.name, "rootfile")) {
            path = xml.attribute(tok.open.attributes, "full-path");
            break;
        }
    }
    const opf_path = path orelse return error.NoPackage;
    const opf = try read_file(alloc, files, opf_path);
    const dir = std.fs.path.dirnamePosix(opf_path) orelse "";
    assert(dir.len <= opf_path.len);
    var p = Package{ .dir = dir, .items = &.{}, .spine = &.{} };
    var items: std.ArrayList(Package.Item) = .empty;
    var spine: std.ArrayList([]const u8) = .empty;
    t = .{ .data = opf };
    while (t.next()) |tok| {
        if (tok != .open) continue;
        const o = tok.open;
        if (std.mem.eql(u8, o.name, "title") and p.title.len == 0) {
            p.title = try text_of(alloc, &t, "title");
        }
        if (std.mem.eql(u8, o.name, "creator") and p.author.len == 0) {
            p.author = try text_of(alloc, &t, "creator");
        }
        if (std.mem.eql(u8, o.name, "item")) try items.append(alloc, .{
            .id = xml.attribute(o.attributes, "id") orelse "",
            .href = xml.attribute(o.attributes, "href") orelse "",
            .media = xml.attribute(o.attributes, "media-type") orelse "",
            .properties = xml.attribute(o.attributes, "properties") orelse "",
        });
        if (std.mem.eql(u8, o.name, "itemref")) {
            if (xml.attribute(o.attributes, "idref")) |id| try spine.append(alloc, id);
        }
        if (std.mem.eql(u8, o.name, "spine")) p.toc_ncx = xml.attribute(o.attributes, "toc");
        if (std.mem.eql(u8, o.name, "meta")) read_package_meta(&p, &o);
    }
    p.items = items.items;
    p.spine = spine.items;
    if (p.spine.len == 0) return error.NoSpine;
    assert(p.spine.len > 0);
    return p;
}

/// A <meta> naming the cover, or Calibre's series and place in it.
fn read_package_meta(p: *Package, meta: *const xml.Tag) void {
    assert(std.mem.eql(u8, meta.name, "meta"));
    const name = xml.attribute(meta.attributes, "name") orelse "";
    const content = xml.attribute(meta.attributes, "content");
    if (std.mem.eql(u8, name, "cover")) p.cover_id = content;
    if (std.mem.eql(u8, name, "calibre:series")) p.series = content orelse "";
    if (std.mem.eql(u8, name, "calibre:series_index")) {
        p.series_index = series_place(content orelse "");
    }
    // Items are gathered aside, and set on the package once it's all read
    assert(p.items.len == 0);
}

/// Calibre's place in a series: a number from 0 to `catalog.max_index`, as a file name's
/// or a hand-set one is. Anything else ("nan", "inf", "-3", a word) counts as none.
// Assertions: it reads a place from the book's metadata, which is outside data.
fn series_place(text: []const u8) f32 {
    const place = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch return 0;
    if (!std.math.isFinite(place)) return 0;
    if (place < 0 or place > catalog.max_index) return 0;
    return place;
}

/// Title, author and, if asked for, the cover, for the library.
pub fn info(alloc: std.mem.Allocator, data: []const u8, with_cover: bool) !Info {
    const files = try zip.entries(alloc, data);
    const p = try read_package(alloc, files);
    assert(p.spine.len > 0);
    const cover = if (with_cover) try info_cover(alloc, files, &p) else null;
    if (!with_cover) assert(cover == null);
    return .{
        .title = p.title,
        .author = p.author,
        .cover = cover,
        .series = p.series,
        .series_index = p.series_index,
    };
}

/// The cover's bytes: the item EPUB 3 marks as the cover image, or the one EPUB 2's
/// metadata names. Null when there's none, or it won't read.
fn info_cover(alloc: std.mem.Allocator, files: []const zip.Entry, p: *const Package) !?[]const u8 {
    assert(p.spine.len > 0);
    for (p.items) |i| {
        const marked = std.mem.indexOf(u8, i.properties, "cover-image") != null;
        const named = if (p.cover_id) |id| std.mem.eql(u8, i.id, id) else false;
        if (!marked and !named) continue;
        const path = try resolve(alloc, p.dir, i.href);
        // A cover that won't read means no picture, not no book
        return read_file(alloc, files, path) catch null;
    }
    return null;
}

/// Where a heading tag puts its text: bigger and bold, the largest centred.
fn heading_look(name: []const u8) ?book.Look {
    if (name.len != 2 or name[0] != 'h' or name[1] < '1' or name[1] > '6') return null;
    const level = name[1] - '1';
    assert(level < heading_levels);
    const look = heading_looks[@min(level, heading_looks.len - 1)];
    assert(look.bold);
    return look;
}

fn is_block(name: []const u8) bool {
    const block = eql_any(name, &block_names) or heading_look(name) != null;
    // Closing a tag ends a paragraph or a style, never both
    if (block) {
        assert(!eql_any(name, &bold_names));
        assert(!eql_any(name, &italic_names));
    }
    return block;
}

fn eql_any(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |l| {
        if (std.mem.eql(u8, name, l)) return true;
    }
    return false;
}

/// A link before its target is known: from where, to "file#id".
const PendingLink = struct { paragraph: u32, start: u32, end: u32, target: []const u8 };

/// Builds paragraphs from one spine file's body.
const Builder = struct {
    alloc: std.mem.Allocator,
    files: []const zip.Entry,
    paragraphs: std.ArrayList(book.Paragraph) = .empty,
    anchors: Anchors = .empty,
    // "file#id" that fall partway into a paragraph
    inner_anchors: std.StringHashMapUnmanaged(void) = .empty,
    links: std.ArrayList(PendingLink) = .empty,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(book.Run) = .empty,
    look: book.Look = .{},
    bold: u32 = 0, // How many bold tags are open
    italic: u32 = 0,
    run_start: ?u32 = null, // Where the current bold or italic stretch began
    link_start: ?u32 = null,
    link_target: []const u8 = "",
    section: u32 = 0,
    file: []const u8 = "",
    dir: []const u8 = "", // The chapter file's folder, for the paths it refers to
    in_body: bool = false,
    skipping: ?[]const u8 = null, // Inside <head>, <style> or <script>: no text
    waiting_ids: std.ArrayList([]const u8) = .empty, // Anchors for the next paragraph

    /// The paragraph's text so far, in bytes. Text comes from one chapter file, which
    /// the zip reader keeps under `zip.size_max`, and decoding it only shrinks it.
    fn text_length(b: *const Builder) u32 {
        const length = b.text.items.len;
        assert(length <= zip.size_max);
        return @intCast(length);
    }

    /// Closes the bold or italic stretch running so far, before the style changes.
    fn end_run(b: *Builder) !void {
        const start = b.run_start orelse return;
        b.run_start = null;
        const end = b.text_length();
        // Text only grows until `flush`, which ends the run before clearing it
        assert(start <= end);
        if (end == start) return;
        try b.runs.append(b.alloc, .{
            .start = start,
            .end = end,
            .bold = b.bold > 0,
            .italic = b.italic > 0,
        });
    }

    fn start_run(b: *Builder) void {
        // Every run started has ended first
        assert(b.run_start == null);
        if (b.bold > 0 or b.italic > 0) b.run_start = b.text_length();
        if (b.run_start) |start| assert(start == b.text.items.len);
    }

    fn add_text(b: *Builder, raw: []const u8) !void {
        assert(b.in_body);
        assert(b.skipping == null);
        var decoded: std.ArrayList(u8) = .empty;
        try xml.decode(&decoded, b.alloc, raw);
        // Whitespace in markup is layout, not text: runs of it become one space.
        for (decoded.items) |c| {
            const space = c == ' ' or c == '\n' or c == '\t' or c == '\r';
            if (space) {
                if (b.text.items.len == 0 or b.text.items[b.text.items.len - 1] == ' ') continue;
                try b.text.append(b.alloc, ' ');
            } else {
                try b.text.append(b.alloc, c);
            }
        }
        if (b.text.items.len > 0) assert(b.text.items[0] != ' ');
    }

    /// Ends the paragraph being built, if it has any text.
    fn flush(b: *Builder) !void {
        try b.end_run();
        while (b.text.items.len > 0 and b.text.items[b.text.items.len - 1] == ' ') {
            _ = b.text.pop();
        }
        b.trim_ranges();
        if (b.text.items.len > 0) try b.flush_paragraph();
        b.text.clearRetainingCapacity();
        b.runs.clearRetainingCapacity();
        b.start_run();
        assert(b.text.items.len == 0);
        assert(b.runs.items.len == 0);
    }

    /// Ends the runs and links of the paragraph being built where its text now ends: a
    /// trailing space they took in was trimmed after they ended. One left over no text
    /// is dropped.
    fn trim_ranges(b: *Builder) void {
        const length = b.text_length();
        const paragraph: u32 = @intCast(b.paragraphs.items.len);
        var runs_kept: u32 = 0;
        for (b.runs.items) |r| {
            if (r.start >= length) continue;
            b.runs.items[runs_kept] = r;
            b.runs.items[runs_kept].end = @min(r.end, length);
            runs_kept += 1;
        }
        b.runs.shrinkRetainingCapacity(runs_kept);
        // This paragraph's links are the last ones added
        var index: u32 = @intCast(b.links.items.len);
        for (0..b.links.items.len) |_| {
            if (index == 0) break;
            const l = &b.links.items[index - 1];
            if (l.paragraph != paragraph) break;
            index -= 1;
            l.end = @min(l.end, length);
            if (l.start >= l.end) _ = b.links.orderedRemove(index);
        }
        for (b.runs.items) |r| assert(r.end <= length);
        for (b.links.items[index..]) |l| assert(l.end <= length);
    }

    fn flush_paragraph(b: *Builder) !void {
        assert(b.text.items.len > 0);
        assert(b.text.items[0] != ' ');
        const index: u32 = @intCast(b.paragraphs.items.len);
        try b.paragraphs.append(b.alloc, .{
            .text = try b.alloc.dupe(u8, b.text.items),
            .style = 0,
            .look = b.look,
            .runs = try b.alloc.dupe(book.Run, b.runs.items),
            .section = b.section,
        });
        try b.place_anchors(index);
    }

    fn place_anchors(b: *Builder, index: u32) !void {
        // The paragraph the anchors land on is the one just added
        assert(index + 1 == b.paragraphs.items.len);
        for (b.waiting_ids.items) |id| {
            const key = try std.fmt.allocPrint(b.alloc, "{s}#{s}", .{ b.file, id });
            const slot = try b.anchors.getOrPut(b.alloc, key);
            if (!slot.found_existing) slot.value_ptr.* = index;
        }
        b.waiting_ids.clearRetainingCapacity();
        const file_slot = try b.anchors.getOrPut(b.alloc, b.file);
        if (!file_slot.found_existing) file_slot.value_ptr.* = index;
        assert(b.waiting_ids.items.len == 0);
    }

    fn add_picture(b: *Builder, dir: []const u8, src: []const u8) !void {
        assert(b.in_body);
        const path = try resolve(b.alloc, dir, src);
        const entry = zip.find(b.files, path) orelse return;
        // The book's own bytes, read only as far as their size: only JPEG and PNG
        // can be drawn
        const image = picture.image(&entry) orelse return;
        assert(image.data.ptr == entry.data.ptr); // Never a copy
        try b.flush();
        const index: u32 = @intCast(b.paragraphs.items.len);
        try b.paragraphs.append(b.alloc, .{
            .text = "",
            .style = 0,
            .image = image,
            .section = b.section,
        });
        try b.place_anchors(index);
    }

    /// Adds one chapter's text: its paragraphs, with their styles, pictures, links and
    /// the anchors links can point to.
    fn chapter(b: *Builder, path: []const u8, xhtml: []const u8) !void {
        // The chapter before ended its last paragraph
        assert(b.text.items.len == 0);
        b.file = path;
        b.dir = std.fs.path.dirnamePosix(path) orelse "";
        b.in_body = false;
        b.skipping = null;
        var t = xml.Tokenizer{ .data = xhtml };
        while (t.next()) |tok| switch (tok) {
            .text => |text| if (b.in_body and b.skipping == null) try b.add_text(text),
            .open => |tag| try b.open_tag(&tag),
            .close => |name| try b.close_tag(name),
        };
        try b.flush();
        b.bold = 0;
        b.italic = 0;
        assert(b.text.items.len == 0);
    }

    fn open_tag(b: *Builder, tag: *const xml.Tag) !void {
        if (b.skipping != null) return;
        if (std.mem.eql(u8, tag.name, "body")) b.in_body = true;
        if (!b.in_body) return;
        if (eql_any(tag.name, &skipped_names) and !tag.self_closing) {
            b.skipping = tag.name;
            return;
        }
        if (xml.attribute(tag.attributes, "id")) |id| try b.note_anchor(id);
        if (is_block(tag.name)) try b.start_block(tag.name);
        if (eql_any(tag.name, &bold_names)) try b.nest_style(&b.bold, .in);
        if (eql_any(tag.name, &italic_names)) try b.nest_style(&b.italic, .in);
        if (std.mem.eql(u8, tag.name, "a")) b.start_link(tag);
        if (eql_any(tag.name, &picture_names)) {
            const src = xml.attribute(tag.attributes, "src") orelse
                xml.attribute(tag.attributes, "href") orelse return;
            try b.add_picture(b.dir, src);
        }
        // A block starts with nothing pending, and a run never starts past the text
        if (is_block(tag.name)) assert(b.text.items.len == 0);
        if (b.run_start) |start| assert(start <= b.text_length());
    }

    fn close_tag(b: *Builder, name: []const u8) !void {
        if (b.skipping) |skipped| {
            if (std.mem.eql(u8, skipped, name)) b.skipping = null;
            return;
        }
        if (eql_any(name, &bold_names)) try b.nest_style(&b.bold, .out);
        if (eql_any(name, &italic_names)) try b.nest_style(&b.italic, .out);
        if (std.mem.eql(u8, name, "a")) try b.end_link();
        if (is_block(name)) {
            try b.flush();
            b.look = .{};
            assert(b.text.items.len == 0);
            assert(b.look.size == book.normal_size);
        }
    }

    /// An element with an id, which links can point to: kept for the paragraph about to
    /// start, and noted as partway in when text has already started.
    fn note_anchor(b: *Builder, id: []const u8) !void {
        assert(b.in_body);
        if (b.text.items.len > 0) {
            const key = try std.fmt.allocPrint(b.alloc, "{s}#{s}", .{ b.file, id });
            try b.inner_anchors.put(b.alloc, key, {});
        }
        try b.waiting_ids.append(b.alloc, id);
        assert(b.waiting_ids.items.len > 0);
    }

    /// A block begins a paragraph, in its heading's look if it is one. A line break
    /// stays in its block's look: "<h2><img/><br/>Chapter I.</h2>" is still a heading
    /// after the picture.
    fn start_block(b: *Builder, name: []const u8) !void {
        assert(is_block(name));
        try b.flush();
        assert(b.text.items.len == 0);
        if (!std.mem.eql(u8, name, "br")) b.look = heading_look(name) orelse .{};
    }

    /// Bold or italic going in or out: the text so far ends its run, a new one starts.
    fn nest_style(b: *Builder, depth: *u32, way: enum { in, out }) !void {
        assert(depth == &b.bold or depth == &b.italic);
        if (way == .out and depth.* == 0) return; // A stray closing tag
        try b.end_run();
        assert(b.run_start == null);
        if (way == .in) depth.* += 1 else depth.* -= 1;
        b.start_run();
    }

    /// A link within the book (not to the web) starts here.
    fn start_link(b: *Builder, tag: *const xml.Tag) void {
        assert(std.mem.eql(u8, tag.name, "a"));
        const href = xml.attribute(tag.attributes, "href") orelse return;
        if (href.len == 0) return; // Nowhere to go, and `end_link` reads its first byte
        if (std.mem.indexOf(u8, href, "://") != null) return;
        b.link_start = b.text_length();
        b.link_target = href;
        assert(b.link_target.len > 0);
    }

    /// The link that started ends here, over the text since, its target resolved
    /// against this chapter: "#note1" or "notes.xhtml#note1".
    fn end_link(b: *Builder) !void {
        const start = b.link_start orelse return;
        b.link_start = null;
        const end = b.text_length();
        if (end <= start) return;
        const href = b.link_target;
        assert(href.len > 0);
        const fragment = href[std.mem.indexOfScalar(u8, href, '#') orelse href.len ..];
        const file = if (href[0] == '#') b.file else try resolve(b.alloc, b.dir, href);
        const target = try std.fmt.allocPrint(b.alloc, "{s}{s}", .{ file, fragment });
        try b.links.append(b.alloc, .{
            .paragraph = @intCast(b.paragraphs.items.len),
            .start = start,
            .end = end,
            .target = target,
        });
    }

    /// Ties each link to the paragraph its target landed in.
    fn resolve_links(b: *Builder) !void {
        var per_paragraph = std.AutoHashMapUnmanaged(u32, std.ArrayList(book.Link)).empty;
        for (b.links.items) |l| {
            // `end_link` keeps only links over some text
            assert(l.start < l.end);
            if (l.paragraph >= b.paragraphs.items.len) continue;
            const target = b.anchors.get(l.target) orelse continue;
            // Anchors are placed on paragraphs as they're added
            assert(target < b.paragraphs.items.len);
            const slot = try per_paragraph.getOrPut(b.alloc, l.paragraph);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(b.alloc, .{
                .start = l.start,
                .end = l.end,
                .target = target,
                .inside = b.inner_anchors.contains(l.target),
            });
        }
        var it = per_paragraph.iterator();
        while (it.next()) |kv| b.paragraphs.items[kv.key_ptr.*].links = kv.value_ptr.items;
    }
};

/// Contents from EPUB 3's nav document, or EPUB 2's NCX.
fn read_contents(
    alloc: std.mem.Allocator,
    files: []const zip.Entry,
    p: *const Package,
    anchors: *const Anchors,
) ![]book.Chapter {
    // Every paragraph added anchors its file, and a book has paragraphs
    assert(anchors.count() > 0);
    var out: std.ArrayList(book.Chapter) = .empty;
    for (p.items) |i| {
        if (std.mem.indexOf(u8, i.properties, "nav") == null) continue;
        const path = try resolve(alloc, p.dir, i.href);
        const nav = read_file(alloc, files, path) catch break;
        try read_contents_nav(alloc, &out, path, nav, anchors);
        if (out.items.len > 0) return out.items;
    }
    assert(out.items.len == 0);
    const ncx_id = p.toc_ncx orelse return out.items;
    const ncx_item = p.item(ncx_id) orelse return out.items;
    const path = try resolve(alloc, p.dir, ncx_item.href);
    const ncx = read_file(alloc, files, path) catch return out.items;
    try read_contents_ncx(alloc, &out, path, ncx, anchors);
    return out.items;
}

/// EPUB 3's contents: the links in the nav of type "toc", nested in lists.
fn read_contents_nav(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(book.Chapter),
    path: []const u8,
    nav: []const u8,
    anchors: *const Anchors,
) !void {
    assert(out.items.len == 0);
    const dir = std.fs.path.dirnamePosix(path) orelse "";
    assert(dir.len <= path.len);
    var t = xml.Tokenizer{ .data = nav };
    var in_toc = false;
    var depth: u8 = 0;
    while (t.next()) |tok| switch (tok) {
        .open => |o| {
            if (std.mem.eql(u8, o.name, "nav")) {
                const kind = xml.attribute(o.attributes, "type") orelse "";
                in_toc = std.mem.indexOf(u8, kind, "toc") != null;
            }
            if (!in_toc) continue;
            if (std.mem.eql(u8, o.name, "ol")) depth +|= 1;
            if (std.mem.eql(u8, o.name, "a")) {
                const href = xml.attribute(o.attributes, "href") orelse continue;
                const title = try text_of(alloc, &t, "a");
                const found = try anchor_for(alloc, dir, href, anchors);
                const paragraph = found orelse continue;
                try out.append(alloc, .{ .title = title, .para = paragraph, .depth = depth -| 1 });
            }
        },
        .close => |name| {
            if (std.mem.eql(u8, name, "ol")) depth -|= 1;
            if (std.mem.eql(u8, name, "nav")) in_toc = false;
        },
        .text => {},
    };
}

/// EPUB 2's contents: nested navPoints, each a title and where it goes.
fn read_contents_ncx(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(book.Chapter),
    path: []const u8,
    ncx: []const u8,
    anchors: *const Anchors,
) !void {
    assert(out.items.len == 0);
    const dir = std.fs.path.dirnamePosix(path) orelse "";
    assert(dir.len <= path.len);
    var t = xml.Tokenizer{ .data = ncx };
    var depth: u8 = 0;
    var title: []const u8 = "";
    while (t.next()) |tok| switch (tok) {
        .open => |o| {
            if (std.mem.eql(u8, o.name, "navPoint")) depth +|= 1;
            if (std.mem.eql(u8, o.name, "text")) title = try text_of(alloc, &t, "text");
            if (std.mem.eql(u8, o.name, "content")) {
                const src = xml.attribute(o.attributes, "src") orelse continue;
                const found = try anchor_for(alloc, dir, src, anchors);
                const paragraph = found orelse continue;
                try out.append(alloc, .{ .title = title, .para = paragraph, .depth = depth -| 1 });
            }
        },
        .close => |name| if (std.mem.eql(u8, name, "navPoint")) {
            depth -|= 1;
        },
        .text => {},
    };
}

/// The paragraph an href in the contents goes to: its "file#id", else its file's start.
fn anchor_for(
    alloc: std.mem.Allocator,
    dir: []const u8,
    href: []const u8,
    anchors: *const Anchors,
) !?u32 {
    assert(anchors.count() > 0);
    const file = try resolve(alloc, dir, href);
    if (std.mem.indexOfScalar(u8, href, '#')) |hash| {
        const key = try std.fmt.allocPrint(alloc, "{s}{s}", .{ file, href[hash..] });
        assert(key.len > file.len);
        if (anchors.get(key)) |paragraph| return paragraph;
    }
    return anchors.get(file);
}

/// Reads a whole EPUB. Everything is allocated from `alloc`, an arena that lives as
/// long as the book is open; the paragraphs point into it.
pub fn parse(alloc: std.mem.Allocator, data: []const u8) !book.Book {
    const files = try zip.entries(alloc, data);
    const p = try read_package(alloc, files);
    var b = Builder{ .alloc = alloc, .files = files };
    for (p.spine, 0..) |id, index| {
        const item = p.item(id) orelse continue;
        if (std.mem.indexOf(u8, item.media, "html") == null) continue;
        const path = try resolve(alloc, p.dir, item.href);
        const xhtml = read_file(alloc, files, path) catch continue;
        b.section = @intCast(index + 1);
        try b.chapter(path, xhtml);
    }
    if (b.paragraphs.items.len == 0) return error.EmptyBook;
    parse_positions(b.paragraphs.items);
    try b.resolve_links();
    notes.mark_notes(b.paragraphs.items);
    const chapters = try read_contents(alloc, files, &p, &b.anchors);
    for (chapters) |c| assert(c.para < b.paragraphs.items.len);
    return .{
        .paragraphs = b.paragraphs.items,
        .chapters = chapters,
        .sections = @intCast(p.spine.len),
        .missing_refs = 0,
    };
}

/// Character positions, numbered the way Kindle books are, so highlights and
/// bookmarks work the same way in both. Never 0: that means "not numbered".
fn parse_positions(paragraphs: []book.Paragraph) void {
    assert(paragraphs.len > 0);
    var position: u32 = 1;
    for (paragraphs) |*paragraph| {
        paragraph.position = position;
        position += book.char_offset(paragraph.text, @intCast(paragraph.text.len)) + 1;
    }
    assert(paragraphs[0].position == 1);
    assert(paragraphs[paragraphs.len - 1].position < position);
}

const sample = @embedFile("testdata/sample.epub");

test "a small EPUB reads into paragraphs, styles, links and contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const about = try info(alloc, sample, true);
    try std.testing.expectEqualStrings("A Test Book", about.title);
    try std.testing.expectEqualStrings("Ann Author", about.author);
    const b = try parse(alloc, sample);
    try std.testing.expectEqualStrings("Chapter One", b.paragraphs[0].text);
    try std.testing.expect(b.paragraphs[0].look.bold);
    try std.testing.expect(b.paragraphs[0].look.size == 4);
    const body = b.paragraphs[1];
    try std.testing.expectEqualStrings("Some bold and italic text, with a note.1", body.text);
    try std.testing.expectEqual(@as(usize, 2), body.runs.len);
    try std.testing.expect(body.runs[0].bold and !body.runs[0].italic);
    try std.testing.expectEqualStrings("bold", body.text[body.runs[0].start..body.runs[0].end]);
    try std.testing.expect(body.runs[1].italic);
    try std.testing.expectEqual(@as(usize, 1), body.links.len);
    try std.testing.expectEqual(@as(usize, 2), b.chapters.len);
    try std.testing.expectEqualStrings("Two", b.chapters[1].title);
    try std.testing.expect(b.paragraphs[b.chapters[1].para].section == 2);
    const last = b.paragraphs[b.paragraphs.len - 1];
    try std.testing.expectEqualStrings("Caf\u{e9} \u{2014} done", last.text);
    try std.testing.expectEqual(@as(u32, 1), b.paragraphs[0].position);
    try std.testing.expect(b.paragraphs[1].position > b.paragraphs[0].position);
}

test "a heading's text after a picture and a line break stays a heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = Builder{ .alloc = arena.allocator(), .files = &.{} };
    try b.chapter(
        "c.xhtml",
        "<html><body><h2><img src=\"x.jpg\"/><br/><br/>Chapter I.</h2>" ++
            "<p>It is a truth.</p></body></html>",
    );
    try b.flush();
    try std.testing.expectEqualStrings("Chapter I.", b.paragraphs.items[0].text);
    try std.testing.expect(b.paragraphs.items[0].look.size != book.normal_size);
    try std.testing.expectEqual(book.normal_size, b.paragraphs.items[1].look.size);
}

test "a note reference ending in a space at a paragraph's end stays inside it" {
    const endings = [_][]const u8{
        "<a href=\"#fn1\">\n  1\n</a></p>",
        "<a href=\"#fn1\">1 </a></p>",
        "<a href=\"#fn1\">1 </a><br/>",
    };
    for (endings) |ending| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var b = Builder{ .alloc = alloc, .files = &.{} };
        const html = try std.fmt.allocPrint(alloc, "<html><body><p>Some text, with a note." ++
            "{s}<p id=\"fn1\">1 The note.</p></body></html>", .{ending});
        try b.chapter("c.xhtml", html);
        try b.flush();
        try b.resolve_links();
        notes.mark_notes(b.paragraphs.items);
        const body = b.paragraphs.items[0];
        try std.testing.expectEqual(@as(usize, 1), body.links.len);
        try std.testing.expect(body.links[0].end <= body.text.len);
        const mark = body.text[body.links[0].start..body.links[0].end];
        try std.testing.expectEqualStrings("1", std.mem.trim(u8, mark, " "));
        try std.testing.expect(b.paragraphs.items[b.paragraphs.items.len - 1].note);
    }
}

test "a series place that isn't a number in range counts as none" {
    const places = [_]struct { []const u8, f32 }{
        .{ "2", 2 },     .{ "1.5", 1.5 }, .{ "nan", 0 }, .{ "NaN", 0 },
        .{ "inf", 0 },   .{ "-inf", 0 },  .{ "-3", 0 },  .{ "word", 0 },
        .{ "99999", 0 }, .{ "", 0 },
    };
    for (places) |place| {
        var p = Package{ .dir = "", .items = &.{}, .spine = &.{} };
        const attributes = try std.fmt.allocPrint(
            std.testing.allocator,
            "name=\"calibre:series_index\" content=\"{s}\"",
            .{place[0]},
        );
        defer std.testing.allocator.free(attributes);
        const meta = xml.Tag{ .name = "meta", .attributes = attributes, .self_closing = true };
        read_package_meta(&p, &meta);
        try std.testing.expectEqual(place[1], p.series_index);
    }
}

test "an empty link goes nowhere, and doesn't stop the reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = Builder{ .alloc = arena.allocator(), .files = &.{} };
    try b.chapter("c.xhtml", "<html><body><p><a href=\"\">here</a></p></body></html>");
    try std.testing.expectEqual(@as(usize, 0), b.links.items.len);
    try std.testing.expectEqualStrings("here", b.paragraphs.items[0].text);
}

test "headings h1 to h6 each have a look, and other tags none" {
    try std.testing.expectEqual(@as(u8, 4), heading_look("h1").?.size);
    try std.testing.expectEqual(heading_look("h4").?, heading_look("h6").?);
    try std.testing.expect(heading_look("h7") == null);
    try std.testing.expect(heading_look("hr") == null);
    try std.testing.expect(is_block("h5"));
    try std.testing.expect(!is_block("b"));
}

test "hrefs resolve against their folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const picture_path = try resolve(alloc, "OEBPS/text", "../images/a%20b.jpg#x");
    try std.testing.expectEqualStrings("OEBPS/images/a b.jpg", picture_path);
    try std.testing.expectEqualStrings("c.xhtml", try resolve(alloc, "", "./c.xhtml"));
}

test "broken EPUBs are refused, never crash" {
    var prng = std.Random.DefaultPrng.init(0x65707562);
    const random = prng.random();
    var buf: [4096]u8 = undefined;
    for (0..1500) |round| {
        const len = @min(sample.len, buf.len);
        @memcpy(buf[0..len], sample[0..len]);
        for (0..1 + round % 8) |_| buf[random.uintLessThan(usize, len)] = random.int(u8);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        _ = parse(arena.allocator(), buf[0..len]) catch {};
        _ = info(arena.allocator(), buf[0..len], true) catch {};
    }
}
