//! The simulator, noface-sim: noface on a computer, in a browser. The real app runs, on
//! a screen in memory and the pretend Kindle the scenario tests use (so nothing is
//! started and nothing on the computer is changed outside its folder), and a small web
//! server on this computer shows the screen and turns clicks into taps.
//!
//!   zig build sim                    the test book
//!   zig build sim -Dbooks=~/Books    the EPUBs in a folder
//!
//! Then open http://localhost:8080. Click to tap, press and hold to hold a word, drag
//! sideways to turn a page, drag down from the top for the light panel. What noface
//! saves (positions, settings, stats) goes in ./noface-sim-data.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("app.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const input_mod = @import("kindle/input.zig");
const decoder_memory = @import("gfx/decoder_memory.zig");
const memory = @import("base/memory.zig");
const wifi_saver = @import("kindle/wifi_saver.zig");
const setup = @import("setup.zig");
const library_screen = @import("screens/library.zig");
const FakeKindle = @import("testing/fake_kindle.zig").FakeKindle;
const sys = @import("sys/calls.zig");
const os = @import("sys/os.zig");
const c = std.c;

const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
const test_book = @embedFile("testdata/scenario.epub");

const width_px = 1272;
const height_px = 1696;

/// Its own folder for what noface keeps.
const data = "noface-sim-data";

const port_default = 8080;

/// How many bytes of an HTTP request are read: its first line is all that's used.
const request_bytes_max = 2048;

/// The screen as a BMP: its file header, its info header, then a palette of 256 grays.
const bmp_palette_bytes = 256 * 4;
const bmp_pixels_offset = 14 + 40 + bmp_palette_bytes;
const bmp_size_bytes = bmp_pixels_offset + width_px * height_px;

comptime {
    // The page shows the screen at its own shape, and maps clicks back to its pixels
    @setEvalBranchQuota(100_000);
    const aspect = std.fmt.comptimePrint("aspect-ratio:{d}/{d}", .{ width_px, height_px });
    assert(std.mem.indexOf(u8, page, aspect) != null);
    assert(std.mem.indexOf(u8, page, std.fmt.comptimePrint("* {d} /", .{width_px})) != null);
    assert(std.mem.indexOf(u8, page, std.fmt.comptimePrint("* {d} /", .{height_px})) != null);
    // A BMP's sizes are 32 bits
    assert(bmp_size_bytes <= std.math.maxInt(u32));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.smp_allocator;
    const port = main_port(init);
    const books = try main_books(init.args.vector);
    // No Amazon books: only the EPUBs
    try write_file(data ++ "/library.tsv", "\n");

    // The pretend Kindle answers the system; the Wi-Fi saver's note stays in the folder
    var fake = try FakeKindle.init(alloc);
    fake.clock = local_clock;
    // A computer is on its charger, and full
    try fake.put("com.lab126.powerd battLevel", "100");
    try fake.put("com.lab126.powerd usbState", "1");
    fake.install();
    wifi_saver.use_data_dir(data);

    var app_budget = memory.Budget{ .name = "app", .child = alloc, .limit = 512 << 20 };
    var decoders_budget = memory.Budget{ .name = "decoders", .child = alloc, .limit = 256 << 20 };
    decoder_memory.use(&decoders_budget);
    const a_alloc = app_budget.allocator();

    var screen = try hwtcon.Screen.fake(a_alloc, width_px, height_px);
    assert(screen.pixels.len == width_px * height_px); // As the server sends it
    var pipe: [2]i32 = undefined;
    if (os.failed(sys.pipe2(&pipe, .{ .CLOEXEC = true }))) return error.NoPipe;
    var input = input_mod.Input{
        .touch = -1,
        .power = -1,
        .width = width_px,
        .height = height_px,
        .x_max = width_px,
        .y_max = height_px,
        .remote = pipe[0],
    };

    var kit = try setup.Kit.init(a_alloc, .{
        .book = go_regular,
        .book_bold = go_bold,
        .ui = go_regular,
        .ui_bold = go_bold,
    });
    var files: setup.DataFiles = .{};
    try files.init(data);
    var a = try setup.assemble(.{
        .alloc = a_alloc,
        .app_budget = &app_budget,
        .decoders_budget = &decoders_budget,
        .screen = &screen,
        .input = &input,
        .kit = &kit,
        .data_dir = data,
        .files = &files,
        .library_path = data ++ "/library.tsv",
    });
    a.documents = books;
    // Every typeface is the Go font: the Kindle's own aren't on a computer
    for (&a.face_files) |*family| family.* = .{ go_regular, go_bold, go_regular, go_bold };
    try a.apply_settings();

    var server = Server{ .screen = &screen, .actions = pipe[1], .port = port };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    thread.detach();
    std.debug.print("noface-sim: open http://localhost:{d}  (books from {s})\n", .{ port, books });

    try library_screen.run_library(&a);
}

