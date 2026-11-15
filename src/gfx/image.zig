//! Pictures: decoding JPEG and PNG covers and illustrations to gray, scaling,
//! dithering and zooming them for the panel.
const std = @import("std");
const assert = std.debug.assert;
const check = @import("../base/check.zig");
const file = @import("../sys/file.zig");
const Page = @import("page.zig").Page;
const decoder_memory = @import("decoder_memory.zig");
const decoded = @import("decoded.zig");
const jpeg_decoder = @import("jpeg.zig");
const png_decoder = @import("png.zig");
const scaler = @import("rows.zig");
const workspace = @import("workspace.zig");

pub const width = 252;
pub const height = 333;
pub const hero_width = 270;
pub const hero_height = 357;

/// The panel's grays are 16 steps of this, from black to white.
const panel_gray_step = 17;
/// The widest view `zoomed` draws: its column tables are this long.
const view_width_max = 2048;

comptime {
    assert(panel_gray_step * 15 == 255);
    // The hero cover, on top of the library, is the larger one
    assert(hero_width > width);
    assert(hero_height > height);
}

/// A size in pixels.
pub const Size = scaler.Size;
/// Box filter: each output pixel averages the source pixels it covers.
pub const scale = scaler.scale;
/// The largest size with a picture's shape that fits inside a box.
pub const fitted = scaler.fitted;

/// Rounds to the 16 grays the panel shows, spreading each pixel's rounding error
/// onto its neighbours (Floyd-Steinberg). Without it the panel rounds by itself,
/// and dark areas flatten into one murky gray.
pub fn dither(alloc: std.mem.Allocator, pixels: []u8, w: u32) !void {
    if (w == 0) return;
    // Whole rows only
    assert(pixels.len % w == 0);
    // The panel gray nearest each value, -255..510 (errors can push past either end)
    const nearest = comptime blk: {
        @setEvalBranchQuota(10000);
        var t: [766]u8 = undefined;
        for (&t, 0..) |*v, i| {
            const want = std.math.clamp(@as(i32, i) - 255, 0, 255);
            v.* = @intCast(@divTrunc(want + 8, panel_gray_step) * panel_gray_step);
            assert(v.* % panel_gray_step == 0);
        }
        break :blk t;
    };
    const errors = try alloc.alloc(i32, 2 * (w + 2));
    defer alloc.free(errors);
    @memset(errors, 0);
    var current = errors[0 .. w + 2];
    var next = errors[w + 2 ..];
    assert(current.len == next.len);
    const h = pixels.len / w;
    for (0..h) |y| {
        const row = pixels[y * w ..][0..w];
        for (row, 0..) |*p, x| {
            // Wrapping math: values stay well inside i32, so the checks are just cost
            const want = std.math.clamp(@as(i32, p.*) +% @divTrunc(current[x + 1], 16), -255, 510);
            const got = nearest[@intCast(want + 255)];
            p.* = got;
            const e = std.math.clamp(want, 0, 255) -% got;
            current[x + 2] +%= e *% 7;
            next[x] +%= e *% 3;
            next[x + 1] +%= e *% 5;
            next[x + 2] +%= e;
        }
        std.mem.swap([]i32, &current, &next);
        @memset(next, 0);
    }
}

/// Decodes a cover and shows all of it, as large as fits, centred on black.
/// `stride` is bytes per row in `buf`, which can be more than the visible width.
pub fn fill_screen(
    alloc: std.mem.Allocator,
    jpeg: []const u8,
    buf: []u8,
    width_px: u32,
    height_px: u32,
    stride: u32,
) bool {
    const screen = Page{ .buf = buf, .width = width_px, .height = height_px, .stride = stride };
    assert(screen.holds_rows());
    const box = Size{ .width = screen.width, .height = screen.height };
    var sink = scaler.Sink{ .target = .{ .fit = box }, .out = alloc };
    const ready = decoded_into(&sink, .{ .bytes = jpeg }, decoder_memory.allocator()) orelse
        return false;
    defer alloc.free(ready);
    const fit = sink.size;
    dither(alloc, ready, fit.width) catch return false;
    for (0..screen.height) |row| @memset(buf[row * stride ..][0..screen.width], 0x00);
    const left = (screen.width - fit.width) / 2;
    const top = (screen.height - fit.height) / 2;
    for (0..fit.height) |row| {
        const line = ready[row * fit.width ..][0..fit.width];
        @memcpy(buf[(top + row) * stride + left ..][0..fit.width], line);
    }
    return true;
}

