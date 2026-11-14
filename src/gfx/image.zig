//! Book thumbnails, decoded once and scaled to library size.
const std = @import("std");
const check = @import("../base/check.zig");
const file = @import("../sys/file.zig");
const Page = @import("page.zig").Page;

extern fn img_gray(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn img_free(p: [*]u8) void;

pub const width = 252;
pub const height = 333;
pub const hero_width = 270;
pub const hero_height = 357;

/// Box filter: each output pixel averages the source pixels it covers.
pub fn scale(src: []const u8, sw: usize, sh: usize, dst: []u8, dw: usize, dh: usize) void {
    // In 64 bits: a picture can be millions of pixels along one side
    for (0..dh) |y| {
        const y0: usize = @intCast(@as(u64, y) * sh / dh);
        const y1 = @max(@as(usize, @intCast(@as(u64, y + 1) * sh / dh)), y0 + 1);
        for (0..dw) |x| {
            const x0: usize = @intCast(@as(u64, x) * sw / dw);
            const x1 = @max(@as(usize, @intCast(@as(u64, x + 1) * sw / dw)), x0 + 1);
            var sum: u32 = 0;
            for (y0..y1) |sy| {
                for (x0..x1) |sx| sum += src[sy * sw + sx];
            }
            dst[y * dw + x] = @intCast(sum / @as(u32, @intCast((y1 - y0) * (x1 - x0))));
        }
    }
}

/// Rounds to the 16 grays the panel shows, spreading each pixel's rounding error
/// onto its neighbours (Floyd-Steinberg). Without it the panel rounds by itself,
/// and dark areas flatten into one murky gray.
pub fn dither(alloc: std.mem.Allocator, pixels: []u8, w: usize) !void {
    if (w == 0) return;
    // The panel gray nearest each value, -255..510 (errors can push past either end)
    const nearest = comptime blk: {
        @setEvalBranchQuota(10000);
        var t: [766]u8 = undefined;
        for (&t, 0..) |*v, i| {
            const want = std.math.clamp(@as(i32, i) - 255, 0, 255);
            v.* = @intCast(@divTrunc(want + 8, 17) * 17);
        }
        break :blk t;
    };
    const errs = try alloc.alloc(i32, 2 * (w + 2));
    defer alloc.free(errs);
    @memset(errs, 0);
    var cur = errs[0 .. w + 2];
    var nxt = errs[w + 2 ..];
    const h = pixels.len / w;
    for (0..h) |y| {
        const row = pixels[y * w ..][0..w];
        for (row, 0..) |*p, x| {
            // Wrapping math: values stay well inside i32, so the checks are just cost
            const want = std.math.clamp(@as(i32, p.*) +% @divTrunc(cur[x + 1], 16), -255, 510);
            const got = nearest[@intCast(want + 255)];
            p.* = got;
            const e = std.math.clamp(want, 0, 255) -% got;
            cur[x + 2] +%= e *% 7;
            nxt[x] +%= e *% 3;
            nxt[x + 1] +%= e *% 5;
            nxt[x + 2] +%= e;
        }
        std.mem.swap([]i32, &cur, &nxt);
        @memset(nxt, 0);
    }
}

/// The largest size with a picture's shape that fits inside a `dw` x `dh` box.
pub fn fitted(sw: usize, sh: usize, dw: usize, dh: usize) struct { w: usize, h: usize } {
    const w: u64 = sw;
    const h: u64 = sh;
    if (w * dh > h * dw) return .{ .w = dw, .h = @intCast(@max(1, h * dw / w)) };
    return .{ .w = @intCast(@max(1, w * dh / h)), .h = dh };
}

/// Decodes a cover and shows all of it, as large as fits, centred on black.
/// `stride` is bytes per row in `buf`, which can be more than the visible width.
pub fn fill_screen(alloc: std.mem.Allocator, jpeg: []const u8, buf: []u8, width_px: usize, height_px: usize, stride: usize) bool {
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(jpeg.ptr, @intCast(jpeg.len), &w, &h) orelse return false;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return false;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const fit = fitted(sw, sh, width_px, height_px);
    const ready = prepare(alloc, pixels[0 .. sw * sh], sw, sh, fit.w, fit.h) orelse return false;
    defer alloc.free(ready);
    for (0..height_px) |row| @memset(buf[row * stride ..][0..width_px], 0x00);
    const left = (width_px - fit.w) / 2;
    const top = (height_px - fit.h) / 2;
    for (0..fit.h) |row| @memcpy(buf[(top + row) * stride + left ..][0..fit.w], ready[row * fit.w ..][0..fit.w]);
    return true;
}

/// Scales decoded grayscale pixels to `w` x `h` and dithers them for the panel,
/// ready to copy onto pages. The caller owns the result.
pub fn prepare(alloc: std.mem.Allocator, pixels: []const u8, sw: usize, sh: usize, w: usize, h: usize) ?[]u8 {
    if (w == 0 or h == 0 or sw == 0 or sh == 0 or pixels.len < sw * sh) return null;
    const out = alloc.alloc(u8, w * h) catch return null;
    scale(pixels[0 .. sw * sh], sw, sh, out, w, h);
    dither(alloc, out, w) catch {
        alloc.free(out);
        return null;
    };
    return out;
}

/// Decodes a JPEG or PNG, then prepares it at `w` x `h`.
pub fn decode_and_prepare(alloc: std.mem.Allocator, encoded: []const u8, w: usize, h: usize) ?[]u8 {
    var sw: c_int = 0;
    var sh: c_int = 0;
    const pixels = img_gray(encoded.ptr, @intCast(encoded.len), &sw, &sh) orelse return null;
    defer img_free(pixels);
    if (sw <= 0 or sh <= 0) return null;
    return prepare(alloc, pixels[0..@intCast(sw * sh)], @intCast(sw), @intCast(sh), w, h);
}

/// Copies a prepared picture into a box on a page.
pub fn blit(page: Page, ready: []const u8, x: u32, y: u32, w: u32, h: u32) void {
    check.thatf(ready.len == @as(usize, w) * h, "picture of {d} bytes fills a {d}x{d} box", .{ ready.len, w, h });
    if (x + w > page.width or y + h > page.height) return;
    for (0..h) |row| @memcpy(page.buf[(y + row) * page.stride + x ..][0..w], ready[row * w ..][0..w]);
}

/// Returns a grayscale cover at the given size, or null if it can't be read.
pub fn load(alloc: std.mem.Allocator, path: [*:0]const u8, dw: usize, dh: usize) ?[]u8 {
    const data = file.map(path) catch return null;
    defer file.unmap(data);
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(data.ptr, @intCast(data.len), &w, &h) orelse return null;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return null;
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);
    const out = alloc.alloc(u8, dw * dh) catch return null;
    scale(pixels[0 .. sw * sh], sw, sh, out, dw, dh);
    return out;
}

