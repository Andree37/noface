//! The scenario tests, noface-scenarios: plays scripted touches through the real app,
//! on a screen in memory and a clock it moves itself, and checks what came of them.
//! Each scenario gets its own folder under /tmp and a generated book, so nothing of the
//! reader's is read or written, and the screen is never touched.
//!
//! Built for Linux: GitHub runs it on every change, and on the Kindle it's the
//! self-test (`noface-scenarios`), done in seconds.
const std = @import("std");
const assert = std.debug.assert;
const folders = @import("sys/dir.zig");
const hyphen = @import("layout/hyphen.zig");
const file = @import("sys/file.zig");
const fonts_db = @import("kindle/fonts.zig");
const process = @import("sys/process.zig");
const image = @import("gfx/image.zig");
const app = @import("app.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const input_mod = @import("kindle/input.zig");
const Font = @import("gfx/font.zig").Font;
const decoder_memory = @import("gfx/decoder_memory.zig");
const memory = @import("base/memory.zig");
const catalog = @import("model/catalog.zig");
const kindle_catalog = @import("kindle/catalog.zig");
const annotation_db = @import("kindle/annotation_db.zig");
const settings_model = @import("model/settings.zig");
const state = @import("sys/state.zig");
const page_store = @import("screens/reader/page_store.zig");
const os = @import("sys/os.zig");
const reader = @import("screens/reader.zig");
const library_screen = @import("screens/library.zig");
const library_ui = @import("ui/library.zig");
const card = @import("ui/card.zig");
const menu_ui = @import("ui/menu.zig");
const style = @import("ui/style.zig");
const toolbar = @import("ui/toolbar.zig");
const aa = @import("ui/aa.zig");
const dictionary = @import("model/dictionary.zig");
const FakeKindle = @import("testing/fake_kindle.zig").FakeKindle;
const wifi_saver = @import("kindle/wifi_saver.zig");
const paths = @import("kindle/paths.zig");
const setup = @import("setup.zig");
const linux = @import("sys/calls.zig");

const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
const book_bytes = @embedFile("testdata/scenario.epub");

const Step = input_mod.Step;
const width = 1272;
const height = 1696;

/// Where the toolbar's buttons are tapped, down from the top of the screen.
const toolbar_button_y = 118;

/// Row `i` of a card of `rows`.
fn card_row(rows: u32, i: u32) Step {
    assert(rows > 0);
    assert(i < rows);
    return tap(636, @intCast(card.row_centre(rows, i)));
}
const highlight_button = tap(122, 1596); // On the definition sheet
const above_sheet = tap(636, 300);

fn tap(x: i32, y: i32) Step {
    // A tap the script makes lands on the screen
    assert(x >= 0);
    assert(x < width);
    assert(y >= 0);
    assert(y < height);
    return .{ .act = .{ .tap = .{ .x = x, .y = y, .us = 0 } } };
}
fn hold(x: i32, y: i32) Step {
    // A hold the script makes lands on the screen
    assert(x >= 0);
    assert(x < width);
    assert(y >= 0);
    assert(y < height);
    return .{ .act = .{ .hold = .{ .x = x, .y = y } } };
}
/// The finger leaving the glass, as it does after a hold.
const lift: Step = .{ .act = .drag_end };
fn swipe(direction: i32) Step {
    assert(direction != 0); // Forward or back, never neither
    assert(direction >= -1);
    assert(direction <= 1);
    return .{ .act = .{ .swipe = .{ .direction = direction, .us = 0 } } };
}
fn wait(ms: u64) Step {
    assert(ms > 0);
    assert(ms <= 3_600_000); // A scenario spans minutes, not hours
    return .{ .wait_ms = ms };
}
const lock_it: Step = .{ .act = .lock };
const wake: Step = .{ .act = .unlock };
/// The quick panel pulled down from the top, and its Kindle button, which leaves noface.
const pull_down: Step = .{ .act = .pull };
const panel_kindle = tap(795, 430);
const forward = tap(1000, 900);
const back = tap(150, 900);
const top = tap(636, 60);
const page_middle = tap(636, 1000);
/// A hold on a word of the first page.
const a_word = hold(600, 700);

comptime {
    // The pretend screen is the one the interface is laid out for
    assert(width == style.screen_width);
    assert(height == style.screen_height);
    // A tap on the left third of a page goes back, the rest forward
    assert(back.act.tap.x < width / 3);
    assert(forward.act.tap.x >= width / 3);
    // `top` opens the toolbar; the middle of the page is outside it, and closes it
    assert(top.act.tap.y < toolbar.top_height);
    assert(toolbar_button_y < toolbar.top_height);
    assert(page_middle.act.tap.y > toolbar.top_height);
    assert(page_middle.act.tap.y < toolbar.bottom_top);
    // A word is held in the page's text, clear of the toolbar's two parts
    assert(a_word.act.hold.y > toolbar.top_height);
    assert(a_word.act.hold.y < toolbar.bottom_top);
    // A tap above a card of up to two rows closes it
    assert(above_sheet.act.tap.y < card.top(2));
    // The panel's Kindle button is where the scenarios tap it
    assert(menu_ui.hit(panel_kindle.act.tap.x, panel_kindle.act.tap.y) == .kindle);
}

/// What a run left behind, for the checks.
const Outcome = struct {
    saved: state.State,
    updates: u32,
    airplane_asked_on: bool, // Whether noface asked for airplane mode at some point
    airplane_at_end: bool, // The Kindle's airplane mode when it was over
    wifi_note_left: bool, // Whether noface's "I turned Wi-Fi off" note is still there
    looked_up: bool, // The dictionary was opened for a word
    offers_dictionary: bool, // Still asks to download a missing dictionary
    ms: u64, // How long the run took, by the wall clock
    // The screen at the end matched its reference image, if one was asked for
    looks_right: bool,
    opened: [2]bool, // Whether the first two books were opened
    finished: [2]bool, // Whether they were marked finished
    highlights: u32, // Highlights and bookmarks saved for the book
    bookmarks: u32,
    // The most of the book's region, and of the pages', in use at once
    book_peak: u64,
    pages_peak: u64,
    breaks: u64, // A digest of the page breaks saved for the book, 0 when none were
};

/// The most books a scenario puts in the documents folder.
const books_max = 4;

/// How the pretend Kindle starts, and where a scenario begins.
const Kindle = struct {
    airplane: bool = false,
    bluetooth: bool = false,
    dictionary: bool = false,
    /// The books in the documents folder, all the scenario book under these names. A
    /// scenario that starts in a book opens the first.
    books: []const []const u8 = &.{"book.epub"},
    /// Starts in the library instead of the first book.
    library: bool = false,
    /// A book read a while already, so the library shows it to continue.
    read_before: ?u32 = null,
    /// One of the reader's own books, opened where it is (never written to), with the
    /// Kindle's own fonts and its own highlights: the self-test's real books.
    real_book: ?RealBook = null,
    /// Wi-Fi's on/off goes unanswered right after it's set.
    radio_slow: bool = false,
    /// Compares the screen at the end with the reference image of this name.
    snapshot: ?Snapshot = null,
};

/// One of the reader's own books, as the self-test opens it.
const RealBook = struct {
    /// Its row in the book list, whose key finds its notes; an EPUB's made from its path
    entry: catalog.Entry,
    /// The annotation database's answers for it (annotation_db.read_lines), read before
    /// the run: during it the pretend Kindle answers every program noface starts.
    highlights: []const u8 = "",
    bookmarks: []const u8 = "",
};

/// Built as noface-scenarios (GitHub's tests) rather than inside noface: only then are
/// the reference images carried, so they don't weigh on the app.
const with_snapshots = @import("root") == @This();

/// Set (from NOFACE_WRITE_SNAPSHOTS) to write each snapshot's screen to this folder as
/// <name>.pgm, to make new reference images, instead of comparing.
var write_snapshots: ?[]const u8 = null;

fn reference_image(comptime name: []const u8) []const u8 {
    return if (with_snapshots) @embedFile("testdata/snapshots/" ++ name ++ ".png") else "";
}

/// The screens compared with a reference image, each src/testdata/snapshots/<name>.png.
const Snapshot = enum { page, toolbar, @"aa-font", definition, library };

/// Whether `pixels` match the reference image `name`, allowing for anti-aliasing:
/// pixels more than a few grays apart may be at most 1 in 5,000 (about 430), fewer
/// than a short line of text has, so one added or lost is seen.
fn matches_reference(alloc: std.mem.Allocator, which: Snapshot, pixels: []const u8) !bool {
    assert(pixels.len == width * height); // The whole screen, as the script left it
    const name = @tagName(which);
    if (write_snapshots) |dir| {
        try matches_reference_write(alloc, dir, name, pixels);
        return true;
    }
    if (!with_snapshots) return true; // The self-test doesn't carry them
    const encoded = switch (which) {
        inline else => |w| reference_image(@tagName(w)),
    };
    const want = image.decode_gray(alloc, encoded) orelse return error.BadSnapshot;
    if (want.width != width or want.height != height) return false;
    var off: u32 = 0;
    for (pixels, want.pixels) |got, w| {
        if (@max(got, w) - @min(got, w) > 48) off += 1;
    }
    assert(off <= pixels.len);
    if (@as(u64, off) * 5000 > pixels.len) {
        std.debug.print("    {d} pixels differ from the {s} reference\n", .{ off, name });
        return false;
    }
    return true;
}

/// Writes the screen as <dir>/<name>.pgm, for a new reference image.
fn matches_reference_write(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    pixels: []const u8,
) !void {
    assert(name.len > 0);
    assert(pixels.len == width * height);
    var dir_buf: [256]u8 = undefined;
    _ = linux.mkdir(try std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{dir}, 0), 0o755);
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}.pgm", .{ dir, name }, 0);
    var head_buf: [32]u8 = undefined;
    const head = try std.fmt.bufPrint(&head_buf, "P5\n{d} {d}\n255\n", .{ width, height });
    const out = try alloc.alloc(u8, head.len + pixels.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], pixels);
    try write_file(path, out);
}

