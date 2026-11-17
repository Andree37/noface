//! Turns a glyph's outline into 8-bit coverage: how much of each pixel the glyph
//! covers, antialiased exactly, with no supersampling.
//!
//! A port of stb_truetype's second rasterizer, in its order of floating-point
//! operations, so glyphs come out as it drew them: curves cut into lines until each
//! is within 0.35 of a pixel of the curve, the lines sorted by their tops, and each
//! scanline's coverage summed from the signed area every line sweeps across it.
const std = @import("std");
const assert = std.debug.assert;
const Vertex = @import("outline.zig").Vertex;

pub const Error = error{OutOfMemory};

/// How far, in pixels, a line may stray from the curve it stands for.
const flatness_px = 0.35;
/// A curve is cut in half at most this many times over: 65536 lines is plenty.
const split_depth_max = 16;
/// Partitions the edge sort may have waiting: it always keeps the larger one for
/// later, so each is under half the one before, and 64 covers any count.
const sort_stack_max = 64;
/// Below this many edges, the sort finishes by insertion.
const sort_insertion_max = 12;
/// Scanline widths that fit the rasterizer's stack buffer, as stb_truetype had.
const scanline_stack_width_max = 64;

comptime {
    assert(flatness_px > 0);
    assert(split_depth_max < 32);
    assert(scanline_stack_width_max * 2 + 1 == 129);
}

const Point = struct { x: f32, y: f32 };

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, invert: bool };

const ActiveEdge = struct {
    fx: f32,
    fdx: f32,
    fdy: f32,
    direction: f32,
    sy: f32,
    ey: f32,
};

/// Where a glyph's bitmap lies: its top-left pixel, in pixels from the glyph's origin,
/// and its size.
pub const Box = struct { x: i32, y: i32, width: u32, height: u32 };

/// Draws `vertices`, scaled by `scale` (y flipped, so up is down the bitmap), into
/// `pixels`, the bitmap of `box`. `pixels` must start zeroed.
pub fn rasterize(
    alloc: std.mem.Allocator,
    vertices: []const Vertex,
    scale: f32,
    box: Box,
    pixels: []u8,
) Error!void {
    assert(scale > 0);
    assert(pixels.len == @as(u64, box.width) * box.height);
    const flatness = flatness_px / scale;
    const flat = try flatten(alloc, vertices, flatness * flatness);
    defer flat.free(alloc);
    if (flat.contour_lengths.len == 0) return;
    var edge_count: u32 = 0;
    for (flat.contour_lengths) |length| edge_count += length;
    // One more, past the end, to stop the scan
    const edges = try alloc.alloc(Edge, edge_count + 1);
    defer alloc.free(edges);
    const used = make_edges(&flat, scale, edges);
    sort_edges(edges[0..used]);
    try rasterize_sorted(alloc, edges[0 .. used + 1], used, box, pixels);
    assert(used <= edge_count);
}

/// The outline as polygons: points, and how many each contour has.
const Flat = struct {
    points: []Point,
    contour_lengths: []u32,

    fn free(flat: *const Flat, alloc: std.mem.Allocator) void {
        assert(flat.points.len <= std.math.maxInt(u32));
        assert(flat.contour_lengths.len <= flat.points.len + 1);
        alloc.free(flat.points);
        alloc.free(flat.contour_lengths);
    }
};

/// Cuts curves into lines, as stb_truetype's two passes did: one to count the points,
/// one to keep them.
fn flatten(alloc: std.mem.Allocator, vertices: []const Vertex, flatness_squared: f32) Error!Flat {
    assert(flatness_squared > 0);
    var contours: u32 = 0;
    for (vertices) |v| {
        if (v.kind == .move) contours += 1;
    }
    if (contours == 0) return .{ .points = &.{}, .contour_lengths = &.{} };
    const contour_lengths = try alloc.alloc(u32, contours);
    errdefer alloc.free(contour_lengths);
    @memset(contour_lengths, 0);
    const count = flatten_pass(vertices, flatness_squared, null, contour_lengths);
    const points = try alloc.alloc(Point, count);
    const kept = flatten_pass(vertices, flatness_squared, points, contour_lengths);
    assert(kept == count);
    return .{ .points = points, .contour_lengths = contour_lengths };
}

