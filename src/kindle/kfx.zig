//! Amazon's KFX book format: the container, its entities, and the parser that turns
//! one into a model.Book.
const std = @import("std");
const ion = @import("ion.zig");
const book = @import("../model/book.zig");
const notes = @import("../model/notes.zig");

const f_name = 4;

const f_style_events = 142;

const f_event_offset = 143;

const f_event_length = 144;

const f_id = 155;

const f_link = 179;

const f_anchor_position = 183;

const f_section_item = 141;

const f_content_ref = 145;

const f_children = 146;

const f_style = 157;

const f_reading_orders = 169;

const f_sections = 170;

const f_story = 176;

const f_index = 403;

const f_compression = 410;

const f_drm = 411;

const f_index_offset = 413;

const f_index_length = 414;

const t_content = 145;

const t_anchor = 266;

const t_story = 259;

const t_section = 260;

const t_document = 538;

const t_book_nav = 258;

const RawLink = struct { para: u32, start: usize, end: usize, anchor: u32 };

const Key = struct { id: u32, kind: u32 };

const MapRow = struct { delta: u32, element: ?u32 };

fn read_map_row(row: ion.Value) ?MapRow {
    if (row.unsigned()) |delta| return .{ .delta = @intCast(delta), .element = null };
    var fields = row.items();
    const delta = (fields.next() orelse return null).unsigned() orelse return null;
    const element = (fields.next() orelse return null).unsigned() orelse return null;
    return .{ .delta = @intCast(delta), .element = @intCast(element) };
}

/// A section's position map is delta encoded. Each row moves the position on, and
/// names its element, or a bare number means the element after the previous one.
const MapWalker = struct {
    position: u32,
    element: u32 = 0,

    const At = struct { position: u32, element: u32 };

    fn next(w: *MapWalker, row: MapRow) At {
        w.position += row.delta;
        w.element = row.element orelse w.element + 1;
        return .{ .position = w.position, .element = w.element };
    }
};

