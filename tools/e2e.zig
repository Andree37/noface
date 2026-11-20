//! Plays a script of touches on the Kindle and checks what noface does with them: what it
//! logs, and how soon it draws. It starts noface itself, fresh, on a test folder of its
//! own books (`noface-launch e2e <folder>`), and stops it after, so the reader's books,
//! places and settings stay as they are; the reader's noface is started again by
//! whoever stopped it.
//! Usage: e2e all <folder>
//!        e2e <script> <test folder>
//! `all` plays every script in tools/e2e/, built in, each on the test folder it needs,
//! which it makes in <folder> with the test books built in too (src/testdata/books.zig):
//! books/, whose documents/ hold "Scenario Book.epub" and "Scenario Book 02.epub" to
//! "14", so the library has two pages, and notes/, whose documents/ hold "Notes and
//! Pictures.epub". It plays them all, says how each went, and exits 1 if any failed.
//! Given a script instead, it plays that one on a test folder whose documents/ already
//! hold its books, such as one `all` made. Each run makes data/ (noface's) and out/
//! (the shots) in its test folder anew.
//!
//! Each line of the script is a step; `#` starts a comment.
//!   tap <target>                    A finger down and up.
//!   hold <target> <ms>              A finger down for <ms>.
//!   drag <target> <target> <ms> [<hold ms>]
//!                                   A finger moved from one point to the other over <ms>,
//!                                   held still first for <hold ms> if given.
//! A target is a point, or "placed <what>": where noface's log says it last drew what
//! moves with the text (screens/placed.zig), such as a footnote's mark or the page's
//! first word, read as the step is played.
//! A point is a control by name, as screens/places.zig lists them ("toolbar.bookmark",
//! "key.s", "card.3.0"), so a script follows layout as it moves, or "<x> <y>" for what
//! isn't a control, like a word on the page. Every name is checked before the first
//! touch.
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
/// Lines a check makes before the run, which the tests keep quiet.
const log = std.log.scoped(.e2e);
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

    pub fn close(screen: *Screen) void {
        assert(screen.fd >= 0);
        _ = linux.close(screen.fd); // Only read from
        screen.fd = -1;
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
const Failure = error{ Usage, Timeout, TooSlow, CantSave, NoLog, UnknownPlace, NotPlaced };
const Words = std.mem.TokenIterator(u8, .any);
const Point = core.places.Point;

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len != 3) return error.Usage;
    const folder = std.mem.sliceTo(argv[2], 0);
    if (folder.len == 0) return error.Usage;
    if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "all")) {
        if (!try play_all(folder)) std.process.exit(1);
        return;
    }
    const script = try core.file.map(argv[1]);
    defer core.file.unmap(script);
    if (!script_reads(script)) std.process.exit(1);
    var buffers: Folder.Buffers = undefined;
    if (!try play_on(script, try Folder.in(&buffers, folder))) std.process.exit(1);
}

/// The scripts `all` plays, built in, and the test folder each plays on.
const suite = [_]Script{
    .{ .name = "library", .text = @embedFile("e2e/library.e2e"), .shelf = .books },
    .{ .name = "reader", .text = @embedFile("e2e/reader.e2e"), .shelf = .books },
    .{ .name = "running", .text = @embedFile("e2e/running.e2e"), .shelf = .books },
    .{ .name = "sheets", .text = @embedFile("e2e/sheets.e2e"), .shelf = .books },
    .{ .name = "goto", .text = @embedFile("e2e/goto.e2e"), .shelf = .books },
    .{ .name = "notes", .text = @embedFile("e2e/notes.e2e"), .shelf = .notes },
};
const Script = struct { name: []const u8, text: []const u8, shelf: Shelf };

/// The test folders `all` makes, by their folder's name, each with the books it holds.
const Shelf = enum {
    books, // The scenario book and 13 copies: a library of two pages
    notes, // The book with a footnote and a picture

    /// How many copies of its book it holds: one, or enough to fill two library pages.
    fn copies(shelf: Shelf) u32 {
        return switch (shelf) {
            .books => scenario_copies,
            .notes => 1,
        };
    }

    fn book(shelf: Shelf) []const u8 {
        return switch (shelf) {
            .books => core.test_books.scenario,
            .notes => core.test_books.notes,
        };
    }

    fn title(shelf: Shelf) []const u8 {
        return switch (shelf) {
            .books => "Scenario Book",
            .notes => "Notes and Pictures",
        };
    }
};

