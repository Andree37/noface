//! Plays a script of touches on the Kindle and checks what noface does with them: what it
//! logs, and how soon it draws. Run against noface's own test books
//! (`noface-launch e2e <dir>`), so the reader's books, places and settings stay as they are.
//! Usage: e2e <script> <log> <out dir>
//!
//! Each line of the script is a step; `#` starts a comment.
//!   tap <x> <y>                     A finger down and up.
//!   hold <x> <y> <ms>               A finger down for <ms>.
//!   drag <x0> <y0> <x1> <y1> <ms> [<hold ms>]
//!                                   A finger moved from one point to the other over <ms>,
//!                                   held still first for <hold ms> if given.
//!   power                           The power button, which locks or unlocks.
//!   log <text>                      A line with <text> logged since the last touch, within
//!                                   10 s.
//!   drawn <ms>                      The screen changed within <ms> of the last touch's lift:
//!                                   a speed check. Times the framebuffer, not the panel's
//!                                   own refresh after it.
//!   still                           Waits for the screen to settle: noface drops a touch
//!                                   that lands before its screen is shown.
//!   shot <name>                     The screen once still, saved as <out dir>/<name>.pgm.
//!   wait <ms>                       A pause.
//! Each step prints a line; the first that fails stops the run, which exits 1.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const touchsim = @import("touchsim.zig");
const linux = std.os.linux;
const now_us = core.os.now_us;
const sleep_ms = core.os.sleep_ms;

const fbioget_vscreeninfo: u32 = 0x4600;
const fbioget_fscreeninfo: u32 = 0x4602;
/// The kernel's `fb_var_screeninfo`, read whole; only the first fields matter here.
const screen_info_size = 160;
const xres_offset = 0;
const yres_offset = 4;
const yoffset_offset = 20;
/// And its `fb_fix_screeninfo`, as a 32-bit Kindle lays it out: only the row length.
const fixed_info_size = 68;
const line_length_offset = 44;
/// The widest row read, in bytes: a row buffer for `Screen.read_row` is this long.
pub const row_size_max = 2048;
/// Rows read to tell one screen from another: every `sample_step`-th, so a sample takes
/// a few milliseconds and still sees any change bigger than a few lines.
const sample_step = 4;
/// How often the screen is looked at while waiting for it to change or settle.
const poll_ms = 5;
/// A screen is still once it hasn't changed for this long.
const still_ms = 400;
/// Longest wait for a log line, or for the screen to settle.
const wait_ms_max = 10_000;
/// The log written since a touch that's searched, at most: far more than one step logs.
const log_read_max = 256 << 10;
/// Steps in a drag: enough for noface to see a swipe's path, as a finger makes it.
const drag_steps = 20;
const lipc_set: [*:0]const u8 = "/usr/bin/lipc-set-prop";

comptime {
    assert(xres_offset + 4 <= yres_offset);
    assert(yoffset_offset + 4 <= screen_info_size);
    assert(line_length_offset + 4 <= fixed_info_size);
    // A row of the panel noface is drawn for, 1272 pixels across, fits.
    assert(row_size_max >= 1272);
    assert(still_ms > poll_ms);
}

