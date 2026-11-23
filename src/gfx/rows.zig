//! Pictures leave the decoders row by row, into a `Sink` that scales them to the size
//! wanted as they come, so a whole picture is never held: a box filter whose sums are
//! kept per column while rows come in order, or per pixel while an interlaced PNG's
//! passes come. The grays are exactly `scale`'s, the box filter over a whole picture.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const decoded = @import("decoded.zig");

pub const Size = struct { width: u32, height: u32 };

/// The size a picture leaves at.
pub const Target = union(enum) {
    size: Size, // This size, whatever the picture's shape
    fit: Size, // As large as fits this box, in the picture's shape
    divided: u8, // Its own size divided by this, rounded up: 1 keeps it as it is
};

/// How rows come: in order, top to bottom, or as an interlaced PNG's passes, each a
/// row with pixels some columns apart.
pub const Order = enum { rows, passes };

/// The source pixels target pixel `index` averages, of `source` along a side shrunk or
/// grown to `target`: as `scale` works them out.
pub const Span = struct { from: u32, to: u32 };

fn span(index: u32, source: u32, target: u32) Span {
    assert(index < target);
    assert(source > 0);
    const from: u32 = @intCast(@as(u64, index) * source / target);
    const to = @max(@as(u32, @intCast(@as(u64, index + 1) * source / target)), from + 1);
    assert(to <= source);
    return .{ .from = from, .to = to };
}

/// The target pixels source pixel `index` counts toward: one when a side shrinks, a
/// run when it grows (each of those that pixel alone). The other way round from `span`.
fn targets_of(index: u32, source: u32, target: u32) Span {
    assert(index < source);
    assert(target > 0);
    if (target <= source) {
        const only: u32 = @intCast(((@as(u64, index) + 1) * target - 1) / source);
        return .{ .from = only, .to = only + 1 };
    }
    const from: u32 = @intCast(divide_up(@as(u64, index) * target, source));
    const to: u32 = @intCast(divide_up((@as(u64, index) + 1) * target, source));
    assert(to > from);
    return .{ .from = from, .to = to };
}

/// `a / b`, rounded up.
pub fn divide_up(a: u64, b: u64) u64 {
    assert(b > 0);
    assert(a <= std.math.maxInt(u64) - b);
    return (a + b - 1) / b;
}

/// Box filter: each output pixel averages the source pixels it covers.
pub fn scale(source: []const u8, source_size: Size, target: []u8, target_size: Size) void {
    assert(source_size.width > 0);
    assert(source_size.height > 0);
    assert(source.len >= @as(u64, source_size.width) * source_size.height);
    assert(target.len >= @as(u64, target_size.width) * target_size.height);
    const sw = source_size.width;
    const sh = source_size.height;
    const dw = target_size.width;
    const dh = target_size.height;
    // In 64 bits: a picture can be millions of pixels along one side
    for (0..dh) |y| {
        const y0: u32 = @intCast(@as(u64, y) * sh / dh);
        const y1 = @max(@as(u32, @intCast(@as(u64, y + 1) * sh / dh)), y0 + 1);
        for (0..dw) |x| {
            const x0: u32 = @intCast(@as(u64, x) * sw / dw);
            const x1 = @max(@as(u32, @intCast(@as(u64, x + 1) * sw / dw)), x0 + 1);
            var sum: u32 = 0;
            for (y0..y1) |sy| {
                for (x0..x1) |sx| sum += source[sy * sw + sx];
            }
            target[y * dw + x] = @intCast(sum / ((y1 - y0) * (x1 - x0)));
        }
    }
}

/// The largest size with a picture's shape that fits inside a box.
pub fn fitted(picture: Size, box: Size) Size {
    assert(picture.width > 0);
    assert(picture.height > 0);
    assert(box.width > 0);
    assert(box.height > 0);
    const w: u64 = picture.width;
    const h: u64 = picture.height;
    var fit: Size = undefined;
    if (w * box.height > h * box.width) {
        fit = .{ .width = box.width, .height = @intCast(@max(1, h * box.width / w)) };
    } else {
        fit = .{ .width = @intCast(@max(1, w * box.height / h)), .height = box.height };
    }
    assert(fit.width <= box.width);
    assert(fit.height <= box.height);
    return fit;
}

