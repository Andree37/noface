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
const paths = @import("paths.zig");
const stock_ui = @import("stock_ui.zig");
const process = @import("../sys/process.zig");
const service = @import("../sys/service.zig");
const calls = @import("../sys/calls.zig");
const linux = calls;
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
/// The longest the watchdog waits for powerd to say whether the Kindle is awake, as
/// src/kindle/lipc.zig waits for any answer.
const power_check_ms = 3_000;
/// While that question is out, the loop looks for its answer this often.
const power_poll_ms = 50;
/// What a shell's `$?` gives for a program that couldn't be started.
const exit_not_started = 127;

/// What asks powerd whether the Kindle is awake.
const power_argv = [_:null]?[*:0]const u8{
    "/usr/bin/lipc-get-prop", "-s", "com.lab126.powerd", "state",
};

/// When the watchdog looks, and how long it waits for powerd. The test runs it faster.
const Timing = struct { good_start_ms: u32, watch_every_ms: u32, power_check_ms: u32 };
const timing_kindle: Timing = .{
    .good_start_ms = good_start_ms,
    .watch_every_ms = watch_every_ms,
    .power_check_ms = power_check_ms,
};

comptime {
    assert(reader_argv.len == 7); // As src/main.zig's reader_arguments_count
    // A beat comes every 30 s: a couple can be late before noface is called stuck
    assert(heartbeat_stale_s * 1000 >= watch_every_ms * 4);
    assert(good_start_ms > watch_every_ms);
    // A question to powerd is answered, or given up on, well before the next look
    assert(power_check_ms * 4 <= watch_every_ms);
    assert(power_poll_ms < power_check_ms);
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
        watch(pid, listening, timing_kindle, &power_argv)
    else
        exit_not_started;
    var line: [32]u8 = undefined;
    const said = std.fmt.bufPrint(&line, "exit code {d}\n", .{code}) catch "exit\n";
    file.append_file(log_path, said);
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
/// Returns its exit code. The watchdog's question to powerd runs beside this loop, so
/// a slow or stuck lipc never holds up a stop request or noface's exit.
fn watch(
    pid: i32,
    listening: bool,
    timing: Timing,
    power: [*:null]const ?[*:0]const u8,
) u32 {
    assert(pid > 0);
    assert(timing.power_check_ms < timing.watch_every_ms);
    var next_look_us = os.now_us() + @as(u64, timing.good_start_ms) * std.time.us_per_ms;
    var good_start_noted = false;
    var check: ?PowerCheck = null;
    // Unbounded: noface runs as long as the reader reads; every turn waits for a
    // signal, the watchdog's next look or powerd's answer
    while (true) {
        var status: i32 = 0;
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        // Failed: not our child, so there's nothing to wait for
        if (rc == @as(u32, @intCast(pid)) or failed(rc)) {
            if (check) |c| c.give_up();
            if (failed(rc)) return exit_not_started;
            return process.exit_code(@bitCast(status));
        }
        if (service.take_stop_request()) {
            _ = linux.kill(pid, linux.SIG.TERM); // Ended already: then the next turn reaps it
        }
        const now_us = os.now_us();
        if (check) |c| {
            const answer = c.answer(now_us);
            if (answer != .waiting) check = null;
            if (answer == .awake) look(pid);
        }
        if (now_us >= next_look_us) {
            if (!good_start_noted) _ = calls.unlink(attempts_path); // Gone: nothing to reset
            // With the last question still out, this look waits for its answer instead
            if (good_start_noted and check == null) {
                const deadline_us = now_us + @as(u64, timing.power_check_ms) * 1000;
                check = PowerCheck.ask(power, deadline_us);
            }
            good_start_noted = true;
            next_look_us = now_us + @as(u64, timing.watch_every_ms) * std.time.us_per_ms;
            continue;
        }
        const until_look_ms = (next_look_us - now_us) / 1000 + 1;
        var wait_ms: u32 = @intCast(@min(until_look_ms, timing.watch_every_ms));
        if (check != null) wait_ms = @min(wait_ms, power_poll_ms);
        if (listening) service.wait_for_wake(wait_ms) else os.sleep_ms(@min(wait_ms, 1000));
    }
}

/// The watchdog's question to powerd, running beside the supervisor's loop.
const PowerCheck = struct {
    child: process.Child,
    deadline_us: u64,

    const Answer = enum { waiting, awake, unknown };

    /// Starts asking, to be answered by `deadline_us`. Null when it can't start.
    fn ask(argv: [*:null]const ?[*:0]const u8, deadline_us: u64) ?PowerCheck {
        assert(argv[0] != null);
        assert(deadline_us > 0);
        const child = process.spawn(argv) orelse return null;
        return .{ .child = child, .deadline_us = deadline_us };
    }

    /// Whether powerd has said the Kindle is awake, without waiting. Once it isn't
    /// `waiting`, the check is over: its program reaped and its pipe closed.
    fn answer(c: PowerCheck, now_us: u64) Answer {
        assert(c.child.pid > 0);
        assert(c.child.out >= 0);
        if (process.exited(c.child.pid) == null) {
            if (now_us < c.deadline_us) return .waiting;
            c.give_up();
            return .unknown;
        }
        var said: [64]u8 = undefined;
        const out = c.child.out;
        var ready = [_]linux.pollfd{.{ .fd = out, .events = linux.POLL.IN, .revents = 0 }};
        // It has exited, so what it said is in the pipe already: no need to wait
        const waited = linux.poll(&ready, 1, 0);
        const got = if (failed(waited) or waited == 0) 0 else linux.read(out, &said, said.len);
        _ = linux.close(out); // Our end of the pipe: nothing to do if it fails
        if (failed(got) or got == 0) return .unknown;
        const text = std.mem.trimEnd(u8, said[0..got], "\n");
        return if (std.mem.eql(u8, text, "active")) .awake else .unknown;
    }

    /// Ends the question unanswered: its program stopped and reaped, its pipe closed.
    fn give_up(c: PowerCheck) void {
        assert(c.child.pid > 0);
        assert(c.child.out >= 0);
        process.stop(c.child.pid);
        _ = linux.close(c.child.out); // Our end of the pipe: nothing to do if it fails
    }
};

/// One look by the watchdog, the Kindle being awake: with no heartbeat for 2 minutes,
/// noface is stuck, and ended.
fn look(pid: i32) void {
    assert(pid > 0);
    var beat_buffer: [32]u8 = undefined;
    const beat = file.read_small(paths.heartbeat, &beat_buffer);
    assert(beat.len <= beat_buffer.len);
    if (!stuck(os.unix_time(), beat)) return;
    file.append_file(log_path, "watchdog: no heartbeat for 2 minutes, stopping noface\n");
    _ = linux.kill(pid, linux.SIG.KILL); // Ended already: then the next turn reaps it
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

test "the watchdog's question to powerd never holds up noface's exit" {
    // With powerd not answering, and noface ending a moment after the first question
    const noface = process.spawn(&.{ "/bin/sleep", "1" }) orelse return error.NotStarted;
    _ = linux.close(noface.out); // Its output isn't wanted here
    const hung_lipc = [_:null]?[*:0]const u8{ "/bin/sleep", "10" };
    const timing: Timing = .{ .good_start_ms = 10, .watch_every_ms = 100, .power_check_ms = 50 };
    const started = os.now_us();
    const code = watch(noface.pid, false, timing, &hung_lipc);
    try std.testing.expectEqual(@as(u32, 0), code);
    try std.testing.expect(os.now_us() - started < 1_800_000);
    // Nothing was left running: every question was ended and reaped
    var status: i32 = 0;
    try std.testing.expect(failed(linux.waitpid(-1, &status, linux.W.NOHANG)));
}
