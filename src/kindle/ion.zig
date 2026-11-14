//! Minimal Amazon Ion binary decoder: just enough to read KFX.
//!
//! Every byte read here comes from a book file, so none of it is asserted: a broken
//! file is an error or a missing value, never a crash. The assertions state the
//! decoder's own invariants: positions stay inside the bytes they index, every value
//! handed out lies inside the bytes it was read from, and padding never leaves the
//! decoder.
const std = @import("std");
const assert = std.debug.assert;

pub const Kind = enum {
    pad,
    null_,
    bool_,
    uint,
    nint,
    float,
    decimal,
    timestamp,
    symbol,
    string,
    clob,
    blob,
    list,
    sexp,
    struct_,
};

pub const Error = error{ Truncated, BadType, TooDeep, TooLarge };

/// The largest stream decoded: positions in it are u32, as on the Kindle.
pub const size_max = std.math.maxInt(u32);

/// How many annotation wrappers may sit around one value. Ion allows no wrapper
/// directly inside another; a few are tolerated, more mean a broken file.
const annotation_wrappers_max = 8;

/// The binary version marker a stream may start with.
const version_marker = "\xe0\x01\x00\xea";

/// A value's descriptor byte: its type code in the high four bits, its length (or one
/// of the special lengths below) in the low four.
const type_code_bool = 1;
const type_code_struct = 13;
const type_code_annotation = 14;
const length_sorted_struct = 1; // A struct whose length follows, sorted by field
const length_variable = 14; // The length follows as a variable-length number
const length_null = 15; // A null of the type, with no body

comptime {
    assert(version_marker.len == 4);
    assert(length_variable + 1 == length_null);
    assert(length_null == 0x0f); // The largest length the low four bits hold
    assert(type_code_annotation <= 0x0f);
    assert(type_code_bool < type_code_struct);
    assert(type_code_struct < type_code_annotation);
    assert(@typeInfo(Kind).@"enum".field_names.len == 15);
}

pub const Value = struct {
    kind: Kind,
    body: []const u8 = &.{},
    int: u64 = 0, // For uint, nint and symbol values

    pub fn items(v: Value) Items {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        return .{ .data = if (v.kind == .list or v.kind == .sexp) v.body else &.{} };
    }

    pub fn get(v: Value, field: u32) ?Value {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        if (v.kind != .struct_) return null;
        var all = v.fields();
        while (all.next()) |each| {
            assert(each.value.kind != .pad);
            if (each.key == field) return each.value;
        }
        return null;
    }

    /// Every field of a struct, in order.
    pub fn fields(v: Value) Fields {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        return .{ .data = if (v.kind == .struct_) v.body else &.{} };
    }

    /// A float, stored big-endian in 4 or 8 bytes. Zero-length means 0.
    pub fn float(v: Value) ?f64 {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        if (v.kind != .float) return null;
        return switch (v.body.len) {
            0 => 0,
            4 => @as(f32, @bitCast(std.mem.readInt(u32, v.body[0..4], .big))),
            8 => @bitCast(std.mem.readInt(u64, v.body[0..8], .big)),
            else => null,
        };
    }

    /// A number however it's stored: unsigned, negative, float or decimal (decimals
    /// read as 0).
    pub fn number(v: Value) ?f64 {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        return switch (v.kind) {
            .uint => @floatFromInt(v.int),
            .nint => -@as(f64, @floatFromInt(v.int)),
            .float => v.float(),
            else => null,
        };
    }

    pub fn text(v: Value) ?[]const u8 {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        return if (v.kind == .string) v.body else null;
    }

    pub fn symbol(v: Value) ?u32 {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        if (v.kind != .symbol) return null;
        // A symbol number past 32 bits can only come from a broken file.
        return std.math.cast(u32, v.int);
    }

    pub fn unsigned(v: Value) ?u64 {
        assert(v.kind != .pad);
        assert(v.body.len <= size_max);
        return if (v.kind == .uint) v.int else null;
    }
};

