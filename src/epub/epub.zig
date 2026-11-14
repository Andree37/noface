//! EPUB books, read into the same model.Book as Kindle books: paragraphs with their
//! look, bold and italic runs, pictures, links between them, and the contents.
//! Only what a reader needs from the markup is kept; CSS is not read, so headings
//! and emphasis come from the tags themselves.
const std = @import("std");
const book = @import("../model/book.zig");
const notes = @import("../model/notes.zig");
const zip = @import("zip.zig");
const xml = @import("xml.zig");
const picture = @import("picture.zig");

/// What the library shows, read without opening the whole book.
pub const Info = struct { title: []const u8, author: []const u8, cover: ?[]const u8 = null, series: []const u8 = "", series_index: f32 = 0 };

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

    const Item = struct { id: []const u8, href: []const u8, media: []const u8, properties: []const u8 };

    fn item(p: Package, id: []const u8) ?Item {
        for (p.items) |i| {
            if (std.mem.eql(u8, i.id, id)) return i;
        }
        return null;
    }
};

fn read_file(alloc: std.mem.Allocator, files: []const zip.Entry, name: []const u8) ![]u8 {
    const e = zip.find(files, name) orelse return error.MissingFile;
    return zip.read(alloc, e);
}

/// Joins a relative href onto a folder, resolving "..", and drops any "#fragment".
fn resolve(alloc: std.mem.Allocator, dir: []const u8, href: []const u8) ![]const u8 {
    const plain = href[0 .. std.mem.indexOfScalar(u8, href, '#') orelse href.len];
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
    return std.mem.join(alloc, "/", parts.items);
}

/// "%20" and friends, as hrefs are URL-encoded.
fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(alloc, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(alloc, s[i]);
    }
    return out.items;
}

fn text_of(alloc: std.mem.Allocator, t: *xml.Tokenizer, closing: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    while (t.next()) |tok| switch (tok) {
        .text => |s| try xml.decode(&out, alloc, s),
        .close => |name| if (std.mem.eql(u8, name, closing)) break,
        .open => {},
    };
    return std.mem.trim(u8, out.items, " \t\r\n");
}

fn read_package(alloc: std.mem.Allocator, files: []const zip.Entry) !Package {
    const container = try read_file(alloc, files, "META-INF/container.xml");
    var path: ?[]const u8 = null;
    var t = xml.Tokenizer{ .data = container };
    while (t.next()) |tok| {
        if (tok == .open and std.mem.eql(u8, tok.open.name, "rootfile")) {
            path = xml.attr(tok.open.attrs, "full-path");
            break;
        }
    }
    const opf_path = path orelse return error.NoPackage;
    const opf = try read_file(alloc, files, opf_path);
    var p = Package{ .dir = std.fs.path.dirnamePosix(opf_path) orelse "", .items = &.{}, .spine = &.{} };
    var items: std.ArrayList(Package.Item) = .empty;
    var spine: std.ArrayList([]const u8) = .empty;
    t = .{ .data = opf };
    while (t.next()) |tok| {
        if (tok != .open) continue;
        const o = tok.open;
        if (std.mem.eql(u8, o.name, "title") and p.title.len == 0) p.title = try text_of(alloc, &t, "title");
        if (std.mem.eql(u8, o.name, "creator") and p.author.len == 0) p.author = try text_of(alloc, &t, "creator");
        if (std.mem.eql(u8, o.name, "item")) try items.append(alloc, .{
            .id = xml.attr(o.attrs, "id") orelse "",
            .href = xml.attr(o.attrs, "href") orelse "",
            .media = xml.attr(o.attrs, "media-type") orelse "",
            .properties = xml.attr(o.attrs, "properties") orelse "",
        });
        if (std.mem.eql(u8, o.name, "itemref")) {
            if (xml.attr(o.attrs, "idref")) |id| try spine.append(alloc, id);
        }
        if (std.mem.eql(u8, o.name, "spine")) p.toc_ncx = xml.attr(o.attrs, "toc");
        if (std.mem.eql(u8, o.name, "meta")) {
            const name = xml.attr(o.attrs, "name") orelse "";
            if (std.mem.eql(u8, name, "cover")) p.cover_id = xml.attr(o.attrs, "content");
            if (std.mem.eql(u8, name, "calibre:series")) p.series = xml.attr(o.attrs, "content") orelse "";
            if (std.mem.eql(u8, name, "calibre:series_index")) p.series_index = std.fmt.parseFloat(f32, xml.attr(o.attrs, "content") orelse "") catch 0;
        }
    }
    p.items = items.items;
    p.spine = spine.items;
    if (p.spine.len == 0) return error.NoSpine;
    return p;
}

