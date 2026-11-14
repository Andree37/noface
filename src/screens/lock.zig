//! The lock screen: the book's cover while the Kindle sleeps.
const std = @import("std");
const catalog = @import("../model/catalog.zig");
const os = @import("../sys/os.zig");
const cover = @import("../gfx/image.zig");
const file = @import("../sys/file.zig");
const kfx = @import("../kindle/kfx.zig");
const now_us = os.now_us;
const app = @import("../app.zig");
const picture = @import("../epub/picture.zig");
const draw = @import("../ui/draw.zig");

pub const lock_redraw_us = 1500 * 1000;

pub const lock_redraws = 2;

/// How a lock ended: the Kindle woke, or noface is leaving (plugged into a computer,
/// or told to stop), with the screen left as it is for whatever comes next.
pub const Woke = enum { woke, leaving };

/// `restore` puts the screen from before back on waking; a caller that redraws
/// everything anyway passes false, saving a whole-screen refresh.
pub const Options = struct { restore: bool = true };

/// Shows the book's cover while the Kindle sleeps, then puts the screen back. A
/// screen update that fails is logged, never fatal: the Kindle is asleep, and the
/// reader shouldn't wake to an error.
pub fn lock_screen(a: *app.App, entry: ?*const catalog.Entry, options: Options) Woke {
    @memcpy(a.lock_saved, a.screen.pixels);
    const target = a.lock_cover;
    // The reader's own picture, if they chose it and it's there; else the book's cover
    var picture_buf: [320]u8 = undefined;
    const own = if (a.settings.lock_picture) picture_path(a, &picture_buf) else null;
    const own_data: ?[]const u8 = if (own) |p| file.map(p) catch null else null;
    defer if (own_data) |d| file.unmap(d);
    const book_key: u64 = if (entry) |e| key_for(e) else 1;
    const wanted = if (own_data) |d| picture_key(d) else book_key;
    if (a.lock_cover_key != wanted) {
        // The key kept is of what was really drawn: a picture that won't decode leaves
        // the book's cover, which mustn't be kept as if it were the picture
        var drew_picture = false;
        if (own_data) |d| if (wanted != a.lock_picture_bad) {
            drew_picture = cover.fill_screen(a.alloc, d, target, a.screen.width, a.screen.height, a.screen.stride);
            if (!drew_picture) {
                a.lock_picture_bad = wanted; // Not decoded again until the file changes
                std.debug.print("lock screen picture can't be read\n", .{});
            }
        };
        const drawn = drew_picture or (if (entry) |e| draw_cover(a, e, target) else false);
        if (!drawn) draw_title(a, entry, target);
        a.lock_cover_key = if (drew_picture) wanted else book_key;
        std.debug.print("locked, cover drawn: {}\n", .{drawn});
    } else std.debug.print("locked, cover kept\n", .{});
    a.present(target, .flash) catch |err| std.debug.print("lock screen not shown: {s}\n", .{@errorName(err)});

    // Stock paints its own lock screen just after this, so draw over it again.
    const was = a.input.enter(a.input.modes(), lock_redraw_us);
    defer a.input.leave(was);
    a.input.locked = true;
    defer a.input.locked = false;
    var redraws: u32 = 0;
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tick => {
                redraws += 1;
                // Only when stock painted over it, and only the pixels it changed.
                if (!std.mem.eql(u8, a.screen.pixels, target)) {
                    std.debug.print("lock cover repainted\n", .{});
                    a.present(target, .screen) catch {};
                }
                if (redraws == lock_redraws) a.input.tick_us = 0;
            },
            .unlock => break,
            .computer, .stop => {
                // Leaving: no point lighting up the old screen first
                a.input.hold_back(action);
                return .leaving;
            },
            else => {},
        }
    }
    a.input.last_input = now_us();
    if (options.restore) a.present(a.lock_saved, .flash) catch |err| std.debug.print("screen not put back: {s}\n", .{@errorName(err)});
    return .woke;
}

