//! What the launcher (src/launch.zig) needs from Linux beyond what the app uses:
//! leaving its caller behind, starting a program with its output in a file, waking
//! for signals without missing one, and finding processes by name, as busybox's
//! `killall` and `pidof` do. Linux only, made directly: the launcher runs on the
//! Kindle alone, and only the pure helpers here are tested on a computer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const os = @import("os.zig");
const calls = @import("calls.zig");
const file = @import("file.zig");

const failed = os.failed;

pub const Side = enum { parent, child };

/// The most processes looked at by name: a Kindle runs a couple of hundred.
const processes_max = 4096;
/// How much of a process's command line is read: its program and first arguments.
const cmdline_bytes_max = 1024;
/// The kernel keeps a process's name to 15 characters (`comm`).
const comm_length_max = 15;

comptime {
    assert(cmdline_bytes_max > comm_length_max);
}

/// Forks. The child leaves its caller's session and terminal, reads nothing, and
/// writes to `log`, appended (to /dev/null when that can't be opened, so a closed
/// pipe of the caller's can never end it). The parent carries on as the caller.
pub fn detach(log: [*:0]const u8) !Side {
    assert(log[0] == '/');
    const pid = linux.fork();
    if (failed(pid)) return error.ForkFailed;
    if (pid != 0) return .parent;
    // Ignored: A fresh child is never a group leader, so this can't fail
    _ = linux.setsid();
    redirect(0, "/dev/null", false);
    redirect(1, log, true);
    redirect(2, log, true);
    assert(linux.getpid() > 0);
    return .child;
}

/// Points `target` (0, 1 or 2) at `path`: read, or appended to. Falls back to
/// /dev/null, so the descriptor is never left pointing at the caller's.
fn redirect(target: i32, path: [*:0]const u8, append: bool) void {
    assert(target >= 0);
    assert(target <= 2);
    const flags: linux.O = if (append)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
    else
        .{ .ACCMODE = .RDONLY };
    var rc = linux.open(path, flags, 0o644);
    if (failed(rc)) rc = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (failed(rc)) return; // No /dev/null: nothing better to point it at
    const fd: i32 = @intCast(rc);
    if (fd == target) return;
    _ = linux.dup2(fd, target); // Ignored: failing leaves the old one, which is all there is
    _ = linux.close(fd); // Ignored: the copy stays open as `target`
}

/// Starts `argv` with `envp`, its output appended to (or written over) the file at
/// `output`, and its errors there too when `errors_too`; else they go where ours go.
/// Null when it couldn't be started.
pub fn spawn_to_file(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    output: [*:0]const u8,
    how: enum { append, replace },
    errors_too: bool,
) ?i32 {
    assert(argv[0] != null);
    assert(output[0] == '/');
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = how == .append,
        .TRUNC = how == .replace,
        .CLOEXEC = true,
    };
    const opened = linux.open(output, flags, 0o644);
    if (failed(opened)) return null;
    const fd: i32 = @intCast(opened);
    const pid = linux.fork();
    if (pid == 0) {
        // Ignored: the copies dup2 makes lose close-on-exec, so the program writes to them
        _ = linux.dup2(fd, 1);
        // Ignored: already 1, the file kept close-on-exec, which would lose what it writes
        if (fd == 1) _ = linux.fcntl(1, linux.F.SETFD, 0);
        // Ignored: the copies dup2 makes lose close-on-exec, so the program writes to them
        if (errors_too) _ = linux.dup2(fd, 2);
        _ = linux.execve(argv[0].?, argv, envp); // Ignored: returns only on failure
        linux.exit(127);
    }
    _ = linux.close(fd); // Ignored: the child holds its own copy
    if (failed(pid)) return null;
    assert(pid > 0);
    assert(pid <= std.math.maxInt(i32));
    return @intCast(pid);
}

/// Wake-ups: a signal handler writes a byte to a pipe, which the waiting side polls,
/// so a signal arriving just before a wait still ends it.
/// Null when it couldn't be made: the waiting side looks every second instead.
var wake_pipe: ?[2]i32 = null;
/// Set by INT, TERM or HUP; read and cleared by `take_stop_request`.
var stop_requested = std.atomic.Value(bool).init(false);

fn on_signal(signal: linux.SIG) callconv(.c) void {
    if (signal != .CHLD) stop_requested.store(true, .release);
    const pipe = wake_pipe orelse return;
    const byte = [1]u8{0};
    // Ignored: full pipe: a wake-up is already waiting, which is all a byte says
    _ = linux.write(pipe[1], &byte, 1);
}

/// Catches INT, TERM and HUP (a request to stop) and CHLD (a child ended), so
/// `wait_for_wake` returns for them. False when the wake-up pipe can't be made: the
/// requests are still caught, and `take_stop_request` still sees them.
pub fn listen_for_signals() bool {
    assert(wake_pipe == null); // Once
    var pipe: [2]i32 = undefined;
    const piped = !failed(linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true }));
    // Made before any handler is, so a handler sees it whole or not at all
    if (piped) wake_pipe = pipe;
    var action = std.mem.zeroes(linux.Sigaction);
    action.handler = .{ .handler = on_signal };
    action.flags = linux.SA.NOCLDSTOP | linux.SA.RESTART;
    for ([_]linux.SIG{ .CHLD, .INT, .TERM, .HUP }) |signal| {
        const rc = linux.sigaction(signal, &action, null);
        // Only KILL and STOP can't be caught, and a handler of ours is a valid address
        assert(!failed(rc));
    }
    return piped;
}