pub const Items = struct {
    data: []const u8,
    position: u32 = 0,

    /// The next value, skipping padding. A value that won't decode ends the list.
    pub fn next(it: *Items) ?Value {
        assert(it.data.len <= size_max);
        assert(it.position <= it.data.len);
        // Bounded: every value read moves the position on by at least a byte.
        while (it.position < it.data.len) {
            const value = decode(it.data, &it.position) catch return null;
            if (value.kind != .pad) return value;
        }
        assert(it.position == it.data.len);
        return null;
    }
};

pub const Field = struct { key: u64, value: Value };

pub const Fields = struct {
    data: []const u8,
    position: u32 = 0,

    /// The next field, skipping padding. A field that won't decode ends the struct.
    pub fn next(it: *Fields) ?Field {
        assert(it.data.len <= size_max);
        assert(it.position <= it.data.len);
        // Bounded: every field read moves the position on by at least a byte.
        while (it.position < it.data.len) {
            const key = read_var_uint(it.data, &it.position) catch return null;
            const value = decode(it.data, &it.position) catch return null;
            if (value.kind != .pad) return .{ .key = key, .value = value };
        }
        assert(it.position == it.data.len);
        return null;
    }
};

/// A variable-length unsigned number: seven bits a byte, the last byte flagged by its
/// high bit. Bits past 64 are dropped.
fn read_var_uint(data: []const u8, position: *u32) Error!u64 {
    assert(data.len <= size_max);
    assert(position.* <= data.len);
    var value: u64 = 0;
    while (position.* < data.len) {
        const byte = data[position.*];
        position.* += 1;
        value = (value << 7) | (byte & 0x7f);
        if (byte & 0x80 != 0) return value;
    }
    assert(position.* == data.len);
    return error.Truncated;
}

/// A big-endian unsigned number. Bytes past eight push the first ones out.
fn be_int(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes) |byte| value = (value << 8) | byte;
    if (bytes.len == 0) assert(value == 0);
    if (bytes.len < 8) assert(value >> @intCast(bytes.len * 8) == 0);
    return value;
}

/// One value as read: a value, or an annotation wrapper's body, whose annotations
/// precede the value it wraps.
const Read = union(enum) { value: Value, annotation: []const u8 };

/// Reads the descriptor at `position` and the body it gives the length of.
fn read_one(data: []const u8, position: *u32) Error!Read {
    assert(data.len <= size_max);
    assert(position.* <= data.len);
    if (position.* >= data.len) return error.Truncated;
    const start = position.*;
    const descriptor = data[position.*];
    position.* += 1;
    const type_code = descriptor >> 4;
    var length: u64 = descriptor & 0x0f;

    if (type_code == type_code_bool) {
        return .{ .value = .{ .kind = .bool_, .int = @intFromBool(length == 1) } };
    }
    if (length == length_null) return .{ .value = .{ .kind = .null_ } };
    const sorted_struct = type_code == type_code_struct and length == length_sorted_struct;
    if (length == length_variable or sorted_struct) length = try read_var_uint(data, position);
    if (length > data.len - position.*) return error.Truncated;
    const body = data[position.*..][0..@intCast(length)];
    position.* += @intCast(length);
    assert(position.* <= data.len);
    assert(body.len < position.* - start);

    if (type_code == type_code_annotation) return .{ .annotation = body };
    const value: Value = switch (type_code) {
        0 => .{ .kind = .pad },
        2 => .{ .kind = .uint, .body = body, .int = be_int(body) },
        3 => .{ .kind = .nint, .body = body, .int = be_int(body) },
        4 => .{ .kind = .float, .body = body },
        5 => .{ .kind = .decimal, .body = body },
        6 => .{ .kind = .timestamp, .body = body },
        7 => .{ .kind = .symbol, .body = body, .int = be_int(body) },
        8 => .{ .kind = .string, .body = body },
        9 => .{ .kind = .clob, .body = body },
        10 => .{ .kind = .blob, .body = body },
        11 => .{ .kind = .list, .body = body },
        12 => .{ .kind = .sexp, .body = body },
        13 => .{ .kind = .struct_, .body = body },
        else => return error.BadType,
    };
    return .{ .value = value };
}

