//! A book's picture on the whole screen, from pressing and holding it on the page.
//! Tap to zoom in (up to four times as close), centred where the tap lands;
//! double-tap to see the whole picture again; drag to move around a zoomed picture;
//! the round button closes it.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const memory = @import("../../base/memory.zig");
const image = @import("../../gfx/image.zig");
const Page = @import("../../gfx/page.zig").Page;
const jpegxr = @import("../../kindle/jpegxr.zig");
const touch_zones = @import("../../kindle/touch.zig");
const draw = @import("../../ui/draw.zig");
const style = @import("../../ui/style.zig");
const app = @import("../../app.zig");
const screen = @import("../screen.zig");
const input_mod = @import("../../kindle/input.zig");
const os = @import("../../sys/os.zig");

/// Bigger than this and it isn't worth the memory: a page-sized scan is ~5M.
const pixels_max = 24 * 1000 * 1000;
/// Zoom steps after fitting the screen: twice, then four times as close.
const steps = [_]f32{ 1, 2, 4 };
/// The close button, top right, a fingertip across.
const close_radius = 50;
const close_center_x = style.screen_width - 40 - close_radius;
const close_center_y = 40 + close_radius;
/// How far from the button's centre a tap still closes: a fingertip around it.
const close_reach = close_radius + 30;
/// How long after a tap a second one makes it a double tap, and how near it must land.
const double_tap_us = 300 * 1000;
const double_tap_reach = 120;

comptime {
    // A picture worth decoding fits a 32-bit size, as the Kindle's usize is
    assert(pixels_max <= std.math.maxInt(u32));
    // The first step is the fit itself, and each one after comes closer
    assert(steps[0] == 1);
    for (steps[1..], steps[0 .. steps.len - 1]) |step, previous| assert(step > previous);
    // The button is on the screen, with room for its ring inside it
    assert(close_center_x + close_reach <= style.screen_width);
    assert(close_center_y >= close_radius);
    assert(close_radius > style.border);
    assert(close_reach > close_radius);
    assert(double_tap_reach > 0);
}

/// Whether a picture's size is worth decoding. In 64 bits: on the Kindle a usize is
/// 32, and a corrupt header's 70000 x 70000 would overflow it.
fn decodable(width: u64, height: u64) bool {
    const ok = width > 0 and height > 0 and width * height <= pixels_max;
    if (ok) assert(width <= pixels_max);
    if (ok) assert(height <= pixels_max);
    return ok;
}

fn decode(alloc: std.mem.Allocator, img: book_model.Image) ?image.Gray {
    if (!decodable(img.width, img.height)) return null;
    const g: image.Gray = if (jpegxr.is_jpeg_xr(img.data)) blk: {
        const x = jpegxr.decode_jpeg_xr(alloc, img.data, img.width, img.height) orelse return null;
        break :blk .{ .pixels = x.pixels, .width = x.width, .height = x.height };
    } else image.decode_gray_from(alloc, .{
        .bytes = img.data,
        .deflated = img.deflated,
        .inflated_size = img.inflated_size,
    }, pixels_max) orelse return null;
    if (!decodable(g.width, g.height)) return null;
    return g;
}

const View = struct {
    picture: image.Gray,
    step: u32 = 0,
    center_x: f32,
    center_y: f32,
    fit: f32, // Screen pixels per picture pixel when it just fits

    fn zoom(v: *const View) f32 {
        assert(v.step < steps.len);
        assert(v.fit > 0);
        return v.fit * steps[v.step];
    }

    /// Keeps the view's centre where the picture still fills the screen.
    fn clamp(v: *View) void {
        const width: f32 = @floatFromInt(v.picture.width);
        const height: f32 = @floatFromInt(v.picture.height);
        v.center_x = image.clamp_centre(v.center_x, width, style.screen_width, v.zoom());
        v.center_y = image.clamp_centre(v.center_y, height, style.screen_height, v.zoom());
        assert(v.center_x >= 0);
        assert(v.center_x <= width);
        assert(v.center_y >= 0);
        assert(v.center_y <= height);
    }

    fn whole(v: *View) void {
        assert(v.picture.width > 0);
        assert(v.picture.height > 0);
        v.step = 0;
        v.center_x = @as(f32, @floatFromInt(v.picture.width)) / 2;
        v.center_y = @as(f32, @floatFromInt(v.picture.height)) / 2;
    }

    /// The picture point under a screen point.
    fn picture_at(v: *const View, x: i32, y: i32) struct { x: f32, y: f32 } {
        // The centre is kept on the picture, by `clamp` and `whole`
        assert(v.center_x >= 0);
        assert(v.center_y >= 0);
        return .{
            .x = v.center_x + (@as(f32, @floatFromInt(x)) - style.screen_width / 2) / v.zoom(),
            .y = v.center_y + (@as(f32, @floatFromInt(y)) - style.screen_height / 2) / v.zoom(),
        };
    }
};

