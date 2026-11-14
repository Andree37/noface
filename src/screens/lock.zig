//! The lock screen: the book's cover while the Kindle sleeps.
const std = @import("std");
const assert = std.debug.assert;
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

/// The key kept when no lock screen is kept, and the key of the title on white drawn
/// for no book. Every picture's and book's key is above both.
const key_nothing = 0;
const key_no_book = 1;

/// Pictures of the same proportions, within this many percent, count as one shape.
const shape_tolerance_percent = 4;

/// The title drawn for a book without a cover: this far in from either side, and its
/// first line this far down.
const title_side = 120;
const title_top = 760;
const title_lines_max = 4;

comptime {
    assert(lock_redraws > 0);
    assert(lock_redraw_us > 0);
    assert(key_nothing != key_no_book);
    assert(shape_tolerance_percent < 100);
    assert(title_lines_max > 0);
}

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
    assert(a.lock_saved.len == a.screen.pixels.len);
    assert(a.lock_cover.len == a.screen.pixels.len);
    @memcpy(a.lock_saved, a.screen.pixels);
    const target = a.lock_cover;
    // The reader's own picture, if they chose it and it's there; else the book's cover
    var picture_buffer: [320]u8 = undefined;
    const own = if (a.settings.lock_picture) picture_path(a, &picture_buffer) else null;
    const own_data: ?[]const u8 = if (own) |p| file.map(p) catch null else null;
    defer if (own_data) |d| file.unmap(d);
    const book_key: u64 = if (entry) |e| key_for(e) else key_no_book;
    const wanted = if (own_data) |d| picture_key(d) else book_key;
    if (a.lock_cover_key != wanted) {
        lock_screen_draw(a, entry, own_data, wanted, book_key);
    } else {
        std.debug.print("locked, cover kept\n", .{});
    }
    // What's kept is a picture's, a book's, or the title on white's: never nothing
    assert(a.lock_cover_key != key_nothing);
    a.present(target, .flash) catch |err| {
        std.debug.print("lock screen not shown: {s}\n", .{@errorName(err)});
    };

    // Stock paints its own lock screen just after this, so draw over it again.
    const was = a.input.enter(a.input.modes(), lock_redraw_us);
    defer a.input.leave(was);
    a.input.locked = true;
    defer a.input.locked = false;
    var redraws: u32 = 0;
    // Unbounded: the Kindle sleeps for as long as the reader leaves it
    while (true) {
        const action = a.input.next();
        switch (action) {
            .tick => {
                redraws += 1;
                // Only when stock painted over it, and only the pixels it changed.
                if (!std.mem.eql(u8, a.screen.pixels, target)) {
                    std.debug.print("lock cover repainted\n", .{});
                    a.present(target, .screen) catch |err| {
                        std.debug.print("lock cover not repainted: {s}\n", .{@errorName(err)});
                    };
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
    assert(a.input.locked);
    a.input.last_input = now_us();
    if (options.restore) {
        a.present(a.lock_saved, .flash) catch |err| {
            std.debug.print("screen not put back: {s}\n", .{@errorName(err)});
        };
    }
    return .woke;
}

/// Draws the lock screen into `a.lock_cover`: the reader's picture when it decodes,
/// else the book's cover, else its title on white. Keeps the key of what it drew.
fn lock_screen_draw(
    a: *app.App,
    entry: ?*const catalog.Entry,
    own_data: ?[]const u8,
    wanted: u64,
    book_key: u64,
) void {
    // A book's or a picture's key is above the title on white's; that one only for no book
    if (entry != null) assert(book_key > key_no_book);
    assert(wanted != key_nothing);
    assert(book_key != key_nothing);
    const target = a.lock_cover;
    // The key kept is of what was really drawn: a picture that won't decode leaves
    // the book's cover, which mustn't be kept as if it were the picture
    var drew_picture = false;
    if (own_data) |d| {
        if (wanted != a.lock_picture_bad) {
            drew_picture = cover.fill_screen(
                a.alloc,
                d,
                target,
                a.screen.width,
                a.screen.height,
                a.screen.stride,
            );
            if (!drew_picture) {
                a.lock_picture_bad = wanted; // Not decoded again until the file changes
                std.debug.print("lock screen picture can't be read\n", .{});
            }
        }
    }
    const drawn = drew_picture or (if (entry) |e| draw_cover(a, e, target) else false);
    if (!drawn) draw_title(a, entry, target);
    a.lock_cover_key = if (drew_picture) wanted else book_key;
    std.debug.print("locked, cover drawn: {}\n", .{drawn});
}

/// The reader's lock screen picture, in the data folder: lockscreen.jpg or .png.
fn picture_path(a: *const app.App, buffer: []u8) ?[:0]const u8 {
    for ([_][]const u8{ "jpg", "jpeg", "png" }) |extension| {
        const p = std.fmt.bufPrintSentinel(
            buffer,
            "{s}/lockscreen.{s}",
            .{ a.state_dir, extension },
            0,
        ) catch continue;
        assert(std.mem.endsWith(u8, p, extension));
        if (file.exists(p)) return p;
    }
    return null;
}

/// Whether the reader has put a lock screen picture in the data folder.
pub fn has_picture(a: *const app.App) bool {
    var buffer: [320]u8 = undefined;
    return picture_path(a, &buffer) != null;
}

/// Tells pictures apart for the kept lock screen, so a replaced one is drawn again.
fn picture_key(data: []const u8) u64 {
    var h = std.hash.Wyhash.init(1);
    h.update(data[0..@min(data.len, 4096)]);
    h.update(std.mem.asBytes(&data.len));
    const key = h.final() | 2;
    assert(key != key_nothing);
    assert(key != key_no_book);
    return key;
}

/// Tells books apart for the kept lock screen: never 0 (nothing kept) or 1 (no book).
fn key_for(e: *const catalog.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.path);
    h.update(e.thumbnail);
    const key = h.final() | 2;
    assert(key != key_nothing);
    assert(key != key_no_book);
    return key;
}

/// The cover, filling the screen. The catalog's thumbnail is the cover the library
/// shows; a Kindle book's own first picture is sharper, so it's used instead when it
/// has the thumbnail's shape, and so is the cover rather than a map or picture inside.
fn draw_cover(a: *app.App, e: *const catalog.Entry, target: []u8) bool {
    assert(target.len == a.screen.pixels.len);
    assert(a.screen.stride >= a.screen.width);
    var thumbnail: ?[]const u8 = null;
    if (e.thumbnail.len > 0) thumbnail = file.map(e.thumbnail) catch null;
    defer if (thumbnail) |t| file.unmap(t);
    const width = a.screen.width;
    const height = a.screen.height;
    const stride = a.screen.stride;
    if (e.is_local() and !e.is_epub()) {
        if (file.map(e.path)) |data| {
            defer file.unmap(data);
            if (kfx.cover_image(data)) |jpeg| {
                if (thumbnail == null or same_shape(jpeg, thumbnail.?)) {
                    const drawn = cover.fill_screen(a.alloc, jpeg, target, width, height, stride);
                    if (drawn) return true;
                }
            }
        } else |_| {}
    }
    const t = thumbnail orelse return false;
    return cover.fill_screen(a.alloc, t, target, width, height, stride);
}

/// Whether two pictures have the same proportions, within a few percent. Unknown
/// sizes count as the same, so nothing is turned down for want of a header.
pub fn same_shape(x: []const u8, y: []const u8) bool {
    const p = picture.size(x) orelse return true;
    const q = picture.size(y) orelse return true;
    const lhs = @as(u64, p.width) * q.height;
    const rhs = @as(u64, q.width) * p.height;
    const difference = if (lhs > rhs) lhs - rhs else rhs - lhs;
    assert(difference <= @max(lhs, rhs));
    if (lhs == rhs) assert(difference == 0);
    return difference * 100 <= @max(lhs, rhs) * shape_tolerance_percent;
}

/// No cover: the title, wrapped, and the author under it, on white.
fn draw_title(a: *app.App, entry: ?*const catalog.Entry, target: []u8) void {
    assert(target.len == a.screen.pixels.len);
    assert(a.screen.width > 2 * title_side);
    @memset(target, 0xff);
    const e = entry orelse return;
    const page = a.page(target);
    const width_available: f32 = @floatFromInt(a.screen.width - 2 * title_side);
    const step = a.ui.hero.line_height;
    const font = a.ui.hero;
    const lines = draw.wrapped(
        font,
        page,
        title_side,
        title_top,
        step,
        e.title,
        width_available,
        title_lines_max,
    ) catch 1;
    assert(lines <= title_lines_max);
    if (e.author.len > 0) {
        const author_top = title_top + @as(i32, @intCast(lines)) * step + 24;
        draw.clipped(
            a.ui.small,
            page,
            title_side,
            author_top,
            e.author,
            width_available,
        ) catch {}; // Ignored: without the author, the title still says which book it is.
    }
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