/// Title, author and, if asked for, the cover, for the library.
pub fn info(alloc: std.mem.Allocator, data: []const u8, with_cover: bool) !Info {
    const files = try zip.entries(alloc, data);
    const p = try read_package(alloc, files);
    var cover: ?[]const u8 = null;
    if (with_cover) for (p.items) |i| {
        const is_cover = std.mem.indexOf(u8, i.properties, "cover-image") != null or (p.cover_id != null and std.mem.eql(u8, i.id, p.cover_id.?));
        if (!is_cover) continue;
        cover = read_file(alloc, files, try resolve(alloc, p.dir, i.href)) catch null;
        break;
    };
    return .{ .title = p.title, .author = p.author, .cover = cover, .series = p.series, .series_index = p.series_index };
}

/// Where a heading tag puts its text: bigger and bold, the largest centred.
fn heading_look(name: []const u8) ?book.Look {
    if (name.len != 2 or name[0] != 'h' or name[1] < '1' or name[1] > '6') return null;
    return switch (name[1]) {
        '1' => .{ .bold = true, .size = 4, .alignment = .center, .space_before = 10, .space_after = 6 },
        '2' => .{ .bold = true, .size = 3, .space_before = 8, .space_after = 4 },
        '3' => .{ .bold = true, .size = 2, .space_before = 6, .space_after = 3 },
        else => .{ .bold = true, .space_before = 4, .space_after = 2 },
    };
}

fn is_block(name: []const u8) bool {
    const blocks = [_][]const u8{ "p", "div", "li", "blockquote", "br", "tr", "dt", "dd", "section", "article", "aside", "figure", "figcaption", "hr", "pre", "table", "ul", "ol", "body" };
    for (blocks) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return heading_look(name) != null;
}

fn eql_any(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |l| {
        if (std.mem.eql(u8, name, l)) return true;
    }
    return false;
}

/// A link before its target is known: from where, to "file#id".
const PendingLink = struct { para: u32, start: usize, end: usize, target: []const u8 };

