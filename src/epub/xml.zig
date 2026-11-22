//! A forgiving tokenizer for the XML and XHTML inside EPUBs: tags, their attributes,
//! and text. Comments, processing instructions and doctypes are skipped. It never
//! fails: broken markup just yields fewer or odder tokens, since books are messy.
const std = @import("std");
const assert = std.debug.assert;
const unicode = @import("../text/unicode.zig");

pub const Tag = struct {
    name: []const u8, // Without any namespace prefix, so "dc:title" is "title"
    attributes: []const u8, // The raw attribute text, read with `attribute`
    self_closing: bool,
};

pub const Token = union(enum) {
    open: Tag,
    close: []const u8, // The closing tag's name, without prefix
    text: []const u8, // Raw text: entities still encoded, see `decode`
};

/// Markup comes out of a book's zip, whose files are far smaller (zip.zig's size_max),
/// so a position in it fits in 32 bits.
const data_size_max = std.math.maxInt(u32);
const whitespace = " \t\r\n";
const cdata_open = "<![CDATA[";
const cdata_close = "]]>";
/// Longer names between `&` and `;` aren't entities: the longest known is "hellip".
const entity_name_length_limit = 12;

const named_entities = [_]struct { []const u8, u21 }{
    .{ "amp", '&' },      .{ "lt", '<' },       .{ "gt", '>' },
    .{ "quot", '"' },     .{ "apos", '\'' },    .{ "nbsp", 0xa0 },
    .{ "mdash", 0x2014 }, .{ "ndash", 0x2013 }, .{ "hellip", 0x2026 },
    .{ "lsquo", 0x2018 }, .{ "rsquo", 0x2019 }, .{ "ldquo", 0x201c },
    .{ "rdquo", 0x201d },
};

comptime {
    for (named_entities) |named| {
        assert(named[0].len > 0);
        assert(named[0].len < entity_name_length_limit);
    }
}

pub const Tokenizer = struct {
    data: []const u8,
    position: u32 = 0,

    /// The next token, or null at the end of the data.
    pub fn next(t: *Tokenizer) ?Token {
        assert(t.data.len <= data_size_max);
        assert(t.position <= t.data.len);
        const data = t.data;
        while (t.position < data.len) {
            const start = t.position;
            const rest = data[start..];
            if (rest[0] != '<') {
                const end = std.mem.indexOfScalarPos(u8, data, start, '<') orelse data.len;
                t.position = @intCast(end);
                return .{ .text = data[start..end] };
            }
            if (std.mem.startsWith(u8, rest, "<!--")) {
                t.position = skip_past(data, start, "-->");
            } else if (std.mem.startsWith(u8, rest, cdata_open)) {
                return t.next_cdata();
            } else if (std.mem.startsWith(u8, rest, "<?") or std.mem.startsWith(u8, rest, "<!")) {
                t.position = skip_past(data, start, ">");
            } else {
                return t.next_tag();
            }
            // Skipping always moves on, so the loop ends
            assert(t.position > start);
        }
        return null;
    }

    /// A CDATA section's text, as written: its markup isn't markup.
    fn next_cdata(t: *Tokenizer) Token {
        const data = t.data;
        assert(std.mem.startsWith(u8, data[t.position..], cdata_open));
        const start = t.position + cdata_open.len;
        const end = std.mem.indexOfPos(u8, data, start, cdata_close) orelse data.len;
        t.position = @intCast(@min(data.len, end + cdata_close.len));
        assert(t.position >= start);
        return .{ .text = data[start..end] };
    }

    /// An opening or closing tag, from its `<`. Null when it never closes: it runs to
    /// the end, and there is nothing more.
    fn next_tag(t: *Tokenizer) ?Token {
        const data = t.data;
        assert(data[t.position] == '<');
        const end = std.mem.indexOfScalarPos(u8, data, t.position, '>') orelse {
            t.position = @intCast(data.len);
            return null;
        };
        const inside = data[t.position + 1 .. end];
        t.position = @intCast(end + 1);
        assert(t.position <= data.len);
        if (inside.len > 0 and inside[0] == '/') {
            return .{ .close = local_name(std.mem.trim(u8, inside[1..], whitespace)) };
        }
        const self_closing = inside.len > 0 and inside[inside.len - 1] == '/';
        const body = if (self_closing) inside[0 .. inside.len - 1] else inside;
        const name_end = std.mem.indexOfAny(u8, body, whitespace) orelse body.len;
        return .{ .open = .{
            .name = local_name(body[0..name_end]),
            .attributes = body[name_end..],
            .self_closing = self_closing,
        } };
    }
};

