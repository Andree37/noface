//! Glyph cache and page layout for 8-bit grayscale pages.
const std = @import("std");
const Font = @import("../gfx/font.zig").Font;
const Page = @import("../gfx/page.zig").Page;
const book_model = @import("../model/book.zig");
const Paragraph = @import("../model/book.zig").Paragraph;
const hyphen = @import("hyphen.zig");

/// Where a note reference landed on a page.
pub const Hit = struct { x: i32, y: i32, w: i32, h: i32, target: u32 };

const mark_shade = 0xe4; // Very faint, so highlighted text reads like any other

fn is_marked(marks: []const book_model.Mark, para: usize, start: usize, end: usize) bool {
    for (marks) |m| {
        if (m.para == para and start < m.end and end > m.start) return true;
    }
    return false;
}

pub const Hits = struct {
    items: [32]Hit = undefined,
    len: usize = 0,
    words: [1024]book_model.Word = undefined,
    word_count: usize = 0,
    pictures: [16]Hit = undefined, // Where each picture sits; target is its paragraph
    picture_count: usize = 0,

    pub fn clear(h: *Hits) void {
        h.len = 0;
        h.word_count = 0;
        h.picture_count = 0;
    }

    fn add_picture(h: *Hits, hit: Hit) void {
        if (h.picture_count == h.pictures.len) return;
        h.pictures[h.picture_count] = hit;
        h.picture_count += 1;
    }

    /// The paragraph of the picture at a point, if there's one there.
    pub fn picture_at(h: *const Hits, x: i32, y: i32) ?u32 {
        for (h.pictures[0..h.picture_count]) |r| {
            if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return r.target;
        }
        return null;
    }

    fn add_word(h: *Hits, word: book_model.Word) void {
        if (h.word_count == h.words.len) return;
        h.words[h.word_count] = word;
        h.word_count += 1;
    }

    fn add(h: *Hits, hit: Hit) void {
        if (h.len == h.items.len) return;
        h.items[h.len] = hit;
        h.len += 1;
    }

    /// Finds the reference at a tap, with room for how small they are.
    pub fn find(h: *const Hits, x: i32, y: i32) ?u32 {
        const pad = 30;
        for (h.items[0..h.len]) |r| {
            if (x >= r.x - pad and x < r.x + r.w + pad and y >= r.y - pad and y < r.y + r.h + pad) return r.target;
        }
        return null;
    }
};

test "tap near a reference finds it" {
    var hits = Hits{};
    hits.add(.{ .x = 100, .y = 200, .w = 20, .h = 40, .target = 7 });
    try std.testing.expectEqual(@as(u32, 7), hits.find(90, 190).?);
    try std.testing.expect(hits.find(300, 200) == null);
}

