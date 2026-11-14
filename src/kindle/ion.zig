//! Minimal Amazon Ion binary decoder: just enough to read KFX.
const std = @import("std");

pub const Kind = enum { pad, null_, bool_, uint, nint, float, decimal, timestamp, symbol, string, clob, blob, list, sexp, struct_ };

pub const Value = struct {
    kind: Kind,
    body: []const u8 = &.{},
    int: u64 = 0, // uint, nint and symbol values

    pub fn items(v: Value) Items {
        return .{ .data = if (v.kind == .list or v.kind == .sexp) v.body else &.{} };
    }

    pub fn get(v: Value, field: u32) ?Value {
        if (v.kind != .struct_) return null;
        var pos: usize = 0;
        while (pos < v.body.len) {
            const key = read_var_uint(v.body, &pos) catch return null;
            const value = decode(v.body, &pos) catch return null;
            if (value.kind != .pad and key == field) return value;
        }
        return null;
    }

    /// Every field of a struct, in order.
    pub fn fields(v: Value) Fields {
        return .{ .data = if (v.kind == .struct_) v.body else &.{} };
    }

    /// A float, stored big-endian in 4 or 8 bytes. Zero-length means 0.
    pub fn float(v: Value) ?f64 {
        if (v.kind != .float) return null;
        return switch (v.body.len) {
            0 => 0,
            4 => @as(f32, @bitCast(std.mem.readInt(u32, v.body[0..4], .big))),
            8 => @bitCast(std.mem.readInt(u64, v.body[0..8], .big)),
            else => null,
        };
    }

    /// A number however it's stored: unsigned, negative, float or decimal (decimals read as 0).
    pub fn number(v: Value) ?f64 {
        return switch (v.kind) {
            .uint => @floatFromInt(v.int),
            .nint => -@as(f64, @floatFromInt(v.int)),
            .float => v.float(),
            else => null,
        };
    }

    pub fn text(v: Value) ?[]const u8 {
        return if (v.kind == .string) v.body else null;
    }

    pub fn symbol(v: Value) ?u32 {
        // A symbol number past 32 bits can only come from a broken file.
        if (v.kind != .symbol or v.int > std.math.maxInt(u32)) return null;
        return @intCast(v.int);
    }

    pub fn unsigned(v: Value) ?u64 {
        return if (v.kind == .uint) v.int else null;
    }
};

pub const Items = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(it: *Items) ?Value {
        while (it.pos < it.data.len) {
            const v = decode(it.data, &it.pos) catch return null;
            if (v.kind != .pad) return v;
        }
        return null;
    }
};

fn read_var_uint(d: []const u8, pos: *usize) !u64 {
    var v: u64 = 0;
    while (true) {
        if (pos.* >= d.len) return error.Truncated;
        const c = d[pos.*];
        pos.* += 1;
        v = (v << 7) | (c & 0x7f);
        if (c & 0x80 != 0) return v;
    }
}

fn be_int(d: []const u8) u64 {
    var v: u64 = 0;
    for (d) |c| v = (v << 8) | c;
    return v;
}

/// Decode the value at `pos`, looking through annotations.
/// Padding comes back as `.pad`: inside a struct a field ID follows it, not a value.
pub const Field = struct { key: u64, value: Value };

pub const Fields = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(f: *Fields) ?Field {
        while (f.pos < f.data.len) {
            const key = read_var_uint(f.data, &f.pos) catch return null;
            const value = decode(f.data, &f.pos) catch return null;
            if (value.kind != .pad) return .{ .key = key, .value = value };
        }
        return null;
    }
};

