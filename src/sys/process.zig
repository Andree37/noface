//! Running other programs, with a deadline so a stuck one can't freeze the reader.
const std = @import("std");
const linux = @import("calls.zig");
const os = @import("os.zig");
const failed = os.failed;

pub const Child = struct { pid: i32, out: i32 };

/// Set by the scenario tests: no program is started at all, and `answer` says what it
/// would have printed (null for "didn't run"). The self-test runs on the reader's own
/// Kindle, and must never change it: no airplane mode, no sync, no catalog export.
pub const Fake = struct {
    ctx: *anyopaque,
    answer: *const fn (ctx: *anyopaque, argv: []const []const u8, out: []u8) ?usize,
};
pub var fake: ?Fake = null;

fn answerFake(f: Fake, argv: [*:null]const ?[*:0]const u8, out: []u8) ?usize {
    var args: [12][]const u8 = undefined;
    var n: usize = 0;
    while (argv[n]) |a| : (n += 1) {
        if (n == args.len) break;
        args[n] = std.mem.sliceTo(a, 0);
    }
    return f.answer(f.ctx, args[0..n], out);
}

/// Starts a program with its output on a pipe, in a process group of its own so
/// everything it starts can be killed together.
pub fn spawn(argv: [*:null]const ?[*:0]const u8) ?Child {
    if (fake != null) return null; // Watchers and helpers don't start under test
    var fds: [2]i32 = undefined;
    // Close-on-exec, so later children don't inherit this pipe. dup2 below clears it on
    // the child's own stdout.
    if (failed(linux.pipe2(&fds, .{ .CLOEXEC = true }))) return null;
    const pid = linux.fork();
    if (failed(pid)) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0].?, argv, &envp);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    return .{ .pid = @intCast(pid), .out = fds[0] };
}

/// Longest any command may take. A stuck lipc or sqlite call must not freeze the reader.
const command_timeout_ms = 15_000;

/// Runs a command, collecting what it prints. Null when it can't start or runs too long,
/// in which case it is killed.
pub fn run(argv: [*:null]const ?[*:0]const u8, out: []u8) ?usize {
    return runUntil(argv, out, os.nowUs() + command_timeout_ms * 1000);
}

/// Like `run`, but must be done by `deadline` (microseconds on the monotonic clock).
pub fn runUntil(argv: [*:null]const ?[*:0]const u8, out: []u8, deadline: u64) ?usize {
    if (fake) |f| return answerFake(f, argv, out);
    if (os.nowUs() >= deadline) return null;
    const child = spawn(argv) orelse return null;
    var total: usize = 0;
    while (total < out.len) {
        const now = os.nowUs();
        if (now >= deadline) break;
        var ready = [_]linux.pollfd{.{ .fd = child.out, .events = linux.POLL.IN, .revents = 0 }};
        const waited = linux.poll(&ready, 1, @intCast((deadline - now) / 1000 + 1));
        if (failed(waited)) continue; // Interrupted by a signal
        if (waited == 0) break;
        const n = linux.read(child.out, out[total..].ptr, out.len - total);
        if (failed(n) or n == 0) break;
        total += n;
    }
    // Closing first means a child with more to say gets SIGPIPE instead of blocking.
    _ = linux.close(child.out);
    if (!reap(child.pid, deadline)) {
        std.debug.print("command timed out: {s}\n", .{std.mem.sliceTo(argv[0].?, 0)});
        return null;
    }
    return total;
}

