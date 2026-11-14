//! The kernel's input events: what a touch panel or a key sends, and how a device
//! is opened and asked about its range.
const std = @import("std");
const linux = @import("../../sys/calls.zig");
const failed = @import("../../sys/os.zig").failed;

/// One event as the kernel hands it over.
pub const InputEvent = extern struct { sec: u32, usec: u32, kind: u16, code: u16, value: i32 };

// The Paperwhite 12th gen's devices, used when nothing else is found
pub const touch_device = "/dev/input/event1";
pub const power_device = "/dev/input/event0";

// ioctl requests
pub const eviocgrab: u32 = 0x40044590; // Take a device's events for ourselves
pub const eviocsclockid: u32 = 0x400445a0; // Which clock stamps the events
pub const eviocgabs_x: u32 = 0x80184540 + 0x35; // An axis's range
pub const eviocgabs_y: u32 = 0x80184540 + 0x36;
pub const eviocgmtslots: u32 = 0x800c450a; // Every touch slot's value of an axis

// Event kinds and codes
pub const ev_key = 1;
pub const ev_abs = 3;
pub const key_power = 116;
pub const abs_mt_slot = 0x2f;
pub const abs_mt_x = 0x35;
pub const abs_mt_y = 0x36;
pub const abs_mt_tracking = 0x39;

pub fn open_input(path: [*:0]const u8) !i32 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return error.InputOpen;
    const fd: i32 = @intCast(rc);
    var clock: i32 = 1; // CLOCK_MONOTONIC, so event times compare with now_us
    _ = linux.ioctl(fd, eviocsclockid, @intFromPtr(&clock));
    return fd;
}

pub fn axis_max(fd: i32, req: u32) i32 {
    var info = std.mem.zeroes([6]i32);
    _ = linux.ioctl(fd, req, @intFromPtr(&info));
    return @max(info[2], 1);
}

/// Current position of a multitouch axis in both slots.
pub fn slot_values(fd: i32, code: u32) [2]i32 {
    var request = [_]i32{ @intCast(code), 0, 0 };
    _ = linux.ioctl(fd, eviocgmtslots, @intFromPtr(&request));
    return .{ request[1], request[2] };
}