pub fn decode(d: []const u8, pos: *usize) anyerror!Value {
    while (true) {
        if (pos.* >= d.len) return error.Truncated;
        const desc = d[pos.*];
        pos.* += 1;
        const t = desc >> 4;
        var len: u64 = desc & 0x0f;

        if (t == 1) return .{ .kind = .bool_, .int = @intFromBool(len == 1) };
        if (len == 15) return .{ .kind = .null_ };
        if (len == 14 or (t == 13 and len == 1)) len = try read_var_uint(d, pos);
        if (len > d.len - pos.*) return error.Truncated;
        const body = d[pos.*..][0..@intCast(len)];
        pos.* += @intCast(len);

        switch (t) {
            0 => return .{ .kind = .pad },
            2 => return .{ .kind = .uint, .body = body, .int = be_int(body) },
            3 => return .{ .kind = .nint, .body = body, .int = be_int(body) },
            4 => return .{ .kind = .float, .body = body },
            5 => return .{ .kind = .decimal, .body = body },
            6 => return .{ .kind = .timestamp, .body = body },
            7 => return .{ .kind = .symbol, .body = body, .int = be_int(body) },
            8 => return .{ .kind = .string, .body = body },
            9 => return .{ .kind = .clob, .body = body },
            10 => return .{ .kind = .blob, .body = body },
            11 => return .{ .kind = .list, .body = body },
            12 => return .{ .kind = .sexp, .body = body },
            13 => return .{ .kind = .struct_, .body = body },
            14 => {
                var inner: usize = 0;
                const ann_len = try read_var_uint(body, &inner);
                inner += @intCast(ann_len);
                return decode(body, &inner);
            },
            else => return error.BadType,
        }
    }
}

/// Decode a whole Ion stream, skipping the version marker if present.
pub fn parse(d: []const u8) !Value {
    var pos: usize = 0;
    if (d.len >= 4 and std.mem.eql(u8, d[0..4], "\xe0\x01\x00\xea")) pos = 4;
    while (true) {
        const v = try decode(d, &pos);
        if (v.kind != .pad) return v;
    }
}

test "struct lookup and strings" {
    // {10: "hi", 11: 300}
    const d = [_]u8{ 0xe0, 1, 0, 0xea, 0xd8, 0x8a, 0x82, 'h', 'i', 0x8b, 0x22, 0x01, 0x2c };
    const v = try parse(&d);
    try std.testing.expectEqualStrings("hi", v.get(10).?.text().?);
    try std.testing.expectEqual(@as(u64, 300), v.get(11).?.unsigned().?);
    try std.testing.expect(v.get(12) == null);
}

test "annotation is transparent and lists iterate" {
    // annot(sym 4)::[1, 2]
    const d = [_]u8{ 0xe7, 0x81, 0x84, 0xb4, 0x21, 1, 0x21, 2 };
    var it = (try parse(&d)).items();
    try std.testing.expectEqual(@as(u64, 1), it.next().?.int);
    try std.testing.expectEqual(@as(u64, 2), it.next().?.int);
    try std.testing.expect(it.next() == null);
}

test "padding between struct fields" {
    // {10: pad, 11: "hi"}
    const d = [_]u8{ 0xd7, 0x8a, 0x01, 0x00, 0x8b, 0x82, 'h', 'i' };
    const v = try parse(&d);
    try std.testing.expectEqualStrings("hi", v.get(11).?.text().?);
    try std.testing.expect(v.get(10) == null);
}

test "padding in lists is skipped, even at the end" {
    const d = [_]u8{ 0xb5, 0x21, 1, 0x01, 0x00, 0x00 };
    var it = (try parse(&d)).items();
    try std.testing.expectEqual(@as(u64, 1), it.next().?.int);
    try std.testing.expect(it.next() == null);
}

/// Reads every value inside `v`, the way the KFX parser does, to reach all the code
/// a hostile file could steer.
fn walk_all(v: Value, depth: u32) void {
    if (depth > 40) return;
    _ = v.text();
    _ = v.symbol();
    _ = v.number();
    var items = v.items();
    while (items.next()) |item| walk_all(item, depth + 1);
    var fields = v.fields();
    while (fields.next()) |f| walk_all(f.value, depth + 1);
}

test "random and broken input never crashes the reader" {
    var prng = std.Random.DefaultPrng.init(0x6e6f66616365);
    const random = prng.random();
    var buf: [512]u8 = undefined;
    for (0..20_000) |round| {
        const len = random.uintLessThan(usize, buf.len);
        random.bytes(buf[0..len]);
        // Half the rounds start like real Ion, so the parser gets past the first byte.
        if (round % 2 == 0 and len >= 4) @memcpy(buf[0..4], &[_]u8{ 0xe0, 0x01, 0x00, 0xea });
        const v = parse(buf[0..len]) catch continue;
        walk_all(v, 0);
    }
}
