//! Running other programs, with a deadline so a stuck one can't freeze the reader.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("calls.zig");
const os = @import("os.zig");
const failed = os.failed;

pub const Child = struct { pid: i32, out: i32 };

/// Set by the scenario tests: no program is started at all, and `answer` says what it
/// would have printed (null for "didn't run"). The self-test runs on the reader's own
/// Kindle, and must never change it: no airplane mode, no sync, no catalog export.
pub const Fake = struct {
    ctx: *anyopaque,
    answer: *const fn (ctx: *anyopaque, argv: []const []const u8, out: []u8) ?u32,
};
pub var fake: ?Fake = null;

/// The most arguments a fake is shown; a command with more is cut short.
const fake_arguments_max = 12;

/// The most commands `run_all` runs at once.
const run_all_commands_max = 16;

/// How often a child that hasn't exited is looked at again.
const reap_poll_ms = 5;

/// Longest any command may take. A stuck lipc or sqlite call must not freeze the reader.
const command_timeout_ms = 15_000;

comptime {
    assert(reap_poll_ms < command_timeout_ms);
}

fn answer_fake(f: Fake, argv: [*:null]const ?[*:0]const u8, out: []u8) ?u32 {
    assert(argv[0] != null); // A command names its program
    var arguments: [fake_arguments_max][]const u8 = undefined;
    var arguments_count: u32 = 0;
    for (&arguments, 0..) |*argument, index| {
        const text = argv[index] orelse break;
        argument.* = std.mem.sliceTo(text, 0);
        arguments_count += 1;
    }
    const printed = f.answer(f.ctx, arguments[0..arguments_count], out);
    if (printed) |count| assert(count <= out.len); // A fake prints into `out` too
    return printed;
}

/// Starts a program with its output on a pipe, in a process group of its own so
/// everything it starts can be killed together.
pub fn spawn(argv: [*:null]const ?[*:0]const u8) ?Child {
    assert(argv[0] != null); // A command names its program
    if (fake != null) return null; // Watchers and helpers don't start under test
    var fds: [2]i32 = undefined;
    // Close-on-exec, so later children don't inherit this pipe. dup2 below clears it on
    // the child's own stdout.
    if (failed(linux.pipe2(&fds, .{ .CLOEXEC = true }))) return null;
    const pid = linux.fork();
    if (failed(pid)) {
        _ = linux.close(fds[0]); // Nothing was started: only the pipe to give back
        _ = linux.close(fds[1]); // Likewise
        return null;
    }
    if (pid == 0) spawn_child(argv, fds);
    _ = linux.close(fds[1]); // The child's end: the child holds its own copy
    const child = Child{ .pid = @intCast(pid), .out = fds[0] };
    assert(child.pid > 0);
    assert(child.out >= 0);
    return child;
}

/// In the child: makes the pipe its output and runs the program, never returning.
fn spawn_child(argv: [*:null]const ?[*:0]const u8, fds: [2]i32) noreturn {
    assert(fds[0] >= 0);
    assert(fds[1] >= 0);
    // Each failure here shows as the program's failure, through the exit status below
    _ = linux.setpgid(0, 0);
    _ = linux.dup2(fds[1], 1);
    _ = linux.close(fds[0]);
    _ = linux.close(fds[1]);
    const envp = [_:null]?[*:0]const u8{};
    _ = linux.execve(argv[0].?, argv, &envp); // Returns only on failure
    linux.exit(127);
}

/// Runs a command, collecting what it prints. Null when it can't start or runs too long,
/// in which case it is killed.
pub fn run(argv: [*:null]const ?[*:0]const u8, out: []u8) ?u32 {
    assert(argv[0] != null);
    const printed = run_until(argv, out, os.now_us() + command_timeout_ms * 1000);
    if (printed) |count| assert(count <= out.len);
    return printed;
}

/// Like `run`, but must be done by `deadline` (microseconds on the monotonic clock).
pub fn run_until(argv: [*:null]const ?[*:0]const u8, out: []u8, deadline: u64) ?u32 {
    assert(argv[0] != null);
    assert(out.len <= std.math.maxInt(u32)); // A command's output is read into a small buffer
    if (fake) |f| return answer_fake(f, argv, out);
    if (os.now_us() >= deadline) return null;
    const child = spawn(argv) orelse return null;
    var total: u32 = 0; // Bytes read into `out`
    // Bounded by the deadline, and by `out`, which each read fills further
    while (total < out.len) {
        const now = os.now_us();
        if (now >= deadline) break;
        var ready = [_]linux.pollfd{.{ .fd = child.out, .events = linux.POLL.IN, .revents = 0 }};
        const waited = linux.poll(&ready, 1, @intCast((deadline - now) / 1000 + 1));
        if (failed(waited)) continue; // Interrupted by a signal
        if (waited == 0) break;
        const got = linux.read(child.out, out[total..].ptr, out.len - total);
        if (failed(got) or got == 0) break;
        total += @intCast(got); // At most what was left of `out`
        assert(total <= out.len);
    }
    // Closing first means a child with more to say gets SIGPIPE instead of blocking.
    _ = linux.close(child.out); // Our end of the pipe: nothing to do if it fails
    if (!reap(child.pid, deadline)) {
        std.debug.print("command timed out: {s}\n", .{std.mem.sliceTo(argv[0].?, 0)});
        return null;
    }
    return total;
}

