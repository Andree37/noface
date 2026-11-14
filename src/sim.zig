//! noface-sim: noface on a computer, in a browser. The real app runs, on a screen in
//! memory and the pretend Kindle the scenario tests use (so nothing is started and
//! nothing on the computer is changed outside its folder), and a small web server on
//! this computer shows the screen and turns clicks into taps.
//!
//!   zig build sim                    the test book
//!   zig build sim -Dbooks=~/Books    the EPUBs in a folder
//!
//! Then open http://localhost:8080. Click to tap, press and hold to hold a word, drag
//! sideways to turn a page, drag down from the top for the light panel. What noface
//! saves (positions, settings, stats) goes in ./noface-sim-data.
const std = @import("std");
const app = @import("app.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const input_mod = @import("kindle/input.zig");
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const c_memory = @import("gfx/c_memory.zig");
const memory = @import("base/memory.zig");
const wifi_saver = @import("kindle/wifi_saver.zig");
const library_screen = @import("screens/library.zig");
const FakeKindle = @import("fake_kindle.zig").FakeKindle;
const sys = @import("sys/calls.zig");
const c = std.c;

const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
const test_book = @embedFile("testdata/scenario.epub");

const width = 1272;
const height = 1696;

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.smp_allocator;
    const args = init.args.vector;
    const port: u16 = if (init.environ.getPosix("NOFACE_SIM_PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 8080 else 8080;

    // Its own folder for what noface keeps, and the books: a folder given, or the test book
    const data = "noface-sim-data";
    _ = sys.mkdir(data, 0o755);
    const books: []const u8 = if (args.len >= 2) std.mem.sliceTo(args[1], 0) else blk: {
        const dir = data ++ "/books";
        _ = sys.mkdir(dir, 0o755);
        try writeFile(dir ++ "/Scenario Book.epub", test_book);
        break :blk dir;
    };
    try writeFile(data ++ "/library.tsv", "\n"); // No Amazon books: only the EPUBs

    // The pretend Kindle answers the system; the Wi-Fi saver's note stays in the folder
    var fake = try FakeKindle.init(alloc);
    fake.clock = localClock;
    // A computer is on its charger, and full
    try fake.put("com.lab126.powerd battLevel", "100");
    try fake.put("com.lab126.powerd usbState", "1");
    fake.install();
    wifi_saver.useDataDir(data);

    var app_budget = memory.Budget{ .name = "app", .child = alloc, .limit = 512 << 20 };
    var stb_budget = memory.Budget{ .name = "stb", .child = alloc, .limit = 256 << 20 };
    c_memory.use(&stb_budget);
    const a_alloc = app_budget.allocator();

    var screen = try hwtcon.Screen.fake(a_alloc, width, height);
    var pipe: [2]i32 = undefined;
    if (sys.pipe2(&pipe, .{ .CLOEXEC = true }) > std.math.maxInt(usize) - 4096) return error.NoPipe;
    var input = input_mod.Input{ .touch = -1, .power = -1, .width = width, .height = height, .x_max = width, .y_max = height, .remote = pipe[0] };

    var body = try Font.init(a_alloc, go_regular, 46, 1.35);
    var note_font = try Font.init(a_alloc, go_regular, 36, 1.3);
    var footer = try Font.init(a_alloc, go_regular, 28, 1.2);
    var reference = try Font.init(a_alloc, go_regular, 28, 1.2);
    var title = try Font.init(a_alloc, go_bold, 34, 1.2);
    var small = try Font.init(a_alloc, go_regular, 34, 1.2);
    var caption = try Font.init(a_alloc, go_regular, 26, 1.2);
    var hero = try Font.init(a_alloc, go_bold, 56, 1.2);
    var cover_type = try Font.init(a_alloc, go_bold, 36, 1.2);
    var slots: [3]app.Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try a_alloc.alloc(u8, screen.pixels.len) };

    var a = app.App{
        .alloc = a_alloc,
        .screen = &screen,
        .input = &input,
        .body = &body,
        .note_font = &note_font,
        .footer = &footer,
        .ui = Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type },
        .slots = slots,
        .overlay = try a_alloc.alloc(u8, screen.pixels.len),
        .lock_saved = try a_alloc.alloc(u8, screen.pixels.len),
        .lock_cover = try a_alloc.alloc(u8, screen.pixels.len),
        .state_dir = data,
        .library_path = data ++ "/library.tsv",
        .settings_path = data ++ "/settings",
        .speed_path = data ++ "/speed",
        .journal_path = data ++ "/journal",
        .battery_path = data ++ "/battery",
        .documents = books,
        .app_budget = &app_budget,
        .stb_budget = &stb_budget,
        .settings = app.loadSettings(data ++ "/settings"),
        .utc_offset = 0,
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &reference },
    };
    // Every typeface is the Go font: the Kindle's own aren't on a computer
    for (&a.face_files) |*family| family.* = .{ go_regular, go_bold, go_regular, go_bold };
    try a.applySettings();

    var server = Server{ .screen = &screen, .actions = pipe[1], .port = port };
    const thread = try std.Thread.spawn(.{}, Server.run, .{&server});
    thread.detach();
    std.debug.print("noface-sim: open http://localhost:{d}  (books from {s})\n", .{ port, books });

    try library_screen.runLibrary(&a);
}

extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(t: *const i64, out: *anyopaque) ?*anyopaque;
extern "c" fn strftime(buf: [*]u8, max: usize, format: [*:0]const u8, tm: *const anyopaque) usize;

/// The computer's local time, as the Kindle's `date +"%H:%M - %d %b %Y"` prints it.
fn localClock(out: []u8) usize {
    var now = time(null);
    var tm: [128]u8 align(16) = undefined; // A struct tm, of whatever size this system's is
    _ = localtime_r(&now, &tm) orelse return 0;
    return strftime(out.ptr, out.len, "%H:%M - %d %b %Y", &tm);
}

fn writeFile(path: [*:0]const u8, bytes: []const u8) !void {
    const rc = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (rc > std.math.maxInt(usize) - 4096) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    defer _ = sys.close(fd);
    _ = sys.write(fd, bytes.ptr, bytes.len);
}

/// The web page and the screen, on localhost only.
const Server = struct {
    screen: *hwtcon.Screen,
    actions: i32, // Write end of the input pipe
    port: u16,

    fn run(s: *Server) void {
        const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (fd < 0) return;
        var yes: c_int = 1;
        _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &yes, @sizeOf(c_int));
        var addr = std.mem.zeroes(c.sockaddr.in);
        if (@hasField(c.sockaddr.in, "len")) addr.len = @sizeOf(c.sockaddr.in);
        addr.family = c.AF.INET;
        addr.port = std.mem.nativeToBig(u16, s.port);
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001); // 127.0.0.1
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0 or c.listen(fd, 8) != 0) {
            std.debug.print("noface-sim: port {d} is taken; set NOFACE_SIM_PORT\n", .{s.port});
            return;
        }
        while (true) {
            const conn = c.accept(fd, null, null);
            if (conn < 0) continue;
            s.serve(conn);
            _ = c.close(conn);
        }
    }

    fn serve(s: *Server, conn: c_int) void {
        var req: [2048]u8 = undefined;
        const n = c.read(conn, &req, req.len);
        if (n <= 0) return;
        const line_end = std.mem.indexOfScalar(u8, req[0..@intCast(n)], '\r') orelse return;
        var parts = std.mem.tokenizeScalar(u8, req[0..line_end], ' ');
        _ = parts.next(); // GET
        const target = parts.next() orelse return;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else "";
        if (std.mem.eql(u8, path, "/")) return reply(conn, "text/html", page);
        if (std.mem.eql(u8, path, "/version")) {
            var buf: [16]u8 = undefined;
            return reply(conn, "text/plain", std.fmt.bufPrint(&buf, "{d}", .{s.screen.updates}) catch "0");
        }
        if (std.mem.eql(u8, path, "/screen.bmp")) return s.sendScreen(conn);
        if (std.mem.eql(u8, path, "/act")) {
            if (action(query)) |act| {
                var bytes = act;
                _ = sys.write(s.actions, @ptrCast(&bytes), @sizeOf(input_mod.Action));
                if (act == .hold or act == .tap) { // Then the finger lifts: a slider or picture follows it until then
                    var lift: input_mod.Action = .drag_end;
                    _ = sys.write(s.actions, @ptrCast(&lift), @sizeOf(input_mod.Action));
                }
            }
            return reply(conn, "text/plain", "ok");
        }
        reply(conn, "text/plain", "not found");
    }

    /// The screen as an 8-bit gray BMP, which every browser shows as it is.
    fn sendScreen(s: *Server, conn: c_int) void {
        const palette = 256 * 4;
        const offset = 14 + 40 + palette;
        const size = offset + width * height;
        var head: [offset]u8 = undefined;
        @memset(&head, 0);
        head[0] = 'B';
        head[1] = 'M';
        std.mem.writeInt(u32, head[2..6], size, .little);
        std.mem.writeInt(u32, head[10..14], offset, .little);
        std.mem.writeInt(u32, head[14..18], 40, .little);
        std.mem.writeInt(i32, head[18..22], width, .little);
        std.mem.writeInt(i32, head[22..26], -height, .little); // Top row first
        std.mem.writeInt(u16, head[26..28], 1, .little);
        std.mem.writeInt(u16, head[28..30], 8, .little);
        std.mem.writeInt(u32, head[46..50], 256, .little);
        for (0..256) |i| {
            const g: u8 = @intCast(i);
            head[54 + i * 4 ..][0..4].* = .{ g, g, g, 0 };
        }
        var http: [160]u8 = undefined;
        const h = std.fmt.bufPrint(&http, "HTTP/1.1 200 OK\r\nContent-Type: image/bmp\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{size}) catch return;
        writeAll(conn, h);
        writeAll(conn, &head);
        writeAll(conn, s.screen.pixels[0 .. width * height]);
    }
};

