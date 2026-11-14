//! noface: a fast reader with its own home screen.
//! Usage: noface <library.tsv> <body.ttf> <title.ttf> <ui.ttf> <ui-bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Tapping the top of a page opens the toolbar. Dragging down from the top opens
//! the quick panel, in a book or in the library.
//! The power button locks, showing the current book's cover. Waking returns to the
//! same place. The panel's Kindle button and Wi-Fi settings hand over to the stock UI.
const std = @import("std");
const paths = @import("kindle/paths.zig");
const setup = @import("setup.zig");
const fonts_db = @import("kindle/fonts.zig");
const memory = @import("base/memory.zig");
const c_memory = @import("gfx/c_memory.zig");
const Font = @import("gfx/font.zig").Font;
const file = @import("sys/file.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const library = @import("ui/library.zig");
const clock = @import("sys/clock.zig");
const input_mod = @import("kindle/input.zig");
const app = @import("app.zig");
const library_screen = @import("screens/library.zig");
const wifi_saver = @import("kindle/wifi_saver.zig");
const doctor = @import("kindle/doctor.zig");
const autostart = @import("kindle/autostart.zig");
const battery_log = @import("kindle/battery_log.zig");

/// A crash during `noface selftest` must say why, though the scenarios hide the app's
/// own messages while they run.
pub const panic = std.debug.FullPanic(struct {
    fn crash(msg: []const u8, first: ?usize) noreturn {
        @import("scenarios.zig").showCrashes();
        std.debug.defaultPanic(msg, first);
    }
}.crash);

/// Whether a font of the reader's own can set text: it opens, has letters, and draws
/// some. Run in a child process by findOwn, so a damaged one only ends that.
fn setsText(data: []const u8) bool {
    if (!Font.usable(data)) return false;
    var font = Font.init(std.heap.page_allocator, data, 30, 1.2) catch return false;
    _ = font.measure("Aa Bb Gg Qq yj 0123 .,;!?") catch return false;
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    // `noface doctor`: what this Kindle has, and whether noface can run on it
    if (argv.len == 2 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "doctor")) {
        std.process.exit(if (doctor.report(1)) 0 else 1);
    }
    // `noface battery-report [data folder]`: how the battery has done off the charger
    // `noface selftest`: noface's own checks, run here, changing nothing
    if (argv.len == 2 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "selftest")) {
        std.process.exit(if (@import("scenarios.zig").selftest()) 0 else 1);
    }
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "battery-report")) {
        battery_log.report(1, if (argv.len >= 3) std.mem.sliceTo(argv[2], 0) else paths.data_dir);
        return;
    }
    if (argv.len != 7) return error.Usage;
    // Everything that lives as long as the app: screen buffers, fonts, picture cache.
    var app_budget = memory.Budget{ .name = "app", .child = std.heap.smp_allocator, .limit = 96 << 20 };
    const alloc = app_budget.allocator();
    // Glyph bitmaps and decoded pictures from the stb C libraries.
    var stb_budget = memory.Budget{ .name = "stb", .child = std.heap.smp_allocator, .limit = 128 << 20 };
    c_memory.use(&stb_budget);

    const state_dir = std.mem.sliceTo(argv[6], 0);

    const regular = try file.map(argv[2]);
    const book_bold = try file.map(argv[3]);
    const ui_regular = try file.map(argv[4]);
    const ui_bold = try file.map(argv[5]);
    // A display noface can't drive: say why in the log, and hand back to the Kindle
    var screen = hwtcon.Screen.open() catch |err| {
        std.debug.print("noface can't start: {s}\n", .{@errorName(err)});
        _ = doctor.report(2);
        return err;
    };
    var kit = try setup.Kit.init(alloc, .{ .book = regular, .book_bold = book_bold, .ui = ui_regular, .ui_bold = ui_bold });

    var input = try input_mod.open(screen.width, screen.height);
    defer input_mod.release(&input);

    input_mod.installSignals();
    wifi_saver.useDataDir(state_dir);
    wifi_saver.restore(); // Left off by a crash or a reboot mid-book
    const saved_screen = try alloc.alloc(u8, screen.pixels.len);
    @memcpy(saved_screen, screen.pixels);
    defer {
        @memcpy(screen.pixels, saved_screen);
        if (screen.show(.flash)) |m| {
            screen.waitComplete(m) catch {};
        } else |_| {}
    }

    var files: setup.DataFiles = .{};
    try files.init(state_dir);
    fonts_db.findOwn(alloc, setsText); // Before the settings: a chosen typeface of the reader's is found by name
    var shared = try setup.assemble(.{
        .alloc = alloc,
        .app_budget = &app_budget,
        .stb_budget = &stb_budget,
        .screen = &screen,
        .input = &input,
        .kit = &kit,
        .data_dir = state_dir,
        .files = &files,
        .library_path = argv[1],
    });
    // A different folder for EPUBs, for a demo or test run beside the real library
    shared.documents = if (init.environ.getPosix("NOFACE_DOCUMENTS")) |d| d else paths.documents;
    shared.dictionary_base = init.environ.getPosix("NOFACE_DICT_URL") orelse @import("kindle/dict_download.zig").default_base;
    shared.utc_offset = clock.utcOffset();
    shared.applySettings() catch {
        shared.settings = .{};
        try shared.applySettings();
    };
    app.saveSettings(files.settings, shared.settings); // Older files come back in the current format
    // On, but the system's startup file isn't this version's (an older install's points
    // somewhere that no longer reads the settings): put the current one back, as the
    // reader agreed to when they turned it on
    if (shared.settings.autostart and autostart.outdated()) {
        std.debug.print("autostart: startup file out of date, reinstalled: {}\n", .{autostart.install()});
    }
    try library_screen.runLibrary(&shared);
    std.debug.print("quit\n", .{});
}
