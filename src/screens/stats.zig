//! Reading stats, opened from the library. Any tap goes back.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("../ui/style.zig");
const screen = @import("screen.zig");
const stats_ui = @import("../ui/stats.zig");
const catalog = @import("../model/catalog.zig");
const journal = @import("../model/journal.zig");
const app = @import("../app.zig");

const stats_ui_top = style.status_height; // Under the status strip, which stays

comptime {
    assert(stats_ui_top > 0);
    assert(stats_ui_top < style.screen_height);
}

/// What the screen shows, from the journal, the reading speed and the library.
pub fn summarize(a: *const app.App, entries: []const catalog.Entry) stats_ui.Summary {
    const j = &a.journal;
    const today = a.today();
    var s = stats_ui.Summary{
        .today = j.get(today).seconds,
        .week = j.seconds_over(today, 7),
        .streak = j.streak(today),
        .first_weekday = journal.weekday(today - 6),
    };
    // The week holds today, so it can't be less
    assert(s.week >= s.today);
    assert(s.first_weekday < 7);
    for (&s.last7, 0..) |*d, i| d.* = j.get(today - 6 + @as(i32, @intCast(i))).seconds;
    const year_start = journal.year_start(today);
    assert(year_start <= today);
    const year = j.since(year_start, today);
    const year_day = (std.time.epoch.EpochDay{ .day = @intCast(today) }).calculateYearDay();
    s.year = @intCast(year_day.year);
    if (a.speed.known()) s.wpm = @intFromFloat(@round(a.speed.wpm()));
    // The journal starts the day noface started keeping it, so the year also counts
    // what was known before: books marked read that were last opened this year (the
    // Kindle's own record), and each book's time read in noface. Whichever is more.
    var finished_this_year: u32 = 0;
    var seconds_this_year: u64 = 0;
    for (entries) |e| {
        s.books += 1;
        if (e.is_read()) s.finished += 1;
        if (e.in_progress()) s.in_progress += 1;
        if (e.last == 0 or journal.day_of(e.last, a.utc_offset) < year_start) continue;
        if (e.is_read()) finished_this_year += 1;
        seconds_this_year += e.seconds_read;
    }
    s.year_finished = @max(year.finished, finished_this_year);
    s.year_seconds = @max(year.seconds, seconds_this_year);
    // A book is read, in progress, or neither, never both
    assert(s.books == entries.len);
    assert(s.finished + s.in_progress <= s.books);
    assert(finished_this_year <= s.finished);
    return s;
}

/// Shows the stats over the library until a tap.
pub fn run(a: *app.App, entries: []const catalog.Entry) !void {
    var stats = Stats{ .a = a, .summary = summarize(a, entries) };
    assert(stats.summary.books == entries.len);
    assert(stats.summary.week >= stats.summary.today);
    _ = try screen.run(a, &stats);
}

const Stats = struct {
    pub const Result = void;
    a: *app.App,
    summary: stats_ui.Summary,

    pub fn draw(s: *Stats, _: screen.Part) !void {
        assert(s.summary.finished + s.summary.in_progress <= s.summary.books);
        assert(s.a.screen.height > stats_ui_top);
        try stats_ui.render(s.a.ui, s.a.page(s.a.screen.pixels), s.summary);
        try s.a.show_band(stats_ui_top, s.a.screen.height - stats_ui_top);
    }

    pub fn on_tap(_: *Stats, _: screen.Tap) !screen.Step(void) {
        return .close; // Any tap closes it
    }
};