/// Where a decoder's rows go. Set `target` and `out`, hand it to the decoder, which
/// calls `begin` once it knows the picture's size and then gives it every row; then
/// `finish` gives the pixels, owned by `out`. `abandon` frees them if decoding failed.
pub const Sink = struct {
    target: Target,
    out: Allocator,
    /// The most pixels the result may have: a larger one is out of memory.
    pixels_max: u64 = decoded.pixels_max,
    source: Size = .{ .width = 0, .height = 0 },
    size: Size = .{ .width = 0, .height = 0 },
    pixels: []u8 = &.{}, // Made by `begin`: none while waiting
    mode: Mode = .waiting,
    rows_in: u32 = 0,
    rows_out: u32 = 0,

    /// How rows become the result: copied or scattered at the picture's own size, or
    /// summed into boxes when it's scaled.
    pub const Mode = union(enum) {
        waiting, // For `begin`
        copy, // Rows in order, as they are
        scatter, // An interlaced picture's passes, as they are
        /// Rows in order, scaled: a sum per target column, and its source columns.
        box: struct { sums: Sums, columns: []Span },
        cells: Sums, // Passes, scaled: a sum per target pixel
        done,
    };

    /// Sums of source grays, in 32 bits when no box can overflow them.
    pub const Sums = union(enum) { narrow: []u32, wide: []u64 };

    /// The size the picture leaves at, now its own is known.
    fn size_for(target: Target, source: Size) Size {
        assert(source.width > 0);
        assert(source.height > 0);
        return switch (target) {
            .size => |s| s,
            .fit => |box| fitted(source, box),
            .divided => |by| divided: {
                assert(by > 0);
                break :divided .{
                    .width = @intCast(divide_up(source.width, by)),
                    .height = @intCast(divide_up(source.height, by)),
                };
            },
        };
    }

    /// Makes room for a picture of `source` pixels, its rows coming in `order`: the
    /// result's in `out`, the sums in `work`.
    pub fn begin(sink: *Sink, work: Allocator, source: Size, order: Order) !void {
        assert(sink.mode == .waiting);
        assert(source.width > 0);
        assert(source.height > 0);
        const size = size_for(sink.target, source);
        assert(size.width > 0);
        assert(size.height > 0);
        const count = @as(u64, size.width) * size.height;
        if (count > sink.pixels_max) return error.OutOfMemory;
        sink.source = source;
        sink.size = size;
        sink.pixels = try sink.out.alloc(u8, @intCast(count));
        errdefer sink.abandon();
        const same = size.width == source.width and size.height == source.height;
        if (same) {
            sink.mode = if (order == .rows) .copy else .scatter;
            return;
        }
        // In 32 bits when a whole box of white fits them
        const box_pixels = divide_up(source.width, size.width) *
            divide_up(source.height, size.height);
        const narrow = box_pixels * 255 <= std.math.maxInt(u32);
        const sums_count: u64 = if (order == .rows) size.width else count;
        const sums: Sums = if (narrow)
            .{ .narrow = try work.alloc(u32, @intCast(sums_count)) }
        else
            .{ .wide = try work.alloc(u64, @intCast(sums_count)) };
        switch (sums) {
            inline else => |s| @memset(s, 0),
        }
        if (order == .passes) {
            sink.mode = .{ .cells = sums };
            return;
        }
        const columns = try work.alloc(Span, size.width);
        for (columns, 0..) |*column, x| column.* = span(@intCast(x), source.width, size.width);
        sink.mode = .{ .box = .{ .sums = sums, .columns = columns } };
    }

    /// The next row, in order, of at least the picture's width.
    pub fn put_row(sink: *Sink, row: []const u8) void {
        assert(row.len >= sink.source.width);
        assert(sink.rows_in < sink.source.height);
        const y = sink.rows_in;
        sink.rows_in += 1;
        const width = sink.size.width;
        switch (sink.mode) {
            .copy => @memcpy(sink.pixels[y * width ..][0..width], row[0..width]),
            .box => |box| switch (box.sums) {
                inline else => |sums| sink.put_row_box(sums, box.columns, row),
            },
            .waiting, .scatter, .cells, .done => unreachable, // Rows come in order
        }
    }

    /// Adds a row to each target column's sum, and writes out every target row it ends.
    fn put_row_box(sink: *Sink, sums: anytype, columns: []const Span, row: []const u8) void {
        const Sum = @typeInfo(@TypeOf(sums)).pointer.child;
        assert(sink.mode == .box);
        assert(sums.len == sink.size.width);
        const y = sink.rows_in - 1;
        add_row(Sum, sums, columns, row);
        const height = sink.size.height;
        // Target rows end in order; growing, several end at the same source row
        while (sink.rows_out < height) {
            const rows = span(sink.rows_out, sink.source.height, height);
            if (rows.to != y + 1) break;
            const line = sink.pixels[sink.rows_out * sink.size.width ..][0..sink.size.width];
            emit_row(Sum, line, sums, columns, rows.to - rows.from);
            sink.rows_out += 1;
            const next_from = if (sink.rows_out < height)
                span(sink.rows_out, sink.source.height, height).from
            else
                y + 1;
            if (next_from != y) @memset(sums, 0);
        }
        assert(sink.rows_out <= height);
    }

    /// A row of an interlaced pass: `values` are the pixels of picture row `y` at
    /// columns `x_start`, `x_start + x_step`, and so on.
    pub fn put_pass_row(sink: *Sink, y: u32, x_start: u32, x_step: u32, values: []const u8) void {
        assert(y < sink.source.height);
        assert(x_step > 0);
        if (values.len > 0) assert(x_start + (values.len - 1) * x_step < sink.source.width);
        switch (sink.mode) {
            .scatter => {
                const line = sink.pixels[y * sink.size.width ..][0..sink.size.width];
                for (values, 0..) |value, index| line[x_start + index * x_step] = value;
            },
            .cells => |sums| switch (sums) {
                inline else => |s| sink.put_cells(s, y, x_start, x_step, values),
            },
            .waiting, .copy, .box, .done => unreachable, // Passes come as passes
        }
    }

    fn put_cells(
        sink: *Sink,
        sums: anytype,
        y: u32,
        x_start: u32,
        x_step: u32,
        values: []const u8,
    ) void {
        assert(sink.mode == .cells);
        assert(sums.len == @as(u64, sink.size.width) * sink.size.height);
        const width = sink.size.width;
        const rows = targets_of(y, sink.source.height, sink.size.height);
        for (values, 0..) |value, index| {
            const x: u32 = @intCast(x_start + index * x_step);
            const columns = targets_of(x, sink.source.width, width);
            for (rows.from..rows.to) |row| {
                for (sums[row * width + columns.from ..][0 .. columns.to - columns.from]) |*sum| {
                    sum.* += value;
                }
            }
        }
    }

    /// The scaled picture, once every row has come. The caller owns it.
    pub fn finish(sink: *Sink) []u8 {
        switch (sink.mode) {
            .copy => assert(sink.rows_in == sink.source.height),
            .box => {
                assert(sink.rows_in == sink.source.height);
                assert(sink.rows_out == sink.size.height);
            },
            .cells => |sums| switch (sums) {
                inline else => |s| sink.finish_cells(s),
            },
            .scatter => {},
            .waiting, .done => unreachable, // Begun, and finished once
        }
        sink.mode = .done;
        const pixels = sink.pixels;
        sink.pixels = &.{};
        assert(pixels.len == @as(u64, sink.size.width) * sink.size.height);
        return pixels;
    }

    fn finish_cells(sink: *Sink, sums: anytype) void {
        const Sum = @typeInfo(@TypeOf(sums)).pointer.child;
        assert(sink.mode == .cells);
        assert(sums.len == sink.pixels.len);
        const width = sink.size.width;
        for (0..sink.size.height) |row| {
            const rows = span(@intCast(row), sink.source.height, sink.size.height);
            for (0..width) |column| {
                const columns = span(@intCast(column), sink.source.width, width);
                const area = @as(Sum, rows.to - rows.from) * (columns.to - columns.from);
                sink.pixels[row * width + column] = @intCast(sums[row * width + column] / area);
            }
        }
    }

    /// Frees the result of a picture that won't finish, if `begin` made one, ready to
    /// `begin` again. The sums are the work allocator's.
    pub fn abandon(sink: *Sink) void {
        assert(sink.mode != .done);
        sink.out.free(sink.pixels); // Empty while waiting: freeing none frees nothing
        sink.* = .{ .target = sink.target, .out = sink.out, .pixels_max = sink.pixels_max };
        assert(sink.mode == .waiting);
    }
};

