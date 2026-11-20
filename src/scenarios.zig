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
const book_model = @import("model/book.zig");
const goto_ui = @import("ui/goto.zig");
const selection = @import("ui/selection.zig");
const run_mode = @import("screens/reader/run.zig");
const running_model = @import("model/running.zig");
const places = @import("screens/places.zig");
const run_view = @import("screens/reader/run_view.zig");
const back_button_ui = @import("screens/reader/back_button.zig");
const more = @import("screens/reader/more.zig");
const definition_ui = @import("ui/definition.zig");
const keyboard = @import("ui/keyboard.zig");
const search_sheet = @import("ui/search_sheet.zig");

const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
const book_bytes = @embedFile("testdata/scenario.epub");

const Step = input_mod.Step;
const width = 1272;
const height = 1696;

/// Where the page scrubber is touched, on its bar: along it, a value.
const scrubber_y = toolbar.place(.scrub).y;

/// Row `i` of a card of `rows`.
fn card_row(rows: u32, i: u32) Step {
    assert(rows > 0);
    assert(i < rows);
    return tap_on(card.place(rows, i));
}
/// A control, tapped in the middle of its taps (screens/places.zig).
fn tap_on(p: style.Point) Step {
    return tap(p.x, p.y);
}
/// A tool of the toolbar's top row.
fn tool(h: toolbar.Hit) Step {
    return tap_on(toolbar.place(h));
}
const highlight_button = tap_on(definition_ui.place(.highlight)); // On the definition sheet
const above_sheet = tap_on(card.place_above());

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

/// Taps on the keyboard typing `word`, its letters' keys.
fn typed(comptime word: []const u8) [word.len]Step {
    var steps: [word.len]Step = undefined;
    for (word, &steps) |char, *step| step.* = tap_on(keyboard.place(.{ .char = char }));
    return steps;
}
const wake: Step = .{ .act = .unlock };
/// The quick panel pulled down from the top, and its Kindle button, which leaves noface.
const pull_down: Step = .{ .act = .pull };
const panel_kindle = tap_on(menu_ui.place(.kindle));
/// Series… on a book's card, held in the library: its third row, after Remove and Mark
/// as read. Then the series lists' second row, "Not in a series", and "Library" along
/// their top.
const book_series = card_row(3, 2);
const not_in_a_series = tap_on(goto_ui.place(.{ .row = 1 }));
const list_back_to_library = tap_on(goto_ui.place(.close));
const forward = tap_on(places.page.forward);
const back = tap_on(places.page.back);
const top = tap_on(places.page.top);
const page_middle = tap_on(places.page.middle);
/// A tap on the page clear of `a_word` and the handles of its highlight, which lets the
/// highlight go: it's the page's text that says where, not a control.
const away_from_word = tap(636, 1000);
/// The middle column while running, which pauses and carries on.
const running_middle = tap_on(places.running_mode.middle);
/// A hold on a word of the first page.
const a_word = hold(600, 700);
/// Running mode on, from the page: the toolbar, its Aa sheet, the Themes tab, and the
/// Running button under its tiles. Then, while running, a tap in the pause band and the
/// pause card's rows.
const text_settings_button = tool(.text);
const themes_tab = tap_on(aa.place(.themes, .{ .tab = .themes }));
const running_button = tap_on(aa.place(.themes, .running));
const start_running = [_]Step{ top, text_settings_button, themes_tab, running_button };
const pause_tap = tap_on(places.running_mode.top);
/// The pause button, at the left of running's footer (screens/reader/run.zig).
const pause_button = tap_on(run_view.pause_place(height));
const pause_resume = card_row(3, 0);
const pause_stop = card_row(3, 2);

