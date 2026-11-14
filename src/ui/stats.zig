//! The reading stats screen: today, this week and the streak as big numbers, the
//! last seven days as bars, then the year, reading speed and the library in rows.
const std = @import("std");
const assert = std.debug.assert;
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
    books: u32 = 0,
    finished: u32 = 0,
    in_progress: u32 = 0,
};

const header_top = style.status_height;
const back_height = 110; // The whole strip under the status bar takes you back
const title_y = header_top + back_height + 70;
const tiles_top = title_y + 60;
const tile_value_y = tiles_top + 116;
const tile_label_width = 330; // The gray behind a tile's label
const chart_title_y = tiles_top + 230;
const chart_top = chart_title_y + 40;
const chart_baseline = chart_top + 300;
const bar_room = chart_baseline - chart_top - 50; // Leaves space for a label above
const day_label_y = chart_baseline + 46;
const rows_top = day_label_y + 50;
const row_height = 112;
const row_count = 4;
const rows_bottom = rows_top + row_count * row_height;

const bar_width = 56; // Thin bars with air between, rounded at the top only
const bar_corner = style.bar_corner;

const day_letters = [_][]const u8{ "M", "T", "W", "T", "F", "S", "S" };

comptime {
    // Everything fits on the screen, top to bottom.
    assert(rows_bottom + 70 <= style.screen_height);
    assert(back_height >= 100); // Going back is a fingertip tall
    // Seven bars, each with air either side, rounded no more than half their width.
    assert(7 * bar_width < style.screen_width - 2 * style.margin);
    assert(2 * bar_corner <= bar_width);
    assert(bar_room >= 6); // The sliver that shows any reading at all
    // A letter for every day the chart shows.
    assert(day_letters.len == @typeInfo(@FieldType(Summary, "last7")).array.len);
    // The three tiles' labels sit side by side without overlapping.
    assert(3 * tile_label_width <= style.screen_width - 2 * style.margin);
}

pub fn is_back(y: i32) bool {
    return y >= header_top and y < header_top + back_height;
}

/// Minutes, to the nearest, in `seconds`.
fn nearest_minute(seconds: u64) u64 {
    const minutes = (seconds + 30) / 60;
    assert(minutes * 60 <= seconds + 30);
    assert(seconds + 30 < minutes * 60 + 60);
    return minutes;
}

/// Minutes to the nearest, as the bars count them, so the two agree; `none` under
/// half a minute.
fn minutes_text(buffer: []u8, seconds: u64, none: []const u8) []const u8 {
    assert(none.len > 0);
    if (seconds < 30) return none;
    const minutes = nearest_minute(seconds);
    assert(minutes > 0);
    return stats_model.format_minutes(buffer, minutes);
}

/// Bar height for `seconds` when the tallest day is `most`. Zero draws nothing; any
/// reading at all shows at least a sliver.
pub fn bar_height(seconds: u64, most: u64, room: u32) u32 {
    if (seconds == 0 or most == 0) return 0;
    assert(seconds <= most);
    const height = @max(@as(u32, @intCast(seconds * room / most)), 6);
    assert(height <= @max(room, 6));
    return height;
}

fn tile(fonts: Fonts, page: Page, x: f32, label: []const u8, value: []const u8) !void {
    assert(x >= style.margin);
    assert(label.len > 0);
    try fonts.caption.draw(page, x, tiles_top + 40, label);
    page.tint(@intFromFloat(x), tiles_top + 12, tile_label_width, 36, style.faded);
    try fonts.hero.draw(page, x, tile_value_y, value);
}

fn row(fonts: Fonts, page: Page, index: u32, label: []const u8, value: []const u8) !void {
    assert(index < row_count);
    assert(label.len > 0);
    const y = rows_top + index * row_height;
    page.fill_rect(style.margin, y, page.width - 2 * style.margin, 1, style.rule);
    try fonts.small.draw(page, style.margin, @intCast(y + 68), label);
    const right: f32 = @floatFromInt(page.width - style.margin);
    try fonts.small.draw(page, right - try fonts.small.measure(value), @intCast(y + 68), value);
}

pub fn render(fonts: Fonts, page: Page, s: Summary) !void {
    assert(page.height > rows_bottom);
    assert(page.width > 2 * style.margin);
    page.fill_rect(0, header_top, page.width, page.height - header_top, style.white);
    icons.back(page, style.margin + 18, header_top + 52);
    try fonts.small.draw(page, style.margin + 56, header_top + 64, "Library");
    try fonts.hero.draw(page, style.margin, title_y, "Reading");
    try render_tiles(fonts, page, &s);
    try render_chart(fonts, page, &s);
    try render_rows(fonts, page, &s);
}

/// Three headline numbers: today, the last seven days and the streak.
fn render_tiles(fonts: Fonts, page: Page, s: *const Summary) !void {
    const third: f32 = @floatFromInt((page.width - 2 * style.margin) / 3);
    assert(third >= tile_label_width);
    var today_buffer: [32]u8 = undefined;
    var week_buffer: [32]u8 = undefined;
    var streak_buffer: [32]u8 = undefined;
    const today = minutes_text(&today_buffer, s.today, "0 min");
    try tile(fonts, page, style.margin, "Today", today);
    const week = minutes_text(&week_buffer, s.week, "0 min");
    try tile(fonts, page, style.margin + third, "Last 7 days", week);
    const days = if (s.streak == 1) "" else "s";
    const streak = std.fmt.bufPrint(&streak_buffer, "{d} day{s}", .{ s.streak, days }) catch "";
    try tile(fonts, page, style.margin + 2 * third, "Streak", streak);
}