test "scaling down averages" {
    const src = [_]u8{ 0, 100, 200, 100 };
    var dst: [1]u8 = undefined;
    scale(&src, 2, 2, &dst, 1, 1);
    try std.testing.expectEqual(@as(u8, 100), dst[0]);
}

test "scaling up repeats" {
    const src = [_]u8{ 10, 20 };
    var dst: [4]u8 = undefined;
    scale(&src, 2, 1, &dst, 4, 1);
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

test "a sliver of an image still crops to something, and dithering nothing is safe" {
    try std.testing.expect(fitted(1, 10000, 1272, 1696).w >= 1);
    try std.testing.expect(fitted(10000, 1, 1272, 1696).h >= 1);
    var none: [0]u8 = .{};
    try dither(std.testing.allocator, &none, 0);
}

test "covers keep their shape on screen" {
    const screen_w = 1272;
    const screen_h = 1696;
    try std.testing.expectEqual(@as(usize, 1272), fitted(600, 800, screen_w, screen_h).w);
    const narrow = fitted(500, 800, screen_w, screen_h);
    try std.testing.expectEqual(@as(usize, 1060), narrow.w);
    try std.testing.expectEqual(@as(usize, 1696), narrow.h);
    try std.testing.expectEqual(@as(usize, 636), fitted(800, 400, screen_w, screen_h).h);
}

/// A decoded picture at its own size, one gray byte per pixel.
pub const Gray = struct { pixels: []u8, width: usize, height: usize };

/// Decodes a JPEG or PNG at full size. The caller owns the pixels.
pub fn decode_gray(alloc: std.mem.Allocator, encoded: []const u8) ?Gray {
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = img_gray(encoded.ptr, @intCast(encoded.len), &w, &h) orelse return null;
    defer img_free(pixels);
    if (w <= 0 or h <= 0) return null;
    const n: usize = @intCast(w * h);
    const out = alloc.alloc(u8, n) catch return null;
    @memcpy(out, pixels[0..n]);
    return .{ .pixels = out, .width = @intCast(w), .height = @intCast(h) };
}

/// A view into a picture for zooming: `zoom` screen pixels per picture pixel, with
/// picture point (`cx`, `cy`) at the middle of a `dw` x `dh` box, white past the
/// picture's edge. `smooth` blends the four nearest picture pixels when blowing a
/// picture up, so it isn't blocks, and averages all it covers when shrinking, so
/// thin lines aren't skipped; without it, each screen pixel takes the nearest one,
/// quick enough to follow a finger.
pub fn zoomed(src: Gray, cx: f32, cy: f32, zoom: f32, page: Page, dw: u32, dh: u32, smooth: bool) void {
    if (smooth and zoom > 1) return blended(src, cx, cy, zoom, page, dw, dh);
    if (smooth and zoom < 1) return averaged(src, cx, cy, zoom, page, dw, dh);
    const half_w: f32 = @as(f32, @floatFromInt(dw)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(dh)) / 2;
    const sw: f32 = @floatFromInt(src.width);
    const sh: f32 = @floatFromInt(src.height);
    // The picture column for each screen column, worked out once
    var columns: [2048]i32 = undefined;
    const cols = @min(dw, columns.len);
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
        const src_row = src.pixels[@as(usize, @intFromFloat(sy)) * src.width ..][0..src.width];
        for (row, columns[0..cols]) |*d, sx| d.* = if (sx < 0) 0xff else src_row[@intCast(sx)];
    }
}

