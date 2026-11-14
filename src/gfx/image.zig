//! Pictures: decoding JPEG and PNG covers and illustrations to gray, scaling,
//! dithering and zooming them for the panel.
const std = @import("std");
const assert = std.debug.assert;
const check = @import("../base/check.zig");
const file = @import("../sys/file.zig");
const Page = @import("page.zig").Page;
const c_memory = @import("c_memory.zig");
const decoded = @import("decoded.zig");
const jpeg_decoder = @import("jpeg.zig");
const png_decoder = @import("png.zig");

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
pub const Size = struct { width: u32, height: u32 };

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

/// Rounds to the 16 grays the panel shows, spreading each pixel's rounding error
/// onto its neighbours (Floyd-Steinberg). Without it the panel rounds by itself,
/// and dark areas flatten into one murky gray.
pub fn dither(alloc: std.mem.Allocator, pixels: []u8, w: usize) !void {
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

/// Decodes a cover and shows all of it, as large as fits, centred on black.
/// `stride` is bytes per row in `buf`, which can be more than the visible width.
pub fn fill_screen(
    alloc: std.mem.Allocator,
    jpeg: []const u8,
    buf: []u8,
    width_px: usize,
    height_px: usize,
    stride: usize,
) bool {
    // The screen's own sizes, far under 32 bits
    const screen = Page{
        .buf = buf,
        .width = @intCast(width_px),
        .height = @intCast(height_px),
        .stride = @intCast(stride),
    };
    assert(screen.holds_rows());
    const decoder = c_memory.allocator();
    const gray = decode_picture(decoder, jpeg) orelse return false;
    defer decoder.free(gray.pixels);
    const picture = Size{ .width = gray.width, .height = gray.height };
    const fit = fitted(picture, .{ .width = screen.width, .height = screen.height });
    const ready = prepare(
        alloc,
        gray.pixels,
        picture.width,
        picture.height,
        fit.width,
        fit.height,
    ) orelse return false;
    defer alloc.free(ready);
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
    sw: usize,
    sh: usize,
    w: usize,
    h: usize,
) ?[]u8 {
    if (w == 0 or h == 0 or sw == 0 or sh == 0 or pixels.len < sw * sh) return null;
    // A picture's sides come from its file: too long to scale is no picture
    if (sw > std.math.maxInt(u32) or sh > std.math.maxInt(u32)) return null;
    // The box is noface's own: a cover's or a page's
    assert(w <= std.math.maxInt(u32));
    assert(h <= std.math.maxInt(u32));
    const out = alloc.alloc(u8, w * h) catch return null;
    const source_size = Size{ .width = @intCast(sw), .height = @intCast(sh) };
    const target_size = Size{ .width = @intCast(w), .height = @intCast(h) };
    scale(pixels[0 .. sw * sh], source_size, out, target_size);
    dither(alloc, out, w) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

/// Decodes a JPEG or PNG, then prepares it at `w` x `h`.
pub fn decode_and_prepare(alloc: std.mem.Allocator, encoded: []const u8, w: usize, h: usize) ?[]u8 {
    const decoder = c_memory.allocator();
    const gray = decode_picture(decoder, encoded) orelse return null;
    defer decoder.free(gray.pixels);
    const ready = prepare(alloc, gray.pixels, gray.width, gray.height, w, h) orelse return null;
    // Paired with `blit`, which copies exactly this many
    assert(ready.len == @as(u64, w) * h);
    return ready;
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
pub fn load(alloc: std.mem.Allocator, path: [*:0]const u8, dw: usize, dh: usize) ?[]u8 {
    assert(dw > 0);
    assert(dh > 0);
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    const decoder = c_memory.allocator();
    const gray = decode_picture(decoder, data) orelse return null;
    defer decoder.free(gray.pixels);
    const picture = Size{ .width = gray.width, .height = gray.height };
    const out = alloc.alloc(u8, dw * dh) catch return null;
    // A cover's size is noface's own, far under 32 bits
    const target_size = Size{ .width = @intCast(dw), .height = @intCast(dh) };
    scale(gray.pixels, picture, out, target_size);
    return out;
}

/// A decoded picture at its own size, one gray byte per pixel.
pub const Gray = struct { pixels: []u8, width: usize, height: usize };

/// Decodes a PNG or a JPEG into gray pixels from `alloc`, which the caller frees, or
/// null for a file that isn't one, or can't be read.
fn decode_picture(alloc: std.mem.Allocator, encoded: []const u8) ?decoded.Gray {
    // A picture that can't be decoded, or has no room, is shown as none: nothing worse
    const picture = decode_either(alloc, encoded) catch return null;
    // Paired with the callers, which index rows by the width
    assert(picture.pixels.len == @as(u64, picture.width) * picture.height);
    assert(picture.width > 0);
    return picture;
}

fn decode_either(alloc: std.mem.Allocator, encoded: []const u8) !decoded.Gray {
    if (png_decoder.is_png(encoded)) return png_decoder.decode(alloc, encoded);
    if (jpeg_decoder.is_jpeg(encoded)) return jpeg_decoder.decode(alloc, encoded);
    return error.NotAPicture;
}

/// Decodes a JPEG or PNG at full size. The caller owns the pixels.
pub fn decode_gray(alloc: std.mem.Allocator, encoded: []const u8) ?Gray {
    const decoder = c_memory.allocator();
    const picture = decode_picture(decoder, encoded) orelse return null;
    defer decoder.free(picture.pixels);
    const out = alloc.alloc(u8, picture.pixels.len) catch return null;
    @memcpy(out, picture.pixels);
    const gray = Gray{ .pixels = out, .width = picture.width, .height = picture.height };

    // Paired with `zoomed` and its helpers, which index rows by the width
    assert(gray.pixels.len == gray.width * gray.height);
    assert(gray.width > 0);
    return gray;
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
