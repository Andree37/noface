//! Sends fake touches to the panel's input device, for testing on the Kindle.
//! Usage: touchsim tap <x> <y>
//!        touchsim drag <x0> <y0> <x1> <y1> <steps> <delay-ms> [hold-ms]
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const sleep_ms = core.os.sleep_ms;
const linux = std.os.linux;

/// The kernel's `input_event` on 32-bit ARM.
const InputEvent = extern struct { sec: u32 = 0, usec: u32 = 0, kind: u16, code: u16, value: i32 };

const ev_syn = 0;
const ev_key = 1;
const ev_abs = 3;
const btn_touch = 0x14a; // "A finger is down": the stock UI waits for it, noface doesn't need it
const abs_mt_touch_major = 0x30;
const abs_mt_slot = 0x2f;
const abs_mt_position_x = 0x35;
const abs_mt_position_y = 0x36;
const abs_mt_tracking_id = 0x39;
/// A fingertip's contact size, as the panel sends.
const touch_major_fingertip = 8;
/// The first finger's id: far from the panel's own, so the app sees a new finger.
const tracking_id_first = 9000;
/// How long a tap's finger stays down.
const tap_ms = 40;

comptime {
    assert(@sizeOf(InputEvent) == 16);
    assert(abs_mt_position_y == abs_mt_position_x + 1);
    // A finger's id is never negative while it's down: -1 lifts it.
    assert(tracking_id_first > 0);
}

/// The panel's input device, open for writing, and the finger we press on it.
const Panel = struct {
    fd: i32,
    tracking_id_next: i32 = tracking_id_first,
    finger_down: bool = false,

    fn send(panel: *const Panel, kind: u16, code: u16, value: i32) void {
        assert(panel.fd >= 0);
        assert(kind == ev_syn or kind == ev_key or kind == ev_abs);
        var event = InputEvent{ .kind = kind, .code = code, .value = value };
        _ = linux.write(panel.fd, @ptrCast(&event), @sizeOf(InputEvent));
    }

    fn down(panel: *Panel, x: i32, y: i32) void {
        assert(!panel.finger_down);
        assert(panel.tracking_id_next >= tracking_id_first);
        panel.send(ev_abs, abs_mt_slot, 0);
        panel.send(ev_abs, abs_mt_tracking_id, panel.tracking_id_next);
        panel.tracking_id_next += 1;
        panel.send(ev_abs, abs_mt_position_x, x);
        panel.send(ev_abs, abs_mt_position_y, y);
        panel.send(ev_abs, abs_mt_touch_major, touch_major_fingertip);
        panel.send(ev_key, btn_touch, 1);
        panel.send(ev_syn, 0, 0);
        panel.finger_down = true;
        assert(panel.tracking_id_next > tracking_id_first);
    }

    fn move(panel: *const Panel, x: i32, y: i32) void {
        assert(panel.finger_down);
        panel.send(ev_abs, abs_mt_position_x, x);
        panel.send(ev_abs, abs_mt_position_y, y);
        panel.send(ev_syn, 0, 0);
    }

    fn up(panel: *Panel) void {
        assert(panel.finger_down);
        assert(panel.tracking_id_next > tracking_id_first);
        panel.send(ev_abs, abs_mt_tracking_id, -1);
        panel.send(ev_key, btn_touch, 0);
        panel.send(ev_syn, 0, 0);
        panel.finger_down = false;
    }
};

/// A number from the command line, or 0 when it isn't one.
fn parse_argument(argument: [*:0]const u8) i32 {
    return std.fmt.parseInt(i32, std.mem.sliceTo(argument, 0), 10) catch 0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len < 4) return error.Usage;
    const rc = linux.open("/dev/input/event1", .{ .ACCMODE = .WRONLY }, 0);
    if (core.os.failed(rc)) return error.NoTouchPanel;
    var panel = Panel{ .fd = @intCast(rc) };
    if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "tap")) {
        const down_us = core.os.now_us();
        panel.down(parse_argument(argv[2]), parse_argument(argv[3]));
        sleep_ms(tap_ms);
        panel.up();
        // When it touched and lifted, on fbrec's clock, for timing what follows
        std.debug.print("touch {d} {d}\n", .{ down_us, core.os.now_us() });
        return;
    }
    if (argv.len < 8) return error.Usage;
    const x0 = parse_argument(argv[2]);
    const y0 = parse_argument(argv[3]);
    const x1 = parse_argument(argv[4]);
    const y1 = parse_argument(argv[5]);
    const steps = parse_argument(argv[6]);
    const delay_ms: u64 = @intCast(parse_argument(argv[7]));
    panel.down(x0, y0);
    // Press before moving, to start a hold
    if (argv.len > 8) sleep_ms(@intCast(parse_argument(argv[8])));
    var x = x0;
    var y = y0;
    var step: i32 = 1;
    while (step <= steps) : (step += 1) {
        sleep_ms(delay_ms);
        x = x0 + @divTrunc((x1 - x0) * step, steps);
        y = y0 + @divTrunc((y1 - y0) * step, steps);
        panel.move(x, y);
    }
    // The last step lands where the drag ends.
    if (steps > 0) {
        assert(x == x1);
        assert(y == y1);
    }
    sleep_ms(delay_ms);
    panel.up();
    std.debug.print("lift {d}\n", .{core.os.now_us()});
}