const Parser = struct {
    alloc: std.mem.Allocator,
    index: std.AutoHashMapUnmanaged(Key, []const u8) = .empty,
    paragraphs: std.ArrayList(book.Paragraph) = .empty,
    missing: u32 = 0,
    positions: std.AutoHashMapUnmanaged(u64, u32) = .empty, // Element ID to paragraph
    raw_links: std.ArrayList(RawLink) = .empty,
    section: u32 = 0,
    looks: std.AutoHashMapUnmanaged(u32, book.Look) = .empty, // Style name to how it sets text
    images: std.AutoHashMapUnmanaged(u32, book.Image) = .empty, // Resource name to picture

    /// Pairs each image resource with its bytes. Converted books list both in the
    /// same order, so the n-th resource is the n-th piece of raw media.
    fn read_images(p: *Parser) !void {
        var resources: std.ArrayList(u32) = .empty;
        var media: std.ArrayList(u32) = .empty;
        var it = p.index.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.kind == t_resource) try resources.append(p.alloc, kv.key_ptr.id);
            if (kv.key_ptr.kind == t_raw_media) try media.append(p.alloc, kv.key_ptr.id);
        }
        if (resources.items.len != media.items.len) return; // Can't pair them safely
        std.mem.sort(u32, resources.items, {}, std.sort.asc(u32));
        std.mem.sort(u32, media.items, {}, std.sort.asc(u32));
        for (resources.items, media.items) |r, m| {
            const res = p.entity(r, t_resource) orelse continue;
            const width = (res.get(f_width) orelse continue).unsigned() orelse continue;
            const height = (res.get(f_height) orelse continue).unsigned() orelse continue;
            const raw = p.index.get(.{ .id = m, .kind = t_raw_media }) orelse continue;
            if (raw.len < 10 or !std.mem.eql(u8, raw[0..4], "ENTY")) continue;
            const hdr = std.mem.readInt(u32, raw[6..10], .little);
            if (hdr >= raw.len or width == 0 or height == 0) continue;
            try p.images.put(p.alloc, r, .{ .data = raw[hdr..], .width = @intCast(width), .height = @intCast(height) });
        }
    }

    /// Reads every style once, keeping what changes how text looks.
    fn read_looks(p: *Parser) !void {
        var it = p.index.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.kind != t_style) continue;
            const v = p.entity(kv.key_ptr.id, t_style) orelse continue;
            try p.looks.put(p.alloc, kv.key_ptr.id, look_of(v));
        }
    }

    fn look_for(p: *const Parser, style: u32) book.Look {
        return p.looks.get(style) orelse .{};
    }

    /// Fills in each paragraph's position: section start plus offset in section.
    fn resolve_positions(p: *Parser) !void {
        var starts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var kinds = p.index.keyIterator();
        while (kinds.next()) |key| {
            if (key.kind != t_section_positions) continue;
            const table = p.entity(key.id, key.kind) orelse continue;
            var rows = (table.get(f_position_rows) orelse continue).items();
            while (rows.next()) |row| {
                const section = (row.get(f_section_name) orelse continue).symbol() orelse continue;
                const start = (row.get(f_section_start) orelse continue).unsigned() orelse continue;
                const map = p.entity(section, t_section_map) orelse continue;
                var walker = MapWalker{ .position = @intCast(start) };
                var rows_in_map = (map.get(f_position_rows) orelse continue).items();
                while (rows_in_map.next()) |row_in_map| {
                    const step = read_map_row(row_in_map) orelse continue;
                    const at = walker.next(step);
                    if (at.element == 0) continue;
                    const slot = try starts.getOrPut(p.alloc, at.element);
                    if (!slot.found_existing) slot.value_ptr.* = at.position;
                }
            }
        }
        for (p.paragraphs.items) |*para| {
            para.position = starts.get(para.element) orelse 0;
        }
    }

    fn collect_links(p: *Parser, item: ion.Value, para: u32, text: []const u8) !void {
        const events = item.get(f_style_events) orelse return;
        var runs: std.ArrayList(book.Run) = .empty;
        defer p.paragraphs.items[para].runs = runs.items;
        var it = events.items();
        while (it.next()) |event| {
            // Bold or italic over a stretch of the paragraph.
            if (event.get(f_style)) |s| {
                const look = p.look_for(s.symbol() orelse 0);
                const offset = (event.get(f_event_offset) orelse continue).unsigned() orelse continue;
                const length = (event.get(f_event_length) orelse continue).unsigned() orelse continue;
                if (look.bold or look.italic) try runs.append(p.alloc, .{
                    .start = @intCast(book.byte_offset(text, offset)),
                    .end = @intCast(book.byte_offset(text, offset + length)),
                    .bold = look.bold,
                    .italic = look.italic,
                });
            }
            const anchor = (event.get(f_link) orelse continue).symbol() orelse continue;
            const offset = (event.get(f_event_offset) orelse continue).unsigned() orelse continue;
            const length = (event.get(f_event_length) orelse continue).unsigned() orelse continue;
            try p.raw_links.append(p.alloc, .{
                .para = para,
                .start = book.byte_offset(text, offset),
                .end = book.byte_offset(text, offset + length),
                .anchor = anchor,
            });
        }
    }

    /// Turns anchors into paragraph indexes, now that every position is known.
    fn resolve_links(p: *Parser) !void {
        var i: usize = 0;
        while (i < p.raw_links.items.len) {
            const para = p.raw_links.items[i].para;
            var links: std.ArrayList(book.Link) = .empty;
            while (i < p.raw_links.items.len and p.raw_links.items[i].para == para) : (i += 1) {
                const raw = p.raw_links.items[i];
                const anchor = p.entity(raw.anchor, t_anchor) orelse continue;
                const position = anchor.get(f_anchor_position) orelse continue;
                const id = (position.get(f_id) orelse continue).unsigned() orelse continue;
                const target = p.positions.get(id) orelse continue;
                try links.append(p.alloc, .{ .start = raw.start, .end = raw.end, .target = target });
            }
            p.paragraphs.items[para].links = try links.toOwnedSlice(p.alloc);
        }
    }

    /// The book's table of contents, from its navigation. Entries whose target
    /// isn't in the text are skipped.
    fn read_contents(p: *Parser) ![]book.Chapter {
        var out: std.ArrayList(book.Chapter) = .empty;
        var it = p.index.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.kind != t_navigation) continue;
            const nav = p.entity(kv.key_ptr.id, kv.key_ptr.kind) orelse continue;
            var orders = nav.items();
            while (orders.next()) |order| {
                var containers = (order.get(f_nav_containers) orelse continue).items();
                while (containers.next()) |ref| {
                    // Containers are listed by name, or written inline.
                    const container = if (ref.symbol()) |id| p.entity(id, t_nav_container) else if (ref.kind == .struct_) ref else null;
                    const c = container orelse continue;
                    if ((c.get(f_nav_type) orelse continue).symbol() != nav_contents) continue;
                    try p.add_chapters(&out, c, 0);
                }
            }
            break;
        }
        return out.toOwnedSlice(p.alloc);
    }

    fn add_chapters(p: *Parser, out: *std.ArrayList(book.Chapter), parent: ion.Value, depth: u8) !void {
        if (depth > 8) return;
        var entries = (parent.get(f_nav_entries) orelse return).items();
        while (entries.next()) |entry| {
            const title = blk: {
                const shown = entry.get(f_nav_label) orelse break :blk null;
                break :blk (shown.get(f_nav_text) orelse break :blk null).text();
            };
            const target = entry.get(f_nav_target);
            const element = if (target) |t| t.get(f_id) else null;
            const para = if (element) |e| p.positions.get(e.int) else null;
            if (title != null and para != null and para.? < p.paragraphs.items.len) {
                try out.append(p.alloc, .{ .title = title.?, .para = para.?, .depth = depth });
            }
            try p.add_chapters(out, entry, depth + 1);
        }
    }

    fn entity(p: *Parser, id: u32, kind: u32) ?ion.Value {
        return entity_value(p.index.get(.{ .id = id, .kind = kind }) orelse return null);
    }

    /// Resolves a text reference. False means it pointed at nothing usable.
    fn add_content(p: *Parser, ref: ion.Value, style: u32) !bool {
        if (ref.text()) |txt| {
            try p.paragraphs.append(p.alloc, .{ .text = txt, .style = style, .look = p.look_for(style) });
            return true;
        }
        const name = (ref.get(f_name) orelse return false).symbol() orelse return false;
        const wanted = (ref.get(f_index) orelse return false).unsigned() orelse return false;
        const content = p.entity(name, t_content) orelse return false;
        var strings = (content.get(f_children) orelse return false).items();
        var i: u64 = 0;
        while (strings.next()) |s| : (i += 1) {
            if (i != wanted) continue;
            const txt = s.text() orelse return false;
            try p.paragraphs.append(p.alloc, .{ .text = txt, .style = style, .look = p.look_for(style) });
            return true;
        }
        return false;
    }

    fn walk(p: *Parser, item: ion.Value, depth: u32) anyerror!void {
        if (depth > 32) return error.TooDeep;
        if (item.text()) |txt| {
            try p.paragraphs.append(p.alloc, .{ .text = txt, .style = 0 });
            return;
        }
        if (item.kind != .struct_) {
            p.missing += 1;
            return;
        }
        const style = if (item.get(f_style)) |s| s.symbol() orelse 0 else 0;
        if (item.get(f_id)) |id| {
            const slot = try p.positions.getOrPut(p.alloc, id.int);
            if (!slot.found_existing) slot.value_ptr.* = @intCast(p.paragraphs.items.len);
        }

        if ((if (item.get(f_type)) |t| t.symbol() else null) == type_image) {
            const resource = if (item.get(f_resource)) |r| r.symbol() else null;
            if (resource) |r| {
                if (p.images.get(r)) |img| try p.paragraphs.append(p.alloc, .{ .text = "", .style = style, .look = p.look_for(style), .image = img, .section = p.section });
            }
        }
        if (item.get(f_content_ref)) |ref| {
            if (try p.add_content(ref, style)) {
                const para: u32 = @intCast(p.paragraphs.items.len - 1);
                p.paragraphs.items[para].section = p.section;
                if (item.get(f_id)) |id| p.paragraphs.items[para].element = @intCast(id.int);
                try p.collect_links(item, para, p.paragraphs.items[para].text);
            } else p.missing += 1;
        }
        if (item.get(f_story)) |story| {
            // A story names itself in this same field, so only descend into its children.
            const loaded = if (story.symbol()) |id| p.entity(id, t_story) else null;
            if (loaded) |s| {
                if (s.get(f_children)) |children| {
                    var it = children.items();
                    while (it.next()) |child| try p.walk(child, depth + 1);
                }
            } else p.missing += 1;
        }
        if (item.get(f_children)) |children| {
            var it = children.items();
            while (it.next()) |child| try p.walk(child, depth + 1);
        }
    }
};