fn reply(conn: c_int, kind: []const u8, body: []const u8) void {
    var http: [160]u8 = undefined;
    const h = std.fmt.bufPrint(&http, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", .{ kind, body.len }) catch return;
    writeAll(conn, h);
    writeAll(conn, body);
}

fn writeAll(conn: c_int, bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(conn, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) return;
        at += @intCast(n);
    }
}

/// "k=tap&x=10&y=20" as noface's input.
fn action(query: []const u8) ?input_mod.Action {
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
    \\  body{margin:0;background:#202124;height:100vh;display:flex;align-items:center;justify-content:center;font:13px system-ui,sans-serif;color:#9aa0a6}
    \\  #kindle{background:#111;padding:26px 26px 18px;border-radius:30px;box-shadow:0 10px 40px #0008}
    \\  img{display:block;height:calc(100vh - 130px);aspect-ratio:1272/1696;border-radius:3px;cursor:pointer;user-select:none;-webkit-user-drag:none;image-rendering:auto}
    \\  .bar{display:flex;justify-content:space-between;align-items:center;margin-top:12px;gap:16px}
    \\  button{background:#2d2e31;color:#e8eaed;border:0;border-radius:16px;padding:7px 14px;font:inherit;cursor:pointer}
    \\  button:hover{background:#3c4043}
    \\</style>
    \\<div id="kindle">
    \\  <img id="screen" src="/screen.bmp" alt="noface's screen" draggable="false">
    \\  <div class="bar"><span>Click to tap · hold to hold · drag sideways to turn · drag down from the top for the light</span>
    \\  <span><button onclick="act('lock')">Lock</button> <button onclick="act('unlock')">Wake</button></span></div>
    \\</div>
    \\<script>
    \\const s = document.getElementById('screen');
    \\let version = '', down = null;
    \\function at(e) { const r = s.getBoundingClientRect(); return [Math.round((e.clientX - r.left) * 1272 / r.width), Math.round((e.clientY - r.top) * 1696 / r.height)]; }
    \\function act(k, x = 0, y = 0, d = 0) { fetch(`/act?k=${k}&x=${x}&y=${y}&d=${d}`); }
    \\s.addEventListener('mousedown', e => { down = { p: at(e), t: Date.now() }; e.preventDefault(); });
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
    \\  try { const v = await (await fetch('/version')).text(); if (v !== version) { version = v; s.src = '/screen.bmp?' + v; } } catch (e) {}
    \\  setTimeout(refresh, 150);
    \\}
    \\refresh();
    \\</script>
    \\
;
