//! The noface launcher (noface-launch): starts noface on the Kindle, and puts the
//! Kindle's own screens back however noface ends. A program of its own, apart from
//! noface, so that noface crashing, hanging, being killed (`killall noface`) or missing
//! never takes it down with it: it is what makes the Kindle usable again.
//!
//!   noface-launch [kpm]     From KPM (";kpm launch noface"): returns at once, and opens
//!                           noface 2 s later, once KPM has repainted the stock screen.
//!   noface-launch now       The same without the wait: over SSH, or after an update.
//!   noface-launch autostart From the system's startup file, at boot (src/kindle/boot.zig).
//!   noface-launch export    Writes the book list (src/kindle/catalog_export.zig).
//!
//! KPM's launch.sh passes no argument, which means "kpm".
//! What it prints goes to noface-data/launch.log; noface's own output to noface.log.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("kindle/paths.zig");
const boot = @import("kindle/boot.zig");
const catalog_export = @import("kindle/catalog_export.zig");
const stock_ui = @import("kindle/stock_ui.zig");
const supervisor = @import("kindle/supervisor.zig");
const wifi_saver = @import("kindle/wifi_saver.zig");
const service = @import("sys/service.zig");
const os = @import("sys/os.zig");

const launch_log = paths.data_dir ++ "/" ++ paths.data.launch_log;

const Mode = enum { kpm, now, autostart, export_list };

/// From the search bar, KPM repaints the stock screen about 2 s after launching:
/// noface starts after that, so it isn't drawn over.
const kpm_wait_ms = 2_000;
/// At boot, the Kindle's home gets a moment to finish drawing before noface opens over it.
const boot_wait_ms = 20_000;
/// At boot, the connection manager gets this long to come up before Wi-Fi is put back.
const boot_wifi_wait_ms = 30_000;

comptime {
    assert(kpm_wait_ms < boot_wait_ms);
    assert(std.mem.endsWith(u8, paths.launcher, "/noface-launch"));
}

/// A code address, as the panic handler is given one: the size of a pointer.
const Address = @Int(.unsigned, @bitSizeOf(*const anyopaque));

/// A crash in the launcher must still put the Kindle's own screens back.
pub const panic = std.debug.FullPanic(struct {
    fn crash(message: []const u8, first: ?Address) noreturn {
        if (stock_ui.paused) stock_ui.restore();
        std.debug.defaultPanic(message, first);
    }
}.crash);

pub fn main(init: std.process.Init.Minimal) void {
    const argv = init.args.vector;
    assert(argv.len >= 1); // The program's own name comes first
    const argument: []const u8 = if (argv.len >= 2) std.mem.sliceTo(argv[1], 0) else "kpm";
    const mode = mode_of(argument);
    const envp: [*:null]const ?[*:0]const u8 = init.environ.block.slice.ptr;
    assert(envp[init.environ.block.slice.len] == null); // As execve wants it
    switch (mode) {
        .export_list => catalog_export.run(),
        .autostart => autostart(envp),
        .kpm, .now => {
            // KPM (or the shell) gets its prompt back straight away
            const side = service.detach(launch_log) catch |err| {
                std.debug.print("launch: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            if (side == .parent) return;
            if (mode == .kpm) os.sleep_ms(kpm_wait_ms);
            start(envp);
        },
    }
}

/// Which mode an argument asks for; anything not named is KPM's.
pub fn mode_of(argument: []const u8) Mode {
    assert(@typeInfo(Mode).@"enum".field_names.len == 4);
    if (std.mem.eql(u8, argument, "now")) return .now;
    if (std.mem.eql(u8, argument, "export")) return .export_list;
    if (std.mem.eql(u8, argument, "autostart")) return .autostart;
    assert(!std.mem.eql(u8, argument, "now"));
    return .kpm;
}

/// At boot: puts back Wi-Fi left off by a restart mid-book, and opens noface if the
/// reader asked for that and it hasn't failed to start three boots in a row. Returns
/// at once, so boot carries on.
fn autostart(envp: [*:null]const ?[*:0]const u8) void {
    assert(envp[0] == null or envp[0].?[0] != 0);
    if (!boot.first_this_boot()) return;
    // Airplane mode noface turned on for reading, left on by a hard restart mid-book:
    // undo it now, at boot, before the reader can make airplane mode their own choice.
    // In the background, as the connection manager may not be up yet.
    if (wifi_saver.marked()) {
        const side = service.detach("/dev/null") catch .parent; // Not forked: tried next start
        if (side == .child) {
            os.sleep_ms(boot_wifi_wait_ms);
            wifi_saver.restore();
            std.process.exit(0);
        }
    }
    if (!boot.should_start()) return;
    assert(!stock_ui.paused);
    // Straight to noface rather than through KPM: KPM's waits are for the search
    // keyboard, which isn't there at boot
    const side = service.detach(launch_log) catch |err| {
        std.debug.print("autostart: {s}\n", .{@errorName(err)});
        return;
    };
    if (side == .parent) return;
    os.sleep_ms(boot_wait_ms);
    start(envp);
}

/// Opens noface: ends Amazon's jobman (which competes for the screen), writes the book
/// list, then runs noface until it ends. Ends the process.
fn start(envp: [*:null]const ?[*:0]const u8) noreturn {
    assert(!stock_ui.paused);
    print_launch_time(os.unix_time());
    _ = service.signal_named("jobman", .TERM);
    catalog_export.run();
    const code = supervisor.run(envp);
    assert(!stock_ui.paused);
    std.process.exit(@intCast(@min(code, 255)));
}

/// "launch Sat Nov 14 10:00:00 UTC 2026", as `date` printed it.
fn print_launch_time(unix_seconds: u64) void {
    assert(unix_seconds > 0);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = unix_seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    assert(month_day.month.numeric() >= 1);
    std.debug.print("launch {s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} UTC {d}\n", .{
        weekdays[@intCast(day.day % 7)], // 1 Jan 1970 was a Thursday
        months[month_day.month.numeric() - 1],
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
        year_day.year,
    });
}

test "each way in is told apart" {
    try std.testing.expectEqual(Mode.kpm, mode_of("/mnt/us/kmc/kpm/packages/noface/launch.sh"));
    try std.testing.expectEqual(Mode.kpm, mode_of("kpm"));
    try std.testing.expectEqual(Mode.now, mode_of("now"));
    try std.testing.expectEqual(Mode.export_list, mode_of("export"));
    try std.testing.expectEqual(Mode.autostart, mode_of("autostart"));
}
