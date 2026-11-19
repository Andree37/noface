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
/// The most the viewer takes of the book's region: the page underneath, and the
/// largest picture's grays with room to spare.
const viewer_bytes_max = 64 << 20;
/// Zoom steps after fitting the screen: twice, then four times as close.
const steps = [_]f32{ 1, 2, 4 };
/// The close button, top right, a fingertip across.
const close_radius = style.fingertip / 2;
const close_inset = 40; // From the screen's top and right edges
const close_center_x = style.screen_width - close_inset - close_radius;
const close_center_y = close_inset + close_radius;
/// How far from the button's centre a tap still closes: a fingertip around it.
const close_reach_extra = 30;
const close_reach = close_radius + close_reach_extra;
/// The cross in it: half each stroke's length across and down, and its thickness.
const close_arm = 16;
const close_stroke = 4;
/// The hint along the bottom: its box's top over the screen's foot, its height, its room
/// either side of the words, and their baseline down from its top.
const hint_rise = 120;
const hint_height = 64;
const hint_pad = 32;
const hint_baseline_drop = 42;
/// How long after a tap a second one makes it a double tap, and how near it must land.
const double_tap_us = 300 * 1000;
const double_tap_reach = 120;

comptime {
    // A picture worth decoding fits a 32-bit size, as the Kindle's usize is
    assert(pixels_max <= std.math.maxInt(u32));
    // The page underneath and the largest picture fit what the viewer may take
    assert(style.screen_width * style.screen_height + pixels_max < viewer_bytes_max);
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
    return ok;
}