/// Scales decoded grayscale pixels to `w` x `h` and dithers them for the panel,
/// ready to copy onto pages. The caller owns the result.
pub fn prepare(
    alloc: std.mem.Allocator,
    pixels: []const u8,
    sw: u32,
    sh: u32,
    w: u32,
    h: u32,
) ?[]u8 {
    const source_pixels = @as(u64, sw) * sh;
    if (w == 0 or h == 0 or sw == 0 or sh == 0 or pixels.len < source_pixels) return null;
    // The box is noface's own, a cover's or a page's: its pixels fit in memory
    assert(@as(u64, w) * h <= std.math.maxInt(u32));
    const out = alloc.alloc(u8, w * h) catch return null;
    const source_size = Size{ .width = sw, .height = sh };
    const target_size = Size{ .width = w, .height = h };
    scale(pixels[0..@intCast(source_pixels)], source_size, out, target_size);
    dither(alloc, out, w) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

/// Decodes a JPEG or PNG, then prepares it at `w` x `h`.
pub fn decode_and_prepare(alloc: std.mem.Allocator, encoded: []const u8, w: u32, h: u32) ?[]u8 {
    return prepare_from(alloc, .{ .bytes = encoded }, w, h);
}

/// A picture's bytes as its book keeps them: the JPEG or PNG itself, or that deflated
/// (as an EPUB may keep it), to be inflated to `inflated_size` bytes when it's drawn.
pub const Encoded = struct {
    bytes: []const u8,
    deflated: bool = false,
    inflated_size: u32 = 0,
};

/// Decodes a picture as its book keeps it, scaled to `w` x `h` as its rows come and
/// dithered for the panel, ready to copy onto pages. The caller owns the result.
pub fn prepare_from(alloc: std.mem.Allocator, source: Encoded, w: u32, h: u32) ?[]u8 {
    if (w == 0 or h == 0) return null;
    // The box is noface's own, a cover's or a page's: its pixels fit in memory
    assert(@as(u64, w) * h <= std.math.maxInt(u32));
    var sink = scaler.Sink{ .target = .{ .size = .{ .width = w, .height = h } }, .out = alloc };
    const ready = decoded_into(&sink, source, decoder_memory.allocator()) orelse return null;
    dither(alloc, ready, w) catch {
        alloc.free(ready);
        return null;
    };
    // Paired with `blit`, which copies exactly this many
    assert(ready.len == @as(u64, w) * h);
    return ready;
}

/// A picture as its book keeps it, at its own size, or at a half, a quarter or an
/// eighth of it when it's larger than `pixels_max` pixels or than memory holds. The
/// caller owns the pixels.
pub fn decode_gray_from(alloc: std.mem.Allocator, source: Encoded, pixels_max: u64) ?Gray {
    assert(pixels_max > 0);
    var sink = scaler.Sink{ .target = .{ .divided = 1 }, .out = alloc, .pixels_max = pixels_max };
    const pixels = decoded_into(&sink, source, decoder_memory.allocator()) orelse return null;
    const gray = Gray{ .pixels = pixels, .width = sink.size.width, .height = sink.size.height };
    // Paired with `zoomed` and its helpers, which index rows by the width
    assert(gray.pixels.len == @as(u64, gray.width) * gray.height);
    assert(gray.width > 0);
    return gray;
}

/// Decodes a JPEG or PNG at full size, or smaller if it won't fit (see
/// `decode_gray_from`). The caller owns the pixels.
pub fn decode_gray(alloc: std.mem.Allocator, encoded: []const u8) ?Gray {
    return decode_gray_from(alloc, .{ .bytes = encoded }, decoded.pixels_max);
}

/// How much smaller a picture is decoded when it won't fit at its size: by its DCT
/// for a JPEG, by the sink's box for a PNG.
const shrinks = [_]u8{ 1, 2, 4, 8 };

/// Decodes a picture into `sink`, in a workspace over `parent` that's emptied after,
/// and gives the sink's result, or null for data that isn't a picture noface reads. A
/// picture whose decoding needs more than `workspace.bytes_max`, or whose result more
/// than `sink.out` has, is decoded smaller where that helps: a JPEG always, a PNG when
/// the sink keeps the picture's own size. The grays only differ from a whole decode's
/// then: a picture that fits comes out exactly as before.
fn decoded_into(sink: *scaler.Sink, source: Encoded, parent: std.mem.Allocator) ?[]u8 {
    assert(sink.mode == .waiting);
    var work = workspace.Workspace.init(parent, workspace.bytes_max);
    defer work.reset();
    var encoded = source.bytes;
    if (source.deflated) encoded = inflated(work.allocator(), source) orelse return null;
    const is_png = png_decoder.is_png(encoded);
    if (!is_png and !jpeg_decoder.is_jpeg(encoded)) return null;
    const target = sink.target;
    const kept = work.mark();
    for (shrinks) |shrink| {
        work.rewind(kept);
        if (is_png and shrink > 1 and target != .divided) return null; // No smaller help
        if (is_png and target == .divided) sink.target = .{ .divided = target.divided * shrink };
        const decoding = if (is_png)
            png_decoder.decode_rows(work.allocator(), encoded, sink)
        else
            jpeg_decoder.decode_rows(&work, encoded, sink, shrink);
        decoding catch |err| {
            if (sink.mode != .waiting) sink.abandon();
            // A picture that can't be decoded is shown as none: nothing worse
            if (err != error.OutOfMemory) return null;
            continue;
        };
        if (shrink > 1) log_shrunk(sink, shrink);
        return sink.finish();
    }
    assert(sink.mode == .waiting);
    return null;
}

fn log_shrunk(sink: *const scaler.Sink, shrink: u8) void {
    assert(shrink > 1);
    assert(sink.source.width > 0);
    if (@import("builtin").is_test) return;
    std.debug.print("picture decoded at 1/{d} for want of memory: {d}x{d} from it\n", .{
        shrink,
        sink.source.width,
        sink.source.height,
    });
}

/// A deflated picture's bytes, inflated into `alloc`, or null for data that doesn't
/// inflate to the size the book gave.
fn inflated(alloc: std.mem.Allocator, source: Encoded) ?[]u8 {
    assert(source.deflated);
    assert(source.bytes.len <= std.math.maxInt(u32));
    const out = alloc.alloc(u8, source.inflated_size) catch return null;
    var input: std.Io.Reader = .fixed(source.bytes);
    // The output holds the history the inflater looks back into: no window needed
    var inflater: std.compress.flate.Decompress = .init(&input, .raw, &.{});
    var writer: std.Io.Writer = .fixed(out);
    inflater.reader.streamExact(&writer, out.len) catch {
        alloc.free(out);
        return null;
    };
    assert(writer.end == out.len);
    return out;
}

/// The gray of a picture's place when it can't be drawn: one of the panel's own, light.
const placeholder_gray = 14 * panel_gray_step;
/// Its corners' radius, at most: the interface's rounded shapes.
const placeholder_corner_max = 24;

comptime {
    assert(placeholder_gray < 255);
    assert(placeholder_gray % panel_gray_step == 0);
}

/// What stands where a picture can't be drawn: a light rounded box filling the
/// picture's own box, so the page around it is laid out as with the picture.
pub fn placeholder(page: Page, x: u32, y: u32, w: u32, h: u32) void {
    assert(page.holds_rows());
    assert(w > 0);
    if (h == 0 or x + w > page.width or y + h > page.height) return;
    const corner: f32 = @floatFromInt(@min(placeholder_corner_max, @min(w, h) / 2));
    page.round_rect(x, y, w, h, corner, placeholder_gray);
}

/// Copies a prepared picture into a box on a page.
pub fn blit(page: Page, ready: []const u8, x: u32, y: u32, w: u32, h: u32) void {
    check.thatf(
        ready.len == @as(u64, w) * h,
        "picture of {d} bytes fills a {d}x{d} box",
        .{ ready.len, w, h },
    );
    assert(page.holds_rows());
    if (x + w > page.width or y + h > page.height) return;
    for (0..h) |row| {
        const line = ready[row * w ..][0..w];
        @memcpy(page.buf[(y + row) * page.stride + x ..][0..w], line);
    }
}

/// Returns a grayscale cover at the given size, or null if it can't be read.
pub fn load(alloc: std.mem.Allocator, path: [*:0]const u8, dw: u32, dh: u32) ?[]u8 {
    assert(dw > 0);
    assert(dh > 0);
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    var sink = scaler.Sink{ .target = .{ .size = .{ .width = dw, .height = dh } }, .out = alloc };
    return decoded_into(&sink, .{ .bytes = data }, decoder_memory.allocator());
}

/// A decoded picture at its own size, one gray byte per pixel.
pub const Gray = struct { pixels: []u8, width: u32, height: u32 };

/// Decodes a PNG or a JPEG at its own size, all its memory from `alloc`, which owns
/// the pixels; or null for a file that isn't one, or can't be read.
fn decode_picture(alloc: std.mem.Allocator, encoded: []const u8) ?decoded.Gray {
    var sink = scaler.Sink{ .target = .{ .divided = 1 }, .out = alloc };
    const pixels = decoded_into(&sink, .{ .bytes = encoded }, alloc) orelse return null;
    const picture = decoded.Gray{
        .pixels = pixels,
        .width = sink.size.width,
        .height = sink.size.height,
    };
    // Paired with the callers, which index rows by the width
    assert(picture.pixels.len == @as(u64, picture.width) * picture.height);
    assert(picture.width > 0);
    return picture;
}

/// A view into a picture for zooming: `zoom` screen pixels per picture pixel, with
/// picture point (`cx`, `cy`) at the middle of a `dw` x `dh` box, white past the
/// picture's edge. `smooth` blends the four nearest picture pixels when blowing a
/// picture up, so it isn't blocks, and averages all it covers when shrinking, so
/// thin lines aren't skipped; without it, each screen pixel takes the nearest one,
/// quick enough to follow a finger.
pub fn zoomed(
    src: Gray,
    cx: f32,
    cy: f32,
    zoom: f32,
    page: Page,
    dw: u32,
    dh: u32,
    smooth: bool,
) void {
    assert(zoom > 0);
    // Checked once, not per pixel: the view's rows lie in the page
    assert(page.holds_rows());
    assert(dh <= page.height);
    assert(src.pixels.len >= src.width * src.height);
    if (smooth and zoom > 1) return blended(src, cx, cy, zoom, page, dw, dh);
    if (smooth and zoom < 1) return averaged(src, cx, cy, zoom, page, dw, dh);
    const half_w: f32 = @as(f32, @floatFromInt(dw)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(dh)) / 2;
    const sw: f32 = @floatFromInt(src.width);
    const sh: f32 = @floatFromInt(src.height);
    // The picture column for each screen column, worked out once
    var columns: [view_width_max]i32 = undefined;
    const cols = @min(dw, columns.len);
    assert(cols <= page.width);
    for (0..cols) |x| {
        const sx = cx + (@as(f32, @floatFromInt(x)) + 0.5 - half_w) / zoom;
        columns[x] = if (sx < 0 or sx >= sw) -1 else @intFromFloat(sx);
    }
    for (0..dh) |y| {
        const row = page.buf[y * page.stride ..][0..cols];
        const sy = cy + (@as(f32, @floatFromInt(y)) + 0.5 - half_h) / zoom;
        if (sy < 0 or sy >= sh) {
            @memset(row, 0xff);
            continue;
        }
        const src_row = src.pixels[@as(u32, @intFromFloat(sy)) * src.width ..][0..src.width];
        for (row, columns[0..cols]) |*d, sx| d.* = if (sx < 0) 0xff else src_row[@intCast(sx)];
    }
}

/// Shrinking: each screen pixel averages every picture pixel it covers, as `scale`
/// does for pages, with each column's span worked out once.
fn averaged(src: Gray, cx: f32, cy: f32, zoom: f32, page: Page, dw: u32, dh: u32) void {
    assert(zoom > 0);
    assert(zoom < 1);
    // Decoded sides come from C ints, so they fit in 32 bits
    const picture_width: u32 = @intCast(src.width);
    const picture_height: u32 = @intCast(src.height);
    const Span = struct { from: u32, to: u32 }; // Equal ends: past the edge
    var cols: [view_width_max]Span = undefined;
    const n = @min(dw, cols.len);
    const half_w: f32 = @as(f32, @floatFromInt(dw)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(dh)) / 2;
    const span = struct {
        fn of(screen: u32, centre: f32, half: f32, z: f32, size: u32) Span {
            assert(z > 0);
            const a = centre + (@as(f32, @floatFromInt(screen)) - half) / z;
            const b = centre + (@as(f32, @floatFromInt(screen + 1)) - half) / z;
            const lo: f32 = @floatFromInt(size);
            if (b <= 0 or a >= lo) return .{ .from = 0, .to = 0 };
            const from: u32 = @intFromFloat(@max(a, 0));
            const to: u32 = @intFromFloat(@min(@ceil(b), lo));
            const result = Span{ .from = from, .to = @max(to, from + 1) };
            assert(result.to > result.from);
            return result;
        }
    }.of;
    for (cols[0..n], 0..) |*c, x| c.* = span(@intCast(x), cx, half_w, zoom, picture_width);
    for (0..dh) |y| {
        const row = page.buf[y * page.stride ..][0..n];
        const rows = span(@intCast(y), cy, half_h, zoom, picture_height);
        if (rows.to == rows.from) {
            @memset(row, 0xff);
            continue;
        }
        for (row, cols[0..n]) |*d, c| {
            if (c.to == c.from) {
                d.* = 0xff;
                continue;
            }
            var sum: u32 = 0;
            for (rows.from..rows.to) |sy| {
                for (src.pixels[sy * src.width + c.from .. sy * src.width + c.to]) |v| sum += v;
            }
            d.* = @intCast(sum / ((rows.to - rows.from) * (c.to - c.from)));
        }
    }
}

/// The smooth view: each screen pixel mixes the four picture pixels around it, in
/// whole numbers (weights out of 256), with each column's sums worked out once.
fn blended(src: Gray, cx: f32, cy: f32, zoom: f32, page: Page, dw: u32, dh: u32) void {
    assert(zoom > 1);
    // The last row and column are the edge every mix is clamped to
    assert(src.width > 0);
    assert(src.height > 0);
    const Col = struct { x0: u32, x1: u32, fx: u32, inside: bool };
    var cols: [view_width_max]Col = undefined;
    const n = @min(dw, cols.len);
    const half_w: f32 = @as(f32, @floatFromInt(dw)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(dh)) / 2;
    const max_x: f32 = @floatFromInt(src.width - 1);
    const max_y: f32 = @floatFromInt(src.height - 1);
    for (cols[0..n], 0..) |*c, x| {
        const sx = cx + (@as(f32, @floatFromInt(x)) + 0.5 - half_w) / zoom - 0.5;
        const xc = std.math.clamp(sx, 0, max_x);
        const x0: u32 = @intFromFloat(@floor(xc));
        c.* = .{
            .x0 = x0,
            .x1 = @min(x0 + 1, @as(u32, @intCast(src.width - 1))),
            .fx = @intFromFloat((xc - @floor(xc)) * 256),
            .inside = sx >= -0.5 and sx <= max_x + 0.5,
        };
    }
    for (0..dh) |y| {
        const row = page.buf[y * page.stride ..][0..n];
        const sy = cy + (@as(f32, @floatFromInt(y)) + 0.5 - half_h) / zoom - 0.5;
        if (sy < -0.5 or sy > max_y + 0.5) {
            @memset(row, 0xff);
            continue;
        }
        const yc = std.math.clamp(sy, 0, max_y);
        const y0: u32 = @intFromFloat(@floor(yc));
        const y1 = @min(y0 + 1, src.height - 1);
        const fy: u32 = @intFromFloat((yc - @floor(yc)) * 256);
        const r0 = src.pixels[y0 * src.width ..][0..src.width];
        const r1 = src.pixels[y1 * src.width ..][0..src.width];
        for (row, cols[0..n]) |*d, c| {
            if (!c.inside) {
                d.* = 0xff;
                continue;
            }
            const top = @as(u32, r0[c.x0]) * (256 - c.fx) + @as(u32, r0[c.x1]) * c.fx;
            const bottom = @as(u32, r1[c.x0]) * (256 - c.fx) + @as(u32, r1[c.x1]) * c.fx;
            d.* = @intCast((top * (256 - fy) + bottom * fy + 32768) >> 16);
        }
    }
}

/// Where the middle of a view can sit so the picture covers it where it can: centred
/// on an axis where the picture is smaller than the view.
pub fn clamp_centre(c: f32, picture: f32, view: f32, zoom: f32) f32 {
    assert(zoom > 0);
    assert(view > 0);
    const half = view / zoom / 2;
    if (picture <= 2 * half) return picture / 2;
    return std.math.clamp(c, half, picture - half);
}

test "scaling down averages" {
    const src = [_]u8{ 0, 100, 200, 100 };
    var dst: [1]u8 = undefined;
    scale(&src, .{ .width = 2, .height = 2 }, &dst, .{ .width = 1, .height = 1 });
    try std.testing.expectEqual(@as(u8, 100), dst[0]);
}

test "scaling up repeats" {
    const src = [_]u8{ 10, 20 };
    var dst: [4]u8 = undefined;
    scale(&src, .{ .width = 2, .height = 1 }, &dst, .{ .width = 4, .height = 1 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 10, 20, 20 }, &dst);
}

test "dithering keeps only panel grays and the overall tone" {
    var pixels: [64 * 64]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast((i % 64) * 4);
    var before: u32 = 0;
    for (pixels) |p| before += p;
    try dither(std.testing.allocator, &pixels, 64);
    var after: u32 = 0;
    for (pixels) |p| {
        try std.testing.expectEqual(@as(u8, 0), p % 17);
        after += p;
    }
    const diff = @as(i64, before) - @as(i64, after);
    try std.testing.expect(@abs(diff) < 64 * 64 * 2);
}

const screen_size = Size{ .width = 1272, .height = 1696 };

test "a sliver of an image still crops to something, and dithering nothing is safe" {
    try std.testing.expect(fitted(.{ .width = 1, .height = 10000 }, screen_size).width >= 1);
    try std.testing.expect(fitted(.{ .width = 10000, .height = 1 }, screen_size).height >= 1);
    var none: [0]u8 = .{};
    try dither(std.testing.allocator, &none, 0);
}

test "covers keep their shape on screen" {
    const full = fitted(.{ .width = 600, .height = 800 }, screen_size);
    try std.testing.expectEqual(@as(u32, 1272), full.width);
    const narrow = fitted(.{ .width = 500, .height = 800 }, screen_size);
    try std.testing.expectEqual(@as(u32, 1060), narrow.width);
    try std.testing.expectEqual(@as(u32, 1696), narrow.height);
    const wide = fitted(.{ .width = 800, .height = 400 }, screen_size);
    try std.testing.expectEqual(@as(u32, 636), wide.height);
}

test "a view keeps inside the picture" {
    // 1000 px picture, 500 px view at 1x: the middle stays 250..750
    try std.testing.expectEqual(@as(f32, 250), clamp_centre(0, 1000, 500, 1));
    try std.testing.expectEqual(@as(f32, 750), clamp_centre(990, 1000, 500, 1));
    try std.testing.expectEqual(@as(f32, 600), clamp_centre(600, 1000, 500, 1));
    // Smaller than the view: centred
    try std.testing.expectEqual(@as(f32, 50), clamp_centre(10, 100, 500, 1));
}

test "zoomed views sample the nearest pixel, white outside" {
    var src_px = [_]u8{ 10, 20, 30, 40 }; // 2 x 2
    const src = Gray{ .pixels = &src_px, .width = 2, .height = 2 };
    var buf: [16]u8 = undefined;
    const page = Page{ .buf = &buf, .width = 4, .height = 4, .stride = 4 };
    zoomed(src, 1, 1, 2, page, 4, 4, false); // Each picture pixel becomes 2 x 2
    const doubled = [_]u8{ 10, 10, 20, 20, 10, 10, 20, 20, 30, 30, 40, 40, 30, 30, 40, 40 };
    try std.testing.expectEqualSlices(u8, &doubled, &buf);
    zoomed(src, 1, 1, 1, page, 4, 4, false); // Half the view is past the edge
    try std.testing.expectEqual(@as(u8, 0xff), buf[0]);
    try std.testing.expectEqual(@as(u8, 10), buf[5]);
    zoomed(src, 1, 1, 2, page, 4, 4, true); // Blended: in between, corners kept
    try std.testing.expectEqual(@as(u8, 10), buf[0]);
    try std.testing.expectEqual(@as(u8, 40), buf[15]);
    try std.testing.expect(buf[1] > 10 and buf[1] < 20);
}

test "shrunk views keep thin lines" {
    // An 8 x 8 picture, white with one black column, shown at half size
    var src_px: [64]u8 = @splat(0xff);
    for (0..8) |y| src_px[y * 8 + 3] = 0;
    const src = Gray{ .pixels = &src_px, .width = 8, .height = 8 };
    var buf: [16]u8 = undefined;
    const page = Page{ .buf = &buf, .width = 4, .height = 4, .stride = 4 };
    zoomed(src, 4, 4, 0.5, page, 4, 4, true);
    // The line is averaged into its column, not skipped
    for (0..4) |y| try std.testing.expect(buf[y * 4 + 1] < 0xc0);
    try std.testing.expectEqual(@as(u8, 0xff), buf[0]);
}

test "pictures millions of pixels long fit without overflowing" {
    const tall = fitted(.{ .width = 1, .height = 3_000_000 }, screen_size);
    try std.testing.expectEqual(@as(u32, 1696), tall.height);
    try std.testing.expectEqual(@as(u32, 1), tall.width);
    const wide = fitted(.{ .width = 3_000_000, .height = 1 }, screen_size);
    try std.testing.expectEqual(@as(u32, 1272), wide.width);
    var src: [3000]u8 = @splat(200);
    var dst: [1]u8 = undefined;
    scale(&src, .{ .width = 1, .height = 3000 }, &dst, .{ .width = 1, .height = 1 });
    try std.testing.expectEqual(@as(u8, 200), dst[0]);
}

/// Small pictures of every kind the decoders read, with the size and grays stb_image
/// decoded them to (a hash of the pixels).
const test_pictures = [_]struct { []const u8, u32, u32, u64 }{
    .{ "baseline420.jpg", 41, 29, 0xaeef13c678bc8f28 },
    .{ "cmyk.jpg", 41, 29, 0x55656065ba7164ae },
    .{ "gray_alpha16.png", 5, 70, 0x0ecf83ee1ef5f828 },
    .{ "gray.jpg", 41, 29, 0xaeef13c678bc8f28 },
    .{ "gray2_interlaced.png", 37, 23, 0xad7efaf1d6b02989 },
    .{ "palette4_interlaced.png", 37, 23, 0x7691cc9c49076f77 },
    .{ "palette8_transparent.png", 30, 20, 0x17d72d02550457bf },
    .{ "progressive_restarts.jpg", 41, 29, 0xaeef13c678bc8f28 },
    .{ "restarts444.jpg", 41, 29, 0xaeef13c678bc8f28 },
    .{ "rgb_subsampled.jpg", 41, 29, 0xfd7f8cb5dbb11168 },
    .{ "rgb16.png", 37, 23, 0xe8f2973a35fb5967 },
    .{ "rgba8_interlaced.png", 37, 23, 0xcb6bb63a35908269 },
};

fn test_picture(comptime name: []const u8) []const u8 {
    return @embedFile("../testdata/pictures/" ++ name);
}

test "pictures decode to the grays stb_image gave" {
    inline for (test_pictures) |case| {
        const picture = decode_picture(std.testing.allocator, test_picture(case[0])).?;
        defer std.testing.allocator.free(picture.pixels);
        try std.testing.expectEqual(case[1], picture.width);
        try std.testing.expectEqual(case[2], picture.height);
        try std.testing.expectEqual(case[3], std.hash.Wyhash.hash(0, picture.pixels));
    }
}

test "pictures cut short are turned down" {
    inline for (test_pictures) |case| {
        const data = test_picture(case[0]);
        // A PNG may lose its last checksum, a JPEG its end marker: the picture is all
        // there, and stb_image showed it
        const kept: u32 = if (png_decoder.is_png(data)) 4 else 2;
        for (0..data.len - kept) |length| {
            try std.testing.expect(decode_picture(std.testing.allocator, data[0..length]) == null);
        }
    }
}

test "damaged pictures decode or are turned down, never crash" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buffer: [4096]u8 = undefined;
    inline for (test_pictures) |case| {
        const data = test_picture(case[0]);
        for (0..200) |_| {
            const damaged = buffer[0..data.len];
            @memcpy(damaged, data);
            for (0..1 + random.uintLessThan(u32, 6)) |_| {
                damaged[random.uintLessThan(u32, @intCast(data.len))] = random.int(u8);
            }
            if (decode_picture(std.testing.allocator, damaged)) |picture| {
                std.testing.allocator.free(picture.pixels);
            }
        }
    }
}

