//! A book's picture on the whole screen, from pressing and holding it on the page.
//! Tap to zoom in (up to four times as close), centred where the tap lands;
//! double-tap to see the whole picture again; drag to move around a zoomed picture;
//! the round button closes it.
const std = @import("std");
const book_model = @import("../../model/book.zig");
const memory = @import("../../base/memory.zig");
const image = @import("../../gfx/image.zig");
const jpegxr = @import("../../kindle/jpegxr.zig");
const touch_zones = @import("../../kindle/touch.zig");
const draw = @import("../../ui/draw.zig");
const style = @import("../../ui/style.zig");
const app = @import("../../app.zig");
const screen = @import("../screen.zig");
const input_mod = @import("../../kindle/input.zig");
const os = @import("../../sys/os.zig");

/// Bigger than this and it isn't worth the memory: a page-sized scan is ~5M.
const max_pixels = 24 * 1000 * 1000;
/// Zoom steps after fitting the screen: twice, then four times as close.
const steps = [_]f32{ 1, 2, 4 };
/// The close button, top right, a fingertip across.
const close_r = 50;
const close_cx = style.screen_width - 40 - close_r;
const close_cy = 40 + close_r;
/// How long after a tap a second one makes it a double tap, and how near it must land.
const double_tap_us = 300 * 1000;
const double_tap_reach = 120;

/// Whether a picture's size is worth decoding. In 64 bits: on the Kindle a usize is
/// 32, and a corrupt header's 70000 x 70000 would overflow it.
fn decodable(width: u64, height: u64) bool {
    return width > 0 and height > 0 and width * height <= max_pixels;
}

fn decode(alloc: std.mem.Allocator, img: book_model.Image) ?image.Gray {
    if (!decodable(img.width, img.height)) return null;
    if (jpegxr.isJpegXr(img.data)) {
        const g = jpegxr.decodeJpegXr(alloc, img.data, img.width, img.height) orelse return null;
        return .{ .pixels = g.pixels, .width = g.width, .height = g.height };
    }
    const g = image.decodeGray(alloc, img.data) orelse return null;
    if (!decodable(g.width, g.height)) return null;
    return g;
}

const View = struct {
    picture: image.Gray,
    step: usize = 0,
    cx: f32,
    cy: f32,
    fit: f32, // Screen pixels per picture pixel when it just fits

    fn zoom(v: View) f32 {
        return v.fit * steps[v.step];
    }

    fn clamp(v: *View) void {
        const w: f32 = @floatFromInt(v.picture.width);
        const h: f32 = @floatFromInt(v.picture.height);
        v.cx = image.clampCentre(v.cx, w, style.screen_width, v.zoom());
        v.cy = image.clampCentre(v.cy, h, style.screen_height, v.zoom());
    }

    fn whole(v: *View) void {
        v.step = 0;
        v.cx = @as(f32, @floatFromInt(v.picture.width)) / 2;
        v.cy = @as(f32, @floatFromInt(v.picture.height)) / 2;
    }

    /// The picture point under a screen point.
    fn pictureAt(v: View, x: i32, y: i32) struct { x: f32, y: f32 } {
        return .{
            .x = v.cx + (@as(f32, @floatFromInt(x)) - style.screen_width / 2) / v.zoom(),
            .y = v.cy + (@as(f32, @floatFromInt(y)) - style.screen_height / 2) / v.zoom(),
        };
    }
};

