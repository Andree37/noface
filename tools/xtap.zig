//! Taps the stock Kindle UI, for timing and recording it beside noface. The stock UI
//! holds the touch panel to itself, so fake panel events (touchsim) never reach it;
//! this asks its X server to fake a press instead, through the XTEST extension.
//! Speaks just enough of the X protocol for that, over the local socket.
//! Usage: xtap <x> <y>
const std = @import("std");
const core = @import("core");
const linux = std.os.linux;

const socket_path = "/tmp/.X11-unix/X0";

fn write_all(fd: i32, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        if (core.os.failed(n) or n == 0) return error.WriteFailed;
        done += n;
    }
}

fn read_exact(fd: i32, buf: []u8) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = linux.read(fd, buf[done..].ptr, buf.len - done);
        if (core.os.failed(n) or n == 0) return error.ReadFailed;
        done += n;
    }
}

/// One XTEST FakeInput request: an event of `kind` with `detail`, at (x, y).
fn fake_input(fd: i32, opcode: u8, kind: u8, detail: u8, x: i16, y: i16) !void {
    var req: [36]u8 = @splat(0);
    req[0] = opcode;
    req[1] = 2; // X_XTestFakeInput
    std.mem.writeInt(u16, req[2..4], 9, .little); // Length in 4-byte units
    req[4] = kind;
    req[5] = detail;
    // time 0 (now) and root 0 (the screen's) stay zero
    std.mem.writeInt(i16, req[24..26], x, .little);
    std.mem.writeInt(i16, req[26..28], y, .little);
    try write_all(fd, &req);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;
    const x = try std.fmt.parseInt(i16, std.mem.sliceTo(argv[1], 0), 10);
    const y = try std.fmt.parseInt(i16, std.mem.sliceTo(argv[2], 0), 10);

    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (core.os.failed(rc)) return error.NoSocket;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    if (core.os.failed(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un)))) return error.NoServer;

    // Connection setup: little-endian, protocol 11.0, no authorisation
    var setup: [12]u8 = @splat(0);
    setup[0] = 'l';
    std.mem.writeInt(u16, setup[2..4], 11, .little);
    try write_all(fd, &setup);
    var head: [8]u8 = undefined;
    try read_exact(fd, &head);
    const rest = @as(usize, std.mem.readInt(u16, head[6..8], .little)) * 4;
    const extra = try std.heap.page_allocator.alloc(u8, rest);
    try read_exact(fd, extra);
    if (head[0] != 1) return error.Refused;

    // QueryExtension "XTEST" for its opcode
    const name = "XTEST";
    var query: [16]u8 = @splat(0);
    query[0] = 98;
    std.mem.writeInt(u16, query[2..4], 4, .little);
    std.mem.writeInt(u16, query[4..6], name.len, .little);
    @memcpy(query[8..][0..name.len], name);
    try write_all(fd, &query);
    var reply: [32]u8 = undefined;
    try read_exact(fd, &reply);
    if (reply[0] != 1 or reply[8] == 0) return error.NoXtest;
    const opcode = reply[9];

    const t_down = core.os.now_us();
    try fake_input(fd, opcode, 6, 0, x, y); // Motion there, absolute
    try fake_input(fd, opcode, 4, 1, x, y); // Button 1 down
    core.os.sleep_ms(40);
    try fake_input(fd, opcode, 5, 1, x, y); // Button 1 up

    // A round trip (GetInputFocus) so everything is handled before closing
    var sync: [4]u8 = .{ 43, 0, 1, 0 };
    try write_all(fd, &sync);
    try read_exact(fd, &reply);
    std.debug.print("touch {d} {d}\n", .{ t_down, core.os.now_us() });
}