/// The screen as noface draws it, read a row at a time at the driver's stride. Also
/// read by tools/fbcap.zig and tools/fbrec.zig, so every tool reads the panel one way.
pub const Screen = struct {
    fd: i32,
    width: u32,
    height: u32,
    stride: u32, // Bytes from one row to the next, as the driver lays them out

    pub fn open() !Screen {
        const rc = linux.open("/dev/fb0", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (core.os.failed(rc)) return error.NoFramebuffer;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd); // Ignored: only read from
        var info: [screen_info_size]u8 align(4) = undefined;
        if (core.os.failed(linux.ioctl(fd, fbioget_vscreeninfo, @intFromPtr(&info)))) {
            return error.NoFramebuffer;
        }
        var fixed: [fixed_info_size]u8 align(4) = undefined;
        if (core.os.failed(linux.ioctl(fd, fbioget_fscreeninfo, @intFromPtr(&fixed)))) {
            return error.NoFramebuffer;
        }
        const screen = Screen{
            .fd = fd,
            .width = std.mem.readInt(u32, info[xres_offset..][0..4], .little),
            .height = std.mem.readInt(u32, info[yres_offset..][0..4], .little),
            .stride = std.mem.readInt(u32, fixed[line_length_offset..][0..4], .little),
        };
        if (screen.width > row_size_max) return error.ScreenTooWide;
        if (screen.stride < screen.width) return error.UnexpectedStride;
        assert(screen.fd >= 0);
        assert(screen.width <= row_size_max);
        return screen;
    }

    /// Where the shown screen starts in the framebuffer: it may flip between two.
    pub fn top(screen: *const Screen) u32 {
        assert(screen.fd >= 0);
        var info: [screen_info_size]u8 align(4) = undefined;
        // Failed: the first screen, where noface always draws on the Kindle
        if (core.os.failed(linux.ioctl(screen.fd, fbioget_vscreeninfo, @intFromPtr(&info)))) {
            return 0;
        }
        return std.mem.readInt(u32, info[yoffset_offset..][0..4], .little);
    }

    /// A number standing for what's on screen: two screens that differ give two.
    fn sample(screen: *const Screen) u64 {
        assert(screen.width <= row_size_max);
        assert(screen.height > 0);
        var hash = std.hash.Wyhash.init(0);
        var row: [row_size_max]u8 = undefined;
        const first = screen.top();
        var y: u32 = 0;
        while (y < screen.height) : (y += sample_step) {
            screen.read_row(&row, first, y);
            hash.update(row[0..screen.width]);
        }
        return hash.final();
    }

    /// Reads row `y` of the screen shown from framebuffer row `first` (`top()`, read once
    /// by the caller: the shown screen may flip, and a whole read should be of one).
    pub fn read_row(screen: *const Screen, row: *[row_size_max]u8, first: u32, y: u32) void {
        assert(screen.width <= row.len);
        assert(y < screen.height);
        const offset: i64 = (@as(i64, first) + y) * screen.stride;
        // A short read leaves the row as it was, and shows as a changed screen
        _ = linux.pread(screen.fd, row, screen.width, offset);
    }

    /// Waits until the screen hasn't changed for `still_ms`, and says whether it did
    /// within `wait_ms_max`.
    fn settle(screen: *const Screen) bool {
        assert(screen.fd >= 0);
        const deadline = now_us() + wait_ms_max * 1000;
        var last = screen.sample();
        var since = now_us();
        while (now_us() < deadline) {
            sleep_ms(poll_ms * 4);
            const now = screen.sample();
            if (now != last) {
                last = now;
                since = now_us();
            } else if (now_us() - since >= still_ms * 1000) {
                return true;
            }
        }
        assert(now_us() >= deadline);
        return false;
    }

    /// Writes the whole screen to `path` as a PGM image.
    fn save(screen: *const Screen, path: [*:0]const u8) bool {
        assert(screen.width <= row_size_max);
        assert(path[0] != 0);
        const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
        const rc = linux.open(path, flags, 0o644);
        if (core.os.failed(rc)) return false;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        return screen.write_pgm(fd, 0, screen.height);
    }

    /// Writes `band_height` rows of the screen from row `band_top` on to `fd`, as a PGM
    /// image, and says whether it all went.
    pub fn write_pgm(screen: *const Screen, fd: i32, band_top: u32, band_height: u32) bool {
        assert(screen.width <= row_size_max);
        assert(band_height <= screen.height);
        assert(band_top <= screen.height - band_height);
        var head: [32]u8 = undefined;
        const format = "P5\n{d} {d}\n255\n";
        const header = std.fmt.bufPrint(&head, format, .{ screen.width, band_height }) catch
            return false;
        if (!core.file.write_all(fd, header)) return false;
        var row: [row_size_max]u8 = undefined;
        const first = screen.top();
        for (0..band_height) |y| {
            screen.read_row(&row, first, band_top + @as(u32, @intCast(y)));
            if (!core.file.write_all(fd, row[0..screen.width])) return false;
        }
        return true;
    }
};

