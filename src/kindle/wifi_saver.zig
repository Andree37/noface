//! Wi-Fi off while reading. The radio is the biggest drain a Kindle has besides the
//! screen, and an open book needs no network. A couple of minutes into a book the
//! Kindle goes into airplane mode, and comes out of it on leaving the book, so the
//! library can sync and download. Airplane mode is the only switch the connection
//! manager doesn't undo: wifid's own "enable" springs back. It's left alone while
//! Bluetooth is on, which airplane mode could cut off.
//!
//! Only a radio noface turned off is turned back on, which a file on the user drive
//! remembers. That way it's put back even after a crash or a reboot: the launcher does
//! it on the way out (src/kindle/stock_ui.zig) and at boot (src/launch.zig), and noface
//! on its way in.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("../sys/file.zig");
const lipc = @import("lipc.zig");
const linux = @import("../sys/calls.zig");
const paths = @import("paths.zig");

/// How long into a book before the radio goes off: a quick look in doesn't toggle it.
pub const after_us: u64 = 2 * 60 * 1000 * 1000;

/// The note, in the data folder noface was started with (see `use_data_dir`), or the
/// reader's own, where the launcher, which is given none, looks for it.
const default_marker = paths.data_dir ++ "/" ++ paths.data.wifi_paused;
var marker: [*:0]const u8 = default_marker;
/// Room for the note in any data folder noface takes, and its closing zero.
var marker_buffer: [file.own_path_bytes_max + 1 + paths.data.wifi_paused.len + 1]u8 = undefined;

comptime {
    // The default note's path fits the buffer another folder's is written to
    assert(default_marker.len < marker_buffer.len);
    // A file's name, not a path: `marker_is_note` finds it after the last slash
    assert(paths.data.wifi_paused.len > 0);
    assert(std.mem.indexOfScalar(u8, paths.data.wifi_paused, '/') == null);
    // Long enough that opening a book for a look doesn't switch the radio
    assert(after_us >= 60 * 1000 * 1000);
}

/// Keeps the note in `dir`: the data folder noface was started with, or a test's own.
/// A folder longer than any noface takes is refused, never quietly left pointing at
/// another folder's note (the reader's, while a test runs).
pub fn use_data_dir(dir: []const u8) error{PathTooLong}!void {
    assert(dir.len > 0);
    const format = "{s}/" ++ paths.data.wifi_paused;
    marker = std.fmt.bufPrintSentinel(&marker_buffer, format, .{dir}, 0) catch
        return error.PathTooLong;
    assert(marker_is_note());
}

/// Keeps the note in the reader's own data folder again, as before any `use_data_dir`.
pub fn use_default() void {
    marker = default_marker;
    assert(marker_is_note());
}

/// Where the note is kept now.
pub fn note_path() [*:0]const u8 {
    assert(marker_is_note());
    return marker;
}

/// Whether `marker` names the note: only `use_data_dir` sets it, to a file of this name.
fn marker_is_note() bool {
    const path = std.mem.span(marker);
    assert(path.len > paths.data.wifi_paused.len);
    assert(path.len < marker_buffer.len);
    return std.mem.endsWith(u8, path, "/" ++ paths.data.wifi_paused);
}

/// When the radio goes off while a book is read, as one value: a couple of minutes in,
/// unless the reader took charge of airplane mode, and not while a download is coming.
/// Its verbs touch nothing of the Kindle's: the reader asks `due`, then `pause`, then
/// says what came of it with `settle`.
pub const Pause = struct {
    off_at: ?u64 = null, // When to try, on the monotonic clock; null once settled
    hands_off: bool = false, // The reader took charge of airplane mode in this book
    downloads_until: u64 = 0, // A download may still be running until then

    /// A book opened: off a couple of minutes from now, whatever came before.
    pub fn book_opened(p: *Pause, now_us: u64) void {
        p.hands_off = false;
        p.off_at = now_us + after_us;
        assert(p.off_at.? > now_us);
    }

    /// The reader turned airplane mode, Wi-Fi or a sync on or off: theirs for the book.
    pub fn reader_took_charge(p: *Pause) void {
        p.hands_off = true;
    }

    /// A download may run until `until`: never a shorter wait than one already asked.
    pub fn download_until(p: *Pause, until_us: u64) void {
        p.downloads_until = @max(p.downloads_until, until_us);
        assert(p.downloads_until >= until_us);
    }

    /// Off again as soon as the reader is back on the page: after noface's pause was
    /// lifted for a moment (a dictionary's download).
    pub fn resume_soon(p: *Pause, now_us: u64) void {
        p.off_at = now_us;
    }

    /// Whether it's time to try, and if so whether a download is coming (`pause`'s
    /// question); null for nothing to do now. Taken charge of, it settles to never.
    // Assertions: it reads its times against the clock's, any of which may be the later.
    pub fn due(p: *Pause, now_us: u64) ?bool {
        const at = p.off_at orelse return null;
        if (now_us < at) return null;
        if (p.hands_off) {
            p.off_at = null;
            return null;
        }
        return now_us < p.downloads_until;
    }

    /// What `pause` came to at `now_us`: settled, or tried again `retry_us` later.
    pub fn settle(p: *Pause, outcome: Outcome, now_us: u64, retry_us: u64) void {
        assert(retry_us > 0);
        p.off_at = switch (outcome) {
            .paused, .never => null,
            .later => now_us + retry_us,
        };
        if (p.off_at) |next| assert(next > now_us);
    }
};

