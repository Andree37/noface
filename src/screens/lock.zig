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
const lock_ui = @import("../ui/lock.zig");
const screen = @import("screen.zig");
const input_mod = @import("../kindle/input.zig");

const lock_redraw_us = 1500 * std.time.us_per_ms;

const lock_redraws = 2;

/// Pictures of the same proportions, within this many percent, count as one shape.
const shape_tolerance_percent = 4;

comptime {
    assert(lock_redraws > 0);
    assert(lock_redraw_us > 0);
    assert(shape_tolerance_percent < 100);
}

/// `restore` puts the screen from before back on waking; a caller that redraws
/// everything anyway passes false, saving a whole-screen refresh.
pub const Options = struct { restore: bool = true };

/// The lock screen, to open over the library or a book while the Kindle sleeps: the
/// book's cover, drawn again when stock paints over it, until the Kindle wakes (done)
/// or noface leaves (interrupted: a computer, or a stop, goes to the screen under it).
/// A screen update that fails is logged, never fatal: the Kindle is asleep, and the
/// reader shouldn't wake to an error.
pub fn make(a: *app.App, entry: ?*const catalog.Entry, options: Options) Lock {
    assert(a.lock_kept.saved.len == a.display.screen.pixels.len);
    assert(a.lock_kept.cover.len == a.display.screen.pixels.len);
    // Touches are taken as they were, though none counts while it's up
    return .{ .a = a, .entry = entry, .options = options, .modes = a.input.modes() };
}

pub const Lock = struct {
    pub const Result = void; // Done when the Kindle wakes
    /// Another lock while asleep changes nothing.
    pub const takes = screen.Takes{ .lock = true };
    a: *app.App,
    entry: ?*const catalog.Entry,
    options: Options,
    modes: input_mod.Input.Modes,
    redraws: u32 = 0,

    /// Drawn once, as it opens; repainted on ticks after.
    pub fn draw(l: *Lock, part: screen.Part) !void {
        assert(part == .all);
        assert(l.redraws == 0);
        l.show();
    }

    /// Keeps the screen from before, and shows the cover with a flash.
    fn show(l: *Lock) void {
        assert(l.redraws == 0);
        const a = l.a;
        @memcpy(a.lock_kept.saved, a.display.screen.pixels);
        draw_target(a, l.entry);
        assert(a.lock_kept.shown != null); // Drawn now, or kept from the last lock
        a.display.present(a.lock_kept.cover, .flash) catch |err| {
            std.debug.print("lock screen not shown: {s}\n", .{@errorName(err)});
        };
    }

    /// Stock paints its own lock screen just after this, so it ticks a few times to
    /// draw over it again. Asleep: the input sleeps too, between events.
    pub fn setting(l: *const Lock) input_mod.Input.Scope {
        assert(l.redraws <= lock_redraws);
        const tick_us: ?u64 = if (l.redraws < lock_redraws) lock_redraw_us else null;
        return .{ .modes = l.modes, .tick_us = tick_us, .locked = true };
    }

    pub fn on_tick(l: *Lock) !screen.Step(void) {
        assert(l.redraws < lock_redraws); // No more ticks after the last redraw
        l.repaint();
        assert(l.redraws <= lock_redraws);
        return .stay;
    }

    /// The cover again, if stock painted over it.
    fn repaint(l: *Lock) void {
        assert(l.redraws < lock_redraws);
        l.redraws += 1;
        const a = l.a;
        // Only when stock painted over it, and only the pixels it changed.
        if (!std.mem.eql(u8, a.display.screen.pixels, a.lock_kept.cover)) {
            std.debug.print("lock cover repainted\n", .{});
            a.display.present(a.lock_kept.cover, .screen) catch |err| {
                std.debug.print("lock cover not repainted: {s}\n", .{@errorName(err)});
            };
        }
        assert(l.redraws <= lock_redraws);
    }

    /// Waking: the screen from before back, unless the caller redraws it anyway.
    pub fn on_action(l: *Lock, action: input_mod.Action) !screen.Step(void) {
        assert(l.a.input.locked);
        if (action != .unlock) return .stay; // Touches and the rest, while asleep
        l.wake();
        assert(action == .unlock);
        return .{ .done = {} };
    }

    fn wake(l: *Lock) void {
        assert(l.a.input.locked);
        l.a.input.last_input = now_us();
        if (l.options.restore) {
            l.a.display.present(l.a.lock_kept.saved, .flash) catch |err| {
                std.debug.print("screen not put back: {s}\n", .{@errorName(err)});
            };
        }
        assert(l.a.input.last_input > 0);
    }

    pub fn on_tap(l: *Lock, _: screen.Tap) !screen.Step(void) {
        assert(l.a.input.locked);
        assert(l.redraws <= lock_redraws);
        return .stay; // A touch while asleep does nothing
    }
};

/// Draws what the lock screen shows into `a.lock_kept.cover`, unless it's there already:
/// the reader's own picture, if they chose it, it's there and it decodes; else the
/// book's cover.
fn draw_target(a: *app.App, entry: ?*const catalog.Entry) void {
    // Drawn into the kept cover, a whole screen apart from the one shown
    assert(a.lock_kept.cover.len == a.display.screen.pixels.len);
    assert(a.lock_kept.cover.ptr != a.display.screen.pixels.ptr);
    var picture_buffer: [file.own_path_bytes_max]u8 = undefined;
    const own = if (a.user.settings.lock_picture) picture_path(a, &picture_buffer) else null;
    const own_data: ?[]const u8 = if (own) |p| file.map(p) catch null else null;
    defer if (own_data) |d| file.unmap(d);
    const book: lock_ui.Shown = if (entry) |e| .{ .book = key_for(e) } else .no_book;
    const own_picture: ?Picture = if (own_data) |d| picture_to_try(a, d) else null;
    // A picture that didn't decode wants the book, as was drawn in its place
    const wanted: lock_ui.Shown = if (own_picture) |p| .{ .picture = p.key } else book;
    if (!std.meta.eql(a.lock_kept.shown, @as(?lock_ui.Shown, wanted))) {
        lock_screen_draw(a, entry, own_picture, book);
    } else {
        std.debug.print("locked, cover kept\n", .{});
    }
    assert(a.lock_kept.shown != null);
}

