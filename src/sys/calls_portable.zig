//! noface's system calls on systems other than Linux, through the C library, under
//! Linux's names and reporting errors Linux's way. See sys.zig.
const std = @import("std");
const c = std.c;

/// A C result as Linux reports it: the value, or the negated errno wrapped around.
fn ret(rc: anytype) usize {
    if (rc >= 0) return @intCast(rc);
    const e: usize = @intCast(c._errno().*);
    return 0 -% e;
}

pub const ACCMODE = enum { RDONLY, WRONLY, RDWR };
pub const O = struct {
    ACCMODE: ACCMODE = .RDONLY,
    CREAT: bool = false,
    TRUNC: bool = false,
    APPEND: bool = false,
    CLOEXEC: bool = false,
    DIRECTORY: bool = false,
    NONBLOCK: bool = false,
};

fn cFlags(o: O) c.O {
    var f: c.O = .{};
    f.ACCMODE = switch (o.ACCMODE) {
        .RDONLY => .RDONLY,
        .WRONLY => .WRONLY,
        .RDWR => .RDWR,
    };
    f.CREAT = o.CREAT;
    f.TRUNC = o.TRUNC;
    f.APPEND = o.APPEND;
    f.CLOEXEC = o.CLOEXEC;
    f.DIRECTORY = o.DIRECTORY;
    f.NONBLOCK = o.NONBLOCK;
    return f;
}

pub fn open(path: [*:0]const u8, flags: O, mode: u32) usize {
    return ret(c.open(path, cFlags(flags), @as(c.mode_t, @intCast(mode))));
}
pub fn close(fd: i32) usize {
    return ret(c.close(fd));
}
pub fn read(fd: i32, buf: [*]u8, n: usize) usize {
    return ret(c.read(fd, buf, n));
}
pub fn write(fd: i32, buf: [*]const u8, n: usize) usize {
    return ret(c.write(fd, buf, n));
}
pub const off_t = i64;
pub const SEEK = struct {
    pub const SET = 0;
    pub const CUR = 1;
    pub const END = 2;
};
pub fn llseek(fd: i32, offset: u64, result: *off_t, whence: usize) usize {
    const rc = c.lseek(fd, @bitCast(offset), @intCast(whence));
    if (rc < 0) return ret(rc);
    result.* = rc;
    return 0;
}
pub const PROT = struct { READ: bool = false, WRITE: bool = false };
pub const MAP = struct { TYPE: enum { PRIVATE, SHARED } = .PRIVATE };
pub fn mmap(addr: ?[*]u8, len: usize, prot: PROT, flags: MAP, fd: i32, offset: i64) usize {
    var p: c.PROT = .{};
    p.READ = prot.READ;
    p.WRITE = prot.WRITE;
    var m: c.MAP = .{ .TYPE = if (flags.TYPE == .PRIVATE) .PRIVATE else .SHARED };
    _ = &m;
    const r = c.mmap(@ptrCast(@alignCast(addr)), len, p, m, fd, offset);
    if (r == c.MAP_FAILED) return ret(@as(isize, -1));
    return @intFromPtr(r);
}
pub fn munmap(addr: [*]const u8, len: usize) usize {
    return ret(c.munmap(@ptrCast(@alignCast(@constCast(addr))), len));
}
pub const timespec = c.timespec;
pub const CLOCK = enum { MONOTONIC, REALTIME };
pub fn clock_gettime(clock: CLOCK, ts: *timespec) usize {
    return ret(c.clock_gettime(if (clock == .MONOTONIC) c.CLOCK.MONOTONIC else c.CLOCK.REALTIME, ts));
}
pub fn nanosleep(req: *const timespec, rem: ?*timespec) usize {
    return ret(c.nanosleep(req, rem));
}
pub fn fork() usize {
    return ret(c.fork());
}
pub fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) usize {
    return ret(c.execve(path, argv, envp));
}
pub fn exit(code: i32) noreturn {
    c._exit(code);
}
pub fn pipe2(fds: *[2]i32, flags: O) usize {
    const rc = c.pipe(fds);
    if (rc < 0) return ret(rc);
    if (flags.CLOEXEC) for (fds) |fd| {
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    };
    return 0;
}
pub fn dup(fd: i32) usize {
    return ret(c.dup(fd));
}
pub fn dup2(old: i32, new: i32) usize {
    return ret(c.dup2(old, new));
}
pub fn setpgid(pid: i32, pgid: i32) usize {
    return ret(c.setpgid(pid, pgid));
}
pub const W = struct {
    pub const NOHANG = 1;
    pub fn IFEXITED(s: u32) bool {
        return s & 0x7f == 0;
    }
    pub fn EXITSTATUS(s: u32) u8 {
        return @intCast((s >> 8) & 0xff);
    }
};
pub fn waitpid(pid: i32, status: *i32, flags: u32) usize {
    var s: c_int = 0;
    const rc = c.waitpid(pid, &s, @intCast(flags));
    status.* = s;
    return ret(rc);
}
pub const SIG = enum(u32) { HUP = 1, INT = 2, KILL = 9, TERM = 15 };
pub fn kill(pid: i32, sig: SIG) usize {
    return ret(c.kill(pid, @fromBackingInt(@intCast(@backingInt(sig)))));
}
pub const pollfd = c.pollfd;
pub const POLL = struct {
    pub const IN = c.POLL.IN;
};
pub fn poll(fds: [*]pollfd, n: usize, timeout: i32) usize {
    return ret(c.poll(fds, @intCast(n), timeout));
}
pub const F = struct {
    pub const GETFL = c.F.GETFL;
    pub const SETFL = c.F.SETFL;
};
pub fn fcntl(fd: i32, cmd: i32, arg: usize) usize {
    return ret(c.fcntl(fd, cmd, arg));
}
pub fn unlink(path: [*:0]const u8) usize {
    return ret(c.unlink(path));
}
pub fn rename(old: [*:0]const u8, new: [*:0]const u8) usize {
    return ret(c.rename(old, new));
}
pub fn mkdir(path: [*:0]const u8, mode: u32) usize {
    return ret(c.mkdir(path, @intCast(mode)));
}
pub fn getpid() i32 {
    return c.getpid();
}
pub fn ioctl(fd: i32, request: u32, arg: usize) usize {
    return ret(c.ioctl(fd, @intCast(request), arg));
}
/// Only stopping signals are caught, so a plain handler is all there is.
pub const Sigaction = struct { handler: struct { handler: ?*const fn (i32) callconv(.c) void = null } = .{} };
pub fn sigaction(sig: SIG, act: *const Sigaction, old: ?*Sigaction) usize {
    _ = old;
    var a: c.Sigaction = std.mem.zeroes(c.Sigaction);
    a.handler = .{ .handler = act.handler.handler };
    return ret(c.sigaction(@fromBackingInt(@intCast(@backingInt(sig))), &a, null));
}
