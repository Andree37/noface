//! Runs noface and watches it: pauses the stock screens, starts noface with its output
//! in noface.log, stops it if it hangs, and puts the stock screens back however it
//! ends. The launcher (src/launch.zig) runs this in a process of its own, apart from
//! noface, so noface crashing, hanging or being killed can't stop it.
//!
//! The watchdog: noface refreshes a heartbeat in RAM every 30 seconds while its loop
//! runs. If that stops for 2 minutes while the Kindle is awake, noface is stuck: it's
//! ended, and the stock screens come back. A locked Kindle lets noface sleep, so it's
//! left alone then. After a minute of running well, the boot crash guard
//! (src/kindle/boot.zig) is reset too.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const paths = @import("paths.zig");
const stock_ui = @import("stock_ui.zig");
const process = @import("../sys/process.zig");
const service = @import("../sys/service.zig");
const state = @import("../sys/state.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");

const failed = os.failed;

const log_path = paths.data_dir ++ "/" ++ paths.data.log;
const log_old_path = paths.data_dir ++ "/" ++ paths.data.log_old;
const attempts_path = paths.data_dir ++ "/" ++ paths.data.boot_attempts;
const fonts = paths.kindle_fonts;

/// The command line noface reads with: the library, four fonts and the data folder (src/main.zig).
const reader_argv = [_:null]?[*:0]const u8{
    paths.reader,
    paths.data_dir ++ "/" ++ paths.data.library,
    fonts ++ "/Bookerly-Regular.ttf",
    fonts ++ "/Bookerly-Bold.ttf",
    fonts ++ "/Amazon-Ember-Regular.ttf",
    fonts ++ "/Amazon-Ember-Bold.ttf",
    paths.data_dir,
};

/// Past this, the log starts over, keeping one old copy.
const log_bytes_max = 512 << 10;
/// Running this long, noface started well: the boot crash guard is reset.
const good_start_ms = 60_000;
/// How often the watchdog looks.
const watch_every_ms = 30_000;
/// A heartbeat older than this, with the Kindle awake, means noface is stuck.
const heartbeat_stale_s = 120;
/// What a shell's `$?` gives for a program that couldn't be started.
const exit_not_started = 127;

comptime {
    assert(reader_argv.len == 7); // As src/main.zig's reader_arguments_count
    // A beat comes every 30 s: a couple can be late before noface is called stuck
    assert(heartbeat_stale_s * 1000 >= watch_every_ms * 4);
    assert(good_start_ms > watch_every_ms);
}

/// Runs noface until it ends, with `envp` as its environment, and puts the stock
/// screens back. Returns noface's exit code, as a shell's `$?` gives it.
pub fn run(envp: [*:null]const ?[*:0]const u8) u32 {
    assert(!stock_ui.paused);
    // Signals first: from here, a request to stop reaches noface instead of ending
    // this before it can put the stock screens back
    const listening = service.listen_for_signals();
    stock_ui.pause();
    rotate_log();
    const code = if (service.spawn_to_file(&reader_argv, envp, log_path, .append, true)) |pid|
        watch(pid, listening)
    else
        exit_not_started;
    var line: [32]u8 = undefined;
    const said = std.fmt.bufPrint(&line, "exit code {d}\n", .{code}) catch "exit\n";
    service.append_file(log_path, said);
    // Leaving on purpose is a good start too, even within the first minute
    if (code == 0) _ = calls.unlink(attempts_path); // Gone already: nothing to reset
    stock_ui.restore();
    assert(!stock_ui.paused);
    return code;
}

/// Keeps the log small: once it passes 512 KB it starts over, keeping one old copy.
fn rotate_log() void {
    const size = file.size_of(log_path);
    if (size <= log_bytes_max) return;
    if (failed(calls.rename(log_path, log_old_path))) {
        std.debug.print("log: couldn't set aside {s}\n", .{log_path});
    }
    assert(size > log_bytes_max);
}

/// Waits for noface to end, passing on a request to stop and running the watchdog.
/// Returns its exit code.
fn watch(pid: i32, listening: bool) u32 {
    assert(pid > 0);
    const started_us = os.now_us();
    var next_look_us = started_us + good_start_ms * std.time.us_per_ms;
    var good_start_noted = false;
    // Unbounded: noface runs as long as the reader reads; every turn waits for a
    // signal or the watchdog's next look
    while (true) {
        var status: i32 = 0;
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(u32, @intCast(pid))) return service.exit_code(@bitCast(status));
        if (failed(rc)) return exit_not_started; // Not our child: nothing to wait for
        if (service.take_stop_request()) {
            _ = linux.kill(pid, .TERM); // Ended already: then the next look reaps it
        }
        const now_us = os.now_us();
        if (now_us >= next_look_us) {
            if (!good_start_noted) _ = calls.unlink(attempts_path); // Gone: nothing to reset
            if (good_start_noted) look(pid);
            good_start_noted = true;
            next_look_us = now_us + watch_every_ms * std.time.us_per_ms;
            continue;
        }
        const wait_ms: u32 = @intCast(@min((next_look_us - now_us) / 1000 + 1, watch_every_ms));
        if (listening) service.wait_for_wake(wait_ms) else os.sleep_ms(@min(wait_ms, 1000));
    }
}

/// One look by the watchdog: with the Kindle awake and no heartbeat for 2 minutes,
/// noface is stuck, and ended.
fn look(pid: i32) void {
    assert(pid > 0);
    var power: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{
        "/usr/bin/lipc-get-prop", "-s", "com.lab126.powerd", "state",
    };
    const printed = process.run(&argv, &power) orelse return;
    assert(printed <= power.len);
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, power[0..printed], "\n"), "active")) return;
    var beat_buffer: [32]u8 = undefined;
    const beat = state.read_small(paths.heartbeat, &beat_buffer);
    if (!stuck(os.unix_time(), beat)) return;
    service.append_file(log_path, "watchdog: no heartbeat for 2 minutes, stopping noface\n");
    _ = linux.kill(pid, .KILL); // Ended already: then the next look reaps it
}

/// Whether noface's last heartbeat (seconds since 1970, as text; none reads as 0) is
/// over 2 minutes before `now`.
pub fn stuck(now: u64, beat_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, beat_text, " \n");
    const beat = std.fmt.parseInt(u64, trimmed, 10) catch 0;
    if (beat >= now) return false; // A clock set back: no sign of being stuck
    assert(now > beat);
    return now - beat > heartbeat_stale_s;
}

test "the watchdog ends noface only after two minutes without a heartbeat" {
    try std.testing.expect(!stuck(1000, "900\n"));
    try std.testing.expect(!stuck(1000, "880\n"));
    try std.testing.expect(stuck(1000, "879\n"));
    try std.testing.expect(stuck(1000, ""));
    try std.testing.expect(!stuck(1000, "2000\n"));
}