test "a deflated picture draws as the same picture kept as it is" {
    const alloc = std.testing.allocator;
    const data = test_picture("baseline420.jpg");
    // Deflate's stored blocks: the picture's bytes as they are, after a block header
    const deflated = try alloc.alloc(u8, data.len + 5);
    defer alloc.free(deflated);
    const length: u16 = @intCast(data.len);
    const l: [2]u8 = @bitCast(std.mem.nativeToLittle(u16, length));
    @memcpy(deflated[0..5], &[_]u8{ 1, l[0], l[1], ~l[0], ~l[1] });
    @memcpy(deflated[5..], data);
    const plain = decode_and_prepare(alloc, data, 20, 14).?;
    defer alloc.free(plain);
    const source = Encoded{ .bytes = deflated, .deflated = true, .inflated_size = length };
    const from = prepare_from(alloc, source, 20, 14).?;
    defer alloc.free(from);
    try std.testing.expectEqualSlices(u8, plain, from);
    const gray = decode_gray_from(alloc, source, 41 * 29).?;
    defer alloc.free(gray.pixels);
    try std.testing.expectEqual(@as(u32, 41), gray.width);
    // Allowed fewer pixels than it has, it comes at half its size
    const half = decode_gray_from(alloc, source, 41 * 29 - 1).?;
    defer alloc.free(half.pixels);
    try std.testing.expectEqual(@as(u32, 21), half.width);
    try std.testing.expectEqual(@as(u32, 15), half.height);
    try std.testing.expect(decode_gray_from(alloc, source, 2) == null);
    const short = Encoded{ .bytes = deflated, .deflated = true, .inflated_size = length + 1 };
    try std.testing.expect(prepare_from(alloc, short, 20, 14) == null);
}