/// One pass over the outline: counts its points, and keeps them when given room.
/// Returns how many there are.
fn flatten_pass(
    vertices: []const Vertex,
    flatness_squared: f32,
    points: ?[]Point,
    contour_lengths: []u32,
) u32 {
    assert(contour_lengths.len > 0);
    var count: u32 = 0;
    var contour: ?u32 = null;
    var start: u32 = 0;
    var x: f32 = 0;
    var y: f32 = 0;
    for (vertices) |v| {
        const end = Point{ .x = @floatFromInt(v.x), .y = @floatFromInt(v.y) };
        switch (v.kind) {
            .move => {
                if (contour) |c| contour_lengths[c] = count - start;
                contour = if (contour) |c| c + 1 else 0;
                start = count;
                add_point(points, &count, end);
            },
            .line => add_point(points, &count, end),
            .curve => {
                const control = Point{ .x = @floatFromInt(v.cx), .y = @floatFromInt(v.cy) };
                split_curve(points, &count, .{ .x = x, .y = y }, control, end, flatness_squared);
            },
            .cubic => {
                const c0 = Point{ .x = @floatFromInt(v.cx), .y = @floatFromInt(v.cy) };
                const c1 = Point{ .x = @floatFromInt(v.cx1), .y = @floatFromInt(v.cy1) };
                const p = [4]Point{ .{ .x = x, .y = y }, c0, c1, end };
                split_cubic(points, &count, &p, flatness_squared);
            },
        }
        x = end.x;
        y = end.y;
    }
    // Counted above: there is at least one move, so a contour
    contour_lengths[contour.?] = count - start;
    assert(count >= start);
    return count;
}

fn add_point(points: ?[]Point, count: *u32, point: Point) void {
    if (points) |kept| kept[count.*] = point;
    count.* += 1;
    assert(count.* > 0);
}

/// A quadratic curve still to cut, and how many times it was cut already.
const CurvePiece = struct { p0: Point, p1: Point, p2: Point, depth: u32 };

/// Cuts a quadratic curve in halves until each is flat enough, first half first.
fn split_curve(
    points: ?[]Point,
    count: *u32,
    p0: Point,
    p1: Point,
    p2: Point,
    flatness_squared: f32,
) void {
    assert(flatness_squared > 0);
    // A piece is replaced by two at most once per depth: the stack holds one waiting
    // second half per depth, and the piece in hand
    var stack: [split_depth_max + 2]CurvePiece = undefined;
    stack[0] = .{ .p0 = p0, .p1 = p1, .p2 = p2, .depth = 0 };
    var stack_count: u32 = 1;
    while (stack_count > 0) {
        stack_count -= 1;
        const piece = stack[stack_count];
        const mx = (piece.p0.x + 2 * piece.p1.x + piece.p2.x) / 4;
        const my = (piece.p0.y + 2 * piece.p1.y + piece.p2.y) / 4;
        const dx = (piece.p0.x + piece.p2.x) / 2 - mx;
        const dy = (piece.p0.y + piece.p2.y) / 2 - my;
        if (piece.depth > split_depth_max) continue;
        if (dx * dx + dy * dy > flatness_squared) {
            const middle = Point{ .x = mx, .y = my };
            const depth = piece.depth + 1;
            assert(stack_count + 2 <= stack.len);
            const second_control = half(piece.p1, piece.p2);
            const first_control = half(piece.p0, piece.p1);
            stack[stack_count] = .{
                .p0 = middle,
                .p1 = second_control,
                .p2 = piece.p2,
                .depth = depth,
            };
            stack[stack_count + 1] = .{
                .p0 = piece.p0,
                .p1 = first_control,
                .p2 = middle,
                .depth = depth,
            };
            stack_count += 2;
        } else {
            add_point(points, count, piece.p2);
        }
    }
    assert(stack_count == 0);
}