comptime {
    // The pretend screen is the one the interface is laid out for
    assert(width == style.screen_width);
    assert(height == style.screen_height);
    // A tap on the left third of a page goes back, the rest forward
    assert(back.act.tap.x < width / 3);
    assert(forward.act.tap.x >= width / 3);
    // `top` opens the toolbar; the middle of the page is outside it, and closes it
    assert(top.act.tap.y < toolbar.top_height);
    // The scrubber takes touches along its whole bar
    assert(toolbar.hit(400, scrubber_y, null) == .scrub);
    assert(toolbar.hit(1100, scrubber_y, null) == .scrub);
    assert(page_middle.act.tap.y > toolbar.top_height);
    assert(page_middle.act.tap.y < toolbar.bottom_top);
    // Clear of the held word's line, and the handles under it
    assert(away_from_word.act.tap.y > a_word.act.hold.y + 2 * style.fingertip);
    // A word is held in the page's text, clear of the toolbar's two parts
    assert(a_word.act.hold.y > toolbar.top_height);
    assert(a_word.act.hold.y < toolbar.bottom_top);
    // A tap above a card of up to two rows closes it
    assert(above_sheet.act.tap.y < card.top(2));
    // The panel's Kindle button is where the scenarios tap it
    assert(menu_ui.hit(panel_kindle.act.tap.x, panel_kindle.act.tap.y) == .kindle);
    // The series lists' rows and their way back are where the scenarios tap them
    const none = not_in_a_series.act.tap;
    assert(goto_ui.hit(none.x, none.y, 0, 2).row == 1);
    const back_to_library = list_back_to_library.act.tap;
    assert(goto_ui.hit(back_to_library.x, back_to_library.y, 0, 2) == .close);
    // Aa's Themes tab, and the Running button on it
    const text = text_settings_button.act.tap;
    assert(toolbar.hit(text.x, text.y, null) == .text);
    const tab = themes_tab.act.tap;
    assert(std.meta.eql(aa.hit(.themes, .{}, tab.x, tab.y), aa.Hit{ .tab = .themes }));
    const run = running_button.act.tap;
    assert(aa.hit(.themes, .{}, run.x, run.y) == .running);
    // While running, taps in the top band pause, as `forward` and `back` turn
    assert(pause_tap.act.tap.y < run_mode.pause_band_px);
    assert(forward.act.tap.y >= run_mode.pause_band_px);
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
    notes: u64, // A digest of the book's notes file, 0 when it has none
    unreadable_kept: bool, // Every file made unreadable is still there, unread and unwritten
    shown: [3]?Shown, // As `Kindle.pages_into` asks: the pages buffered at the end
    running_pace: ?f64, // Running's pace, once it has one
    awake_at_end: bool, // The Kindle held awake as the steps ran out, before noface stopped
    speed_pages: u32, // Pages the reader's speed in the hand has counted
    settings: settings_model.Settings, // In use at the end
    saved_settings: settings_model.Settings, // As the settings file has them
};

/// A page drawn, and its words where they were drawn.
const Shown = struct { page: u32, words: []const book_model.Word };

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
    /// A book read a while already, so the library shows it to continue, and opens
    /// at its place.
    read_before: ?ReadBefore = null,
    /// What the pages' region lets a layout after a settings change take: less than
    /// the Kindle's makes that layout run out of room.
    pages_bytes: u64 = setup.region_bytes.pages,
    /// Room left in the app's budget once it's assembled, when it's to run out (the
    /// Kindle's whole budget when null).
    app_bytes_spare: ?u64 = null,
    /// Files of the data folder that are there but can't be read, as on a drive that
    /// fails a read: each a link to itself, which noface must never write over.
    unreadable: []const []const u8 = &.{},
    /// Where the pages in the app's page buffers at the end are copied, for a scenario
    /// that looks at the words drawn: the run's own memory is gone once it returns.
    pages_into: ?std.mem.Allocator = null,
    /// One of the reader's own books, opened where it is (never written to), with the
    /// Kindle's own fonts and its own highlights: the self-test's real books.
    real_book: ?RealBook = null,
    /// Wi-Fi's on/off goes unanswered right after it's set.
    radio_slow: bool = false,
    /// The reader has bold word starts on, which lay words out at other widths.
    bold_starts: bool = false,
    /// Compares the screen at the end with the reference image of this name.
    snapshot: ?Snapshot = null,
};

/// Which book was read before, and its place, as its state file keeps it.
const ReadBefore = struct { book: u32 = 0, para: u32 = 0, byte: u32 = 0 };

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
const Snapshot = enum {
    page,
    toolbar,
    @"aa-font",
    definition,
    library,
    lock,
    search,
    @"library-search",
    running,
};

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
    var path_buf: [file.own_path_bytes_max]u8 = undefined;
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
    if (kindle.read_before) |before| assert(before.book < kindle.books.len);
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

    const devices = try play_on_devices(harness, steps, &fake);

    // Before any font: the decoders allocate through it, in the region the Kindle has,
    // so a picture with no room there has none here
    const decoders_budget = try setup.decoders();
    decoder_memory.use(decoders_budget);
    defer decoder_memory.stop_using(decoders_budget);
    try setup.use_glyph_cache();

    return play_on_app(kindle, steps, .{
        .harness = harness,
        .dir = dir,
        .library_path = library_path,
        .book_paths = &book_paths,
        .fake = &fake,
        .devices = devices,
        .decoders_budget = decoders_budget,
    });
}

/// What `play_on` made for a scenario's app, which outlives it.
const Stage = struct {
    harness: std.mem.Allocator,
    dir: [:0]const u8,
    library_path: [*:0]const u8,
    book_paths: *const [books_max][:0]const u8,
    fake: *const FakeKindle,
    devices: Devices,
    decoders_budget: *memory.Budget,
};

