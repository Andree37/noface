//! Opening noface when the Kindle starts. The system's startup file
//! (device/noface-autostart.conf, run once the user drive is mounted) runs
//! `noface-launch autostart`, which comes here. It never holds up boot: what waits
//! runs in the background.
//!
//! Safety:
//!   - Off unless the settings say so (Aa > More in noface).
//!   - Crash guard: three boots in a row where noface didn't run for a minute turn
//!     autostart off by themselves (the launcher clears the count after a good minute,
//!     or when noface leaves on purpose).
const std = @import("std");
const assert = std.debug.assert;
const file = @import("../sys/file.zig");
const paths = @import("paths.zig");
const os = @import("../sys/os.zig");
const calls = @import("../sys/calls.zig");
const settings_model = @import("../model/settings.zig");

const failed = os.failed;

const settings_path = paths.data_dir ++ "/" ++ paths.data.settings;
const attempts_path = paths.data_dir ++ "/" ++ paths.data.boot_attempts;
const log_path = paths.data_dir ++ "/" ++ paths.data.log;
const off_not_saved = "autostart: couldn't save it turned off, tried again next boot\n";
const uncounted = "autostart: this boot couldn't be counted, so noface wasn't started\n";
/// Boots in a row without noface running a minute before autostart turns itself off.
pub const attempts_max = 3;
/// The settings file at its largest: its longest line is the typeface's name.
const settings_bytes_max = settings_model.file_bytes_max;

comptime {
    assert(attempts_max >= 2); // One bad boot alone never turns it off
}

pub const Decision = union(enum) {
    /// The setting is off: nothing to do.
    off,
    /// Too many failed starts: turn the setting off, and don't start.
    give_up,
    /// On, but the count of failed boots can't be read: not started, as the guard
    /// that stops a noface failing to start couldn't count this one.
    uncounted,
    /// Start noface, noting this as attempt number `attempt`.
    start: u32,
};

/// What to do at boot, from the settings and the count of failed boots: its file's
/// text, or null when it's there but unreadable.
pub fn decide(settings: *const settings_model.Settings, attempts_text: ?[]const u8) Decision {
    if (!settings.autostart) return .off;
    const attempts = parse_attempts(attempts_text orelse return .uncounted);
    if (attempts >= attempts_max) return .give_up;
    return .{ .start = attempts + 1 };
}

/// The count of failed boots, from its file: anything but a number is none.
pub fn parse_attempts(text: []const u8) u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    assert(trimmed.len <= text.len);
    const attempts = std.fmt.parseInt(u32, trimmed, 10) catch 0;
    return attempts;
}

/// Runs once per boot: the user drive comes back after every USB unplug. /tmp is in
/// RAM, so the mark is gone on the next boot. True the first time: the one run that
/// makes the mark, so two at once can't both start noface.
pub fn first_this_boot() bool {
    const mark = paths.autostart_ran;
    comptime assert(std.mem.startsWith(u8, mark, "/tmp/"));
    const flags: calls.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const rc = calls.open(mark, flags, 0o644);
    if (!failed(rc)) {
        _ = calls.close(@intCast(rc)); // Ignored: made: it says all it needs to
        return true;
    }
    if (file.exists(mark)) return false;
    // Not made, and not there: start anyway, as a boot that can't be marked is still
    // the first one
    file.append_file(log_path, "autostart: couldn't mark this boot as started\n");
    return true;
}

/// Reads the setting and the count, and acts on them. True when noface should be
/// started; the count already says this boot tried.
pub fn should_start() bool {
    var settings_buffer: [settings_bytes_max]u8 = undefined;
    var attempts_buffer: [32]u8 = undefined;
    // The reader's settings: one unreadable reads as autostart off, and is never written
    var settings_file = file.Kept.at(settings_path);
    var settings = settings_model.parse(settings_file.read(&settings_buffer));
    // The count is noface's own: one there but unreadable is no count (`decide`)
    const attempts: ?[]const u8 = file.read_small(attempts_path, &attempts_buffer) catch |err|
        switch (err) {
            error.NotFound => "",
            error.CantRead => null,
        };
    switch (decide(&settings, attempts)) {
        .off => return false,
        .uncounted => {
            file.append_file(log_path, uncounted);
            return false;
        },
        .give_up => {
            // Written as noface writes it: every other setting stays as it was
            settings.autostart = false;
            const off = settings_model.format(&settings_buffer, &settings);
            // Unwritten, autostart stays on: the count stays too, so the next boot gives
            // up again and tries again, never starting noface meanwhile
            if (!settings_file.write(&.{off})) {
                file.append_file(log_path, off_not_saved);
                return false;
            }
            // Ignored: gone already: the count starts over either way
            _ = calls.unlink(attempts_path);
            const message = "autostart: noface failed to start 3 boots in a row, " ++
                "autostart turned off\n";
            comptime assert(attempts_max == 3); // As the message says
            file.append_file(log_path, message);
            return false;
        },
        .start => |attempt| {
            assert(attempt >= 1);
            var text: [16]u8 = undefined;
            comptime assert(text.len >= 10 + 1); // Any u32, and its newline
            const count = std.fmt.bufPrint(&text, "{d}\n", .{attempt}) catch return true;
            // Uncounted, a noface that fails to start would start on every boot: the
            // guard that stops it can't count, so this boot doesn't start it
            if (!file.write_small(attempts_path, count)) {
                file.append_file(log_path, uncounted);
                return false;
            }
            return true;
        },
    }
}

test "autostart starts only when on, and gives up after three failed boots" {
    const off = settings_model.parse("size 3\n");
    const on = settings_model.parse("size 3\nautostart on\n");
    try std.testing.expectEqual(Decision.off, decide(&off, ""));
    try std.testing.expectEqual(Decision{ .start = 1 }, decide(&on, ""));
    try std.testing.expectEqual(Decision{ .start = 3 }, decide(&on, "2\n"));
    try std.testing.expectEqual(Decision.give_up, decide(&on, "3\n"));
    try std.testing.expectEqual(Decision{ .start = 1 }, decide(&on, "junk"));
    // A count that can't be read: off says nothing of it, on doesn't start
    try std.testing.expectEqual(Decision.off, decide(&off, null));
    try std.testing.expectEqual(Decision.uncounted, decide(&on, null));
}

test "giving up turns the setting off and keeps the rest, the reader's own typeface too" {
    var buffer: [settings_bytes_max]u8 = undefined;
    var s = settings_model.parse("size 4\nfont Open Sans\nautostart on\n");
    s.autostart = false;
    const again = settings_model.parse(settings_model.format(&buffer, &s));
    try std.testing.expect(!again.autostart);
    try std.testing.expectEqual(@as(u32, 4), again.size);
    try std.testing.expectEqualStrings("Open Sans", again.font.name());
}