/// Every word in the scenario book, for a small English dictionary of them.
const book_words = [_][]const u8{
    "a",     "bright", "chapter", "evening", "garden", "green", "house",  "letter",
    "light", "long",   "morning", "new",     "old",    "page",  "quiet",  "reader",
    "river", "road",   "slow",    "small",   "the",    "turns", "window",
};

comptime {
    // A dictionary's words are sorted, as its lookup's binary search needs
    for (book_words[0 .. book_words.len - 1], book_words[1..]) |earlier, later| {
        assert(std.mem.order(u8, earlier, later) == .lt);
    }
}

/// A dictionary file, in the format of model/dictionary.zig, with `book_words`.
fn write_dictionary(alloc: std.mem.Allocator, path: [*:0]const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    for (book_words) |w| { // Already sorted, and already folded
        try offsets.append(alloc, @intCast(body.items.len));
        const definition = "{s}\x00{s}\x00noun\n1 the scenario book's word \"{s}\"\n";
        try body.print(alloc, definition, .{ w, w, w });
    }
    try offsets.append(alloc, @intCast(body.items.len));
    // Where each word starts, and where the last one ends
    assert(offsets.items.len == book_words.len + 1);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, dictionary.magic);
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, book_words.len, .little);
    try out.appendSlice(alloc, &word);
    for (offsets.items) |o| {
        std.mem.writeInt(u32, &word, o, .little);
        try out.appendSlice(alloc, &word);
    }
    try out.appendSlice(alloc, body.items);
    assert(dictionary.Dictionary.open(out.items) != null); // As noface reads it
    try write_file(path, out.items);
}

/// How many lines of `kind` the book's notes file holds.
fn count_notes(state_path: []const u8, kind: []const u8) u32 {
    assert(kind.len > 0);
    assert(state_path.len > 0);
    var path_buf: [320]u8 = undefined;
    const path = state.sibling(&path_buf, state_path, "notes") catch return 0;
    var buf: [8192]u8 = undefined;
    var n: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, file.read_small(path, &buf), '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, kind)) n += 1;
    }
    return n;
}

var run_counter: u32 = 0;

fn play(steps: []const Step) !Outcome {
    return play_on(.{}, steps);
}