/// Copies of the scenario book on the books shelf: more than a library page holds.
const scenario_copies = 14;

comptime {
    // Two pages of the library, so its scripts can turn on and back
    assert(core.library.page_count(scenario_copies) == 2);
}

/// Plays every script in `suite` on its shelf in `root`, made first, and says whether
/// all of them passed. One that fails doesn't stop the rest.
fn play_all(root: []const u8) !bool {
    assert(root.len > 0);
    for (suite) |script| {
        if (!script_reads(script.text)) return false;
    }
    var failed: u32 = 0;
    for (suite) |script| {
        std.debug.print("== {s}\n", .{script.name});
        var path_buffer: [core.file.own_path_bytes_max]u8 = undefined;
        const shelf_root = try std.fmt.bufPrint(
            &path_buffer,
            "{s}/{s}",
            .{ root, @tagName(script.shelf) },
        );
        try shelve(shelf_root, script.shelf);
        var buffers: Folder.Buffers = undefined;
        if (!try play_on(script.text, try Folder.in(&buffers, shelf_root))) failed += 1;
    }
    assert(failed <= suite.len);
    const passed = suite.len - failed;
    std.debug.print("e2e: {d} of {d} scripts passed\n", .{ passed, suite.len });
    return failed == 0;
}

/// Makes the test folder `shelf_root` for `shelf`, its documents/ holding its books.
/// Books already there are kept: written again, they'd count as just added, and the
/// library's order by date added would change from one run to the next.
fn shelve(shelf_root: []const u8, shelf: Shelf) !void {
    assert(shelf_root.len > 0);
    var path_buffer: [core.file.own_path_bytes_max]u8 = undefined;
    for ([_][]const u8{ "", "/documents" }) |under| {
        const folder = try std.fmt.bufPrintSentinel(&path_buffer, "{s}{s}", .{
            shelf_root, under,
        }, 0);
        const rc = core.calls.mkdir(folder, 0o755);
        if (core.os.failed(rc) and !core.file.exists(folder)) return error.CantShelve;
    }
    for (0..shelf.copies()) |i| {
        const book = try book_path(&path_buffer, shelf_root, shelf, @intCast(i));
        if (core.file.exists(book)) continue;
        core.file.write_small(book, shelf.book());
        if (core.file.size_of(book) != shelf.book().len) return error.CantShelve;
    }
}

/// Copy `i` of `shelf`'s book in `shelf_root`'s documents: the first by the book's
/// title, the rest numbered from 02, as a reader's copies would be.
fn book_path(
    buffer: *[core.file.own_path_bytes_max]u8,
    shelf_root: []const u8,
    shelf: Shelf,
    i: u32,
) ![:0]const u8 {
    assert(i < shelf.copies());
    const documents = .{ shelf_root, shelf.title() };
    if (i == 0) return std.fmt.bufPrintSentinel(buffer, "{s}/documents/{s}.epub", documents, 0);
    const copy_number = i + 1; // The first copy is the book's second
    return std.fmt.bufPrintSentinel(buffer, "{s}/documents/{s} {d:0>2}.epub", .{
        shelf_root, shelf.title(), copy_number,
    }, 0);
}

/// Starts noface on `folder`, plays `script` against it, and stops it again, whatever
/// the script did: a failed step leaves no noface on the test folder for the reader's
/// own to start beside. Says whether every step passed.
fn play_on(script: []const u8, folder: Folder) !bool {
    assert(script.len > 0);
    try start_noface(folder);
    defer stop_noface();
    return play(script, folder);
}

/// Plays every step of `script` against noface on `folder`, saying how each went:
/// false at the first that fails.
fn play(script: []const u8, folder: Folder) bool {
    assert(script.len > 0);
    assert(folder.out.len > 0);
    var run = Run{
        .panel = touchsim.Panel.open() catch return false,
        .screen = Screen.open() catch return false,
        .log_path = folder.log,
        .out_dir = folder.out,
    };
    defer run.panel.close();
    defer run.screen.close();
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
            return false;
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
    return true;
}

