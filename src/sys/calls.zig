//! The system calls noface makes, under Linux's names. On Linux (the Kindle, and the
//! tests on GitHub) they are Linux's own, made directly, exactly as before. Anywhere
//! else (a Mac running the simulator) the same names go through the C library, and
//! report errors the way Linux does: as values in the top 4096 of the range, so
//! `os.failed` reads both alike. Only what noface uses is here.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const c = std.c;
const failed = @import("os.zig").failed;

pub const is_linux = builtin.os.tag == .linux;

const portable = @import("calls_portable.zig");

const chosen = if (is_linux) linux else portable;

pub const open = chosen.open;
pub const close = chosen.close;
pub const read = chosen.read;
pub const write = chosen.write;
pub const pread = chosen.pread;
pub const pwrite = chosen.pwrite;
pub const off_t = chosen.off_t;
pub const SEEK = chosen.SEEK;
/// 32-bit Linux seeks with llseek; 64-bit Linux has only lseek, which is wide enough.
pub const llseek = if (!is_linux or builtin.target.ptrBitWidth() == 32) chosen.llseek else lseek64;

/// The lseek call under llseek's signature, for 64-bit Linux.
// usize: Linux's syscall ABI
fn lseek64(fd: i32, offset: u64, result: *linux.off_t, whence: usize) usize {
    assert(whence == SEEK.SET or whence == SEEK.CUR or whence == SEEK.END);
    const rc = linux.lseek(fd, @bitCast(offset), @intCast(whence));
    if (failed(rc)) return rc;
    result.* = @intCast(rc);
    assert(result.* >= 0); // An offset is never before the file's start
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

pub const Facts = portable.Facts;

/// The size and change time of the file open on `fd`, or null if it can't be read.
pub const facts = if (is_linux) facts_linux else portable.facts;

/// Bytes free to an unprivileged writer on the file system holding `path`, or null if
/// it can't be read.
pub const free_bytes = if (is_linux) free_bytes_linux else portable.free_bytes;

/// What fstat fills, as the kernel lays it out: `struct stat64` on 32-bit ARM
/// (arch/arm/include/uapi/asm/stat.h, EABI alignment), `struct stat` on x86-64
/// (arch/x86/include/uapi/asm/stat.h) and on 64-bit ARM (asm-generic/stat.h). Zig's
/// std has no fstat for Linux, so these are written out, and their sizes and the
/// places of what's read checked against the kernel's below.
const KernelStat = switch (builtin.cpu.arch) {
    .arm, .thumb => extern struct {
        dev: u64,
        pad0: [4]u8,
        ino_low: u32,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        pad3: [4]u8,
        size: i64,
        blksize: u32,
        blocks: u64,
        atime: u32,
        atime_nsec: u32,
        mtime: u32,
        mtime_nsec: u32,
        ctime: u32,
        ctime_nsec: u32,
        ino: u64,
    },
    .x86_64 => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atime: i64,
        atime_nsec: i64,
        mtime: i64,
        mtime_nsec: i64,
        ctime: i64,
        ctime_nsec: i64,
        unused: [3]i64,
    },
    .aarch64 => extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        pad1: u64,
        size: i64,
        blksize: i32,
        pad2: i32,
        blocks: i64,
        atime: i64,
        atime_nsec: u64,
        mtime: i64,
        mtime_nsec: u64,
        ctime: i64,
        ctime_nsec: u64,
        unused: [2]u32,
    },
    else => @compileError("noface reads fstat on ARM, x86-64 and 64-bit ARM only"),
};

/// What statfs fills: `struct statfs64` on 32-bit ARM (asm-generic/statfs.h, packed
/// to 4-byte alignment by arch/arm/include/uapi/asm/statfs.h: 84 bytes, a size the
/// kernel checks), `struct statfs` of 64-bit words on the 64-bit ones.
const KernelStatfs = if (builtin.target.ptrBitWidth() == 32) extern struct {
    kind: u32,
    block_bytes: u32,
    blocks: u64 align(4),
    blocks_free: u64 align(4),
    blocks_available: u64 align(4),
    files: u64 align(4),
    files_free: u64 align(4),
    fsid: [2]i32,
    name_bytes_max: u32,
    fragment_bytes: u32,
    flags: u32,
    spare: [4]u32,
} else extern struct {
    kind: i64,
    block_bytes: i64,
    blocks: u64,
    blocks_free: u64,
    blocks_available: u64,
    files: u64,
    files_free: u64,
    fsid: [2]i32,
    name_bytes_max: i64,
    fragment_bytes: i64,
    flags: i64,
    spare: [4]i64,
};

comptime {
    // The kernel's layouts, as its headers give them
    if (is_linux) {
        switch (builtin.cpu.arch) {
            .arm, .thumb => {
                assert(@sizeOf(KernelStat) == 104);
                assert(@offsetOf(KernelStat, "size") == 48);
                assert(@offsetOf(KernelStat, "mtime") == 80);
                assert(@sizeOf(KernelStatfs) == 84);
                assert(@offsetOf(KernelStatfs, "blocks_available") == 24);
            },
            .x86_64 => {
                assert(@sizeOf(KernelStat) == 144);
                assert(@offsetOf(KernelStat, "size") == 48);
                assert(@offsetOf(KernelStat, "mtime") == 88);
            },
            .aarch64 => {
                assert(@sizeOf(KernelStat) == 128);
                assert(@offsetOf(KernelStat, "size") == 48);
                assert(@offsetOf(KernelStat, "mtime") == 88);
            },
            else => {},
        }
        if (builtin.target.ptrBitWidth() == 64) {
            assert(@sizeOf(KernelStatfs) == 120);
            assert(@offsetOf(KernelStatfs, "blocks_available") == 32);
        }
    }
}