/// Waits up to `timeout_ms` for a signal, then empties the wake-up pipe.
pub fn wait_for_wake(timeout_ms: u32) void {
    const pipe = wake_pipe.?; // Waited on only once `listen_for_signals` made it
    assert(timeout_ms <= std.math.maxInt(i32));
    var fds = [_]linux.pollfd{.{ .fd = pipe[0], .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&fds, 1, @intCast(timeout_ms)); // Ignored: interrupted or timed out: look anyway
    var drain: [64]u8 = undefined;
    // The pipe is non-blocking and holds at most a few pages of wake-ups
    for (0..1024) |_| {
        const got = linux.read(pipe[0], &drain, drain.len);
        if (failed(got) or got < drain.len) break;
    }
}

/// Whether a stop was asked for since the last look.
pub fn take_stop_request() bool {
    return stop_requested.swap(false, .acq_rel);
}

/// Whether a process is the program `name`: its kernel name (`comm`, cut to 15
/// characters) or the last part of its first argument, as busybox's killall decides.
pub fn is_named(comm: []const u8, cmdline: []const u8, name: []const u8) bool {
    assert(name.len > 0);
    assert(std.mem.indexOfScalar(u8, name, '/') == null);
    const short = name[0..@min(name.len, comm_length_max)];
    if (std.mem.eql(u8, std.mem.trimEnd(u8, comm, "\n"), short)) return true;
    const program = std.mem.sliceTo(cmdline, 0);
    const slash = std.mem.lastIndexOfScalar(u8, program, '/');
    const base = if (slash) |at| program[at + 1 ..] else program;
    return std.mem.eql(u8, base, name);
}

/// The process ids listed in /proc, apart from our own.
const Pids = struct {
    ids: [processes_max]i32 = undefined,
    count: u32 = 0,
    own: i32,

    fn add(pids: *Pids, name: []const u8, is_dir: bool) void {
        assert(pids.count <= processes_max);
        if (!is_dir or pids.count == processes_max) return;
        const id = std.fmt.parseInt(i32, name, 10) catch return; // Not a process
        if (id <= 0 or id == pids.own) return;
        pids.ids[pids.count] = id;
        pids.count += 1;
    }
};

/// A process's command line, its arguments split by zero bytes, as much as fits.
pub fn read_cmdline(pid: i32, buffer: []u8) []const u8 {
    assert(pid > 0);
    assert(buffer.len > 0);
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/cmdline", .{pid}, 0) catch
        return "";
    return file.read_small(path, buffer);
}

/// Calls `each(context, pid, cmdline)` for every running process named `name`, but
/// this one. Returns how many there were.
pub fn each_named(
    name: []const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), i32, []const u8) void,
) u32 {
    assert(name.len > 0);
    var pids: Pids = .{ .own = linux.getpid() };
    // Ignored: /proc lists what runs now; one missed has ended or is looked for again
    _ = calls.each_entry("/proc", &pids, Pids.add);
    var found: u32 = 0;
    for (pids.ids[0..pids.count]) |pid| {
        var comm_buffer: [32]u8 = undefined;
        var path_buffer: [32]u8 = undefined;
        const comm_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch
            continue;
        const comm = file.read_small(comm_path, &comm_buffer);
        var cmdline_buffer: [cmdline_bytes_max]u8 = undefined;
        const cmdline = read_cmdline(pid, &cmdline_buffer);
        if (!is_named(comm, cmdline, name)) continue;
        each(context, pid, cmdline);
        found += 1;
    }
    assert(found <= pids.count);
    return found;
}

/// Sends `signal` to every process named `name`, as `killall -SIGNAL name`.
pub fn signal_named(name: []const u8, signal: linux.SIG) u32 {
    assert(name.len > 0);
    const send = struct {
        fn send(wanted: *const linux.SIG, pid: i32, _: []const u8) void {
            assert(pid > 0);
            _ = linux.kill(pid, wanted.*); // Ignored: ended since it was found: nothing to signal
        }
    }.send;
    const count = each_named(name, &signal, send);
    assert(count <= processes_max);
    return count;
}

test "processes are found by their kernel name or their program's name" {
    try std.testing.expect(is_named("awesome\n", "awesome\x00-c\x00x", "awesome"));
    try std.testing.expect(is_named("x\n", "/usr/bin/jobman\x00", "jobman"));
    try std.testing.expect(is_named("lipc-wait-event\n", "", "lipc-wait-event"));
    try std.testing.expect(!is_named("awesome-x\n", "/bin/awesome-x\x00", "awesome"));
    try std.testing.expect(!is_named("sh\n", "sh\x00/mnt/us/awesome\x00", "awesome"));
}