/// The last seven days, one bar each; today in black, the rest gray.
fn render_chart(fonts: Fonts, page: Page, s: *const Summary) !void {
    try fonts.small.draw(page, style.margin, chart_title_y, "Minutes read each day");
    var most: u64 = 0;
    var busiest: u32 = 0;
    for (s.last7, 0..) |seconds, day| {
        if (seconds > most) busiest = @intCast(day);
        most = @max(most, seconds);
    }
    assert(s.last7[busiest] == most);
    const width = page.width - 2 * style.margin;
    const slot: u32 = width / 7;
    page.fill_rect(style.margin, chart_baseline, width, 2, style.rule);
    if (most == 0) {
        // An empty week says so, rather than leaving a blank that looks broken
        const middle: f32 = @floatFromInt(page.width / 2);
        const empty = "No reading this week yet";
        const baseline: i32 = chart_top + bar_room / 2 + 40;
        try draw.centered(fonts.small, page, middle, baseline, empty);
        page.tint(style.margin, chart_top + bar_room / 2, width, 50, style.faded);
    }
    for (s.last7, 0..) |seconds, day| {
        const center_x: u32 = style.margin + @as(u32, @intCast(day)) * slot + slot / 2;
        const today = day == s.last7.len - 1;
        const height = bar_height(seconds, most, bar_room);
        if (height > 0) {
            try render_chart_bar(fonts, page, .{
                .center_x = center_x,
                .height = height,
                .seconds = seconds,
                .today = today,
                // Numbers only where they say something: today, and the busiest day
                .labelled = today or day == busiest,
            });
        }
        const letter = day_letters[(s.first_weekday + @as(u32, @intCast(day))) % 7];
        const letter_font = if (today) fonts.title else fonts.caption;
        try draw.centered(letter_font, page, @floatFromInt(center_x), day_label_y, letter);
    }
}

/// One day's bar in the chart.
const Bar = struct {
    center_x: u32,
    height: u32,
    seconds: u64,
    today: bool,
    labelled: bool, // With its minutes above it
};

fn render_chart_bar(fonts: Fonts, page: Page, bar: Bar) !void {
    assert(bar.height > 0);
    assert(bar.height <= bar_room);
    const shade: u8 = if (bar.today) 0x00 else 0x90;
    const top = chart_baseline - bar.height;
    const left = bar.center_x - bar_width / 2;
    const corner = @min(bar_corner, @as(f32, @floatFromInt(bar.height)) / 2);
    page.round_rect(left, top, bar_width, bar.height, corner, shade);
    // Square at the baseline: only the top corners are rounded
    if (bar.height > bar_corner) {
        page.fill_rect(left, chart_baseline - bar_corner, bar_width, bar_corner, shade);
    }
    if (bar.labelled) {
        var buffer: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d}", .{nearest_minute(bar.seconds)}) catch "";
        const center_x: f32 = @floatFromInt(bar.center_x);
        try draw.centered(fonts.caption, page, center_x, @intCast(top - 14), label);
    }
}

/// The year, speed and library, as rows.
fn render_rows(fonts: Fonts, page: Page, s: *const Summary) !void {
    // Each book counts once in the library, and once at most as read or as going.
    assert(s.finished <= s.books);
    assert(s.in_progress <= s.books);
    var year_buffer: [48]u8 = undefined;
    var finished_buffer: [48]u8 = undefined;
    var speed_buffer: [48]u8 = undefined;
    var library_buffer: [64]u8 = undefined;
    var minutes_buffer: [32]u8 = undefined;
    const year_label = std.fmt.bufPrint(&year_buffer, "Finished in {d}", .{s.year}) catch "";
    const plural = if (s.year_finished == 1) "" else "s";
    const finished_format = "{d} book{s}";
    const finished = std.fmt.bufPrint(&finished_buffer, finished_format, .{
        s.year_finished,
        plural,
    }) catch "";
    try row(fonts, page, 0, year_label, finished);
    const year_time = minutes_text(&minutes_buffer, s.year_seconds, "None yet");
    try row(fonts, page, 1, "Read in noface this year", year_time);
    var speed: []const u8 = "Still learning";
    if (s.wpm) |wpm| {
        speed = std.fmt.bufPrint(&speed_buffer, "{d} words a minute", .{wpm}) catch "";
    }
    try row(fonts, page, 2, "Reading speed", speed);
    const library = std.fmt.bufPrint(&library_buffer, "{d} books, {d} read, {d} going", .{
        s.books,
        s.finished,
        s.in_progress,
    }) catch "";
    try row(fonts, page, 3, "Library", library);
    const width = page.width - 2 * style.margin;
    page.fill_rect(style.margin, rows_bottom, width, 1, style.rule);
    const note = "Days and the streak count from when noface started its journal.";
    try fonts.caption.draw(page, style.margin, @intCast(rows_bottom + 56), note);
    page.tint(style.margin, rows_bottom + 26, width, 40, style.faded);
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