/// Opens the scenario book in a fresh app on a pretend Kindle, plays `steps`, and
/// returns what was saved and what the Kindle was asked to do. The app's memory is
/// reserved and sealed as on the Kindle, so one asked of the system as it runs fails
/// the scenario; the harness's own (the pretend Kindle, the folder) is apart from it.
fn play_on(kindle: Kindle, steps: []const Step) !Outcome {
    assert(kindle.books.len > 0);
    assert(kindle.books.len <= books_max);
    if (kindle.read_before) |i| assert(i < kindle.books.len);
    var harness_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer harness_arena.deinit();
    const harness = harness_arena.allocator();

    var dir_buf: [96]u8 = undefined;
    const dir = try play_on_dir(&dir_buf);
    defer clean_up(dir);
    var book_paths: [books_max][:0]const u8 = undefined;
    try play_on_folder(harness, kindle, dir, &book_paths);
    var library_buf: [128]u8 = undefined;
    const library_path = try std.fmt.bufPrintSentinel(&library_buf, "{s}/library.tsv", .{dir}, 0);

    os.fake_us = 1_000_000_000;
    defer os.fake_us = null;

    // Nothing reaches the real Kindle: its tools are answered by a pretend one, and
    // the Wi-Fi saver's note goes in this folder
    var fake = try play_on_fake(harness, kindle);
    fake.install();
    defer fake.release();
    wifi_saver.use_data_dir(dir);
    defer wifi_saver.use_data_dir(paths.data_dir);

    const devices = try play_on_devices(harness, steps);

    // Before any font: the decoders allocate through it, in the region the Kindle has,
    // so a picture with no room there has none here
    const decoders_budget = try setup.decoders();
    decoder_memory.use(decoders_budget);
    defer decoder_memory.stop_using(decoders_budget);
    try setup.use_glyph_cache();

    const kept = try play_on_kept(harness, dir);
    const app_budget = try app_memory();
    // What an earlier scenario's app kept, which that scenario reported
    const live_before = app_budget.live;
    var a = try setup.assemble(.{
        .alloc = app_budget.allocator(),
        .app_budget = app_budget,
        .decoders_budget = decoders_budget,
        .screen = devices.screen,
        .input = devices.input,
        .kit = kept.kit,
        .data_dir = dir,
        .files = kept.files,
        .library_path = library_path,
    });
    const outcome = outcome: {
        defer a.release();
        try play_on_start(&a, kindle, dir, &book_paths);
        const ms = try play_on_sealed(&a, kindle, book_paths[0]);
        // Every step was played: the steps ran out and noface was told to stop, or the
        // last one left noface itself
        try expect(devices.script.at == steps.len, "noface left before the script ended");
        break :outcome try play_on_outcome(&a, kindle, &book_paths, .{
            .alloc = harness,
            .fake = &fake,
            .last_screen = devices.last_screen,
            .ms = ms,
        });
    };
    try expect(app_budget.live == live_before, "the app kept memory after it ended");
    return outcome;
}

/// The app's region in the scenarios, reserved by the first and kept for good: the
/// Kindle's size and limit, with no arena over it, so an app that needs more than the
/// Kindle gives it fails here too. Each scenario's app gives all of it back as it ends
/// (`App.release`), for the next.
var app_region: memory.Region = undefined;
var app_budget_kept: memory.Budget = undefined;
var app_reserved = false;

fn app_memory() !*memory.Budget {
    if (!app_reserved) {
        const size = setup.region_bytes.app;
        app_region = try .reserve("app", .heap, size);
        app_budget_kept = .{ .name = "app", .region = &app_region, .limit = size };
        app_reserved = true;
    }
    assert(app_budget_kept.region == &app_region);
    assert(app_budget_kept.limit == setup.region_bytes.app); // As main.zig gives it
    return &app_budget_kept;
}

/// Plays the script with memory sealed, as the Kindle runs: any memory asked of the
/// system from here on fails the scenario.
fn play_on_sealed(a: *app.App, kindle: Kindle, book_path: [:0]const u8) !u64 {
    assert(!memory.sealed);
    assert(a.app_budget.region != null); // The app's memory comes from a region
    const late_before = memory.late_requests;
    memory.seal();
    defer memory.sealed = false;
    const ms = try play_on_run(a, kindle, book_path);
    try expect(memory.late_requests == late_before, "memory was asked of the system after startup");
    return ms;
}

/// A new folder for a scenario under /tmp, named for this process and run.
fn play_on_dir(buffer: []u8) ![:0]const u8 {
    const runs_before = run_counter;
    run_counter += 1;
    const dir = try std.fmt.bufPrintSentinel(
        buffer,
        "/tmp/noface-scenarios-{d}-{d}",
        .{ linux.getpid(), run_counter },
        0,
    );
    _ = linux.mkdir(dir, 0o755);
    assert(run_counter > runs_before); // A name no other run has used
    assert(std.mem.startsWith(u8, dir, "/tmp/noface-scenarios-")); // As clean_up removes
    return dir;
}

/// The pretend Kindle, as the scenario has it start.
fn play_on_fake(alloc: std.mem.Allocator, kindle: Kindle) !FakeKindle {
    const wifi_key = "com.lab126.cmd wirelessEnable";
    var fake = try FakeKindle.init(alloc);
    if (kindle.airplane) try fake.put(wifi_key, "0");
    if (kindle.bluetooth) try fake.put("com.lab126.btfd BTstate", "1");
    if (kindle.radio_slow) fake.busy_after_set = wifi_key;
    if (kindle.real_book) |real| {
        fake.highlights = real.highlights;
        fake.bookmarks = real.bookmarks;
    }
    assert(fake.sets.items.len == 0); // Nothing asked of it yet
    assert(!fake.busy);
    return fake;
}

/// The screen and touches a scenario plays on, and where the screen is kept as the
/// steps left it.
const Devices = struct {
    screen: *hwtcon.Screen,
    script: *input_mod.Script,
    input: *input_mod.Input,
    last_screen: []u8,
};

/// A screen in memory and a script of touches, kept in `alloc`, which outlives the App.
fn play_on_devices(alloc: std.mem.Allocator, steps: []const Step) !Devices {
    const screen = try alloc.create(hwtcon.Screen);
    screen.* = try hwtcon.Screen.fake(alloc, width, height);
    const script = try alloc.create(input_mod.Script);
    script.* = .{ .steps = steps };
    // The screen as the steps left it, before noface is told to stop and tidies up
    const last_screen = try alloc.alloc(u8, width * height);
    @memset(last_screen, 0xff);
    const keep = try alloc.create(Keep);
    keep.* = .{ .screen = screen, .into = last_screen };
    script.at_end = .{ .ctx = keep, .call = Keep.call };
    const input = try alloc.create(input_mod.Input);
    input.* = .{
        .touch = -1,
        .power = -1,
        .width = width,
        .height = height,
        .x_max = width,
        .y_max = height,
        .script = script,
    };
    assert(screen.pixels.len == last_screen.len);
    assert(script.stops_given == 0);
    return .{ .screen = screen, .script = script, .input = input, .last_screen = last_screen };
}

/// What an App points at for as long as it lives: its fonts and data file paths.
const Kept = struct { kit: *setup.Kit, files: *setup.DataFiles };

/// The test fonts and a scenario's data file paths, kept in `alloc`, which outlives
/// the App: the harness's, as main.zig keeps them outside the App's budget too.
fn play_on_kept(alloc: std.mem.Allocator, dir: [:0]const u8) !Kept {
    assert(dir.len > 0);
    const kit = try alloc.create(setup.Kit);
    kit.* = try setup.Kit.init(.{
        .book = go_regular,
        .book_bold = go_bold,
        .ui = go_regular,
        .ui_bold = go_bold,
    });
    const files = try alloc.create(setup.DataFiles);
    files.* = .{};
    try files.init(dir);
    assert(std.mem.startsWith(u8, files.settings, dir)); // In the scenario's folder
    return .{ .kit = kit, .files = files };
}

