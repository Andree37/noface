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
const paths = @import("kindle/paths.zig");
const setup = @import("setup.zig");
const fonts_db = @import("kindle/fonts.zig");
const memory = @import("base/memory.zig");
const decoder_memory = @import("gfx/decoder_memory.zig");
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
const dict_download = @import("kindle/dict_download.zig");

/// The arguments noface is started with to read: its own name, the library, four
/// fonts and the data folder.
const reader_arguments_count = 7;

/// A crash during `noface selftest` must say why, though the scenarios hide the app's
/// own messages while they run.
pub const panic = std.debug.FullPanic(struct {
    fn crash(msg: []const u8, first: ?usize) noreturn { // usize: Zig's panic handler signature
        @import("scenarios.zig").show_crashes();
        std.debug.defaultPanic(msg, first);
    }
}.crash);

/// Whether a font of the reader's own can set text: it opens, has letters, and draws
/// some. Run in a child process by find_own, so a damaged one only ends that.
fn sets_text(data: []const u8) bool {
    if (!Font.usable(data)) return false;
    assert(Font.tables_inside(data)); // Checked by usable, before opening it
    var font = Font.init(std.heap.page_allocator, data, 30, 1.2) catch return false;
    assert(font.line_height > 0); // Set from the size asked for
    _ = font.measure("Aa Bb Gg Qq yj 0123 .,;!?") catch return false;
    return true;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    assert(argv.len >= 1); // The program's own name comes first
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
        const data_dir = if (argv.len >= 3) std.mem.sliceTo(argv[2], 0) else paths.data_dir;
        battery_log.report(1, data_dir);
        return;
    }
    if (argv.len != reader_arguments_count) return error.Usage;
    try main_reader(init);
}

/// Reads: the library, then books, until noface quits.
fn main_reader(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    assert(argv.len == reader_arguments_count);
    // Reserved now; a book's, the library's and one action's by setup.assemble
    var app_region = try memory.Region.reserve("app", .heap, setup.region_bytes.app);
    var app_budget = memory.Budget{
        .name = "app",
        .region = &app_region,
        .limit = setup.region_bytes.app,
    };
    const alloc = app_budget.allocator();
    var decoders_region = try memory.Region.reserve("decoders", .heap, setup.region_bytes.decoders);
    var decoders_budget = memory.Budget{
        .name = "decoders",
        .region = &decoders_region,
        .limit = setup.region_bytes.decoders,
    };
    decoder_memory.use(&decoders_budget);

    const state_dir = std.mem.sliceTo(argv[6], 0);

    const font_files = try main_reader_fonts(argv);
    // A display noface can't drive: say why in the log, and hand back to the Kindle
    var screen = hwtcon.Screen.open() catch |err| {
        std.debug.print("noface can't start: {s}\n", .{@errorName(err)});
        _ = doctor.report(2);
        return err;
    };
    var kit = try setup.Kit.init(alloc, font_files);

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
        } else |_| {}
    }

    var files: setup.DataFiles = .{};
    try files.init(state_dir);
    assert(files.settings.len > state_dir.len); // The data folder, then the file's name
    // Before the settings: a chosen typeface of the reader's is found by name
    fonts_db.find_own(alloc, sets_text);
    var shared = try setup.assemble(.{
        .alloc = alloc,
        .app_budget = &app_budget,
        .decoders_budget = &decoders_budget,
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
    assert(shared.settings_path == files.settings.ptr); // Assembled from these files
    // A different folder for EPUBs, for a demo or test run beside the real library
    shared.documents = if (init.environ.getPosix("NOFACE_DOCUMENTS")) |d| d else paths.documents;
    shared.dictionary_base = init.environ.getPosix("NOFACE_DICT_URL") orelse
        dict_download.default_base;
    shared.utc_offset = clock.utc_offset();
    shared.apply_settings() catch {
        shared.settings = .{};
        try shared.apply_settings();
    };
    assert(shared.layout.faces != null); // Set by apply_settings
    assert(shared.body.line_height > 0);
    // Older files come back in the current format
    app.save_settings(files.settings, shared.settings);
    // On, but the system's startup file isn't this version's (an older install's points
    // somewhere that no longer reads the settings): put the current one back, as the
    // reader agreed to when they turned it on
    if (shared.settings.autostart and autostart.outdated()) {
        const installed = autostart.install();
        std.debug.print("autostart: startup file out of date, reinstalled: {}\n", .{installed});
    }
}