/// The reader's lock screen picture, in the data folder: lockscreen.jpg or .png.
fn picture_path(a: *const app.App, buf: []u8) ?[:0]const u8 {
    for ([_][]const u8{ "jpg", "jpeg", "png" }) |ext| {
        const p = std.fmt.bufPrintSentinel(buf, "{s}/lockscreen.{s}", .{ a.state_dir, ext }, 0) catch continue;
        if (file.exists(p)) return p;
    }
    return null;
}

/// Whether the reader has put a lock screen picture in the data folder.
pub fn has_picture(a: *const app.App) bool {
    var buf: [320]u8 = undefined;
    return picture_path(a, &buf) != null;
}

/// Tells pictures apart for the kept lock screen, so a replaced one is drawn again.
fn picture_key(data: []const u8) u64 {
    var h = std.hash.Wyhash.init(1);
    h.update(data[0..@min(data.len, 4096)]);
    h.update(std.mem.asBytes(&data.len));
    return h.final() | 2;
}

/// Tells books apart for the kept lock screen: never 0 (nothing kept) or 1 (no book).
fn key_for(e: *const catalog.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.path);
    h.update(e.thumbnail);
    return h.final() | 2;
}

/// The cover, filling the screen. The catalog's thumbnail is the cover the library
/// shows; a Kindle book's own first picture is sharper, so it's used instead when it
/// has the thumbnail's shape, and so is the cover rather than a map or picture inside.
fn draw_cover(a: *app.App, e: *const catalog.Entry, target: []u8) bool {
    const thumb: ?[]const u8 = if (e.thumbnail.len > 0) file.map(e.thumbnail) catch null else null;
    defer if (thumb) |t| file.unmap(t);
    if (e.is_local() and !e.is_epub()) {
        if (file.map(e.path)) |data| {
            defer file.unmap(data);
            if (kfx.cover_image(data)) |jpeg| {
                if (thumb == null or same_shape(jpeg, thumb.?)) {
                    if (cover.fill_screen(a.alloc, jpeg, target, a.screen.width, a.screen.height, a.screen.stride)) return true;
                }
            }
        } else |_| {}
    }
    const t = thumb orelse return false;
    return cover.fill_screen(a.alloc, t, target, a.screen.width, a.screen.height, a.screen.stride);
}

/// Whether two pictures have the same proportions, within a few percent. Unknown
/// sizes count as the same, so nothing is turned down for want of a header.
pub fn same_shape(x: []const u8, y: []const u8) bool {
    const p = picture.size(x) orelse return true;
    const q = picture.size(y) orelse return true;
    const lhs = @as(u64, p.width) * q.height;
    const rhs = @as(u64, q.width) * p.height;
    const diff = if (lhs > rhs) lhs - rhs else rhs - lhs;
    return diff * 100 <= @max(lhs, rhs) * 4;
}

/// No cover: the title, wrapped, and the author under it, on white.
fn draw_title(a: *app.App, entry: ?*const catalog.Entry, target: []u8) void {
    @memset(target, 0xff);
    const e = entry orelse return;
    const page = a.page(target);
    const side = 120;
    const avail: f32 = @floatFromInt(a.screen.width - 2 * side);
    const step = a.ui.hero.line_height;
    const lines = draw.wrapped(a.ui.hero, page, side, 760, step, e.title, avail, 4) catch 1;
    if (e.author.len > 0) draw.clipped(a.ui.small, page, side, 760 + @as(i32, @intCast(lines)) * step + 24, e.author, avail) catch {};
}

test "a cover and a picture of another shape tell apart" {
    // PNG headers with only a size: 600x800 and 1200x1600 match, 800x600 doesn't
    const png = struct {
        fn of(w: u32, h: u32) [24]u8 {
            var b: [24]u8 = @splat(0);
            @memcpy(b[0..8], "\x89PNG\r\n\x1a\n");
            std.mem.writeInt(u32, b[16..20], w, .big);
            std.mem.writeInt(u32, b[20..24], h, .big);
            return b;
        }
    }.of;
    const cover_small = png(600, 800);
    const cover_big = png(1200, 1600);
    const map = png(800, 600);
    try std.testing.expect(same_shape(&cover_big, &cover_small));
    try std.testing.expect(!same_shape(&map, &cover_small));
    try std.testing.expect(same_shape("not a picture", &cover_small));
}