const t_raw_media = 417;

const t_style = 157;

const t_resource = 164;

const f_type = 159;

const type_image = 271;

const f_resource = 175;

const f_width = 422;

const f_height = 423;

const f_font_style = 12;

const f_font_weight = 13;

const f_font_size = 16;

const f_text_align = 34;

const f_margin_top = 47;

const f_margin_bottom = 49;

const f_amount = 307;

const f_unit = 306;

const unit_rem = 505;

const unit_lines = 310;

const style_italic = 382;

const weight_bold = 361;

const weight_semibold = 362;

const align_center = 320;

const align_justify = 321;

const align_left = 59;

const align_right = 61;

fn amount(v: ion.Value, unit: u32) ?f64 {
    if ((v.get(f_unit) orelse return null).symbol() != unit) return null;
    return (v.get(f_amount) orelse return null).number();
}

fn tenths(lines: f64) u8 {
    return @intFromFloat(std.math.clamp(lines * 10, 0, 30));
}

/// How a style sets text, from the fields that matter on a reader's page.
fn look_of(v: ion.Value) book.Look {
    var look = book.Look{};
    if (v.get(f_font_style)) |s| look.italic = s.symbol() == style_italic;
    if (v.get(f_font_weight)) |w| look.bold = w.symbol() == weight_bold or w.symbol() == weight_semibold;
    if (v.get(f_font_size)) |s| {
        if (amount(s, unit_rem)) |rem| look.size = book.size_class(rem);
    }
    if (v.get(f_text_align)) |a| look.alignment = switch (a.symbol() orelse 0) {
        align_center => .center,
        align_justify => .justify,
        align_left => .left,
        align_right => .right,
        else => .auto,
    };
    if (v.get(f_margin_top)) |m| look.space_before = tenths(amount(m, unit_lines) orelse 0);
    if (v.get(f_margin_bottom)) |m| look.space_after = tenths(amount(m, unit_lines) orelse 0);
    return look;
}