test "a JPEG decoded smaller looks like the whole picture scaled down" {
    const alloc = std.testing.allocator;
    inline for (test_pictures) |case| {
        const data = test_picture(case[0]);
        if (comptime std.mem.endsWith(u8, case[0], ".jpg")) {
            const whole = decode_picture(alloc, data).?;
            defer alloc.free(whole.pixels);
            for ([_]u8{ 2, 4, 8 }) |shrink| {
                var work = workspace.Workspace.init(alloc, workspace.bytes_max);
                defer work.reset();
                var sink = scaler.Sink{ .target = .{ .divided = 1 }, .out = alloc };
                try jpeg_decoder.decode_rows(&work, data, &sink, shrink);
                const small = sink.finish();
                defer alloc.free(small);
                const size = sink.size;
                try std.testing.expectEqual(scaler.divide_up(case[1], shrink), size.width);
                try std.testing.expectEqual(scaler.divide_up(case[2], shrink), size.height);
                var difference: u64 = 0;
                for (0..size.height) |y| {
                    for (0..size.width) |x| {
                        const wanted = test_block_average(whole, @intCast(x), @intCast(y), shrink);
                        difference += @abs(@as(i32, small[y * size.width + x]) - wanted);
                    }
                }
                // Within a few grays on average: a progressive picture keeps only its
                // blocks' coarsest coefficients, colour is upsampled from fewer samples,
                // and in pictures this small most pixels are near an edge
                try std.testing.expect(difference <= small.len * 4 * shrink);
            }
        }
    }
}