/// Keeps the screen as the script left it, called when its steps run out.
const Keep = struct {
    screen: *hwtcon.Screen,
    into: []u8,

    fn call(ctx: *anyopaque) void {
        const k: *@This() = @ptrCast(@alignCast(ctx));
        assert(k.into.len <= k.screen.pixels.len);
        assert(k.into.len == width * height); // The whole of the pretend screen
        @memcpy(k.into, k.screen.pixels[0..k.into.len]);
    }
};

/// Fills a scenario's folder: its books, an empty Kindle library, and the dictionary
/// if asked for. `book_paths` gets each book's path, the first the one opened.
fn play_on_folder(
    alloc: std.mem.Allocator,
    kindle: Kindle,
    dir: [:0]const u8,
    book_paths: *[books_max][:0]const u8,
) !void {
    assert(kindle.books.len <= book_paths.len);
    assert(std.mem.startsWith(u8, dir, "/tmp/"));
    for (kindle.books, 0..) |name, i| {
        book_paths[i] = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0);
        if (kindle.real_book == null) try write_file(book_paths[i], book_bytes);
    }
    if (kindle.real_book) |real| book_paths[0] = real.entry.path;
    var library_buf: [128]u8 = undefined;
    const library_path = try std.fmt.bufPrintSentinel(&library_buf, "{s}/library.tsv", .{dir}, 0);
    try write_file(library_path, "\n"); // No Kindle books: only the EPUBs in the folder
    if (kindle.dictionary) {
        var dict_buf: [128]u8 = undefined;
        const dict_path = try std.fmt.bufPrintSentinel(&dict_buf, "{s}/dict-en", .{dir}, 0);
        try write_dictionary(alloc, dict_path);
    }
}

/// Sets the App up as a new reader's, in the scenario's folder.
fn play_on_start(
    a: *app.App,
    kindle: Kindle,
    dir: [:0]const u8,
    book_paths: *const [books_max][:0]const u8,
) !void {
    assert(a.screen.width == width);
    assert(a.screen.height == height);
    a.documents = dir;
    // Each run starts as a new reader: nothing read before, every setting as shipped,
    // and the regions' peaks its own
    a.book_region.end_peak = 0;
    a.pages_budget.peak = 0;
    a.settings = .{};
    a.speed = .{};
    a.journal = .{};
    // Every typeface the settings could pick is the test font: no Kindle fonts needed.
    // A real book is set in the Kindle's own, found by the app as it always does.
    if (kindle.real_book == null) {
        a.typefaces.stand_in = .{ go_regular, go_bold, go_regular, go_bold };
    }
    try a.apply_settings();

    if (kindle.read_before) |i| {
        var before_buf: [320]u8 = undefined;
        const before_path = try a.state_path(&before_buf, book_paths[i]);
        state.save(before_path, .{
            .para = 0,
            .byte = 0,
            .percent = 5,
            .opened = 1_700_000_000,
            .seconds = 600,
        });
    }
}

/// Plays the script in the library or the first book, with the app's own messages
/// hidden. How long it took, by the wall clock.
fn play_on_run(a: *app.App, kindle: Kindle, book_path: [:0]const u8) !u64 {
    assert(book_path.len > 0);
    assert(hidden_stderr == -1); // One scenario at a time
    const kind = if (std.mem.endsWith(u8, book_path, ".epub")) "EPUB" else "KFX";
    var entry = if (kindle.real_book) |real| real.entry else catalog.Entry{
        .path = book_path,
        .title = "Scenario Book",
        .author = "noface tests",
        .percent = 0,
        .last = 0,
        .kind = kind,
    };
    assert(std.mem.eql(u8, entry.path, book_path));
    // The app reports as it goes; a run shows only its results
    const saved_stderr: i32 = @intCast(linux.dup(2));
    hidden_stderr = saved_stderr;
    defer {
        hidden_stderr = -1;
        _ = linux.dup2(saved_stderr, 2);
        _ = linux.close(saved_stderr);
    }
    const quiet = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    if (!os.failed(quiet)) {
        _ = linux.dup2(@intCast(quiet), 2);
        _ = linux.close(@intCast(quiet));
    }
    const t0 = real_ms();
    if (kindle.library) {
        try library_screen.run_library(a);
    } else {
        _ = try reader.read_book(a, &entry);
    }
    return real_ms() - t0;
}

/// What `play_on_outcome` reads besides the App.
const Ran = struct {
    alloc: std.mem.Allocator,
    fake: *const FakeKindle,
    last_screen: []const u8,
    ms: u64,
};

/// What a finished run left: in the App, its folder and the pretend Kindle.
fn play_on_outcome(
    a: *app.App,
    kindle: Kindle,
    book_paths: *const [books_max][:0]const u8,
    ran: Ran,
) !Outcome {
    assert(ran.last_screen.len == width * height);
    // Something was drawn, at least the first screen
    try expect(a.screen.updates > 0, "nothing was drawn");
    var state_buf: [320]u8 = undefined;
    var note_buf: [8]u8 = undefined;
    const state_path = try a.state_path(&state_buf, book_paths[0]);
    var opened: [2]bool = @splat(false);
    var finished: [2]bool = @splat(false);
    for (kindle.books[0..@min(2, kindle.books.len)], 0..) |_, i| {
        var b: [320]u8 = undefined;
        const s = state.load(try a.state_path(&b, book_paths[i]));
        opened[i] = s.opened > 1_700_000_000;
        finished[i] = s.finished;
    }
    var looks_right = true;
    if (kindle.snapshot) |name| {
        looks_right = try matches_reference(ran.alloc, name, ran.last_screen);
    }
    const wifi_key = "com.lab126.cmd wirelessEnable";
    return .{
        .ms = ran.ms,
        .looks_right = looks_right,
        .opened = opened,
        .finished = finished,
        .saved = state.load(state_path),
        .looked_up = a.dictionaries[0] != null or a.dictionaries[1] != null,
        .offers_dictionary = a.settings.offer_dictionary,
        .highlights = count_notes(state_path, "highlight"),
        .bookmarks = count_notes(state_path, "bookmark"),
        .book_peak = a.book_region.end_peak,
        .pages_peak = a.pages_budget.peak,
        .breaks = breaks_digest(state_path),
        .updates = a.screen.updates,
        .airplane_asked_on = ran.fake.was_set(wifi_key ++ " 0"),
        .airplane_at_end = std.mem.eql(u8, ran.fake.get(wifi_key), "0"),
        .wifi_note_left = file.read_small(wifi_saver.note_path(), &note_buf).len > 0,
    };
}