/// Draws the view and starts the update, returning it to wait on. Settled, the
/// picture gets its 16 grays; while a finger moves it's made pure black and white
/// for the fast update, which leaves grays alone.
fn draw_view(a: *app.App, v: *const View, settled: bool) !u32 {
    assert(v.step < steps.len);
    assert(a.overlay.len >= a.screen.stride * a.screen.height);
    // Drawn in ordinary memory, then copied: the screen's own memory is slow to read
    // back, and dithering reads every pixel it writes
    const page = a.page(a.overlay);
    const t0 = os.now_us();
    const zoom = v.zoom();
    const width = a.screen.width;
    const height = a.screen.height;
    image.zoomed(v.picture, v.center_x, v.center_y, zoom, page, width, height, settled);
    if (settled) {
        const pixels = a.overlay[0 .. a.screen.stride * a.screen.height];
        image.dither(a.alloc, pixels, a.screen.stride) catch {}; // Ignored: grays still show.
    } else {
        page.threshold(0, a.screen.height);
    }
    draw_view_close_button(page);
    // How it works, at the bottom, until the first zoom
    if (v.step == 0 and settled) try draw_view_hint(a, page);
    @memcpy(a.screen.pixels, a.overlay);
    std.debug.print("picture drawn in {d} ms\n", .{(os.now_us() - t0) / 1000});
    return a.screen.show(if (settled) .screen else .quick);
}

/// The close button: a white disc with a ring and a cross.
fn draw_view_close_button(page: Page) void {
    const arm: f32 = 16;
    const center_x: f32 = close_center_x;
    const center_y: f32 = close_center_y;
    comptime assert(arm < close_radius - style.border);
    page.disc(close_center_x, close_center_y, close_radius, 0, style.black);
    page.disc(close_center_x, close_center_y, close_radius - style.border, 0, style.white);
    page.stroke(center_x - arm, center_y - arm, center_x + arm, center_y + arm, 4);
    page.stroke(center_x - arm, center_y + arm, center_x + arm, center_y - arm, 4);
}

/// How to zoom, move and go back, in a box at the bottom of the screen.
fn draw_view_hint(a: *app.App, page: Page) !void {
    const hint = "Tap to zoom in  \u{b7}  double-tap to zoom out" ++
        "  \u{b7}  drag to move";
    const width: u32 = @intFromFloat(try a.ui.caption.measure(hint) + 64);
    assert(width <= a.screen.width);
    const top = a.screen.height - 120;
    assert(top < a.screen.height);
    draw.box(page, (a.screen.width - width) / 2, top, width, 64);
    const center_x: f32 = @floatFromInt(a.screen.width / 2);
    try draw.centered(a.ui.caption, page, center_x, @intCast(top + 42), hint);
}

fn render(a: *app.App, v: *const View) !void {
    assert(v.picture.width > 0);
    assert(v.picture.height > 0);
    try a.screen.wait_complete(try draw_view(a, v, true));
}

/// Follows one finger from touching to lifting: past the slop it pans a zoomed view.
const Follow = struct {
    a: *app.App,
    v: *View,
    start_x: i32,
    start_y: i32,
    start_center_x: f32,
    start_center_y: f32,
    panned: bool = false, // Moved past the slop: a drag, not a tap

    pub fn moved(f: *Follow, x: i32, y: i32) !?u32 {
        assert(f.v.step < steps.len);
        if (!f.panned and !touch_zones.moved_off(f.start_x, f.start_y, x, y)) return null;
        f.panned = true;
        if (f.v.step == 0) return null; // The whole picture shows: nowhere to go
        // Zoomed in, the picture is larger than the screen, so there's somewhere to go
        assert(f.v.zoom() > f.v.fit);
        f.v.center_x = f.start_center_x - @as(f32, @floatFromInt(x - f.start_x)) / f.v.zoom();
        f.v.center_y = f.start_center_y - @as(f32, @floatFromInt(y - f.start_y)) / f.v.zoom();
        f.v.clamp();
        return try draw_view(f.a, f.v, false);
    }
};

/// What came after a tap, within the double tap's moment.
const After = enum { nothing, double_tap, other_tap, quit };

/// Waits briefly for a second tap near the first. One that lands elsewhere is left
/// for the main loop as a tap of its own.
fn after_tap(a: *app.App, x: i32, y: i32) After {
    const was = a.input.enter(a.input.modes(), double_tap_us);
    defer a.input.leave(was);
    // The tick that ends the wait comes after the double tap's moment
    assert(a.input.tick_us == double_tap_us);
    while (a.input.next_for()) |action| switch (action) {
        .tick => return .nothing, // No second tap in time
        .tap => |t| {
            const near_x = @abs(t.x - x) <= double_tap_reach;
            const near_y = @abs(t.y - y) <= double_tap_reach;
            if (near_x and near_y) return follow_second_tap(a, t);
            a.input.hold_back(action);
            return .other_tap;
        },
        else => {},
    };
    // Only a lock or a stop ends the wait otherwise, and it's kept for the loop
    assert(a.input.held_back() != null);
    return .quit;
}