/// The reader's lock screen picture, mapped, and the key it's kept by.
const Picture = struct { data: []const u8, key: u64 };

/// The picture in `data`, unless it's one that didn't decode: that isn't tried again
/// until the file changes.
fn picture_to_try(a: *const app.App, data: []const u8) ?Picture {
    const key = picture_key(data);
    if (a.lock_kept.picture_bad == key) return null;
    return .{ .data = data, .key = key };
}

/// Draws the lock screen into `a.lock_kept.cover`: `own_picture` when it decodes, else the
/// book's cover, else its title on white (`book` says which book). Keeps what it drew.
fn lock_screen_draw(
    a: *app.App,
    entry: ?*const catalog.Entry,
    own_picture: ?Picture,
    book: lock_ui.Shown,
) void {
    assert(book != .picture);
    assert(a.lock_kept.cover.len == a.display.screen.pixels.len);
    const target = a.lock_kept.cover;
    // What's kept is what was really drawn: a picture that won't decode leaves the
    // book's cover, which mustn't be kept as if it were the picture
    var drew: ?u64 = null; // The picture drawn, by its key
    if (own_picture) |p| {
        const w = a.display.screen.width;
        const eink = a.display.screen;
        if (cover.fill_screen(a.alloc, p.data, target, w, eink.height, eink.stride)) {
            drew = p.key;
        } else {
            a.lock_kept.picture_bad = p.key;
            std.debug.print("lock screen picture can't be read\n", .{});
        }
    }
    const drawn = drew != null or (if (entry) |e| draw_cover(a, e, target) else false);
    if (!drawn) draw_title(a, entry, target);
    a.lock_kept.shown = if (drew) |key| .{ .picture = key } else book;
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
    var buffer: [file.own_path_bytes_max]u8 = undefined;
    return picture_path(a, &buffer) != null;
}

/// How much of a picture's start its key is made from, with its length: enough to tell
/// pictures apart without reading a large one whole on every lock.
const picture_key_bytes = 4096;

/// Tells pictures apart for the kept lock screen, so a replaced one is drawn again.
fn picture_key(data: []const u8) u64 {
    assert(data.len > 0); // A mapped file is never empty
    var h = std.hash.Wyhash.init(1);
    h.update(data[0..@min(data.len, picture_key_bytes)]);
    h.update(std.mem.asBytes(&data.len));
    return h.final();
}

/// Tells books apart for the kept lock screen.
fn key_for(e: *const catalog.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(e.path);
    h.update(e.thumbnail orelse "");
    return h.final();
}

/// The cover, filling the screen. The catalog's thumbnail is the cover the library
/// shows; a Kindle book's own first picture is sharper, so it's used instead when it
/// has the thumbnail's shape, and so is the cover rather than a map or picture inside.
fn draw_cover(a: *app.App, e: *const catalog.Entry, target: []u8) bool {
    assert(target.len == a.display.screen.pixels.len);
    assert(a.display.screen.stride >= a.display.screen.width);
    var thumbnail: ?[]const u8 = null;
    if (e.thumbnail) |t| thumbnail = file.map(t) catch null;
    defer if (thumbnail) |t| file.unmap(t);
    const width = a.display.screen.width;
    const height = a.display.screen.height;
    const stride = a.display.screen.stride;
    if (e.is_local() and !e.is_epub()) {
        // A book that can't be read has no cover of its own to give: its thumbnail's
        // is tried next
        const book: ?[]const u8 = file.map(e.path) catch null;
        defer if (book) |data| file.unmap(data);
        if (book) |data| {
            if (kfx.cover_image(data)) |jpeg| {
                if (thumbnail == null or same_shape(jpeg, thumbnail.?)) {
                    const drawn = cover.fill_screen(a.alloc, jpeg, target, width, height, stride);
                    if (drawn) return true;
                }
            }
        }
    }
    const t = thumbnail orelse return false;
    return cover.fill_screen(a.alloc, t, target, width, height, stride);
}

/// Whether two pictures have the same proportions, within a few percent. Unknown
/// sizes count as the same, so nothing is turned down for want of a header.
fn same_shape(x: []const u8, y: []const u8) bool {
    const p = picture.size(x) orelse return true;
    const q = picture.size(y) orelse return true;
    const lhs = @as(u64, p.width) * q.height;
    const rhs = @as(u64, q.width) * p.height;
    const difference = if (lhs > rhs) lhs - rhs else rhs - lhs;
    assert(difference <= @max(lhs, rhs));
    return difference * 100 <= @max(lhs, rhs) * shape_tolerance_percent;
}

/// No cover: the title, wrapped, and the author under it, on white.
fn draw_title(a: *app.App, entry: ?*const catalog.Entry, target: []u8) void {
    assert(target.len == a.display.screen.pixels.len);
    assert(target.ptr != a.display.screen.pixels.ptr); // Drawn apart, shown whole after
    const page = a.display.page(target);
    if (entry) |e| {
        lock_ui.render_title(a.ui, page, e.title, e.author);
    } else {
        lock_ui.render_title(a.ui, page, null, "");
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