fn half(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

const CubicPiece = struct { p: [4]Point, depth: u32 };

/// Cuts a cubic curve in halves until stb_truetype's measure of flatness is met.
fn split_cubic(points: ?[]Point, count: *u32, p: *const [4]Point, flatness_squared: f32) void {
    var stack: [split_depth_max + 2]CubicPiece = undefined;
    stack[0] = .{ .p = p.*, .depth = 0 };
    var stack_count: u32 = 1;
    while (stack_count > 0) {
        stack_count -= 1;
        const piece = stack[stack_count];
        const q = piece.p;
        if (cubic_flatness_squared(&q) > flatness_squared and piece.depth <= split_depth_max) {
            const p01 = half(q[0], q[1]);
            const p12 = half(q[1], q[2]);
            const p23 = half(q[2], q[3]);
            const a = half(p01, p12);
            const b = half(p12, p23);
            const m = half(a, b);
            const depth = piece.depth + 1;
            assert(stack_count + 2 <= stack.len);
            stack[stack_count] = .{ .p = .{ m, b, p23, q[3] }, .depth = depth };
            stack[stack_count + 1] = .{ .p = .{ q[0], p01, a, m }, .depth = depth };
            stack_count += 2;
        } else if (piece.depth <= split_depth_max) {
            add_point(points, count, q[3]);
        }
    }
    assert(stack_count == 0);
}

/// The length of the control polygon squared, less that of the chord squared: made
/// up by stb_truetype, and kept, so curves are cut where they were.
fn cubic_flatness_squared(q: *const [4]Point) f32 {
    assert(q.len == 4);
    const dx0 = q[1].x - q[0].x;
    const dy0 = q[1].y - q[0].y;
    const dx1 = q[2].x - q[1].x;
    const dy1 = q[2].y - q[1].y;
    const dx2 = q[3].x - q[2].x;
    const dy2 = q[3].y - q[2].y;
    const dx = q[3].x - q[0].x;
    const dy = q[3].y - q[0].y;
    // The square roots in double precision, as C's sqrt took them
    const long_length: f32 = @floatCast(@sqrt(@as(f64, dx0 * dx0 + dy0 * dy0)) +
        @sqrt(@as(f64, dx1 * dx1 + dy1 * dy1)) + @sqrt(@as(f64, dx2 * dx2 + dy2 * dy2)));
    const short_length: f32 = @floatCast(@sqrt(@as(f64, dx * dx + dy * dy)));
    assert(!(long_length < 0));
    return long_length * long_length - short_length * short_length;
}

/// The polygons' edges, scaled to pixels, y flipped, each pointing down. Horizontal
/// ones cover nothing and are left out. Returns how many there are.
fn make_edges(flat: *const Flat, scale: f32, edges: []Edge) u32 {
    assert(scale != 0);
    var count: u32 = 0;
    var start: u32 = 0;
    for (flat.contour_lengths) |length| {
        const p = flat.points[start..][0..length];
        start += length;
        if (length == 0) continue;
        var j: u32 = length - 1;
        for (0..length) |k| {
            defer j = @intCast(k);
            if (p[j].y == p[k].y) continue;
            // Flipped, so an edge pointing up the font points down the bitmap
            const invert = p[j].y > p[k].y;
            const a = if (invert) p[j] else p[k];
            const b = if (invert) p[k] else p[j];
            // Adding stb_truetype's zero shift turns a -0 into a 0, as it did
            edges[count] = .{
                .x0 = a.x * scale + 0,
                .y0 = a.y * -scale + 0,
                .x1 = b.x * scale + 0,
                .y1 = b.y * -scale + 0,
                .invert = invert,
            };
            count += 1;
        }
    }
    assert(count < edges.len);
    return count;
}

fn edge_above(a: *const Edge, b: *const Edge) bool {
    return a.y0 < b.y0;
}

fn swap_edges(edges: []Edge, a: u32, b: u32) void {
    assert(a < edges.len);
    assert(b < edges.len);
    const t = edges[a];
    edges[a] = edges[b];
    edges[b] = t;
}

/// Sorts edges by their tops, exactly as stb_truetype did (its quicksort, then an
/// insertion sort), so that edges with the same top keep its order.
fn sort_edges(edges: []Edge) void {
    assert(edges.len <= std.math.maxInt(u32));
    var stack: [sort_stack_max][2]u32 = undefined;
    stack[0] = .{ 0, @intCast(edges.len) };
    var stack_count: u32 = 1;
    while (stack_count > 0) {
        stack_count -= 1;
        var offset = stack[stack_count][0];
        var n = stack[stack_count][1];
        // Each turn sorts a partition around a pivot, keeps the larger part for later
        // and goes on with the smaller, so the parts waiting stay few
        while (n > sort_insertion_max) {
            const part = edges[offset..][0..n];
            const split = partition(part);
            if (split.j < n - split.i) {
                stack[stack_count] = .{ offset + split.i, n - split.i };
                n = split.j;
            } else {
                stack[stack_count] = .{ offset, split.j };
                offset += split.i;
                n -= split.i;
            }
            stack_count += 1;
            assert(stack_count < sort_stack_max);
        }
    }
    insertion_sort(edges);
}

const Split = struct { i: u32, j: u32 };

/// The partition stb_truetype used: the median of three as the pivot, moved to the
/// front.
fn partition(p: []Edge) Split {
    assert(p.len > sort_insertion_max);
    const n: u32 = @intCast(p.len);
    const m = n >> 1;
    const c01 = edge_above(&p[0], &p[m]);
    const c12 = edge_above(&p[m], &p[n - 1]);
    if (c01 != c12) {
        const c = edge_above(&p[0], &p[n - 1]);
        const z: u32 = if (c == c12) 0 else n - 1;
        swap_edges(p, z, m);
    }
    swap_edges(p, 0, m);
    var i: u32 = 1;
    var j: u32 = n - 1;
    // Each turn moves i up and j down, so they meet within n turns
    for (0..n) |_| {
        while (i < n and edge_above(&p[i], &p[0])) i += 1;
        while (j > 0 and edge_above(&p[0], &p[j])) j -= 1;
        if (i >= j) break;
        swap_edges(p, i, j);
        i += 1;
        j -= 1;
    }
    assert(i <= n);
    assert(i >= j);
    return .{ .i = i, .j = j };
}

fn insertion_sort(edges: []Edge) void {
    assert(edges.len <= std.math.maxInt(u32));
    if (edges.len < 2) return;
    for (1..edges.len) |i| {
        const t = edges[i];
        var j = i;
        while (j > 0 and edge_above(&t, &edges[j - 1])) : (j -= 1) edges[j] = edges[j - 1];
        if (i != j) edges[j] = t;
    }
}

/// Sweeps the sorted edges down the bitmap a scanline at a time. `edges` holds one
/// more past the `count` real ones, set here to stop the sweep.
fn rasterize_sorted(
    alloc: std.mem.Allocator,
    edges: []Edge,
    count: u32,
    box: Box,
    pixels: []u8,
) Error!void {
    assert(edges.len == count + 1);
    assert(box.width > 0);
    const active = try alloc.alloc(ActiveEdge, count);
    defer alloc.free(active);
    var stack_buffer: [scanline_stack_width_max * 2 + 1]f32 = undefined;
    const wide = box.width > scanline_stack_width_max;
    const buffer = if (wide) try alloc.alloc(f32, box.width * 2 + 1) else &stack_buffer;
    defer if (wide) alloc.free(buffer);
    const scanline = buffer[0..box.width];
    const scanline2 = buffer[box.width..][0 .. box.width + 1];
    edges[count].y0 = @as(f32, @floatFromInt(box.y + @as(i32, @intCast(box.height)))) + 1;
    var active_count: u32 = 0;
    var next: u32 = 0;
    for (0..box.height) |row| {
        const y = box.y + @as(i32, @intCast(row));
        const top: f32 = @floatFromInt(y);
        const bottom = top + 1;
        @memset(scanline, 0);
        @memset(scanline2, 0);
        active_count = drop_finished(active[0..active_count], top);
        // The edge past the end starts below the box, and stops this
        while (edges[next].y0 <= bottom) : (next += 1) {
            const e = &edges[next];
            if (e.y0 == e.y1) continue;
            var z = new_active(e, box.x, top);
            if (row == 0 and box.y != 0 and z.ey < top) z.ey = top;
            // Newest first, as stb_truetype kept its list: the end of this array
            active[active_count] = z;
            active_count += 1;
        }
        if (active_count > 0) fill_active_edges(scanline, scanline2, active[0..active_count], top);
        accumulate(scanline, scanline2, pixels[row * box.width ..][0..box.width]);
        for (active[0..active_count]) |*z| z.fx += z.fdx;
    }
    assert(next <= count);
    assert(active_count <= count);
}

/// Removes edges ending above `top`, keeping the others in order. Returns how many
/// are left.
fn drop_finished(active: []ActiveEdge, top: f32) u32 {
    assert(active.len <= std.math.maxInt(u32));
    var kept: u32 = 0;
    for (active) |z| {
        if (z.ey <= top) continue;
        active[kept] = z;
        kept += 1;
    }
    assert(kept <= active.len);
    return kept;
}

fn new_active(e: *const Edge, x_offset: i32, start: f32) ActiveEdge {
    assert(e.y0 != e.y1);
    const dxdy = (e.x1 - e.x0) / (e.y1 - e.y0);
    var fx = e.x0 + dxdy * (start - e.y0);
    fx -= @floatFromInt(x_offset);
    const z = ActiveEdge{
        .fdx = dxdy,
        .fdy = if (dxdy != 0) 1 / dxdy else 0,
        .fx = fx,
        .direction = if (e.invert) 1 else -1,
        .sy = e.y0,
        .ey = e.y1,
    };
    assert(z.direction != 0);
    return z;
}

/// Each pixel's coverage: its own area, plus the running sum of areas carried in
/// from the left, made absolute and scaled to 0..255.
fn accumulate(scanline: []const f32, scanline2: []const f32, row: []u8) void {
    assert(scanline.len == row.len);
    assert(scanline2.len == row.len + 1);
    var sum: f32 = 0;
    for (row, scanline, scanline2[0..row.len]) |*pixel, area, carried| {
        sum += carried;
        const k = @abs(area + sum) * 255 + 0.5;
        // A NaN, from a damaged outline, is no coverage; more than full is full
        pixel.* = if (k >= 255) 255 else if (k >= 0) @intFromFloat(k) else 0;
    }
}

/// Adds the signed area of an edge's piece, clipped to the column at `x`.
fn handle_clipped_edge(scanline: []f32, x: i32, e: *const ActiveEdge, piece: [4]f32) void {
    var x0 = piece[0];
    var y0 = piece[1];
    var x1 = piece[2];
    var y1 = piece[3];
    if (y0 == y1) return;
    if (y0 > e.ey) return;
    if (y1 < e.sy) return;
    if (y0 < e.sy) {
        x0 += (x1 - x0) * (e.sy - y0) / (y1 - y0);
        y0 = e.sy;
    }
    if (y1 > e.ey) {
        x1 += (x1 - x0) * (e.ey - y1) / (y1 - y0);
        y1 = e.ey;
    }
    assert(x >= 0);
    assert(x < scanline.len);
    const left: f32 = @floatFromInt(x);
    if (x0 <= left and x1 <= left) {
        scanline[@intCast(x)] += e.direction * (y1 - y0);
    } else if (x0 >= left + 1 and x1 >= left + 1) {
        // Wholly to the right: nothing in this column
    } else {
        // Coverage is one less the average x position
        scanline[@intCast(x)] += e.direction * (y1 - y0) * (1 - ((x0 - left) + (x1 - left)) / 2);
    }
}

fn trapezoid_area(height: f32, top_width: f32, bottom_width: f32) f32 {
    return (top_width + bottom_width) / 2.0 * height;
}

/// The heart of the rasterizer: adds every active edge's area to this scanline. A
/// hot loop over plain arrays; each edge in stb_truetype's order, newest first.
fn fill_active_edges(scanline: []f32, scanline2: []f32, active: []const ActiveEdge, top: f32) void {
    assert(scanline2.len == scanline.len + 1);
    assert(active.len > 0);
    const length: f32 = @floatFromInt(scanline.len);
    var index = active.len;
    while (index > 0) {
        index -= 1;
        const e = &active[index];
        if (e.fdx == 0) {
            const x0 = e.fx;
            if (x0 < length) {
                if (x0 >= 0) {
                    const column: i32 = @intFromFloat(x0);
                    handle_clipped_edge(scanline, column, e, .{ x0, top, x0, top + 1 });
                    handle_clipped_edge(scanline2, column + 1, e, .{ x0, top, x0, top + 1 });
                } else {
                    handle_clipped_edge(scanline2, 0, e, .{ x0, top, x0, top + 1 });
                }
            }
        } else {
            fill_sloped_edge(scanline, scanline2, e, top);
        }
    }
}

/// A sloped edge across this scanline, from its top to its bottom (clipped to the
/// edge's own ends).
fn fill_sloped_edge(scanline: []f32, scanline2: []f32, e: *const ActiveEdge, top: f32) void {
    assert(e.fdx != 0);
    const bottom = top + 1;
    const x0 = e.fx;
    const xb = x0 + e.fdx;
    var x_top: f32 = undefined;
    var x_bottom: f32 = undefined;
    var sy0: f32 = undefined;
    var sy1: f32 = undefined;
    if (e.sy > top) {
        x_top = x0 + e.fdx * (e.sy - top);
        sy0 = e.sy;
    } else {
        x_top = x0;
        sy0 = top;
    }
    if (e.ey < bottom) {
        x_bottom = x0 + e.fdx * (e.ey - top);
        sy1 = e.ey;
    } else {
        x_bottom = xb;
        sy1 = bottom;
    }
    const length: f32 = @floatFromInt(scanline.len);
    const inside = x_top >= 0 and x_bottom >= 0 and x_top < length and x_bottom < length;
    if (!inside) {
        fill_clipped_edge(scanline, e, top, x0, xb);
        return;
    }
    // From here on, x values need no range checks
    const sloped = Sloped{ .x_top = x_top, .x_bottom = x_bottom, .sy0 = sy0, .sy1 = sy1 };
    if (@as(i32, @intFromFloat(x_top)) == @as(i32, @intFromFloat(x_bottom))) {
        fill_one_pixel(scanline, scanline2, e, &sloped);
    } else {
        fill_span(scanline, scanline2, e, top, &sloped);
    }
    assert(x_top >= 0);
}

const Sloped = struct { x_top: f32, x_bottom: f32, sy0: f32, sy1: f32 };

/// An edge within one pixel of this scanline.
fn fill_one_pixel(scanline: []f32, scanline2: []f32, e: *const ActiveEdge, s: *const Sloped) void {
    const x: i32 = @intFromFloat(s.x_top);
    assert(x >= 0);
    assert(x < scanline.len);
    const height = (s.sy1 - s.sy0) * e.direction;
    const right = @as(f32, @floatFromInt(x)) + 1.0;
    const at: u32 = @intCast(x);
    scanline[at] += trapezoid_area(height, right - s.x_top, right - s.x_bottom);
    // Everything right of this pixel is filled
    scanline2[at + 1] += height;
}

/// An edge across two or more pixels of this scanline.
fn fill_span(
    scanline: []f32,
    scanline2: []f32,
    e: *const ActiveEdge,
    top: f32,
    s: *const Sloped,
) void {
    assert(e.fdx != 0);
    assert(scanline2.len == scanline.len + 1);
    const bottom = top + 1;
    var x0 = e.fx;
    var dx = e.fdx;
    var dy = e.fdy;
    var x_top = s.x_top;
    var x_bottom = s.x_bottom;
    var sy0 = s.sy0;
    var sy1 = s.sy1;
    if (x_top > x_bottom) {
        // Flipped upside down: the signed area is the same
        const flipped_sy0 = bottom - (sy0 - top);
        const flipped_sy1 = bottom - (sy1 - top);
        sy0 = flipped_sy1;
        sy1 = flipped_sy0;
        const t = x_bottom;
        x_bottom = x_top;
        x_top = t;
        dx = -dx;
        dy = -dy;
        x0 = x0 + e.fdx;
    }
    const x1: i32 = @intFromFloat(x_top);
    const x2: i32 = @intFromFloat(x_bottom);
    assert(x1 < x2);
    var y_crossing = top + dy * (@as(f32, @floatFromInt(x1 + 1)) - x0);
    var y_final = top + dy * (@as(f32, @floatFromInt(x2)) - x0);
    // Where x2 is right at x1's edge, the crossing can run past the scanline
    if (y_crossing > bottom) y_crossing = bottom;
    const sign = e.direction;
    var area = sign * (y_crossing - sy0);
    // The triangle in the first pixel
    scanline[@intCast(x1)] += area * (@as(f32, @floatFromInt(x1 + 1)) - x_top) / 2;
    if (y_final > bottom) {
        y_final = bottom;
        dy = (y_final - y_crossing) / @as(f32, @floatFromInt(x2 - (x1 + 1)));
    }
    // Each pixel between gets the rectangle so far, and a trapezoid sliding down
    const step = sign * dy * 1;
    var x = x1 + 1;
    while (x < x2) : (x += 1) {
        scanline[@intCast(x)] += area + step / 2;
        area += step;
    }
    const x2_left: f32 = @floatFromInt(x2);
    const last = trapezoid_area(sy1 - y_final, x2_left + 1.0 - x2_left, x2_left + 1.0 - x_bottom);
    scanline[@intCast(x2)] += area + sign * last;
    // The rest of the row is filled by the edge's whole height in this scanline
    scanline2[@as(u32, @intCast(x2)) + 1] += sign * (sy1 - sy0);
}

/// An edge reaching past the bitmap's sides: stb_truetype's slow way, pixel by pixel,
/// cutting the edge where it crosses each pixel's sides.
fn fill_clipped_edge(scanline: []f32, e: *const ActiveEdge, top: f32, x0: f32, xb: f32) void {
    assert(e.fdx != 0);
    assert(scanline.len <= std.math.maxInt(i32));
    const y0 = top;
    const y3 = top + 1;
    const x3 = xb;
    const dx = e.fdx;
    for (0..scanline.len) |column| {
        const x: i32 = @intCast(column);
        const x1: f32 = @floatFromInt(x);
        const x2: f32 = @floatFromInt(x + 1);
        const y1 = (@as(f32, @floatFromInt(x)) - x0) / dx + top;
        const y2 = (@as(f32, @floatFromInt(x + 1)) - x0) / dx + top;
        if (x0 < x1 and x3 > x2) {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x1, y1 });
            handle_clipped_edge(scanline, x, e, .{ x1, y1, x2, y2 });
            handle_clipped_edge(scanline, x, e, .{ x2, y2, x3, y3 });
        } else if (x3 < x1 and x0 > x2) {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x2, y2 });
            handle_clipped_edge(scanline, x, e, .{ x2, y2, x1, y1 });
            handle_clipped_edge(scanline, x, e, .{ x1, y1, x3, y3 });
        } else if (x0 < x1 and x3 > x1) {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x1, y1 });
            handle_clipped_edge(scanline, x, e, .{ x1, y1, x3, y3 });
        } else if (x3 < x1 and x0 > x1) {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x1, y1 });
            handle_clipped_edge(scanline, x, e, .{ x1, y1, x3, y3 });
        } else if (x0 < x2 and x3 > x2) {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x2, y2 });
            handle_clipped_edge(scanline, x, e, .{ x2, y2, x3, y3 });
        } else if (x3 < x2 and x0 > x2) {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x2, y2 });
            handle_clipped_edge(scanline, x, e, .{ x2, y2, x3, y3 });
        } else {
            handle_clipped_edge(scanline, x, e, .{ x0, y0, x3, y3 });
        }
    }
}
