//! What goes wrong: memory running out, a layout cut short, files that can't be read or saved, a
//! screen that fails, and the app's memory limit.
const std = @import("std");
const input_mod = @import("../kindle/input.zig");
const settings_model = @import("../model/settings.zig");
const library_ui = @import("../ui/library.zig");
const toolbar = @import("../ui/toolbar.zig");
const aa = @import("../ui/aa.zig");
const paths = @import("../kindle/paths.zig");
const setup = @import("../setup.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const ReadBefore = harness.ReadBefore;
const Scenario = harness.Scenario;
const app_memory = harness.app_memory;
const expect = harness.expect;
const play = harness.play;
const play_on = harness.play_on;
const same_place = harness.same_place;
const unreadable_kept = harness.unreadable_kept;
const taps = @import("taps.zig");
const Step = taps.Step;
const book_series = taps.book_series;
const forward = taps.forward;
const hold_in = taps.hold_in;
const largest_size = taps.largest_size;
const lift = taps.lift;
const list_back_to_library = taps.list_back_to_library;
const lock_it = taps.lock_it;
const not_in_a_series = taps.not_in_a_series;
const size_step = taps.size_step;
const swipe = taps.swipe;
const tap_in = taps.tap_in;
const tap_on = taps.tap_on;
const text_settings_button = taps.text_settings_button;
const tool = taps.tool;
const top = taps.top;
const wait = taps.wait;
const wake = taps.wake;
const width = taps.width;

pub const all = [_]Scenario{
    .{
        .name = "changing the text size again and again takes no more memory",
        .run = struct {
            fn run() !void {
                const sheet = [_]Step{ top, tool(.text) };
                // The slider's smallest step, then its largest, each a tap and a lift
                const change = [_]Step{ size_step(0), lift, largest_size, lift };
                const twice = try play(&(sheet ++ change));
                const often = try play(&(sheet ++ change ++ change ++ change ++ change));
                try expect(often.book_peak == twice.book_peak, "the book's memory grew");
                try expect(twice.pages_peak > 0, "the pages weren't laid out again");
                try expect(often.pages_peak <= twice.pages_peak, "the pages' memory grew");
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
                    top, tool(.text), largest_size, lift,
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
                // Its pages gone, how far in it is goes by the words before the place
                const from_start = [_]Step{ hero, wait(2_000), top, home };
                const at_start = try play_on(.{ .library = true }, &from_start);
                const total = at_start.saved.words_left orelse return error.WordsNotSaved;
                const left = failed.saved.words_left orelse return error.WordsNotSaved;
                // Checked, not assumed: a scenario reports and goes on, never crashes
                if (total == 0 or left > total) return expect(false, "the words left don't add up");
                const by_words: u32 = @intCast((total - left) * 100 / total);
                try expect(failed.saved.percent == by_words, "how far in it is changed");
            }
        }.run,
    },
    .{
        .name = "a scrub cut short by the lock leaves the place where it was",
        .run = struct {
            fn run() !void {
                // A quarter of the way through the book, then dragged on to three quarters
                const quarter = tap_on(toolbar.scrub_place(1, 4));
                const three_quarters = toolbar.scrub_place(3, 4);
                const to: input_mod.Point = .{ .x = three_quarters.x, .y = three_quarters.y };
                const along: Step = .{ .act = .{ .drag = to } };
                const plain = try play(&.{forward});
                const lifted = try play(&.{ forward, top, quarter, along, lift });
                try expect(!same_place(plain.saved, lifted.saved), "the scrubber didn't jump");
                const locked = try play(&.{
                    forward, top, quarter, along, lock_it, wait(3_000), wake,
                });
                try expect(same_place(plain.saved, locked.saved), "the lock jumped the book");
            }
        }.run,
    },
    .{
        .name = "a text size drag cut short by the lock leaves the size as it was",
        .run = struct {
            fn run() !void {
                // The Aa sheet opens on its Font tab, with the text size's slider
                const largest = aa.step_place(aa.size_row, aa.size_row.steps - 1);
                const along: Step = .{ .act = .{ .drag = .{ .x = largest.x, .y = largest.y } } };
                const begin = [_]Step{ top, text_settings_button, size_step(1), along };
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
        .name = "a book opens and pages through whatever highlights a sync leaves it",
        .run = struct {
            fn run() !void {
                // Each as Amazon's sync or an older noface could leave it: empty, ending
                // before it starts, one character, overlapping another, the same span
                // twice, the same ID twice, across many paragraphs, past the book's end,
                // and at the largest positions there are
                const notes =
                    \\highlight kindle.highlight-0 0 0
                    \\highlight kindle.highlight-10 10 5
                    \\highlight kindle.highlight-20 20 21
                    \\highlight kindle.highlight-30 30 90
                    \\highlight kindle.highlight-40 40 60
                    \\highlight kindle.highlight-41 30 90
                    \\highlight kindle.highlight-30 35 95
                    \\highlight kindle.highlight-50 50 1500
                    \\highlight kindle.highlight-900000 900000 1000000
                    \\highlight kindle.highlight-4294967000 4294967000 4294967295
                    \\bookmark kindle.bookmark-30 30 30
                    \\
                ;
                // Swiped, as a tap on a highlighted word selects it instead of turning
                // Past the highlights, all in the first few pages on the smallest screen,
                // so the toolbar's tap at the top of the page reaches no highlighted word
                const turns: [8]Step = @splat(swipe(1));
                const kindle: Kindle = .{ .notes_before = notes };
                // Go To's notes listed with them
                const listed_steps = turns ++ .{ top, tool(.goto) };
                const listed = try play_on(kindle, &listed_steps);
                const plain = try play(&listed_steps);
                try expect(same_place(listed.saved, plain.saved), "the highlights moved the place");
                // A bookmark set, so the notes file is written again: none stored is lost,
                // as what noface can't place it leaves for the device that made it
                const marked_steps = turns ++ .{ top, tool(.bookmark) };
                const marked = try play_on(kindle, &marked_steps);
                try expect((try play(&marked_steps)).bookmarks == 1, "the bookmark wasn't set");
                const stored = std.mem.count(u8, notes, "highlight ");
                try expect(marked.highlights == stored, "a stored note was dropped");
                try expect(marked.bookmarks == 2, "the stored bookmark was dropped");
            }
        }.run,
    },
    .{
        .name = "a book's place there but unreadable opens the book at its start, read and " ++
            "left, and is never written over; the speed learned is still saved",
        .run = struct {
            fn run() !void {
                const r = try play_on(.{ .place_unreadable = true }, &.{
                    wait(60_000), forward, top, tool(.home),
                });
                try expect(r.place_kept, "the unreadable place was written over");
                try expect(r.saved_speed_pages > 0, "the speed learned wasn't saved");
            }
        }.run,
    },
    .{
        .name = "a place the drive won't take is never taken for saved",
        .run = struct {
            fn run() !void {
                const read = [_]Step{ wait(60_000), forward };
                const saved = try play_on(.{}, &read);
                const refused = try play_on(.{ .place_unwritable = true }, &read);
                try expect(saved.saved.opened > 0, "the place wasn't saved");
                try expect(saved.book_last > 0, "a place saved wasn't taken for saved");
                try expect(refused.saved.opened == 0, "a place the drive refused was kept");
                // The book's record shows only what's saved: never a place the drive refused
                try expect(refused.book_last == 0, "a place the drive refused was taken for saved");
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