/// The test folder (`noface-launch e2e <folder>`): its books in documents/, and what a
/// run makes in it, noface's data, made fresh for each run so noface starts on its
/// library with nothing read, and the shots. The reader's own books, places and
/// settings are elsewhere, never touched.
const Folder = struct {
    root: [:0]const u8,
    data: [:0]const u8,
    log: [:0]const u8,
    out: [:0]const u8,

    const Buffers = [4][core.file.own_path_bytes_max]u8;

    fn in(buffers: *Buffers, root: []const u8) !Folder {
        assert(root.len > 0);
        const f: Folder = .{
            .root = try std.fmt.bufPrintSentinel(&buffers[0], "{s}", .{root}, 0),
            .data = try std.fmt.bufPrintSentinel(&buffers[1], "{s}/data", .{root}, 0),
            .log = try std.fmt.bufPrintSentinel(
                &buffers[2],
                "{s}/data/{s}",
                .{ root, core.paths.data.log },
                0,
            ),
            .out = try std.fmt.bufPrintSentinel(&buffers[3], "{s}/out", .{root}, 0),
        };
        // What's removed for a fresh run is inside the test folder, never above it
        assert(std.mem.startsWith(u8, f.data, root));
        assert(std.mem.startsWith(u8, f.out, root));
        return f;
    }
};

/// Longest wait for noface to start on the test folder and log its library.
const start_ms_max = 40_000;
/// Then, once the library's screen is still, this long more for the panel's own
/// refresh of it to finish: `still` sees the framebuffer, and noface drops a touch
/// that lands before the panel's done.
const panel_refresh_ms = 1_000;
/// Longest wait for noface and its launcher to stop.
const stop_ms_max = 20_000;
/// A Kindle woken from its screensaver takes this long to show what's under it.
const wake_ms = 3_000;
/// How often a start or a stop is checked on.
const check_ms = 250;

/// Starts noface fresh on `folder`: the Kindle awake and held so for the run, the
/// folder's data and shots made anew, and noface on its library.
fn start_noface(folder: Folder) !void {
    // Its log in its data, which is made anew below
    assert(std.mem.startsWith(u8, folder.log, folder.data));
    assert(folder.out.len > folder.root.len);
    // A Kindle in its screensaver shows noface's lock, which would take the touches
    if (core.lipc.power_state() == .asleep) {
        press_power() catch return error.CantWake;
        sleep_ms(wake_ms);
    }
    core.lipc.hold_awake(true);
    var out: [64]u8 = undefined;
    const remove = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", folder.data, folder.out };
    _ = core.process.run(&remove, &out) orelse return error.CantClear;
    if (core.os.failed(core.calls.mkdir(folder.out, 0o755))) return error.CantClear;
    const launch = [_:null]?[*:0]const u8{ core.paths.launcher, "e2e", folder.root };
    _ = core.process.run(&launch, &out) orelse return error.CantStart;
    const deadline = now_us() + start_ms_max * 1000;
    // Bounded by the deadline
    while (!(log_has(folder.log, 0, "library") catch false)) {
        if (now_us() >= deadline) return error.CantStart;
        sleep_ms(check_ms);
    }
    var screen = Screen.open() catch return error.CantStart;
    defer screen.close();
    if (!screen.settle()) return error.CantStart;
    sleep_ms(panel_refresh_ms);
}

/// Stops noface, its launcher with it, and lets the Kindle sleep again.
fn stop_noface() void {
    defer core.lipc.hold_awake(false);
    const pid = pid_of("noface") orelse return;
    assert(pid > 0); // A process's, never 0 or -1, which would signal many
    _ = linux.kill(pid, linux.SIG.TERM); // Already gone: nothing to stop
    const deadline = now_us() + stop_ms_max * 1000;
    // Bounded by the deadline
    while (pid_of("noface") != null or pid_of("noface-launch") != null) {
        if (now_us() >= deadline) {
            std.debug.print("noface didn't stop\n", .{});
            return;
        }
        sleep_ms(check_ms);
    }
    assert(pid_of("noface") == null);
}

/// The power button, pressed once.
fn press_power() Failure!void {
    comptime assert(std.mem.startsWith(u8, std.mem.span(lipc_set), "/usr/bin/"));
    const argv = [_:null]?[*:0]const u8{ lipc_set, "com.lab126.powerd", "powerButton", "1" };
    var out: [64]u8 = undefined;
    _ = core.process.run(&argv, &out) orelse return error.Timeout;
}

/// The longest name Linux keeps for a process (its comm, less the closing zero).
const comm_bytes_max = 15;