/// A digest of the page breaks saved beside the book's state file, without the key
/// they're saved under: where the pages break, nothing else, read a piece at a time so
/// a book of any length is digested whole. 0 when none were saved.
fn breaks_digest(state_path: []const u8) u64 {
    assert(state_path.len > 0);
    var path_buf: [320]u8 = undefined;
    const path = page_store.path_for(&path_buf, state_path) catch return 0;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (os.failed(rc)) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd); // Ignored: only read
    var h = std.hash.Wyhash.init(0);
    var skip: u32 = page_store.header_len;
    var total: u64 = 0;
    var buf: [4096]u8 = undefined;
    // Each read moves on by at least a byte, or ends the file
    for (0..std.math.maxInt(u32)) |_| {
        const got = linux.read(fd, &buf, buf.len);
        if (os.failed(got) or got == 0) break;
        const piece = buf[0..got];
        const from = @min(skip, piece.len);
        skip -= @intCast(from);
        h.update(piece[from..]);
        total += piece.len;
    }
    if (total <= page_store.header_len) return 0;
    return h.final();
}

fn write_file(path: [*:0]const u8, data: []const u8) !void {
    assert(data.len > 0); // Each file a scenario writes has something in it
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (os.failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.CantWrite;
}

/// Removes a scenario's folder and what's in it (one level: it holds only files).
fn clean_up(dir: [:0]const u8) void {
    // Never anything but a scenario's own folder: this removes it whole
    assert(std.mem.startsWith(u8, dir, "/tmp/noface-scenarios-"));
    assert(std.mem.indexOf(u8, dir, "..") == null);
    var out: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", dir };
    _ = process.run(&argv, &out);
}

fn same_place(a: state.State, b: state.State) bool {
    return a.para == b.para and a.byte == b.byte;
}

const Scenario = struct { name: []const u8, run: *const fn () anyerror!void };

const scenarios = [_]Scenario{
    .{ .name = "three pages on and one back is two pages on", .run = struct {
        fn run() !void {
            const there_and_back = try play(&.{ forward, forward, forward, swipe(-1) });
            const two_on = try play(&.{ forward, forward });
            const start = try play(&.{});
            try expect(same_place(there_and_back.saved, two_on.saved), "the places differ");
            try expect(!same_place(two_on.saved, start.saved), "turning didn't move the place");
        }
    }.run },
    .{
        .name = "the layout breaks pages where page_store.layout_version says it does",
        .run = struct {
            fn run() !void {
                // Long enough for the whole book to be laid out in idle moments, and saved
                const laid_out = try play(&.{wait(3000)});
                if (laid_out.breaks != page_store.breaks_digest) {
                    std.debug.print(
                        "page breaks moved: digest {x}. If the layout changed on purpose, " ++
                            "raise layout_version in page_store.zig and set its " ++
                            "breaks_digest to this, so saved breaks are laid out again.\n",
                        .{laid_out.breaks},
                    );
                }
                try expect(laid_out.breaks != 0, "no page breaks were saved");
                try expect(laid_out.breaks == page_store.breaks_digest, "page breaks moved");
            }
        }.run,
    },
    .{ .name = "going back from the first page stays there", .run = struct {
        fn run() !void {
            const start = try play(&.{});
            const tried = try play(&.{ back, swipe(-1) });
            try expect(same_place(start.saved, tried.saved), "moved before the first page");
        }
    }.run },
    .{ .name = "a swipe turns like a tap", .run = struct {
        fn run() !void {
            const tapped = try play(&.{forward});
            const swiped = try play(&.{swipe(1)});
            try expect(same_place(tapped.saved, swiped.saved), "a swipe went somewhere else");
        }
    }.run },
    .{
        .name = "reading time counts only while the page shows",
        .run = struct {
            fn run() !void {
                // A minute on the page, then a minute with the toolbar open
                const r = try play(&.{ wait(60_000), forward, top, wait(60_000), page_middle });
                try expect(r.saved.seconds >= 55, "reading time too short");
                try expect(r.saved.seconds <= 70, "reading time counted the toolbar");
            }
        }.run,
    },
    .{
        .name = "common actions on a page run and leave the place alone",
        .run = struct {
            fn run() !void {
                const plain = try play(&.{forward});
                const busy = try play(&.{
                    forward,
                    // The dictionary question, then the definition, each closed above it
                    a_word,
                    lift,
                    above_sheet,
                    above_sheet,
                    // The text settings, closed
                    top,
                    tap(696, toolbar_button_y),
                    page_middle,
                    // Contents, closed above it
                    top,
                    tap(816, toolbar_button_y),
                    tap(636, 120),
                    // The menu, closed above the card
                    top,
                    tap(1176, toolbar_button_y),
                    tap(636, 200),
                    wait(130_000), // Past the Wi-Fi pause
                });
                try expect(same_place(plain.saved, busy.saved), "the place moved");
                try expect(busy.updates > plain.updates, "nothing was drawn");
            }
        }.run,
    },
    .{ .name = "locking and waking mid-book keeps the place and the screen", .run = struct {
        fn run() !void {
            const plain = try play(&.{ forward, forward });
            const locked = try play(&.{ forward, lock_it, wait(3_000), wake, forward });
            try expect(same_place(plain.saved, locked.saved), "the place moved");
            try expect(locked.updates > plain.updates, "the lock screen wasn't drawn");
        }
    }.run },
    .{ .name = "leaving noface from the quick panel mid-book keeps the place", .run = struct {
        fn run() !void {
            const plain = try play(&.{ forward, forward });
            const left = try play(&.{ forward, forward, pull_down, panel_kindle });
            try expect(same_place(plain.saved, left.saved), "the place was lost");
        }
    }.run },
    .{
        .name = "a couple of minutes into a book Wi-Fi goes off, and comes back on leaving",
        .run = struct {
            fn run() !void {
                const r = try play(&.{ wait(150_000), forward });
                try expect(r.airplane_asked_on, "airplane mode wasn't turned on");
                try expect(!r.airplane_at_end, "Wi-Fi wasn't put back");
                try expect(!r.wifi_note_left, "the note was left behind");
            }
        }.run,
    },
    .{
        .name = "Wi-Fi comes back even when the Kindle was slow to say it went off",
        .run = struct {
            fn run() !void {
                const r = try play_on(.{ .radio_slow = true }, &.{ wait(150_000), forward });
                try expect(r.airplane_asked_on, "airplane mode wasn't turned on");
                try expect(!r.airplane_at_end, "Wi-Fi was left off");
                // The note may stay, as Wi-Fi coming back went unconfirmed too: the
                // launcher or the next start checks again, so it's kept until Wi-Fi is seen on
            }
        }.run,
    },
    .{
        .name = "after jumping to a chapter, Back returns to the page being read",
        .run = struct {
            fn run() !void {
                const read_on = try play(&.{ forward, forward, forward });
                const contents = tap(816, toolbar_button_y);
                const first_chapter = tap(636, 390);
                const back_button = tap(205, 1626);
                // Back sits in the toolbar's lower part, under the scrubber
                assert(back_button.act.tap.y >= toolbar.scrub_top);
                const jumped = try play(&.{
                    forward, forward, forward, top, contents, first_chapter,
                });
                try expect(
                    !same_place(read_on.saved, jumped.saved),
                    "the chapter didn't move the place",
                );
                const returned = try play(&.{
                    forward, forward, forward, top, contents, first_chapter, back_button,
                });
                try expect(
                    same_place(read_on.saved, returned.saved),
                    "Back didn't return to the page",
                );
                // The toolbar's chapter skip is a jump too
                const chapter_back = tap(110, 1450);
                // In the toolbar's lower part, above the scrubber
                assert(chapter_back.act.tap.y >= toolbar.bottom_top);
                assert(chapter_back.act.tap.y < toolbar.scrub_top);
                const moved = try play(&.{
                    forward, forward, forward, top, chapter_back, page_middle,
                });
                try expect(
                    !same_place(read_on.saved, moved.saved),
                    "the chapter skip didn't move the place",
                );
                const skipped = try play(&.{
                    forward, forward, forward, top, chapter_back, page_middle, back_button,
                });
                try expect(
                    same_place(read_on.saved, skipped.saved),
                    "Back didn't follow a chapter skip",
                );
                // The ⋮ menu's Go to beginning is a jump too, so it can be undone
                const menu = tap(1176, toolbar_button_y);
                const beginning = tap(636, 1265); // Its second row
                const started_over = try play(&.{
                    forward, forward, forward, top, menu, beginning,
                });
                try expect(
                    !same_place(read_on.saved, started_over.saved),
                    "Go to beginning didn't move the place",
                );
                const undone = try play(&.{
                    forward, forward, forward, top, menu, beginning, back_button,
                });
                try expect(
                    same_place(read_on.saved, undone.saved),
                    "Back didn't follow Go to beginning",
                );
            }
        }.run,
    },
    .{
        .name = "after Go to beginning, Back is still there when the book is opened again",
        .run = struct {
            fn run() !void {
                const menu = tap(1176, toolbar_button_y);
                const beginning = tap(636, 1265); // Its second row
                const back_button = tap(205, 1626);
                const home = tap(150, toolbar_button_y);
                const hero = tap_in(library_ui.hero_rect(width));
                const library: Kindle = .{ .library = true, .read_before = 0 };
                const kept_on = try play_on(library, &.{
                    hero, wait(2_000), forward, forward, forward, top, home,
                });
                const reopened = try play_on(library, &.{
                    hero, wait(2_000), forward, forward,     forward,     top, menu, beginning,
                    top,  home,        hero,    wait(2_000), back_button,
                });
                try expect(
                    same_place(kept_on.saved, reopened.saved),
                    "Back didn't last through closing the book",
                );
            }
        }.run,
    },
    .{ .name = "a quick look into a book leaves Wi-Fi alone", .run = struct {
        fn run() !void {
            const r = try play(&.{ wait(60_000), forward });
            try expect(!r.airplane_asked_on, "airplane mode was turned on");
        }
    }.run },
    .{ .name = "airplane mode the reader turned on stays on", .run = struct {
        fn run() !void {
            const r = try play_on(.{ .airplane = true }, &.{ wait(150_000), forward });
            try expect(r.airplane_at_end, "noface turned the reader's airplane mode off");
            try expect(!r.wifi_note_left, "noface claimed the reader's airplane mode");
        }
    }.run },
    .{ .name = "with Bluetooth on, Wi-Fi is left alone", .run = struct {
        fn run() !void {
            const r = try play_on(.{ .bluetooth = true }, &.{ wait(150_000), forward });
            try expect(!r.airplane_asked_on, "airplane mode could cut Bluetooth off");
        }
    }.run },
    .{
        .name = "holding a word looks it up, and its Highlight button highlights it",
        .run = struct {
            fn run() !void {
                const r = try play_on(.{ .dictionary = true }, &.{
                    a_word, lift, highlight_button, page_middle,
                });
                try expect(r.looked_up, "the dictionary wasn't opened");
                try expect(r.highlights == 1, "the word wasn't highlighted");
            }
        }.run,
    },
    .{
        .name = "without a dictionary, holding a word asks once to get it, " ++
            "and Not now stops the asking",
        .run = struct {
            fn run() !void {
                const r = try play(&.{
                    // Asked: Not now, then the sheet closed
                    a_word,
                    lift,
                    card_row(2, 1),
                    above_sheet,
                    // Not asked again: straight to the sheet
                    a_word,
                    lift,
                    highlight_button,
                    page_middle,
                });
                try expect(!r.offers_dictionary, "it would ask again");
                try expect(r.highlights == 1, "the word wasn't highlighted");
            }
        }.run,
    },
    .{
        .name = "a dictionary download that can't start says so, " ++
            "and the word can still be highlighted",
        .run = struct {
            fn run() !void {
                // The pretend Kindle starts no programs, so curl never runs
                const r = try play(&.{
                    a_word,         lift,             card_row(2, 0),
                    card_row(1, 0), highlight_button, page_middle,
                });
                try expect(!r.looked_up, "a dictionary appeared from nowhere");
                try expect(r.highlights == 1, "the word wasn't highlighted");
            }
        }.run,
    },
    .{ .name = "the toolbar's bookmark marks the page, and again unmarks it", .run = struct {
        fn run() !void {
            const bookmark = tap(936, toolbar_button_y);
            const once = try play(&.{ top, bookmark, page_middle });
            try expect(once.bookmarks == 1, "the page wasn't bookmarked");
            const twice = try play(&.{ top, bookmark, bookmark, page_middle });
            try expect(twice.bookmarks == 0, "the bookmark stayed");
        }
    }.run },
    .{ .name = "a book opens from the library, and Home goes back", .run = struct {
        fn run() !void {
            const r = try play_on(.{ .library = true }, &.{
                tap_in(library_ui.book_rect(0, 0)),
                wait(2_000),
                top,
                tap(150, toolbar_button_y),
            });
            try expect(r.opened[0], "the book didn't open");
        }
    }.run },
    .{
        .name = "a tap made while the stats were up closes them and never reaches the library",
        .run = struct {
            fn run() !void {
                const stats_button = tap(758, 558);
                const hero = tap_in(library_ui.hero_rect(width));
                const hit = library_ui.hit(758, 558, 0, 1, false);
                try expect(hit == .stats, "the stats button isn't where it was");
                const kindle: Kindle = .{ .library = true, .read_before = 0 };
                // The second tap touched as the first closed them, before the library
                // was back: meant for the stats, it opens nothing
                const twice = try play_on(kindle, &.{
                    stats_button, page_middle, .{ .act_queued = hero.act }, wait(2_000),
                });
                try expect(!twice.opened[0], "a tap meant for the stats opened the book");
                // Once the library is back, the same tap opens the book
                const after = try play_on(kindle, &.{
                    stats_button, page_middle, hero, wait(2_000),
                });
                try expect(after.opened[0], "the book didn't open from the library");
            }
        }.run,
    },
    .{
        .name = "finishing a book of a series offers the next, and it opens",
        .run = struct {
            fn run() !void {
                const r = try play_on(.{
                    .library = true,
                    .books = &.{
                        "Scenario Book -- noface tests -- Scenario Saga #1.epub",
                        "Scenario Book -- noface tests -- Scenario Saga #2.epub",
                    },
                    .read_before = 0,
                }, &.{
                    tap_in(library_ui.hero_rect(width)), wait(2_000), // Continue the first
                    top, tap(1176, toolbar_button_y), tap(600, 1600), // ⋮, Mark as finished
                    top, tap(150, toolbar_button_y), // Home, where the next one is offered
                    tap(600, 1604), // Up next: Read it now
                    wait(2_000), top, tap(150, toolbar_button_y), // Home
                });
                try expect(r.finished[0], "the first wasn't marked finished");
                try expect(r.opened[1], "the next one didn't open");
            }
        }.run,
    },
    .{
        .name = "a book marked finished then unread starts again, and stays unread",
        .run = struct {
            fn run() !void {
                const read_row = tap(600, 1600); // The ⋮ menu's last row
                const r = try play(&.{
                    forward, forward,                     forward,
                    top,     tap(1176, toolbar_button_y), read_row,
                    top,     tap(1176, toolbar_button_y), read_row,
                });
                try expect(!r.finished[0], "it's still marked finished");
                try expect(r.saved.para == 0, "it didn't start again");
                try expect(r.saved.byte == 0, "it didn't start again");
                try expect((r.saved.percent orelse 0) < 99, "it's saved as read by its percent");
            }
        }.run,
    },
    .{
        .name = "changing the text size again and again takes no more memory",
        .run = struct {
            fn run() !void {
                const sheet = [_]Step{ top, tap(696, toolbar_button_y) };
                // The slider's smallest step, then its largest, each a tap and a lift
                const change = [_]Step{
                    tap(100, aa.size_row.top + 90),  lift,
                    tap(1172, aa.size_row.top + 90), lift,
                };
                const twice = try play(&(sheet ++ change));
                const often = try play(&(sheet ++ change ++ change ++ change ++ change));
                try expect(often.book_peak == twice.book_peak, "the book's memory grew");
                try expect(twice.pages_peak > 0, "the pages weren't laid out again");
                try expect(often.pages_peak <= twice.pages_peak, "the pages' memory grew");
            }
        }.run,
    },
    .{
        .name = "the page, toolbar, text settings, a definition and the library " ++
            "look as they should",
        .run = struct {
            fn run() !void {
                const text_settings = tap(696, toolbar_button_y);
                const shots = .{
                    .{ Snapshot.page, &[_]Step{forward} },
                    .{ Snapshot.toolbar, &[_]Step{ forward, top } },
                    .{
                        Snapshot.@"aa-font",
                        &[_]Step{ forward, top, text_settings, tap(477, 270) },
                    },
                    .{ Snapshot.definition, &[_]Step{ forward, a_word, lift } },
                };
                inline for (shots) |shot| {
                    const r = try play_on(.{ .dictionary = true, .snapshot = shot[0] }, shot[1]);
                    try expect(r.looks_right, @tagName(shot[0]) ++ " looks different");
                }
                const lib = try play_on(.{ .library = true, .snapshot = .library }, &.{});
                try expect(lib.looks_right, "library looks different");
            }
        }.run,
    },
    .{ .name = "the app has the Kindle's memory and no more", .run = struct {
        fn run() !void {
            const alloc = (try app_memory()).allocator();
            const refused = if (alloc.alloc(u8, setup.region_bytes.app + 1)) |got| refused: {
                alloc.free(got);
                break :refused false;
            } else |err| err == error.OutOfMemory;
            try expect(refused, "the app was given more than the Kindle gives it");
        }
    }.run },
};

comptime {
    // Each scenario is reported by its name, so no two may share one
    @setEvalBranchQuota(100_000);
    for (scenarios, 0..) |s, index| {
        assert(s.name.len > 0);
        for (scenarios[index + 1 ..]) |other| assert(!std.mem.eql(u8, s.name, other.name));
    }
}

/// A tap in the middle of `r`.
fn tap_in(r: library_ui.Rect) Step {
    assert(r.w > 0);
    assert(r.h > 0);
    return tap(@intCast(r.x + r.w / 2), @intCast(r.y + r.h / 2));
}

fn expect(ok: bool, why: []const u8) !void {
    assert(why.len > 0); // A failure says what went wrong
    if (!ok) {
        std.debug.print("    {s}\n", .{why});
        return error.ScenarioFailed;
    }
}

/// The real stderr, kept aside while a scenario's app output goes nowhere; -1 when
/// it's in place. A crash puts it back first, so its message is seen.
var hidden_stderr: i32 = -1;

pub fn show_crashes() void {
    if (hidden_stderr >= 0) _ = linux.dup2(hidden_stderr, 2);
}

/// The panic handler for noface-scenarios: the message reaches the terminal even
/// when it happens mid-scenario.
pub const panic = std.debug.FullPanic(struct {
    fn crash(msg: []const u8, first: ?usize) noreturn { // usize: Zig's panic handler signature
        show_crashes();
        std.debug.defaultPanic(msg, first);
    }
}.crash);

/// Real time, for how long a scenario really took: the app's own clock is the fake one.
/// Monotonic: the wall clock can be set back mid-run, as the Kindle does after waking,
/// and a time taken from it then would be less than zero.
fn real_ms() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Runs every scenario, printing a line for each. The number that failed.
fn run_scenarios() u32 {
    comptime assert(scenarios.len > 0);
    var failed: u32 = 0;
    for (scenarios) |s| {
        const t0 = real_ms();
        if (s.run()) {
            std.debug.print("ok    {s} ({d} ms)\n", .{ s.name, real_ms() - t0 });
        } else |err| {
            failed += 1;
            std.debug.print("FAIL  {s}: {s}\n", .{ s.name, @errorName(err) });
        }
    }
    assert(failed <= scenarios.len);
    const passed = scenarios.len - failed;
    std.debug.print("{d} of {d} scenarios passed\n", .{ passed, scenarios.len });
    return failed;
}

pub fn main(init: std.process.Init.Minimal) !void {
    write_snapshots = init.environ.getPosix("NOFACE_WRITE_SNAPSHOTS");
    if (run_scenarios() > 0) std.process.exit(1);
}

/// `noface selftest`, on the reader's Kindle: the scenarios, then this Kindle's own
/// fonts, dictionaries and a few of its books, opened in memory with nothing saved
/// where the reader's things are. True when everything passed.
pub fn selftest() bool {
    var ok = run_scenarios() == 0;
    std.debug.print("\nthis Kindle\n", .{});
    ok = selftest_files() and ok;
    ok = selftest_books() and ok;
    const result = if (ok) "everything passed" else "something failed (see FAIL above)";
    std.debug.print("\nselftest: {s}\n", .{result});
    return ok;
}

/// This Kindle's own fonts, the dictionaries if installed, and the picture helper.
fn selftest_files() bool {
    var ok = true;
    for (settings_model.builtin_families, 0..) |name, i| {
        const path = fonts_db.path(i, false, false);
        const usable = if (file.map(path)) |data| usable: {
            defer file.unmap(data);
            break :usable Font.usable(data);
        } else |_| false;
        std.debug.print("{s}  font {s}\n", .{ if (usable) "ok  " else "FAIL", name });
        ok = ok and usable;
    }
    const dictionaries = [_][]const u8{ "dict-en", "dict-pt" };
    comptime assert(dictionaries.len == @typeInfo(hyphen.Lang)
        .@"enum".field_names.len);
    for (dictionaries) |name| {
        var buf: [96]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(
            &buf,
            paths.data_dir ++ "/{s}",
            .{name},
            0,
        ) catch continue;
        const data = file.map(path) catch {
            std.debug.print("--    {s} not installed\n", .{name});
            continue;
        };
        defer file.unmap(data); // Tens of MB each, in an address space the scenarios crowd
        const readable = dictionary.Dictionary.open(data) != null;
        std.debug.print("{s}  {s}\n", .{ if (readable) "ok  " else "FAIL", name });
        ok = ok and readable;
    }
    const helper = file.exists(paths.jxr_helper);
    std.debug.print("{s}  picture helper (jxr2pgm)\n", .{if (helper) "ok  " else "FAIL"});
    return ok and helper;
}

/// The most of the reader's books the self-test opens of each kind, and looks at.
const selftest_books_opened_max = 3;
const selftest_books_tried_max = 12;
/// The most a book's highlights or bookmarks take, as the database answers: the
/// reader's own buffer for them is this size.
const selftest_notes_bytes_max = 1024 * 1024;

comptime {
    assert(selftest_books_opened_max <= selftest_books_tried_max);
}

/// A few of the reader's books, each opened to its first page with its own highlights
/// and bookmarks: they come from outside noface, and must never stop a book opening.
fn selftest_books() bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A list that can't be read opens no book: said, and failed, so a run that opened
    // none never reports everything passed
    var ok = true;
    if (selftest_epubs(alloc)) |epubs| {
        ok = selftest_open("epub", epubs) and ok;
    } else |err| {
        std.debug.print("FAIL  listing epub books: {s}\n", .{@errorName(err)});
        ok = false;
    }
    if (selftest_kindle_books(alloc)) |kindle_books| {
        ok = selftest_open("kfx", kindle_books) and ok;
    } else |err| {
        std.debug.print("FAIL  listing kfx books: {s}\n", .{@errorName(err)});
        ok = false;
    }
    return ok;
}

