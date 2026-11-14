//! The reading stats screen: today, this week and the streak as big numbers, the
//! last seven days as bars, then the year, reading speed and the library in rows.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const icons = @import("icons.zig");
const stats_model = @import("../model/stats.zig");
const Fonts = @import("fonts.zig").Fonts;

/// Everything the screen shows, worked out by the caller.
pub const Summary = struct {
    today: u64, // Seconds
    week: u64, // Seconds, the last seven days
    streak: u32, // Days
    last7: [7]u64 = @splat(0), // Seconds per day, oldest first, today last
    first_weekday: u32 = 0, // Of last7[0], 0 for Monday
    year: i32 = 0,
    year_finished: u32 = 0,
    year_seconds: u64 = 0,
    wpm: ?u32 = null, // Null while the speed is still being learned
    books: usize = 0,
    finished: usize = 0,
    in_progress: usize = 0,
};

const header_top = style.status_height;
const back_height = 110; // The whole strip under the status bar takes you back
const title_y = header_top + back_height + 70;
const tiles_top = title_y + 60;
const tile_value_y = tiles_top + 116;
const chart_title_y = tiles_top + 230;
const chart_top = chart_title_y + 40;
const chart_baseline = chart_top + 300;
const day_label_y = chart_baseline + 46;
const rows_top = day_label_y + 50;
const row_height = 112;

const bar_width = 56; // Thin bars with air between, rounded at the top only
const bar_corner = style.bar_corner;

pub fn is_back(y: i32) bool {
    return y >= header_top and y < header_top + back_height;
}

/// Bar height for `seconds` when the tallest day is `most`. Zero draws nothing; any
/// reading at all shows at least a sliver.
fn nearest_minute(seconds: u64) u64 {
    return (seconds + 30) / 60;
}

pub fn bar_height(seconds: u64, most: u64, room: u32) u32 {
    if (seconds == 0 or most == 0) return 0;
    return @max(@as(u32, @intCast(seconds * room / most)), 6);
}

fn tile(fonts: Fonts, page: Page, x: f32, label: []const u8, value: []const u8) !void {
    try fonts.caption.draw(page, x, tiles_top + 40, label);
    page.tint(@intFromFloat(x), tiles_top + 12, 330, 36, style.faded);
    try fonts.hero.draw(page, x, tile_value_y, value);
}

fn row(fonts: Fonts, page: Page, index: u32, label: []const u8, value: []const u8) !void {
    const y = rows_top + index * row_height;
    page.fill_rect(style.margin, y, page.width - 2 * style.margin, 1, style.rule);
    try fonts.small.draw(page, style.margin, @intCast(y + 68), label);
    const right: f32 = @floatFromInt(page.width - style.margin);
    try fonts.small.draw(page, right - try fonts.small.measure(value), @intCast(y + 68), value);
}

const day_letters = [_][]const u8{ "M", "T", "W", "T", "F", "S", "S" };

