//! Amazon's KFX book format: the container, its entities, and the parser that turns
//! one into a model.Book.
//!
//! Every byte read here comes from a book file, so none of it is asserted: a broken
//! book is an error, a skipped part or a missing reference, never a crash. The
//! assertions state the parser's own invariants.
const std = @import("std");
const assert = std.debug.assert;
const ion = @import("ion.zig");
const book = @import("../model/book.zig");
const notes = @import("../model/notes.zig");

// Field symbols: the keys of the structs a book is made of.
const f_name = 4;
const f_font_style = 12;
const f_font_weight = 13;
const f_font_size = 16;
const f_text_align = 34;
const f_margin_top = 47;
const f_margin_bottom = 49;
const f_section_item = 141;
const f_style_events = 142;
const f_event_offset = 143;
const f_event_length = 144;
const f_content_ref = 145;
const f_children = 146;
const f_id = 155;
const f_style = 157;
const f_type = 159;
const f_reading_orders = 169;
const f_sections = 170;
const f_section_name = 174;
const f_resource = 175;
const f_story = 176;
const f_link = 179;
const f_position_rows = 181;
const f_anchor_position = 183;
const f_section_start = 184;
const f_nav_type = 235;
const f_nav_label = 241;
const f_nav_text = 244;
const f_nav_target = 246;
const f_nav_entries = 247;
const f_unit = 306;
const f_amount = 307;
const f_nav_containers = 392;
const f_index = 403;
const f_compression = 410;
const f_drm = 411;
const f_index_offset = 413;
const f_index_length = 414;
const f_width = 422;
const f_height = 423;

// Entity types: what each entity in the container's index is.
const t_content = 145;
const t_style = 157;
const t_resource = 164;
const t_book_nav = 258;
const t_story = 259;
const t_section = 260;
const t_section_positions = 265;
const t_anchor = 266;
const t_navigation = 389;
const t_nav_container = 391;
const t_raw_media = 417;
const t_document = 538;
const t_section_map = 609;

/// Every entity type the parser looks up.
const entity_types = [_]u32{
    t_content,           t_style,    t_resource,    t_book_nav,      t_story,
    t_section,           t_anchor,   t_navigation,  t_nav_container, t_raw_media,
    t_section_positions, t_document, t_section_map,
};

// Symbols used as values.
const nav_contents = 212;
const type_image = 271;
const unit_lines = 310;
const align_left = 59;
const align_right = 61;
const align_center = 320;
const align_justify = 321;
const weight_bold = 361;
const weight_semibold = 362;
const style_italic = 382;
const unit_rem = 505;

/// "CONT", a version, then the header's size, and the info's offset and size.
const container_header_size = 18;
/// "ENTY", a version, then the header's size.
const entity_header_size = 10;
/// An index row: entity id, type, and the offset and size of its bytes in the body.
const row_size = 24;

/// How deep the reading order may nest. Deeper is a broken book, or one whose stories
/// include themselves.
const walk_depth_max = 32;
/// An item leaves at most two lists to walk one level down (its story's children and
/// its own), and only the item being walked at each depth has lists left.
const walk_frames_max = 2 * (walk_depth_max + 1);
/// How deep the table of contents is read; deeper entries are left out.
const chapters_depth_max = 8;
/// The most space around a paragraph, in tenths of a line.
const tenths_max = 30;

comptime {
    assert(row_size == 4 + 4 + 8 + 8);
    assert(container_header_size == 4 + 2 + 4 + 4 + 4);
    assert(entity_header_size == 4 + 2 + 4);
    assert(walk_frames_max == 2 * (walk_depth_max + 1));
    assert(chapters_depth_max < std.math.maxInt(u8)); // Chapter.depth is a u8
    assert(tenths_max <= std.math.maxInt(u8)); // Look.space_before is a u8
    // Entities are keyed by id and type, so types must not share a symbol.
    for (entity_types, 0..) |a, i| {
        for (entity_types[i + 1 ..]) |b| assert(a != b);
    }
}

/// A link as found in the text, before its anchor is turned into a paragraph.
const RawLink = struct { para: u32, start: u32, end: u32, anchor: u32 };

