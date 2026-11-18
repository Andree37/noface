//! Glyph cache and page layout for 8-bit grayscale pages.
const std = @import("std");
const assert = std.debug.assert;
const Font = @import("../gfx/font.zig").Font;
const Page = @import("../gfx/page.zig").Page;
const book_model = @import("../model/book.zig");
const Paragraph = @import("../model/book.zig").Paragraph;
const hyphen = @import("hyphen.zig");

/// Where a note reference landed on a page.
pub const Hit = struct { x: i32, y: i32, w: i32, h: i32, target: u32 };

const mark_shade = 0xe4; // Very faint, so highlighted text reads like any other

/// The most words on one line.
const max_words = 96;

comptime {
    // Pure black and white turns a highlight's shading white, not into a black band
    assert(mark_shade >= 128);
    assert(mark_shade < 0xff); // Yet still a shade on white paper
    assert(max_words > 1);
}

fn is_marked(marks: []const book_model.Mark, para: u32, start: u32, end: u32) bool {
    assert(start <= end);
    for (marks) |m| {
        if (m.para == para and start < m.end and end > m.start) return true;
    }
    return false;
}

pub const Hits = struct {
    items: [32]Hit = undefined,
    len: u32 = 0,
    words: [1024]book_model.Word = undefined,
    word_count: u32 = 0,
    pictures: [16]Hit = undefined, // Where each picture sits; target is its paragraph
    picture_count: u32 = 0,

    pub fn clear(h: *Hits) void {
        assert(h.len <= h.items.len);
        assert(h.word_count <= h.words.len);
        assert(h.picture_count <= h.pictures.len);
        h.len = 0;
        h.word_count = 0;
        h.picture_count = 0;
    }

    fn add_picture(h: *Hits, hit: Hit) void {
        assert(h.picture_count <= h.pictures.len);
        assert(hit.w > 0); // `image_size` makes every picture at least a pixel
        assert(hit.h > 0);
        if (h.picture_count == h.pictures.len) return;
        h.pictures[h.picture_count] = hit;
        h.picture_count += 1;
    }

    /// The paragraph of the picture at a point, if there's one there.
    pub fn picture_at(h: *const Hits, x: i32, y: i32) ?u32 {
        assert(h.picture_count <= h.pictures.len);
        for (h.pictures[0..h.picture_count]) |r| {
            if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return r.target;
        }
        return null;
    }

    fn add_word(h: *Hits, word: book_model.Word) void {
        assert(h.word_count <= h.words.len);
        assert(word.start <= word.end);
        if (h.word_count == h.words.len) return;
        h.words[h.word_count] = word;
        h.word_count += 1;
    }

    fn add(h: *Hits, hit: Hit) void {
        assert(h.len <= h.items.len);
        assert(hit.w > 0); // A mark is at least a pixel wide, to be found
        if (h.len == h.items.len) return;
        h.items[h.len] = hit;
        h.len += 1;
    }

    /// Finds the reference at a tap, with room for how small they are.
    pub fn find(h: *const Hits, x: i32, y: i32) ?u32 {
        assert(h.len <= h.items.len);
        const pad = 30;
        for (h.items[0..h.len]) |r| {
            const across = x >= r.x - pad and x < r.x + r.w + pad;
            if (across and y >= r.y - pad and y < r.y + r.h + pad) return r.target;
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
    draw: *const fn (
        ctx: *anyopaque,
        page: Page,
        image: book_model.Image,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) void,
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

/// Whether `para`, `byte` has reached the stop position.
fn at_stop(l: *const Layout, para: u32, byte: u32) bool {
    const st = l.stop orelse return false;
    const here = book_model.Pos{ .para = para, .byte = byte };
    return !here.is_before(st);
}

const Link = book_model.Link;

/// The link in `links` that refers to a note and overlaps `len` bytes from `start`.
fn find_reference(links: []const Link, paras: []const Paragraph, start: u32, len: u32) ?Link {
    for (links) |link| {
        if (link.end <= start or link.start >= start + len) continue;
        if (link.target < paras.len and paras[link.target].note_start) return link;
    }
    return null;
}

fn face(l: *const Layout, base: *Font, bold: bool, italic: bool, size: u8) !*Font {
    assert(size < book_model.size_scales.len); // The model snaps sizes to these steps
    const f = l.faces orelse return base;
    return f.pick(f.ctx, bold, italic, size);
}

/// How many bytes of `word` are set bold with bold word starts: anything before its
/// first letter, then half its letters (one for words of up to three), rounded up.
pub fn bold_start(word: []const u8) u32 {
    var letters: u32 = 0;
    var it = (std.unicode.Utf8View.init(word) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (is_letter(cp)) letters += 1;
    }
    if (letters == 0) return 0;
    const want = if (letters <= 3) 1 else (letters + 1) / 2;
    assert(want > 0);
    assert(want <= letters);
    var seen: u32 = 0;
    it = (std.unicode.Utf8View.init(word) catch return 0).iterator();
    while (it.nextCodepoint()) |cp| {
        if (is_letter(cp)) seen += 1;
        if (seen == want) break;
    }
    // Just past the last letter set bold: as many as wanted were seen before the end
    assert(seen == want);
    return @intCast(it.i);
}

/// Letters and digits; beyond ASCII, anything but Latin-1's symbols and the general
/// punctuation block (curly quotes, dashes, ellipses).
fn is_letter(cp: u21) bool {
    assert(cp <= 0x10ffff); // Decoded from UTF-8, so a code point Unicode has room for
    if (cp < 128) return std.ascii.isAlphanumeric(@intCast(cp));
    return cp > 0xbf and !(cp >= 0x2000 and cp <= 0x206f);
}

/// The bold face for a word's start with bold word starts on, or null: off, or the
/// word is bold already, or it's the rest of a word broken at the line before.
fn start_face(
    l: *const Layout,
    base: *Font,
    p: *const Paragraph,
    wf: *Font,
    word_start: u32,
) !?*Font {
    assert(word_start < p.text.len);
    assert(p.image == null); // Only text has faces
    if (!l.bold_starts) return null;
    const text = p.text;
    if (word_start > 0 and text[word_start - 1] != ' ' and text[word_start - 1] != '\n') {
        return null;
    }
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
    assert(k <= word.len);
    return try b.measure(word[0..k]) + try wf.measure(word[k..]);
}

fn draw_word(p: Page, wf: *Font, start: ?*Font, x: f32, y: i32, word: []const u8) !void {
    const b = start orelse return wf.draw(p, x, y, word);
    const k = bold_start(word);
    assert(k <= word.len);
    try b.draw(p, x, y, word[0..k]);
    try wf.draw(p, x + try b.measure(word[0..k]), y, word[k..]);
}

/// Bold and italic for a word: its paragraph's, plus any run it starts in.
fn word_face(l: *const Layout, base: *Font, p: *const Paragraph, word_start: u32) !*Font {
    assert(word_start < p.text.len);
    assert(p.image == null); // Only text has faces
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

/// A picture's size on the page, in pixels.
pub const PictureSize = struct { w: i32, h: i32 };

/// A picture's size on the page: as large as fits, but at most twice its own size,
/// so small ornaments don't turn into blocks.
pub fn image_size(img: book_model.Image, max_w: f32, max_h: f32) PictureSize {
    assert(max_w > 0);
    assert(max_h > 0);
    // The book readers keep only pictures with a size
    assert(img.width > 0);
    assert(img.height > 0);
    const w: f32 = @floatFromInt(img.width);
    const h: f32 = @floatFromInt(img.height);
    const scale = @min(@min(max_w / w, max_h / h), 2.0);
    return .{
        .w = @max(1, @as(i32, @intFromFloat(w * scale))),
        .h = @max(1, @as(i32, @intFromFloat(h * scale))),
    };
}

fn space_lines(tenths: u8, base: *Font) i32 {
    assert(base.line_height > 0);
    const lines = @divTrunc(@as(i32, tenths) * base.line_height, 10);
    assert(lines >= 0);
    return lines;
}

/// Where a picture `w` wide starts: centred in the text column.
fn picture_left(l: *const Layout, line_width: f32, w: i32) u32 {
    assert(line_width > 0);
    assert(w > 0);
    return @intCast(l.margin_x + @divTrunc(@as(i32, @intFromFloat(line_width)) - w, 2));
}

/// Lays out one page from `start`, drawing it into `maybe_page` when given (else only
/// measuring, to find where pages break), and returns where the next page starts.
pub fn layout_page(
    font: *Font,
    maybe_page: ?Page,
    geometry: Page,
    paras: []const Paragraph,
    start: book_model.Pos,
    l: *const Layout,
    hits: ?*Hits,
) !book_model.Pos {
    if (maybe_page) |p| @memset(p.buf, 0xff);
    const next = try layout_page_paragraphs(font, maybe_page, geometry, paras, start, l, hits);
    // A page never ends before it starts
    assert(next.para >= start.para);
    if (next.para == start.para) assert(next.byte >= start.byte);
    return next;
}

/// Sets paragraphs from `start` until the page is full, or the stop or the end is
/// reached, and returns where that is.
fn layout_page_paragraphs(
    font: *Font,
    maybe_page: ?Page,
    geometry: Page,
    paras: []const Paragraph,
    start: book_model.Pos,
    l: *const Layout,
    hits: ?*Hits,
) !book_model.Pos {
    const line_width: f32 = @floatFromInt(@as(i32, @intCast(geometry.width)) - 2 * l.margin_x);
    const bottom = @as(i32, @intCast(geometry.height)) - l.margin_bottom;
    // The page leaves room for text: these come from our own settings
    assert(line_width > 0);
    assert(bottom > l.margin_top);
    var top = l.margin_top; // Top of the next line
    var pos = start;

    while (pos.para < paras.len) : ({
        pos.para += 1;
        pos.byte = 0;
    }) {
        if (at_stop(l, @intCast(pos.para), @intCast(pos.byte))) return pos;
        const para = &paras[pos.para];
        if (para.note) continue; // Notes open in a panel, not in the text
        if (para.image) |img| {
            const size = image_size(img, line_width, @floatFromInt(bottom - l.margin_top));
            // A picture never splits: it starts the next page unless it opens this one
            if (top + size.h > bottom + font.ascent and top > l.margin_top) {
                return .{ .para = pos.para, .byte = 0 };
            }
            if (maybe_page) |p| {
                draw_picture(p, l, img, line_width, size, top, @intCast(pos.para), hits);
            }
            top += size.h + @divTrunc(font.line_height, 2);
            continue;
        }
        const placed = try layout_page_lines(&.{
            .font = font,
            .maybe_page = maybe_page,
            .paras = paras,
            .para_index = @intCast(pos.para),
            .byte = @intCast(pos.byte),
            .l = l,
            .hits = hits,
            .line_width = line_width,
            .bottom = bottom,
        }, &top);
        if (placed) |byte| return .{ .para = pos.para, .byte = byte };
    }
    return pos;
}

/// What setting one paragraph's lines needs to know about the page.
const Lines = struct {
    font: *Font,
    maybe_page: ?Page,
    paras: []const Paragraph,
    para_index: u32,
    byte: u32, // Where in the paragraph to start
    l: *const Layout,
    hits: ?*Hits,
    line_width: f32,
    bottom: i32,
};

/// Sets the lines of one paragraph from `lines.byte`, moving `top` down past them. Null
/// when all of it fit; else the byte the next page starts at.
fn layout_page_lines(lines: *const Lines, top: *i32) !?u32 {
    const l = lines.l;
    const para = &lines.paras[lines.para_index];
    assert(para.image == null);
    assert(!para.note);
    const look = para.look;
    const font = lines.font;
    const pf = try face(l, font, look.bold, look.italic, look.size); // Sets the line height
    const style = ParagraphStyle.of(look, l);
    const space = try pf.measure(" ");
    const text = para.text;
    var i = lines.byte;
    var indent: f32 = if (i == 0 and style.plain) l.indent else 0;
    if (i == 0 and top.* > l.margin_top) top.* += space_lines(look.space_before, font);

    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\n')) i += 1;
        if (i >= text.len) break;
        if (at_stop(l, lines.para_index, i)) return i;
        const avail = lines.line_width - indent;
        const line = try fill_line_to_stop(l, font, lines, i, avail, style.plain, space);
        const baseline = top.* + pf.ascent;
        if (baseline > lines.bottom) return i; // The page is full
        const gap = line_gap(&line, style.justify, avail, space);
        const used = line.width() + gap * @as(f32, @floatFromInt(@max(line.n, 1) - 1));
        const left = line_left(l, look.alignment, indent, avail, used);
        if (lines.maybe_page) |p| {
            try draw_line(p, l, lines.paras, lines.para_index, &line, &.{
                .left = left,
                .baseline = baseline,
                .gap = gap,
                .pf = pf,
                .hits = lines.hits,
            });
        }
        top.* += pf.line_height;
        assert(line.next > i); // Every line moves on
        i = line.next;
        indent = if (line.ends_para and style.plain) l.indent else 0;
    }
    top.* += space_lines(look.space_after, font);
    return null;
}

/// The space between a line's words: justified lines spread them, up to a limit;
/// others keep a space.
fn line_gap(line: *const Line, justify: bool, avail: f32, space: f32) f32 {
    assert(line.n > 0);
    assert(avail > 0);
    if (justify and !line.ends_para and line.n > 1) {
        return @min((avail - line.width()) / @as(f32, @floatFromInt(line.n - 1)), space * 2.5);
    }
    return space;
}

/// Where a line `used` wide starts, by its paragraph's alignment.
fn line_left(
    l: *const Layout,
    alignment: book_model.Look.Alignment,
    indent: f32,
    avail: f32,
    used: f32,
) f32 {
    assert(indent >= 0);
    assert(avail > 0);
    return @as(f32, @floatFromInt(l.margin_x)) + indent + switch (alignment) {
        .center => @max(avail - used, 0) / 2,
        .right => @max(avail - used, 0),
        .auto, .left, .justify => 0,
    };
}

/// How a paragraph's lines are set: `plain` body text is indented and may be
/// hyphenated; `justify`ed lines are spread to the margins.
const ParagraphStyle = struct {
    plain: bool,
    justify: bool,

    fn of(look: book_model.Look, l: *const Layout) ParagraphStyle {
        const body_size = look.size == book_model.normal_size;
        const alignment = look.alignment;
        const style = ParagraphStyle{
            // Headings and centred lines aren't indented
            .plain = body_size and
                (alignment == .auto or alignment == .justify or alignment == .left),
            // Only body text is justified, unless the book asks for it
            .justify = switch (alignment) {
                .auto => l.justify and body_size,
                .justify => true,
                .left, .center, .right => false,
            },
        };
        if (style.plain) assert(body_size);
        if (alignment == .center or alignment == .right) assert(!style.justify);
        return style;
    }
};

/// The line from byte `i` as it falls without a stop, unless its words run past the
/// stop: only then is it cut there, set like a paragraph's last line. A stop where a
/// page breaks anyway so leaves every line as it was, justified and hyphenated.
fn fill_line_to_stop(
    l: *const Layout,
    font: *Font,
    lines: *const Lines,
    i: u32,
    avail: f32,
    plain: bool,
    space: f32,
) !Line {
    const para = &lines.paras[lines.para_index];
    const line = try fill_line(l, font, para, i, @intCast(para.text.len), avail, plain, space);
    const st = l.stop orelse return line;
    // A stop before this line would have ended the page before it
    assert(st.para >= lines.para_index);
    if (st.para > lines.para_index) return line;
    assert(st.byte > i);
    if (line.words_end(para.text) <= st.byte) return line;
    return fill_line(l, font, para, i, st.byte, avail, plain, space);
}

/// The words of one line, as measured, and where the next line starts.
const Line = struct {
    words: [max_words][]const u8 = undefined,
    widths: [max_words]f32 = undefined,
    fonts: [max_words]*Font = undefined,
    starts: [max_words]?*Font = undefined, // Bold word starts' face, per word
    n: u32 = 0,
    next: u32 = 0, // Where the next line starts, in the paragraph's text
    ends_para: bool = false, // Set like a paragraph's last line: not spread
    hyphen_end: bool = false, // The last word is the first part of a broken word

    fn add(line: *Line, word: []const u8, w: f32, wf: *Font, sf: ?*Font) void {
        assert(line.n < max_words);
        assert(!line.hyphen_end); // A broken word ends its line
        line.words[line.n] = word;
        line.widths[line.n] = w;
        line.fonts[line.n] = wf;
        line.starts[line.n] = sf;
        line.n += 1;
    }

    /// Where the line's last word, or the part of it on this line, ends in `text`.
    fn words_end(line: *const Line, text: []const u8) u32 {
        assert(line.n > 0);
        const last = line.words[line.n - 1];
        const end = offset_in(text, last) + @as(u32, @intCast(last.len));
        assert(end <= text.len);
        return end;
    }

    fn width(line: *const Line) f32 {
        assert(line.n <= max_words);
        var total: f32 = 0;
        for (line.widths[0..line.n]) |w| total += w;
        return total;
    }
};

/// The words from byte `i` that fit in `avail`. The word that doesn't fit is
/// hyphenated if part of it fits (in plain text), else left for the next line; a
/// word wider than a whole line (a URL, unspaced CJK) is cut.
fn fill_line(
    l: *const Layout,
    font: *Font,
    para: *const Paragraph,
    i: u32,
    limit: u32,
    avail: f32,
    plain: bool,
    space: f32,
) !Line {
    assert(i < limit);
    assert(avail > 0); // A cut word keeps at least a letter
    const text = para.text;
    var line = Line{};
    var used: f32 = 0;
    var j = i;
    while (line.n < max_words) {
        if (j >= limit) {
            line.ends_para = true; // Ends early at the stop
            break;
        }
        const end = fill_line_word_end(text, j, limit);
        const word = text[j..end];
        const wf = try word_face(l, font, para, j);
        const sf = try start_face(l, font, para, wf, j);
        const w = try word_width(wf, sf, word);
        if (line.n == 0 and w > avail) {
            const part = word[0..try wf.fit(word, avail)];
            line.add(part, try wf.measure(part), wf, null);
            j += @intCast(part.len);
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
    assert(line.n > 0);
    return line;
}

/// Where the word from byte `start` ends: at a space, a line break, `limit` or the
/// text's end.
fn fill_line_word_end(text: []const u8, start: u32, limit: u32) u32 {
    assert(start < text.len);
    assert(start < limit);
    var end = start;
    while (end < limit and end < text.len) : (end += 1) {
        if (text[end] == ' ' or text[end] == '\n') break;
    }
    assert(end <= text.len);
    return end;
}

/// The longest first part of `word` (by its hyphenation points) that fits in `room`,
/// with its width, the hyphen included where one is drawn.
fn hyphenated(
    l: *const Layout,
    wf: *Font,
    sf: ?*Font,
    word: []const u8,
    room: f32,
) !?struct { at: u32, hyphen: bool, width: f32 } {
    assert(room > 0);
    var found: [24]hyphen.Break = undefined;
    const breaks = hyphen.breaks(l.hyphenator, word, &found);
    var k = breaks.len;
    while (k > 0) {
        k -= 1;
        const b = breaks[k];
        assert(b.at < word.len); // A part of the word, never all of it
        const hyphen_width = if (b.hyphen) try wf.measure("-") else 0;
        const w = try word_width(wf, sf, word[0..b.at]) + hyphen_width;
        if (w <= room) return .{ .at = b.at, .hyphen = b.hyphen, .width = w };
    }
    return null;
}

/// Where and how a line is drawn, as `layout_page_lines` placed it.
const LinePlace = struct {
    left: f32,
    baseline: i32,
    gap: f32, // Between words
    pf: *Font, // The paragraph's font, which sets the line height
    hits: ?*Hits,
};

/// Draws a line's words from `left`, `gap` apart: a highlight's shading under them,
/// their tap areas, note marks raised and small, and the hyphen of a broken word.
fn draw_line(
    p: Page,
    l: *const Layout,
    paras: []const Paragraph,
    para_index: u32,
    line: *const Line,
    place: *const LinePlace,
) !void {
    assert(para_index < paras.len);
    assert(line.n > 0);
    const para = &paras[para_index];
    const pf = place.pf;
    var x = place.left;
    for (0..line.n) |k| {
        const word = line.words[k];
        const w = line.widths[k];
        const wf = line.fonts[k];
        const word_start = offset_in(para.text, word);
        const word_end: u32 = @intCast(word_start + word.len);
        const line_top = place.baseline - pf.ascent;
        if (is_marked(l.marks, para_index, word_start, word_end)) {
            // Reaches into the gap only when the next word is marked too, so a marked
            // phrase reads as one band and nothing past its last word is shaded
            const joined = k + 1 < line.n and
                word_marked(l.marks, para.text, para_index, line.words[k + 1]);
            const band_width: u32 = @intFromFloat(if (joined) w + place.gap else w);
            const band_height: u32 = @intCast(pf.line_height - 8);
            const band_top: u32 = @intCast(line_top + 4);
            p.fill_rect(@intFromFloat(x), band_top, band_width, band_height, mark_shade);
        }
        if (place.hits) |h| h.add_word(.{
            .x = @intFromFloat(x),
            .y = line_top,
            .w = @intFromFloat(w),
            .h = pf.line_height,
            .para = para_index,
            .start = word_start,
            .end = word_end,
        });
        var shrink: f32 = 0; // A small mark takes less room than was measured
        if (find_reference(para.links, paras, word_start, @intCast(word.len))) |r| {
            shrink = try draw_with_mark(p, l, wf, word, word_start, r, x, place);
        } else {
            try draw_word(p, wf, line.starts[k], x, place.baseline, word);
        }
        if (line.hyphen_end and k + 1 == line.n) {
            const hyphen_x = x + try word_width(wf, line.starts[k], word);
            try wf.draw(p, hyphen_x, place.baseline, "-");
        }
        x += w + place.gap - shrink;
    }
}

/// Where `word`, a slice of `text`, starts in it.
fn offset_in(text: []const u8, word: []const u8) u32 {
    assert(@intFromPtr(word.ptr) >= @intFromPtr(text.ptr));
    const start = @intFromPtr(word.ptr) - @intFromPtr(text.ptr);
    assert(start + word.len <= text.len);
    return @intCast(start);
}

/// Whether a highlight covers any of `word`, a slice of paragraph `para_index`'s `text`.
fn word_marked(
    marks: []const book_model.Mark,
    text: []const u8,
    para_index: u32,
    word: []const u8,
) bool {
    const start = offset_in(text, word);
    return is_marked(marks, para_index, start, start + @as(u32, @intCast(word.len)));
}

/// A word holding a note's reference: the mark raised and small, like a printed one,
/// and tappable. Returns how much narrower the mark is than measured.
fn draw_with_mark(
    p: Page,
    l: *const Layout,
    wf: *Font,
    word: []const u8,
    word_start: u32,
    r: Link,
    x: f32,
    place: *const LinePlace,
) !f32 {
    const small = l.reference orelse wf;
    const pf = place.pf;
    const baseline = place.baseline;
    // The mark's bytes in the word: `find_reference` found it overlapping
    const a = @max(r.start, word_start) - word_start;
    const b = @min(r.end, word_start + word.len) - word_start;
    assert(a <= word.len);
    assert(b <= word.len);
    try wf.draw(p, x, baseline, word[0..a]);
    const mark_x = x + try wf.measure(word[0..a]);
    try small.draw(p, mark_x, baseline - @divTrunc(pf.line_height, 3), word[a..b]);
    const mark_w = try small.measure(word[a..b]);
    try wf.draw(p, mark_x + mark_w, baseline, word[b..]);
    if (place.hits) |h| h.add(.{
        .x = @intFromFloat(mark_x),
        .y = baseline - pf.ascent,
        .w = @intFromFloat(@max(mark_w, 1)),
        .h = pf.line_height,
        .target = r.target,
    });
    return try wf.measure(word[a..b]) - mark_w;
}

fn draw_picture(
    p: Page,
    l: *const Layout,
    img: book_model.Image,
    line_width: f32,
    size: PictureSize,
    top: i32,
    para_index: u32,
    hits: ?*Hits,
) void {
    assert(size.w > 0);
    assert(size.h > 0);
    const x = picture_left(l, line_width, size.w);
    if (l.images) |im| {
        im.draw(im.ctx, p, img, x, @intCast(top), @intCast(size.w), @intCast(size.h));
    }
    if (hits) |h| h.add_picture(.{
        .x = @intCast(x),
        .y = @intCast(top),
        .w = size.w,
        .h = size.h,
        .target = para_index,
    });
}

pub fn render_page(
    font: *Font,
    page: Page,
    paras: []const Paragraph,
    start: book_model.Pos,
    l: Layout,
    hits: ?*Hits,
) !book_model.Pos {
    assert(page.buf.len > 0); // Drawn into, unlike a page only measured
    assert(page.width <= page.stride);
    return layout_page(font, page, page, paras, start, &l, hits);
}

/// Hard black and white, for waveforms that cannot show gray.
pub fn threshold(src: []const u8, dst: []u8) void {
    assert(src.len == dst.len);
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
    const quoted = "\u{201c}Bingley.\u{201d}";
    try std.testing.expectEqualStrings("\u{201c}Bing", quoted[0..bold_start(quoted)]);
    try std.testing.expectEqualStrings("caf", "caf\u{e9}s"[0..bold_start("caf\u{e9}s")]);
    try std.testing.expectEqual(@as(u32, 0), bold_start("\u{2014}"));
}

/// One page drawn from `start` on a fresh page, its words' places and where it ends.
const TestPage = struct {
    pixels: [test_width * test_height]u8 = undefined,
    hits: Hits = .{},
    next: book_model.Pos = .{},

    const test_width = 600;
    const test_height = 420;

    fn draw(
        out: *TestPage,
        font: *Font,
        paras: []const Paragraph,
        start: book_model.Pos,
        l: Layout,
    ) !void {
        const page = Page{
            .buf = &out.pixels,
            .width = test_width,
            .height = test_height,
            .stride = test_width,
        };
        out.hits.clear();
        out.next = try render_page(font, page, paras, start, l, &out.hits);
    }

    fn expect_same(a: *const TestPage, b: *const TestPage) !void {
        try std.testing.expectEqual(a.next, b.next);
        try std.testing.expectEqualSlices(u8, &a.pixels, &b.pixels);
        try std.testing.expectEqual(a.hits.word_count, b.hits.word_count);
        const count = a.hits.word_count;
        const Word = book_model.Word;
        try std.testing.expectEqualSlices(Word, a.hits.words[0..count], b.hits.words[0..count]);
    }
};

/// Long words, so that pages often end on a word broken across them.
const test_text =
    "Notwithstanding the extraordinary circumstances, the international " ++
    "representatives demonstrated unquestionable responsibility, understanding " ++
    "the incomprehensible characteristics of their constitutional arrangements. " ++
    "Nevertheless, communication between neighbourhoods remained uncharacteristically " ++
    "straightforward, and the administration acknowledged its disproportionate " ++
    "contributions to the establishment of interdisciplinary institutions.";

test "a stop at a page's own end draws that page exactly as it falls without one" {
    // Saved page breaks are drawn with the next page's start as the stop, so a page
    // whose break fell naturally must keep its justified last line and its hyphen
    var font = try Font.init(@embedFile("../testdata/fonts/Go-Regular.ttf"), 30, 1.2);
    var english = try hyphen.Hyphenator.init(std.testing.allocator, .english);
    defer english.deinit();
    const paras = [_]Paragraph{
        .{ .text = test_text ++ " " ++ test_text },
        .{ .text = test_text },
    };
    const plain = Layout{
        .margin_x = 40,
        .margin_top = 30,
        .margin_bottom = 30,
        .indent = 40,
        .hyphenator = &english,
    };
    const free = try std.testing.allocator.create(TestPage);
    defer std.testing.allocator.destroy(free);
    free.* = .{};
    const stopped = try std.testing.allocator.create(TestPage);
    defer std.testing.allocator.destroy(stopped);
    stopped.* = .{};
    var start = book_model.Pos{};
    var broken_words: u32 = 0; // Pages that end inside a word, hyphenated
    var mid_paragraph: u32 = 0;
    for (0..64) |_| {
        if (start.para >= paras.len) break;
        try free.draw(&font, &paras, start, plain);
        var with_stop = plain;
        with_stop.stop = free.next;
        try stopped.draw(&font, &paras, start, with_stop);
        try TestPage.expect_same(free, stopped);
        const next = free.next;
        if (next.para < paras.len and next.byte > 0) {
            mid_paragraph += 1;
            if (paras[next.para].text[next.byte - 1] != ' ') broken_words += 1;
        }
        start = next;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(mid_paragraph > 0);
    try std.testing.expect(broken_words > 0);
}

test "a stop inside a page ends it exactly there, the lines above as they were" {
    // The pages before a reader's place are laid out to end at it, which is rarely
    // where a page would break; drawn with that stop, the page shows nothing past it
    var font = try Font.init(@embedFile("../testdata/fonts/Go-Regular.ttf"), 30, 1.2);
    var english = try hyphen.Hyphenator.init(std.testing.allocator, .english);
    defer english.deinit();
    const paras = [_]Paragraph{.{ .text = test_text }};
    const plain = Layout{
        .margin_x = 40,
        .margin_top = 30,
        .margin_bottom = 30,
        .indent = 40,
        .hyphenator = &english,
    };
    const free = try std.testing.allocator.create(TestPage);
    defer std.testing.allocator.destroy(free);
    free.* = .{};
    const stopped = try std.testing.allocator.create(TestPage);
    defer std.testing.allocator.destroy(stopped);
    stopped.* = .{};
    try free.draw(&font, &paras, .{}, plain);
    const count = free.hits.word_count;
    try std.testing.expect(count > 8);
    const middle = free.hits.words[count / 2];
    // At a word's start, and inside a word
    for ([_]u32{ middle.start, middle.start + 3 }) |byte| {
        var with_stop = plain;
        with_stop.stop = .{ .para = 0, .byte = byte };
        try stopped.draw(&font, &paras, .{}, with_stop);
        try std.testing.expectEqual(book_model.Pos{ .para = 0, .byte = byte }, stopped.next);
        const words = stopped.hits.words[0..stopped.hits.word_count];
        try std.testing.expect(words.len > 0);
        for (words) |w| try std.testing.expect(w.end <= byte);
        // Every line above the stop's is drawn as on the page without it
        for (words, free.hits.words[0..words.len]) |w, f| {
            if (w.y < middle.y) try std.testing.expectEqual(f, w);
        }
    }
}

test "a highlight's shading spans the gap between its words, and none after its last" {
    var font = try Font.init(@embedFile("../testdata/fonts/Go-Regular.ttf"), 30, 1.2);
    const paras = [_]Paragraph{.{ .text = test_text }};
    const out = try std.testing.allocator.create(TestPage);
    defer std.testing.allocator.destroy(out);
    out.* = .{};
    // "Notwithstanding the": its first word alone, then both
    for ([_]u32{ 15, 19 }, [_]u8{ 0xff, mark_shade }) |mark_end, in_gap| {
        const marks = [_]book_model.Mark{.{ .para = 0, .start = 0, .end = mark_end }};
        const l = Layout{
            .margin_x = 40,
            .margin_top = 30,
            .margin_bottom = 30,
            .indent = 0,
            .marks = &marks,
        };
        try out.draw(&font, &paras, .{}, l);
        const first = out.hits.words[0];
        const second = out.hits.words[1];
        try std.testing.expectEqual(@as(u32, 15), first.end);
        try std.testing.expect(second.x > first.x + first.w + 4); // A gap to look into
        const y: u32 = @intCast(first.y + @divTrunc(first.h, 2));
        const x: u32 = @intCast(first.x + first.w + 2);
        try std.testing.expectEqual(in_gap, out.pixels[y * TestPage.test_width + x]);
    }
}