/// Where `marker` ends, from `from` on, or the end of the data without one.
fn skip_past(data: []const u8, from: u32, marker: []const u8) u32 {
    assert(from < data.len);
    assert(marker.len > 0);
    const at = std.mem.indexOfPos(u8, data, from, marker) orelse return @intCast(data.len);
    return @intCast(at + marker.len);
}

/// "dc:title" -> "title".
pub fn local_name(name: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return name;
    const local = name[colon + 1 ..];
    assert(local.len < name.len);
    assert(std.mem.indexOfScalar(u8, local, ':') == null);
    return local;
}

/// The first position from `from` on that isn't whitespace, or the end.
fn skip_whitespace(text: []const u8, from: u32) u32 {
    assert(text.len <= data_size_max);
    assert(from <= text.len);
    var at = from;
    while (at < text.len and std.ascii.isWhitespace(text[at])) at += 1;
    return at;
}

/// An attribute's raw value, matching its name without prefix: `attribute(a, "href")`.
pub fn attribute(attributes: []const u8, name: []const u8) ?[]const u8 {
    assert(attributes.len <= data_size_max);
    assert(name.len > 0);
    var at: u32 = 0;
    while (at < attributes.len) {
        const start = at;
        at = skip_whitespace(attributes, at);
        const name_start = at;
        while (at < attributes.len and attributes[at] != '=' and
            !std.ascii.isWhitespace(attributes[at])) at += 1;
        const this = local_name(attributes[name_start..at]);
        at = skip_whitespace(attributes, at);
        if (at >= attributes.len or attributes[at] != '=') {
            if (at == name_start) at += 1; // Never stall on a stray character
            assert(at > start);
            continue;
        }
        at = skip_whitespace(attributes, at + 1);
        if (at >= attributes.len) return null;
        const quote = attributes[at];
        var value: []const u8 = undefined;
        if (quote == '"' or quote == '\'') {
            const end = std.mem.indexOfScalarPos(u8, attributes, at + 1, quote) orelse
                attributes.len;
            value = attributes[at + 1 .. end];
            at = @intCast(@min(attributes.len, end + 1));
        } else {
            const rest = attributes[at..];
            const end = std.mem.indexOfAny(u8, rest, whitespace) orelse rest.len;
            value = rest[0..end];
            at += @intCast(end);
        }
        assert(at > start);
        if (std.mem.eql(u8, this, name)) return value;
    }
    return null;
}

/// Appends text with its entities decoded. Unknown entities are kept as written.
pub fn decode(out: *std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    assert(text.len <= data_size_max);
    var at: u32 = 0;
    while (at < text.len) {
        const start = at;
        const ampersand = std.mem.indexOfScalarPos(u8, text, at, '&') orelse {
            try out.appendSlice(alloc, text[at..]);
            return;
        };
        try out.appendSlice(alloc, text[at..ampersand]);
        // An entity's name is shorter than the limit, so its `;` is no further than
        // this. Looking past it would scan to a far `;` once for every `&`, so a
        // chapter of `&`s with one `;` at its end would take time growing as its square.
        const window_end = @min(text.len, ampersand + entity_name_length_limit + 1);
        const window = text[0..window_end];
        if (std.mem.indexOfScalarPos(u8, window, ampersand + 1, ';')) |semicolon| {
            if (entity(text[ampersand + 1 .. semicolon])) |code_point| {
                var encoded: [4]u8 = undefined;
                // `entity` gives only characters, which always encode
                try out.appendSlice(alloc, unicode.encode(code_point, &encoded).?);
                at = @intCast(semicolon + 1);
                assert(at > start);
                continue;
            }
        }
        try out.append(alloc, '&');
        at = @intCast(ampersand + 1);
        assert(at > start);
    }
}

/// The character an entity's name stands for, or null when it isn't one ("&;" isn't).
fn entity(name: []const u8) ?u21 {
    // The caller looks for the `;` no further than the longest name
    assert(name.len < entity_name_length_limit);
    if (name.len == 0) return null;
    if (name[0] == '#') return entity_numeric(name);
    for (named_entities) |named| {
        if (std.mem.eql(u8, named[0], name)) return named[1];
    }
    return null;
}

/// "#233" or "#xe9": a character by its number, if it is one.
fn entity_numeric(name: []const u8) ?u21 {
    assert(name.len > 0);
    assert(name[0] == '#');
    const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
    const digits = name[if (hex) 2 else 1..];
    const value = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
    if (value == 0) return null;
    if (value >= 0xd800 and value <= 0xdfff) return null; // Surrogates aren't characters
    if (value > unicode.code_point_max) return null;
    return value;
}