/// Adds a source row to each target column's sum. A hot loop: plain arguments.
fn add_row(comptime Sum: type, sums: []Sum, columns: []const Span, row: []const u8) void {
    assert(sums.len == columns.len);
    assert(columns.len > 0);
    for (sums, columns) |*sum, column| {
        var add: u32 = 0;
        for (row[column.from..column.to]) |value| add += value;
        sum.* += add;
    }
}

/// A target row from its sums, each averaged over its box.
fn emit_row(
    comptime Sum: type,
    line: []u8,
    sums: []const Sum,
    columns: []const Span,
    rows: u32,
) void {
    assert(line.len == sums.len);
    assert(rows > 0);
    for (line, sums, columns) |*pixel, sum, column| {
        const area = @as(Sum, rows) * (column.to - column.from);
        pixel.* = @intCast(sum / area);
    }
}

fn test_scaled(source: []const u8, source_size: Size, size: Size, order: Order) ![]u8 {
    assert(source.len == @as(u64, source_size.width) * source_size.height);
    assert(size.width > 0);
    var sink = Sink{ .target = .{ .size = size }, .out = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sink.begin(arena.allocator(), source_size, order);
    const w = source_size.width;
    if (order == .rows) {
        for (0..source_size.height) |y| sink.put_row(source[y * w ..][0..w]);
        return sink.finish();
    }
    // Adam7's passes, as a PNG's come
    const starts = [_][2]u8{
        .{ 0, 0 }, .{ 4, 0 }, .{ 0, 4 }, .{ 2, 0 }, .{ 0, 2 }, .{ 1, 0 }, .{ 0, 1 },
    };
    const steps = [_][2]u8{
        .{ 8, 8 }, .{ 8, 8 }, .{ 4, 8 }, .{ 4, 4 }, .{ 2, 4 }, .{ 2, 2 }, .{ 1, 2 },
    };
    var values: [64]u8 = undefined;
    for (starts, steps) |start, step| {
        var y: u32 = start[1];
        while (y < source_size.height) : (y += step[1]) {
            var count: u32 = 0;
            var x: u32 = start[0];
            while (x < w) : (x += step[0]) {
                values[count] = source[y * w + x];
                count += 1;
            }
            sink.put_pass_row(y, start[0], step[0], values[0..count]);
        }
    }
    return sink.finish();
}

test "rows scaled as they come are exactly the whole picture scaled" {
    var prng = std.Random.DefaultPrng.init(0x726f7773);
    const random = prng.random();
    var source: [64 * 64]u8 = undefined;
    var whole: [80 * 80]u8 = undefined;
    for (0..400) |_| {
        const source_size = Size{
            .width = 1 + random.uintLessThan(u32, 64),
            .height = 1 + random.uintLessThan(u32, 64),
        };
        const size = Size{
            .width = 1 + random.uintLessThan(u32, 80),
            .height = 1 + random.uintLessThan(u32, 80),
        };
        const pixels = source[0 .. source_size.width * source_size.height];
        random.bytes(pixels);
        const want = whole[0 .. size.width * size.height];
        scale(pixels, source_size, want, size);
        for ([_]Order{ .rows, .passes }) |order| {
            const got = try test_scaled(pixels, source_size, size, order);
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualSlices(u8, want, got);
        }
    }
}

test "a picture kept at its size comes out as it went in" {
    var source: [12 * 7]u8 = undefined;
    for (&source, 0..) |*pixel, index| pixel.* = @intCast(index * 3 % 256);
    const size = Size{ .width = 12, .height = 7 };
    for ([_]Order{ .rows, .passes }) |order| {
        const got = try test_scaled(&source, size, size, order);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualSlices(u8, &source, got);
    }
}

test "a box too large for 32-bit sums is summed in 64" {
    // 5000 x 4000 white to one pixel: 20 million times 255 is past 32 bits
    const one = Size{ .width = 1, .height = 1 };
    var sink = Sink{ .target = .{ .size = one }, .out = std.testing.allocator };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try sink.begin(arena.allocator(), .{ .width = 5000, .height = 4000 }, .rows);
    try std.testing.expectEqual(@as(usize, 1), sink.mode.box.sums.wide.len);
    const white: [5000]u8 = @splat(255);
    for (0..4000) |_| sink.put_row(&white);
    const got = sink.finish();
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(u8, 255), got[0]);
    // A small box sums in 32 bits
    var small = Sink{ .target = .{ .size = one }, .out = std.testing.allocator };
    try small.begin(arena.allocator(), .{ .width = 100, .height = 100 }, .rows);
    try std.testing.expectEqual(@as(usize, 1), small.mode.box.sums.narrow.len);
    small.abandon();
    // A result past the most pixels allowed has no room
    var many = Sink{ .target = .{ .divided = 1 }, .out = std.testing.allocator, .pixels_max = 10 };
    const twelve = Size{ .width = 4, .height = 3 };
    try std.testing.expectError(error.OutOfMemory, many.begin(arena.allocator(), twelve, .rows));
}
