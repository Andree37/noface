//! The system calls noface makes, under Linux's names. On Linux (the Kindle, and the
//! tests on GitHub) they are Linux's own, made directly, exactly as before. Anywhere
//! else (a Mac running the tests) the same names go through the C library, and
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
pub const O = chosen.O;
pub const waitpid = chosen.waitpid;
pub const SIG = chosen.SIG;
pub const kill = chosen.kill;
pub const pollfd = chosen.pollfd;
pub const POLL = chosen.POLL;
pub const poll = chosen.poll;
pub const F = chosen.F;
pub const fcntl = chosen.fcntl;

/// Makes reads of `fd` return at once when nothing's there, instead of waiting: false
/// when it couldn't be (its flags unread, or not set).
pub fn set_nonblocking(fd: i32) bool {
    assert(fd >= 0);
    const flags = fcntl(fd, F.GETFL, 0);
    if (failed(flags)) return false; // Unknown flags aren't set over
    const nonblocking: u32 = if (is_linux)
        @bitCast(linux.O{ .NONBLOCK = true })
    else
        @bitCast(std.c.O{ .NONBLOCK = true });
    assert(nonblocking != 0);
    return !failed(fcntl(fd, F.SETFL, flags | nonblocking));
}
pub const unlink = chosen.unlink;
pub const rename = chosen.rename;
pub const fsync = chosen.fsync;
pub const symlink = chosen.symlink;
pub const mkdir = chosen.mkdir;
pub const getpid = chosen.getpid;
pub const ioctl = chosen.ioctl;
pub const Sigaction = chosen.Sigaction;
pub const sigaction = chosen.sigaction;

pub const Facts = portable.Facts;

/// The size and change time of the file open on `fd`, or null if it can't be read.
pub const facts = if (is_linux) facts_linux else portable.facts;

/// The size and change time of the file at `path`, or null if it isn't there: read
/// without opening it, which on the user drive's FUSE file system costs a round trip.
pub const facts_at = if (is_linux) facts_at_linux else portable.facts_at;

fn facts_linux(fd: i32) ?Facts {
    assert(fd >= 0);
    return statx_facts(fd, "", linux.AT.EMPTY_PATH);
}

fn facts_at_linux(path: [*:0]const u8) ?Facts {
    assert(path[0] != 0);
    return statx_facts(linux.AT.FDCWD, path, 0);
}

/// Read with statx, which the kernel lays out the same on every architecture (Linux
/// 4.11 and later; the Kindle runs 5.15), so nothing here depends on which one.
fn statx_facts(fd: i32, path: [*:0]const u8, flags: u32) ?Facts {
    var st: linux.Statx = undefined;
    const mask: linux.STATX = .{ .SIZE = true, .MTIME = true };
    const rc = linux.statx(fd, path, flags, mask, &st);
    if (failed(rc)) return null;
    const result: Facts = .{ .size = st.size, .modified_s = st.mtime.sec };
    assert(result.size == st.size);
    return result;
}

test "a file's size and change time" {
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
    try std.testing.expectEqual(got, facts_at(path) orelse return error.NoFacts);
    // Written just now: within a day of the clock, whatever the file system's rounding
    var now: timespec = undefined;
    _ = clock_gettime(.REALTIME, &now);
    try std.testing.expect(@abs(got.modified_s - now.sec) < 86400);
}

/// The most names read from one folder. noface's folders hold far fewer: a folder
/// with more is listed only this far.
const entries_max = 1 << 20;

/// The names in a folder, each passed to `each` with whether it's a folder (without
/// "." and ".."). Linux reads them with getdents64; elsewhere the C library's readdir.
/// Whether every name was: false when the folder couldn't be opened or read to its
/// end, which a caller that acts on what's missing from it must not take for empty.
pub fn each_entry(
    dir: [*:0]const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) bool {
    assert(dir[0] != 0);
    // `each` keeps what it's given through the context, so it must point somewhere
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer);
    if (is_linux) return each_entry_linux(dir, context, each);
    return each_entry_libc(dir, context, each);
}

/// A struct linux_dirent64, as getdents64 writes them: its inode (u64), offset (i64),
/// record length (u16), type (u8), then its name.
const dirent_reclen_at = 16;
const dirent_type_at = 18;
const dirent_name_at = 19;
/// A folder's type in a dirent (DT_DIR), on Linux and the C libraries alike.
const dirent_type_folder = 4;
/// What one getdents64 call reads into: many names, at least one.
const dirents_bytes = 4096;

comptime {
    assert(dirent_name_at == dirent_type_at + 1);
    assert(dirent_type_at == dirent_reclen_at + 2);
}

fn each_entry_linux(
    dir: [*:0]const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) bool {
    comptime assert(is_linux);
    assert(dir[0] != 0);
    const rc = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return false;
    const fd: i32 = @intCast(rc);
    // Ignored: only read
    defer _ = linux.close(fd);
    var buffer: [dirents_bytes]u8 align(8) = undefined;
    // Each read gives at least one name, so this many reads list every name allowed
    for (0..entries_max) |_| {
        const got = linux.getdents64(fd, &buffer, buffer.len);
        if (got == 0) return true; // The end: every name passed on
        if (failed(got)) return false;
        assert(got <= buffer.len);
        if (!each_entry_linux_records(buffer[0..got], context, each)) return false;
    }
    return false; // More names than are read
}

/// Passes on each name in what getdents64 read. False when a record is damaged.
fn each_entry_linux_records(
    records: []const u8,
    context: anytype,
    comptime each: fn (@TypeOf(context), []const u8, bool) void,
) bool {
    assert(records.len > 0);
    assert(records.len <= dirents_bytes);
    var at: u32 = 0;
    while (at < records.len) {
        if (at + dirent_name_at > records.len) return false;
        const record_len = std.mem.readInt(u16, records[at + dirent_reclen_at ..][0..2], .little);
        if (record_len < dirent_name_at or at + record_len > records.len) return false;
        const is_dir = records[at + dirent_type_at] == dirent_type_folder;
        const name = std.mem.sliceTo(records[at + dirent_name_at .. at + record_len], 0);
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
) bool {
    comptime assert(!is_linux);
    assert(dir[0] != 0);
    const stream = c.opendir(dir) orelse return false;
    // Ignored: only read from: a close that fails loses nothing
    defer _ = c.closedir(stream);
    for (0..entries_max) |_| {
        // Its end and an error both read as none: told apart by errno, cleared first
        std.c._errno().* = 0;
        const entry = c.readdir(stream) orelse {
            if (std.c._errno().* != 0) return false; // Cut short: not the whole listing
            break;
        };
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (is_listed(name)) each(context, name, entry.type == dirent_type_folder);
    } else return false; // More names than are read
    return true;
}

/// Whether a folder's entry is a name to pass on: not "." or "..".
fn is_listed(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    return true;
}
