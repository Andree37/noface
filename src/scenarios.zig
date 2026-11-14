//! noface-scenarios: plays scripted touches through the real app, on a screen in
//! memory and a clock it moves itself, and checks what came of them. Each scenario
//! gets its own folder under /tmp and a generated book, so nothing of the reader's is
//! read or written, and the screen is never touched.
//!
//! Built for Linux: GitHub runs it on every change, and on the Kindle it's the
//! self-test (`noface-scenarios`), done in seconds.
const std = @import("std");
const app = @import("app.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const input_mod = @import("kindle/input.zig");
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const c_memory = @import("gfx/c_memory.zig");
const memory = @import("base/memory.zig");
const catalog = @import("model/catalog.zig");
const settings_model = @import("model/settings.zig");
const state = @import("sys/state.zig");
const os = @import("sys/os.zig");
const reader = @import("screens/reader.zig");
const library_screen = @import("screens/library.zig");
const library_ui = @import("ui/library.zig");
const card = @import("ui/card.zig");

/// Row `i` of a card of `rows`.
fn cardRow(rows: usize, i: usize) Step {
    return tap(636, @intCast(card.rowCentre(rows, i)));
}
const highlight_button = tap(122, 1596); // On the definition sheet
const above_sheet = tap(636, 300);
const dictionary = @import("model/dictionary.zig");
const FakeKindle = @import("fake_kindle.zig").FakeKindle;
const wifi_saver = @import("kindle/wifi_saver.zig");
const paths = @import("kindle/paths.zig");
const linux = @import("sys/calls.zig");

const go_regular = @embedFile("testdata/fonts/Go-Regular.ttf");
const go_bold = @embedFile("testdata/fonts/Go-Bold.ttf");
const book_bytes = @embedFile("testdata/scenario.epub");

const Step = input_mod.Step;
const width = 1272;
const height = 1696;

fn tap(x: i32, y: i32) Step {
    return .{ .act = .{ .tap = .{ .x = x, .y = y, .us = 0 } } };
}
fn hold(x: i32, y: i32) Step {
    return .{ .act = .{ .hold = .{ .x = x, .y = y } } };
}
/// The finger leaving the glass, as it does after a hold.
const lift: Step = .{ .act = .drag_end };
fn swipe(direction: i32) Step {
    return .{ .act = .{ .swipe = direction } };
}
fn wait(ms: u64) Step {
    return .{ .wait_ms = ms };
}
const lock_it: Step = .{ .act = .lock };
const wake: Step = .{ .act = .unlock };
const forward = tap(1000, 900);
const back = tap(150, 900);
const top = tap(636, 60);
const page_middle = tap(636, 1000);

/// What a run left behind, for the checks.
const Outcome = struct {
    saved: state.State,
    updates: u32,
    airplane_asked_on: bool, // noface asked for airplane mode at some point
    airplane_at_end: bool, // The Kindle's airplane mode when it was over
    wifi_note_left: bool, // noface's "I turned Wi-Fi off" note is still there
    looked_up: bool, // The dictionary was opened for a word
    offers_dictionary: bool, // Still asks to download a missing dictionary
    ms: u64, // How long the run took, by the wall clock
    looks_right: bool, // The screen at the end matched its reference image, if one was asked for
    opened: [2]bool, // Whether the first two books were opened
    finished: [2]bool, // Whether they were marked finished
    highlights: usize, // Highlights and bookmarks saved for the book
    bookmarks: usize,
};

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
    read_before: ?usize = null,
    /// One of the reader's own books, opened where it is (never written to), with the
    /// Kindle's own fonts: the self-test's timing of real books.
    real_book: ?[:0]const u8 = null,
    /// Wi-Fi's on/off goes unanswered right after it's set.
    radio_slow: bool = false,
    /// Compares the screen at the end with the reference image of this name.
    snapshot: ?Snapshot = null,
};

/// Built as noface-scenarios (GitHub's tests) rather than inside noface: only then are
/// the reference images carried, so they don't weigh on the app.
const with_snapshots = @import("root") == @This();

/// Set (from NOFACE_WRITE_SNAPSHOTS) to write each snapshot's screen to this folder as
/// <name>.pgm, to make new reference images, instead of comparing.
var write_snapshots: ?[]const u8 = null;