/// Builds paragraphs from one spine file's body.
const Builder = struct {
    alloc: std.mem.Allocator,
    files: []const zip.Entry,
    paragraphs: std.ArrayList(book.Paragraph) = .empty,
    anchors: std.StringHashMapUnmanaged(u32) = .empty, // "file#id" or "file" to paragraph
    inner_anchors: std.StringHashMapUnmanaged(void) = .empty, // "file#id" that fall partway into a paragraph
    links: std.ArrayList(PendingLink) = .empty,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(book.Run) = .empty,
    look: book.Look = .{},
    bold: u32 = 0, // How many bold tags are open
    italic: u32 = 0,
    run_start: ?usize = null, // Where the current bold or italic stretch began
    link_start: ?usize = null,
    link_target: []const u8 = "",
    section: u32 = 0,
    file: []const u8 = "",
    dir: []const u8 = "", // The chapter file's folder, for the paths it refers to
    in_body: bool = false,
    skipping: ?[]const u8 = null, // Inside <head>, <style> or <script>: no text
    waiting_ids: std.ArrayList([]const u8) = .empty, // Anchors for the next paragraph

    fn styled(b: *const Builder) bool {
        return b.bold > 0 or b.italic > 0;
    }

    /// Closes the bold or italic stretch running so far, before the style changes.
    fn end_run(b: *Builder) !void {
        const start = b.run_start orelse return;
        b.run_start = null;
        if (b.text.items.len > start) try b.runs.append(b.alloc, .{ .start = @intCast(start), .end = @intCast(b.text.items.len), .bold = b.bold > 0, .italic = b.italic > 0 });
    }

    fn start_run(b: *Builder) void {
        if (b.styled()) b.run_start = b.text.items.len;
    }

    fn add_text(b: *Builder, raw: []const u8) !void {
        var decoded: std.ArrayList(u8) = .empty;
        try xml.decode(&decoded, b.alloc, raw);
        // Whitespace in markup is layout, not text: runs of it become one space.
        for (decoded.items) |c| {
            const space = c == ' ' or c == '\n' or c == '\t' or c == '\r';
            if (space) {
                if (b.text.items.len == 0 or b.text.items[b.text.items.len - 1] == ' ') continue;
                try b.text.append(b.alloc, ' ');
            } else try b.text.append(b.alloc, c);
        }
    }

    /// Ends the paragraph being built, if it has any text.
    fn flush(b: *Builder) !void {
        try b.end_run();
        while (b.text.items.len > 0 and b.text.items[b.text.items.len - 1] == ' ') _ = b.text.pop();
        if (b.text.items.len > 0) {
            const index: u32 = @intCast(b.paragraphs.items.len);
            const text = try b.alloc.dupe(u8, b.text.items);
            try b.paragraphs.append(b.alloc, .{ .text = text, .style = 0, .look = b.look, .runs = try b.alloc.dupe(book.Run, b.runs.items), .section = b.section });
            try b.place_anchors(index);
        }
        b.text.clearRetainingCapacity();
        b.runs.clearRetainingCapacity();
        b.start_run();
    }

    fn place_anchors(b: *Builder, index: u32) !void {
        for (b.waiting_ids.items) |id| {
            const key = try std.fmt.allocPrint(b.alloc, "{s}#{s}", .{ b.file, id });
            const slot = try b.anchors.getOrPut(b.alloc, key);
            if (!slot.found_existing) slot.value_ptr.* = index;
        }
        b.waiting_ids.clearRetainingCapacity();
        const file_slot = try b.anchors.getOrPut(b.alloc, b.file);
        if (!file_slot.found_existing) file_slot.value_ptr.* = index;
    }

    fn add_picture(b: *Builder, dir: []const u8, src: []const u8) !void {
        const path = try resolve(b.alloc, dir, src);
        const entry = zip.find(b.files, path) orelse return;
        const data = zip.read(b.alloc, entry) catch return;
        const size = picture.size(data) orelse return; // Only JPEG and PNG can be drawn
        try b.flush();
        const index: u32 = @intCast(b.paragraphs.items.len);
        try b.paragraphs.append(b.alloc, .{ .text = "", .style = 0, .image = .{ .data = data, .width = size.width, .height = size.height }, .section = b.section });
        try b.place_anchors(index);
    }

    /// Adds one chapter's text: its paragraphs, with their styles, pictures, links and
    /// the anchors links can point to.
    fn chapter(b: *Builder, path: []const u8, xhtml: []const u8) !void {
        b.file = path;
        b.dir = std.fs.path.dirnamePosix(path) orelse "";
        b.in_body = false;
        b.skipping = null;
        var t = xml.Tokenizer{ .data = xhtml };
        while (t.next()) |tok| switch (tok) {
            .text => |text| if (b.in_body and b.skipping == null) try b.add_text(text),
            .open => |tag| try b.open_tag(tag),
            .close => |name| try b.close_tag(name),
        };
        try b.flush();
        b.bold = 0;
        b.italic = 0;
    }

    fn open_tag(b: *Builder, tag: xml.Tag) !void {
        if (b.skipping != null) return;
        if (std.mem.eql(u8, tag.name, "body")) b.in_body = true;
        if (!b.in_body) return;
        if (eql_any(tag.name, &.{ "style", "script", "head" }) and !tag.self_closing) {
            b.skipping = tag.name;
            return;
        }
        if (xml.attr(tag.attrs, "id")) |id| try b.note_anchor(id);
        if (is_block(tag.name)) try b.start_block(tag.name);
        if (eql_any(tag.name, &.{ "b", "strong" })) try b.nest_style(&b.bold, .in);
        if (eql_any(tag.name, &.{ "i", "em", "cite" })) try b.nest_style(&b.italic, .in);
        if (std.mem.eql(u8, tag.name, "a")) b.start_link(tag);
        if (eql_any(tag.name, &.{ "img", "image" })) {
            const src = xml.attr(tag.attrs, "src") orelse xml.attr(tag.attrs, "href") orelse return;
            try b.add_picture(b.dir, src);
        }
    }

    fn close_tag(b: *Builder, name: []const u8) !void {
        if (b.skipping) |skipped| {
            if (std.mem.eql(u8, skipped, name)) b.skipping = null;
            return;
        }
        if (eql_any(name, &.{ "b", "strong" })) try b.nest_style(&b.bold, .out);
        if (eql_any(name, &.{ "i", "em", "cite" })) try b.nest_style(&b.italic, .out);
        if (std.mem.eql(u8, name, "a")) try b.end_link();
        if (is_block(name)) {
            try b.flush();
            b.look = .{};
        }
    }

    /// An element with an id, which links can point to: kept for the paragraph about to
    /// start, and noted as partway in when text has already started.
    fn note_anchor(b: *Builder, id: []const u8) !void {
        if (b.text.items.len > 0) try b.inner_anchors.put(b.alloc, try std.fmt.allocPrint(b.alloc, "{s}#{s}", .{ b.file, id }), {});
        try b.waiting_ids.append(b.alloc, id);
    }

    /// A block begins a paragraph, in its heading's look if it is one. A line break
    /// stays in its block's look: "<h2><img/><br/>Chapter I.</h2>" is still a heading
    /// after the picture.
    fn start_block(b: *Builder, name: []const u8) !void {
        try b.flush();
        if (!std.mem.eql(u8, name, "br")) b.look = heading_look(name) orelse .{};
    }

    /// Bold or italic going in or out: the text so far ends its run, a new one starts.
    fn nest_style(b: *Builder, depth: *u32, way: enum { in, out }) !void {
        if (way == .out and depth.* == 0) return; // A stray closing tag
        try b.end_run();
        if (way == .in) depth.* += 1 else depth.* -= 1;
        b.start_run();
    }

    /// A link within the book (not to the web) starts here.
    fn start_link(b: *Builder, tag: xml.Tag) void {
        const href = xml.attr(tag.attrs, "href") orelse return;
        if (std.mem.indexOf(u8, href, "://") != null) return;
        b.link_start = b.text.items.len;
        b.link_target = href;
    }

    /// The link that started ends here, over the text since, its target resolved
    /// against this chapter: "#note1" or "notes.xhtml#note1".
    fn end_link(b: *Builder) !void {
        const start = b.link_start orelse return;
        b.link_start = null;
        if (b.text.items.len <= start) return;
        const href = b.link_target;
        const target = if (href[0] == '#')
            try std.fmt.allocPrint(b.alloc, "{s}{s}", .{ b.file, href })
        else
            try std.fmt.allocPrint(b.alloc, "{s}{s}", .{ try resolve(b.alloc, b.dir, href), href[std.mem.indexOfScalar(u8, href, '#') orelse href.len ..] });
        try b.links.append(b.alloc, .{ .para = @intCast(b.paragraphs.items.len), .start = start, .end = b.text.items.len, .target = target });
    }

    /// Ties each link to the paragraph its target landed in.
    fn resolve_links(b: *Builder) !void {
        var per_para = std.AutoHashMapUnmanaged(u32, std.ArrayList(book.Link)).empty;
        for (b.links.items) |l| {
            if (l.para >= b.paragraphs.items.len) continue;
            const target = b.anchors.get(l.target) orelse continue;
            const slot = try per_para.getOrPut(b.alloc, l.para);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(b.alloc, .{ .start = l.start, .end = l.end, .target = target, .inside = b.inner_anchors.contains(l.target) });
        }
        var it = per_para.iterator();
        while (it.next()) |kv| b.paragraphs.items[kv.key_ptr.*].links = kv.value_ptr.items;
    }
};