pub fn render(fonts: Fonts, page: Page, s: Summary) !void {
    page.fill_rect(0, header_top, page.width, page.height - header_top, style.white);
    icons.back(page, style.margin + 18, header_top + 52);
    try fonts.small.draw(page, style.margin + 56, header_top + 64, "Library");
    try fonts.hero.draw(page, style.margin, title_y, "Reading");

    // Three headline numbers
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    const third: f32 = @floatFromInt((page.width - 2 * style.margin) / 3);
    // Minutes to the nearest, as the bars below count them, so the two agree
    try tile(fonts, page, style.margin, "Today", if (s.today >= 30) stats_model.format_minutes(&b1, nearest_minute(s.today)) else "0 min");
    try tile(fonts, page, style.margin + third, "Last 7 days", if (s.week >= 30) stats_model.format_minutes(&b2, nearest_minute(s.week)) else "0 min");
    const streak = std.fmt.bufPrint(&b3, "{d} day{s}", .{ s.streak, if (s.streak == 1) "" else "s" }) catch "";
    try tile(fonts, page, style.margin + 2 * third, "Streak", streak);

    // The last seven days, one bar each; today in black, the rest gray
    try fonts.small.draw(page, style.margin, chart_title_y, "Minutes read each day");
    var most: u64 = 0;
    var busiest: usize = 0;
    for (s.last7, 0..) |d, i| {
        if (d > most) busiest = i;
        most = @max(most, d);
    }
    const slot: u32 = (page.width - 2 * style.margin) / 7;
    const room: u32 = chart_baseline - chart_top - 50; // Leaves space for a label above
    page.fill_rect(style.margin, chart_baseline, page.width - 2 * style.margin, 2, style.rule);
    if (most == 0) {
        // An empty week says so, rather than leaving a blank that looks broken
        try draw.centered(fonts.small, page, @floatFromInt(page.width / 2), @intCast(chart_top + room / 2 + 40), "No reading this week yet");
        page.tint(style.margin, chart_top + room / 2, page.width - 2 * style.margin, 50, style.faded);
    }
    for (s.last7, 0..) |d, i| {
        const cx: u32 = style.margin + @as(u32, @intCast(i)) * slot + slot / 2;
        const h = bar_height(d, most, room);
        const today = i == s.last7.len - 1;
        if (h > 0) {
            const shade: u8 = if (today) 0x00 else 0x90;
            const top = chart_baseline - h;
            page.round_rect(cx - bar_width / 2, top, bar_width, h, @min(bar_corner, @as(f32, @floatFromInt(h)) / 2), shade);
            // Square at the baseline: only the top corners are rounded
            if (h > bar_corner) page.fill_rect(cx - bar_width / 2, chart_baseline - bar_corner, bar_width, bar_corner, shade);
            // Numbers only where they say something: today, and the busiest day
            if (today or i == busiest) {
                var lb: [16]u8 = undefined;
                const label = std.fmt.bufPrint(&lb, "{d}", .{nearest_minute(d)}) catch "";
                try draw.centered(fonts.caption, page, @floatFromInt(cx), @intCast(top - 14), label);
            }
        }
        const letter = day_letters[(s.first_weekday + @as(u32, @intCast(i))) % 7];
        try draw.centered(if (today) fonts.title else fonts.caption, page, @floatFromInt(cx), day_label_y, letter);
    }

    // The year, speed and library, as rows
    var r1: [48]u8 = undefined;
    var r2: [48]u8 = undefined;
    var r3: [48]u8 = undefined;
    var r4: [64]u8 = undefined;
    var t: [32]u8 = undefined;
    const year_label = std.fmt.bufPrint(&r1, "Finished in {d}", .{s.year}) catch "";
    const finished = std.fmt.bufPrint(&r2, "{d} book{s}", .{ s.year_finished, if (s.year_finished == 1) "" else "s" }) catch "";
    try row(fonts, page, 0, year_label, finished);
    try row(fonts, page, 1, "Read in noface this year", if (s.year_seconds >= 30) stats_model.format_minutes(&t, nearest_minute(s.year_seconds)) else "None yet");
    const speed = if (s.wpm) |w| std.fmt.bufPrint(&r3, "{d} words a minute", .{w}) catch "" else "Still learning";
    try row(fonts, page, 2, "Reading speed", speed);
    const library = std.fmt.bufPrint(&r4, "{d} books, {d} read, {d} going", .{ s.books, s.finished, s.in_progress }) catch "";
    try row(fonts, page, 3, "Library", library);
    page.fill_rect(style.margin, rows_top + 4 * row_height, page.width - 2 * style.margin, 1, style.rule);
    try fonts.caption.draw(page, style.margin, @intCast(rows_top + 4 * row_height + 56), "Days and the streak count from when noface started its journal.");
    page.tint(style.margin, rows_top + 4 * row_height + 26, page.width - 2 * style.margin, 40, style.faded);
}

test "tiles and bars count minutes the same way" {
    try std.testing.expectEqual(@as(u64, 2), nearest_minute(100)); // 1 min 40 s
    try std.testing.expectEqual(@as(u64, 1), nearest_minute(89));
}

test "bars scale to the busiest day, and any reading shows" {
    try std.testing.expectEqual(@as(u32, 0), bar_height(0, 600, 250));
    try std.testing.expectEqual(@as(u32, 250), bar_height(600, 600, 250));
    try std.testing.expectEqual(@as(u32, 125), bar_height(300, 600, 250));
    try std.testing.expectEqual(@as(u32, 6), bar_height(1, 6000, 250));
}

test "the screen fits, and going back is a fingertip tall" {
    try std.testing.expect(rows_top + 4 * row_height + 70 <= style.screen_height);
    try std.testing.expect(back_height >= 100);
    try std.testing.expect(is_back(header_top + 50));
    try std.testing.expect(!is_back(header_top + back_height + 10));
}
