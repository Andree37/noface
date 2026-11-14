//! CFF outlines, the kind OpenType fonts (.otf) keep their glyphs in: the font's
//! indexes and dictionaries, and the Type 2 charstrings each glyph is drawn by.
//!
//! A port of stb_truetype's reader, so glyphs come out exactly as it drew them,
//! except that every read stays inside the font: a damaged font draws blank glyphs,
//! never past its end. Hinting is ignored, as stb_truetype ignored it.
const std = @import("std");
const assert = std.debug.assert;
const Vertex = @import("outline.zig").Vertex;

/// A stretch of the font: where a reader is in it. Reading past its end gives zeros.
pub const Buffer = struct {
    data: []const u8 = &.{},
    cursor: u32 = 0,

    fn size(b: *const Buffer) u32 {
        assert(b.data.len <= std.math.maxInt(u32));
        assert(b.cursor <= b.data.len);
        return @intCast(b.data.len);
    }

    fn get8(b: *Buffer) u8 {
        assert(b.cursor <= b.data.len);
        if (b.cursor >= b.data.len) return 0;
        const byte = b.data[b.cursor];
        b.cursor += 1;
        assert(b.cursor <= b.data.len);
        return byte;
    }

    fn peek8(b: *const Buffer) u8 {
        assert(b.cursor <= b.data.len);
        assert(b.data.len <= std.math.maxInt(u32));
        if (b.cursor >= b.data.len) return 0;
        return b.data[b.cursor];
    }

    /// Moves to `offset`, or to the end when it lies outside.
    fn seek(b: *Buffer, offset: i64) void {
        assert(b.data.len <= std.math.maxInt(u32));
        const inside = offset >= 0 and offset <= b.data.len;
        b.cursor = if (inside) @intCast(offset) else b.size();
        assert(b.cursor <= b.data.len);
    }

    fn skip(b: *Buffer, count: i64) void {
        assert(b.cursor <= b.data.len);
        b.seek(@as(i64, b.cursor) + count);
        assert(b.cursor <= b.data.len);
    }

    /// A big-endian number of `n` bytes, 1 to 4 (0 for any other count).
    fn get(b: *Buffer, n: u32) u32 {
        assert(b.cursor <= b.data.len);
        if (n < 1 or n > 4) return 0;
        var value: u32 = 0;
        for (0..n) |_| value = value << 8 | b.get8();
        assert(n == 4 or value >> @intCast(8 * n) == 0);
        return value;
    }

    /// The part of the buffer from `offset`, `length` long: empty if it doesn't fit.
    fn range(b: *const Buffer, offset: i64, length: i64) Buffer {
        assert(b.data.len <= std.math.maxInt(u32));
        if (offset < 0 or length < 0 or offset > b.data.len) return .{};
        if (length > @as(i64, @intCast(b.data.len)) - offset) return .{};
        const start: u32 = @intCast(offset);
        const part: Buffer = .{ .data = b.data[start..][0..@intCast(length)] };
        assert(part.data.len == length);
        return part;
    }
};

/// Reads an INDEX at the cursor, and returns all of it (count, offsets and data).
fn get_index(b: *Buffer) Buffer {
    assert(b.cursor <= b.data.len);
    const start = b.cursor;
    const count = b.get(2);
    if (count > 0) {
        const offset_size = b.get8();
        b.skip(@as(i64, offset_size) * count);
        b.skip(@as(i64, b.get(offset_size)) - 1);
    }
    assert(b.cursor >= start);
    return b.range(start, b.cursor - start);
}

/// An integer operand of a dictionary or charstring, as the C code read it: a
/// 32-bit pattern, which may stand for a negative number.
fn read_int(b: *Buffer) u32 {
    const b0: i32 = b.get8();
    assert(b0 >= 0);
    assert(b0 <= 255);
    if (b0 >= 32 and b0 <= 246) return @bitCast(b0 - 139);
    if (b0 >= 247 and b0 <= 250) return @bitCast((b0 - 247) * 256 + @as(i32, b.get8()) + 108);
    if (b0 >= 251 and b0 <= 254) return @bitCast(-(b0 - 251) * 256 - @as(i32, b.get8()) - 108);
    if (b0 == 28) return b.get(2);
    if (b0 == 29) return b.get(4);
    // A reserved byte: no number
    return 0;
}