/// Runs several commands at once, collecting what each prints into its own buffer:
/// together they take about as long as the slowest, not the sum. `lens[i]` is how much
/// command i printed, or null when it didn't start or wasn't done by `deadline`.
pub fn runAll(argvs: []const [*:null]const ?[*:0]const u8, outs: [][]u8, lens: []?usize, deadline: u64) void {
    const max = 16;
    std.debug.assert(argvs.len <= max and outs.len == argvs.len and lens.len == argvs.len);
    if (fake) |f| {
        for (argvs, outs, lens) |argv, out, *len| len.* = answerFake(f, argv, out);
        return;
    }
    var children: [max]?Child = @splat(null);
    var open: [max]bool = @splat(false);
    for (argvs, 0..) |argv, i| {
        lens[i] = null;
        children[i] = spawn(argv);
        if (children[i] != null) {
            open[i] = true;
            lens[i] = 0;
        }
    }
    // Read whichever has output until all have finished printing, or time runs out
    while (os.nowUs() < deadline) {
        var fds: [max]linux.pollfd = undefined;
        var which: [max]usize = undefined;
        var n: usize = 0;
        for (0..argvs.len) |i| {
            if (!open[i]) continue;
            fds[n] = .{ .fd = children[i].?.out, .events = linux.POLL.IN, .revents = 0 };
            which[n] = i;
            n += 1;
        }
        if (n == 0) break;
        const waited = linux.poll(&fds, n, @intCast((deadline - os.nowUs()) / 1000 + 1));
        if (failed(waited)) continue; // Interrupted by a signal
        if (waited == 0) break;
        for (fds[0..n], which[0..n]) |f, i| {
            if (f.revents == 0) continue;
            const buf = outs[i][lens[i].?..];
            const got = if (buf.len == 0) 0 else linux.read(f.fd, buf.ptr, buf.len);
            if (failed(got) or got == 0) {
                open[i] = false;
                continue;
            }
            lens[i] = lens[i].? + got;
        }
    }
    for (0..argvs.len) |i| {
        const child = children[i] orelse continue;
        _ = linux.close(child.out);
        if (open[i] or !reap(child.pid, deadline)) lens[i] = null; // Not finished in time
    }
}

/// Waits for a child to exit until `deadline`, then kills its whole group. For
/// `sh -c`, the stuck program is the shell's child. True when it exited in time.
fn reap(pid: i32, deadline: u64) bool {
    var status: i32 = 0;
    while (true) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) != 0) return true;
        if (os.nowUs() >= deadline) break;
        os.sleepMs(5);
    }
    _ = linux.kill(-pid, linux.SIG.KILL);
    _ = linux.waitpid(pid, &status, 0);
    return false;
}

/// A spawned child's state, without waiting: null while it runs, then whether it
/// exited cleanly (status 0). Reaps it once it's done.
pub fn exited(pid: i32) ?bool {
    var status: i32 = 0;
    const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
    if (rc == 0) return null;
    if (failed(rc)) return false;
    const st: u32 = @bitCast(status);
    return linux.W.IFEXITED(st) and linux.W.EXITSTATUS(st) == 0;
}

/// Stops a spawned child and everything it started, and reaps it.
pub fn stop(pid: i32) void {
    _ = linux.kill(-pid, linux.SIG.KILL);
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
}

/// Runs `check(ctx)` in a child process and says whether it returned true there. For
/// trying something that could crash (a font file of unknown quality, say): only the
/// child dies. Under the scenario tests' fake, it runs here instead.
pub fn survives(ctx: anytype, comptime check: fn (@TypeOf(ctx)) bool) bool {
    if (fake != null) return check(ctx);
    const pid = linux.fork();
    if (failed(pid)) return false;
    if (pid == 0) linux.exit(if (check(ctx)) 0 else 1);
    const deadline = os.nowUs() + 5 * 1_000_000;
    while (os.nowUs() < deadline) {
        if (exited(@intCast(pid))) |ok| return ok;
        os.sleepMs(5);
    }
    stop(@intCast(pid));
    return false;
}

test "a check that crashes only ends its child" {
    const ok = struct {
        fn check(_: void) bool {
            return true;
        }
    }.check;
    const crashes = struct {
        fn check(_: void) bool {
            _ = linux.close(2); // Crash quietly: no stack trace in the test output
            const p: ?*volatile u8 = null;
            return p.?.* == 0; // A read through nothing, as a damaged font can cause
        }
    }.check;
    try std.testing.expect(survives({}, ok));
    try std.testing.expect(!survives({}, crashes));
}