const Key = struct { id: u32, kind: u32 };

const MapRow = struct { delta: u32, element: ?u32 };

fn read_map_row(row: ion.Value) ?MapRow {
    assert(row.kind != .pad);
    // Numbers past 32 bits can only come from a broken book: skip the row.
    if (row.unsigned()) |delta| {
        return .{ .delta = std.math.cast(u32, delta) orelse return null, .element = null };
    }
    var fields = row.items();
    const delta = (fields.next() orelse return null).unsigned() orelse return null;
    const element = (fields.next() orelse return null).unsigned() orelse return null;
    const result = MapRow{
        .delta = std.math.cast(u32, delta) orelse return null,
        .element = std.math.cast(u32, element) orelse return null,
    };
    assert(result.element != null); // Only a bare number leaves its element unnamed
    return result;
}

/// A section's position map is delta encoded. Each row moves the position on, and
/// names its element, or a bare number means the element after the previous one.
const MapWalker = struct {
    position: u32,
    element: u32 = 0,

    const At = struct { position: u32, element: u32 };

    fn next(w: *MapWalker, row: MapRow) At {
        const position_before = w.position;
        // A broken book's deltas could run past 32 bits: stop at the end, don't crash.
        w.position +|= row.delta;
        w.element = row.element orelse w.element +| 1;
        assert(w.position >= position_before);
        if (row.element) |element| assert(w.element == element);
        return .{ .position = w.position, .element = w.element };
    }
};

/// Where a style event applies, in characters of its paragraph.
const Span = struct { offset: u64, length: u64 };

fn event_span(event: ion.Value) ?Span {
    assert(event.kind == .struct_); // A field was found in it: only structs have fields
    const offset = (event.get(f_event_offset) orelse return null).unsigned() orelse return null;
    const length = (event.get(f_event_length) orelse return null).unsigned() orelse return null;
    return .{ .offset = offset, .length = length };
}