/// Contents from EPUB 3's nav document, or EPUB 2's NCX.
fn read_contents(alloc: std.mem.Allocator, files: []const zip.Entry, p: Package, anchors: anytype) ![]book.Chapter {
    var out: std.ArrayList(book.Chapter) = .empty;
    for (p.items) |i| {
        if (std.mem.indexOf(u8, i.properties, "nav") == null) continue;
        const path = try resolve(alloc, p.dir, i.href);
        const nav = read_file(alloc, files, path) catch break;
        const dir = std.fs.path.dirnamePosix(path) orelse "";
        var t = xml.Tokenizer{ .data = nav };
        var in_toc = false;
        var depth: u8 = 0;
        while (t.next()) |tok| switch (tok) {
            .open => |o| {
                if (std.mem.eql(u8, o.name, "nav")) in_toc = std.mem.indexOf(u8, xml.attr(o.attrs, "type") orelse "", "toc") != null;
                if (!in_toc) continue;
                if (std.mem.eql(u8, o.name, "ol")) depth +|= 1;
                if (std.mem.eql(u8, o.name, "a")) {
                    const href = xml.attr(o.attrs, "href") orelse continue;
                    const title = try text_of(alloc, &t, "a");
                    if (try anchor_for(alloc, dir, href, anchors)) |para| try out.append(alloc, .{ .title = title, .para = para, .depth = depth -| 1 });
                }
            },
            .close => |name| {
                if (std.mem.eql(u8, name, "ol")) depth -|= 1;
                if (std.mem.eql(u8, name, "nav")) in_toc = false;
            },
            .text => {},
        };
        if (out.items.len > 0) return out.items;
    }
    const ncx_id = p.toc_ncx orelse return out.items;
    const ncx_item = p.item(ncx_id) orelse return out.items;
    const path = try resolve(alloc, p.dir, ncx_item.href);
    const ncx = read_file(alloc, files, path) catch return out.items;
    const dir = std.fs.path.dirnamePosix(path) orelse "";
    var t = xml.Tokenizer{ .data = ncx };
    var depth: u8 = 0;
    var title: []const u8 = "";
    while (t.next()) |tok| switch (tok) {
        .open => |o| {
            if (std.mem.eql(u8, o.name, "navPoint")) depth +|= 1;
            if (std.mem.eql(u8, o.name, "text")) title = try text_of(alloc, &t, "text");
            if (std.mem.eql(u8, o.name, "content")) {
                const src = xml.attr(o.attrs, "src") orelse continue;
                if (try anchor_for(alloc, dir, src, anchors)) |para| try out.append(alloc, .{ .title = title, .para = para, .depth = depth -| 1 });
            }
        },
        .close => |name| if (std.mem.eql(u8, name, "navPoint")) {
            depth -|= 1;
        },
        .text => {},
    };
    return out.items;
}

