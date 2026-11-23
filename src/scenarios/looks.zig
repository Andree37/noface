//! Screens compared with their reference images (src/testdata/recorded/<model>/).
const library_ui = @import("../ui/library.zig");
const aa = @import("../ui/aa.zig");
const keyboard = @import("../ui/keyboard.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const Scenario = harness.Scenario;
const Snapshot = harness.Snapshot;
const expect = harness.expect;
const play_on = harness.play_on;
const word_held = harness.word_held;
const taps = @import("taps.zig");
const Step = taps.Step;
const book_series = taps.book_series;
const forward = taps.forward;
const hold_in = taps.hold_in;
const lift = taps.lift;
const lock_it = taps.lock_it;
const start_running = taps.start_running;
const tap_on = taps.tap_on;
const tool = taps.tool;
const top = taps.top;
const typed = taps.typed;
const wait = taps.wait;
const width = taps.width;

pub const all = [_]Scenario{
    .{
        .name = "the page, toolbar, text settings, a definition, a book's search, the " ++
            "lock screen, running, the library, its search and a series list look as " ++
            "they should",
        .run = struct {
            fn run() !void {
                const a_word = try word_held(.{}, &.{forward});
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
                // Shelf enough for the grid's whole first row and part of its second, so
                // its columns are seen as well as the hero, read a while: when it was last
                // read, and at 300 words a minute, 1 h 40 min left
                const shelf: Kindle = .{
                    .library = true,
                    .books = &shelf_books,
                    .snapshot = .library,
                    .read_before = .{ .words_left = 30_000 },
                    .speed = .{ .pages = 10, .words = 3000, .seconds = 600 },
                };
                const lib = try play_on(shelf, &.{});
                try expect(lib.looks_right, "library looks different");
                const search_books = tap_on(library_ui.place(.search));
                const found: Kindle = .{ .library = true, .snapshot = .@"library-search" };
                const lib_search = try play_on(found, &.{search_books});
                try expect(lib_search.looks_right, "the library's search looks different");
                const hold_hero = hold_in(library_ui.hero_rect(width));
                const series_list = [_]Step{ hold_hero, lift, book_series };
                const found_series: Kindle = .{ .library = true, .snapshot = .series };
                const series = try play_on(found_series, &series_list);
                try expect(series.looks_right, "the series list looks different");
            }
        }.run,
    },
};

/// A shelf for the library's look: more books than one row of its grid takes.
const shelf_books = [_][]const u8{ "a.epub", "b.epub", "c.epub", "d.epub", "e.epub", "f.epub" };