fn skip_operand(b: *Buffer) void {
    const b0 = b.peek8();
    assert(b0 >= 28);
    if (b0 != 30) {
        _ = read_int(b);
        return;
    }
    // A real number: nibbles up to one that ends it
    b.skip(1);
    while (b.cursor < b.data.len) {
        const v = b.get8();
        if (v & 0xf == 0xf or v >> 4 == 0xf) break;
    }
    assert(b.cursor <= b.data.len);
}

/// The operands of the dictionary entry `key`, or none.
fn dict_get(b: *Buffer, key: u32) Buffer {
    // Operators are a byte, or 12 and a byte
    assert(key <= 0x1ff);
    b.seek(0);
    // Each entry takes at least its operator's byte
    while (b.cursor < b.data.len) {
        const start = b.cursor;
        // Each operand takes at least a byte; past the end, `peek8` gives 0
        while (b.peek8() >= 28) skip_operand(b);
        const end = b.cursor;
        var operator: u32 = b.get8();
        if (operator == 12) operator = @as(u32, b.get8()) | 0x100;
        if (operator == key) return b.range(start, end - start);
    }
    assert(b.cursor == b.data.len);
    return b.range(0, 0);
}

/// Up to `out.len` integer operands of the entry `key`; those it lacks are left be.
fn dict_get_ints(b: *Buffer, key: u32, out: []u32) void {
    assert(out.len >= 1);
    assert(out.len <= 2);
    var operands = dict_get(b, key);
    for (out) |*value| {
        if (operands.cursor >= operands.data.len) break;
        value.* = read_int(&operands);
    }
}

fn index_count(b: *Buffer) u32 {
    b.seek(0);
    assert(b.cursor == 0);
    const count = b.get(2);
    assert(count <= std.math.maxInt(u16));
    return count;
}

/// Item `i` of an INDEX, or nothing if it has no such item.
fn index_get(index: Buffer, i: u32) Buffer {
    var b = index;
    b.seek(0);
    const count = b.get(2);
    const offset_size = b.get8();
    if (i >= count or offset_size < 1 or offset_size > 4) return .{};
    b.skip(@as(i64, i) * offset_size);
    const start: i64 = b.get(offset_size);
    const end: i64 = b.get(offset_size);
    const data_start = 2 + (@as(i64, count) + 1) * offset_size;
    assert(data_start >= 3);
    const item = b.range(data_start + start, end - start);
    assert(item.data.len <= index.data.len);
    return item;
}

/// The local subroutines a font dictionary's private dictionary points to.
fn get_subrs(cff: Buffer, font_dict: Buffer) Buffer {
    assert(cff.data.len <= std.math.maxInt(u32));
    var dict = font_dict;
    var private: [2]u32 = .{ 0, 0 };
    dict_get_ints(&dict, 18, &private);
    if (private[0] == 0 or private[1] == 0) return .{};
    var whole = cff;
    var private_dict = whole.range(private[1], private[0]);
    var subrs_offset = [1]u32{0};
    dict_get_ints(&private_dict, 19, &subrs_offset);
    if (subrs_offset[0] == 0) return .{};
    whole.seek(@as(i64, private[1]) + subrs_offset[0]);
    const subrs = get_index(&whole);
    assert(subrs.data.len <= cff.data.len);
    return subrs;
}

/// What a CFF font's glyphs are drawn from.
pub const Font = struct {
    /// The CFF table, to the end of the file, as stb_truetype read it.
    cff: Buffer = .{},
    charstrings: Buffer = .{},
    global_subrs: Buffer = .{},
    subrs: Buffer = .{},
    font_dicts: Buffer = .{},
    fd_select: Buffer = .{},
};