fn facts_linux(fd: i32) ?Facts {
    assert(fd >= 0);
    var st: KernelStat = undefined;
    const number = if (builtin.target.ptrBitWidth() == 32) linux.SYS.fstat64 else linux.SYS.fstat;
    const rc = linux.syscall2(number, @as(u32, @bitCast(fd)), @intFromPtr(&st));
    if (failed(rc)) return null;
    if (st.size < 0) return null;
    const result: Facts = .{ .size = @intCast(st.size), .modified_s = st.mtime };
    assert(result.size == st.size);
    return result;
}

/// Read with statfs64 on 32-bit ARM, given its struct's size, statfs on 64-bit.
fn free_bytes_linux(path: [*:0]const u8) ?u64 {
    assert(path[0] != 0);
    var fs: KernelStatfs = undefined;
    const rc = if (builtin.target.ptrBitWidth() == 32)
        linux.syscall3(.statfs64, @intFromPtr(path), @sizeOf(KernelStatfs), @intFromPtr(&fs))
    else
        linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&fs));
    if (failed(rc)) return null;
    if (fs.block_bytes < 0) return null;
    const block_bytes: u64 = @intCast(fs.block_bytes);
    return std.math.mul(u64, block_bytes, fs.blocks_available) catch std.math.maxInt(u64);
}

test "a file's size and change time, and the room left beside it" {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/noface-facts-{d}", .{
        getpid(),
    }, 0);
    const rc = open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    try std.testing.expect(!failed(rc));
    const fd: i32 = @intCast(rc);
    defer _ = unlink(path);
    defer _ = close(fd);
    try std.testing.expectEqual(@as(usize, 5), write(fd, "hello", 5));
    const got = facts(fd) orelse return error.NoFacts;
    try std.testing.expectEqual(@as(u64, 5), got.size);
    // Written just now: within a day of the clock, whatever the file system's rounding
    var now: timespec = undefined;
    _ = clock_gettime(.REALTIME, &now);
    try std.testing.expect(@abs(got.modified_s - now.sec) < 86400);
    try std.testing.expect((free_bytes("/tmp") orelse 0) > 5);
    try std.testing.expect(free_bytes("/no/such/folder") == null);
}

/// The most names read from one folder. noface's folders hold far fewer: a folder
/// with more is listed only this far.
const entries_max = 1 << 20;

/// The names in a folder, each passed to `each` with whether it's a folder (without
/// "." and ".."). Linux reads them with getdents64; elsewhere the C library's readdir.
pub fn each_entry(
    dir: [*:0]const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) void {
    assert(dir[0] != 0);
    // `each` keeps what it's given through the context, so it must point somewhere
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer);
    if (is_linux) {
        each_entry_linux(dir, context, each);
    } else {
        each_entry_libc(dir, context, each);
    }
}

fn each_entry_linux(
    dir: [*:0]const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) void {
    comptime assert(is_linux);
    assert(dir[0] != 0);
    const rc = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buffer: [4096]u8 align(8) = undefined;
    // Each read gives at least one name, so this many reads list every name allowed
    for (0..entries_max) |_| {
        const got = linux.getdents64(fd, &buffer, buffer.len);
        if (got == 0 or failed(got)) break;
        assert(got <= buffer.len);
        if (!each_entry_linux_records(buffer[0..got], context, each)) return;
    }
}

/// Passes on each name in what getdents64 read. False when a record is damaged.
fn each_entry_linux_records(
    records: []const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) bool {
    assert(records.len > 0);
    assert(records.len <= 4096);
    var at: u32 = 0;
    while (at < records.len) {
        // A struct linux_dirent64: inode u64, offset i64, record length u16, type u8, name
        if (at + 19 > records.len) return false;
        const record_len = std.mem.readInt(u16, records[at + 16 ..][0..2], .little);
        if (record_len < 19 or at + record_len > records.len) return false;
        const is_dir = records[at + 18] == 4; // DT_DIR
        const name = std.mem.sliceTo(records[at + 19 .. at + record_len], 0);
        at += record_len;
        if (is_listed(name)) each(context, name, is_dir);
    }
    assert(at == records.len);
    return true;
}

fn each_entry_libc(
    dir: [*:0]const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) void {
    comptime assert(!is_linux);
    assert(dir[0] != 0);
    const stream = c.opendir(dir) orelse return;
    defer _ = c.closedir(stream);
    for (0..entries_max) |_| {
        const entry = c.readdir(stream) orelse break;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (is_listed(name)) each(context, name, entry.type == 4); // DT_DIR
    }
}

/// Whether a folder's entry is a name to pass on: not "." or "..".
fn is_listed(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    return true;
}
