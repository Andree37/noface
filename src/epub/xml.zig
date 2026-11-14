//! A forgiving tokenizer for the XML and XHTML inside EPUBs: tags, their attributes,
//! and text. Comments, processing instructions and doctypes are skipped. It never
//! fails: broken markup just yields fewer or odder tokens, since books are messy.
const std = @import("std");

pub const Tag = struct {
    name: []const u8, // Without any namespace prefix, so "dc:title" is "title"
    attrs: []const u8, // The raw attribute text, read with `attr`
    self_closing: bool,
};

pub const Token = union(enum) {
    open: Tag,
    close: []const u8, // The closing tag's name, without prefix
    text: []const u8, // Raw text: entities still encoded, see `decode`
};

pub const Tokenizer = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(t: *Tokenizer) ?Token {
        while (t.pos < t.data.len) {
            const d = t.data;
            if (d[t.pos] != '<') {
                const end = std.mem.indexOfScalarPos(u8, d, t.pos, '<') orelse d.len;
                const text = d[t.pos..end];
                t.pos = end;
                return .{ .text = text };
            }
            if (std.mem.startsWith(u8, d[t.pos..], "<!--")) {
                t.pos = skip_past(d, t.pos, "-->");
                continue;
            }
            if (std.mem.startsWith(u8, d[t.pos..], "<![CDATA[")) {
                const start = t.pos + "<![CDATA[".len;
                const end = std.mem.indexOfPos(u8, d, start, "]]>") orelse d.len;
                t.pos = @min(d.len, end + 3);
                return .{ .text = d[start..end] };
            }
            if (std.mem.startsWith(u8, d[t.pos..], "<?") or std.mem.startsWith(u8, d[t.pos..], "<!")) {
                t.pos = skip_past(d, t.pos, ">");
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, d, t.pos, '>') orelse {
                t.pos = d.len;
                return null;
            };
            const inside = d[t.pos + 1 .. end];
            t.pos = end + 1;
            if (inside.len > 0 and inside[0] == '/') return .{ .close = local_name(std.mem.trim(u8, inside[1..], " \t\r\n")) };
            const self_closing = inside.len > 0 and inside[inside.len - 1] == '/';
            const body = if (self_closing) inside[0 .. inside.len - 1] else inside;
            const name_end = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
            return .{ .open = .{ .name = local_name(body[0..name_end]), .attrs = body[name_end..], .self_closing = self_closing } };
        }
        return null;
    }
};

fn skip_past(d: []const u8, from: usize, marker: []const u8) usize {
    const at = std.mem.indexOfPos(u8, d, from, marker) orelse return d.len;
    return at + marker.len;
}

/// "dc:title" -> "title".
pub fn local_name(name: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return name;
    return name[colon + 1 ..];
}

/// An attribute's raw value, matching its name without prefix: `attr(a, "href")`.
pub fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at < attrs.len) {
        while (at < attrs.len and std.ascii.isWhitespace(attrs[at])) at += 1;
        const name_start = at;
        while (at < attrs.len and attrs[at] != '=' and !std.ascii.isWhitespace(attrs[at])) at += 1;
        const this = local_name(attrs[name_start..at]);
        while (at < attrs.len and std.ascii.isWhitespace(attrs[at])) at += 1;
        if (at >= attrs.len or attrs[at] != '=') {
            if (at == name_start) at += 1; // Never stall on a stray character
            continue;
        }
        at += 1;
        while (at < attrs.len and std.ascii.isWhitespace(attrs[at])) at += 1;
        if (at >= attrs.len) return null;
        const quote = attrs[at];
        var value: []const u8 = undefined;
        if (quote == '"' or quote == '\'') {
            const end = std.mem.indexOfScalarPos(u8, attrs, at + 1, quote) orelse attrs.len;
            value = attrs[at + 1 .. end];
            at = @min(attrs.len, end + 1);
        } else {
            const end = std.mem.indexOfAny(u8, attrs[at..], " \t\r\n") orelse attrs.len - at;
            value = attrs[at..][0..end];
            at += end;
        }
        if (std.mem.eql(u8, this, name)) return value;
    }
    return null;
}

/// Appends text with its entities decoded. Unknown entities are kept as written.
pub fn decode(out: *std.ArrayList(u8), alloc: std.mem.Allocator, text: []const u8) !void {
    var at: usize = 0;
    while (at < text.len) {
        const amp = std.mem.indexOfScalarPos(u8, text, at, '&') orelse {
            try out.appendSlice(alloc, text[at..]);
            return;
        };
        try out.appendSlice(alloc, text[at..amp]);
        const semi = std.mem.indexOfScalarPos(u8, text, amp, ';') orelse {
            try out.appendSlice(alloc, text[amp..]);
            return;
        };
        const name = text[amp + 1 .. semi];
        if (name.len > 0 and name.len < 12) {
            if (entity(name)) |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(alloc, buf[0..n]);
                at = semi + 1;
                continue;
            }
        }
        try out.append(alloc, '&');
        at = amp + 1;
    }
}

fn entity(name: []const u8) ?u21 {
    if (name[0] == '#') {
        const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
        const digits = name[if (hex) 2 else 1..];
        const v = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return null;
        return if (v == 0 or (v >= 0xd800 and v <= 0xdfff) or v > 0x10ffff) null else v;
    }
    const named = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },      .{ "lt", '<' },       .{ "gt", '>' },       .{ "quot", '"' },      .{ "apos", '\'' },
        .{ "nbsp", 0xa0 },    .{ "mdash", 0x2014 }, .{ "ndash", 0x2013 }, .{ "hellip", 0x2026 }, .{ "lsquo", 0x2018 },
        .{ "rsquo", 0x2019 }, .{ "ldquo", 0x201c }, .{ "rdquo", 0x201d },
    };
    for (named) |n| {
        if (std.mem.eql(u8, n[0], name)) return n[1];
    }
    return null;
}

test "tags, attributes and text come out in order" {
    var t = Tokenizer{ .data = "<?xml version=\"1.0\"?><!-- note --><dc:title id='t'>A &amp; B</dc:title><br/>" };
    const open = t.next().?.open;
    try std.testing.expectEqualStrings("title", open.name);
    try std.testing.expectEqualStrings("t", attr(open.attrs, "id").?);
    try std.testing.expectEqualStrings("A &amp; B", t.next().?.text);
    try std.testing.expectEqualStrings("title", t.next().?.close);
    try std.testing.expect(t.next().?.open.self_closing);
    try std.testing.expect(t.next() == null);
}

test "attributes read with any quoting, and missing ones are null" {
    const a = " href=\"ch1.xhtml#n2\" xml:lang=en  data-x='y'";
    try std.testing.expectEqualStrings("ch1.xhtml#n2", attr(a, "href").?);
    try std.testing.expectEqualStrings("en", attr(a, "lang").?);
    try std.testing.expectEqualStrings("y", attr(a, "data-x").?);
    try std.testing.expect(attr(a, "src") == null);
}

test "entities decode, unknown ones stay" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try decode(&out, alloc, "caf&#233; &#x2014; &lt;b&gt; &bogus; &");
    try std.testing.expectEqualStrings("caf\u{e9} \u{2014} <b> &bogus; &", out.items);
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
                .open => |o| _ = attr(o.attrs, "href"),
                .text => |s| {
                    out.clearRetainingCapacity();
                    try decode(&out, alloc, s);
                },
                .close => {},
            }
        }
    }
}