fn anchor_for(alloc: std.mem.Allocator, dir: []const u8, href: []const u8, anchors: anytype) !?u32 {
    const file = try resolve(alloc, dir, href);
    if (std.mem.indexOfScalar(u8, href, '#')) |hash| {
        const key = try std.fmt.allocPrint(alloc, "{s}{s}", .{ file, href[hash..] });
        if (anchors.get(key)) |para| return para;
    }
    return anchors.get(file);
}

/// Reads a whole EPUB. Everything is allocated from `alloc`, an arena that lives as
/// long as the book is open; the paragraphs point into it.
pub fn parse(alloc: std.mem.Allocator, data: []const u8) !book.Book {
    const files = try zip.entries(alloc, data);
    const p = try read_package(alloc, files);
    var b = Builder{ .alloc = alloc, .files = files };
    for (p.spine, 0..) |id, i| {
        const item = p.item(id) orelse continue;
        if (std.mem.indexOf(u8, item.media, "html") == null) continue;
        const path = try resolve(alloc, p.dir, item.href);
        const xhtml = read_file(alloc, files, path) catch continue;
        b.section = @intCast(i + 1);
        try b.chapter(path, xhtml);
    }
    if (b.paragraphs.items.len == 0) return error.EmptyBook;
    // Character positions, numbered the way Kindle books are, so highlights and
    // bookmarks work the same way in both. Never 0: that means "not numbered".
    var position: u32 = 1;
    for (b.paragraphs.items) |*para| {
        para.position = position;
        position += book.char_offset(para.text, para.text.len) + 1;
    }
    try b.resolve_links();
    notes.mark_notes(b.paragraphs.items);
    const chapters = try read_contents(alloc, files, p, &b.anchors);
    return .{ .paragraphs = b.paragraphs.items, .chapters = chapters, .sections = @intCast(p.spine.len), .missing_refs = 0 };
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
    try std.testing.expect(b.paragraphs[0].look.bold and b.paragraphs[0].look.size == 4);
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
    try std.testing.expectEqualStrings("Caf\u{e9} \u{2014} done", b.paragraphs[b.paragraphs.len - 1].text);
    try std.testing.expectEqual(@as(u32, 1), b.paragraphs[0].position);
    try std.testing.expect(b.paragraphs[1].position > b.paragraphs[0].position);
}

test "a heading's text after a picture and a line break stays a heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = Builder{ .alloc = arena.allocator(), .files = &.{} };
    try b.chapter("c.xhtml", "<html><body><h2><img src=\"x.jpg\"/><br/><br/>Chapter I.</h2><p>It is a truth.</p></body></html>");
    try b.flush();
    try std.testing.expectEqualStrings("Chapter I.", b.paragraphs.items[0].text);
    try std.testing.expect(b.paragraphs.items[0].look.size != book.normal_size);
    try std.testing.expectEqual(book.normal_size, b.paragraphs.items[1].look.size);
}

test "hrefs resolve against their folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("OEBPS/images/a b.jpg", try resolve(alloc, "OEBPS/text", "../images/a%20b.jpg#x"));
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
