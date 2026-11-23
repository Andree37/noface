//! Tapping the battery in the library: a small bubble under it saying how long the
//! charge will last at the way the Kindle has been used lately. Any tap closes it.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../text/line.zig").of;
const battery = @import("../model/battery.zig");
const battery_log = @import("../kindle/battery_log.zig");
const stats = @import("../model/stats.zig");
const draw_ui = @import("../ui/draw.zig");
const screen = @import("screen.zig");
const style = @import("../ui/style.zig");
const app = @import("../app.zig");
const display = @import("../display.zig");
const input_mod = @import("../kindle/input.zig");

const width = style.screen_width / 2;
const height = style.space.wide + style.space.tall;
const top_gap = style.space.hair; // Under the status row
const top = style.status_height + top_gap;
const left = style.screen_width - style.margin - width;
/// Days of reading averaged for "your usual".
const usual_days = 14;
/// The part of `lines`' buffer the title is written into, and the detail's after it.
const title_size = 64;
const detail_size = 96;
/// What `lines` writes into: room for both.
const lines_size = title_size + detail_size;
/// The text inside the bubble: this far in from either side.
const text_inset = style.space.roomy;
/// The title's and the faded detail's baselines, down from the bubble's top.
const title_drop = style.space.wider;
const detail_drop = style.space.tall;

comptime {
    // The bubble sits by the battery: inside the margin on the right, under the status row
    assert(left >= style.margin);
    assert(left + width + style.margin == style.screen_width);
    assert(top >= style.status_height);
    assert(top + height <= style.screen_height);
    assert(2 * text_inset < width);
}

const Lines = struct { title: []const u8, detail: []const u8 };

/// What the bubble says, from the log, the battery now, and recent reading per day.
fn lines(
    buffer: *[lines_size]u8,
    log: []const battery.Sample,
    now: ?battery.Sample,
    read_per_day_s: u64,
) Lines {
    comptime assert(lines_size > title_size);
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
    const title = line_of(buffer[0..title_size], "{s} left", .{time_left});
    // The time takes at most its 32 bytes, so the title always fits
    assert(title.len > 0);
    var read_buffer: stats.Minutes = undefined;
    const reading = stats.reading_time(&read_buffer, read_per_day_s) orelse return .{
        .title = title,
        .detail = "At the way it's been used lately",
    };
    const detail = line_of(
        buffer[title_size..],
        "Reading about {s} a day, as lately",
        .{reading},
    );
    // The reading time takes at most its 32 bytes too, so the detail always fits
    assert(detail.len > 0);
    return .{ .title = title, .detail = detail };
}

/// Makes the bubble in place, its lines in its own buffer; `put_back` puts what was
/// under it back once it closes.
pub fn open(a: *app.App, bubble: *Bubble) void {
    var samples: [2048]battery.Sample = undefined;
    const log = battery_log.load(a.battery_path, &samples);
    assert(log.len <= samples.len);
    const per_day = a.user.journal.seconds_over(a.today(), usual_days) / usual_days;
    bubble.a = a;
    bubble.said = lines(&bubble.buffer, log, battery_log.now(), per_day);
    assert(bubble.said.title.len > 0);
    assert(bubble.said.detail.len > 0);
    std.debug.print("battery: {s} ({d} samples)\n", .{ bubble.said.title, log.len });
}

/// The library as it was under the bubble, `under`, back on the screen.
pub fn put_back(a: *app.App, under: display.Backdrop) !void {
    assert(left + width <= a.display.screen.width);
    a.display.put_back(under);
    try a.display.show_rect(left, top, width, height);
}

/// The estimate, in a bubble by the battery. Any tap closes it.
pub const Bubble = struct {
    pub const Result = void;
    /// A tap closes it as it lands: held a little long, it would be a hold, which it
    /// would keep waiting through.
    pub const touches = input_mod.Input.Modes.sheet;
    a: *app.App,
    said: Lines, // In `buffer`, so the bubble stays where `open` made it
    buffer: [lines_size]u8,

    pub fn draw(b: *Bubble, _: screen.Part) !void {
        assert(b.said.title.len > 0);
        assert(b.said.detail.len > 0);
        const a = b.a;
        const page = a.display.on_screen();
        draw_ui.box(page, left, top, width, height);
        const x: f32 = left + text_inset;
        const width_available: f32 = width - 2 * text_inset;
        const title_y = top + title_drop;
        try draw_ui.clipped(a.ui.title, page, x, title_y, b.said.title, width_available);
        const detail_y = top + detail_drop;
        try draw_ui.clipped(a.ui.caption, page, x, detail_y, b.said.detail, width_available);
        const tint_width = width - 2 * text_inset;
        a.ui.caption.fade(page, left + text_inset, detail_y, tint_width, style.faded);
        try a.display.show_rect(left, top, width, height);
    }

    pub fn on_tap(_: *Bubble, _: screen.Tap) !screen.Step(void) {
        return .close;
    }
};

test "the bubble says what it knows" {
    var buffer: [lines_size]u8 = undefined;
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
