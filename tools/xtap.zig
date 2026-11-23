//! Taps the stock Kindle UI, for timing and recording it beside noface. The stock UI
//! holds the touch panel to itself, so fake panel events (touchsim) never reach it;
//! this asks its X server to fake a press instead, through the XTEST extension.
//! Speaks just enough of the X protocol for that, over the local socket.
//! Usage: xtap <x> <y>
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const linux = std.os.linux;

const socket_path = "/tmp/.X11-unix/X0";

/// X requests give their length in 4-byte units.
const request_unit_size = 4;
const setup_request_size = 12;
const query_extension_size = 16;
const query_extension_opcode = 98;
const get_input_focus_opcode = 43;
const xtest_fake_input_minor = 2;
const fake_input_size = 36;
const reply_size = 32;
/// XTEST FakeInput's event types, X's core event codes.
const button_press = 4;
const button_release = 5;
const motion_notify = 6;
/// How long the faked button stays down.
const press_ms = 40;

comptime {
    assert(setup_request_size % request_unit_size == 0);
    assert(query_extension_size % request_unit_size == 0);
    assert(fake_input_size % request_unit_size == 0);
}

fn write_all(fd: i32, bytes: []const u8) !void {
    assert(fd >= 0);
    assert(bytes.len > 0);
    var done: u32 = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (core.os.failed(n) or n == 0) return error.WriteFailed;
        done += @intCast(n);
    }
    assert(done == bytes.len);
}

fn read_exact(fd: i32, buffer: []u8) !void {
    assert(fd >= 0);
    assert(buffer.len > 0);
    var done: u32 = 0;
    while (done < buffer.len) {
        const n = linux.read(fd, buffer[done..].ptr, buffer.len - done);
        if (core.os.failed(n) or n == 0) return error.ReadFailed;
        done += @intCast(n);
    }
    assert(done == buffer.len);
}

/// One faked event: what happens, which button (0 for a motion), and where.
const FakeInput = struct { kind: u8, detail: u8, x: i16, y: i16 };

/// One XTEST FakeInput request, to the extension at `opcode`.
fn fake_input(fd: i32, opcode: u8, input: FakeInput) !void {
    assert(input.kind == button_press or input.kind == button_release or
        input.kind == motion_notify);
    // A motion moves the pointer to (x, y) absolutely; a button event names its button.
    if (input.kind == motion_notify) assert(input.detail == 0) else assert(input.detail > 0);
    var request: [fake_input_size]u8 = @splat(0);
    request[0] = opcode;
    request[1] = xtest_fake_input_minor;
    std.mem.writeInt(u16, request[2..4], fake_input_size / request_unit_size, .little);
    request[4] = input.kind;
    request[5] = input.detail;
    // Time 0 (now) and root 0 (the screen's) stay zero
    std.mem.writeInt(i16, request[24..26], input.x, .little);
    std.mem.writeInt(i16, request[26..28], input.y, .little);
    try write_all(fd, &request);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;
    const x = try std.fmt.parseInt(i16, std.mem.sliceTo(argv[1], 0), 10);
    const y = try std.fmt.parseInt(i16, std.mem.sliceTo(argv[2], 0), 10);

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (core.os.failed(rc)) return error.NoSocket;
    const fd: i32 = @intCast(rc);
    // Ignored: the socket's work is done or failed by now
    defer _ = linux.close(fd);
    var address = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[0..socket_path.len], socket_path);
    const connected = linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un));
    if (core.os.failed(connected)) return error.NoServer;

    // Connection setup: little-endian, protocol 11.0, no authorisation
    var setup: [setup_request_size]u8 = @splat(0);
    setup[0] = 'l';
    std.mem.writeInt(u16, setup[2..4], 11, .little);
    try write_all(fd, &setup);
    var head: [8]u8 = undefined;
    try read_exact(fd, &head);
    const rest_size = @as(u32, std.mem.readInt(u16, head[6..8], .little)) * request_unit_size;
    const rest = try std.heap.page_allocator.alloc(u8, rest_size);
    // A refusal can come with nothing more to read.
    if (rest.len > 0) try read_exact(fd, rest);
    if (head[0] != 1) return error.Refused;

    // QueryExtension "XTEST" for its opcode
    const name = "XTEST";
    var query: [query_extension_size]u8 = @splat(0);
    query[0] = query_extension_opcode;
    std.mem.writeInt(u16, query[2..4], query_extension_size / request_unit_size, .little);
    std.mem.writeInt(u16, query[4..6], name.len, .little);
    @memcpy(query[8..][0..name.len], name);
    try write_all(fd, &query);
    var reply: [reply_size]u8 = undefined;
    try read_exact(fd, &reply);
    if (reply[0] != 1 or reply[8] == 0) return error.NoXtest;
    const opcode = reply[9];

    const down_us = core.os.now_us();
    try fake_input(fd, opcode, .{ .kind = motion_notify, .detail = 0, .x = x, .y = y });
    try fake_input(fd, opcode, .{ .kind = button_press, .detail = 1, .x = x, .y = y });
    core.os.sleep_ms(press_ms);
    try fake_input(fd, opcode, .{ .kind = button_release, .detail = 1, .x = x, .y = y });

    // A round trip (GetInputFocus) so everything is handled before closing
    var sync: [request_unit_size]u8 = .{ get_input_focus_opcode, 0, 1, 0 };
    try write_all(fd, &sync);
    try read_exact(fd, &reply);
    std.debug.print("touch {d} {d}\n", .{ down_us, core.os.now_us() });
}