/// Draws the view and starts the update, returning it to wait on. Settled, the
/// picture gets its 16 grays; while a finger moves it's made pure black and white
/// for the fast update, which leaves grays alone.
fn drawView(a: *app.App, v: View, settled: bool) !u32 {
    // Drawn in ordinary memory, then copied: the screen's own memory is slow to read
    // back, and dithering reads every pixel it writes
    const page = a.page(a.overlay);
    const t0 = os.nowUs();
    image.zoomed(v.picture, v.cx, v.cy, v.zoom(), page, a.screen.width, a.screen.height, settled);
    if (settled) {
        image.dither(a.alloc, a.overlay[0 .. a.screen.stride * a.screen.height], a.screen.stride) catch {};
    } else {
        page.threshold(0, a.screen.height);
    }
    // The close button: a white disc with a ring and a cross
    page.disc(close_cx, close_cy, close_r, 0, style.black);
    page.disc(close_cx, close_cy, close_r - style.border, 0, style.white);
    const arm: f32 = 16;
    const cx: f32 = close_cx;
    const cy: f32 = close_cy;
    page.stroke(cx - arm, cy - arm, cx + arm, cy + arm, 4);
    page.stroke(cx - arm, cy + arm, cx + arm, cy - arm, 4);
    if (v.step == 0 and settled) {
        // How it works, at the bottom, until the first zoom
        const hint = "Tap to zoom in  \u{b7}  double-tap to zoom out  \u{b7}  drag to move";
        const w: u32 = @intFromFloat(try a.ui.caption.measure(hint) + 64);
        const top = a.screen.height - 120;
        draw.box(page, (a.screen.width - w) / 2, top, w, 64);
        try draw.centered(a.ui.caption, page, @floatFromInt(a.screen.width / 2), @intCast(top + 42), hint);
    }
    @memcpy(a.screen.pixels, a.overlay);
    std.debug.print("picture drawn in {d} ms\n", .{(os.nowUs() - t0) / 1000});
    return a.screen.show(if (settled) .screen else .quick);
}

fn render(a: *app.App, v: View) !void {
    try a.screen.waitComplete(try drawView(a, v, true));
}

/// Follows one finger from touching to lifting: past the slop it pans a zoomed view.
const Follow = struct {
    a: *app.App,
    v: *View,
    x0: i32,
    y0: i32,
    start_cx: f32,
    start_cy: f32,
    panned: bool = false, // Moved past the slop: a drag, not a tap

    pub fn moved(f: *Follow, x: i32, y: i32) !?u32 {
        if (!f.panned and !touch_zones.movedOff(f.x0, f.y0, x, y)) return null;
        f.panned = true;
        if (f.v.step == 0) return null; // The whole picture shows: nowhere to go
        f.v.cx = f.start_cx - @as(f32, @floatFromInt(x - f.x0)) / f.v.zoom();
        f.v.cy = f.start_cy - @as(f32, @floatFromInt(y - f.y0)) / f.v.zoom();
        f.v.clamp();
        return try drawView(f.a, f.v.*, false);
    }
};

/// What came after a tap, within the double tap's moment.
const After = enum { nothing, double_tap, other_tap, quit };

/// Waits briefly for a second tap near the first. One that lands elsewhere is left
/// for the main loop as a tap of its own.
fn afterTap(a: *app.App, x: i32, y: i32) After {
    const tick = a.input.tick_us;
    defer a.input.tick_us = tick;
    a.input.tick_us = double_tap_us;
    a.input.last_tick = os.nowUs();
    while (a.input.nextFor()) |action| switch (action) {
        .tick => return .nothing, // No second tap in time
        .tap => |t| {
            if (@abs(t.x - x) <= double_tap_reach and @abs(t.y - y) <= double_tap_reach) return followSecondTap(a, t);
            a.input.stashed = action;
            return .other_tap;
        },
        else => {},
    };
    return .quit;
}

/// The second tap's finger, followed to its lift (which isn't a new tap): a double tap
/// if it stayed put, else a drag after all.
fn followSecondTap(a: *app.App, t: input_mod.Tap) After {
    a.input.beginDrag();
    var still = true;
    while (a.input.nextFor()) |action| switch (action) {
        .drag => |dx| {
            if (touch_zones.movedOff(t.x, t.y, dx, a.input.drag_y)) still = false;
        },
        .drag_end => return if (still) .double_tap else .nothing,
        else => {},
    };
    return .quit;
}