/// Assembles the scenario's app on the Kindle's budget, plays the steps in it, and
/// lets it go: what it left, once it has given all of its memory back.
fn play_on_app(kindle: Kindle, steps: []const Step, stage: Stage) !Outcome {
    assert(kindle.pages_bytes <= setup.region_bytes.pages); // Within the pages' region
    const kept = try play_on_kept(stage.harness, stage.dir);
    const app_budget = try app_memory();
    // What an earlier scenario's app kept, which that scenario reported
    const live_before = app_budget.live;
    defer app_budget.limit = setup.region_bytes.app; // Whatever the scenario left
    var a = try setup.assemble(.{
        .alloc = app_budget.allocator(),
        .app_budget = app_budget,
        .decoders_budget = stage.decoders_budget,
        .screen = stage.devices.screen,
        .input = stage.devices.input,
        .kit = kept.kit,
        .data_dir = stage.dir,
        .files = kept.files,
        .library_path = stage.library_path,
    });
    const outcome = outcome: {
        defer a.release();
        if (kindle.app_bytes_spare) |spare| app_budget.limit = app_budget.live + spare;
        try play_on_start(&a, kindle, stage.dir, stage.book_paths);
        const ms = try play_on_sealed(&a, kindle, stage.book_paths[0]);
        // Every step was played: the steps ran out and noface was told to stop, or the
        // last one left noface itself
        const played = stage.devices.script.at == steps.len;
        try expect(played, "noface left before the script ended");
        break :outcome try play_on_outcome(&a, kindle, stage.book_paths, .{
            .alloc = stage.harness,
            .fake = stage.fake,
            .last_screen = stage.devices.last_screen,
            .awake_at_end = stage.devices.keep.awake,
            .ms = ms,
            .dir = stage.dir,
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
    keep: *const Keep,
};

/// A screen in memory and a script of touches, kept in `alloc`, which outlives the App.
fn play_on_devices(
    alloc: std.mem.Allocator,
    steps: []const Step,
    fake: *const FakeKindle,
) !Devices {
    const screen = try alloc.create(hwtcon.Screen);
    screen.* = try hwtcon.Screen.fake(alloc, width, height);
    const script = try alloc.create(input_mod.Script);
    script.* = .{ .steps = steps };
    // The screen as the steps left it, before noface is told to stop and tidies up
    const last_screen = try alloc.alloc(u8, width * height);
    @memset(last_screen, 0xff);
    const keep = try alloc.create(Keep);
    keep.* = .{ .screen = screen, .into = last_screen, .fake = fake };
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
    return .{
        .screen = screen,
        .script = script,
        .input = input,
        .last_screen = last_screen,
        .keep = keep,
    };
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
    fake: *const FakeKindle,
    /// Whether the Kindle was held awake as the steps ran out, before noface was told
    /// to stop, which lets it sleep whatever was before
    awake: bool = false,

    fn call(ctx: *anyopaque) void {
        const k: *@This() = @ptrCast(@alignCast(ctx));
        assert(k.into.len <= k.screen.pixels.len);
        assert(k.into.len == width * height); // The whole of the pretend screen
        @memcpy(k.into, k.screen.pixels[0..k.into.len]);
        const held = k.fake.get("com.lab126.powerd preventScreenSaver");
        k.awake = std.mem.eql(u8, held, "1");
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
    for (kindle.unreadable) |name| {
        const link = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0);
        if (os.failed(linux.symlink(link, link))) return error.CantWrite;
    }
}

/// Whether every file the scenario made unreadable is still the link it was: open
/// fails on it, where noface renaming its own file over it would make it readable.
fn unreadable_kept(alloc: std.mem.Allocator, kindle: Kindle, dir: []const u8) !bool {
    assert(dir.len > 0);
    for (kindle.unreadable) |name| {
        const link = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0);
        const data = file.map(link) catch |err| switch (err) {
            error.OpenFailed => continue, // The link, still
            error.NotFound, error.SeekFailed, error.EmptyFile, error.MmapFailed => return false,
        };
        file.unmap(data);
        return false;
    }
    return true;
}

/// Sets the App up as a new reader's, in the scenario's folder.
fn play_on_start(
    a: *app.App,
    kindle: Kindle,
    dir: [:0]const u8,
    book_paths: *const [books_max][:0]const u8,
) !void {
    assert(a.display.screen.width == width);
    assert(a.display.screen.height == height);
    a.documents = dir;
    // Each run starts as a new reader: nothing read before, every setting as shipped,
    // and the regions' peaks its own
    a.regions.book.end_peak = 0;
    a.regions.pages_budget.peak = 0;
    a.regions.pages_budget.limit = kindle.pages_bytes;
    a.user.settings = .{ .bold_starts = kindle.bold_starts };
    a.user.running_pace = null;
    a.user.speed = .{};
    a.user.journal = .{};
    // Every typeface the settings could pick is the test font: no Kindle fonts needed.
    // A real book is set in the Kindle's own, found by the app as it always does.
    if (kindle.real_book == null) {
        a.typefaces.stand_in = .{ go_regular, go_bold, go_regular, go_bold };
    }
    try a.apply_settings();

    if (kindle.read_before) |before| {
        var before_buf: [file.own_path_bytes_max]u8 = undefined;
        const before_path = try a.state_path(&before_buf, book_paths[before.book]);
        state.save(before_path, .{
            .para = before.para,
            .byte = before.byte,
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
    awake_at_end: bool, // As `Keep` found it when the steps ran out
    ms: u64,
    dir: []const u8, // The scenario's folder
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
    try expect(a.display.screen.updates > 0, "nothing was drawn");
    var state_buf: [file.own_path_bytes_max]u8 = undefined;
    var note_buf: [8]u8 = undefined;
    const state_path = try a.state_path(&state_buf, book_paths[0]);
    var opened: [2]bool = @splat(false);
    var finished: [2]bool = @splat(false);
    for (kindle.books[0..@min(2, kindle.books.len)], 0..) |_, i| {
        var b: [file.own_path_bytes_max]u8 = undefined;
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
        .looked_up = a.languages.looked_up(),
        .offers_dictionary = a.user.settings.offer_dictionary,
        .highlights = count_notes(state_path, "highlight"),
        .bookmarks = count_notes(state_path, "bookmark"),
        .book_peak = a.regions.book.end_peak,
        .pages_peak = a.regions.pages_budget.peak,
        .breaks = breaks_digest(state_path),
        .notes = notes_digest(state_path),
        .unreadable_kept = try unreadable_kept(ran.alloc, kindle, ran.dir),
        .shown = if (kindle.pages_into) |into| try pages_shown(into, a) else @splat(null),
        .updates = a.display.screen.updates,
        .running_pace = a.user.running_pace,
        .awake_at_end = ran.awake_at_end,
        .speed_pages = a.user.speed.pages,
        .settings = a.user.settings,
        .saved_settings = a.user.saved_settings(),
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
    var path_buf: [file.own_path_bytes_max]u8 = undefined;
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

/// A digest of the book's notes file, 0 when it has none: whether two runs left the
/// same highlights, bookmarks and notes, in the same places.
fn notes_digest(state_path: []const u8) u64 {
    assert(state_path.len > 0);
    var path_buf: [file.own_path_bytes_max]u8 = undefined;
    const path = state.sibling(&path_buf, state_path, "notes") catch return 0;
    var buf: [8192]u8 = undefined;
    const content = file.read_small(path, &buf);
    if (content.len == 0) return 0;
    return std.hash.Wyhash.hash(0, content);
}

/// The pages the app's page buffers hold, with their words copied into `alloc`: they
/// stay as last drawn after the book closes.
fn pages_shown(alloc: std.mem.Allocator, a: *const app.App) ![3]?Shown {
    var shown: [3]?Shown = @splat(null);
    comptime assert(shown.len == a.display.slots.len);
    for (a.display.slots, &shown) |slot, *out| {
        const page = slot.page orelse continue;
        assert(slot.hits.word_count <= slot.hits.words.len);
        const words = slot.hits.words[0..slot.hits.word_count];
        out.* = .{ .page = page, .words = try alloc.dupe(book_model.Word, words) };
    }
    return shown;
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
                // Bold word starts lay words out at their own widths, and break there
                const bold = try play_on(.{ .bold_starts = true }, &.{wait(3000)});
                if (bold.breaks != page_store.breaks_digest_bold_starts) {
                    std.debug.print("bold-starts page breaks moved: digest {x}\n", .{bold.breaks});
                }
                const bold_same = bold.breaks == page_store.breaks_digest_bold_starts;
                try expect(bold_same, "page breaks with bold word starts moved");
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
                    tool(.text),
                    page_middle,
                    // Contents, closed above it
                    top,
                    tool(.goto),
                    tap_on(goto_ui.place(.close)),
                    // The menu, closed above the card
                    top,
                    tool(.more),
                    tap_on(card.place_above()),
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
                const contents = tool(.goto);
                const first_chapter = tap_on(goto_ui.place(.{ .row = 0 }));
                const back_button = tap_on(back_button_ui.place(height));
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
                const chapter_back = tool(.chapter_prev);
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
                const menu = tool(.more);
                const beginning = tap_on(more.place(.beginning));
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
                const menu = tool(.more);
                const beginning = tap_on(more.place(.beginning));
                const back_button = tap_on(back_button_ui.place(height));
                const home = tool(.home);
                const hero = tap_in(library_ui.hero_rect(width));
                const library: Kindle = .{ .library = true, .read_before = .{} };
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
                    a_word, lift, highlight_button, away_from_word,
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
                    away_from_word,
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
                    card_row(1, 0), highlight_button, away_from_word,
                });
                try expect(!r.looked_up, "a dictionary appeared from nowhere");
                try expect(r.highlights == 1, "the word wasn't highlighted");
            }
        }.run,
    },
    .{
        .name = "a book search jumps to its first result, and a tap on the sheet just " ++
            "over its field keeps the sheet open",
        .run = struct {
            fn run() !void {
                const search = tool(.search);
                const enter = tap_on(keyboard.place(.enter));
                const first_result = tap_on(goto_ui.place(.{ .row = 0 }));
                // The reader's sheet starts at its status row, above the bar's own layout
                const over_field = tap(width / 4, (toolbar.status_row + search_sheet.top) / 2);
                assert(over_field.act.tap.y >= toolbar.status_row);
                assert(over_field.act.tap.y < search_sheet.top);
                const garden = typed("garden");
                const read_on = try play(&.{ forward, forward, forward, forward, forward });
                const searched = try play(&(.{ forward, forward, forward, forward, forward } ++
                    .{ top, search } ++ garden ++ .{ enter, first_result }));
                try expect(
                    !same_place(read_on.saved, searched.saved),
                    "the search's result didn't move the place",
                );
                const over = try play(&(.{ forward, forward, forward, forward, forward } ++
                    .{ top, search, over_field } ++ garden ++ .{ enter, first_result }));
                try expect(
                    same_place(searched.saved, over.saved),
                    "a tap just over the field closed the search",
                );
            }
        }.run,
    },
    .{ .name = "the toolbar's bookmark marks the page, and again unmarks it", .run = struct {
        fn run() !void {
            const bookmark = tool(.bookmark);
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
                tool(.home),
            });
            try expect(r.opened[0], "the book didn't open");
        }
    }.run },
    .{
        .name = "a tap made while the stats were up closes them and never reaches the library",
        .run = struct {
            fn run() !void {
                const stats_button = tap_on(library_ui.place(.stats));
                const hero = tap_in(library_ui.hero_rect(width));
                const hit = library_ui.hit(758, 558, 0, 1, false);
                try expect(hit == .stats, "the stats button isn't where it was");
                const kindle: Kindle = .{ .library = true, .read_before = .{} };
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
                    .read_before = .{},
                }, &.{
                    tap_in(library_ui.hero_rect(width)), wait(2_000), // Continue the first
                    top, tool(.more), tap_on(more.place(.finished)), // ⋮, Mark as finished
                    top, tool(.home), // Home, where the next one is offered
                    card_row(1, 0), // Up next: Read it now
                    wait(2_000), top, tool(.home), // Home
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
                const read_row = tap_on(more.place(.finished)); // Finished, or unread once it is
                const r = try play(&.{
                    forward, forward,     forward,
                    top,     tool(.more), read_row,
                    top,     tool(.more), read_row,
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
                const sheet = [_]Step{ top, tool(.text) };
                // The slider's smallest step, then its largest, each a tap and a lift
                const change = [_]Step{
                    tap(100, aa.row_middle(aa.size_row)),  lift,
                    tap(1172, aa.row_middle(aa.size_row)), lift,
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
        .name = "the page, toolbar, text settings, a definition, a book's search, the " ++
            "lock screen, running, the library and its search look as they should",
        .run = struct {
            fn run() !void {
                const text_settings = tool(.text);
                const font_tab = tap_on(aa.place(.themes, .{ .tab = .font }));
                const shots = .{
                    .{ Snapshot.page, &[_]Step{forward} },
                    .{ Snapshot.toolbar, &[_]Step{ forward, top } },
                    .{
                        Snapshot.@"aa-font",
                        &[_]Step{ forward, top, text_settings, font_tab },
                    },
                    .{ Snapshot.definition, &[_]Step{ forward, a_word, lift } },
                    // A book without a cover: its title on white
                    .{ Snapshot.lock, &[_]Step{ forward, lock_it, wait(3_000) } },
                    // A phrase partway, the dial swept part of the way round
                    .{ Snapshot.running, &(start_running ++ [_]Step{wait(2_500)}) },
                    .{ Snapshot.search, &(.{ top, tool(.search) } ++ typed("garden") ++ .{
                        tap_on(keyboard.place(.enter)),
                    }) },
                };
                inline for (shots) |shot| {
                    const r = try play_on(.{ .dictionary = true, .snapshot = shot[0] }, shot[1]);
                    try expect(r.looks_right, @tagName(shot[0]) ++ " looks different");
                }
                const lib = try play_on(.{ .library = true, .snapshot = .library }, &.{});
                try expect(lib.looks_right, "library looks different");
                const search_books = tap_on(library_ui.place(.search));
                const found: Kindle = .{ .library = true, .snapshot = .@"library-search" };
                const lib_search = try play_on(found, &.{search_books});
                try expect(lib_search.looks_right, "the library's search looks different");
            }
        }.run,
    },
    .{
        .name = "the page before a place mid-page ends where that place's page starts",
        .run = struct {
            fn run() !void {
                // A place a page doesn't start at by itself: the page before it is cut
                // short there, and must be drawn so, or its last lines show twice
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                const r = try play_on(.{
                    .read_before = .{ .para = 6, .byte = 120 },
                    .pages_into = arena.allocator(),
                }, &.{back});
                try expect(adjacent_pages(r.shown), "the two pages weren't both drawn");
                try expect(!word_shown_twice(r.shown), "a word showed on two pages");
            }
        }.run,
    },
    .{
        .name = "a layout after a text change that runs out of room keeps the place " ++
            "and how far in the book is",
        .run = struct {
            fn run() !void {
                const hero = tap_in(library_ui.hero_rect(width));
                const home = tool(.home);
                const bigger = [_]Step{
                    top, tool(.text), tap(1172, aa.row_middle(aa.size_row)), lift,
                };
                const before: ReadBefore = .{ .para = 6, .byte = 120 };
                const kept_on = try play_on(.{ .library = true, .read_before = before }, &.{
                    hero, wait(2_000), top, home,
                });
                // No room for even the first of the new pages: the book closes, failed
                const failed = try play_on(.{
                    .library = true,
                    .read_before = before,
                    .pages_bytes = 1,
                }, &([_]Step{ hero, wait(2_000) } ++ bigger));
                try expect(same_place(kept_on.saved, failed.saved), "the place was lost");
                const percent_kept = failed.saved.percent == kept_on.saved.percent;
                try expect(percent_kept, "how far in it is changed");
            }
        }.run,
    },
    .{ .name = "a scrub cut short by the lock leaves the place where it was", .run = struct {
        fn run() !void {
            const along: Step = .{ .act = .{ .drag = .{ .x = 1100, .y = scrubber_y } } };
            const plain = try play(&.{forward});
            const lifted = try play(&.{ forward, top, tap(400, scrubber_y), along, lift });
            try expect(!same_place(plain.saved, lifted.saved), "the scrubber didn't jump");
            const locked = try play(&.{
                forward, top, tap(400, scrubber_y), along, lock_it, wait(3_000), wake,
            });
            try expect(same_place(plain.saved, locked.saved), "the lock jumped the book");
        }
    }.run },
    .{
        .name = "a text size drag cut short by the lock leaves the size as it was",
        .run = struct {
            fn run() !void {
                // The Aa sheet opens on its Font tab, with the text size's slider
                const slider_y = aa.row_middle(aa.size_row);
                const along: Step = .{ .act = .{ .drag = .{ .x = 1172, .y = slider_y } } };
                const begin = [_]Step{ top, text_settings_button, tap(400, slider_y), along };
                const lifted = try play(&(begin ++ [_]Step{lift}));
                const own: settings_model.Settings = .{};
                try expect(lifted.settings.size != own.size, "the slider didn't change the size");
                const locked = try play(&(begin ++ [_]Step{ lock_it, wait(3_000), wake }));
                try expect(locked.settings.size == own.size, "the lock changed the size");
                try expect(locked.saved_settings.size == own.size, "the lock saved a size");
            }
        }.run,
    },
    .{
        .name = "a reading journal that's there but can't be read is never written over",
        .run = struct {
            fn run() !void {
                const unreadable: Kindle = .{ .unreadable = &.{paths.data.journal} };
                const r = try play_on(unreadable, &.{ wait(60_000), forward });
                try expect(r.unreadable_kept, "the journal was written over");
                try expect(r.saved.seconds > 0, "the reading wasn't saved");
            }
        }.run,
    },
    .{
        .name = "a series that can't be saved leaves its file as it was, and noface running",
        .run = struct {
            fn run() !void {
                const r = try play_on(.{ .library = true, .unreadable = &.{"series"} }, &.{
                    hold_in(library_ui.hero_rect(width)),
                    lift,
                    book_series,
                    not_in_a_series,
                    // Still on the list, which a tap along its top leaves
                    list_back_to_library,
                });
                try expect(r.unreadable_kept, "the series file was written over");
            }
        }.run,
    },
    .{
        .name = "an error in a screen over the library fails its run, and the next starts clean",
        .run = struct {
            fn run() !void {
                const series = [_]Step{
                    hold_in(library_ui.hero_rect(width)), lift, book_series,
                };
                // No room left in the app's budget: the series lists can't be made
                const broken = play_on(.{ .library = true, .app_bytes_spare = 0 }, &series);
                const failed = if (broken) |_| false else |err| err == error.OutOfMemory;
                try expect(failed, "the series lists opened with no memory for them");
                // The book's, the library's and the action's regions were let go of
                const left = series ++ .{list_back_to_library};
                const after = try play_on(.{ .library = true }, &left);
                try expect(after.updates > 0, "the next run drew nothing");
            }
        }.run,
    },
    .{
        .name = "a highlight's handle still drags once the book is laid out behind it",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                const held_at = a_word.act.hold;
                const highlighted = [_]Step{ a_word, lift, highlight_button, away_from_word };
                // Read before, so it opens with its first pages and lays out the rest on
                // ticks, as a book opened again after a layout change does
                const read: Kindle = .{ .dictionary = true, .read_before = .{} };
                var looked = read;
                looked.pages_into = arena.allocator();
                // Where the word held and the one after it were drawn on the first page
                const first = try play_on(looked, &highlighted);
                const words = shown_words(first.shown, 0);
                const held = word_at(words, held_at.x, held_at.y) orelse
                    return expect(false, "no word where the word was held");
                const next = word_after(words, held) orelse
                    return expect(false, "nothing after the word on its line");
                const handle = selection.end_handle(&.{held});
                // The highlight tapped to select it, then the whole book laid out on ticks
                const selected = highlighted ++ [_]Step{ tap(held_at.x, held_at.y), wait(3_000) };
                const kept = try play_on(read, &(selected ++ .{away_from_word}));
                const dragged = try play_on(read, &(selected ++ .{
                    tap(handle.x, handle.y),
                    drag_to(next),
                    lift,
                    away_from_word,
                }));
                try expect(kept.highlights == 1, "the word wasn't highlighted");
                try expect(dragged.highlights == 1, "the drag made another highlight");
                try expect(dragged.notes != kept.notes, "the handle's drag didn't move the end");
            }
        }.run,
    },
    .{
        .name = "running moves on through the book by itself, and stopping leaves the " ++
            "reader's settings as they were, at the place it reached",
        .run = struct {
            fn run() !void {
                const start = try play(&.{});
                // A few minutes on the treadmill, then stopped from the pause card
                const steps = start_running ++ [_]Step{ wait(240_000), pause_tap, pause_stop };
                const ran = try play(&steps);
                try expect(!same_place(start.saved, ran.saved), "the place didn't move on");
                try expect(!ran.awake_at_end, "the Kindle was still held awake after Stop");
                const own: settings_model.Settings = .{};
                const back_as_were = std.meta.eql(ran.settings, own);
                try expect(back_as_were, "the reader's settings came back changed");
                const saved_as_were = std.meta.eql(ran.saved_settings, own);
                try expect(saved_as_were, "the reader's settings were saved changed");
                // Pages gone past at the running pace say nothing of the speed in the hand
                try expect(ran.speed_pages == 0, "running taught the reader's speed");
                try expect(ran.running_pace != null, "running had no pace");
                // Leaving the book while running ends it too
                const left = try play(&(start_running ++ [_]Step{wait(60_000)}));
                const left_own = std.meta.eql(left.saved_settings, own);
                try expect(left_own, "leaving running changed the reader's settings");
            }
        }.run,
    },
    .{
        .name = "while running, a tap goes on at once and quickens the pace, going back " ++
            "slows it, and a second touch right after the first is let go",
        .run = struct {
            fn run() !void {
                const first = running_model.first_pace(.{});
                const turned = start_running ++ [_]Step{ wait(2_000), forward };
                const on = try play(&turned);
                try expect(on.running_pace.? > first, "going on early didn't quicken the pace");
                const went_back = try play(&(turned ++ [_]Step{ wait(1_000), back }));
                const slowed = went_back.running_pace.? < on.running_pace.?;
                try expect(slowed, "going back didn't slow it");
                // Two taps a second apart, and two a moment apart, of which one counts
                const two = try play(&(turned ++ [_]Step{ wait(1_000), forward }));
                const bumped = try play(&(turned ++ [_]Step{forward}));
                try expect(same_place(bumped.saved, on.saved), "a bump right after a tap acted");
                const second = !same_place(two.saved, on.saved);
                try expect(second, "a second tap a second later didn't go on");
            }
        }.run,
    },
    .{
        .name = "while running, holding a word neither looks it up nor highlights it",
        .run = struct {
            fn run() !void {
                const steps = start_running ++ [_]Step{ wait(2_000), a_word, lift };
                const held = try play_on(.{ .dictionary = true }, &steps);
                try expect(!held.looked_up, "a hold looked a word up");
                try expect(held.highlights == 0, "a hold highlighted");
            }
        }.run,
    },
    .{
        .name = "the card, the pause button and the middle column stop the phrase's " ++
            "timer, and each carries on",
        .run = struct {
            fn run() !void {
                // Paused long enough to have gone through many phrases: the place stays
                const paused = [_]Step{ wait(1_000), pause_tap, wait(300_000) };
                const held = try play(&(start_running ++ paused));
                const still = try play(&(start_running ++ [_]Step{wait(1_000)}));
                try expect(same_place(held.saved, still.saved), "the place moved on while paused");
                const resumed = try play(&(start_running ++ [_]Step{
                    wait(1_000), pause_tap, pause_resume, wait(240_000),
                }));
                try expect(!same_place(resumed.saved, still.saved), "Resume didn't carry on");
                // The pause button stops the phrase where it is, and again carries on
                const tapped = [_]Step{ wait(2_000), pause_button };
                const just_paused = try play(&(start_running ++ tapped));
                const stopped = tapped ++ [_]Step{wait(300_000)};
                const button_held = try play(&(start_running ++ stopped));
                const held_there = same_place(button_held.saved, just_paused.saved);
                try expect(held_there, "the place moved on when paused");
                const going = [_]Step{ wait(1_000), pause_button, wait(240_000) };
                const button_resumed = try play(&(start_running ++ stopped ++ going));
                const went_on = !same_place(button_resumed.saved, button_held.saved);
                try expect(went_on, "the pause button didn't carry on");
                // The middle column, the screen's height, pauses as the button does
                const middle = [_]Step{ wait(2_000), running_middle, wait(300_000) };
                const middle_held = try play(&(start_running ++ middle));
                const tapped_middle = [_]Step{ wait(2_000), running_middle };
                const middle_tapped = try play(&(start_running ++ tapped_middle));
                const middle_there = same_place(middle_held.saved, middle_tapped.saved);
                try expect(middle_there, "the place moved on when paused from the middle");
            }
        }.run,
    },
    .{
        .name = "running holds the Kindle awake only while it goes on: not paused, nor at " ++
            "the book's end, where it stays after a lock",
        .run = struct {
            fn run() !void {
                const going = try play_on(.{ .read_before = .{ .para = 120 } }, &(start_running ++
                    [_]Step{wait(2_000)}));
                try expect(going.awake_at_end, "the Kindle wasn't held awake while running");
                const paused = try play(&(start_running ++ [_]Step{ wait(2_000), running_middle }));
                try expect(!paused.awake_at_end, "the Kindle was held awake while paused");
                // Near the book's end: run past its last phrase, then lock and wake
                const near_end: Kindle = .{ .read_before = .{ .para = 120 } };
                const to_end = start_running ++ [_]Step{wait(600_000)};
                const ended = try play_on(near_end, &to_end);
                try expect(!ended.awake_at_end, "the Kindle was held awake at the book's end");
                const relocked = try play_on(near_end, &(to_end ++
                    [_]Step{ lock_it, wake, wait(60_000) }));
                try expect(same_place(relocked.saved, ended.saved), "the end moved after a lock");
            }
        }.run,
    },
    .{
        .name = "the card's Resume carries on after the pause button stopped, and a tap " ++
            "back with nothing before leaves the pace",
        .run = struct {
            fn run() !void {
                const stopped = start_running ++ [_]Step{ wait(2_000), pause_button };
                const held = try play(&stopped);
                const resumed = try play(&(stopped ++ [_]Step{
                    wait(1_000), pause_tap, pause_resume, wait(120_000),
                }));
                try expect(!same_place(resumed.saved, held.saved), "Resume didn't carry on");
                try expect(resumed.awake_at_end, "Resume left the Kindle free to sleep");
                // The first phrase since running began has none before it to go back to
                const first = running_model.first_pace(.{});
                const backed = try play(&(start_running ++ [_]Step{ wait(500), back }));
                try expect(backed.running_pace.? == first, "a back tap with nothing before slowed");
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

/// Whether two of the pages shown are next to each other in the book.
fn adjacent_pages(shown: [3]?Shown) bool {
    for (shown, 0..) |first, index| {
        const one = first orelse continue;
        for (shown[index + 1 ..]) |second| {
            const other = second orelse continue;
            assert(one.page != other.page); // A page is in one buffer at most
            if (one.page + 1 == other.page or other.page + 1 == one.page) return true;
        }
    }
    return false;
}

/// The words drawn on page `page`, none when it isn't among those shown.
fn shown_words(shown: [3]?Shown, page: u32) []const book_model.Word {
    for (shown) |slot| {
        const one = slot orelse continue;
        if (one.page == page) return one.words;
    }
    return &.{};
}

/// A finger moved, still down, to the middle of `word`.
fn drag_to(word: book_model.Word) Step {
    assert(word.w > 0);
    assert(word.h > 0);
    const x = word.x + @divTrunc(word.w, 2);
    const y = word.y + @divTrunc(word.h, 2);
    return .{ .act = .{ .drag = .{ .x = x, .y = y } } };
}

/// The word drawn at a point, if any.
fn word_at(words: []const book_model.Word, x: i32, y: i32) ?book_model.Word {
    for (words) |word| {
        if (x < word.x or x >= word.x + word.w) continue;
        if (y < word.y or y >= word.y + word.h) continue;
        return word;
    }
    return null;
}

/// The word drawn next after `word` on its line, if any.
fn word_after(words: []const book_model.Word, word: book_model.Word) ?book_model.Word {
    var after: ?book_model.Word = null;
    for (words) |other| {
        if (other.y != word.y or other.x <= word.x) continue;
        if (after == null or other.x < after.?.x) after = other;
    }
    if (after) |found| assert(found.x > word.x); // Right of it, on its line
    return after;
}

/// Whether any word was drawn on two of the pages shown.
fn word_shown_twice(shown: [3]?Shown) bool {
    for (shown, 0..) |first, index| {
        const one = first orelse continue;
        for (shown[index + 1 ..]) |second| {
            const other = second orelse continue;
            assert(one.page != other.page); // A page is in one buffer at most
            for (one.words) |word| {
                for (other.words) |again| {
                    if (word.para == again.para and word.start == again.start) return true;
                }
            }
        }
    }
    return false;
}

/// A tap in the middle of `r`.
fn tap_in(r: library_ui.Rect) Step {
    assert(r.w > 0);
    assert(r.h > 0);
    return tap(@intCast(r.x + r.w / 2), @intCast(r.y + r.h / 2));
}

/// A hold in the middle of `r`.
fn hold_in(r: library_ui.Rect) Step {
    assert(r.w > 0);
    assert(r.h > 0);
    return hold(@intCast(r.x + r.w / 2), @intCast(r.y + r.h / 2));
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
        const path = (fonts_db.Offered{}).path(@intCast(i), false, false);
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