/// The process named `name`, found by its name in /proc, or null with none.
fn pid_of(name: []const u8) ?i32 {
    assert(name.len > 0);
    assert(name.len <= comm_bytes_max); // Linux keeps no more of a name in comm
    var found: Found = .{ .name = name };
    core.calls.each_entry("/proc", &found, Found.each);
    return found.pid;
}

/// What `pid_of` looks for as /proc is listed, and what it found.
const Found = struct {
    name: []const u8,
    pid: ?i32 = null,

    fn each(f: *Found, entry: []const u8, is_folder: bool) void {
        assert(entry.len > 0);
        assert(f.name.len <= comm_bytes_max);
        if (f.pid != null or !is_folder) return;
        const pid = std.fmt.parseInt(i32, entry, 10) catch return; // Not a process
        var path: [32]u8 = undefined;
        const comm = std.fmt.bufPrintSentinel(&path, "/proc/{d}/comm", .{pid}, 0) catch return;
        var buffer: [32]u8 = undefined;
        const named = std.mem.trimEnd(u8, core.file.read_small(comm, &buffer), "\n");
        if (std.mem.eql(u8, named, f.name)) f.pid = pid;
    }
};

/// Whether every touch in `script` reads, its places found, before any is made: a
/// mistake in a later line would otherwise show only after the touches before it.
fn script_reads(script: []const u8) bool {
    var lines = std.mem.splitScalar(u8, script, '\n');
    var line_number: u32 = 0;
    var bad: u32 = 0;
    while (lines.next()) |line_raw| {
        line_number += 1;
        const code = line_raw[0 .. std.mem.indexOfScalar(u8, line_raw, '#') orelse line_raw.len];
        var words = std.mem.tokenizeAny(u8, code, " \t\r");
        const verb = words.next() orelse continue;
        _ = parse_touch(verb, &words) catch |err| {
            // Logged, so a test of a script that mustn't read stays quiet (std.testing
            // keeps only warnings), while a run on the Kindle shows which line
            log.info("FAIL {d}: {s}: {s}, before any touch", .{
                line_number, std.mem.trim(u8, code, " \t\r"), @errorName(err),
            });
            bad += 1;
        };
    }
    assert(bad <= line_number);
    return bad == 0;
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
        try touch(run, try parse_touch(verb, &words) orelse return error.Usage);
    }
    return null;
}

/// A touch a script makes, or the power button, read from its line.
const Touch = union(enum) {
    power,
    tap: Target,
    hold: struct { at: Target, ms: u32 },
    drag: struct { from: Target, to: Target, ms: u32, hold_ms: u32 },
};

/// Where a touch lands: a point known before the run (a control by name, or
/// "<x> <y>"), or what noface placed with the page, by "placed <what>", found in its log
/// as the step is played (screens/placed.zig).
const Target = union(enum) {
    at: Point,
    placed: core.placed.What,

    /// The point, looked up in the log for what noface placed: where it last drew it.
    fn resolve(t: Target, run: *const Run) Failure!Point {
        assert(run.log_path[0] != 0);
        const what = switch (t) {
            .at => |p| return p,
            .placed => |w| w,
        };
        const text = core.file.map(run.log_path) catch return error.NoLog;
        defer core.file.unmap(text);
        assert(text.len > 0); // A mapped file is never empty
        return core.placed.find(text, @tagName(what)) orelse error.NotPlaced;
    }
};

/// The touch a line's words say, its points by name or as "<x> <y>"; null for a line
/// that isn't a touch. Every line is read this way before the first touch is made, so a
/// name no place has stops the run before it taps anything.
fn parse_touch(verb: []const u8, words: *Words) Failure!?Touch {
    assert(verb.len > 0);
    if (std.mem.eql(u8, verb, "power")) return .power;
    if (std.mem.eql(u8, verb, "tap")) return .{ .tap = try target(words) };
    if (std.mem.eql(u8, verb, "hold")) {
        const at = try target(words);
        return .{ .hold = .{ .at = at, .ms = try number(words) } };
    }
    if (std.mem.eql(u8, verb, "drag")) {
        const from = try target(words);
        const to = try target(words);
        const ms = try number(words);
        // A hold first, for selecting: a word that isn't a number is a mistake, not none
        const hold_ms: u32 = if (words.peek() != null) try number(words) else 0;
        return .{ .drag = .{ .from = from, .to = to, .ms = ms, .hold_ms = hold_ms } };
    }
    return null;
}

