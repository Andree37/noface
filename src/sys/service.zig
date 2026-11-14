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

const failed = os.failed;

pub const Side = enum { parent, child };

/// The most processes looked at by name: a Kindle runs a couple of hundred.
const processes_max = 4096;
/// How much of a process's command line is read: its program and first arguments.
const cmdline_bytes_max = 1024;
/// The kernel keeps a process's name to 15 characters (`comm`).
const comm_length_max = 15;
/// The largest file `copy_file` copies: Amazon's catalog is a few megabytes.
const copy_bytes_max = 1 << 30;
const copy_chunk_bytes = 1 << 16;

comptime {
    assert(copy_bytes_max % copy_chunk_bytes == 0);
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
    // A fresh child is never a group leader, so this can't fail
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
    _ = linux.dup2(fd, target); // Failing leaves the old one, which is all there is
    _ = linux.close(fd); // The copy stays open as `target`
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
        // The copies dup2 makes lose close-on-exec, so the program writes to them
        _ = linux.dup2(fd, 1);
        // Already 1, the file kept close-on-exec, which would lose what it writes
        if (fd == 1) _ = linux.fcntl(1, linux.F.SETFD, 0);
        if (errors_too) _ = linux.dup2(fd, 2);
        _ = linux.execve(argv[0].?, argv, envp); // Returns only on failure
        linux.exit(127);
    }
    _ = linux.close(fd); // The child holds its own copy
    if (failed(pid)) return null;
    assert(pid > 0);
    assert(pid <= std.math.maxInt(i32));
    return @intCast(pid);
}

/// The status a shell's `$?` gives for a wait status: the exit code, or 128 plus the
/// signal that ended it.
pub fn exit_code(status: u32) u32 {
    const code: u32 = if (linux.W.IFEXITED(status))
        linux.W.EXITSTATUS(status)
    else
        128 + @as(u32, @backingInt(linux.W.TERMSIG(status)));
    assert(code < 256);
    if (status == 0) assert(code == 0);
    return code;
}

/// Waits for a child to end until `deadline` (microseconds, monotonic); then kills
/// it. Its exit code, or null when it ran out of time.
pub fn wait_until(pid: i32, deadline: u64) ?u32 {
    assert(pid > 0);
    var status: i32 = 0;
    // Bounded by the deadline: each look waits a few milliseconds
    while (os.now_us() < deadline) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(u32, @intCast(pid))) return exit_code(@bitCast(status));
        if (failed(rc)) return null; // Not our child, or gone already: nothing to wait for
        os.sleep_ms(20);
    }
    _ = linux.kill(pid, .KILL); // Already gone: then there's nothing to stop
    _ = linux.waitpid(pid, &status, 0); // Reaped, whatever its status
    assert(os.now_us() >= deadline);
    return null;
}

/// Copies the file at `source` to `target`, replacing it. False when it couldn't
/// be copied whole, in which case no partial copy is left.
pub fn copy_file(source: [*:0]const u8, target: [*:0]const u8) bool {
    assert(source[0] == '/');
    assert(target[0] == '/');
    const in_rc = linux.open(source, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(in_rc)) return false;
    const in: i32 = @intCast(in_rc);
    defer _ = linux.close(in); // Only read: nothing is lost if closing fails
    const out_flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const out_rc = linux.open(target, out_flags, 0o644);
    if (failed(out_rc)) return false;
    const out: i32 = @intCast(out_rc);
    var chunk: [copy_chunk_bytes]u8 = undefined;
    var copied: u64 = 0;
    const whole = for (0..copy_bytes_max / copy_chunk_bytes) |_| {
        const got = linux.read(in, &chunk, chunk.len);
        if (failed(got)) break false;
        if (got == 0) break true;
        if (!write_all(out, chunk[0..got])) break false;
        copied += got;
    } else false; // Larger than any catalog
    const closed = !failed(linux.close(out)); // A copy that can't be closed may be short
    if (!whole or !closed) _ = linux.unlink(target); // A partial copy goes
    assert(copied <= copy_bytes_max);
    return whole and closed;
}

fn write_all(fd: i32, data: []const u8) bool {
    assert(fd >= 0);
    var done: u32 = 0;
    // Each write moves at least a byte, or fails
    while (done < data.len) {
        const wrote = linux.write(fd, data[done..].ptr, data.len - done);
        if (failed(wrote) or wrote == 0) return false;
        done += @intCast(wrote);
    }
    assert(done == data.len);
    return true;
}

