//! Turning pages and keeping the reader's place: taps, swipes, Back, the layout's page breaks,
//! locking, and a book marked read.
const std = @import("std");
const assert = std.debug.assert;
const library_ui = @import("../ui/library.zig");
const card = @import("../ui/card.zig");
const toolbar = @import("../ui/toolbar.zig");
const goto_ui = @import("../ui/goto.zig");
const back_button_ui = @import("../screens/reader/back_button.zig");
const more = @import("../screens/reader/more.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const Scenario = harness.Scenario;
const adjacent_pages = harness.adjacent_pages;
const breaks_digest = harness.breaks_digest;
const expect = harness.expect;
const play = harness.play;
const play_on = harness.play_on;
const same_place = harness.same_place;
const word_held = harness.word_held;
const word_shown_twice = harness.word_shown_twice;
const taps = @import("taps.zig");
const above_sheet = taps.above_sheet;
const back = taps.back;
const forward = taps.forward;
const height = taps.height;
const lift = taps.lift;
const lock_it = taps.lock_it;
const page_middle = taps.page_middle;
const swipe = taps.swipe;
const tap = taps.tap;
const tap_in = taps.tap_in;
const tap_on = taps.tap_on;
const tool = taps.tool;
const top = taps.top;
const wait = taps.wait;
const wake = taps.wake;
const width = taps.width;

pub const all = [_]Scenario{
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
                try expect(laid_out.breaks != 0, "no page breaks were saved");
                // Bold word starts lay words out at their own widths, and break there
                const bold = try play_on(.{ .bold_starts = true }, &.{wait(3000)});
                try expect(bold.breaks != 0, "no page breaks were saved with bold word starts");
                // Compared with those recorded for this Kindle's screen
                const want = harness.recorded_breaks;
                if (laid_out.breaks != want.plain or bold.breaks != want.bold_starts) {
                    std.debug.print(
                        "page breaks moved: {x}, with bold word starts {x}. If the layout " ++
                            "changed on purpose, raise layout_version in page_store.zig " ++
                            "and write these to src/testdata/recorded/{s}/breaks.txt, so " ++
                            "saved breaks are laid out again.\n",
                        .{ laid_out.breaks, bold.breaks, harness.layout_model },
                    );
                }
                try expect(laid_out.breaks == want.plain, "page breaks moved");
                const bold_same = bold.breaks == want.bold_starts;
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
                const a_word = try word_held(.{}, &.{forward});
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
    .{
        .name = "a book marked finished then unread starts again, and stays unread",
        .run = struct {
            fn run() !void {
                const read_row = tap_on(more.place(.finished)); // Finished, or unread once it is
                // Marking it finished leaves the toolbar open: its ⋮ is tapped again
                const r = try play(&.{
                    forward,     forward,     forward,
                    top,         tool(.more), read_row,
                    tool(.more), read_row,
                });
                try expect(!r.finished[0], "it's still marked finished");
                try expect(r.saved.para == 0, "it didn't start again");
                try expect(r.saved.byte == 0, "it didn't start again");
                try expect((r.saved.percent orelse 0) < 99, "it's saved as read by its percent");
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
};