/// Reads the CFF table at `table` of `data`. Null for one stb_truetype turned down.
pub fn init(data: []const u8, table: u32) ?Font {
    assert(data.len <= std.math.maxInt(u32));
    if (table >= data.len) return null;
    var font: Font = .{ .cff = .{ .data = data[table..] } };
    var b = font.cff;
    b.skip(2);
    b.seek(b.get8()); // The header's size
    _ = get_index(&b); // Names
    const top_dict_index = get_index(&b);
    var top_dict = index_get(top_dict_index, 0);
    _ = get_index(&b); // Strings
    font.global_subrs = get_index(&b);
    var charstrings = [1]u32{0};
    var charstring_type = [1]u32{2};
    var fd_array = [1]u32{0};
    var fd_select = [1]u32{0};
    dict_get_ints(&top_dict, 17, &charstrings);
    dict_get_ints(&top_dict, 0x100 | 6, &charstring_type);
    dict_get_ints(&top_dict, 0x100 | 36, &fd_array);
    dict_get_ints(&top_dict, 0x100 | 37, &fd_select);
    font.subrs = get_subrs(b, top_dict);
    // Type 2 charstrings only
    if (charstring_type[0] != 2) return null;
    if (charstrings[0] == 0) return null;
    if (fd_array[0] != 0) {
        // A CID font: each glyph picks its font dictionary
        if (fd_select[0] == 0) return null;
        b.seek(fd_array[0]);
        font.font_dicts = get_index(&b);
        font.fd_select = b.range(fd_select[0], @as(i64, b.size()) - fd_select[0]);
    }
    b.seek(charstrings[0]);
    font.charstrings = get_index(&b);
    assert(font.cff.data.len > 0);
    return font;
}

/// How many glyphs the font draws.
pub fn glyph_count(font: *const Font) u32 {
    var charstrings = font.charstrings;
    const count = index_count(&charstrings);
    assert(count <= std.math.maxInt(u16));
    assert(font.cff.data.len >= font.charstrings.data.len);
    return count;
}

/// A subroutine by its biased number.
fn get_subr(index: Buffer, n: i32) Buffer {
    var b = index;
    const count = index_count(&b);
    assert(count <= std.math.maxInt(u16));
    const bias: i32 = if (count >= 33900) 32768 else if (count >= 1240) 1131 else 107;
    assert(bias > 0);
    const unbiased = @as(i64, n) + bias;
    if (unbiased < 0 or unbiased >= count) return .{};
    return index_get(index, @intCast(unbiased));
}

/// A CID font's local subroutines for one glyph, from the dictionary it selects.
fn cid_glyph_subrs(font: *const Font, glyph: u32) Buffer {
    assert(font.fd_select.data.len > 0);
    var fd_select = font.fd_select;
    fd_select.seek(0);
    const format = fd_select.get8();
    var selector: ?u32 = null;
    if (format == 0) {
        fd_select.skip(glyph);
        selector = fd_select.get8();
    } else if (format == 3) {
        const ranges = fd_select.get(2);
        var start = fd_select.get(2);
        for (0..ranges) |_| {
            const value = fd_select.get8();
            const end = fd_select.get(2);
            if (glyph >= start and glyph < end) {
                selector = value;
                break;
            }
            start = end;
        }
    }
    assert(fd_select.cursor <= fd_select.data.len);
    const chosen = selector orelse return .{};
    return get_subrs(font.cff, index_get(font.font_dicts, chosen));
}