/// The average of the `shrink` x `shrink` square of a picture's pixels at (x, y) of the
/// picture shrunk, rounded, as a JPEG decoded smaller averages a block's.
fn test_block_average(picture: decoded.Gray, x: u32, y: u32, shrink: u8) u8 {
    assert(shrink > 1);
    assert(picture.width > 0);
    var sum: u32 = 0;
    var count: u32 = 0;
    for (y * shrink..@min((y + 1) * shrink, picture.height)) |row| {
        for (x * shrink..@min((x + 1) * shrink, picture.width)) |column| {
            sum += picture.pixels[row * picture.width + column];
            count += 1;
        }
    }
    return @intCast((sum + count / 2) / count);
}

test "a picture too large for the workspace is decoded smaller, not dropped" {
    const alloc = std.testing.allocator;
    const data = test_picture("progressive_restarts.jpg");
    var peaks: [2]u64 = undefined;
    for (&peaks, [_]u8{ 1, 2 }) |*peak, shrink| {
        var work = workspace.Workspace.init(alloc, workspace.bytes_max);
        defer work.reset();
        var sink = scaler.Sink{ .target = .{ .divided = 1 }, .out = alloc };
        try jpeg_decoder.decode_rows(&work, data, &sink, shrink);
        alloc.free(sink.finish());
        peak.* = work.peak;
    }
    try std.testing.expect(peaks[1] < peaks[0]);
    // Room for the picture decoded at half its size, not at its own
    var work = workspace.Workspace.init(alloc, peaks[1]);
    defer work.reset();
    var sink = scaler.Sink{ .target = .{ .divided = 1 }, .out = alloc };
    try std.testing.expectError(error.OutOfMemory, jpeg_decoder.decode_rows(&work, data, &sink, 1));
    try std.testing.expectEqual(scaler.Sink.Mode.waiting, sink.mode);
    work.reset();
    try jpeg_decoder.decode_rows(&work, data, &sink, 2);
    const small = sink.finish();
    defer alloc.free(small);
    try std.testing.expectEqual(@as(u32, 21), sink.size.width);
}