const t_navigation = 389;

const t_nav_container = 391;

const f_nav_containers = 392;

const f_nav_type = 235;

const nav_contents = 212;

const f_nav_entries = 247;

const f_nav_label = 241;

const f_nav_text = 244;

const f_nav_target = 246;

const t_section_positions = 265;

const t_section_map = 609;

const f_position_rows = 181;

const f_section_name = 174;

const f_section_start = 184;

/// A KFX container: its header info, the entity index (24-byte rows), and the
/// body the index points into.
const Container = struct { info: ion.Value, index: []const u8, body: []const u8 };

fn open_container(data: []const u8) !Container {
    if (data.len < 18 or !std.mem.eql(u8, data[0..4], "CONT")) return error.NotKfx;
    const header_len = std.mem.readInt(u32, data[6..10], .little);
    const info_off = std.mem.readInt(u32, data[10..14], .little);
    const info_len = std.mem.readInt(u32, data[14..18], .little);
    if (info_off > data.len or info_len > data.len - info_off or header_len > data.len) return error.Truncated;
    const info = try ion.parse(data[info_off..][0..info_len]);
    const idx_off = (info.get(f_index_offset) orelse return error.BadHeader).int;
    const idx_len = (info.get(f_index_length) orelse return error.BadHeader).int;
    if (idx_off > data.len or idx_len > data.len - idx_off) return error.Truncated;
    return .{ .info = info, .index = data[@intCast(idx_off)..][0..@intCast(idx_len)], .body = data[header_len..] };
}

