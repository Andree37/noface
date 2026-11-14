//! Opening noface when the Kindle starts. The system's startup file
//! (device/noface-autostart.conf, run once the user drive is mounted) runs
//! `noface-launch autostart`, which comes here. It never holds up boot: what waits
//! runs in the background.
//!
//! Safety:
//!   - Off unless the settings say "autostart on" (Aa > More in noface).
//!   - Crash guard: three boots in a row where noface didn't run for a minute turn
//!     autostart off by themselves (the launcher clears the count after a good minute,
//!     or when noface leaves on purpose).
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const state = @import("../sys/state.zig");
const service = @import("../sys/service.zig");
const os = @import("../sys/os.zig");
const calls = @import("../sys/calls.zig");

const failed = os.failed;

const settings_path = paths.data_dir ++ "/settings";
const attempts_path = paths.data_dir ++ "/" ++ paths.data.boot_attempts;
const log_path = paths.data_dir ++ "/" ++ paths.data.log;
/// Boots in a row without noface running a minute before autostart turns itself off.
pub const attempts_max = 3;
/// The settings file is a few hundred bytes: more than this is read only this far.
const settings_bytes_max = 16 << 10;
const setting_on = "autostart on";
const setting_off = "autostart off";

comptime {
    assert(attempts_max >= 2); // One bad boot alone never turns it off
    assert(std.mem.startsWith(u8, setting_off, "autostart "));
}

pub const Decision = union(enum) {
    /// The setting is off: nothing to do.
    off,
    /// Too many failed starts: turn the setting off, and don't start.
    give_up,
    /// Start noface, noting this as attempt number `attempt`.
    start: u32,
};

/// What to do at boot, from the settings file and the count of failed boots.
pub fn decide(settings: []const u8, attempts_text: []const u8) Decision {
    if (!autostart_on(settings)) return .off;
    assert(settings.len >= setting_on.len); // It says so
    const attempts = parse_attempts(attempts_text);
    if (attempts >= attempts_max) return .give_up;
    assert(attempts < attempts_max);
    return .{ .start = attempts + 1 };
}

/// Whether a line of the settings starts "autostart on".
pub fn autostart_on(settings: []const u8) bool {
    var lines = std.mem.splitScalar(u8, settings, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, setting_on)) return true;
    }
    assert(std.mem.indexOf(u8, settings, "\n" ++ setting_on) == null);
    return false;
}

/// The count of failed boots, from its file: anything but a number is none.
pub fn parse_attempts(text: []const u8) u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    assert(trimmed.len <= text.len);
    const attempts = std.fmt.parseInt(u32, trimmed, 10) catch 0;
    if (trimmed.len == 0) assert(attempts == 0);
    return attempts;
}

/// The settings with every line starting "autostart on" starting "autostart off"
/// instead, into `out`. Null when it doesn't fit.
pub fn turned_off(settings: []const u8, out: []u8) ?[]const u8 {
    var length: u32 = 0;
    var lines = std.mem.splitScalar(u8, settings, '\n');
    var first = true;
    while (lines.next()) |line| {
        const replaced = std.mem.startsWith(u8, line, setting_on);
        const rest = if (replaced) line[setting_on.len..] else line;
        const head: []const u8 = if (replaced) setting_off else "";
        const needed = @intFromBool(!first) + head.len + rest.len;
        if (length + needed > out.len) return null;
        if (!first) out[length] = '\n';
        length += @intFromBool(!first);
        @memcpy(out[length..][0..head.len], head);
        @memcpy(out[length + head.len ..][0..rest.len], rest);
        length += @intCast(head.len + rest.len);
        first = false;
    }
    assert(length <= out.len);
    assert(length >= settings.len);
    return out[0..length];
}

/// Runs once per boot: the user drive comes back after every USB unplug, and an older
/// install's startup file may call this too. /tmp is in RAM, so the mark is gone on the
/// next boot. True the first time.
pub fn first_this_boot() bool {
    const mark = paths.autostart_ran;
    comptime assert(std.mem.startsWith(u8, mark, "/tmp/"));
    if (file_exists(mark)) return false;
    assert(!file_exists(mark));
    const rc = calls.open(mark, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644);
    if (!failed(rc)) _ = calls.close(@intCast(rc)); // Made: it says all it needs to
    return true;
}

fn file_exists(path: [*:0]const u8) bool {
    assert(path[0] == '/');
    const rc = calls.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return false;
    _ = calls.close(@intCast(rc)); // Only opened to see that it could be
    return true;
}

/// Reads the setting and the count, and acts on them. True when noface should be
/// started; the count already says this boot tried.
pub fn should_start() bool {
    var settings_buffer: [settings_bytes_max]u8 = undefined;
    var attempts_buffer: [32]u8 = undefined;
    const settings = state.read_small(settings_path, &settings_buffer);
    const attempts = state.read_small(attempts_path, &attempts_buffer);
    switch (decide(settings, attempts)) {
        .off => return false,
        .give_up => {
            // A file that filled the buffer may hold more: rewriting it would lose that
            var out: [settings_bytes_max + 64]u8 = undefined;
            if (settings.len < settings_buffer.len) {
                if (turned_off(settings, &out)) |text| state.write_small(settings_path, text);
            }
            _ = calls.unlink(attempts_path); // Gone already: the count starts over either way
            const message = "autostart: noface failed to start 3 boots in a row, " ++
                "autostart turned off\n";
            comptime assert(attempts_max == 3); // As the message says
            service.append_file(log_path, message);
            return false;
        },
        .start => |attempt| {
            assert(attempt >= 1);
            var text: [16]u8 = undefined;
            comptime assert(text.len >= 10 + 1); // Any u32, and its newline
            const count = std.fmt.bufPrint(&text, "{d}\n", .{attempt}) catch return true;
            state.write_small(attempts_path, count);
            return true;
        },
    }
}

test "autostart starts only when on, and gives up after three failed boots" {
    try std.testing.expectEqual(Decision.off, decide("font 3\n", ""));
    try std.testing.expectEqual(Decision.off, decide("autostart off\n", "0\n"));
    try std.testing.expectEqual(Decision{ .start = 1 }, decide("font 3\nautostart on\n", ""));
    try std.testing.expectEqual(Decision{ .start = 3 }, decide("autostart on\n", "2\n"));
    try std.testing.expectEqual(Decision.give_up, decide("autostart on\n", "3\n"));
    try std.testing.expectEqual(Decision{ .start = 1 }, decide("autostart on\n", "junk"));
}

test "giving up turns the setting off and leaves the rest" {
    var out: [64]u8 = undefined;
    const text = turned_off("font 3\nautostart on\nsize 2\n", &out).?;
    try std.testing.expectEqualStrings("font 3\nautostart off\nsize 2\n", text);
    try std.testing.expect(turned_off("autostart on", out[0..12]) == null);
}
