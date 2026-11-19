//! The noface app: a fast reader with its own home screen.
//! Usage: noface <library.tsv> <body.ttf> <title.ttf> <ui.ttf> <ui-bold.ttf> <state-dir>
//!
//! In a book, touch-down turns the page: left third goes back, the rest forward.
//! Tapping the top of a page opens the toolbar. Dragging down from the top opens
//! the quick panel, in a book or in the library.
//! The power button locks, showing the current book's cover. Waking returns to the
//! same place. The panel's Kindle button and Wi-Fi settings hand over to the stock UI.
const std = @import("std");
const assert = std.debug.assert;
const scenarios = @import("scenarios.zig");
const paths = @import("kindle/paths.zig");
const setup = @import("setup.zig");
const fonts_db = @import("kindle/fonts.zig");
const memory = @import("base/memory.zig");
const decoder_memory = @import("gfx/decoder_memory.zig");
const Font = @import("gfx/font.zig").Font;
const Page = @import("gfx/page.zig").Page;
const file = @import("sys/file.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const clock = @import("sys/clock.zig");
const input_mod = @import("kindle/input.zig");
const app = @import("app.zig");
const library_screen = @import("screens/library.zig");
const wifi_saver = @import("kindle/wifi_saver.zig");
const doctor = @import("kindle/doctor.zig");
const autostart = @import("kindle/autostart.zig");
const dict_download = @import("kindle/dict_download.zig");

/// What noface logs goes to noface.log as plain lines, as its other output does.
pub const std_options: std.Options = .{ .logFn = plain_log };

fn plain_log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    arguments: anytype,
) void {
    _ = level; // Every level is a line of the same log
    _ = scope;
    std.debug.print(format ++ "\n", arguments);
}

/// The arguments noface is started with to read: its own name, the library, four
/// fonts and the data folder.
const reader_arguments_count = 7;

/// A crash during `noface selftest` must say why, though the scenarios hide the app's
/// own messages while they run.
pub const panic = std.debug.FullPanic(struct {
    fn crash(msg: []const u8, first: ?usize) noreturn { // usize: Zig's panic handler signature
        scenarios.show_crashes();
        std.debug.defaultPanic(msg, first);
    }
}.crash);

/// Whether a font of the reader's own can set text: it opens, has letters, and draws
/// some. Run in a child process by find_own, so a damaged one only ends that.
fn sets_text(data: []const u8) bool {
    if (!Font.usable(data)) return false;
    assert(Font.tables_inside(data)); // Checked by usable, before opening it
    var font = Font.init(data, 30, 1.2) catch return false;
    assert(font.line_height > 0); // Set from the size asked for
    const sample = "Aa Bb Gg Qq yj 0123 .,;!?";
    _ = font.measure(sample) catch return false;
    // Drawn too, so its outlines are read and rasterized here, where a crash ends only
    // this trial, not the reader's first page set in it. Each glyph is made whole
    // before it's clipped to the page, so a small page is enough
    var pixels: [64 * 48]u8 = @splat(0xff);
    const page: Page = .{ .buf = &pixels, .width = 64, .height = 48, .stride = 64 };
    font.draw(page, 0, 40, sample) catch return false;
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    assert(argv.len >= 1); // The program's own name comes first
    // `noface doctor`: what this Kindle has, and whether noface can run on it
    if (argv.len == 2 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "doctor")) {
        std.process.exit(if (doctor.report(1)) 0 else 1);
    }
    // `noface selftest`: noface's own checks, run here, changing nothing
    if (argv.len == 2 and std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "selftest")) {
        std.process.exit(if (scenarios.selftest()) 0 else 1);
    }
    if (argv.len != reader_arguments_count) return error.Usage;
    try main_reader(init);
}