/// What a run has to hand: the panel, the screen, the log, and the last touch.
const Run = struct {
    panel: touchsim.Panel,
    screen: Screen,
    log_path: [*:0]const u8,
    out_dir: []const u8,
    /// The log's length as the last touch began: a `log` step reads what came after.
    log_mark: u64 = 0,
    /// The screen just before the last touch, and when that touch lifted.
    before: u64 = 0,
    lifted_us: u64 = 0,

    /// Notes the log's length and the screen, just before a touch.
    fn mark(run: *Run) void {
        assert(run.screen.fd >= 0);
        run.log_mark = core.file.size_of(run.log_path);
        run.before = run.screen.sample();
        assert(run.lifted_us <= now_us());
    }

    fn lifted(run: *Run) void {
        assert(!run.panel.finger_down);
        run.lifted_us = now_us();
        assert(run.lifted_us > 0);
    }
};

/// Why a step failed, to print.
const Failure = error{ Usage, Timeout, TooSlow, CantSave, NoLog };

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 4) return error.Usage;
    const script = try core.file.map(argv[1]);
    defer core.file.unmap(script);
    var run = Run{
        .panel = try touchsim.Panel.open(),
        .screen = try Screen.open(),
        .log_path = argv[2],
        .out_dir = std.mem.sliceTo(argv[3], 0),
    };
    var lines = std.mem.splitScalar(u8, script, '\n');
    var line_number: u32 = 0;
    var passed: u32 = 0;
    while (lines.next()) |line_raw| {
        line_number += 1;
        const code = line_raw[0 .. std.mem.indexOfScalar(u8, line_raw, '#') orelse line_raw.len];
        const line = std.mem.trim(u8, code, " \t\r");
        if (line.len == 0) continue;
        const took_ms = step(&run, line) catch |err| {
            std.debug.print("FAIL {d}: {s}: {s}\n", .{ line_number, line, @errorName(err) });
            std.process.exit(1);
        };
        passed += 1;
        if (took_ms) |ms| {
            std.debug.print("ok   {d}: {s} ({d} ms)\n", .{ line_number, line, ms });
        } else {
            std.debug.print("ok   {d}: {s}\n", .{ line_number, line });
        }
    }
    assert(passed <= line_number);
    std.debug.print("e2e: {d} steps passed\n", .{passed});
}

/// Plays one step, returning how long the screen took to change for a `drawn` step.
fn step(run: *Run, line: []const u8) Failure!?u32 {
    assert(line.len > 0);
    assert(!run.panel.finger_down);
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const verb = words.next() orelse return error.Usage;
    if (std.mem.eql(u8, verb, "drawn")) return try drawn(run, try number(&words));
    if (std.mem.eql(u8, verb, "log")) {
        const wanted = std.mem.trim(u8, line[verb.len..], " \t");
        if (wanted.len == 0) return error.Usage;
        try wait_for_log(run, wanted);
    } else if (std.mem.eql(u8, verb, "still")) {
        if (!run.screen.settle()) return error.Timeout;
    } else if (std.mem.eql(u8, verb, "shot")) {
        try shot(run, words.next() orelse return error.Usage);
    } else if (std.mem.eql(u8, verb, "wait")) {
        sleep_ms(try number(&words));
    } else {
        try touch(run, verb, &words);
    }
    return null;
}

/// Plays a touch, or the power button.
fn touch(run: *Run, verb: []const u8, words: *std.mem.TokenIterator(u8, .any)) Failure!void {
    assert(verb.len > 0);
    assert(!run.panel.finger_down);
    if (std.mem.eql(u8, verb, "power")) {
        run.mark();
        const argv = [_:null]?[*:0]const u8{ lipc_set, "com.lab126.powerd", "powerButton", "1" };
        var out: [64]u8 = undefined;
        _ = core.process.run(&argv, &out) orelse return error.Timeout;
    } else if (std.mem.eql(u8, verb, "tap")) {
        const x = try coordinate(words);
        const y = try coordinate(words);
        run.mark();
        run.panel.down(x, y);
        sleep_ms(touchsim.tap_ms);
        run.panel.up();
    } else if (std.mem.eql(u8, verb, "hold")) {
        const x = try coordinate(words);
        const y = try coordinate(words);
        const hold_ms = try number(words);
        run.mark();
        run.panel.down(x, y);
        sleep_ms(hold_ms);
        run.panel.up();
    } else if (std.mem.eql(u8, verb, "drag")) {
        try drag(run, words);
    } else {
        return error.Usage;
    }
    run.lifted();
}