/// A span's bytes in `text`, clamped to it.
fn span_bytes(text: []const u8, span: Span) struct { start: u32, end: u32 } {
    assert(text.len <= ion.size_max);
    const start = book.byte_offset(text, span.offset);
    const end = book.byte_offset(text, span.offset +| span.length);
    assert(start <= end);
    assert(end <= text.len);
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

/// The walk's stack of lists of items still to walk, deepest last.
const WalkStack = struct {
    frames: [walk_frames_max]Frame = undefined,
    count: u32 = 0,

    const Frame = struct { children: ion.Items, depth: u32 };

    fn push(stack: *WalkStack, children: ion.Value, depth: u32) void {
        assert(stack.count < walk_frames_max);
        assert(depth <= walk_depth_max + 1);
        stack.frames[stack.count] = .{ .children = children.items(), .depth = depth };
        stack.count += 1;
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

    /// Lists every entity by id and type. One outside the file means the book is cut
    /// short.
    fn read_index(p: *Parser, container: *const Container) !void {
        assert(p.index.count() == 0);
        assert(container.index.len <= ion.size_max);
        var offset: u32 = 0;
        while (row_size <= container.index.len - offset) : (offset += row_size) {
            const row = read_row(container.index, offset);
            const bytes = row_bytes(row, container.body) orelse return error.Truncated;
            try p.index.put(p.alloc, .{ .id = row.id, .kind = row.kind }, bytes);
        }
        assert(p.index.count() <= @divFloor(container.index.len, row_size));
    }

    /// Pairs each image resource with its bytes. Converted books list both in the
    /// same order, so the n-th resource is the n-th piece of raw media.
    fn read_images(p: *Parser) !void {
        assert(p.images.count() == 0);
        var resources: std.ArrayList(u32) = .empty;
        var media: std.ArrayList(u32) = .empty;
        var it = p.index.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr;
            if (key.kind == t_resource) try resources.append(p.alloc, key.id);
            if (key.kind == t_raw_media) try media.append(p.alloc, key.id);
        }
        if (resources.items.len != media.items.len) return; // Can't pair them safely
        std.mem.sort(u32, resources.items, {}, std.sort.asc(u32));
        std.mem.sort(u32, media.items, {}, std.sort.asc(u32));
        for (resources.items, media.items) |r, m| {
            const resource = p.entity(r, t_resource) orelse continue;
            const width = (resource.get(f_width) orelse continue).unsigned() orelse continue;
            const height = (resource.get(f_height) orelse continue).unsigned() orelse continue;
            const raw = p.index.get(.{ .id = m, .kind = t_raw_media }) orelse continue;
            if (raw.len < entity_header_size or !std.mem.eql(u8, raw[0..4], "ENTY")) continue;
            const header_size = std.mem.readInt(u32, raw[6..10], .little);
            if (header_size >= raw.len or width == 0 or height == 0) continue;
            const width_px = std.math.cast(u32, width) orelse continue;
            const height_px = std.math.cast(u32, height) orelse continue;
            const image = book.Image{
                .data = raw[header_size..],
                .width = width_px,
                .height = height_px,
            };
            try p.images.put(p.alloc, r, image);
        }
        assert(p.images.count() <= resources.items.len);
    }

    /// Reads every style once, keeping what changes how text looks.
    fn read_looks(p: *Parser) !void {
        assert(p.looks.count() == 0);
        var it = p.index.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.kind != t_style) continue;
            const v = p.entity(entry.key_ptr.id, t_style) orelse continue;
            try p.looks.put(p.alloc, entry.key_ptr.id, look_of(v));
        }
        assert(p.looks.count() <= p.index.count());
    }

    fn look_for(p: *const Parser, style: u32) book.Look {
        const look = p.looks.get(style) orelse book.Look{};
        // Paired with look_of, which makes every look kept.
        assert(look.space_before <= tenths_max);
        assert(look.space_after <= tenths_max);
        return look;
    }

    /// Fills in each paragraph's position: section start plus offset in section.
    fn resolve_positions(p: *Parser) !void {
        var starts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var keys = p.index.keyIterator();
        while (keys.next()) |key| {
            if (key.kind != t_section_positions) continue;
            const table = p.entity(key.id, key.kind) orelse continue;
            var rows = (table.get(f_position_rows) orelse continue).items();
            while (rows.next()) |row| try p.resolve_positions_section(&starts, row);
        }
        assert(starts.get(0) == null); // Element 0 is no element
        for (p.paragraphs.items) |*para| {
            para.position = starts.get(para.element); // None for one Amazon doesn't number
        }
    }

    /// Records where each element of one section starts, from the section's map.
    fn resolve_positions_section(
        p: *Parser,
        starts: *std.AutoHashMapUnmanaged(u32, u32),
        row: ion.Value,
    ) !void {
        assert(row.kind != .pad);
        const section = (row.get(f_section_name) orelse return).symbol() orelse return;
        const start = (row.get(f_section_start) orelse return).unsigned() orelse return;
        const map = p.entity(section, t_section_map) orelse return;
        const start_position = std.math.cast(u32, start) orelse return;
        var walker = MapWalker{ .position = start_position };
        var rows_in_map = (map.get(f_position_rows) orelse return).items();
        while (rows_in_map.next()) |row_in_map| {
            const step = read_map_row(row_in_map) orelse continue;
            const at = walker.next(step);
            if (at.element == 0) continue;
            const slot = try starts.getOrPut(p.alloc, at.element);
            if (!slot.found_existing) slot.value_ptr.* = at.position;
        }
        assert(walker.position >= start_position);
    }

    /// Reads a paragraph's bold and italic runs, and the links in it.
    fn collect_links(p: *Parser, item: ion.Value, para: u32) !void {
        assert(item.kind == .struct_);
        assert(para < p.paragraphs.items.len);
        const text = p.paragraphs.items[para].text;
        const events = item.get(f_style_events) orelse return;
        var runs: std.ArrayList(book.Run) = .empty;
        defer p.paragraphs.items[para].runs = runs.items;
        var it = events.items();
        while (it.next()) |event| {
            // Bold or italic over a stretch of the paragraph.
            if (event.get(f_style)) |style| {
                const look = p.look_for(style.symbol() orelse 0);
                const span = event_span(event) orelse continue;
                if (look.bold or look.italic) {
                    const bytes = span_bytes(text, span);
                    try runs.append(p.alloc, .{
                        .start = bytes.start,
                        .end = bytes.end,
                        .bold = look.bold,
                        .italic = look.italic,
                    });
                }
            }
            const anchor = (event.get(f_link) orelse continue).symbol() orelse continue;
            const span = event_span(event) orelse continue;
            const bytes = span_bytes(text, span);
            try p.raw_links.append(p.alloc, .{
                .para = para,
                .start = bytes.start,
                .end = bytes.end,
                .anchor = anchor,
            });
        }
    }

    /// Turns anchors into paragraph indexes, now that every position is known.
    fn resolve_links(p: *Parser) !void {
        const raw_links = p.raw_links.items;
        var index: u32 = 0;
        var para_previous: ?u32 = null;
        while (index < raw_links.len) {
            const para = raw_links[index].para;
            assert(para < p.paragraphs.items.len);
            // Links are collected a paragraph at a time, so each paragraph's are together.
            if (para_previous) |previous| assert(previous < para);
            para_previous = para;
            var links: std.ArrayList(book.Link) = .empty;
            while (index < raw_links.len and raw_links[index].para == para) : (index += 1) {
                const link = p.resolve_link(raw_links[index]) orelse continue;
                try links.append(p.alloc, link);
            }
            p.paragraphs.items[para].links = try links.toOwnedSlice(p.alloc);
        }
        assert(index == raw_links.len);
    }

    /// The paragraph a link's anchor points at, if it's in the text.
    fn resolve_link(p: *Parser, raw: RawLink) ?book.Link {
        assert(raw.start <= raw.end); // Paired with span_bytes
        assert(raw.para < p.paragraphs.items.len);
        const anchor = p.entity(raw.anchor, t_anchor) orelse return null;
        const position = anchor.get(f_anchor_position) orelse return null;
        const id = (position.get(f_id) orelse return null).unsigned() orelse return null;
        const target = p.positions.get(id) orelse return null;
        // An id on nothing after it (a trailing empty container) points past the last
        // paragraph: no link, so every link of a book points at one of its paragraphs
        if (target >= p.paragraphs.items.len) return null;
        return .{ .start = raw.start, .end = raw.end, .target = target };
    }

    /// The book's table of contents, from its navigation. Entries whose target
    /// isn't in the text are skipped.
    fn read_contents(p: *Parser) ![]book.Chapter {
        var out: std.ArrayList(book.Chapter) = .empty;
        var it = p.index.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.kind != t_navigation) continue;
            const nav = p.entity(entry.key_ptr.id, entry.key_ptr.kind) orelse continue;
            var orders = nav.items();
            while (orders.next()) |order| {
                var containers = (order.get(f_nav_containers) orelse continue).items();
                while (containers.next()) |ref| {
                    const container = p.nav_container(ref) orelse continue;
                    const nav_type = container.get(f_nav_type) orelse continue;
                    if (nav_type.symbol() != nav_contents) continue;
                    try p.add_chapters(&out, container);
                }
            }
            break;
        }
        for (out.items) |chapter| {
            assert(chapter.para < p.paragraphs.items.len);
            assert(chapter.depth <= chapters_depth_max);
        }
        return out.toOwnedSlice(p.alloc);
    }

    /// A navigation container, listed by name or written inline.
    fn nav_container(p: *Parser, ref: ion.Value) ?ion.Value {
        assert(ref.kind != .pad);
        if (ref.symbol()) |id| return p.entity(id, t_nav_container);
        if (ref.kind == .struct_) return ref;
        return null;
    }

    /// Adds every entry under `parent`, depth first, the way they nest.
    fn add_chapters(p: *Parser, out: *std.ArrayList(book.Chapter), parent: ion.Value) !void {
        const Frame = struct { entries: ion.Items, depth: u8 };
        assert(parent.kind == .struct_);
        var stack: [chapters_depth_max + 1]Frame = undefined;
        stack[0] = .{ .entries = (parent.get(f_nav_entries) orelse return).items(), .depth = 0 };
        var count: u32 = 1;
        // Bounded: each step reads an entry or drops a finished list.
        while (count > 0) {
            const frame = &stack[count - 1];
            assert(frame.depth == count - 1);
            const entry = frame.entries.next() orelse {
                count -= 1;
                continue;
            };
            try p.add_chapter(out, entry, frame.depth);
            if (frame.depth < chapters_depth_max) {
                if (entry.get(f_nav_entries)) |entries| {
                    stack[count] = .{ .entries = entries.items(), .depth = frame.depth + 1 };
                    count += 1;
                }
            }
        }
    }

    /// Adds one entry, if it has a title and its target is in the text.
    fn add_chapter(
        p: *Parser,
        out: *std.ArrayList(book.Chapter),
        entry: ion.Value,
        depth: u8,
    ) !void {
        assert(entry.kind != .pad);
        assert(depth <= chapters_depth_max);
        const label = entry.get(f_nav_label) orelse return;
        const title = (label.get(f_nav_text) orelse return).text() orelse return;
        const target = entry.get(f_nav_target) orelse return;
        const element = target.get(f_id) orelse return;
        const para = p.positions.get(element.unsigned() orelse return) orelse return;
        if (para >= p.paragraphs.items.len) return;
        try out.append(p.alloc, .{ .title = title, .para = para, .depth = depth });
    }

    fn entity(p: *Parser, id: u32, kind: u32) ?ion.Value {
        assert(std.mem.indexOfScalar(u32, &entity_types, kind) != null);
        const value = entity_value(p.index.get(.{ .id = id, .kind = kind }) orelse return null);
        if (value) |v| assert(v.kind != .pad);
        return value;
    }

    /// Resolves a text reference. False means it pointed at nothing usable.
    fn add_content(p: *Parser, ref: ion.Value, style: u32) !bool {
        assert(ref.kind != .pad);
        const count_before = p.paragraphs.items.len;
        const text = p.content_text(ref) orelse return false;
        try p.paragraphs.append(p.alloc, .{
            .text = text,
            .look = p.look_for(style),
        });
        assert(p.paragraphs.items.len == count_before + 1);
        return true;
    }

    /// The text a reference names: written inline, or the n-th string of a content.
    fn content_text(p: *Parser, ref: ion.Value) ?[]const u8 {
        assert(ref.kind != .pad);
        if (ref.text()) |text| return text;
        const name = (ref.get(f_name) orelse return null).symbol() orelse return null;
        const wanted = (ref.get(f_index) orelse return null).unsigned() orelse return null;
        const content = p.entity(name, t_content) orelse return null;
        assert(content.kind != .pad);
        var strings = (content.get(f_children) orelse return null).items();
        var i: u64 = 0;
        while (strings.next()) |s| : (i += 1) {
            if (i != wanted) continue;
            return s.text();
        }
        return null;
    }

    /// Walks a section's reading order, depth first, adding its text and pictures.
    fn walk(p: *Parser, first: ion.Value) !void {
        var stack: WalkStack = .{};
        try p.walk_item(first, 0, &stack);
        // Bounded: each step walks one item or drops a finished list.
        while (stack.count > 0) {
            assert(stack.count <= walk_frames_max);
            const frame = &stack.frames[stack.count - 1];
            const child = frame.children.next() orelse {
                stack.count -= 1;
                continue;
            };
            if (frame.depth > walk_depth_max) return error.TooDeep;
            try p.walk_item(child, frame.depth, &stack);
        }
        assert(stack.count == 0);
    }

    /// Adds one item of the reading order, and leaves its children on the stack: its
    /// story's on top, as they come first, then its own.
    fn walk_item(p: *Parser, item: ion.Value, depth: u32, stack: *WalkStack) !void {
        assert(depth <= walk_depth_max);
        assert(stack.count <= 2 * depth);
        assert(p.section > 0);
        if (item.text()) |text| {
            try p.paragraphs.append(p.alloc, .{ .text = text });
            return;
        }
        if (item.kind != .struct_) {
            p.missing += 1;
            return;
        }
        const style = if (item.get(f_style)) |s| s.symbol() orelse 0 else 0;
        // An id is a number: one of another kind would key as 0, another element's
        const element_id = if (item.get(f_id)) |field| field.unsigned() else null;
        if (element_id) |id| {
            const slot = try p.positions.getOrPut(p.alloc, id);
            if (!slot.found_existing) slot.value_ptr.* = @intCast(p.paragraphs.items.len);
        }
        const item_type = if (item.get(f_type)) |t| t.symbol() else null;
        if (item_type == type_image) try p.walk_item_image(item, style);
        if (item.get(f_content_ref)) |ref| {
            if (try p.add_content(ref, style)) {
                try p.walk_item_content(item);
            } else {
                p.missing += 1;
            }
        }
        if (item.get(f_children)) |children| stack.push(children, depth + 1);
        if (item.get(f_story)) |story| {
            // A story names itself in this same field, so only descend into its children.
            const loaded = if (story.symbol()) |id| p.entity(id, t_story) else null;
            if (loaded) |s| {
                if (s.get(f_children)) |children| stack.push(children, depth + 1);
            } else {
                p.missing += 1;
            }
        }
        assert(stack.count <= 2 * (depth + 1));
    }

    /// Adds an image item's picture, if its resource is one.
    fn walk_item_image(p: *Parser, item: ion.Value, style: u32) !void {
        assert(item.kind == .struct_);
        const resource = (item.get(f_resource) orelse return).symbol() orelse return;
        const image = p.images.get(resource) orelse return;
        // Paired with read_images, which keeps no empty picture.
        assert(image.width > 0);
        assert(image.height > 0);
        try p.paragraphs.append(p.alloc, .{
            .text = "",
            .look = p.look_for(style),
            .image = image,
            .section = p.section,
        });
    }

    /// Fills in the paragraph add_content just made from `item`.
    fn walk_item_content(p: *Parser, item: ion.Value) !void {
        assert(item.kind == .struct_);
        assert(p.paragraphs.items.len > 0);
        const para: u32 = @intCast(p.paragraphs.items.len - 1);
        p.paragraphs.items[para].section = p.section;
        const element_id = if (item.get(f_id)) |field| field.unsigned() else null;
        if (element_id) |id| p.paragraphs.items[para].element = std.math.cast(u32, id) orelse 0;
        try p.collect_links(item, para);
    }
};