/// Shrinking: each screen pixel averages every picture pixel it covers, as `scale`
/// does for pages, with each column's span worked out once.
fn averaged(src: Gray, cx: f32, cy: f32, zoom: f32, page: Page, dw: u32, dh: u32) void {
    const Span = struct { from: u32, to: u32 }; // to == from: past the edge
    var cols: [2048]Span = undefined;
    const n = @min(dw, cols.len);
    const half_w: f32 = @as(f32, @floatFromInt(dw)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(dh)) / 2;
    const span = struct {
        fn of(screen: usize, centre: f32, half: f32, z: f32, size: usize) Span {
            const a = centre + (@as(f32, @floatFromInt(screen)) - half) / z;
            const b = centre + (@as(f32, @floatFromInt(screen + 1)) - half) / z;
            const lo: f32 = @floatFromInt(size);
            if (b <= 0 or a >= lo) return .{ .from = 0, .to = 0 };
            const from: u32 = @intFromFloat(@max(a, 0));
            const to: u32 = @intFromFloat(@min(@ceil(b), lo));
            return .{ .from = from, .to = @max(to, from + 1) };
        }
    }.of;
    for (cols[0..n], 0..) |*c, x| c.* = span(x, cx, half_w, zoom, src.width);
    for (0..dh) |y| {
        const row = page.buf[y * page.stride ..][0..n];
        const rows = span(y, cy, half_h, zoom, src.height);
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
    const Col = struct { x0: u32, x1: u32, fx: u32, inside: bool };
    var cols: [2048]Col = undefined;
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
        const y0: usize = @intFromFloat(@floor(yc));
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
    const half = view / zoom / 2;
    if (picture <= 2 * half) return picture / 2;
    return std.math.clamp(c, half, picture - half);
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
    try std.testing.expectEqualSlices(u8, &.{ 10, 10, 20, 20, 10, 10, 20, 20, 30, 30, 40, 40, 30, 30, 40, 40 }, &buf);
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
    const tall = fitted(1, 3_000_000, 1272, 1696);
    try std.testing.expectEqual(@as(usize, 1696), tall.h);
    try std.testing.expectEqual(@as(usize, 1), tall.w);
    const wide = fitted(3_000_000, 1, 1272, 1696);
    try std.testing.expectEqual(@as(usize, 1272), wide.w);
    var src: [3000]u8 = @splat(200);
    var dst: [1]u8 = undefined;
    scale(&src, 1, 3000, &dst, 1, 1);
    try std.testing.expectEqual(@as(u8, 200), dst[0]);
}
