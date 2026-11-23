//! The kernel's input events: what a touch panel or a key sends, and how a device
//! is opened and asked about its range.
const std = @import("std");
const assert = std.debug.assert;
const linux = @import("../../sys/calls.zig");
const failed = @import("../../sys/os.zig").failed;

/// One event as the kernel hands it over.
pub const InputEvent = extern struct { sec: u32, usec: u32, kind: u16, code: u16, value: i32 };

// The Paperwhite 12th gen's devices, used when nothing else is found
pub const touch_device = "/dev/input/event1";
pub const power_device = "/dev/input/event0";

// The ioctl requests
pub const eviocgrab: u32 = 0x40044590; // Take a device's events for ourselves
pub const eviocsclockid: u32 = 0x400445a0; // Which clock stamps the events
pub const eviocgabs_x: u32 = 0x80184540 + 0x35; // An axis's range
pub const eviocgabs_y: u32 = 0x80184540 + 0x36;
pub const eviocgmtslots: u32 = 0x800c450a; // Every touch slot's value of an axis

// Event kinds and codes
pub const ev_syn = 0; // A packet's end
pub const ev_key = 1;
pub const btn_touch = 0x14a; // A finger is down: the stock UI waits for it
pub const abs_mt_touch_major = 0x30; // A contact's size
pub const ev_abs = 3;
pub const key_power = 116;
pub const abs_mt_slot = 0x2f;
pub const abs_mt_x = 0x35;
pub const abs_mt_y = 0x36;
pub const abs_mt_tracking = 0x39;

/// The axis info EVIOCGABS fills: value, minimum, maximum, fuzz, flat, resolution.
const AxisInfo = [6]i32;

comptime {
    // The kernel's struct is 16 bytes: two u32 stamps, two u16s and an i32
    assert(@sizeOf(InputEvent) == 16);
    // EVIOCGABS(axis) is its base plus the axis code, and carries the struct's size
    assert(eviocgabs_x - abs_mt_x == eviocgabs_y - abs_mt_y);
    assert((eviocgabs_x >> 16) & 0x3fff == @sizeOf(AxisInfo));
    // EVIOCGMTSLOTS here asks for a code and two slots' values: three i32s
    assert((eviocgmtslots >> 16) & 0x3fff == 3 * @sizeOf(i32));
    assert(abs_mt_slot < abs_mt_x);
    assert(abs_mt_x < abs_mt_y);
    assert(abs_mt_y < abs_mt_tracking);
    assert(ev_key != ev_abs);
}

pub fn open_input(path: [*:0]const u8) !i32 {
    assert(path[0] == '/');
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
    if (failed(rc)) return error.InputOpen;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    var clock: i32 = 1; // CLOCK_MONOTONIC, so event times compare with now_us
    // Ignored: A device that keeps its own clock still works; its times are only less exact
    _ = linux.ioctl(fd, eviocsclockid, @intFromPtr(&clock));
    return fd;
}

pub fn axis_max(fd: i32, request: u32) i32 {
    assert(fd >= 0);
    assert(request == eviocgabs_x or request == eviocgabs_y);
    var info = std.mem.zeroes(AxisInfo);
    // Ignored: on failure `info` stays zeroed, and the floor of one below still gives a range
    _ = linux.ioctl(fd, request, @intFromPtr(&info));
    const maximum = @max(info[2], 1);
    assert(maximum >= 1);
    return maximum;
}

/// Current position of a multitouch axis in both slots.
pub fn slot_values(fd: i32, code: u32) [2]i32 {
    assert(fd >= 0);
    assert(code == abs_mt_x or code == abs_mt_y);
    var request = [_]i32{ @intCast(code), 0, 0 };
    // Ignored: on failure both slots read zero, as no touch would
    _ = linux.ioctl(fd, eviocgmtslots, @intFromPtr(&request));
    return .{ request[1], request[2] };
}