fn referenceImage(comptime name: []const u8) []const u8 {
    return if (with_snapshots) @embedFile("testdata/snapshots/" ++ name ++ ".png") else "";
}

/// The screens compared with a reference image, each src/testdata/snapshots/<name>.png.
const Snapshot = enum { page, toolbar, @"aa-font", definition, library };

/// Whether `pixels` match the reference image `name`, allowing for anti-aliasing:
/// pixels more than a few grays apart may be at most 0.3% of the screen.
fn matchesReference(alloc: std.mem.Allocator, which: Snapshot, pixels: []const u8) !bool {
    const name = @tagName(which);
    if (write_snapshots) |dir| {
        var dir_buf: [256]u8 = undefined;
        _ = linux.mkdir(try std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{dir}, 0), 0o755);
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}.pgm", .{ dir, name }, 0);
        var head_buf: [32]u8 = undefined;
        const head = try std.fmt.bufPrint(&head_buf, "P5\n{d} {d}\n255\n", .{ width, height });
        const out = try alloc.alloc(u8, head.len + pixels.len);
        @memcpy(out[0..head.len], head);
        @memcpy(out[head.len..], pixels);
        try writeFile(path, out);
        return true;
    }
    if (!with_snapshots) return true; // The self-test doesn't carry them
    const encoded = switch (which) {
        inline else => |w| referenceImage(@tagName(w)),
    };
    const image = @import("gfx/image.zig");
    const want = image.decodeGray(alloc, encoded) orelse return error.BadSnapshot;
    if (want.width != width or want.height != height) return false;
    var off: usize = 0;
    for (pixels, want.pixels) |got, w| {
        if (@max(got, w) - @min(got, w) > 48) off += 1;
    }
    if (off * 1000 > pixels.len * 3) {
        std.debug.print("    {d} pixels differ from the {s} reference\n", .{ off, name });
        return false;
    }
    return true;
}

/// Every word in the scenario book, for a small English dictionary of them.
const book_words = [_][]const u8{ "a", "bright", "chapter", "evening", "garden", "green", "house", "letter", "light", "long", "morning", "new", "old", "page", "quiet", "reader", "river", "road", "slow", "small", "the", "turns", "window" };

/// A dictionary file, in the format of model/dictionary.zig, with `book_words`.
fn writeDictionary(alloc: std.mem.Allocator, path: [*:0]const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    for (book_words) |w| { // Already sorted, and already folded
        try offsets.append(alloc, @intCast(body.items.len));
        try body.print(alloc, "{s}\x00{s}\x00noun\n1 the scenario book's word \"{s}\"\n", .{ w, w, w });
    }
    try offsets.append(alloc, @intCast(body.items.len));
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
    try writeFile(path, out.items);
}

/// How many lines of `kind` the book's notes file holds.
fn countNotes(state_path: []const u8, kind: []const u8) usize {
    var path_buf: [320]u8 = undefined;
    const path = state.sibling(&path_buf, state_path, "notes") catch return 0;
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, state.readSmall(path, &buf), '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, kind)) n += 1;
    }
    return n;
}

var run_counter: u32 = 0;

fn play(steps: []const Step) !Outcome {
    return playOn(.{}, steps);
}

