//! Tapping the battery in the library: a small bubble under it saying how long the
//! charge will last at the way the Kindle has been used lately. Any tap closes it.
const std = @import("std");
const assert = std.debug.assert;
const battery = @import("../model/battery.zig");
const battery_log = @import("../kindle/battery_log.zig");
const stats = @import("../model/stats.zig");
const draw_ui = @import("../ui/draw.zig");
const screen = @import("screen.zig");
const style = @import("../ui/style.zig");
const app = @import("../app.zig");

const width = 640;
const height = 176;
const top = 100; // Just under the status row
const left = style.screen_width - style.margin - width;
/// Days of reading averaged for "your usual".
const usual_days = 14;
/// The part of `lines`' buffer the title is written into; the detail gets the rest.
const title_size = 64;
/// The text inside the bubble: this far in from either side.
const text_inset = 36;

comptime {
    // The bubble sits by the battery: inside the margin on the right, under the status row
    assert(left >= style.margin);
    assert(left + width + style.margin == style.screen_width);
    assert(top >= style.status_height);
    assert(top + height <= style.screen_height);
    assert(2 * text_inset < width);
}

pub const Lines = struct { title: []const u8, detail: []const u8 };

/// What the bubble says, from the log, the battery now, and recent reading per day.
pub fn lines(
    buffer: []u8,
    log: []const battery.Sample,
    now: ?battery.Sample,
    read_per_day_s: u64,
) Lines {
    assert(buffer.len > title_size);
    const n = now orelse return .{
        .title = "Battery",
        .detail = "Its level can't be read right now.",
    };
    if (n.plugged) {
        return .{ .title = "Plugged in", .detail = "How long it lasts shows once it's unplugged." };
    }
    const left_s = battery.seconds_left(log, n.time, n.level) orelse return .{
        .title = "Still learning",
        .detail = "A day or two unplugged, and this shows how long it lasts.",
    };
    var time_buffer: [32]u8 = undefined;
    const time_left = battery.describe(&time_buffer, left_s);
    const title = std.fmt.bufPrint(buffer[0..title_size], "{s} left", .{time_left}) catch "";
    // The time takes at most its 32 bytes, so the title always fits
    assert(title.len > 0);
    var read_buffer: [32]u8 = undefined;
    const reading = stats.reading_time(&read_buffer, read_per_day_s) orelse return .{
        .title = title,
        .detail = "At the way it's been used lately",
    };
    const detail = std.fmt.bufPrint(
        buffer[title_size..],
        "Reading about {s} a day, as lately",
        .{reading},
    ) catch "";
    // The reading time takes at most its 32 bytes too, so the detail always fits
    assert(detail.len > 0);
    return .{ .title = title, .detail = detail };
}

pub fn show(a: *app.App) !void {
    var samples: [2048]battery.Sample = undefined;
    const log = battery_log.load(a.battery_path, &samples);
    assert(log.len <= samples.len);
    const per_day = a.journal.seconds_over(a.today(), usual_days) / usual_days;
    var buffer: [160]u8 = undefined;
    const said = lines(&buffer, log, battery_log.now(), per_day);
    assert(said.title.len > 0);
    assert(said.detail.len > 0);
    std.debug.print("battery: {s} ({d} samples)\n", .{ said.title, log.len });

    assert(a.overlay.len == a.screen.pixels.len);
    @memcpy(a.overlay, a.screen.pixels); // The library under it, put back after
    var bubble = Bubble{ .a = a, .said = said };
    _ = try screen.run(a, &bubble);
    @memcpy(a.screen.pixels, a.overlay);
    try a.show_rect(left, top, width, height);
}

/// The estimate, in a bubble by the battery. Any tap closes it.
const Bubble = struct {
    pub const Result = void;
    a: *app.App,
    said: Lines,

    pub fn draw(b: *Bubble, _: screen.Part) !void {
        assert(b.said.title.len > 0);
        assert(b.said.detail.len > 0);
        const a = b.a;
        const page = a.page(a.screen.pixels);
        draw_ui.box(page, left, top, width, height);
        const x: f32 = left + text_inset;
        const width_available: f32 = width - 2 * text_inset;
        try draw_ui.clipped(a.ui.title, page, x, top + 72, b.said.title, width_available);
        try draw_ui.clipped(a.ui.caption, page, x, top + 128, b.said.detail, width_available);
        page.tint(left + text_inset, top + 96, width - 2 * text_inset, 44, style.faded);
        try a.show_rect(left, top, width, height);
    }

    pub fn on_tap(_: *Bubble, _: screen.Tap) !screen.Step(void) {
        return .close;
    }
};

test "the bubble says what it knows" {
    var buffer: [160]u8 = undefined;
    const d = 86400;
    const t = 1_790_000_000;
    const log = [_]battery.Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + 2 * d, .level = 90, .plugged = false }, // 5% a day
    };
    const now = battery.Sample{ .time = t + 2 * d, .level = 90, .plugged = false };
    const said = lines(&buffer, &log, now, 70 * 60);
    try std.testing.expectEqualStrings("About 3 weeks left", said.title); // 18 days
    try std.testing.expectEqualStrings("Reading about 1 h 10 min a day, as lately", said.detail);
    try std.testing.expectEqualStrings("Still learning", lines(&buffer, log[0..1], now, 0).title);
    var plugged = now;
    plugged.plugged = true;
    try std.testing.expectEqualStrings("Plugged in", lines(&buffer, &log, plugged, 0).title);
}
