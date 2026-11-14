//! The system calls noface makes, under Linux's names. On Linux (the Kindle, and the
//! tests on GitHub) they are Linux's own, made directly, exactly as before. Anywhere
//! else (a Mac running the simulator) the same names go through the C library, and
//! report errors the way Linux does: as values in the top 4096 of the range, so
//! `os.failed` reads both alike. Only what noface uses is here.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const c = std.c;

pub const is_linux = builtin.os.tag == .linux;

const portable = @import("calls_portable.zig");

const chosen = if (is_linux) linux else portable;

pub const open = chosen.open;
pub const close = chosen.close;
pub const read = chosen.read;
pub const write = chosen.write;
pub const off_t = chosen.off_t;
pub const SEEK = chosen.SEEK;
/// 32-bit Linux seeks with llseek; 64-bit Linux has only lseek, which is wide enough.
pub const llseek = if (!is_linux or @sizeOf(usize) == 4) chosen.llseek else lseek64;

fn lseek64(fd: i32, offset: u64, result: *linux.off_t, whence: usize) usize {
    const rc = linux.lseek(fd, @bitCast(offset), @intCast(whence));
    if (rc > std.math.maxInt(usize) - 4096) return rc;
    result.* = @intCast(rc);
    return 0;
}
pub const mmap = chosen.mmap;
pub const munmap = chosen.munmap;
pub const timespec = chosen.timespec;
pub const clock_gettime = chosen.clock_gettime;
pub const nanosleep = chosen.nanosleep;
pub const fork = chosen.fork;
pub const execve = chosen.execve;
pub const exit = chosen.exit;
pub const pipe2 = chosen.pipe2;
pub const dup = chosen.dup;
pub const dup2 = chosen.dup2;
pub const setpgid = chosen.setpgid;
pub const W = chosen.W;
pub const waitpid = chosen.waitpid;
pub const SIG = chosen.SIG;
pub const kill = chosen.kill;
pub const pollfd = chosen.pollfd;
pub const POLL = chosen.POLL;
pub const poll = chosen.poll;
pub const F = chosen.F;
pub const fcntl = chosen.fcntl;
pub const unlink = chosen.unlink;
pub const rename = chosen.rename;
pub const mkdir = chosen.mkdir;
pub const getpid = chosen.getpid;
pub const ioctl = chosen.ioctl;
pub const Sigaction = chosen.Sigaction;
pub const sigaction = chosen.sigaction;

/// The names in a folder, each passed to `each` with whether it's a folder (without
/// "." and ".."). Linux reads them with getdents64; elsewhere the C library's readdir.
pub fn each_entry(dir: [*:0]const u8, ctx: anytype, comptime each: fn (@TypeOf(ctx), []const u8, bool) void) void {
    if (is_linux) {
        const rc = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
        if (rc > std.math.maxInt(usize) - 4096) return;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var buf: [4096]u8 align(8) = undefined;
        while (true) {
            const got = linux.getdents64(fd, &buf, buf.len);
            if (got == 0 or got > std.math.maxInt(usize) - 4096) break;
            var at: usize = 0;
            while (at < got) {
                // struct linux_dirent64: inode u64, offset i64, record length u16, type u8, name
                const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
                if (reclen == 0 or at + reclen > got) return;
                const is_dir = buf[at + 18] == 4;
                const name = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
                at += reclen;
                if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                each(ctx, name, is_dir);
            }
        }
    } else {
        const d = c.opendir(dir) orelse return;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |entry| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            each(ctx, name, entry.type == 4); // DT_DIR
        }
    }
}
