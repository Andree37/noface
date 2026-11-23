//! What runs a scenario: a pretend Kindle in a folder of its own, the real app on a
//! screen in memory, the steps played on a clock it moves itself, and what came of
//! them, read back for the checks.
const std = @import("std");
const layout = @import("layout");
const assert = std.debug.assert;
const file = @import("../sys/file.zig");
const fonts_db = @import("../kindle/fonts.zig");
const process = @import("../sys/process.zig");
const image = @import("../gfx/image.zig");
const app = @import("../app.zig");
const hwtcon = @import("../kindle/hwtcon.zig");
const touch_zones = @import("../kindle/touch.zig");
const input_mod = @import("../kindle/input.zig");
const decoder_memory = @import("../gfx/decoder_memory.zig");
const memory = @import("../base/memory.zig");
const catalog = @import("../model/catalog.zig");
const settings_model = @import("../model/settings.zig");
const stats = @import("../model/stats.zig");
const state = @import("../sys/state.zig");
const page_store = @import("../screens/reader/page_store.zig");
const os = @import("../sys/os.zig");
const reader = @import("../screens/reader.zig");
const library_screen = @import("../screens/library.zig");
const style = @import("../ui/style.zig");
const toolbar = @import("../ui/toolbar.zig");
const dictionary = @import("../model/dictionary.zig");
const FakeKindle = @import("../testing/fake_kindle.zig").FakeKindle;
const wifi_saver = @import("../kindle/wifi_saver.zig");
const paths = @import("../kindle/paths.zig");
const setup = @import("../setup.zig");
const linux = @import("../sys/calls.zig");
const book_model = @import("../model/book.zig");
const placed = @import("../screens/placed.zig");
const test_books = @import("../testdata/books.zig");
const go_regular = @embedFile("../testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("../testdata/fonts/Go-Bold.ttf");
const taps = @import("taps.zig");
const Step = taps.Step;
const away_from_word = taps.away_from_word;
const height = taps.height;
const hold = taps.hold;
const tap = taps.tap;
const width = taps.width;

/// The test books, by what a scenario reads: three chapters of plain text, or one with a
/// footnote and a picture.
pub const TestBook = enum {
    scenario,
    notes,

    fn bytes(b: TestBook) []const u8 {
        return switch (b) {
            .scenario => test_books.scenario,
            .notes => test_books.notes,
        };
    }
};

/// What a run left behind, for the checks.
pub const Outcome = struct {
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
    // The screen at the end, hashed: two runs that end on different screens differ here
    screen_hash: u64,
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
    /// Where the app last placed what moves with the page, by `placed.What`: a note's
    /// mark, a picture, a highlight's Delete bubble.
    placed: [placed_kinds]?style.Point,
    /// Every "service property value" noface set on the Kindle, in order, as
    /// `Kindle.sets_into` asks; none otherwise.
    sets: []const []const u8,
    settings: settings_model.Settings, // In use at the end
    saved_settings: settings_model.Settings, // As the settings file has them
};

/// The app's messages in a scenario's folder, as noface's own log on the Kindle.
pub const app_log = "noface.log";
pub const placed_kinds = std.enums.values(placed.What).len;

/// A page drawn, and its words where they were drawn.
pub const Shown = struct { page: u32, words: []const book_model.Word };

/// The most books a scenario puts in the documents folder.
pub const books_max = 6;

/// How the pretend Kindle starts, and where a scenario begins.
pub const Kindle = struct {
    airplane: bool = false,
    bluetooth: bool = false,
    dictionary: bool = false,
    /// The books in the documents folder, all the scenario book under these names. A
    /// scenario that starts in a book opens the first.
    books: []const []const u8 = &.{"book.epub"},
    /// What each of them is.
    book: TestBook = .scenario,
    /// Keeps every "service property value" noface set on the Kindle, in this memory,
    /// for the outcome's `sets`.
    sets_into: ?std.mem.Allocator = null,
    /// Starts in the library instead of the first book.
    library: bool = false,
    /// Typefaces of the reader's own offered after the Kindle's, as from its fonts
    /// folder: each the test font under its own name ("Own 1", "Own 2", ...).
    own_typefaces: u32 = 0,
    /// A book read a while already, so the library shows it to continue, and opens
    /// at its place.
    read_before: ?ReadBefore = null,
    /// The first book's notes file before the run, as a sync or an older noface could
    /// have left it: "<highlight|bookmark> <id> <start> <end>" lines. Empty for none.
    notes_before: []const u8 = "",
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
    /// The reader's text size (settings.zig `sizes`): the largest makes the most pages
    /// of the test book, on a screen of any size.
    text_size: u32 = (settings_model.Settings{}).size,
    /// Compares the screen at the end with the reference image of this name.
    snapshot: ?Snapshot = null,
    /// The reader's speed, as learned before the run: a new reader's by default.
    speed: stats.Speed = .{},
    /// "Show time left" (Aa, More), on as shipped.
    time_left: bool = true,
};

/// Which book was read before, and its place, as its state file keeps it.
pub const ReadBefore = struct {
    book: u32 = 0,
    para: u32 = 0,
    byte: u32 = 0,
    /// Words from the place to the end, as noface saves them with the place.
    words_left: ?u64 = null,
};

/// One of the reader's own books, as the self-test opens it.
pub const RealBook = struct {
    /// Its row in the book list, whose key finds its notes; an EPUB's made from its path
    entry: catalog.Entry,
    /// The annotation database's answers for it (annotation_db.read_lines), read before
    /// the run: during it the pretend Kindle answers every program noface starts.
    highlights: []const u8 = "",
    bookmarks: []const u8 = "",
};

/// Built as noface-scenarios (GitHub's tests) rather than inside noface: only then are
/// the reference images carried, so they don't weigh on the app.
const with_snapshots = @import("root") == @import("../scenarios.zig");

/// The Kindle this build is laid out for (`layout`). Its screens and page breaks are
/// recorded to compare with in src/testdata/recorded/<model>/, as every Kindle's are:
/// one added to device.Model is recorded as it's added (docs/DEVELOPING.md).
pub const layout_model = layout.model;
const recorded_dir = "../testdata/recorded/" ++ layout.model ++ "/";

/// Where the test book's pages break, as recorded for this Kindle: as shipped, and with
/// bold word starts on, which set words in other widths.
pub const Breaks = struct { plain: u64, bold_starts: u64 };
pub const recorded_breaks: Breaks = breaks: {
    @setEvalBranchQuota(10_000);
    var lines = std.mem.tokenizeScalar(u8, @embedFile(recorded_dir ++ "breaks.txt"), '\n');
    const plain = std.fmt.parseInt(u64, lines.next().?, 16) catch
        @compileError(recorded_dir ++ "breaks.txt: its first line isn't a hex digest");
    const bold_starts = std.fmt.parseInt(u64, lines.next().?, 16) catch
        @compileError(recorded_dir ++ "breaks.txt: its second line isn't a hex digest");
    break :breaks .{ .plain = plain, .bold_starts = bold_starts };
};

/// Set (from NOFACE_WRITE_SNAPSHOTS) to write each snapshot's screen to this folder as
/// <name>.pgm, to make new reference images, instead of comparing.
pub var write_snapshots: ?[]const u8 = null;

pub fn reference_image(comptime name: []const u8) []const u8 {
    if (!with_snapshots) return "";
    return @embedFile(recorded_dir ++ name ++ ".png");
}

/// The screens compared with a reference image, each
/// src/testdata/recorded/<model>/<name>.png.
pub const Snapshot = enum {
    page,
    toolbar,
    @"aa-font",
    definition,
    library,
    lock,
    search,
    @"library-search",
    running,
    series,
    note,
    picture,
    highlight,
};

/// Whether `pixels` match the reference image `name`, allowing for anti-aliasing:
/// pixels more than a few grays apart may be at most 1 in 5,000 (about 430), fewer
/// than a short line of text has, so one added or lost is seen.
pub fn matches_reference(alloc: std.mem.Allocator, which: Snapshot, pixels: []const u8) !bool {
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
pub fn matches_reference_write(
    alloc: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    pixels: []const u8,
) !void {
    assert(name.len > 0);
    assert(pixels.len == width * height);
    var dir_buf: [256]u8 = undefined;
    // Ignored: the writes after it say if the folder is missing
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
pub const book_words = [_][]const u8{
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
pub fn write_dictionary(alloc: std.mem.Allocator, path: [*:0]const u8) !void {
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
pub fn count_notes(state_path: []const u8, kind: []const u8) u32 {
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

pub var run_counter: u32 = 0;

pub fn play(steps: []const Step) !Outcome {
    return play_on(.{}, steps);
}

/// Opens the scenario book in a fresh app on a pretend Kindle, plays `steps`, and
/// returns what was saved and what the Kindle was asked to do. The app's memory is
/// reserved and sealed as on the Kindle, so one asked of the system as it runs fails
/// the scenario; the harness's own (the pretend Kindle, the folder) is apart from it.
pub fn play_on(kindle: Kindle, steps: []const Step) !Outcome {
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
pub const Stage = struct {
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
pub fn play_on_app(kindle: Kindle, steps: []const Step, stage: Stage) !Outcome {
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
        .offered = try own_offered(stage.harness, stage.dir, kindle.own_typefaces),
    });
    const outcome = outcome: {
        defer a.release();
        if (kindle.app_bytes_spare) |spare| app_budget.limit = app_budget.live + spare;
        try play_on_start(&a, kindle, stage.dir, stage.book_paths);
        const ms = try play_on_sealed(&a, kindle, stage.book_paths[0], stage.dir);
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
pub var app_region: memory.Region = undefined;
pub var app_budget_kept: memory.Budget = undefined;
pub var app_reserved = false;

pub fn app_memory() !*memory.Budget {
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
pub fn play_on_sealed(a: *app.App, kindle: Kindle, book_path: [:0]const u8, dir: []const u8) !u64 {
    assert(!memory.sealed);
    assert(a.app_budget.region != null); // The app's memory comes from a region
    const late_before = memory.late_requests;
    memory.seal();
    defer memory.sealed = false;
    const ms = try play_on_run(a, kindle, book_path, dir);
    try expect(memory.late_requests == late_before, "memory was asked of the system after startup");
    return ms;
}

/// A new folder for a scenario under /tmp, named for this process and run.
pub fn play_on_dir(buffer: []u8) ![:0]const u8 {
    const runs_before = run_counter;
    run_counter += 1;
    const dir = try std.fmt.bufPrintSentinel(
        buffer,
        "/tmp/noface-scenarios-{d}-{d}",
        .{ linux.getpid(), run_counter },
        0,
    );
    // A new folder for each run: one that couldn't be made would run on what's left
    const made = linux.mkdir(dir, 0o755);
    if (os.failed(made)) return error.CantMakeFolder;
    assert(run_counter > runs_before); // A name no other run has used
    assert(std.mem.startsWith(u8, dir, "/tmp/noface-scenarios-")); // As clean_up removes
    return dir;
}

/// The pretend Kindle, as the scenario has it start.
pub fn play_on_fake(alloc: std.mem.Allocator, kindle: Kindle) !FakeKindle {
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
pub const Devices = struct {
    screen: *hwtcon.Screen,
    script: *input_mod.Script,
    input: *input_mod.Input,
    last_screen: []u8,
    keep: *const Keep,
};

/// A screen in memory and a script of touches, kept in `alloc`, which outlives the App.
pub fn play_on_devices(
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

/// The most typefaces of the reader's own a scenario offers.
pub const own_typefaces_max = 16;

/// The Kindle's typefaces, then `count` of the reader's own, each the test font written
/// into the scenario's folder `dir`, under its own name. Kept in `alloc`, which outlives
/// the App, as main.zig keeps the ones it finds.
pub fn own_offered(alloc: std.mem.Allocator, dir: []const u8, count: u32) !fonts_db.Offered {
    assert(count <= own_typefaces_max);
    if (count == 0) return .{};
    const regular = try std.fmt.allocPrintSentinel(alloc, "{s}/own-regular.ttf", .{dir}, 0);
    const bold = try std.fmt.allocPrintSentinel(alloc, "{s}/own-bold.ttf", .{dir}, 0);
    file.write_small(regular, go_regular);
    file.write_small(bold, go_bold);
    const names = try alloc.alloc([]const u8, settings_model.builtin_families.len + count);
    @memcpy(names[0..settings_model.builtin_families.len], &settings_model.builtin_families);
    const own = try alloc.alloc([4][:0]const u8, count);
    for (names[settings_model.builtin_families.len..], own, 1..) |*name, *files, n| {
        name.* = try std.fmt.allocPrint(alloc, "Own {d}", .{n});
        files.* = .{ regular, bold, regular, bold }; // Regular, bold, italic, bold italic
    }
    const offered: fonts_db.Offered = .{ .families = .offer(names), .own = own };
    assert(offered.families.count() == settings_model.builtin_families.len + count);
    return offered;
}

/// What an App points at for as long as it lives: its fonts and data file paths.
pub const Kept = struct { kit: *setup.Kit, files: *setup.DataFiles };

/// The test fonts and a scenario's data file paths, kept in `alloc`, which outlives
/// the App: the harness's, as main.zig keeps them outside the App's budget too.
pub fn play_on_kept(alloc: std.mem.Allocator, dir: [:0]const u8) !Kept {
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
pub const Keep = struct {
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
pub fn play_on_folder(
    alloc: std.mem.Allocator,
    kindle: Kindle,
    dir: [:0]const u8,
    book_paths: *[books_max][:0]const u8,
) !void {
    assert(kindle.books.len <= book_paths.len);
    assert(std.mem.startsWith(u8, dir, "/tmp/"));
    for (kindle.books, 0..) |name, i| {
        book_paths[i] = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0);
        if (kindle.real_book == null) try write_file(book_paths[i], kindle.book.bytes());
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
pub fn unreadable_kept(alloc: std.mem.Allocator, kindle: Kindle, dir: []const u8) !bool {
    assert(dir.len > 0);
    assert(std.fs.path.isAbsolute(dir)); // The scenario's own folder, under /tmp
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
pub fn play_on_start(
    a: *app.App,
    kindle: Kindle,
    dir: [:0]const u8,
    book_paths: *const [books_max][:0]const u8,
) !void {
    assert(a.display.screen.width == width);
    assert(a.display.screen.height == height);
    a.documents = dir;
    a.logs_placed = true; // The scenarios tap what moves with the text where it's logged
    // Each run starts as a new reader: nothing read before, every setting as shipped,
    // and the regions' peaks its own
    a.regions.book.end_peak = 0;
    a.regions.pages_budget.peak = 0;
    a.regions.pages_budget.limit = kindle.pages_bytes;
    assert(kindle.text_size < settings_model.sizes.len);
    a.user.settings = .{
        .bold_starts = kindle.bold_starts,
        .size = kindle.text_size,
        .time_left = kindle.time_left,
    };
    a.user.running_pace = null;
    a.user.speed = kindle.speed;
    a.user.journal = .{};
    // Every typeface the settings could pick is the test font: no Kindle fonts needed.
    // A real book is set in the Kindle's own, found by the app as it always does.
    if (kindle.real_book == null) {
        a.typefaces.stand_in = .{ go_regular, go_bold, go_regular, go_bold };
    }
    try a.apply_settings();

    if (kindle.notes_before.len > 0) {
        var state_buf: [file.own_path_bytes_max]u8 = undefined;
        const state_path = try a.state_path(&state_buf, book_paths[0]);
        var notes_buf: [file.own_path_bytes_max]u8 = undefined;
        const notes_path = try state.sibling(&notes_buf, state_path, "notes");
        try write_file(notes_path, kindle.notes_before);
    }
    if (kindle.read_before) |before| {
        var before_buf: [file.own_path_bytes_max]u8 = undefined;
        const before_path = try a.state_path(&before_buf, book_paths[before.book]);
        state.save(before_path, .{
            .para = before.para,
            .byte = before.byte,
            .percent = 5,
            .opened = 1_700_000_000,
            .seconds = 600,
            .words_left = before.words_left,
        });
    }
}

/// Plays the script in the library or the first book, the app's own messages kept out
/// of the run's in the scenario folder's log, which says where it placed what moves
/// with the page (screens/placed.zig). How long it took, by the wall clock.
pub fn play_on_run(a: *app.App, kindle: Kindle, book_path: [:0]const u8, dir: []const u8) !u64 {
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
        // Ignored: the tests' own output put back: nothing is lost if it fails
        _ = linux.dup2(saved_stderr, 2);
        // Ignored: the tests' own output put back: nothing is lost if it fails
        _ = linux.close(saved_stderr);
    }
    var log_buffer: [file.own_path_bytes_max]u8 = undefined;
    const log_path = try std.fmt.bufPrintSentinel(&log_buffer, "{s}/{s}", .{ dir, app_log }, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const quiet = linux.open(log_path, flags, 0o644);
    if (!os.failed(quiet)) {
        // Ignored: the app's output kept out of the run's: it shows if this fails
        _ = linux.dup2(@intCast(quiet), 2);
        // Ignored: the tests' quiet output: nothing is lost if it fails
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
pub const Ran = struct {
    alloc: std.mem.Allocator,
    fake: *const FakeKindle,
    last_screen: []const u8,
    awake_at_end: bool, // As `Keep` found it when the steps ran out
    ms: u64,
    dir: []const u8, // The scenario's folder
};

/// Where the app last placed what moves with the page, by `placed.What`, as the log it
/// wrote in the scenario's folder `dir` says.
pub fn placed_logged(dir: []const u8) ![placed_kinds]?style.Point {
    assert(dir.len > 0);
    var placed_at: [placed_kinds]?style.Point = @splat(null);
    var log_buffer: [file.own_path_bytes_max]u8 = undefined;
    const log_path = try std.fmt.bufPrintSentinel(&log_buffer, "{s}/{s}", .{ dir, app_log }, 0);
    // An empty log placed nothing; one that can't be read fails the scenario
    const logged: ?[]const u8 = file.map(log_path) catch |err| switch (err) {
        error.EmptyFile => null,
        else => return err,
    };
    const text = logged orelse return placed_at;
    defer file.unmap(text);
    assert(text.len > 0);
    for (std.enums.values(placed.What), &placed_at) |what, *at| {
        at.* = placed.find(text, @tagName(what));
    }
    return placed_at;
}

/// What the pretend Kindle was set to, copied into `into` to outlive it.
pub fn sets_kept(into: std.mem.Allocator, fake: *const FakeKindle) ![]const []const u8 {
    const copied = try into.alloc([]const u8, fake.sets.items.len);
    for (copied, fake.sets.items) |*c, set| c.* = try into.dupe(u8, set);
    assert(copied.len == fake.sets.items.len);
    return copied;
}

/// What a finished run left: in the App, its folder and the pretend Kindle.
pub fn play_on_outcome(
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
        .sets = if (kindle.sets_into) |into| try sets_kept(into, ran.fake) else &.{},
        .placed = try placed_logged(ran.dir),
        .ms = ran.ms,
        .looks_right = looks_right,
        .screen_hash = std.hash.Wyhash.hash(0, ran.last_screen),
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
pub fn breaks_digest(state_path: []const u8) u64 {
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
pub fn notes_digest(state_path: []const u8) u64 {
    assert(state_path.len > 0);
    var path_buf: [file.own_path_bytes_max]u8 = undefined;
    const path = state.sibling(&path_buf, state_path, "notes") catch return 0;
    assert(std.mem.startsWith(u8, path, std.fs.path.dirname(state_path) orelse ""));
    var buf: [8192]u8 = undefined;
    const content = file.read_small(path, &buf);
    if (content.len == 0) return 0;
    return std.hash.Wyhash.hash(0, content);
}

/// The pages the app's page buffers hold, with their words copied into `alloc`: they
/// stay as last drawn after the book closes.
pub fn pages_shown(alloc: std.mem.Allocator, a: *const app.App) ![3]?Shown {
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

pub fn write_file(path: [*:0]const u8, data: []const u8) !void {
    assert(data.len > 0); // Each file a scenario writes has something in it
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (os.failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    assert(fd >= 0);
    // Ignored: only read
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.CantWrite;
}

/// Removes a scenario's folder and what's in it (one level: it holds only files).
pub fn clean_up(dir: [:0]const u8) void {
    // Never anything but a scenario's own folder: this removes it whole
    assert(std.mem.startsWith(u8, dir, "/tmp/noface-scenarios-"));
    assert(std.mem.indexOf(u8, dir, "..") == null);
    var out: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", dir };
    // Ignored: a folder left over is only space in /tmp
    _ = process.run(&argv, &out);
}

pub fn same_place(a: state.State, b: state.State) bool {
    return a.para == b.para and a.byte == b.byte;
}

pub const Scenario = struct { name: []const u8, run: *const fn () anyerror!void };

/// Whether two of the pages shown are next to each other in the book.
pub fn adjacent_pages(shown: [3]?Shown) bool {
    comptime assert(shown.len >= 2); // Two at least, to be next to each other
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
pub fn shown_words(shown: [3]?Shown, page: u32) []const book_model.Word {
    for (shown) |slot| {
        const one = slot orelse continue;
        if (one.page == page) return one.words;
    }
    return &.{};
}

/// A hold on the first word of the page `before` leaves the book on, where the app's
/// log says it drew it (screens/placed.zig): a word wherever the layout puts it.
pub fn word_held(kindle: Kindle, before: []const Step) !Step {
    const shown = try play_on(kindle, before);
    const at = shown.placed[@backingInt(placed.What.word)] orelse return error.WordNotPlaced;
    // Below the top edge's strip, where a touch reaches words, and far enough above
    // `away_from_word` that a tap there misses its line and the handles under it
    try expect(at.y >= touch_zones.top_zone, "the word is in the top edge's strip");
    try expect(at.y < toolbar.bottom_top, "the word is under the toolbar's bottom");
    const clear = away_from_word.act.tap.y > at.y + 2 * style.fingertip;
    try expect(clear, "a tap away from the word would land on it");
    return hold(at.x, at.y);
}

/// The values a powerd level was set to, in order.
pub fn levels_set(
    alloc: std.mem.Allocator,
    sets: []const []const u8,
    level: []const u8,
) ![]const u32 {
    assert(level.len > 0);
    var values: std.ArrayList(u32) = .empty;
    for (sets) |set| {
        var words = std.mem.tokenizeScalar(u8, set, ' ');
        const service = words.next() orelse continue;
        if (!std.mem.eql(u8, service, "com.lab126.powerd")) continue;
        if (!std.mem.eql(u8, words.next() orelse continue, level)) continue;
        try values.append(alloc, try std.fmt.parseInt(u32, words.next().?, 10));
    }
    assert(values.items.len <= sets.len); // One a set at most
    return values.items;
}

/// The word drawn at a point, if any.
pub fn word_at(words: []const book_model.Word, x: i32, y: i32) ?book_model.Word {
    assert(x >= 0); // A point on the screen
    assert(y >= 0);
    for (words) |word| {
        if (x < word.x or x >= word.x + word.w) continue;
        if (y < word.y or y >= word.y + word.h) continue;
        return word;
    }
    return null;
}

/// The word drawn next after `word` on its line, if any.
pub fn word_after(words: []const book_model.Word, word: book_model.Word) ?book_model.Word {
    assert(word.w > 0); // A word drawn, so one can be right of it
    var after: ?book_model.Word = null;
    for (words) |other| {
        if (other.y != word.y or other.x <= word.x) continue;
        if (after == null or other.x < after.?.x) after = other;
    }
    if (after) |found| assert(found.x > word.x); // Right of it, on its line
    return after;
}

/// Whether any word was drawn on two of the pages shown.
pub fn word_shown_twice(shown: [3]?Shown) bool {
    comptime assert(shown.len >= 2); // Two at least, to share a word
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

pub fn expect(ok: bool, why: []const u8) !void {
    assert(why.len > 0); // A failure says what went wrong
    if (!ok) {
        std.debug.print("    {s}\n", .{why});
        return error.ScenarioFailed;
    }
}

/// The real stderr, kept aside while a scenario's app output goes nowhere; -1 when
/// it's in place. A crash puts it back first, so its message is seen.
pub var hidden_stderr: i32 = -1;

pub fn show_crashes() void {
    // Ignored: showing a crash's report is all that's left to do
    if (hidden_stderr >= 0) _ = linux.dup2(hidden_stderr, 2);
}

/// Real time, for how long a scenario really took: the app's own clock is the fake one.
/// Monotonic: the wall clock can be set back mid-run, as the Kindle does after waking,
/// and a time taken from it then would be less than zero.
pub fn real_ms() u64 {
    var ts: linux.timespec = undefined;
    // Ignored: the monotonic clock always answers
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// The most of the reader's books the self-test opens of each kind, and looks at.
pub const selftest_books_opened_max = 3;
pub const selftest_books_tried_max = 12;
/// The most a book's highlights or bookmarks take, as the database answers: the
/// reader's own buffer for them is this size.
pub const selftest_notes_bytes_max = 1024 * 1024;

comptime {
    assert(selftest_books_opened_max <= selftest_books_tried_max);
}