/// Plays a touch, or the power button.
fn touch(run: *Run, t: Touch) Failure!void {
    assert(!run.panel.finger_down);
    run.mark();
    switch (t) {
        .power => try press_power(),
        .tap => |to| {
            const at = try to.resolve(run);
            run.panel.down(at.x, at.y);
            sleep_ms(touchsim.tap_ms);
            run.panel.up();
        },
        .hold => |h| {
            const at = try h.at.resolve(run);
            run.panel.down(at.x, at.y);
            sleep_ms(h.ms);
            run.panel.up();
        },
        .drag => |d| drag(run, try d.from.resolve(run), try d.to.resolve(run), d.ms, d.hold_ms),
    }
    run.lifted();
}

/// A finger moved in `drag_steps` even steps over `total_ms`, held still at `from` for
/// `hold_ms` first.
fn drag(run: *Run, from: Point, to: Point, total_ms: u32, hold_ms: u32) void {
    assert(!run.panel.finger_down);
    run.panel.down(from.x, from.y);
    sleep_ms(hold_ms);
    var x = from.x;
    var y = from.y;
    for (1..drag_steps + 1) |index| {
        sleep_ms(total_ms / drag_steps);
        const i: i32 = @intCast(index);
        x = from.x + @divTrunc((to.x - from.x) * i, drag_steps);
        y = from.y + @divTrunc((to.y - from.y) * i, drag_steps);
        run.panel.move(x, y);
    }
    // The last step lands where the drag ends
    assert(x == to.x);
    assert(y == to.y);
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

/// The next point: a place by name (screens/places.zig), or "<x> <y>" for what isn't a
/// control, like a word on the page.
/// A tap's or a hold's target: "placed <what>", or a point.
fn target(words: *Words) Failure!Target {
    if (words.peek()) |word| if (std.mem.eql(u8, word, "placed")) {
        _ = words.next(); // The word just looked at
        const name = words.next() orelse return error.Usage;
        assert(name.len > 0); // A word, from splitting on spaces
        const what = std.meta.stringToEnum(core.placed.What, name) orelse return error.UnknownPlace;
        return .{ .placed = what };
    };
    const at = try point(words);
    // On the screen: a control's place is, and a typed point is read as a u16
    assert(at.x >= 0);
    assert(at.y >= 0);
    return .{ .at = at };
}

fn point(words: *Words) Failure!Point {
    const word = words.next() orelse return error.Usage;
    assert(word.len > 0);
    if (!std.ascii.isDigit(word[0])) return core.places.find(word) orelse error.UnknownPlace;
    const x = std.fmt.parseInt(u16, word, 10) catch return error.Usage;
    const y_word = words.next() orelse return error.Usage;
    const y = std.fmt.parseInt(u16, y_word, 10) catch return error.Usage;
    return .{ .x = x, .y = y };
}

/// The next word as a number.
fn number(words: *Words) Failure!u32 {
    const word = words.next() orelse return error.Usage;
    assert(word.len > 0);
    return std.fmt.parseInt(u32, word, 10) catch return error.Usage;
}

test "every script reads, each place it names found" {
    for (suite) |script| try std.testing.expect(script_reads(script.text));
    try std.testing.expect(!script_reads("tap toolbar.nothing\n"));
    try std.testing.expect(script_reads("tap 10 20 # A word\ntap page.forward\n"));
    try std.testing.expect(script_reads("tap placed note\nhold placed picture 700\n"));
    try std.testing.expect(!script_reads("tap placed nothing\n"));
    try std.testing.expect(script_reads("drag placed paragraph placed paragraph_end 400 700\n"));
}

test "a shelf's books are named as a reader's copies would be, the first by its title" {
    var buffer: [core.file.own_path_bytes_max]u8 = undefined;
    const first = try book_path(&buffer, "t/books", .books, 0);
    try std.testing.expectEqualStrings("t/books/documents/Scenario Book.epub", first);
    const second = try book_path(&buffer, "t/books", .books, 1);
    try std.testing.expectEqualStrings("t/books/documents/Scenario Book 02.epub", second);
    const last = try book_path(&buffer, "t/books", .books, scenario_copies - 1);
    try std.testing.expectEqualStrings("t/books/documents/Scenario Book 14.epub", last);
    const notes = try book_path(&buffer, "t/notes", .notes, 0);
    try std.testing.expectEqualStrings("t/notes/documents/Notes and Pictures.epub", notes);
}