/// An index row: entity id, type, and where its bytes sit in the body.
const Row = struct { id: u32, kind: u32, off: u64, len: u64 };

fn read_row(row: *const [24]u8) Row {
    return .{
        .id = std.mem.readInt(u32, row[0..4], .little),
        .kind = std.mem.readInt(u32, row[4..8], .little),
        .off = std.mem.readInt(u64, row[8..16], .little),
        .len = std.mem.readInt(u64, row[16..24], .little),
    };
}

/// An entity's value, past its "ENTY" header.
pub fn entity_value(raw: []const u8) ?ion.Value {
    if (raw.len < 10 or !std.mem.eql(u8, raw[0..4], "ENTY")) return null;
    const hdr = std.mem.readInt(u32, raw[6..10], .little);
    if (hdr > raw.len) return null;
    return ion.parse(raw[hdr..]) catch null;
}

pub const Entity = struct { id: u32, kind: u32, raw: []const u8 };

/// Walks every entity in the book, skipping any that point outside the file.
pub const Entities = struct {
    c: Container,
    at: usize = 0,

    pub fn next(it: *Entities) ?Entity {
        while (it.at + 24 <= it.c.index.len) {
            const r = read_row(it.c.index[it.at..][0..24]);
            it.at += 24;
            if (r.off > it.c.body.len or r.len > it.c.body.len - r.off) continue;
            return .{ .id = r.id, .kind = r.kind, .raw = it.c.body[@intCast(r.off)..][0..@intCast(r.len)] };
        }
        return null;
    }
};

pub fn entities(data: []const u8) !Entities {
    return .{ .c = try open_container(data) };
}

/// True when every entity the index lists is inside the file. A download still in
/// progress fails this, and checking it is far cheaper than parsing the book.
pub fn is_complete(data: []const u8) bool {
    const c = open_container(data) catch return false;
    if (c.index.len < 24) return false;
    var at: usize = 0;
    while (at + 24 <= c.index.len) : (at += 24) {
        const r = read_row(c.index[at..][0..24]);
        if (r.off > c.body.len or r.len > c.body.len - r.off) return false;
    }
    return true;
}

/// The book's first embedded JPEG, which is its cover in converted books.
pub fn cover_image(data: []const u8) ?[]const u8 {
    const c = open_container(data) catch return null;
    const body = c.body;
    var at: usize = 0;
    while (at + 24 <= c.index.len) : (at += 24) {
        const row = c.index[at..][0..24];
        if (std.mem.readInt(u32, row[4..8], .little) != t_raw_media) continue;
        const off = std.mem.readInt(u64, row[8..16], .little);
        const len = std.mem.readInt(u64, row[16..24], .little);
        if (off > body.len or len > body.len - off or len < 10) continue;
        const raw = body[@intCast(off)..][0..@intCast(len)];
        const hdr = std.mem.readInt(u32, raw[6..10], .little);
        if (hdr >= raw.len) continue;
        const media = raw[hdr..];
        if (media.len > 2 and media[0] == 0xff and media[1] == 0xd8) return media;
    }
    return null;
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) !book.Book {
    const c = try open_container(data);
    if ((c.info.get(f_compression) orelse return error.BadHeader).int != 0) return error.Compressed;
    if ((c.info.get(f_drm) orelse return error.BadHeader).int != 0) return error.Encrypted;

    var p = Parser{ .alloc = alloc };
    var at: usize = 0;
    while (at + 24 <= c.index.len) : (at += 24) {
        const r = read_row(c.index[at..][0..24]);
        if (r.off > c.body.len or r.len > c.body.len - r.off) return error.Truncated;
        try p.index.put(alloc, .{ .id = r.id, .kind = r.kind }, c.body[@intCast(r.off)..][0..@intCast(r.len)]);
    }
    try p.read_looks();
    try p.read_images();

    const doc = find_document(&p) orelse return error.NoReadingOrder;
    var orders = (doc.get(f_reading_orders) orelse return error.NoReadingOrder).items();
    const order = orders.next() orelse return error.NoReadingOrder;
    var sections = (order.get(f_sections) orelse return error.NoReadingOrder).items();

    var count: u32 = 0;
    while (sections.next()) |s| {
        const section = p.entity(s.symbol() orelse continue, t_section) orelse {
            p.missing += 1;
            continue;
        };
        count += 1;
        p.section = count;
        var templates = (section.get(f_section_item) orelse continue).items();
        // Later templates are conditional alternatives of the first.
        if (templates.next()) |first| try p.walk(first, 0);
    }
    try p.resolve_links();
    try p.resolve_positions();
    notes.mark_notes(p.paragraphs.items);
    const chapters = try p.read_contents();
    return .{ .paragraphs = try p.paragraphs.toOwnedSlice(alloc), .chapters = chapters, .sections = count, .missing_refs = p.missing };
}