/// Runs several commands at once, collecting what each prints into its own buffer:
/// together they take about as long as the slowest, not the sum. `lens[i]` is how much
/// command i printed, or null when it didn't start or wasn't done by `deadline`.
pub fn run_all(
    argvs: []const [*:null]const ?[*:0]const u8,
    outs: [][]u8,
    lens: []?u32,
    deadline: u64,
) void {
    assert(argvs.len <= run_all_commands_max);
    assert(outs.len == argvs.len);
    assert(lens.len == argvs.len);
    if (fake) |f| {
        for (argvs, outs, lens) |argv, out, *len| len.* = answer_fake(f, argv, out);
        return;
    }
    var children: [run_all_commands_max]?Child = @splat(null);
    var open: [run_all_commands_max]bool = @splat(false);
    for (argvs, 0..) |argv, index| {
        lens[index] = null;
        children[index] = spawn(argv);
        if (children[index] != null) {
            open[index] = true;
            lens[index] = 0;
        }
    }
    // Read whichever has output until all have finished printing, or time runs out
    while (os.now_us() < deadline) {
        if (!run_all_read(children[0..argvs.len], open[0..argvs.len], outs, lens, deadline)) {
            break;
        }
    }
    for (0..argvs.len) |index| {
        const child = children[index] orelse continue;
        _ = linux.close(child.out); // Our end of the pipe: nothing to do if it fails
        if (open[index] or !reap(child.pid, deadline)) lens[index] = null; // Not finished in time
        if (lens[index]) |count| assert(count <= outs[index].len);
    }
}

/// Waits for output from the children still open, until `deadline`, and reads what
/// came. False when there's nothing more to wait for: all are done, or time ran out.
fn run_all_read(
    children: []const ?Child,
    open: []bool,
    outs: [][]u8,
    lens: []?u32,
    deadline: u64,
) bool {
    assert(children.len <= run_all_commands_max);
    assert(open.len == children.len);
    var fds: [run_all_commands_max]linux.pollfd = undefined;
    var which: [run_all_commands_max]u32 = undefined;
    var fds_count: u32 = 0;
    for (children, open, 0..) |child, is_open, index| {
        if (!is_open) continue;
        fds[fds_count] = .{ .fd = child.?.out, .events = linux.POLL.IN, .revents = 0 };
        which[fds_count] = @intCast(index);
        fds_count += 1;
    }
    if (fds_count == 0) return false;
    // The deadline may have passed since the caller looked: then the wait is over
    const now = os.now_us();
    if (now >= deadline) return false;
    const waited = linux.poll(&fds, fds_count, @intCast((deadline - now) / 1000 + 1));
    if (failed(waited)) return true; // Interrupted by a signal
    if (waited == 0) return false;
    for (fds[0..fds_count], which[0..fds_count]) |f, index| {
        if (f.revents == 0) continue;
        const buffer = outs[index][lens[index].?..];
        const got = if (buffer.len == 0) 0 else linux.read(f.fd, buffer.ptr, buffer.len);
        if (failed(got) or got == 0) {
            open[index] = false;
            continue;
        }
        lens[index] = lens[index].? + @as(u32, @intCast(got)); // At most the buffer left
        assert(lens[index].? <= outs[index].len);
    }
    return true;
}

/// Waits for a child to exit until `deadline`, then kills its whole group. For
/// `sh -c`, the stuck program is the shell's child. True when it exited in time.
fn reap(pid: i32, deadline: u64) bool {
    assert(pid > 0); // So -pid is its group, not every process
    var status: i32 = 0;
    // Bounded by the deadline
    while (linux.waitpid(pid, &status, linux.W.NOHANG) == 0) {
        if (os.now_us() >= deadline) {
            _ = linux.kill(-pid, linux.SIG.KILL); // Already gone: then there's nothing to stop
            _ = linux.waitpid(pid, &status, 0); // Reaped, whatever its status
            return false;
        }
        os.sleep_ms(reap_poll_ms);
    }
    return true;
}

/// A spawned child's state, without waiting: null while it runs, then whether it
/// exited cleanly (status 0). Reaps it once it's done.
pub fn exited(pid: i32) ?bool {
    assert(pid > 0);
    var status: i32 = 0;
    const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
    if (rc == 0) return null;
    if (failed(rc)) return false;
    assert(rc == @as(u32, @intCast(pid))); // The child asked about
    const status_bits: u32 = @bitCast(status);
    return linux.W.IFEXITED(status_bits) and linux.W.EXITSTATUS(status_bits) == 0;
}

/// Stops a spawned child and everything it started, and reaps it.
pub fn stop(pid: i32) void {
    assert(pid > 0); // So -pid is its group, not every process
    _ = linux.kill(-pid, linux.SIG.KILL); // Already gone: then there's nothing to stop
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0); // Reaped, whatever its status
}

/// Runs `check(ctx)` in a child process and says whether it returned true there. For
/// trying something that could crash (a font file of unknown quality, say): only the
/// child dies. Under the scenario tests' fake, it runs here instead.
pub fn survives(ctx: anytype, comptime check: fn (@TypeOf(ctx)) bool) bool {
    if (fake != null) return check(ctx);
    const pid = linux.fork();
    if (failed(pid)) return false;
    if (pid == 0) linux.exit(if (check(ctx)) 0 else 1);
    assert(pid <= std.math.maxInt(i32)); // A process id
    const deadline = os.now_us() + 5 * 1_000_000;
    while (os.now_us() < deadline) {
        if (exited(@intCast(pid))) |ok| return ok;
        os.sleep_ms(reap_poll_ms);
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