fn amount(v: ion.Value, unit: u32) ?f64 {
    assert(v.kind != .pad);
    assert(unit == unit_rem or unit == unit_lines);
    if ((v.get(f_unit) orelse return null).symbol() != unit) return null;
    return (v.get(f_amount) orelse return null).number();
}

fn tenths(lines: f64) u8 {
    const result: u8 = @intFromFloat(std.math.clamp(lines * 10, 0, tenths_max));
    assert(result <= tenths_max);
    return result;
}

/// How a style sets text, from the fields that matter on a reader's page.
fn look_of(v: ion.Value) book.Look {
    assert(v.kind != .pad);
    var look = book.Look{};
    if (v.get(f_font_style)) |s| look.italic = s.symbol() == style_italic;
    if (v.get(f_font_weight)) |w| {
        look.bold = w.symbol() == weight_bold or w.symbol() == weight_semibold;
    }
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
    assert(look.size < book.size_scales.len);
    assert(look.space_before <= tenths_max);
    assert(look.space_after <= tenths_max);
    return look;
}

/// A KFX container: its header info, the entity index (24-byte rows), and the
/// body the index points into.
const Container = struct { info: ion.Value, index: []const u8, body: []const u8 };

fn open_container(data: []const u8) !Container {
    if (data.len < container_header_size) return error.NotKfx;
    if (!std.mem.eql(u8, data[0..4], "CONT")) return error.NotKfx;
    if (data.len > ion.size_max) return error.TooLarge;
    const header_size = std.mem.readInt(u32, data[6..10], .little);
    const info_offset = std.mem.readInt(u32, data[10..14], .little);
    const info_size = std.mem.readInt(u32, data[14..18], .little);
    if (info_offset > data.len) return error.Truncated;
    if (info_size > data.len - info_offset) return error.Truncated;
    if (header_size > data.len) return error.Truncated;
    const info = try ion.parse(data[info_offset..][0..info_size]);
    // Numbers only as numbers: a field of another kind reads 0 as `.int`, a place it isn't
    const index_offset = (info.get(f_index_offset) orelse return error.BadHeader).unsigned() orelse
        return error.BadHeader;
    const index_size = (info.get(f_index_length) orelse return error.BadHeader).unsigned() orelse
        return error.BadHeader;
    if (index_offset > data.len) return error.Truncated;
    if (index_size > data.len - index_offset) return error.Truncated;
    const container = Container{
        .info = info,
        .index = data[@intCast(index_offset)..][0..@intCast(index_size)],
        .body = data[header_size..],
    };
    assert(container.index.len <= data.len);
    assert(container.body.len <= data.len);
    return container;
}

