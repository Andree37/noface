//! Reading stats, opened from the library. Any tap goes back.
const std = @import("std");
const assert = std.debug.assert;
const style = @import("../ui/style.zig");
const screen = @import("screen.zig");
const stats_ui = @import("../ui/stats.zig");
const books = @import("books.zig");
const journal = @import("../model/journal.zig");
const app = @import("../app.zig");
const input_mod = @import("../kindle/input.zig");

const stats_ui_top = style.status_height; // Under the status strip, which stays

comptime {
    assert(stats_ui_top > 0);
    assert(stats_ui_top < style.screen_height);
}

/// What the screen shows, from the journal, the reading speed and the library.
fn summarize(a: *const app.App, library: *books.Library) stats_ui.Summary {
    const j = &a.user.journal;
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
    if (a.user.speed.known()) s.wpm = @intFromFloat(@round(a.user.speed.wpm()));
    // The journal starts the day noface started keeping it, so the year also counts
    // what was known before: books marked read that were last opened this year (the
    // Kindle's own record), and each book's time read in noface. Whichever is more.
    const totals = library.totals(year_start, a.utc_offset);
    s.books = totals.books;
    s.finished = totals.finished;
    s.in_progress = totals.in_progress;
    s.year_finished = @max(year.finished, totals.finished_this_year);
    s.year_seconds = @max(year.seconds, totals.seconds_this_year);
    // A book is read, in progress, or neither, never both
    assert(s.finished + s.in_progress <= s.books);
    assert(totals.finished_this_year <= s.finished);
    return s;
}

/// The stats, to show over the library until a tap.
pub fn make(a: *app.App, library: *books.Library) Stats {
    const stats = Stats{ .a = a, .summary = summarize(a, library) };
    assert(stats.summary.books >= stats.summary.finished);
    assert(stats.summary.week >= stats.summary.today);
    return stats;
}

pub const Stats = struct {
    pub const Result = void;
    /// A tap closes it as it lands: held a little long, it would be a hold, which it
    /// would keep waiting through.
    pub const touches = input_mod.Input.Modes.sheet;
    a: *app.App,
    summary: stats_ui.Summary,

    pub fn draw(s: *Stats, _: screen.Part) !void {
        assert(s.summary.finished + s.summary.in_progress <= s.summary.books);
        assert(s.a.display.screen.height > stats_ui_top);
        try stats_ui.render(s.a.ui, s.a.display.on_screen(), s.summary);
        try s.a.display.show_band(stats_ui_top, s.a.display.screen.height - stats_ui_top);
    }

    pub fn on_tap(_: *Stats, _: screen.Tap) !screen.Step(void) {
        return .close; // Any tap closes it
    }
};
