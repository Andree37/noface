//! The system calls noface makes, on systems other than Linux: through the C library,
//! under Linux's names, and reporting errors Linux's way. See calls.zig.
//!
//! Their signatures are Linux's own (std.os.linux), `usize` results and all, so
//! calls.zig can pick either set under the same names.
//!
//! A file descriptor isn't asserted: -1 stands for a device that isn't there (a
//! computer has no touch panel), and a call on it fails harmlessly, as on Linux.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const c = std.c;

// The numbers noface passes on unchanged are the C library's own.
comptime {
    if (builtin.os.tag != .linux) {
        assert(SEEK.SET == c.SEEK.SET);
        assert(SEEK.CUR == c.SEEK.CUR);
        assert(SEEK.END == c.SEEK.END);
        assert(W.NOHANG == c.W.NOHANG);
        for (@typeInfo(SIG).@"enum".field_names) |name| {
            assert(@backingInt(@field(SIG, name)) == @backingInt(@field(c.SIG, name)));
        }
    }
}

/// Linux reports an error as its number negated: a value in the top 4096 of the range.
const errno_max = 4095;

/// A C result as Linux reports it: the value, or the negated errno wrapped around.
fn linux_result(rc: anytype) usize { // usize: Linux's syscall ABI
    // A result is at most C's largest signed value, so it never reads as an error
    if (rc >= 0) return @intCast(rc);
    const errno: u32 = @intCast(c._errno().*);
    assert(errno > 0); // A failure always says why
    assert(errno <= errno_max);
    return @bitCast(-@as(isize, errno));
}

pub const ACCMODE = enum { RDONLY, WRONLY, RDWR };
pub const O = struct {
    ACCMODE: ACCMODE = .RDONLY,
    CREAT: bool = false,
    EXCL: bool = false, // With CREAT: fails when the file is there
    TRUNC: bool = false,
    APPEND: bool = false,
    CLOEXEC: bool = false,
    DIRECTORY: bool = false,
    NONBLOCK: bool = false,
};

fn c_flags(options: O) c.O {
    // Creating or emptying a file is only done to write it, and a folder is only read
    if (options.CREAT) assert(options.ACCMODE != .RDONLY);
    if (options.TRUNC) assert(options.ACCMODE != .RDONLY);
    if (options.EXCL) assert(options.CREAT);
    if (options.DIRECTORY) assert(options.ACCMODE == .RDONLY);
    var flags: c.O = .{};
    flags.ACCMODE = switch (options.ACCMODE) {
        .RDONLY => .RDONLY,
        .WRONLY => .WRONLY,
        .RDWR => .RDWR,
    };
    flags.CREAT = options.CREAT;
    flags.EXCL = options.EXCL;
    flags.TRUNC = options.TRUNC;
    flags.APPEND = options.APPEND;
    flags.CLOEXEC = options.CLOEXEC;
    flags.DIRECTORY = options.DIRECTORY;
    flags.NONBLOCK = options.NONBLOCK;
    return flags;
}