/// The port to serve on: NOFACE_SIM_PORT, or 8080.
fn main_port(init: std.process.Init.Minimal) u16 {
    comptime assert(port_default > 1024); // One a user may open
    const text = init.environ.getPosix("NOFACE_SIM_PORT") orelse return port_default;
    return std.fmt.parseInt(u16, text, 10) catch port_default;
}

/// The data folder made, and the books' folder: a folder given, or the test book.
fn main_books(args: []const [*:0]const u8) ![]const u8 {
    assert(args.len >= 1); // The program's own name comes first
    _ = sys.mkdir(data, 0o755);
    if (args.len >= 2) return std.mem.sliceTo(args[1], 0);
    const dir = data ++ "/books";
    _ = sys.mkdir(dir, 0o755);
    try write_file(dir ++ "/Scenario Book.epub", test_book);
    comptime assert(dir.len > data.len); // Inside the data folder
    return dir;
}

extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(t: *const i64, out: *anyopaque) ?*anyopaque;
// usize: C's size_t
extern "c" fn strftime(buf: [*]u8, max: usize, format: [*:0]const u8, tm: *const anyopaque) usize;

/// The computer's local time, as the Kindle's `date +"%H:%M - %d %b %Y"` prints it.
fn local_clock(out: []u8) u32 {
    var now = time(null);
    var tm: [128]u8 align(16) = undefined; // A struct tm, of whatever size this system's is
    _ = localtime_r(&now, &tm) orelse return 0;
    const written = strftime(out.ptr, out.len, "%H:%M - %d %b %Y", &tm);
    assert(written <= out.len); // Zero when it doesn't fit, never more
    return @intCast(written);
}