test "tags, attributes and text come out in order" {
    var t = Tokenizer{
        .data = "<?xml version=\"1.0\"?><!-- note --><dc:title id='t'>A &amp; B</dc:title><br/>",
    };
    const open = t.next().?.open;
    try std.testing.expectEqualStrings("title", open.name);
    try std.testing.expectEqualStrings("t", attribute(open.attributes, "id").?);
    try std.testing.expectEqualStrings("A &amp; B", t.next().?.text);
    try std.testing.expectEqualStrings("title", t.next().?.close);
    try std.testing.expect(t.next().?.open.self_closing);
    try std.testing.expect(t.next() == null);
}

test "attributes read with any quoting, and missing ones are null" {
    const a = " href=\"ch1.xhtml#n2\" xml:lang=en  data-x='y'";
    try std.testing.expectEqualStrings("ch1.xhtml#n2", attribute(a, "href").?);
    try std.testing.expectEqualStrings("en", attribute(a, "lang").?);
    try std.testing.expectEqualStrings("y", attribute(a, "data-x").?);
    try std.testing.expect(attribute(a, "src") == null);
}

test "entities decode, unknown ones stay" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try decode(&out, alloc, "caf&#233; &#x2014; &lt;b&gt; &bogus; &");
    try std.testing.expectEqualStrings("caf\u{e9} \u{2014} <b> &bogus; &", out.items);
}

/// `decode` as it was, looking for each `&`'s `;` anywhere after it: the oracle that
/// the bounded search gives the same text.
fn test_decode_unbounded(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    text: []const u8,
) !void {
    assert(text.len <= data_size_max);
    var at: u32 = 0;
    while (at < text.len) {
        const ampersand = std.mem.indexOfScalarPos(u8, text, at, '&') orelse {
            return out.appendSlice(alloc, text[at..]);
        };
        try out.appendSlice(alloc, text[at..ampersand]);
        const semicolon = std.mem.indexOfScalarPos(u8, text, ampersand, ';') orelse {
            return out.appendSlice(alloc, text[ampersand..]);
        };
        const name = text[ampersand + 1 .. semicolon];
        if (name.len < entity_name_length_limit) {
            if (entity(name)) |code_point| {
                var encoded: [4]u8 = undefined;
                // `entity` gives only characters, which always encode
                try out.appendSlice(alloc, unicode.encode(code_point, &encoded).?);
                at = @intCast(semicolon + 1);
                continue;
            }
        }
        try out.append(alloc, '&');
        at = @intCast(ampersand + 1);
    }
}

test "entities decode as before, looking for each `;` only as far as the longest name" {
    const alloc = std.testing.allocator;
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0x26_3b);
    const random = prng.random();
    const alphabet = "&;#x0123456789amplthellipquotnbsp ";
    var buf: [64]u8 = undefined;
    for (0..50_000) |_| {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        got.clearRetainingCapacity();
        want.clearRetainingCapacity();
        try decode(&got, alloc, buf[0..len]);
        try test_decode_unbounded(&want, alloc, buf[0..len]);
        try std.testing.expectEqualStrings(want.items, got.items);
    }
    // A chapter of `&`s with one `;` at its end, which took seconds, comes out whole
    const ampersands = try alloc.alloc(u8, 400_000);
    defer alloc.free(ampersands);
    @memset(ampersands, '&');
    ampersands[ampersands.len - 1] = ';';
    got.clearRetainingCapacity();
    try decode(&got, alloc, ampersands);
    try std.testing.expectEqualStrings(ampersands, got.items);
}

test "CDATA comes out as text, markup and all" {
    var t = Tokenizer{ .data = "<p><![CDATA[a <b> c]]></p>" };
    try std.testing.expectEqualStrings("p", t.next().?.open.name);
    try std.testing.expectEqualStrings("a <b> c", t.next().?.text);
    try std.testing.expectEqualStrings("p", t.next().?.close);
    try std.testing.expect(t.next() == null);
}

test "random markup never crashes the tokenizer" {
    var prng = std.Random.DefaultPrng.init(0x786d6c);
    const random = prng.random();
    const alphabet = "<>/=\"' &;#x!-?[]abcdpq:\n";
    var buf: [256]u8 = undefined;
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (0..20_000) |_| {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        var t = Tokenizer{ .data = buf[0..len] };
        var guard: usize = 0;
        while (t.next()) |tok| : (guard += 1) {
            if (guard > len + 2) return error.TokenizerStalled;
            switch (tok) {
                .open => |o| _ = attribute(o.attributes, "href"),
                .text => |s| {
                    out.clearRetainingCapacity();
                    try decode(&out, alloc, s);
                },
                .close => {},
            }
        }
    }
}