/// The first EPUBs in the documents folder. Their notes are in noface's own files,
/// beside places a run never reads, so they open without any.
fn selftest_epubs(alloc: std.mem.Allocator) ![]const RealBook {
    const found = try folders.find_files(alloc, paths.documents, ".epub");
    const books = try alloc.alloc(RealBook, @min(found.len, selftest_books_tried_max));
    for (books, found[0..books.len]) |*book, path| {
        assert(std.fs.path.isAbsolute(path));
        const name = std.fs.path.stem(path);
        book.* = .{ .entry = .{
            .path = path,
            .title = name,
            .author = "",
            .percent = 0,
            .last = 0,
            .kind = "EPUB",
        } };
    }
    return books;
}

/// The Kindle books read last, from the book list, with their notes as the database
/// has them: those with highlights first.
fn selftest_kindle_books(alloc: std.mem.Allocator) ![]const RealBook {
    const list_path = paths.data_dir ++ "/" ++ paths.data.library;
    const mapped = file.map(list_path) catch |err| switch (err) {
        error.NotFound, error.EmptyFile => return &.{}, // Not exported yet, or no books
        error.OpenFailed, error.SeekFailed, error.MmapFailed => return err,
    };
    const list = try alloc.dupe(u8, mapped); // The entries keep slices of it
    file.unmap(mapped);
    const entries = try kindle_catalog.parse(alloc, list);
    std.sort.block(catalog.Entry, entries, {}, read_later);
    var books: std.ArrayList(RealBook) = .empty;
    const stored = try alloc.alloc(u8, selftest_notes_bytes_max);
    for (entries) |entry| {
        if (books.items.len == selftest_books_tried_max) break;
        if (!entry.is_local() or entry.is_epub()) continue;
        if (!file.exists(entry.path)) continue; // Gone since the list was written
        const highlights = annotation_db.read_lines(entry.key, .highlight, stored);
        const highlights_kept = try alloc.dupe(u8, highlights);
        const bookmarks = annotation_db.read_lines(entry.key, .bookmark, stored);
        try books.append(alloc, .{
            .entry = entry,
            .highlights = highlights_kept,
            .bookmarks = try alloc.dupe(u8, bookmarks),
        });
    }
    std.sort.block(RealBook, books.items, {}, more_highlighted);
    assert(books.items.len <= selftest_books_tried_max);
    return books.items;
}