/// An index row: entity id, type, and where its bytes sit in the body.
const Row = struct { id: u32, kind: u32, offset: u64, size: u64 };

/// The row at `offset` in the index, a whole row from its start.
fn read_row(index: []const u8, offset: u32) Row {
    assert(offset % row_size == 0);
    assert(offset <= index.len);
    assert(row_size <= index.len - offset);
    const row = index[offset..][0..row_size];
    return .{
        .id = std.mem.readInt(u32, row[0..4], .little),
        .kind = std.mem.readInt(u32, row[4..8], .little),
        .offset = std.mem.readInt(u64, row[8..16], .little),
        .size = std.mem.readInt(u64, row[16..24], .little),
    };
}

/// A row's bytes in the body, or null when they would lie outside it.
fn row_bytes(row: Row, body: []const u8) ?[]const u8 {
    assert(body.len <= ion.size_max);
    if (row.offset > body.len) return null;
    if (row.size > body.len - row.offset) return null;
    const bytes = body[@intCast(row.offset)..][0..@intCast(row.size)];
    assert(bytes.len == row.size);
    assert(row.offset + row.size <= body.len);
    return bytes;
}

/// An entity's value, past its "ENTY" header.
pub fn entity_value(raw: []const u8) ?ion.Value {
    if (raw.len < entity_header_size or !std.mem.eql(u8, raw[0..4], "ENTY")) return null;
    const header_size = std.mem.readInt(u32, raw[6..10], .little);
    if (header_size > raw.len) return null;
    const value = ion.parse(raw[header_size..]) catch return null;
    // Paired with ion.parse: no padding, and a value lies inside the bytes it was read from.
    assert(value.kind != .pad);
    assert(value.body.len <= raw.len - header_size);
    return value;
}