/// Opens the scenario book in a fresh app on a pretend Kindle, plays `steps`, and
/// returns what was saved and what the Kindle was asked to do.
fn playOn(kindle: Kindle, steps: []const Step) !Outcome {
    var budget = memory.Budget{ .name = "scenario", .child = std.heap.smp_allocator, .limit = 256 << 20 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    run_counter += 1;
    var dir_buf: [96]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/noface-scenarios-{d}-{d}", .{ linux.getpid(), run_counter }, 0);
    _ = linux.mkdir(dir, 0o755);
    defer cleanUp(dir);
    var book_paths: [4][:0]const u8 = undefined;
    for (kindle.books, 0..) |name, i| {
        book_paths[i] = try std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0);
        if (kindle.real_book == null) try writeFile(book_paths[i], book_bytes);
    }
    if (kindle.real_book) |p| book_paths[0] = p;
    const book_path = book_paths[0];
    var library_buf: [128]u8 = undefined;
    const library_path = try std.fmt.bufPrintSentinel(&library_buf, "{s}/library.tsv", .{dir}, 0);
    try writeFile(library_path, "\n"); // No Kindle books: only the EPUBs in the folder
    if (kindle.dictionary) {
        var dict_buf: [128]u8 = undefined;
        try writeDictionary(alloc, try std.fmt.bufPrintSentinel(&dict_buf, "{s}/dict-en", .{dir}, 0));
    }

    os.fake_us = 1_000_000_000;
    defer os.fake_us = null;

    // Nothing reaches the real Kindle: its tools are answered by a pretend one, and
    // the Wi-Fi saver's note goes in this folder
    var fake = try FakeKindle.init(alloc);
    if (kindle.airplane) try fake.put("com.lab126.cmd wirelessEnable", "0");
    if (kindle.bluetooth) try fake.put("com.lab126.btfd BTstate", "1");
    if (kindle.radio_slow) fake.busy_after_set = "com.lab126.cmd wirelessEnable";
    fake.install();
    defer fake.release();
    wifi_saver.useDataDir(dir);
    defer wifi_saver.useDataDir(paths.data_dir);

    var screen = try hwtcon.Screen.fake(alloc, width, height);
    var script = input_mod.Script{ .steps = steps };
    // The screen as the steps left it, before noface is told to stop and tidies up
    const last_screen = try alloc.alloc(u8, width * height);
    @memset(last_screen, 0xff);
    const Keep = struct {
        screen: *hwtcon.Screen,
        into: []u8,
        fn call(ctx: *anyopaque) void {
            const k: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(k.into, k.screen.pixels[0..k.into.len]);
        }
    };
    var keep = Keep{ .screen = &screen, .into = last_screen };
    script.at_end = .{ .ctx = &keep, .call = Keep.call };
    var input = input_mod.Input{ .touch = -1, .power = -1, .width = width, .height = height, .x_max = width, .y_max = height, .script = &script };

    // Before any font: stb allocates through it. Let go of on return, as it lives here
    var stb_budget = memory.Budget{ .name = "stb", .child = std.heap.smp_allocator, .limit = 128 << 20 };
    c_memory.use(&stb_budget);
    defer c_memory.useDefault();

    var body = try Font.init(alloc, go_regular, 46, 1.35);
    var note_font = try Font.init(alloc, go_regular, 36, 1.3);
    var footer = try Font.init(alloc, go_regular, 28, 1.2);
    var reference = try Font.init(alloc, go_regular, 28, 1.2);
    var title = try Font.init(alloc, go_bold, 34, 1.2);
    var small = try Font.init(alloc, go_regular, 34, 1.2);
    var caption = try Font.init(alloc, go_regular, 26, 1.2);
    var hero = try Font.init(alloc, go_bold, 56, 1.2);
    var cover_type = try Font.init(alloc, go_bold, 36, 1.2);
    var slots: [3]app.Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try alloc.alloc(u8, screen.pixels.len) };

    var path_bufs: [4][160]u8 = undefined;
    const settings_path = try std.fmt.bufPrintSentinel(&path_bufs[0], "{s}/" ++ paths.data.settings, .{dir}, 0);
    const speed_path = try std.fmt.bufPrintSentinel(&path_bufs[1], "{s}/" ++ paths.data.speed, .{dir}, 0);
    const journal_path = try std.fmt.bufPrintSentinel(&path_bufs[2], "{s}/" ++ paths.data.journal, .{dir}, 0);
    const battery_path = try std.fmt.bufPrintSentinel(&path_bufs[3], "{s}/" ++ paths.data.battery, .{dir}, 0);
    var a = app.App{
        .alloc = alloc,
        .screen = &screen,
        .input = &input,
        .body = &body,
        .note_font = &note_font,
        .footer = &footer,
        .ui = Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type },
        .slots = slots,
        .overlay = try alloc.alloc(u8, screen.pixels.len),
        .lock_saved = try alloc.alloc(u8, screen.pixels.len),
        .lock_cover = try alloc.alloc(u8, screen.pixels.len),
        .state_dir = dir,
        .library_path = library_path,
        .settings_path = settings_path,
        .speed_path = speed_path,
        .journal_path = journal_path,
        .battery_path = battery_path,
        .documents = dir,
        .app_budget = &budget,
        .stb_budget = &stb_budget,
        .settings = .{},
        .utc_offset = 0,
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &reference },
    };
    // Every typeface the settings could pick is the test font: no Kindle fonts needed.
    // A real book is set in the Kindle's own, found by the app as it always does.
    if (kindle.real_book == null) for (&a.face_files) |*family| {
        family[0] = go_regular;
        family[1] = go_bold;
        family[2] = go_regular;
        family[3] = go_bold;
    };
    try a.applySettings();

    if (kindle.read_before) |i| {
        var before_buf: [320]u8 = undefined;
        state.save(try a.statePath(&before_buf, book_paths[i]), .{ .para = 0, .byte = 0, .percent = 5, .opened = 1_700_000_000, .seconds = 600 });
    }
    const kind = if (std.mem.endsWith(u8, book_path, ".epub")) "EPUB" else "KFX";
    var entry = catalog.Entry{ .path = book_path, .title = "Scenario Book", .author = "noface tests", .percent = 0, .last = 0, .kind = kind };
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
    const t0 = realMs();
    if (kindle.library) try library_screen.runLibrary(&a) else _ = try reader.readBook(&a, &entry);
    const ms = realMs() - t0;

    var state_buf: [320]u8 = undefined;
    var note_buf: [8]u8 = undefined;
    const state_path = try a.statePath(&state_buf, book_path);
    var opened: [2]bool = @splat(false);
    var finished: [2]bool = @splat(false);
    for (kindle.books[0..@min(2, kindle.books.len)], 0..) |_, i| {
        var b: [320]u8 = undefined;
        const s = state.load(try a.statePath(&b, book_paths[i]));
        opened[i] = s.opened > 1_700_000_000;
        finished[i] = s.finished;
    }
    const looks_right = if (kindle.snapshot) |name| try matchesReference(alloc, name, last_screen) else true;
    return .{
        .ms = ms,
        .looks_right = looks_right,
        .opened = opened,
        .finished = finished,
        .saved = state.load(state_path),
        .looked_up = a.dictionaries[0] != null or a.dictionaries[1] != null,
        .offers_dictionary = a.settings.offer_dictionary,
        .highlights = countNotes(state_path, "highlight"),
        .bookmarks = countNotes(state_path, "bookmark"),
        .updates = screen.updates,
        .airplane_asked_on = fake.wasSet("com.lab126.cmd wirelessEnable 0"),
        .airplane_at_end = std.mem.eql(u8, fake.get("com.lab126.cmd wirelessEnable"), "0"),
        .wifi_note_left = state.readSmall(wifi_saver.notePath(), &note_buf).len > 0,
    };
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (os.failed(rc)) return error.CantWrite;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.write(fd, data.ptr, data.len) != data.len) return error.CantWrite;
}