pub fn open(path: [*:0]const u8, flags: O, mode: u32) usize { // usize: Linux's syscall ABI
    assert(path[0] != 0);
    assert(mode <= 0o7777);
    if (!flags.CREAT) assert(mode == 0); // A mode only means something to a new file
    return linux_result(c.open(path, c_flags(flags), @as(c.mode_t, @intCast(mode))));
}
pub fn close(fd: i32) usize { // usize: Linux's syscall ABI
    return linux_result(c.close(fd));
}
pub fn read(fd: i32, buffer: [*]u8, count: usize) usize { // usize: Linux's syscall ABI
    assert(count <= std.math.maxInt(isize)); // C's read returns the count signed
    const rc = c.read(fd, buffer, count);
    assert(rc <= count); // What was read, or -1
    return linux_result(rc);
}
pub fn write(fd: i32, buffer: [*]const u8, count: usize) usize { // usize: Linux's syscall ABI
    assert(count <= std.math.maxInt(isize)); // C's write returns the count signed
    const rc = c.write(fd, buffer, count);
    assert(rc <= count); // What was written, or -1
    return linux_result(rc);
}
// usize: Linux's syscall ABI
pub fn pread(fd: i32, buffer: [*]u8, count: usize, offset: off_t) usize {
    assert(count <= std.math.maxInt(isize)); // C's pread returns the count signed
    assert(offset >= 0);
    return linux_result(c.pread(fd, buffer, count, offset));
}
// usize: Linux's syscall ABI
pub fn pwrite(fd: i32, buffer: [*]const u8, count: usize, offset: off_t) usize {
    assert(count <= std.math.maxInt(isize)); // C's pwrite returns the count signed
    assert(offset >= 0);
    return linux_result(c.pwrite(fd, buffer, count, offset));
}
pub const off_t = i64;
pub const SEEK = struct {
    pub const SET = 0;
    pub const CUR = 1;
    pub const END = 2;
};
// usize: Linux's syscall ABI
pub fn llseek(fd: i32, offset: u64, result: *off_t, whence: usize) usize {
    assert(whence == SEEK.SET or whence == SEEK.CUR or whence == SEEK.END);
    const rc = c.lseek(fd, @bitCast(offset), @intCast(whence));
    if (rc < 0) return linux_result(rc);
    result.* = rc;
    return 0;
}
pub const PROT = struct { READ: bool = false, WRITE: bool = false };
pub const MAP = struct { TYPE: enum { PRIVATE, SHARED } = .PRIVATE };
pub fn mmap(
    address: ?[*]u8,
    len: usize, // usize: Linux's syscall ABI
    protection: PROT,
    flags: MAP,
    fd: i32,
    offset: i64,
) usize { // usize: Linux's syscall ABI
    assert(address == null); // The system chooses where
    assert(len > 0);
    assert(offset >= 0);
    var c_protection: c.PROT = .{};
    c_protection.READ = protection.READ;
    c_protection.WRITE = protection.WRITE;
    var c_map: c.MAP = .{ .TYPE = if (flags.TYPE == .PRIVATE) .PRIVATE else .SHARED };
    _ = &c_map;
    const mapped = c.mmap(@ptrCast(@alignCast(address)), len, c_protection, c_map, fd, offset);
    if (mapped == c.MAP_FAILED) return linux_result(@as(isize, -1));
    return @intFromPtr(mapped);
}
pub fn munmap(address: [*]const u8, len: usize) usize { // usize: Linux's syscall ABI
    assert(len > 0);
    assert(std.mem.isAligned(@intFromPtr(address), std.heap.page_size_min)); // As mmap gave it
    return linux_result(c.munmap(@ptrCast(@alignCast(@constCast(address))), len));
}
pub const timespec = c.timespec;
pub const CLOCK = enum { MONOTONIC, REALTIME };
pub fn clock_gettime(clock: CLOCK, time: *timespec) usize { // usize: Linux's syscall ABI
    const id = if (clock == .MONOTONIC) c.CLOCK.MONOTONIC else c.CLOCK.REALTIME;
    const result = linux_result(c.clock_gettime(id, time));
    // A clock's time is never before its start, nor its nanoseconds a whole second
    if (result == 0) assert(time.sec >= 0);
    if (result == 0) assert(time.nsec >= 0);
    if (result == 0) assert(time.nsec < std.time.ns_per_s);
    return result;
}
// usize: Linux's syscall ABI
pub fn nanosleep(request: *const timespec, remaining: ?*timespec) usize {
    assert(request.sec >= 0);
    assert(request.nsec >= 0);
    assert(request.nsec < std.time.ns_per_s);
    return linux_result(c.nanosleep(request, remaining));
}
pub fn fork() usize { // usize: Linux's syscall ABI
    return linux_result(c.fork());
}
pub fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) usize { // usize: Linux's syscall ABI
    assert(path[0] != 0);
    assert(argv[0] != null); // A program is passed its own name first
    return linux_result(c.execve(path, argv, envp));
}
pub fn exit(code: i32) noreturn {
    assert(code >= 0);
    assert(code <= 255); // All an exit status holds
    c._exit(code);
}
pub fn pipe2(fds: *[2]i32, flags: O) usize { // usize: Linux's syscall ABI
    // Only close-on-exec is passed on
    assert(flags.ACCMODE == .RDONLY);
    assert(!flags.NONBLOCK);
    const rc = c.pipe(fds);
    if (rc < 0) return linux_result(rc);
    assert(fds[0] != fds[1]);
    if (flags.CLOEXEC) {
        for (fds) |fd| {
            // Ignored: on a pipe just made, setting close-on-exec doesn't fail
            _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        }
    }
    return 0;
}
pub fn dup(fd: i32) usize { // usize: Linux's syscall ABI
    return linux_result(c.dup(fd));
}
pub fn dup2(old: i32, new: i32) usize { // usize: Linux's syscall ABI
    assert(new >= 0);
    return linux_result(c.dup2(old, new));
}
pub fn setpgid(pid: i32, pgid: i32) usize { // usize: Linux's syscall ABI
    assert(pid >= 0);
    assert(pgid >= 0);
    return linux_result(c.setpgid(pid, pgid));
}
pub const W = struct {
    pub const NOHANG = 1;
    pub fn IFEXITED(status: u32) bool {
        return status & 0x7f == 0;
    }
    pub fn EXITSTATUS(status: u32) u8 {
        assert(IFEXITED(status)); // Only an exit has a status
        return @intCast((status >> 8) & 0xff);
    }
};
pub fn waitpid(pid: i32, status: *i32, flags: u32) usize { // usize: Linux's syscall ABI
    assert(pid != 0); // A child, or any child (-1), never a group
    assert(flags & ~@as(u32, W.NOHANG) == 0);
    var c_status: c_int = 0;
    const rc = c.waitpid(pid, &c_status, @intCast(flags));
    status.* = c_status;
    return linux_result(rc);
}
pub const SIG = enum(u32) { HUP = 1, INT = 2, KILL = 9, TERM = 15 };
pub fn kill(pid: i32, signal: SIG) usize { // usize: Linux's syscall ABI
    assert(pid != 0); // Not noface's own group
    assert(pid != -1); // Not every process there is
    return linux_result(c.kill(pid, @fromBackingInt(@intCast(@backingInt(signal)))));
}
pub const pollfd = c.pollfd;
pub const POLL = struct {
    pub const IN = c.POLL.IN;
};
pub fn poll(fds: [*]pollfd, count: usize, timeout: i32) usize { // usize: Linux's syscall ABI
    assert(count > 0);
    assert(timeout >= -1); // -1 waits for as long as it takes
    return linux_result(c.poll(fds, @intCast(count), timeout));
}
pub const F = struct {
    pub const GETFL = c.F.GETFL;
    pub const SETFL = c.F.SETFL;
};
pub fn fcntl(fd: i32, command: i32, argument: usize) usize { // usize: Linux's syscall ABI
    assert(command == F.GETFL or command == F.SETFL);
    return linux_result(c.fcntl(fd, command, argument));
}
pub fn unlink(path: [*:0]const u8) usize { // usize: Linux's syscall ABI
    assert(path[0] != 0);
    return linux_result(c.unlink(path));
}
pub fn rename(old: [*:0]const u8, new: [*:0]const u8) usize { // usize: Linux's syscall ABI
    assert(old[0] != 0);
    assert(new[0] != 0);
    return linux_result(c.rename(old, new));
}
pub fn fsync(fd: i32) usize { // usize: Linux's syscall ABI
    return linux_result(c.fsync(fd));
}
// usize: Linux's syscall ABI
pub fn symlink(existing: [*:0]const u8, new: [*:0]const u8) usize {
    assert(existing[0] != 0);
    assert(new[0] != 0);
    return linux_result(c.symlink(existing, new));
}
pub fn mkdir(path: [*:0]const u8, mode: u32) usize { // usize: Linux's syscall ABI
    assert(path[0] != 0);
    assert(mode <= 0o7777);
    return linux_result(c.mkdir(path, @intCast(mode)));
}
/// What noface reads of an open file: its size and when it last changed (calls.zig).
pub const Facts = struct { size: u64, modified_s: i64 };