/// Where a charstring draws to: counting vertices and their bounds, or writing them.
pub const Context = struct {
    bounds: bool,
    started: bool = false,
    first_x: f32 = 0,
    first_y: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    min_x: i32 = 0,
    max_x: i32 = 0,
    min_y: i32 = 0,
    max_y: i32 = 0,
    vertices: []Vertex = &.{},
    vertex_count: u32 = 0,

    fn track(c: *Context, x: i32, y: i32) void {
        assert(c.bounds);
        if (x > c.max_x or !c.started) c.max_x = x;
        if (y > c.max_y or !c.started) c.max_y = y;
        if (x < c.min_x or !c.started) c.min_x = x;
        if (y < c.min_y or !c.started) c.min_y = y;
        c.started = true;
        assert(c.min_x <= c.max_x);
    }

    fn vertex(c: *Context, kind: Vertex.Kind, points: [3][2]i32) void {
        assert(c.vertex_count < std.math.maxInt(u32));
        if (c.bounds) {
            c.track(points[0][0], points[0][1]);
            if (kind == .cubic) {
                c.track(points[1][0], points[1][1]);
                c.track(points[2][0], points[2][1]);
            }
        } else if (c.vertex_count < c.vertices.len) {
            c.vertices[c.vertex_count] = .{
                .kind = kind,
                .x = @truncate(points[0][0]),
                .y = @truncate(points[0][1]),
                .cx = @truncate(points[1][0]),
                .cy = @truncate(points[1][1]),
                .cx1 = @truncate(points[2][0]),
                .cy1 = @truncate(points[2][1]),
            };
        }
        c.vertex_count += 1;
        assert(c.vertex_count > 0);
    }

    fn close_shape(c: *Context) void {
        assert(c.vertex_count <= std.math.maxInt(u32) - 1);
        if (c.first_x != c.x or c.first_y != c.y) {
            c.vertex(.line, .{ .{ to_int(c.first_x), to_int(c.first_y) }, .{ 0, 0 }, .{ 0, 0 } });
        }
        if (c.bounds) assert(c.started or c.vertex_count == 0);
    }

    fn move_to(c: *Context, dx: f32, dy: f32) void {
        c.close_shape();
        c.x += dx;
        c.y += dy;
        c.first_x = c.x;
        c.first_y = c.y;
        c.vertex(.move, .{ .{ to_int(c.x), to_int(c.y) }, .{ 0, 0 }, .{ 0, 0 } });
        assert(c.vertex_count > 0);
        if (c.bounds) assert(c.started);
    }

    fn line_to(c: *Context, dx: f32, dy: f32) void {
        c.x += dx;
        c.y += dy;
        c.vertex(.line, .{ .{ to_int(c.x), to_int(c.y) }, .{ 0, 0 }, .{ 0, 0 } });
        assert(c.vertex_count > 0);
        if (c.bounds) assert(c.started);
    }

    fn curve_to(c: *Context, d: [6]f32) void {
        const cx1 = c.x + d[0];
        const cy1 = c.y + d[1];
        const cx2 = cx1 + d[2];
        const cy2 = cy1 + d[3];
        c.x = cx2 + d[4];
        c.y = cy2 + d[5];
        c.vertex(.cubic, .{
            .{ to_int(c.x), to_int(c.y) },
            .{ to_int(cx1), to_int(cy1) },
            .{ to_int(cx2), to_int(cy2) },
        });
        assert(c.vertex_count > 0);
        if (c.bounds) assert(c.started);
    }
};

/// A coordinate to whole units, toward zero as C converts, held to 32 bits.
fn to_int(x: f32) i32 {
    if (!(x > -2147483648.0)) return if (x < 0) std.math.minInt(i32) else 0;
    if (!(x < 2147483648.0)) return std.math.maxInt(i32);
    const result: i32 = @intFromFloat(x);
    assert(@abs(@as(f32, @floatFromInt(result))) <= @abs(x) + 1);
    assert(result == 0 or (result < 0) == (x < 0));
    return result;
}

/// The most operators one glyph may run, subroutines and all: more is a damaged font
/// looping through its subroutines.
const operators_max = 1 << 20;
const stack_max = 48;
const subr_depth_max = 10;

/// The interpreter's state: the operand stack and where it's reading.
const Machine = struct {
    stack: [stack_max]f32 = undefined,
    sp: u32 = 0,
    in_header: bool = true,
    mask_bits: u32 = 0,
    has_subrs: bool = false,
    subrs: Buffer,
    b: Buffer,
    returns: [subr_depth_max]Buffer = undefined,
    depth: u32 = 0,
};

/// What one operator did: carry on (clearing the stack or not), end the glyph, or
/// fail (a damaged charstring, which stb_truetype drew nothing for).
const Step = enum { clear, keep, done, failed };

/// Runs glyph `glyph`'s charstring into `c`. False for a damaged one.
pub fn run(font: *const Font, glyph: u32, c: *Context) bool {
    var m: Machine = .{ .subrs = font.subrs, .b = index_get(font.charstrings, glyph) };
    assert(m.sp == 0);
    for (0..operators_max) |_| {
        if (m.b.cursor >= m.b.data.len) return false; // No endchar
        const step = run_operator(font, glyph, c, &m);
        switch (step) {
            .clear => m.sp = 0,
            .keep => {},
            .done => return true,
            .failed => return false,
        }
        assert(m.sp <= stack_max);
    }
    return false;
}