fn read_later(_: void, a: catalog.Entry, b: catalog.Entry) bool {
    return a.last > b.last;
}

fn more_highlighted(_: void, a: RealBook, b: RealBook) bool {
    return a.highlights.len > 0 and b.highlights.len == 0;
}

/// Opens up to `selftest_books_opened_max` of `books`. Protected ones (most bought from
/// Amazon) open in the Kindle's own reader instead, so they're passed over, not failed.
fn selftest_open(kind: []const u8, books: []const RealBook) bool {
    assert(books.len <= selftest_books_tried_max);
    if (books.len == 0) {
        // Said, so a run with nothing of this kind to open is told from one that passed
        std.debug.print("--    no {s} books to open\n", .{kind});
        return true;
    }
    var ok = true;
    var opened: u32 = 0;
    // Named by kind and number, not title: this report is pasted into public issues
    for (books, 1..) |book, number| {
        assert(opened <= selftest_books_opened_max);
        if (opened == selftest_books_opened_max) break;
        if (play_on(.{ .real_book = book }, &.{})) |r| {
            const highlights = std.mem.count(u8, book.highlights, "\n");
            const line = "ok    opened {s} book {d} ({d} ms, {d} highlights)\n";
            std.debug.print(line, .{ kind, number, r.ms, highlights });
            opened += 1;
        } else |err| switch (err) {
            error.Encrypted, error.Compressed, error.NotKfx => {
                const why = @errorName(err);
                const line = "--    {s} book {d}: not one noface opens ({s})\n";
                std.debug.print(line, .{ kind, number, why });
            },
            else => {
                const line = "FAIL  opened {s} book {d}: {s}\n";
                std.debug.print(line, .{ kind, number, @errorName(err) });
                ok = false;
            },
        }
    }
    return ok;
}