pub const Entity = struct { id: u32, kind: u32, raw: []const u8 };

/// Walks every entity in the book, skipping any that point outside the file.
pub const Entities = struct {
    container: Container,
    offset: u32 = 0,

    pub fn next(it: *Entities) ?Entity {
        const index = it.container.index;
        assert(index.len <= ion.size_max);
        assert(it.offset <= index.len);
        assert(it.offset % row_size == 0);
        while (row_size <= index.len - it.offset) {
            const row = read_row(index, it.offset);
            it.offset += row_size;
            const raw = row_bytes(row, it.container.body) orelse continue;
            return .{ .id = row.id, .kind = row.kind, .raw = raw };
        }
        assert(it.offset <= index.len);
        return null;
    }
};

pub fn entities(data: []const u8) !Entities {
    const container = try open_container(data);
    // Paired with open_container: offsets in the index fit in a u32.
    assert(container.index.len <= ion.size_max);
    assert(container.body.len <= ion.size_max);
    return .{ .container = container };
}

/// True when every entity the index lists is inside the file. A download still in
/// progress fails this, and checking it is far cheaper than parsing the book.
pub fn is_complete(data: []const u8) bool {
    const container = open_container(data) catch return false;
    assert(container.index.len <= ion.size_max);
    if (container.index.len < row_size) return false;
    var offset: u32 = 0;
    while (row_size <= container.index.len - offset) : (offset += row_size) {
        const row = read_row(container.index, offset);
        if (row_bytes(row, container.body) == null) return false;
    }
    assert(offset <= container.index.len);
    return true;
}