fn run_operator(font: *const Font, glyph: u32, c: *Context, m: *Machine) Step {
    assert(m.sp <= stack_max);
    assert(m.depth <= subr_depth_max);

    const b0 = m.b.get8();
    switch (b0) {
        0x13, 0x14 => {
            // Hintmask and cntrmask: an implicit vstem first, then the mask's bytes
            if (m.in_header) m.mask_bits += m.sp / 2;
            m.in_header = false;
            m.b.skip((m.mask_bits + 7) / 8);
            return .clear;
        },
        0x01, 0x03, 0x12, 0x17 => {
            m.mask_bits += m.sp / 2; // Stems: each pair is one more mask bit
            return .clear;
        },
        0x15, 0x04, 0x16 => return move_operator(c, m, b0),
        0x05, 0x06, 0x07, 0x18, 0x19 => return line_operator(c, m, b0),
        0x08, 0x1a, 0x1b, 0x1e, 0x1f => return curve_operator(c, m, b0),
        0x0a, 0x1d => return call_operator(font, glyph, m, b0),
        0x0b => {
            if (m.depth == 0) return .failed;
            m.depth -= 1;
            m.b = m.returns[m.depth];
            return .keep;
        },
        0x0e => {
            c.close_shape();
            return .done;
        },
        0x0c => return flex_operator(c, m),
        else => return push_number(m, b0),
    }
}

fn push_number(m: *Machine, b0: u8) Step {
    assert(m.b.cursor >= 1);
    if (b0 != 255 and b0 != 28 and b0 < 32) return .failed; // Reserved
    var value: f32 = undefined;
    if (b0 == 255) {
        // 16.16 fixed point
        const fixed: i32 = @bitCast(m.b.get(4));
        value = @as(f32, @floatFromInt(fixed)) / 0x10000;
    } else {
        m.b.skip(-1);
        const number: i16 = @bitCast(@as(u16, @truncate(read_int(&m.b))));
        value = @floatFromInt(number);
    }
    if (m.sp >= stack_max) return .failed;
    m.stack[m.sp] = value;
    m.sp += 1;
    assert(m.sp <= stack_max);
    return .keep;
}

fn move_operator(c: *Context, m: *Machine, b0: u8) Step {
    assert(b0 == 0x15 or b0 == 0x04 or b0 == 0x16);
    m.in_header = false;
    const s = m.stack[0..m.sp];
    switch (b0) {
        0x15 => {
            if (s.len < 2) return .failed;
            c.move_to(s[s.len - 2], s[s.len - 1]);
        },
        0x04 => {
            if (s.len < 1) return .failed;
            c.move_to(0, s[s.len - 1]);
        },
        else => {
            if (s.len < 1) return .failed;
            c.move_to(s[s.len - 1], 0);
        },
    }
    assert(!m.in_header);
    return .clear;
}

fn line_operator(c: *Context, m: *Machine, b0: u8) Step {
    const s = m.stack[0..m.sp];
    assert(s.len <= stack_max);
    var i: u32 = 0;
    switch (b0) {
        0x05 => {
            if (s.len < 2) return .failed;
            while (i + 1 < s.len) : (i += 2) c.line_to(s[i], s[i + 1]);
        },
        0x06, 0x07 => {
            // Lines that turn by a right angle each time, starting across or down
            if (s.len < 1) return .failed;
            var across = b0 == 0x06;
            while (i < s.len) : (i += 1) {
                if (across) c.line_to(s[i], 0) else c.line_to(0, s[i]);
                across = !across;
            }
        },
        0x18 => {
            // Curves, then a line
            if (s.len < 8) return .failed;
            while (i + 5 < s.len - 2) : (i += 6) c.curve_to(s[i..][0..6].*);
            if (i + 1 >= s.len) return .failed;
            c.line_to(s[i], s[i + 1]);
        },
        else => {
            // Lines, then a curve
            assert(b0 == 0x19);
            if (s.len < 8) return .failed;
            while (i + 1 < s.len - 6) : (i += 2) c.line_to(s[i], s[i + 1]);
            if (i + 5 >= s.len) return .failed;
            c.curve_to(s[i..][0..6].*);
        },
    }
    return .clear;
}