/// Removes a scenario's folder and what's in it (one level: it holds only files).
fn cleanUp(dir: [*:0]const u8) void {
    var out: [64]u8 = undefined;
    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", dir };
    _ = @import("sys/process.zig").run(&argv, &out);
}

fn samePlace(a: state.State, b: state.State) bool {
    return a.para == b.para and a.byte == b.byte;
}

const Scenario = struct { name: []const u8, run: *const fn () anyerror!void };

const scenarios = [_]Scenario{
    .{ .name = "three pages on and one back is two pages on", .run = struct {
        fn run() !void {
            const there_and_back = try play(&.{ forward, forward, forward, swipe(-1) });
            const two_on = try play(&.{ forward, forward });
            const start = try play(&.{});
            try expect(samePlace(there_and_back.saved, two_on.saved), "the places differ");
            try expect(!samePlace(two_on.saved, start.saved), "turning didn't move the place");
        }
    }.run },
    .{ .name = "going back from the first page stays there", .run = struct {
        fn run() !void {
            const start = try play(&.{});
            const tried = try play(&.{ back, swipe(-1) });
            try expect(samePlace(start.saved, tried.saved), "moved before the first page");
        }
    }.run },
    .{ .name = "a swipe turns like a tap", .run = struct {
        fn run() !void {
            const tapped = try play(&.{forward});
            const swiped = try play(&.{swipe(1)});
            try expect(samePlace(tapped.saved, swiped.saved), "a swipe went somewhere else");
        }
    }.run },
    .{ .name = "reading time counts only while the page shows", .run = struct {
        fn run() !void {
            // A minute on the page, then a minute with the toolbar open
            const r = try play(&.{ wait(60_000), forward, top, wait(60_000), page_middle });
            try expect(r.saved.seconds >= 55 and r.saved.seconds <= 70, "reading time off");
        }
    }.run },
    .{ .name = "common actions on a page run and leave the place alone", .run = struct {
        fn run() !void {
            const plain = try play(&.{forward});
            const busy = try play(&.{
                forward,
                hold(600, 700), lift, above_sheet, above_sheet, // The dictionary question, then the definition, each closed above it
                top, tap(696, 118), page_middle, // The text settings, closed
                top, tap(816, 118), tap(636, 120), // Contents, closed above it
                top, tap(1176, 118), tap(636, 200), // The menu, closed above the card
                wait(130_000), // Past the Wi-Fi pause
            });
            try expect(samePlace(plain.saved, busy.saved), "the place moved");
            try expect(busy.updates > plain.updates, "nothing was drawn");
        }
    }.run },
    .{ .name = "locking and waking mid-book keeps the place and the screen", .run = struct {
        fn run() !void {
            const plain = try play(&.{ forward, forward });
            const locked = try play(&.{ forward, lock_it, wait(3_000), wake, forward });
            try expect(samePlace(plain.saved, locked.saved), "the place moved");
            try expect(locked.updates > plain.updates, "the lock screen wasn't drawn");
        }
    }.run },
    .{ .name = "a couple of minutes into a book Wi-Fi goes off, and comes back on leaving", .run = struct {
        fn run() !void {
            const r = try play(&.{ wait(150_000), forward });
            try expect(r.airplane_asked_on, "airplane mode wasn't turned on");
            try expect(!r.airplane_at_end, "Wi-Fi wasn't put back");
            try expect(!r.wifi_note_left, "the note was left behind");
        }
    }.run },
    .{ .name = "Wi-Fi comes back even when the Kindle was slow to say it went off", .run = struct {
        fn run() !void {
            const r = try playOn(.{ .radio_slow = true }, &.{ wait(150_000), forward });
            try expect(r.airplane_asked_on, "airplane mode wasn't turned on");
            try expect(!r.airplane_at_end, "Wi-Fi was left off");
            // The note may stay, as Wi-Fi coming back went unconfirmed too: noface.sh or
            // the next start checks again, so it's kept until Wi-Fi is seen on
        }
    }.run },
    .{ .name = "after jumping to a chapter, Back returns to the page being read", .run = struct {
        fn run() !void {
            const read_on = try play(&.{ forward, forward, forward });
            const contents = tap(816, 118);
            const first_chapter = tap(636, 390);
            const back_button = tap(205, 1626);
            const jumped = try play(&.{ forward, forward, forward, top, contents, first_chapter });
            try expect(!samePlace(read_on.saved, jumped.saved), "the chapter didn't move the place");
            const returned = try play(&.{ forward, forward, forward, top, contents, first_chapter, back_button });
            try expect(samePlace(read_on.saved, returned.saved), "Back didn't return to the page");
            // The toolbar's chapter skip is a jump too
            const chapter_back = tap(110, 1450);
            const moved = try play(&.{ forward, forward, forward, top, chapter_back, page_middle });
            try expect(!samePlace(read_on.saved, moved.saved), "the chapter skip didn't move the place");
            const skipped = try play(&.{ forward, forward, forward, top, chapter_back, page_middle, back_button });
            try expect(samePlace(read_on.saved, skipped.saved), "Back didn't follow a chapter skip");
        }
    }.run },
    .{ .name = "a quick look into a book leaves Wi-Fi alone", .run = struct {
        fn run() !void {
            const r = try play(&.{ wait(60_000), forward });
            try expect(!r.airplane_asked_on, "airplane mode was turned on");
        }
    }.run },
    .{ .name = "airplane mode the reader turned on stays on", .run = struct {
        fn run() !void {
            const r = try playOn(.{ .airplane = true }, &.{ wait(150_000), forward });
            try expect(r.airplane_at_end, "noface turned the reader's airplane mode off");
            try expect(!r.wifi_note_left, "noface claimed the reader's airplane mode");
        }
    }.run },
    .{ .name = "with Bluetooth on, Wi-Fi is left alone", .run = struct {
        fn run() !void {
            const r = try playOn(.{ .bluetooth = true }, &.{ wait(150_000), forward });
            try expect(!r.airplane_asked_on, "airplane mode could cut Bluetooth off");
        }
    }.run },
    .{ .name = "holding a word looks it up, and its Highlight button highlights it", .run = struct {
        fn run() !void {
            const r = try playOn(.{ .dictionary = true }, &.{ hold(600, 700), lift, highlight_button, page_middle });
            try expect(r.looked_up, "the dictionary wasn't opened");
            try expect(r.highlights == 1, "the word wasn't highlighted");
        }
    }.run },
    .{ .name = "without a dictionary, holding a word asks once to get it, and Not now stops the asking", .run = struct {
        fn run() !void {
            const r = try play(&.{
                hold(600, 700), lift, cardRow(2, 1), above_sheet, // Asked: Not now, then the sheet closed
                hold(600, 700), lift, highlight_button, page_middle, // Not asked again: straight to the sheet
            });
            try expect(!r.offers_dictionary, "it would ask again");
            try expect(r.highlights == 1, "the word wasn't highlighted");
        }
    }.run },
    .{ .name = "a dictionary download that can't start says so, and the word can still be highlighted", .run = struct {
        fn run() !void {
            // The pretend Kindle starts no programs, so curl never runs
            const r = try play(&.{ hold(600, 700), lift, cardRow(2, 0), cardRow(1, 0), highlight_button, page_middle });
            try expect(!r.looked_up, "a dictionary appeared from nowhere");
            try expect(r.highlights == 1, "the word wasn't highlighted");
        }
    }.run },
    .{ .name = "the toolbar's bookmark marks the page, and again unmarks it", .run = struct {
        fn run() !void {
            const once = try play(&.{ top, tap(936, 118), page_middle });
            try expect(once.bookmarks == 1, "the page wasn't bookmarked");
            const twice = try play(&.{ top, tap(936, 118), tap(936, 118), page_middle });
            try expect(twice.bookmarks == 0, "the bookmark stayed");
        }
    }.run },
    .{ .name = "a book opens from the library, and Home goes back", .run = struct {
        fn run() !void {
            const r = try playOn(.{ .library = true }, &.{ tapIn(library_ui.bookRect(0, 0)), wait(2_000), top, tap(150, 118) });
            try expect(r.opened[0], "the book didn't open");
        }
    }.run },
    .{ .name = "finishing a book of a series offers the next, and it opens", .run = struct {
        fn run() !void {
            const r = try playOn(.{
                .library = true,
                .books = &.{ "Scenario Book -- noface tests -- Scenario Saga #1.epub", "Scenario Book -- noface tests -- Scenario Saga #2.epub" },
                .read_before = 0,
            }, &.{
                tapIn(library_ui.heroRect(width)), wait(2_000), // Continue the first
                top, tap(1176, 118), tap(600, 1600), // ⋮, Mark as finished
                top, tap(150, 118), // Home, where the next one is offered
                tap(600, 1604), // Up next: Read it now
                wait(2_000), top, tap(150, 118), // Home
            });
            try expect(r.finished[0], "the first wasn't marked finished");
            try expect(r.opened[1], "the next one didn't open");
        }
    }.run },
    .{ .name = "the page, toolbar, text settings, a definition and the library look as they should", .run = struct {
        fn run() !void {
            const shots = .{
                .{ Snapshot.page, &[_]Step{forward} },
                .{ Snapshot.toolbar, &[_]Step{ forward, top } },
                .{ Snapshot.@"aa-font", &[_]Step{ forward, top, tap(696, 118), tap(477, 270) } },
                .{ Snapshot.definition, &[_]Step{ forward, hold(600, 700), lift } },
            };
            inline for (shots) |shot| {
                const r = try playOn(.{ .dictionary = true, .snapshot = shot[0] }, shot[1]);
                try expect(r.looks_right, @tagName(shot[0]) ++ " looks different");
            }
            const lib = try playOn(.{ .library = true, .snapshot = .library }, &.{});
            try expect(lib.looks_right, "library looks different");
        }
    }.run },
};