/// Decode the value at `position`, looking through annotations. Padding comes back as
/// `.pad`: inside a struct a field ID follows it, not a value.
pub fn decode(data: []const u8, position: *u32) Error!Value {
    assert(data.len <= size_max);
    assert(position.* <= data.len);
    const start = position.*;
    // An annotation wrapper's bytes, and where in them the wrapped value starts.
    var wrapper: []const u8 = data;
    var wrapped: u32 = 0;
    var cursor = position;
    for (0..annotation_wrappers_max + 1) |_| {
        switch (try read_one(wrapper, cursor)) {
            .value => |value| {
                assert(position.* > start);
                assert(value.body.len < position.* - start);
                return value;
            },
            .annotation => |body| {
                wrapped = 0;
                const annotations_size = try read_var_uint(body, &wrapped);
                if (annotations_size > body.len - wrapped) return error.Truncated;
                wrapped += @intCast(annotations_size);
                wrapper = body;
                cursor = &wrapped;
            },
        }
    }
    return error.TooDeep;
}

/// Decode a whole Ion stream, skipping the version marker if present.
pub fn parse(data: []const u8) Error!Value {
    if (data.len > size_max) return error.TooLarge;
    var position: u32 = 0;
    if (data.len >= version_marker.len and std.mem.eql(u8, data[0..4], version_marker)) {
        position = version_marker.len;
    }
    // Bounded: every value read moves the position on by at least a byte.
    while (position < data.len) {
        const value = try decode(data, &position);
        assert(position <= data.len);
        if (value.kind != .pad) return value;
    }
    assert(position == data.len);
    return error.Truncated;
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
    // Annotation (symbol 4) on the list [1, 2].
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

test "an annotation longer than its wrapper is refused, not a crash" {
    // An annotation wrapper whose annotation list claims 2^64 - 1 bytes.
    const d = [_]u8{ 0xeb, 0x01, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0xff, 0x20 };
    try std.testing.expectError(error.Truncated, parse(&d));
}

test "annotations nested past the limit are refused" {
    // Nine wrappers, each with an empty annotation list, around the number 1.
    var d: [3 * 9 + 2]u8 = undefined;
    for (0..9) |wrapper| {
        const inside: u8 = @intCast(3 * (9 - wrapper - 1) + 3);
        d[3 * wrapper ..][0..3].* = .{ 0xee, 0x80 | inside, 0x80 };
    }
    d[27..29].* = .{ 0x21, 1 };
    try std.testing.expectError(error.TooDeep, parse(&d));
    // Eight are tolerated.
    try std.testing.expectEqual(@as(u64, 1), (try parse(d[3..])).int);
}

/// Reads every value inside `root`, the way the KFX parser does, to reach all the code
/// a hostile file could steer. Depth first, with a stack as deep as the walk may go.
fn walk_all(root: Value) void {
    const depth_max = 40;
    const Frame = struct { items: Items, fields: Fields, items_done: bool = false };
    assert(root.kind != .pad);
    var stack: [depth_max]Frame = undefined;
    var count: u32 = 1;
    stack[0] = .{ .items = root.items(), .fields = root.fields() };
    _ = .{ root.text(), root.symbol(), root.number() };
    // Bounded: every step reads a value or pops a frame, and frames hold finite bytes.
    while (count > 0) {
        assert(count <= depth_max);
        const top = &stack[count - 1];
        const item = if (top.items_done) null else top.items.next();
        if (item == null) top.items_done = true;
        const child = item orelse if (top.fields.next()) |field| field.value else {
            count -= 1;
            continue;
        };
        _ = .{ child.text(), child.symbol(), child.number() };
        if (count < depth_max) {
            stack[count] = .{ .items = child.items(), .fields = child.fields() };
            count += 1;
        }
    }
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
        walk_all(v);
    }
}