fn find_document(p: *Parser) ?ion.Value {
    var it = p.index.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.kind != t_document and kv.key_ptr.kind != t_book_nav) continue;
        if (p.entity(kv.key_ptr.id, kv.key_ptr.kind)) |v| {
            if (v.get(f_reading_orders) != null) return v;
        }
    }
    return null;
}

test "offsets that would wrap are rejected" {
    var d = std.mem.zeroes([18]u8);
    @memcpy(d[0..4], "CONT");
    std.mem.writeInt(u32, d[10..14], 0xFFFFFFF0, .little);
    std.mem.writeInt(u32, d[14..18], 0x20, .little);
    try std.testing.expectError(error.Truncated, parse(std.testing.allocator, &d));
}

test "cover lookup refuses files that aren't books" {
    try std.testing.expect(cover_image("short") == null);
    var d = std.mem.zeroes([18]u8);
    @memcpy(d[0..4], "CONT");
    std.mem.writeInt(u32, d[10..14], 0xFFFFFFF0, .little);
    try std.testing.expect(cover_image(&d) == null);
}

test "position map finds element 80 where the Kindle stored it" {
    // Section 870 of a real book. Kindle records this element at 377338.
    const rows = [_]MapRow{
        .{ .delta = 0, .element = 120 },
        .{ .delta = 1, .element = 74 },
        .{ .delta = 4077, .element = null },
        .{ .delta = 5554, .element = null },
        .{ .delta = 3395, .element = null },
        .{ .delta = 6967, .element = null },
        .{ .delta = 6453, .element = null },
        .{ .delta = 3892, .element = null },
    };
    var walker = MapWalker{ .position = 346999 };
    var last: MapWalker.At = undefined;
    for (rows) |r| last = walker.next(r);
    try std.testing.expectEqual(@as(u32, 80), last.element);
    try std.testing.expectEqual(@as(u32, 377338), last.position);
}

test "a book cut short is not complete" {
    var d = std.mem.zeroes([32]u8);
    try std.testing.expect(!is_complete(&d));
    @memcpy(d[0..4], "CONT");
    std.mem.writeInt(u32, d[6..10], 40, .little); // Header longer than the file
    try std.testing.expect(!is_complete(&d));
}

test "random and broken books are refused, never crash" {
    var prng = std.Random.DefaultPrng.init(0x6b6678);
    const random = prng.random();
    var buf: [2048]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..5_000) |_| {
        const len = random.uintLessThan(usize, buf.len);
        random.bytes(buf[0..len]);
        // Most rounds look like a container, with offsets that point somewhere inside it.
        if (len >= 18 and random.boolean()) {
            @memcpy(buf[0..4], "CONT");
            std.mem.writeInt(u32, buf[6..10], random.uintLessThan(u32, @intCast(len + 8)), .little);
            std.mem.writeInt(u32, buf[10..14], random.uintLessThan(u32, @intCast(len + 8)), .little);
            std.mem.writeInt(u32, buf[14..18], random.uintLessThan(u32, @intCast(len + 8)), .little);
        }
        const data = buf[0..len];
        _ = is_complete(data);
        _ = cover_image(data);
        if (entities(data)) |it| {
            var all = it;
            while (all.next()) |e| _ = entity_value(e.raw);
        } else |_| {}
        _ = parse(arena.allocator(), data) catch {};
        _ = arena.reset(.retain_capacity);
    }
}