/// The book's first embedded JPEG, which is its cover in converted books.
pub fn cover_image(data: []const u8) ?[]const u8 {
    const container = open_container(data) catch return null;
    assert(container.index.len <= ion.size_max);
    var offset: u32 = 0;
    while (row_size <= container.index.len - offset) : (offset += row_size) {
        const row = read_row(container.index, offset);
        if (row.kind != t_raw_media) continue;
        const raw = row_bytes(row, container.body) orelse continue;
        if (raw.len < entity_header_size) continue;
        const header_size = std.mem.readInt(u32, raw[6..10], .little);
        if (header_size >= raw.len) continue;
        const media = raw[header_size..];
        assert(media.len > 0);
        if (media.len > 2 and media[0] == 0xff and media[1] == 0xd8) return media;
    }
    assert(offset <= container.index.len);
    return null;
}

pub fn parse(alloc: std.mem.Allocator, data: []const u8) !book.Book {
    const container = try open_container(data);
    // Unsigned numbers, or the book isn't read: one of another kind would read as 0,
    // uncompressed and unencrypted, whatever it said
    const compression = container.info.get(f_compression) orelse return error.BadHeader;
    if ((compression.unsigned() orelse return error.BadHeader) != 0) return error.Compressed;
    const drm = container.info.get(f_drm) orelse return error.BadHeader;
    if ((drm.unsigned() orelse return error.BadHeader) != 0) return error.Encrypted;

    var p = Parser{ .alloc = alloc };
    try p.read_index(&container);
    try p.read_looks();
    try p.read_images();
    const sections = try parse_sections(&p);
    // Nothing to read (its sections missing, say): refused, as an EPUB without any is
    if (p.paragraphs.items.len == 0) return error.EmptyBook;
    try p.resolve_links();
    try p.resolve_positions();
    notes.mark_notes(p.paragraphs.items);
    const chapters = try p.read_contents();
    const result = book.Book{
        .paragraphs = try p.paragraphs.toOwnedSlice(alloc),
        .chapters = chapters,
        .sections = sections,
        .missing_refs = p.missing,
    };
    assert(result.sections == p.section);
    for (result.chapters) |chapter| assert(chapter.para < result.paragraphs.len);
    return result;
}