/// The second tap's finger, followed to its lift (which isn't a new tap): a double tap
/// if it stayed put, else a drag after all.
fn follow_second_tap(a: *app.App, t: input_mod.Tap) After {
    a.input.begin_drag();
    assert(a.input.drag_slot != null);
    var still = true;
    while (a.input.next_for()) |action| switch (action) {
        .drag => |drag_x| {
            if (touch_zones.moved_off(t.x, t.y, drag_x, a.input.drag_y)) still = false;
        },
        .drag_end => return if (still) .double_tap else .nothing,
        else => {},
    };
    // Only a lock or a stop ends the wait otherwise, and it's kept for the loop
    assert(a.input.held_back() != null);
    return .quit;
}

fn on_close(x: i32, y: i32) bool {
    const distance_x = x - close_center_x;
    const distance_y = y - close_center_y;
    return distance_x * distance_x + distance_y * distance_y <= close_reach * close_reach;
}

/// The picture, full screen, until it's closed. Touches come at once, so a drag can
/// follow them; edge zones would hold back taps near the top, so they're off, and a
/// resting thumb is skipped in `on_tap` instead.
const Viewer = struct {
    pub const Result = void;
    pub const touches = input_mod.Input.Modes{
        .grips = false,
        .deferred = false,
        .edge_zones = false,
    };
    a: *app.App,
    v: View,

    pub fn draw(viewer: *Viewer, _: screen.Part) !void {
        assert(viewer.v.step < steps.len);
        assert(viewer.v.fit > 0);
        try render(viewer.a, &viewer.v);
    }

    /// A finger on the picture: a drag pans it; a tap on the close button closes it; a
    /// double tap shows it whole; a single tap goes a step closer, centred on it.
    pub fn on_tap(viewer: *Viewer, t: screen.Tap) !screen.Step(void) {
        const a = viewer.a;
        const v = &viewer.v;
        assert(v.step < steps.len);
        // A thumb resting where the Kindle is held isn't a tap
        if (touch_zones.is_grip(t.x, t.y, a.input.width, a.input.height)) return .stay;
        a.input.begin_drag();
        var follow = Follow{
            .a = a,
            .v = v,
            .start_x = t.x,
            .start_y = t.y,
            .start_center_x = v.center_x,
            .start_center_y = v.center_y,
        };
        _ = try app.follow_drag(a, null, &follow);
        // Locked, leaving, or another touch came in
        if (a.input.held_back() != null) return .close;
        // Its grays back
        if (follow.panned) return if (v.step > 0) .{ .redraw = .all } else .stay;
        // Closing on the lift, so a drag that starts by the button still pans
        if (on_close(t.x, t.y)) return .close;
        switch (after_tap(a, t.x, t.y)) {
            .quit => return .close,
            .double_tap => {
                if (v.step == 0) return .stay;
                v.whole();
            },
            .nothing, .other_tap => {
                if (v.step + 1 == steps.len) return .stay; // Already at the closest step
                const at = v.picture_at(t.x, t.y);
                v.step += 1;
                v.center_x = at.x;
                v.center_y = at.y;
            },
        }
        v.clamp();
        assert(v.step < steps.len);
        std.debug.print("picture zoom {d}x\n", .{@as(u32, @intFromFloat(steps[v.step]))});
        return .{ .redraw = .all };
    }
};

/// Shows the picture until it's closed, then puts the page back as it was.
pub fn show(a: *app.App, img: book_model.Image) !void {
    var budget = memory.Budget{
        .name = "picture",
        .child = std.heap.smp_allocator,
        .limit = 64 << 20,
    };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer {
        arena.deinit();
        budget.report();
    }
    const saved = try arena.allocator().dupe(u8, a.screen.pixels);
    const picture = decode(arena.allocator(), img) orelse {
        try app.show_notice(a, "This picture can't be shown larger.");
        // The notice was drawn over the page: put the page back
        try a.present(saved, .page);
        return;
    };
    // Checked as it was decoded: what follows divides by its size
    assert(decodable(picture.width, picture.height));
    std.debug.print("picture: {d}x{d}\n", .{ picture.width, picture.height });
    const picture_width: f32 = @floatFromInt(picture.width);
    const picture_height: f32 = @floatFromInt(picture.height);
    const fit = @min(style.screen_width / picture_width, style.screen_height / picture_height);
    assert(fit > 0);
    var viewer = Viewer{ .a = a, .v = .{
        .picture = picture,
        .center_x = picture_width / 2,
        .center_y = picture_height / 2,
        .fit = fit,
    } };
    _ = try screen.run(a, &viewer);
    try a.present(saved, .flash);
}

test "taps on and near the close button close" {
    try std.testing.expect(on_close(close_center_x, close_center_y));
    try std.testing.expect(on_close(close_center_x - close_radius - 20, close_center_y));
    try std.testing.expect(!on_close(600, 800));
}

test "sizes too big to decode are refused without overflowing" {
    try std.testing.expect(decodable(2000, 3000));
    try std.testing.expect(!decodable(70000, 70000));
    try std.testing.expect(!decodable(0xffff_ffff, 0xffff_ffff));
    try std.testing.expect(!decodable(0, 10));
}
