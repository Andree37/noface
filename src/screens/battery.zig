//! Tapping the battery in the library: a small bubble under it saying how long the
//! charge will last at the way the Kindle has been used lately. Any tap closes it.
const std = @import("std");
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

pub const Lines = struct { title: []const u8, detail: []const u8 };

/// What the bubble says, from the log, the battery now, and recent reading per day.
pub fn lines(buf: []u8, log: []const battery.Sample, now: ?battery.Sample, read_per_day_s: u64) Lines {
    const n = now orelse return .{ .title = "Battery", .detail = "Its level can't be read right now." };
    if (n.plugged) return .{ .title = "Plugged in", .detail = "How long it lasts shows once it's unplugged." };
    const left_s = battery.seconds_left(log, n.time, n.level) orelse
        return .{ .title = "Still learning", .detail = "A day or two unplugged, and this shows how long it lasts." };
    var time_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(buf[0..64], "{s} left", .{battery.describe(&time_buf, left_s)}) catch "";
    var read_buf: [32]u8 = undefined;
    const detail = if (stats.reading_time(&read_buf, read_per_day_s)) |r|
        std.fmt.bufPrint(buf[64..], "Reading about {s} a day, as lately", .{r}) catch ""
    else
        "At the way it's been used lately";
    return .{ .title = title, .detail = detail };
}

pub fn show(a: *app.App) !void {
    var samples: [2048]battery.Sample = undefined;
    const log = battery_log.load(a.battery_path, &samples);
    const per_day = a.journal.seconds_over(a.today(), usual_days) / usual_days;
    var buf: [160]u8 = undefined;
    const said = lines(&buf, log, battery_log.now(), per_day);
    std.debug.print("battery: {s} ({d} samples)\n", .{ said.title, log.len });

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
        const a = b.a;
        const page = a.page(a.screen.pixels);
        draw_ui.box(page, left, top, width, height);
        const x: f32 = left + 36;
        const avail: f32 = width - 72;
        try draw_ui.clipped(a.ui.title, page, x, top + 72, b.said.title, avail);
        try draw_ui.clipped(a.ui.caption, page, x, top + 128, b.said.detail, avail);
        page.tint(left + 36, top + 96, width - 72, 44, style.faded);
        try a.show_rect(left, top, width, height);
    }

    pub fn on_tap(_: *Bubble, _: screen.Tap) !screen.Step(void) {
        return .close;
    }
};

test "the bubble says what it knows" {
    var buf: [160]u8 = undefined;
    const d = 86400;
    const t = 1_790_000_000;
    const log = [_]battery.Sample{
        .{ .time = t, .level = 100, .plugged = false },
        .{ .time = t + 2 * d, .level = 90, .plugged = false }, // 5% a day
    };
    const now = battery.Sample{ .time = t + 2 * d, .level = 90, .plugged = false };
    const said = lines(&buf, &log, now, 70 * 60);
    try std.testing.expectEqualStrings("About 3 weeks left", said.title); // 18 days
    try std.testing.expectEqualStrings("Reading about 1 h 10 min a day, as lately", said.detail);
    try std.testing.expectEqualStrings("Still learning", lines(&buf, log[0..1], now, 0).title);
    var plugged = now;
    plugged.plugged = true;
    try std.testing.expectEqualStrings("Plugged in", lines(&buf, &log, plugged, 0).title);
}
