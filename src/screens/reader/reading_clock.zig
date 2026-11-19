//! The reading clock: time on the page in front of the reader, and in the book. It
//! stops while something covers the page or the Kindle sleeps, and time on a page adds
//! up across those, so a page read in two sittings counts as one page read in the time
//! of both. The session says when the reader leaves a page, and where its time goes.
const std = @import("std");
const assert = std.debug.assert;
const stats = @import("../../model/stats.zig");

pub const Clock = struct {
    /// When the clock last started on this page; null while it's stopped.
    shown_us: ?u64 = null,
    /// Time on the current page before `shown_us`.
    page_us: u64 = 0,
    /// Time spent in this book on pages left, saved with the position.
    seconds_read: u64 = 0,

    /// What leaving a page took from the clock: its time, all of it and as counted.
    pub const Left = struct { us: u64, counted_seconds: u64 };

    pub fn stopped(c: Clock) bool {
        return c.shown_us == null;
    }

    /// Adds the time since the clock last started to the current page's time.
    fn tick(c: *Clock, now: u64) void {
        const shown = c.shown_us orelse return; // Stopped: nothing to add
        const page_us_before = c.page_us;
        c.page_us += now -| shown;
        c.shown_us = now;
        assert(c.page_us >= page_us_before);
    }

    /// Stops the clock while something covers the page, or the Kindle sleeps.
    pub fn stop(c: *Clock, now: u64) void {
        c.tick(now);
        c.shown_us = null;
        assert(c.stopped());
    }

    /// Starts the clock again when the page is back in front of the reader.
    pub fn start(c: *Clock, now: u64) void {
        if (c.shown_us == null) c.shown_us = now;
        assert(!c.stopped());
    }

    /// The page being left: its time goes to the book, as counted (a page left open
    /// for hours isn't hours of reading), and the next page's time starts at nothing.
    pub fn leave_page(c: *Clock, now: u64) Left {
        c.tick(now);
        const us = c.page_us;
        const seconds_before = c.seconds_read;
        c.page_us = 0;
        const counted = stats.counted_seconds(us / std.time.us_per_s);
        c.seconds_read += counted;
        // A page arrived at starts its time now, if the clock runs
        if (c.shown_us != null) c.shown_us = now;
        assert(c.seconds_read >= seconds_before);
        assert(c.page_us == 0);
        return .{ .us = us, .counted_seconds = counted };
    }

    /// Reading time in the book so far, with the page in front of the reader.
    pub fn seconds_total(c: *Clock, now: u64) u64 {
        c.tick(now);
        const counted = stats.counted_seconds(c.page_us / std.time.us_per_s);
        const total = c.seconds_read + counted;
        assert(total >= c.seconds_read);
        return total;
    }
};

test "time on a page adds up across stops, and goes to the book when it's left" {
    const s = std.time.us_per_s;
    var c: Clock = .{ .seconds_read = 100 };
    try std.testing.expect(c.stopped());
    c.start(0);
    c.stop(20 * s); // A menu over the page
    c.stop(500 * s); // Time stopped isn't counted
    c.start(500 * s);
    try std.testing.expectEqual(@as(u64, 130), c.seconds_total(510 * s));
    const left = c.leave_page(530 * s);
    try std.testing.expectEqual(@as(u64, 50 * s), left.us);
    try std.testing.expectEqual(@as(u64, 50), left.counted_seconds);
    try std.testing.expectEqual(@as(u64, 150), c.seconds_total(530 * s));
    try std.testing.expectEqual(@as(u64, 155), c.seconds_total(535 * s));
}