/// A tap in the middle of `r`.
fn tapIn(r: library_ui.Rect) Step {
    return tap(@intCast(r.x + r.w / 2), @intCast(r.y + r.h / 2));
}

fn expect(ok: bool, why: []const u8) !void {
    if (!ok) {
        std.debug.print("    {s}\n", .{why});
        return error.ScenarioFailed;
    }
}

/// The real stderr, kept aside while a scenario's app output goes nowhere; -1 when
/// it's in place. A crash puts it back first, so its message is seen.
var hidden_stderr: i32 = -1;

pub fn showCrashes() void {
    if (hidden_stderr >= 0) _ = linux.dup2(hidden_stderr, 2);
}

/// The panic handler for noface-scenarios: the message reaches the terminal even
/// when it happens mid-scenario.
pub const panic = std.debug.FullPanic(struct {
    fn crash(msg: []const u8, first: ?usize) noreturn {
        showCrashes();
        std.debug.defaultPanic(msg, first);
    }
}.crash);

/// Wall time, for how long a scenario really took: the app's own clock is the fake one.
fn realMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Runs every scenario, printing a line for each. The number that failed.
fn runScenarios() u32 {
    var failed: u32 = 0;
    for (scenarios) |s| {
        const t0 = realMs();
        if (s.run()) {
            std.debug.print("ok    {s} ({d} ms)\n", .{ s.name, realMs() - t0 });
        } else |err| {
            failed += 1;
            std.debug.print("FAIL  {s}: {s}\n", .{ s.name, @errorName(err) });
        }
    }
    std.debug.print("{d} of {d} scenarios passed\n", .{ scenarios.len - failed, scenarios.len });
    return failed;
}