fn write_file(path: [*:0]const u8, bytes: []const u8) !void {
    assert(bytes.len > 0); // Each file the simulator writes has something in it
    const rc = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (os.failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    defer _ = sys.close(fd);
    _ = sys.write(fd, bytes.ptr, bytes.len);
}

/// The web page and the screen, on localhost only.
const Server = struct {
    screen: *hwtcon.Screen,
    actions: i32, // Write end of the input pipe
    port: u16,

    fn run(s: *Server) void {
        assert(s.actions >= 0); // The pipe was made before the server started
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return;
        var yes: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.mem.zeroes(c.sockaddr.in);
        if (@hasField(c.sockaddr.in, "len")) addr.len = @sizeOf(c.sockaddr.in);
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, s.port);
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001); // 127.0.0.1
        const bound = c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) == 0;
        if (!bound or c.listen(fd, 8) != 0) {
            std.debug.print("noface-sim: port {d} is taken; set NOFACE_SIM_PORT\n", .{s.port});
            return;
        }
        // Unbounded: the simulator serves the page until it's stopped.
        while (true) {
            const conn = c.accept(fd, null, null);
            if (conn < 0) continue;
            s.serve(conn);
            _ = c.close(conn);
        }
    }

    fn serve(s: *Server, conn: c_int) void {
        assert(conn >= 0); // Accepted
        var request: [request_bytes_max]u8 = undefined;
        const n = c.read(conn, &request, request.len);
        if (n <= 0) return;
        assert(n <= request.len);
        const line_end = std.mem.indexOfScalar(u8, request[0..@intCast(n)], '\r') orelse return;
        var parts = std.mem.tokenizeScalar(u8, request[0..line_end], ' ');
        _ = parts.next(); // GET
        const target = parts.next() orelse return;
        const question = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. question orelse target.len];
        const query = if (question) |q| target[q + 1 ..] else "";
        if (std.mem.eql(u8, path, "/")) return reply(conn, "text/html", page);
        if (std.mem.eql(u8, path, "/version")) {
            var buf: [16]u8 = undefined;
            const version = std.fmt.bufPrint(&buf, "{d}", .{s.screen.updates}) catch "0";
            return reply(conn, "text/plain", version);
        }
        if (std.mem.eql(u8, path, "/screen.bmp")) return s.send_screen(conn);
        if (std.mem.eql(u8, path, "/act")) {
            if (action(query)) |act| {
                var bytes = act;
                _ = sys.write(s.actions, @ptrCast(&bytes), @sizeOf(input_mod.Action));
                // Then the finger lifts: a slider or picture follows it until then
                if (act == .hold or act == .tap) {
                    var lift: input_mod.Action = .drag_end;
                    _ = sys.write(s.actions, @ptrCast(&lift), @sizeOf(input_mod.Action));
                }
            }
            return reply(conn, "text/plain", "ok");
        }
        reply(conn, "text/plain", "not found");
    }

    /// The screen as an 8-bit gray BMP, which every browser shows as it is.
    fn send_screen(s: *Server, conn: c_int) void {
        assert(conn >= 0);
        assert(s.screen.pixels.len >= width_px * height_px);
        var head: [bmp_pixels_offset]u8 = undefined;
        @memset(&head, 0);
        head[0] = 'B';
        head[1] = 'M';
        std.mem.writeInt(u32, head[2..6], bmp_size_bytes, .little);
        std.mem.writeInt(u32, head[10..14], bmp_pixels_offset, .little);
        std.mem.writeInt(u32, head[14..18], 40, .little);
        std.mem.writeInt(i32, head[18..22], width_px, .little);
        std.mem.writeInt(i32, head[22..26], -height_px, .little); // Top row first
        std.mem.writeInt(u16, head[26..28], 1, .little);
        std.mem.writeInt(u16, head[28..30], 8, .little);
        std.mem.writeInt(u32, head[46..50], 256, .little);
        for (0..256) |i| {
            const g: u8 = @intCast(i);
            head[54 + i * 4 ..][0..4].* = .{ g, g, g, 0 };
        }
        var http: [160]u8 = undefined;
        const h = std.fmt.bufPrint(&http, http_head ++ "Content-Type: image/bmp\r\n" ++
            "Content-Length: {d}\r\n" ++ http_tail, .{bmp_size_bytes}) catch return;
        write_all(conn, h);
        write_all(conn, &head);
        write_all(conn, s.screen.pixels[0 .. width_px * height_px]);
    }
};

const http_head = "HTTP/1.1 200 OK\r\n";
const http_tail = "Cache-Control: no-store\r\nConnection: close\r\n\r\n";

fn reply(conn: c_int, kind: []const u8, body: []const u8) void {
    assert(conn >= 0);
    assert(kind.len > 0);
    var http: [160]u8 = undefined;
    const h = std.fmt.bufPrint(&http, http_head ++ "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++ http_tail, .{ kind, body.len }) catch return;
    write_all(conn, h);
    write_all(conn, body);
}

fn write_all(conn: c_int, bytes: []const u8) void {
    assert(conn >= 0);
    assert(bytes.len <= std.math.maxInt(u32)); // At most a screen
    var at: u32 = 0;
    while (at < bytes.len) {
        const n = c.write(conn, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) return;
        at += @intCast(n);
    }
    assert(at == bytes.len);
}

/// "k=tap&x=10&y=20" as noface's input.
fn action(query: []const u8) ?input_mod.Action {
    assert(query.len < request_bytes_max); // Part of a request's first line
    var kind: []const u8 = "";
    var x: i32 = 0;
    var y: i32 = 0;
    var d: i32 = 0;
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "k")) kind = value;
        if (std.mem.eql(u8, key, "x")) x = std.fmt.parseInt(i32, value, 10) catch 0;
        if (std.mem.eql(u8, key, "y")) y = std.fmt.parseInt(i32, value, 10) catch 0;
        if (std.mem.eql(u8, key, "d")) d = std.fmt.parseInt(i32, value, 10) catch 0;
    }
    if (std.mem.eql(u8, kind, "tap")) return .{ .tap = .{ .x = x, .y = y, .us = 0 } };
    if (std.mem.eql(u8, kind, "hold")) return .{ .hold = .{ .x = x, .y = y } };
    if (std.mem.eql(u8, kind, "swipe")) return .{ .swipe = if (d < 0) -1 else 1 };
    if (std.mem.eql(u8, kind, "pull")) return .pull;
    if (std.mem.eql(u8, kind, "lock")) return .lock;
    if (std.mem.eql(u8, kind, "unlock")) return .unlock;
    return null;
}