fn decode(alloc: std.mem.Allocator, img: book_model.Image) ?image.Gray {
    if (!decodable(img.width, img.height)) return null;
    const g: image.Gray = if (jpegxr.is_jpeg_xr(img.data)) blk: {
        const x = jpegxr.decode_jpeg_xr(alloc, img.data, img.width, img.height) orelse return null;
        break :blk .{ .pixels = x.pixels, .width = x.width, .height = x.height };
    } else image.decode_gray_from(alloc, .{
        .bytes = img.data,
        .inflate_to = img.inflate_to,
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
    // Drawn in ordinary memory, then copied: the screen's own memory is slow to read
    // back, and dithering reads every pixel it writes
    const page = a.compose_whole();
    const t0 = os.now_us();
    const zoom = v.zoom();
    const width = a.screen.width;
    const height = a.screen.height;
    image.zoomed(v.picture, v.center_x, v.center_y, zoom, page, width, height, settled);
    if (settled) {
        const pixels = page.buf[0 .. a.screen.stride * a.screen.height];
        image.dither(a.alloc, pixels, a.screen.stride) catch {}; // Ignored: grays still show.
    } else {
        page.threshold(0, a.screen.height);
    }
    draw_view_close_button(page);
    // How it works, at the bottom, until the first zoom
    if (v.step == 0 and settled) try draw_view_hint(a, page);
    a.put_composed();
    std.debug.print("picture drawn in {d} ms\n", .{(os.now_us() - t0) / 1000});
    return a.screen.show(if (settled) .screen else .quick);
}

/// The close button: a white disc with a ring and a cross.
fn draw_view_close_button(page: Page) void {
    const arm: f32 = close_arm;
    const center_x: f32 = close_center_x;
    const center_y: f32 = close_center_y;
    comptime assert(arm < close_radius - style.border);
    page.disc(close_center_x, close_center_y, close_radius, 0, style.black);
    page.disc(close_center_x, close_center_y, close_radius - style.border, 0, style.white);
    page.stroke(center_x - arm, center_y - arm, center_x + arm, center_y + arm, close_stroke);
    page.stroke(center_x - arm, center_y + arm, center_x + arm, center_y - arm, close_stroke);
}

/// How to zoom, move and go back, in a box at the bottom of the screen.
fn draw_view_hint(a: *app.App, page: Page) !void {
    const hint = "Tap to zoom in  \u{b7}  double-tap to zoom out" ++
        "  \u{b7}  drag to move";
    const width: u32 = @intFromFloat(try a.ui.caption.measure(hint) + 2 * hint_pad);
    assert(width <= a.screen.width);
    const top = a.screen.height - hint_rise;
    assert(top < a.screen.height);
    draw.box(page, (a.screen.width - width) / 2, top, width, hint_height);
    const center_x: f32 = @floatFromInt(a.screen.width / 2);
    try draw.centered(a.ui.caption, page, center_x, @intCast(top + hint_baseline_drop), hint);
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

    fn moved(f: *Follow, x: i32, y: i32) !?u32 {
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

fn on_close(x: i32, y: i32) bool {
    const distance_x = x - close_center_x;
    const distance_y = y - close_center_y;
    return distance_x * distance_x + distance_y * distance_y <= close_reach * close_reach;
}

/// Starts showing `img` full screen in `viewer`, where it stays while it's open
/// (`screen.open`); null when it can't be decoded, said in a notice over the page.
/// Once it has ended, `ended` puts the page back as it was. The page underneath and
/// the picture's grays sit on top of the open book's memory, in its region, and are
/// let go of as the viewer closes: nothing else takes from that region while the
/// viewer is open, so what it took is the last there.
pub fn begin(viewer: *Viewer, a: *app.App, img: book_model.Image) !?screen.Frame {
    assert(a.book_region.kind == .bump);
    assert(!a.book_region.empty()); // The book the picture is in is open
    viewer.* = .{
        .a = a,
        .budget = .{ .name = "picture", .region = a.book_region, .limit = viewer_bytes_max },
        .book_end = a.book_region.end,
        .start = undefined,
        .saved = &.{},
        .v = undefined,
    };
    viewer.start = viewer.budget.mark();
    errdefer viewer.release();
    const alloc = viewer.budget.allocator();
    viewer.saved = try alloc.dupe(u8, a.screen.pixels);
    const picture = decode(alloc, img) orelse {
        try app.show_notice(a, "This picture can't be shown larger.");
        // The notice was drawn over the page: put the page back
        try a.present(viewer.saved, .page);
        viewer.release();
        return null;
    };
    // Checked as it was decoded: what follows divides by its size
    assert(decodable(picture.width, picture.height));
    std.debug.print("picture: {d}x{d}\n", .{ picture.width, picture.height });
    const picture_width: f32 = @floatFromInt(picture.width);
    const picture_height: f32 = @floatFromInt(picture.height);
    const fit = @min(style.screen_width / picture_width, style.screen_height / picture_height);
    assert(fit > 0);
    viewer.v = .{
        .picture = picture,
        .center_x = picture_width / 2,
        .center_y = picture_height / 2,
        .fit = fit,
    };
    return screen.open(viewer, &viewer.ending);
}

/// The viewer closed: the page back as it was, and its memory let go of.
pub fn ended(viewer: *Viewer) !void {
    assert(viewer.ending != null);
    assert(viewer.saved.len == viewer.a.screen.pixels.len);
    defer viewer.release();
    try viewer.a.present(viewer.saved, .flash);
}

/// The picture, full screen, until it's closed. Touches come at once, so a drag can
/// follow them; edge zones would hold back taps near the top, so they're off, and a
/// resting thumb is skipped in `on_tap` instead. A finger on it is followed to its
/// lift: a drag pans it; a tap on the close button closes it; a double tap shows it
/// whole; a single tap goes a step closer, centred on it.
pub const Viewer = struct {
    pub const Result = void;
    a: *app.App,
    budget: memory.Budget, // On top of the book's memory, in its region
    book_end: u32, // Where the book's memory ended as the viewer opened
    start: memory.Budget.Mark, // Where the viewer's own memory began
    saved: []u8, // The page under it
    v: View,
    phase: Phase = .idle,
    ending: ?screen.Ending(void) = null,

    /// Waiting for a finger; following one (with the last update made following it);
    /// waiting the double tap's moment for a second tap; following the second tap's
    /// finger to its lift (with whether it's stayed put). Each but the first with the
    /// tap a second one may make a double tap of.
    const Phase = union(enum) {
        idle,
        following: struct { first: input_mod.Tap, follow: Follow, marker: ?u32 = null },
        waiting: input_mod.Tap,
        second: struct { first: input_mod.Tap, still: bool = true },
    };

    const touches = input_mod.Input.Modes{ .grips = false, .deferred = false, .edge_zones = false };

    pub fn draw(viewer: *Viewer, _: screen.Part) !void {
        assert(viewer.v.step < steps.len);
        assert(viewer.v.fit > 0);
        try render(viewer.a, &viewer.v);
    }

    /// Ticks only for the double tap's moment, which ends with the tick.
    pub fn setting(viewer: *const Viewer) input_mod.Input.Scope {
        assert(viewer.v.step < steps.len);
        const tick_us: ?u64 = if (viewer.phase == .waiting) double_tap_us else null;
        return .{ .modes = touches, .tick_us = tick_us };
    }

    pub fn on_tap(viewer: *Viewer, t: screen.Tap) !screen.Step(void) {
        assert(viewer.v.step < steps.len);
        assert(viewer.saved.len == viewer.a.screen.pixels.len);
        return switch (viewer.phase) {
            .idle => viewer.touched(t),
            // Another finger while one is followed: as before, the viewer closes
            .following, .second => .close,
            .waiting => viewer.second_tap(t),
        };
    }

    pub fn on_tick(viewer: *Viewer) !screen.Step(void) {
        assert(viewer.v.step < steps.len);
        assert(viewer.v.fit > 0);
        const first = switch (viewer.phase) {
            .waiting => |first| first,
            .idle, .following, .second => return .stay,
        };
        // No second tap in time
        viewer.phase = .idle;
        return viewer.zoom_in(first);
    }

    pub fn on_action(viewer: *Viewer, action: input_mod.Action) !screen.Step(void) {
        assert(viewer.v.step < steps.len);
        assert(viewer.v.fit > 0);
        switch (viewer.phase) {
            .idle, .waiting => return .stay,
            .following => |*f| switch (action) {
                .drag => |dragged| {
                    const a = viewer.a;
                    if (f.marker) |m| try a.screen.wait_complete(m);
                    const at = a.input.latest_drag() orelse dragged;
                    f.marker = try f.follow.moved(at.x, at.y);
                    return .stay;
                },
                .drag_end => return viewer.lifted(),
                // Only the finger followed moves the picture
                .tap, .hold, .pull, .swipe, .tick, .charger => return .stay,
                .lock, .unlock, .power, .computer, .stop => return .stay,
            },
            .second => |*second| switch (action) {
                .drag => |at| {
                    const t = second.first;
                    if (touch_zones.moved_off(t.x, t.y, at.x, at.y)) second.still = false;
                    return .stay;
                },
                // A double tap if it stayed put, else a drag after all
                .drag_end => {
                    const lifted_second = second.*;
                    viewer.phase = .idle;
                    if (!lifted_second.still) return viewer.zoom_in(lifted_second.first);
                    if (viewer.v.step == 0) return .stay;
                    viewer.v.whole();
                    return viewer.zoomed();
                },
                // Only the second touch's finger decides
                .tap, .hold, .pull, .swipe, .tick, .charger => return .stay,
                .lock, .unlock, .power, .computer, .stop => return .stay,
            },
        }
    }

    /// A finger touched: it's followed to its lift.
    fn touched(viewer: *Viewer, t: screen.Tap) screen.Step(void) {
        const a = viewer.a;
        const v = &viewer.v;
        assert(viewer.phase == .idle);
        // A thumb resting where the Kindle is held isn't a tap
        if (touch_zones.is_grip(t.x, t.y, a.input.width, a.input.height)) return .stay;
        a.input.begin_drag();
        viewer.phase = .{ .following = .{ .first = t, .follow = .{
            .a = a,
            .v = v,
            .start_x = t.x,
            .start_y = t.y,
            .start_center_x = v.center_x,
            .start_center_y = v.center_y,
        } } };
        return .stay;
    }

    /// The finger lifted: a pan's grays back, the close button, or the double tap's
    /// moment to wait.
    fn lifted(viewer: *Viewer) !screen.Step(void) {
        const f = viewer.phase.following;
        assert(f.follow.v == &viewer.v); // It moves this viewer's picture
        const a = viewer.a;
        if (f.marker) |m| try a.screen.wait_complete(m);
        viewer.phase = .idle;
        // Its grays back
        if (f.follow.panned) return if (viewer.v.step > 0) .{ .redraw = .all } else .stay;
        // Closing on the lift, so a drag that starts by the button still pans
        if (on_close(f.first.x, f.first.y)) return .close;
        viewer.phase = .{ .waiting = f.first };
        a.input.last_tick = os.now_us(); // The moment counts from the lift
        return .stay;
    }

    /// A tap within the double tap's moment: near the first, its finger is followed to
    /// its lift; elsewhere, the first zooms in and this one is a tap of its own.
    fn second_tap(viewer: *Viewer, t: screen.Tap) !screen.Step(void) {
        const first = viewer.phase.waiting;
        const near_x = @abs(t.x - first.x) <= double_tap_reach;
        const near_y = @abs(t.y - first.y) <= double_tap_reach;
        if (near_x and near_y) {
            viewer.a.input.begin_drag();
            viewer.phase = .{ .second = .{ .first = first } };
            return .stay;
        }
        viewer.phase = .idle;
        const step = viewer.zoom_in(first);
        if (step == .redraw) try viewer.draw(.all);
        return viewer.touched(t);
    }

    /// A step closer, centred where `t` was.
    fn zoom_in(viewer: *Viewer, t: screen.Tap) screen.Step(void) {
        const v = &viewer.v;
        assert(viewer.phase == .idle);
        assert(v.step < steps.len);
        if (v.step + 1 == steps.len) return .stay; // Already at the closest step
        const at = v.picture_at(t.x, t.y);
        v.step += 1;
        v.center_x = at.x;
        v.center_y = at.y;
        return viewer.zoomed();
    }

    fn zoomed(viewer: *Viewer) screen.Step(void) {
        const v = &viewer.v;
        v.clamp();
        assert(v.step < steps.len);
        assert(v.fit > 0);
        std.debug.print("picture zoom {d}x\n", .{@as(u32, @intFromFloat(steps[v.step]))});
        return .{ .redraw = .all };
    }

    fn release(viewer: *Viewer) void {
        const region = viewer.a.book_region;
        assert(viewer.budget.live <= viewer.budget.limit);
        viewer.budget.report();
        viewer.budget.rewind(viewer.start);
        region.give_back_past_end();
        assert(region.end == viewer.book_end); // The book's memory as it was
    }
};

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
