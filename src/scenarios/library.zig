//! The library: opening a book, searching, series, stats, and finishing one.
const std = @import("std");
const library_ui = @import("../ui/library.zig");
const more = @import("../screens/reader/more.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const Scenario = harness.Scenario;
const expect = harness.expect;
const play_on = harness.play_on;
const taps = @import("taps.zig");
const backspace = taps.backspace;
const book_series = taps.book_series;
const card_row = taps.card_row;
const hold_in = taps.hold_in;
const lift = taps.lift;
const list_back_to_library = taps.list_back_to_library;
const page_middle = taps.page_middle;
const tap_in = taps.tap_in;
const tap_on = taps.tap_on;
const tool = taps.tool;
const top = taps.top;
const forward = taps.forward;
const Step = taps.Step;
const stats = @import("../model/stats.zig");
const typed = taps.typed;
const hold = taps.hold;
const keyboard = @import("../ui/keyboard.zig");
const wait = taps.wait;
const width = taps.width;

pub const all = [_]Scenario{
    .{
        .name = "every key typed in the library's search shows, a space at the end too",
        .run = struct {
            fn run() !void {
                const search_books = tap_on(library_ui.place(.search));
                const word = try play_on(.{ .library = true }, &(.{search_books} ++ typed("o")));
                const spaced = try play_on(.{ .library = true }, &(.{search_books} ++ typed("o ")));
                try expect(word.screen_hash != spaced.screen_hash, "the space didn't show");
            }
        }.run,
    },
    .{
        .name = "the library's search finds a book by its title as it's typed, and opens it",
        .run = struct {
            fn run() !void {
                const search_books = tap_on(library_ui.place(.search));
                const first_found = tap_on(search_sheet.place_row(0));
                const r = try play_on(.{ .library = true }, &(.{search_books} ++
                    typed("scenario") ++ .{ first_found, wait(2_000) }));
                try expect(r.opened[0], "the book found wasn't opened");
                // Two words, the space bar between, and a slip taken back with backspace:
                // a key that failed leaves words no title has, and nothing to open
                const slipped = typed("scenarix") ++ .{backspace} ++ typed("o book");
                const fixed = try play_on(.{ .library = true }, &(.{search_books} ++
                    slipped ++ .{ first_found, wait(2_000) }));
                try expect(fixed.opened[0], "the book typed with a slip wasn't opened");
            }
        }.run,
    },
    .{
        .name = "the library's search takes a capital with shift and an accent held on its " ++
            "letter, and finds the book written without them",
        .run = struct {
            // Assertions: one thing to know, whether the book typed this way opened
            fn run() !void {
                const search_books = tap_on(library_ui.place(.search));
                const first_found = tap_on(search_sheet.place_row(0));
                const a = keyboard.place(.{ .char = 'a' });
                const held_a = keyboard.held_letter(.{}, a.x, a.y).?;
                const acute = tap_on(keyboard.accent_place(held_a, 1));
                // "Scenário": S with shift, á held on a
                const steps = .{ search_books, tap_on(keyboard.place(.shift)) } ++
                    typed("scen") ++ .{ hold(a.x, a.y), acute } ++
                    typed("rio") ++ .{ first_found, wait(2_000) };
                const r = try play_on(.{ .library = true }, &steps);
                try expect(r.opened[0], "the book typed with a capital and an accent wasn't found");
            }
        }.run,
    },
    .{
        .name = "after a book's series list is left, the library's next tap opens a book",
        .run = struct {
            // Assertions: one thing to know, whether the tap opened the book
            fn run() !void {
                const hold_hero = hold_in(library_ui.hero_rect(width));
                const hero = tap_on(library_ui.place(.hero));
                const r = try play_on(.{ .library = true }, &.{
                    hold_hero,
                    lift,
                    book_series,
                    list_back_to_library,
                    wait(1_000),
                    hero,
                    wait(2_000),
                });
                try expect(r.opened[0], "the tap after the series list was dropped");
            }
        }.run,
    },
    .{
        .name = "a book opens from the library, and Home goes back",
        .run = struct {
            // Assertions: one thing to know, whether the book opened, Home closing it after
            fn run() !void {
                const r = try play_on(.{ .library = true }, &.{
                    tap_in(library_ui.book_rect(0, 0)),
                    wait(2_000),
                    top,
                    tool(.home),
                });
                try expect(r.opened[0], "the book didn't open");
            }
        }.run,
    },
    .{
        .name = "a book's place keeps the words left from it, fewer the further in, " ++
            "and the library shows the time they take unless time left is off",
        .run = struct {
            fn run() !void {
                const hero = tap_in(library_ui.hero_rect(width));
                const home = [_]Step{ wait(2_000), top, tool(.home) };
                const opened = try play_on(.{ .library = true }, &(.{hero} ++ home));
                const at_start = opened.saved.words_left orelse return error.WordsNotSaved;
                const further = [_]Step{ hero, wait(2_000), forward, forward } ++ home;
                const read_on = try play_on(.{ .library = true }, &further);
                const words_left = read_on.saved.words_left orelse return error.WordsNotSaved;
                try expect(words_left < at_start, "the words left didn't go down");
                // Known words and speed: the card's line changes
                const speed: stats.Speed = .{ .pages = 10, .words = 3000, .seconds = 600 };
                const before: harness.ReadBefore = .{ .words_left = at_start };
                const known = try play_on(.{ .library = true, .read_before = before }, &.{});
                const timed: Kindle = .{ .library = true, .read_before = before, .speed = speed };
                const shown = try play_on(timed, &.{});
                try expect(known.screen_hash != shown.screen_hash, "no time left shown");
                // Time left turned off: none on the card either
                var off = timed;
                off.time_left = false;
                const hidden = try play_on(off, &.{});
                try expect(known.screen_hash == hidden.screen_hash, "time left shown while off");
            }
        }.run,
    },
    .{
        .name = "a tap made while the stats were up closes them and never reaches the library",
        .run = struct {
            fn run() !void {
                const stats_button = tap_on(library_ui.place(.stats));
                const hero = tap_in(library_ui.hero_rect(width));
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
        .name = "the one book on the Unread tab's last page marked read leaves a page there " ++
            "is, never one past the last",
        .run = struct {
            // Assertions: the run ending without noface stopping is what's checked
            fn run() !void {
                // The hero, a first page full of unread books under it, and one over on
                // the second, the grid's first book after the first page's
                const last = library_ui.grid_size(true);
                const r = try play_on(.{ .library = true, .books = &unread_books }, &.{
                    // Each once the screen before it is drawn, as taps are dropped till then
                    tap_on(library_ui.place(.{ .tab = .unread })),
                    wait(2_000),
                    tap_on(library_ui.place(.next)),
                    wait(2_000),
                    hold_in(library_ui.book_rect(last, 1)),
                    lift,
                    wait(2_000),
                    card_row(3, 1), // Mark as read
                    wait(2_000),
                });
                try expect(r.updates > 0, "the library wasn't drawn again");
            }

            const unread_books = names: {
                var list: [harness.books_max][]const u8 = undefined;
                for (&list, 0..) |*name, i| {
                    name.* = std.fmt.comptimePrint("Unread {d:0>2}.epub", .{i});
                }
                const named = list;
                break :names named;
            };
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
                    tool(.home), // Home, on the toolbar left open, where the next one is offered
                    card_row(1, 0), // Up next: Read it now
                    wait(2_000), top, tool(.home), // Home
                });
                try expect(r.finished[0], "the first wasn't marked finished");
                try expect(r.opened[1], "the next one didn't open");
            }
        }.run,
    },
};