/// Appends `text` to the file at `path`, as a shell's `echo text >> path` does.
pub fn append_file(path: [*:0]const u8, text: []const u8) void {
    assert(path[0] == '/');
    assert(text.len > 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const rc = linux.open(path, flags, 0o644);
    if (failed(rc)) return; // A log line that can't be written is only a log line
    const fd: i32 = @intCast(rc);
    _ = write_all(fd, text); // Likewise
    _ = linux.close(fd); // Likewise
}

/// Wake-ups: a signal handler writes a byte to a pipe, which the waiting side polls,
/// so a signal arriving just before a wait still ends it.
var wake_pipe: [2]i32 = .{ -1, -1 };
/// Set by INT, TERM or HUP; read and cleared by `take_stop_request`.
var stop_requested = std.atomic.Value(bool).init(false);

fn on_signal(signal: linux.SIG) callconv(.c) void {
    if (signal != .CHLD) stop_requested.store(true, .release);
    if (wake_pipe[1] < 0) return; // No pipe: the waiting side looks every second instead
    const byte = [1]u8{0};
    // Full pipe: a wake-up is already waiting, which is all a byte says
    _ = linux.write(wake_pipe[1], &byte, 1);
}

/// Catches INT, TERM and HUP (a request to stop) and CHLD (a child ended), so
/// `wait_for_wake` returns for them. False when the wake-up pipe can't be made: the
/// requests are still caught, and `take_stop_request` still sees them.
pub fn listen_for_signals() bool {
    assert(wake_pipe[0] == -1); // Once
    const piped = !failed(linux.pipe2(&wake_pipe, .{ .CLOEXEC = true, .NONBLOCK = true }));
    if (!piped) wake_pipe = .{ -1, -1 };
    var action = std.mem.zeroes(linux.Sigaction);
    action.handler = .{ .handler = on_signal };
    action.flags = linux.SA.NOCLDSTOP | linux.SA.RESTART;
    for ([_]linux.SIG{ .CHLD, .INT, .TERM, .HUP }) |signal| {
        const rc = linux.sigaction(signal, &action, null);
        // Only KILL and STOP can't be caught, and a handler of ours is a valid address
        assert(!failed(rc));
    }
    if (piped) assert(wake_pipe[0] >= 0);
    return piped;
}

/// Waits up to `timeout_ms` for a signal, then empties the wake-up pipe.
pub fn wait_for_wake(timeout_ms: u32) void {
    assert(wake_pipe[0] >= 0);
    assert(timeout_ms <= std.math.maxInt(i32));
    var fds = [_]linux.pollfd{.{ .fd = wake_pipe[0], .events = linux.POLL.IN, .revents = 0 }};
    _ = linux.poll(&fds, 1, @intCast(timeout_ms)); // Interrupted or timed out: look anyway
    var drain: [64]u8 = undefined;
    // The pipe is non-blocking and holds at most a few pages of wake-ups
    for (0..1024) |_| {
        const got = linux.read(wake_pipe[0], &drain, drain.len);
        if (failed(got) or got < drain.len) break;
    }
}

/// Whether a stop was asked for since the last look.
pub fn take_stop_request() bool {
    const asked = stop_requested.swap(false, .acq_rel);
    // Both ends of the wake-up pipe are made, or neither
    assert((wake_pipe[0] == -1) == (wake_pipe[1] == -1));
    return asked;
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
    return read_small(path, buffer);
}

fn read_small(path: [*:0]const u8, buffer: []u8) []const u8 {
    assert(path[0] == '/');
    assert(buffer.len > 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return ""; // Gone since it was listed
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Only read: nothing is lost if closing fails
    const got = linux.read(fd, buffer.ptr, buffer.len);
    if (failed(got)) return "";
    return buffer[0..got];
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
    calls.each_entry("/proc", &pids, Pids.add);
    var found: u32 = 0;
    for (pids.ids[0..pids.count]) |pid| {
        var comm_buffer: [32]u8 = undefined;
        var path_buffer: [32]u8 = undefined;
        const comm_path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch
            continue;
        const comm = read_small(comm_path, &comm_buffer);
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
            _ = linux.kill(pid, wanted.*); // Ended since it was found: nothing to signal
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