/// The size and change time of the file open on `fd`, or null if it can't be read.
pub fn facts(fd: i32) ?Facts {
    assert(fd >= 0);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    if (st.size < 0) return null;
    const result: Facts = .{ .size = @intCast(st.size), .modified_s = st.mtime().sec };
    assert(result.size == st.size);
    return result;
}

/// The size and change time of the file at `path`, or null if it isn't there.
pub fn facts_at(path: [*:0]const u8) ?Facts {
    assert(path[0] != 0);
    var st: c.Stat = undefined;
    if (c.stat(path, &st) != 0) return null;
    if (st.size < 0) return null;
    const result: Facts = .{ .size = @intCast(st.size), .modified_s = st.mtime().sec };
    assert(result.size == st.size);
    return result;
}

pub fn getpid() i32 {
    const pid = c.getpid();
    assert(pid > 0);
    return pid;
}
pub fn ioctl(fd: i32, request: u32, argument: usize) usize { // usize: Linux's syscall ABI
    assert(request != 0);
    return linux_result(c.ioctl(fd, @intCast(request), argument));
}
/// Only stopping signals are caught, so a plain handler is all there is.
pub const Sigaction = struct {
    handler: struct { handler: ?*const fn (i32) callconv(.c) void = null } = .{},
};
// usize: Linux's syscall ABI
pub fn sigaction(signal: SIG, action: *const Sigaction, old: ?*Sigaction) usize {
    assert(old == null); // The handler it replaces is never asked for
    assert(signal != .KILL); // KILL can't be caught
    var c_action: c.Sigaction = std.mem.zeroes(c.Sigaction);
    c_action.handler = .{ .handler = action.handler.handler };
    const c_signal: c.SIG = @fromBackingInt(@intCast(@backingInt(signal)));
    return linux_result(c.sigaction(c_signal, &c_action, null));
}