/// Walks every section of the first reading order. Returns how many there were.
fn parse_sections(p: *Parser) !u32 {
    assert(p.section == 0);
    assert(p.paragraphs.items.len == 0);
    const document = find_document(p) orelse return error.NoReadingOrder;
    const reading_orders = document.get(f_reading_orders) orelse return error.NoReadingOrder;
    var orders = reading_orders.items();
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
        if (templates.next()) |first| try p.walk(first);
    }
    assert(p.section == count);
    return count;
}

fn find_document(p: *Parser) ?ion.Value {
    assert(p.section == 0); // Read before any section is walked
    var it = p.index.iterator();
    while (it.next()) |entry| {
        const kind = entry.key_ptr.kind;
        if (kind != t_document and kind != t_book_nav) continue;
        if (p.entity(entry.key_ptr.id, kind)) |v| {
            if (v.get(f_reading_orders) != null) {
                assert(v.kind == .struct_); // Only a struct has fields
                return v;
            }
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

test "numbers too large for a position are skipped, not a crash" {
    try std.testing.expect(read_map_row(.{ .kind = .uint, .int = 1 << 40 }) == null);
    var walker = MapWalker{ .position = std.math.maxInt(u32) - 1, .element = std.math.maxInt(u32) };
    const at = walker.next(.{ .delta = 5, .element = null });
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), at.position);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), at.element);
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
            const bound: u32 = @intCast(len + 8);
            @memcpy(buf[0..4], "CONT");
            std.mem.writeInt(u32, buf[6..10], random.uintLessThan(u32, bound), .little);
            std.mem.writeInt(u32, buf[10..14], random.uintLessThan(u32, bound), .little);
            std.mem.writeInt(u32, buf[14..18], random.uintLessThan(u32, bound), .little);
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