fn curve_operator(c: *Context, m: *Machine, b0: u8) Step {
    const s = m.stack[0..m.sp];
    assert(s.len <= stack_max);
    var i: u32 = 0;
    switch (b0) {
        0x08 => {
            if (s.len < 6) return .failed;
            while (i + 5 < s.len) : (i += 6) c.curve_to(s[i..][0..6].*);
        },
        0x1e, 0x1f => {
            // Curves whose ends turn by a right angle each time
            if (s.len < 4) return .failed;
            var vertical = b0 == 0x1e;
            while (i + 3 < s.len) : (i += 4) {
                const last: f32 = if (s.len - i == 5) s[i + 4] else 0;
                if (vertical) {
                    c.curve_to(.{ 0, s[i], s[i + 1], s[i + 2], s[i + 3], last });
                } else {
                    c.curve_to(.{ s[i], 0, s[i + 1], s[i + 2], last, s[i + 3] });
                }
                vertical = !vertical;
            }
        },
        else => {
            // Curves that start and end level (hhcurveto) or upright (vvcurveto)
            assert(b0 == 0x1a or b0 == 0x1b);
            if (s.len < 4) return .failed;
            var f: f32 = 0;
            if (s.len & 1 != 0) {
                f = s[0];
                i = 1;
            }
            while (i + 3 < s.len) : (i += 4) {
                if (b0 == 0x1b) {
                    c.curve_to(.{ s[i], f, s[i + 1], s[i + 2], s[i + 3], 0 });
                } else {
                    c.curve_to(.{ f, s[i], s[i + 1], s[i + 2], 0, s[i + 3] });
                }
                f = 0;
            }
        },
    }
    return .clear;
}

fn call_operator(font: *const Font, glyph: u32, m: *Machine, b0: u8) Step {
    assert(b0 == 0x0a or b0 == 0x1d);
    assert(m.depth <= subr_depth_max);
    if (b0 == 0x0a and !m.has_subrs) {
        if (font.fd_select.data.len > 0) m.subrs = cid_glyph_subrs(font, glyph);
        m.has_subrs = true;
    }
    if (m.sp < 1) return .failed;
    m.sp -= 1;
    const number = to_int(m.stack[m.sp]);
    if (m.depth >= subr_depth_max) return .failed;
    m.returns[m.depth] = m.b;
    m.depth += 1;
    m.b = get_subr(if (b0 == 0x0a) m.subrs else font.global_subrs, number);
    if (m.b.data.len == 0) return .failed;
    m.b.cursor = 0;
    return .keep;
}

/// The flex operators, after the escape byte. Their depth is ignored: always curves.
fn flex_operator(c: *Context, m: *Machine) Step {
    const b1 = m.b.get8();
    const s = m.stack[0..m.sp];
    assert(s.len <= stack_max);
    switch (b1) {
        0x22 => {
            if (s.len < 7) return .failed;
            c.curve_to(.{ s[0], 0, s[1], s[2], s[3], 0 });
            c.curve_to(.{ s[4], 0, s[5], -s[2], s[6], 0 });
        },
        0x23 => {
            if (s.len < 13) return .failed;
            c.curve_to(s[0..6].*);
            c.curve_to(s[6..12].*);
        },
        0x24 => {
            if (s.len < 9) return .failed;
            c.curve_to(.{ s[0], s[1], s[2], s[3], s[4], 0 });
            c.curve_to(.{ s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]) });
        },
        0x25 => {
            if (s.len < 11) return .failed;
            const dx = s[0] + s[2] + s[4] + s[6] + s[8];
            const dy = s[1] + s[3] + s[5] + s[7] + s[9];
            var dx6 = s[10];
            var dy6 = s[10];
            if (@abs(dx) > @abs(dy)) dy6 = -dy else dx6 = -dx;
            c.curve_to(s[0..6].*);
            c.curve_to(.{ s[6], s[7], s[8], s[9], dx6, dy6 });
        },
        else => return .failed,
    }
    assert(c.vertex_count > 0);
    return .clear;
}