/// Whose airplane mode is on, if it is: noface's own pause (its note is there), which
/// noface undoes, or the reader's, which is theirs. Unknown when the Kindle didn't say.
pub const Airplane = enum { off, noface, reader, unknown };

pub fn airplane() Airplane {
    assert(marker_is_note());
    const on = lipc.airplane_on() orelse return .unknown;
    if (!on) return .off;
    // Whose, by the note: one that can't be looked at says neither
    return switch (file.presence(marker)) {
        .here => .noface,
        .absent => .reader,
        .unknown => .unknown,
    };
}

pub const Outcome = enum {
    paused, // Off now
    later, // Not now (a download, Bluetooth, or lipc not answering): try again
    never, // Airplane mode is the reader's own, or noface couldn't note that it acted
};

/// Turns the radio off, if airplane mode and Bluetooth are both off and nothing is
/// downloading. The note goes down first and must land: without it nothing would
/// ever turn the radio on again. Asked once, it's `.later`: the next try sees airplane
/// mode on, with noface's note, and settles it, never waiting on the radio here.
pub fn pause(downloading: bool) Outcome {
    assert(marker_is_note());
    if (downloading) return .later;
    // On already: noface's own doing if its note is there (a switch that answered late),
    // else the reader's
    switch (airplane()) {
        .off => {},
        .noface => {
            std.debug.print("wifi: off while reading\n", .{});
            return .paused;
        },
        .reader => return .never,
        .unknown => return .later,
    }
    if (lipc.bluetooth_on() orelse return .later) return .later;
    // Unwritten, it's never paused: noface couldn't put it back
    if (!file.write_small(marker, "1\n")) return .never;
    lipc.set_airplane(true);
    // Not read back now: the radio going down is what's slow to answer. The note stays,
    // as noface may well have turned it off and must be the one to turn it back on
    return .later;
}

/// Whether noface has the radio off right now, so it may turn it back on: its note is
/// seen there. One that can't be looked at is neither: nothing is turned on for it, as
/// only a radio noface turned off is turned back on, and the note stays for next time.
pub fn marked() bool {
    assert(marker_is_note());
    return file.presence(marker) == .here;
}

/// Turns the radio back on, if noface is the one that turned it off. The note stays
/// until airplane mode is seen off, so the launcher or the next start can try again.
pub fn restore() void {
    assert(marker_is_note());
    if (!marked()) return;
    lipc.set_airplane(false);
    // Seen off: the note goes. Still on, or no answer: it stays, to try again
    switch (airplane()) {
        .off => {
            forget();
            std.debug.print("wifi: back on\n", .{});
        },
        .noface, .reader, .unknown => std.debug.print("wifi: couldn't turn it back on yet\n", .{}),
    }
}

/// The reader switched airplane mode themselves: theirs now, not noface's to undo.
pub fn forget() void {
    assert(marker_is_note());
    // Ignored: A note already gone is what forgetting wants, so its failing to go is no matter
    _ = linux.unlink(marker);
}

test "the note goes in any data folder noface takes, and a longer one is refused" {
    defer use_default();
    const longest: [file.own_path_bytes_max]u8 = @splat('d');
    try use_data_dir(&longest);
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(note_path()), &longest));
    const longer: [file.own_path_bytes_max + marker_buffer.len]u8 = @splat('d');
    try std.testing.expectError(error.PathTooLong, use_data_dir(&longer));
}

test "the radio goes off a couple of minutes into a book, unless the reader took charge" {
    var p: Pause = .{};
    p.book_opened(0);
    try std.testing.expectEqual(@as(?bool, null), p.due(after_us - 1));
    try std.testing.expectEqual(@as(?bool, false), p.due(after_us)); // Nothing coming down
    p.settle(.later, after_us, 1);
    try std.testing.expectEqual(@as(?bool, null), p.due(after_us)); // Tried again later
    // A download coming: asked with it, and a shorter one never cuts it short
    p.download_until(after_us * 3);
    p.download_until(after_us * 2);
    try std.testing.expectEqual(@as(?bool, true), p.due(after_us + 1));
    // Taken charge of: settles to never
    p.reader_took_charge();
    try std.testing.expectEqual(@as(?bool, null), p.due(after_us * 4));
    try std.testing.expectEqual(@as(?u64, null), p.off_at);
    // A new book, a new choice
    p.book_opened(after_us * 4);
    try std.testing.expect(!p.hands_off);
}
