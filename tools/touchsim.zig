//! Sends fake touches to the panel's input device, for testing on the Kindle.
//! Usage: touchsim tap <x> <y>
//!        touchsim drag <x0> <y0> <x1> <y1> <steps> <delay-ms> [hold-ms]
const std = @import("std");
const core = @import("core");
const sleep_ms = core.os.sleep_ms;
const linux = std.os.linux;

const InputEvent = extern struct { sec: u32 = 0, usec: u32 = 0, kind: u16, code: u16, value: i32 };

const ev_syn = 0;
const ev_key = 1;
const touch_major = 0x30;
const btn_touch = 0x14a; // "A finger is down": the stock UI waits for it, noface doesn't need it
const ev_abs = 3;
const slot = 0x2f;
const pos_x = 0x35;
const pos_y = 0x36;
const tracking = 0x39;

var fd: i32 = -1;
var next_id: i32 = 9000;

fn send(kind: u16, code: u16, value: i32) void {
    var e = InputEvent{ .kind = kind, .code = code, .value = value };
    _ = linux.write(fd, @ptrCast(&e), @sizeOf(InputEvent));
}

fn down(x: i32, y: i32) void {
    send(ev_abs, slot, 0);
    send(ev_abs, tracking, next_id);
    next_id += 1;
    send(ev_abs, pos_x, x);
    send(ev_abs, pos_y, y);
    send(ev_abs, touch_major, 8); // A fingertip's contact size, as the panel sends
    send(ev_key, btn_touch, 1);
    send(ev_syn, 0, 0);
}

fn move(x: i32, y: i32) void {
    send(ev_abs, pos_x, x);
    send(ev_abs, pos_y, y);
    send(ev_syn, 0, 0);
}

fn up() void {
    send(ev_abs, tracking, -1);
    send(ev_key, btn_touch, 0);
    send(ev_syn, 0, 0);
}

fn arg(v: [*:0]const u8) i32 {
    return std.fmt.parseInt(i32, std.mem.sliceTo(v, 0), 10) catch 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len < 4) return error.Usage;
    fd = @intCast(linux.open("/dev/input/event1", .{ .ACCMODE = .WRONLY }, 0));
    if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "tap")) {
        const t_down = core.os.now_us();
        down(arg(argv[2]), arg(argv[3]));
        sleep_ms(40);
        up();
        // When it touched and lifted, on fbrec's clock, for timing what follows
        std.debug.print("touch {d} {d}\n", .{ t_down, core.os.now_us() });
        return;
    }
    const x0 = arg(argv[2]);
    const y0 = arg(argv[3]);
    const x1 = arg(argv[4]);
    const y1 = arg(argv[5]);
    const steps = arg(argv[6]);
    const delay: u64 = @intCast(arg(argv[7]));
    down(x0, y0);
    if (argv.len > 8) sleep_ms(@intCast(arg(argv[8]))); // Press before moving, to start a hold
    var i: i32 = 1;
    while (i <= steps) : (i += 1) {
        sleep_ms(delay);
        move(x0 + @divTrunc((x1 - x0) * i, steps), y0 + @divTrunc((y1 - y0) * i, steps));
    }
    sleep_ms(delay);
    up();
    std.debug.print("lift {d}\n", .{core.os.now_us()});
}