const page =
    \\<!doctype html><meta charset="utf-8"><title>noface</title>
    \\<style>
    \\  body{margin:0;background:#202124;height:100vh;display:flex;align-items:center;
    \\    justify-content:center;font:13px system-ui,sans-serif;color:#9aa0a6}
    \\  #kindle{background:#111;padding:26px 26px 18px;border-radius:30px;
    \\    box-shadow:0 10px 40px #0008}
    \\  img{display:block;height:calc(100vh - 130px);aspect-ratio:1272/1696;border-radius:3px;
    \\    cursor:pointer;user-select:none;-webkit-user-drag:none;image-rendering:auto}
    \\  .bar{display:flex;justify-content:space-between;align-items:center;margin-top:12px;
    \\    gap:16px}
    \\  button{background:#2d2e31;color:#e8eaed;border:0;border-radius:16px;padding:7px 14px;
    \\    font:inherit;cursor:pointer}
    \\  button:hover{background:#3c4043}
    \\</style>
    \\<div id="kindle">
    \\  <img id="screen" src="/screen.bmp" alt="noface's screen" draggable="false">
    \\  <div class="bar"><span>Click to tap · hold to hold · drag sideways to turn ·
    \\    drag down from the top for the light</span>
    \\  <span><button onclick="act('lock')">Lock</button>
    \\    <button onclick="act('unlock')">Wake</button></span></div>
    \\</div>
    \\<script>
    \\const s = document.getElementById('screen');
    \\let version = '', down = null;
    \\function at(e) {
    \\  const r = s.getBoundingClientRect();
    \\  return [Math.round((e.clientX - r.left) * 1272 / r.width),
    \\    Math.round((e.clientY - r.top) * 1696 / r.height)];
    \\}
    \\function act(k, x = 0, y = 0, d = 0) { fetch(`/act?k=${k}&x=${x}&y=${y}&d=${d}`); }
    \\s.addEventListener('mousedown', e => {
    \\  down = { p: at(e), t: Date.now() };
    \\  e.preventDefault();
    \\});
    \\window.addEventListener('mouseup', e => {
    \\  if (!down) return;
    \\  const p = at(e), dx = p[0] - down.p[0], dy = p[1] - down.p[1], held = Date.now() - down.t;
    \\  if (Math.abs(dx) > 80 && Math.abs(dx) > Math.abs(dy)) act('swipe', 0, 0, dx < 0 ? 1 : -1);
    \\  else if (down.p[1] < 200 && dy > 120) act('pull');
    \\  else if (held > 450) act('hold', down.p[0], down.p[1]);
    \\  else act('tap', down.p[0], down.p[1]);
    \\  down = null;
    \\});
    \\document.addEventListener('keydown', e => {
    \\  if (e.key === 'ArrowRight' || e.key === ' ') act('tap', 1000, 900);
    \\  if (e.key === 'ArrowLeft') act('tap', 150, 900);
    \\});
    \\async function refresh() {
    \\  try {
    \\    const v = await (await fetch('/version')).text();
    \\    if (v !== version) { version = v; s.src = '/screen.bmp?' + v; }
    \\  } catch (e) {}
    \\  setTimeout(refresh, 150);
    \\}
    \\refresh();
    \\</script>
    \\
;