/// A finger moved in `drag_steps` even steps over the time given.
fn drag(run: *Run, words: *std.mem.TokenIterator(u8, .any)) Failure!void {
    assert(!run.panel.finger_down);
    var at: [4]i32 = undefined;
    for (&at) |*value| value.* = try coordinate(words);
    const total_ms = try number(words);
    // A hold first, for selecting: a word that isn't a number is a mistake, not none
    const hold_ms: u32 = if (words.peek() != null) try number(words) else 0;
    run.mark();
    run.panel.down(at[0], at[1]);
    sleep_ms(hold_ms);
    var x = at[0];
    var y = at[1];
    for (1..drag_steps + 1) |index| {
        sleep_ms(total_ms / drag_steps);
        const i: i32 = @intCast(index);
        x = at[0] + @divTrunc((at[2] - at[0]) * i, drag_steps);
        y = at[1] + @divTrunc((at[3] - at[1]) * i, drag_steps);
        run.panel.move(x, y);
    }
    // The last step lands where the drag ends
    assert(x == at[2]);
    assert(y == at[3]);
    run.panel.up();
}

/// Waits for the screen to change from how it was before the last touch, and returns
/// how long after the touch's lift it did. Too slow, or never, fails.
fn drawn(run: *const Run, budget_ms: u32) Failure!u32 {
    assert(run.lifted_us > 0);
    assert(budget_ms > 0);
    const deadline = run.lifted_us + @as(u64, budget_ms) * 1000;
    // Bounded by the deadline
    while (run.screen.sample() == run.before) {
        if (now_us() >= deadline) return error.TooSlow;
        sleep_ms(poll_ms);
    }
    // Drawn while the finger was still down (a hold's menu, say) counts as at once
    const took_us = now_us() -| run.lifted_us;
    return @intCast(took_us / 1000);
}

/// Waits for the screen to settle and saves it as `<out dir>/<name>.pgm`.
fn shot(run: *const Run, name: []const u8) Failure!void {
    assert(name.len > 0);
    assert(run.out_dir.len > 0);
    if (!run.screen.settle()) return error.Timeout;
    var path: [512]u8 = undefined;
    const full = std.fmt.bufPrintSentinel(&path, "{s}/{s}.pgm", .{ run.out_dir, name }, 0) catch
        return error.Usage;
    if (!run.screen.save(full)) return error.CantSave;
}

/// Waits for a line with `wanted` in what the log gained since the last touch.
fn wait_for_log(run: *const Run, wanted: []const u8) Failure!void {
    assert(wanted.len > 0);
    const deadline = now_us() + wait_ms_max * 1000;
    // Bounded by the deadline
    while (now_us() < deadline) {
        if (try log_has(run.log_path, run.log_mark, wanted)) return;
        sleep_ms(poll_ms * 10);
    }
    return error.Timeout;
}

var log_buffer: [log_read_max]u8 = undefined;

/// Whether the log, from byte `from` on, has `wanted` in it.
fn log_has(path: [*:0]const u8, from: u64, wanted: []const u8) Failure!bool {
    assert(wanted.len > 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (core.os.failed(rc)) return error.NoLog;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    // A log started again since (shorter than the mark) is read from its start
    const start: i64 = if (core.file.size_of(path) < from) 0 else @intCast(from);
    const read = linux.pread(fd, &log_buffer, log_buffer.len, start);
    if (core.os.failed(read)) return error.NoLog;
    assert(read <= log_buffer.len);
    return std.mem.indexOf(u8, log_buffer[0..read], wanted) != null;
}

/// The next word as a place on the screen, in its pixels: no screen is wider or taller.
fn coordinate(words: *std.mem.TokenIterator(u8, .any)) Failure!i32 {
    const word = words.next() orelse return error.Usage;
    assert(word.len > 0);
    return std.fmt.parseInt(u16, word, 10) catch return error.Usage;
}

/// The next word as a number.
fn number(words: *std.mem.TokenIterator(u8, .any)) Failure!u32 {
    const word = words.next() orelse return error.Usage;
    assert(word.len > 0);
    return std.fmt.parseInt(u32, word, 10) catch return error.Usage;
}