fn onClose(x: i32, y: i32) bool {
    const dx = x - close_cx;
    const dy = y - close_cy;
    const reach = close_r + 30;
    return dx * dx + dy * dy <= reach * reach;
}

/// The picture, full screen, until it's closed. Touches come at once, so a drag can
/// follow them; edge zones would hold back taps near the top, so they're off, and a
/// resting thumb is skipped in `onTap` instead.
const Viewer = struct {
    pub const Result = void;
    pub const touches = input_mod.Input.Modes{ .grips = false, .deferred = false, .edge_zones = false };
    a: *app.App,
    v: View,

    pub fn draw(vw: *Viewer, _: screen.Part) !void {
        try render(vw.a, vw.v);
    }

    /// A finger on the picture: a drag pans it; a tap on the close button closes it; a
    /// double tap shows it whole; a single tap goes a step closer, centred on it.
    pub fn onTap(vw: *Viewer, t: screen.Tap) !screen.Step(void) {
        const a = vw.a;
        const v = &vw.v;
        // A thumb resting where the Kindle is held isn't a tap
        if (touch_zones.isGrip(t.x, t.y, a.input.width, a.input.height)) return .stay;
        a.input.beginDrag();
        var follow = Follow{ .a = a, .v = v, .x0 = t.x, .y0 = t.y, .start_cx = v.cx, .start_cy = v.cy };
        _ = try app.followDrag(a, null, &follow);
        if (a.input.stashed != null) return .close; // Locked, or leaving
        if (follow.panned) return if (v.step > 0) .{ .redraw = .all } else .stay; // Its grays back
        // Closing on the lift, so a drag that starts by the button still pans
        if (onClose(t.x, t.y)) return .close;
        switch (afterTap(a, t.x, t.y)) {
            .quit => return .close,
            .double_tap => {
                if (v.step == 0) return .stay;
                v.whole();
            },
            .nothing, .other_tap => {
                if (v.step + 1 == steps.len) return .stay; // Already at the closest step
                const at = v.pictureAt(t.x, t.y);
                v.step += 1;
                v.cx = at.x;
                v.cy = at.y;
            },
        }
        v.clamp();
        std.debug.print("picture zoom {d}x\n", .{@as(u32, @intFromFloat(steps[v.step]))});
        return .{ .redraw = .all };
    }
};

/// Shows the picture until it's closed, then puts the page back as it was.
pub fn show(a: *app.App, img: book_model.Image) !void {
    var budget = memory.Budget{ .name = "picture", .child = std.heap.smp_allocator, .limit = 64 << 20 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer {
        arena.deinit();
        budget.report();
    }
    const saved = try arena.allocator().dupe(u8, a.screen.pixels);
    const picture = decode(arena.allocator(), img) orelse {
        try app.showNotice(a, "This picture can't be shown larger.");
        // The notice was drawn over the page: put the page back
        try a.present(saved, .page);
        return;
    };
    std.debug.print("picture: {d}x{d}\n", .{ picture.width, picture.height });
    const pw: f32 = @floatFromInt(picture.width);
    const ph: f32 = @floatFromInt(picture.height);
    var viewer = Viewer{ .a = a, .v = .{ .picture = picture, .cx = pw / 2, .cy = ph / 2, .fit = @min(style.screen_width / pw, style.screen_height / ph) } };
    _ = try screen.run(a, &viewer);
    try a.present(saved, .flash);
}

test "taps on and near the close button close" {
    try std.testing.expect(onClose(close_cx, close_cy));
    try std.testing.expect(onClose(close_cx - close_r - 20, close_cy));
    try std.testing.expect(!onClose(600, 800));
}

test "sizes too big to decode are refused without overflowing" {
    try std.testing.expect(decodable(2000, 3000));
    try std.testing.expect(!decodable(70000, 70000));
    try std.testing.expect(!decodable(0xffff_ffff, 0xffff_ffff));
    try std.testing.expect(!decodable(0, 10));
}