/// Where layout gets the font for a weight, slant and size. Without one, every
/// word uses the base font.
pub const Faces = struct {
    ctx: *anyopaque,
    pick: *const fn (ctx: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*Font,
};

/// Draws a picture into a page. Decoding lives outside layout, which only needs sizes.
pub const Images = struct {
    ctx: *anyopaque,
    draw: *const fn (ctx: *anyopaque, page: Page, image: book_model.Image, x: u32, y: u32, w: u32, h: u32) void,
};

pub const Layout = struct {
    faces: ?Faces = null,
    images: ?Images = null,
    margin_x: i32,
    margin_top: i32,
    margin_bottom: i32,
    indent: f32,
    reference: ?*Font = null, // Smaller font for note references
    marks: []const book_model.Mark = &.{},
    justify: bool = true,
    bold_starts: bool = false, // The first half of each word's letters in bold, to lead the eye
    hyphenator: ?*const hyphen.Hyphenator = null, // The book's language, when known
    // A page ends here at the latest, so a page can be made to break exactly where
    // another page is known to start
    stop: ?book_model.Pos = null,
};

/// Whether `p` has reached the stop position.
fn at_stop(l: Layout, para: usize, byte: usize) bool {
    const st = l.stop orelse return false;
    return para > st.para or (para == st.para and byte >= st.byte);
}

const max_words = 96;

const Link = book_model.Link;

fn find_reference(links: []const Link, paras: []const Paragraph, start: usize, len: usize) ?Link {
    for (links) |link| {
        if (link.end <= start or link.start >= start + len) continue;
        if (link.target < paras.len and paras[link.target].note_start) return link;
    }
    return null;
}

fn face(l: Layout, base: *Font, bold: bool, italic: bool, size: u8) !*Font {
    const f = l.faces orelse return base;
    return f.pick(f.ctx, bold, italic, size);
}

/// How many bytes of `word` are set bold with bold word starts: anything before its
/// first letter, then half its letters (one for words of up to three), rounded up.
pub fn bold_start(word: []const u8) usize {
    var letters: usize = 0;
    var it = (std.unicode.Utf8View.init(word) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (is_letter(cp)) letters += 1;
    }
    if (letters == 0) return 0;
    const want = if (letters <= 3) 1 else (letters + 1) / 2;
    var seen: usize = 0;
    it = (std.unicode.Utf8View.init(word) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (is_letter(cp)) seen += 1;
        if (seen == want) return it.i;
    }
    return word.len;
}

/// Letters and digits; beyond ASCII, anything but Latin-1's symbols and the general
/// punctuation block (curly quotes, dashes, ellipses).
fn is_letter(cp: u21) bool {
    if (cp < 128) return std.ascii.isAlphanumeric(@intCast(cp));
    return cp > 0xbf and !(cp >= 0x2000 and cp <= 0x206f);
}

/// The bold face for a word's start with bold word starts on, or null: off, or the
/// word is bold already, or it's the rest of a word broken at the line before.
fn start_face(l: Layout, base: *Font, p: Paragraph, wf: *Font, text: []const u8, word_start: usize) !?*Font {
    if (!l.bold_starts) return null;
    if (word_start > 0 and text[word_start - 1] != ' ' and text[word_start - 1] != '\n') return null;
    var italic = p.look.italic;
    for (p.runs) |r| {
        if (word_start >= r.start and word_start < r.end) italic = italic or r.italic;
    }
    const bold = try face(l, base, true, italic, p.look.size);
    return if (bold == wf) null else bold;
}

/// A word's width, its start in `start` when given.
fn word_width(wf: *Font, start: ?*Font, word: []const u8) !f32 {
    const b = start orelse return wf.measure(word);
    const k = bold_start(word);
    return try b.measure(word[0..k]) + try wf.measure(word[k..]);
}

fn draw_word(p: Page, wf: *Font, start: ?*Font, x: f32, y: i32, word: []const u8) !void {
    const b = start orelse return wf.draw(p, x, y, word);
    const k = bold_start(word);
    try b.draw(p, x, y, word[0..k]);
    try wf.draw(p, x + try b.measure(word[0..k]), y, word[k..]);
}

/// Bold and italic for a word: its paragraph's, plus any run it starts in.
fn word_face(l: Layout, base: *Font, p: Paragraph, word_start: usize) !*Font {
    var bold = p.look.bold;
    var italic = p.look.italic;
    for (p.runs) |r| {
        if (word_start >= r.start and word_start < r.end) {
            bold = bold or r.bold;
            italic = italic or r.italic;
        }
    }
    return face(l, base, bold, italic, p.look.size);
}

/// A picture's size on the page: as large as fits, but at most twice its own size,
/// so small ornaments don't turn into blocks.
pub fn image_size(img: book_model.Image, max_w: f32, max_h: f32) struct { w: i32, h: i32 } {
    const w: f32 = @floatFromInt(img.width);
    const h: f32 = @floatFromInt(img.height);
    const scale = @min(@min(max_w / w, max_h / h), 2.0);
    return .{ .w = @max(1, @as(i32, @intFromFloat(w * scale))), .h = @max(1, @as(i32, @intFromFloat(h * scale))) };
}

fn space_lines(tenths: u8, base: *Font) i32 {
    return @divTrunc(@as(i32, tenths) * base.line_height, 10);
}

/// Where a picture `w` wide starts: centred in the text column.
fn picture_left(l: Layout, line_width: f32, w: i32) u32 {
    return @intCast(l.margin_x + @divTrunc(@as(i32, @intFromFloat(line_width)) - w, 2));
}

/// Lay out one page and return where the next page starts.
/// With `page` null this only measures, which is how the book gets paginated.
/// Lays out one page from `start`, drawing it into `maybe_page` when given (else only
/// measuring, to find where pages break), and returns where the next page starts.
pub fn layout_page(font: *Font, maybe_page: ?Page, geometry: Page, paras: []const Paragraph, start: book_model.Pos, l: Layout, hits: ?*Hits) !book_model.Pos {
    if (maybe_page) |p| @memset(p.buf, 0xff);
    const line_width: f32 = @floatFromInt(@as(i32, @intCast(geometry.width)) - 2 * l.margin_x);
    const bottom = @as(i32, @intCast(geometry.height)) - l.margin_bottom;
    var top = l.margin_top; // Top of the next line
    var pos = start;

    while (pos.para < paras.len) : ({
        pos.para += 1;
        pos.byte = 0;
    }) {
        if (at_stop(l, pos.para, pos.byte)) return pos;
        const para = paras[pos.para];
        if (para.note) continue; // Notes open in a panel, not in the text
        if (para.image) |img| {
            const size = image_size(img, line_width, @floatFromInt(bottom - l.margin_top));
            // A picture never splits: it starts the next page unless it opens this one
            if (top + size.h > bottom + font.ascent and top > l.margin_top) return .{ .para = pos.para, .byte = 0 };
            if (maybe_page) |p| draw_picture(p, l, img, line_width, size, top, @intCast(pos.para), hits);
            top += size.h + @divTrunc(font.line_height, 2);
            continue;
        }
        const look = para.look;
        const pf = try face(l, font, look.bold, look.italic, look.size); // Sets the line height
        const style = ParagraphStyle.of(look, l);
        const space = try pf.measure(" ");
        const text = para.text;
        var i = pos.byte;
        var indent: f32 = if (i == 0 and style.plain) l.indent else 0;
        if (i == 0 and top > l.margin_top) top += space_lines(look.space_before, font);

        while (i < text.len) {
            while (i < text.len and (text[i] == ' ' or text[i] == '\n')) i += 1;
            if (i >= text.len) break;
            if (at_stop(l, pos.para, i)) return .{ .para = pos.para, .byte = i };
            const avail = line_width - indent;
            const line = try fill_line(l, font, para, i, line_limit(l, pos.para, i, text.len), avail, style.plain, space);
            const baseline = top + pf.ascent;
            if (baseline > bottom) return .{ .para = pos.para, .byte = i }; // The page is full
            // Justified lines spread their words, up to a limit; others keep a space
            const gap = if (style.justify and !line.ends_para and line.n > 1)
                @min((avail - line.width()) / @as(f32, @floatFromInt(line.n - 1)), space * 2.5)
            else
                space;
            const used = line.width() + gap * @as(f32, @floatFromInt(@max(line.n, 1) - 1));
            const left = @as(f32, @floatFromInt(l.margin_x)) + indent + switch (look.alignment) {
                .center => @max(avail - used, 0) / 2,
                .right => @max(avail - used, 0),
                else => 0,
            };
            if (maybe_page) |p| try draw_line(p, l, paras, pos.para, &line, left, baseline, gap, pf, hits);
            top += pf.line_height;
            i = line.next;
            indent = if (line.ends_para and style.plain) l.indent else 0;
        }
        top += space_lines(look.space_after, font);
    }
    return pos;
}

/// How a paragraph's lines are set: `plain` body text is indented and may be
/// hyphenated; `justify`ed lines are spread to the margins.
const ParagraphStyle = struct {
    plain: bool,
    justify: bool,

    fn of(look: book_model.Look, l: Layout) ParagraphStyle {
        const body_size = look.size == book_model.normal_size;
        return .{
            // Headings and centred lines aren't indented
            .plain = body_size and (look.alignment == .auto or look.alignment == .justify or look.alignment == .left),
            // Only body text is justified, unless the book asks for it
            .justify = switch (look.alignment) {
                .auto => l.justify and body_size,
                .justify => true,
                else => false,
            },
        };
    }
};

/// Where a line starting at byte `i` must end: the paragraph's end, or in the stop's
/// paragraph, the stop.
fn line_limit(l: Layout, para: usize, i: usize, text_len: usize) usize {
    const st = l.stop orelse return text_len;
    return if (st.para == para) @max(st.byte, i + 1) else text_len;
}

/// The words of one line, as measured, and where the next line starts.
const Line = struct {
    words: [max_words][]const u8 = undefined,
    widths: [max_words]f32 = undefined,
    fonts: [max_words]*Font = undefined,
    starts: [max_words]?*Font = undefined, // Bold word starts' face, per word
    n: usize = 0,
    next: usize = 0, // Where the next line starts, in the paragraph's text
    ends_para: bool = false, // Set like a paragraph's last line: not spread
    hyphen_end: bool = false, // The last word is the first part of a broken word

    fn add(line: *Line, word: []const u8, w: f32, wf: *Font, sf: ?*Font) void {
        line.words[line.n] = word;
        line.widths[line.n] = w;
        line.fonts[line.n] = wf;
        line.starts[line.n] = sf;
        line.n += 1;
    }

    fn width(line: *const Line) f32 {
        var total: f32 = 0;
        for (line.widths[0..line.n]) |w| total += w;
        return total;
    }
};

/// The words from byte `i` that fit in `avail`. The word that doesn't fit is
/// hyphenated if part of it fits (in plain text), else left for the next line; a
/// word wider than a whole line (a URL, unspaced CJK) is cut.
fn fill_line(l: Layout, font: *Font, para: Paragraph, i: usize, limit: usize, avail: f32, plain: bool, space: f32) !Line {
    const text = para.text;
    var line = Line{};
    var used: f32 = 0;
    var j = i;
    while (line.n < max_words) {
        if (j >= limit) {
            line.ends_para = true; // Ends early at the stop
            break;
        }
        var end = j;
        while (end < limit and end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
        const word = text[j..end];
        const wf = try word_face(l, font, para, j);
        const sf = try start_face(l, font, para, wf, text, j);
        const w = try word_width(wf, sf, word);
        if (line.n == 0 and w > avail) {
            const part = word[0..try wf.fit(word, avail)];
            line.add(part, try wf.measure(part), wf, null);
            j += part.len;
            break;
        }
        const gap: f32 = if (line.n == 0) 0 else space;
        if (line.n > 0 and used + gap + w > avail) {
            // Rather than leave a hole, take as much of the word as fits
            const room = avail - used - gap;
            if (plain and room > space) {
                if (try hyphenated(l, wf, sf, word, room)) |b| {
                    line.add(word[0..b.at], b.width, wf, sf);
                    j += b.at;
                    line.hyphen_end = b.hyphen;
                }
            }
            break;
        }
        line.add(word, w, wf, sf);
        used += gap + w;
        j = end;
        if (j >= text.len or text[j] == '\n') {
            line.ends_para = true;
            if (j < text.len) j += 1;
            break;
        }
        while (j < text.len and text[j] == ' ') j += 1;
        if (j >= text.len) {
            line.ends_para = true;
            break;
        }
    }
    line.next = j;
    return line;
}

/// The longest first part of `word` (by its hyphenation points) that fits in `room`,
/// with its width, the hyphen included where one is drawn.
fn hyphenated(l: Layout, wf: *Font, sf: ?*Font, word: []const u8, room: f32) !?struct { at: usize, hyphen: bool, width: f32 } {
    var found: [24]hyphen.Break = undefined;
    const breaks = hyphen.breaks(l.hyphenator, word, &found);
    var k = breaks.len;
    while (k > 0) {
        k -= 1;
        const b = breaks[k];
        const w = try word_width(wf, sf, word[0..b.at]) + if (b.hyphen) try wf.measure("-") else 0;
        if (w <= room) return .{ .at = b.at, .hyphen = b.hyphen, .width = w };
    }
    return null;
}

/// Draws a line's words from `left`, `gap` apart: a highlight's shading under them,
/// their tap areas, note marks raised and small, and the hyphen of a broken word.
fn draw_line(p: Page, l: Layout, paras: []const Paragraph, para_index: usize, line: *const Line, left: f32, baseline: i32, gap: f32, pf: *Font, hits: ?*Hits) !void {
    const para = paras[para_index];
    var x = left;
    for (line.words[0..line.n], line.widths[0..line.n], line.fonts[0..line.n], line.starts[0..line.n], 0..) |word, w, wf, sf, k| {
        const word_start = @intFromPtr(word.ptr) - @intFromPtr(para.text.ptr);
        const line_top = baseline - pf.ascent;
        if (is_marked(l.marks, para_index, word_start, word_start + word.len)) {
            // Reaches into the gap, so a marked phrase reads as one band
            p.fill_rect(@intFromFloat(x), @intCast(line_top + 4), @intFromFloat(w + gap), @intCast(pf.line_height - 8), mark_shade);
        }
        if (hits) |h| h.add_word(.{
            .x = @intFromFloat(x),
            .y = line_top,
            .w = @intFromFloat(w),
            .h = pf.line_height,
            .para = @intCast(para_index),
            .start = @intCast(word_start),
            .end = @intCast(word_start + word.len),
        });
        var shrink: f32 = 0; // A small mark takes less room than was measured
        if (find_reference(para.links, paras, word_start, word.len)) |r| {
            shrink = try draw_with_mark(p, l, wf, pf, word, word_start, r, x, baseline, hits);
        } else {
            try draw_word(p, wf, sf, x, baseline, word);
        }
        if (line.hyphen_end and k + 1 == line.n) try wf.draw(p, x + try word_width(wf, sf, word), baseline, "-");
        x += w + gap - shrink;
    }
}

/// A word holding a note's reference: the mark raised and small, like a printed one,
/// and tappable. Returns how much narrower the mark is than measured.
fn draw_with_mark(p: Page, l: Layout, wf: *Font, pf: *Font, word: []const u8, word_start: usize, r: Link, x: f32, baseline: i32, hits: ?*Hits) !f32 {
    const small = l.reference orelse wf;
    const a = @max(r.start, word_start) - word_start;
    const b = @min(r.end, word_start + word.len) - word_start;
    try wf.draw(p, x, baseline, word[0..a]);
    const mark_x = x + try wf.measure(word[0..a]);
    try small.draw(p, mark_x, baseline - @divTrunc(pf.line_height, 3), word[a..b]);
    const mark_w = try small.measure(word[a..b]);
    try wf.draw(p, mark_x + mark_w, baseline, word[b..]);
    if (hits) |h| h.add(.{
        .x = @intFromFloat(mark_x),
        .y = baseline - pf.ascent,
        .w = @intFromFloat(@max(mark_w, 1)),
        .h = pf.line_height,
        .target = r.target,
    });
    return try wf.measure(word[a..b]) - mark_w;
}

fn draw_picture(p: Page, l: Layout, img: book_model.Image, line_width: f32, size: anytype, top: i32, para_index: u32, hits: ?*Hits) void {
    const x = picture_left(l, line_width, size.w);
    if (l.images) |im| im.draw(im.ctx, p, img, x, @intCast(top), @intCast(size.w), @intCast(size.h));
    if (hits) |h| h.add_picture(.{ .x = @intCast(x), .y = @intCast(top), .w = size.w, .h = size.h, .target = para_index });
}

pub fn render_page(font: *Font, page: Page, paras: []const Paragraph, start: book_model.Pos, l: Layout, hits: ?*Hits) !book_model.Pos {
    return layout_page(font, page, page, paras, start, l, hits);
}

/// Hard black and white, for waveforms that cannot show gray.
pub fn threshold(src: []const u8, dst: []u8) void {
    for (src, dst) |s, *d| d.* = if (s < 128) 0x00 else 0xff;
}

test "pictures fit the page and small ones stay small" {
    const big = image_size(.{ .data = "", .width = 2000, .height = 1000 }, 1000, 1400);
    try std.testing.expectEqual(@as(i32, 1000), big.w);
    try std.testing.expectEqual(@as(i32, 500), big.h);
    const tall = image_size(.{ .data = "", .width = 500, .height = 3000 }, 1000, 1400);
    try std.testing.expectEqual(@as(i32, 1400), tall.h);
    const ornament = image_size(.{ .data = "", .width = 50, .height = 16 }, 1000, 1400);
    try std.testing.expectEqual(@as(i32, 100), ornament.w);
}

test "bold word starts cover half of each word's letters" {
    try std.testing.expectEqualStrings("acknow", "acknowledged"[0..bold_start("acknowledged")]);
    try std.testing.expectEqualStrings("t", "the"[0..bold_start("the")]);
    try std.testing.expectEqualStrings("\u{201c}Bing", "\u{201c}Bingley.\u{201d}"[0..bold_start("\u{201c}Bingley.\u{201d}")]);
    try std.testing.expectEqualStrings("caf", "caf\u{e9}s"[0..bold_start("caf\u{e9}s")]);
    try std.testing.expectEqual(@as(usize, 0), bold_start("\u{2014}"));
}