pub fn main(init: std.process.Init.Minimal) !void {
    write_snapshots = init.environ.getPosix("NOFACE_WRITE_SNAPSHOTS");
    if (runScenarios() > 0) std.process.exit(1);
}

/// `noface selftest`, on the reader's Kindle: the scenarios, then this Kindle's own
/// fonts, dictionaries and a few of its books, opened in memory with nothing saved
/// where the reader's things are. True when everything passed.
pub fn selftest() bool {
    var ok = runScenarios() == 0;
    std.debug.print("\nthis Kindle\n", .{});

    const fonts_db = @import("kindle/fonts.zig");
    const file = @import("sys/file.zig");
    for (settings_model.builtin_families, 0..) |name, i| {
        const usable = if (file.map(fonts_db.path(i, false, false))) |data| Font.usable(data) else |_| false;
        std.debug.print("{s}  font {s}\n", .{ if (usable) "ok  " else "FAIL", name });
        ok = ok and usable;
    }
    for ([_][]const u8{ "dict-en", "dict-pt" }) |name| {
        var buf: [96]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, paths.data_dir ++ "/{s}", .{name}, 0) catch continue;
        const data = file.map(path) catch {
            std.debug.print("--    {s} not installed\n", .{name});
            continue;
        };
        const readable = dictionary.Dictionary.open(data) != null;
        std.debug.print("{s}  {s}\n", .{ if (readable) "ok  " else "FAIL", name });
        ok = ok and readable;
    }
    const helper = file.exists(paths.jxr_helper);
    std.debug.print("{s}  picture helper (jxr2pgm)\n", .{if (helper) "ok  " else "FAIL"});
    ok = ok and helper;

    // A few of the reader's books, each opened to its first page
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const dir = @import("sys/dir.zig");
    for ([_][]const u8{ ".epub", ".kfx" }) |suffix| {
        const found = dir.findFiles(arena.allocator(), paths.documents, suffix) catch continue;
        // Up to three that noface can open; protected ones (most bought from Amazon)
        // open in the Kindle's own reader instead, so they're passed over, not failed
        var opened: usize = 0;
        for (found[0..@min(found.len, 12)]) |path| {
            if (opened == 3) break;
            const name = std.fs.path.stem(path);
            const short = name[0..@min(name.len, 48)];
            if (playOn(.{ .real_book = path }, &.{})) |r| {
                std.debug.print("ok    opened {s} ({d} ms)\n", .{ short, r.ms });
                opened += 1;
            } else |err| switch (err) {
                error.Encrypted, error.Compressed, error.NotKfx => std.debug.print("--    {s}: not one noface opens ({s})\n", .{ short, @errorName(err) }),
                else => {
                    std.debug.print("FAIL  opened {s}: {s}\n", .{ short, @errorName(err) });
                    ok = false;
                },
            }
        }
    }
    std.debug.print("\nselftest: {s}\n", .{if (ok) "everything passed" else "something failed (see FAIL above)"});
    return ok;
}