/// Reads: the library, then books, until noface quits.
fn main_reader(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    assert(argv.len == reader_arguments_count);
    // The watchdog's two minutes start now, not from a beat left by an earlier run: what
    // runs long before the loop first turns (a library built) beats on its own
    input_mod.beat_to(paths.heartbeat);
    // Reserved now; a book's, the library's and one action's by setup.assemble
    var app_region = try memory.Region.reserve("app", .heap, setup.region_bytes.app);
    var app_budget = memory.Budget{
        .name = "app",
        .region = &app_region,
        .limit = setup.region_bytes.app,
    };
    const alloc = app_budget.allocator();
    const decoders_budget = try setup.decoders();
    decoder_memory.use(decoders_budget);
    try setup.use_glyph_cache();
    // Characters the reading fonts haven't got, a Chinese name or note in an English
    // book, come from the Kindle's own Chinese typeface rather than as empty boxes
    main_reader_fallback();

    const state_dir = std.mem.sliceTo(argv[6], 0);

    const font_files = try main_reader_fonts(argv);
    // A display noface can't drive: say why in the log, and hand back to the Kindle
    var screen = hwtcon.Screen.open() catch |err| {
        std.debug.print("noface can't start: {s}\n", .{@errorName(err)});
        _ = doctor.report(2);
        return err;
    };
    var kit = try setup.Kit.init(font_files);

    var input = try input_mod.open(screen.width, screen.height);
    defer input_mod.release(&input);

    input_mod.install_signals();
    wifi_saver.use_data_dir(state_dir);
    wifi_saver.restore(); // Left off by a crash or a reboot mid-book
    const saved_screen = try alloc.alloc(u8, screen.pixels.len);
    assert(saved_screen.len == screen.pixels.len); // Put back whole as noface leaves
    @memcpy(saved_screen, screen.pixels);
    defer {
        @memcpy(screen.pixels, saved_screen);
        if (screen.show(.flash)) |m| {
            screen.wait_complete(m) catch {}; // Ignored: the Kindle draws its own screen next.
        } else |_| {} // Ignored: not shown, the Kindle draws its own screen next.
    }

    var files: setup.DataFiles = .{};
    try files.init(state_dir);
    assert(files.settings.len > state_dir.len); // The data folder, then the file's name
    // Before the settings: a chosen typeface of the reader's is found by name
    fonts_db.find_own(alloc, sets_text);
    var shared = try setup.assemble(.{
        .alloc = alloc,
        .app_budget = &app_budget,
        .decoders_budget = decoders_budget,
        .screen = &screen,
        .input = &input,
        .kit = &kit,
        .data_dir = state_dir,
        .files = &files,
        .library_path = argv[1],
    });
    try main_reader_configure(&shared, init, &files);
    memory.seal(); // From here on, every allocation comes out of a region reserved above
    try library_screen.run_library(&shared);
    std.debug.print("quit\n", .{});
}

/// Gives the fonts the Kindle's Chinese typeface for characters they haven't got. A
/// Kindle without it draws those as the fonts' empty boxes, as before.
// Assertions: none; what it reads is the Kindle's file, checked by `Font.use_fallback`.
fn main_reader_fallback() void {
    const data = file.map(paths.fallback_font) catch |err| {
        std.debug.print("no fallback font: {s}\n", .{@errorName(err)});
        return;
    };
    const opened = Font.use_fallback(data) catch |err| {
        std.debug.print("no fallback font: {s}\n", .{@errorName(err)});
        return;
    };
    if (!opened) std.debug.print("no fallback font: not a font\n", .{});
}

/// The four fonts named on the command line, mapped.
fn main_reader_fonts(argv: []const [*:0]const u8) !setup.FontFiles {
    assert(argv.len == reader_arguments_count);
    const files: setup.FontFiles = .{
        .book = try file.map(argv[2]),
        .book_bold = try file.map(argv[3]),
        .ui = try file.map(argv[4]),
        .ui_bold = try file.map(argv[5]),
    };
    // An empty file is an error from file.map
    assert(files.book.len > 0);
    assert(files.ui.len > 0);
    return files;
}

/// What differs on the Kindle from an App as assembled: where books and dictionaries
/// come from, the clock's offset, and the settings brought up to date.
fn main_reader_configure(
    shared: *app.App,
    init: std.process.Init.Minimal,
    files: *const setup.DataFiles,
) !void {
    assert(shared.user.files.settings == files.settings.ptr); // Assembled from these files
    // A different folder for EPUBs, for a demo or test run beside the real library
    shared.documents = if (init.environ.getPosix("NOFACE_DOCUMENTS")) |d| d else paths.documents;
    shared.dictionary_base = init.environ.getPosix("NOFACE_DICT_URL") orelse
        dict_download.default_base;
    shared.utc_offset = clock.utc_offset();
    shared.apply_settings() catch {
        shared.user.settings = .{};
        try shared.apply_settings();
    };
    assert(shared.layout.faces != null); // Set by apply_settings
    assert(shared.body.line_height > 0);
    // On, but the system's startup file isn't the one this version ships (an update
    // changed it): put the current one back, as the reader agreed to when they turned
    // it on
    if (shared.user.settings.autostart and autostart.outdated()) {
        const installed = autostart.install();
        std.debug.print("autostart: startup file out of date, reinstalled: {}\n", .{installed});
    }
}
