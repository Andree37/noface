//! Words on the page: looking one up, highlighting, a footnote, a picture, and a highlight's
//! handles.
const std = @import("std");
const goto_ui = @import("../ui/goto.zig");
const selection = @import("../ui/selection.zig");
const places = @import("../screens/places.zig");
const placed = @import("../screens/placed.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const Scenario = harness.Scenario;
const expect = harness.expect;
const play = harness.play;
const play_on = harness.play_on;
const same_place = harness.same_place;
const shown_words = harness.shown_words;
const word_after = harness.word_after;
const word_at = harness.word_at;
const word_held = harness.word_held;
const taps = @import("taps.zig");
const Step = taps.Step;
const above_sheet = taps.above_sheet;
const away_from_word = taps.away_from_word;
const card_row = taps.card_row;
const drag_to = taps.drag_to;
const forward = taps.forward;
const highlight_button = taps.highlight_button;
const hold = taps.hold;
const lift = taps.lift;
const tap = taps.tap;
const tap_on = taps.tap_on;
const tool = taps.tool;
const top = taps.top;
const wait = taps.wait;

pub const all = [_]Scenario{
    .{
        .name = "holding a word looks it up, and its Highlight button highlights it",
        .run = struct {
            fn run() !void {
                const a_word = try word_held(.{ .dictionary = true }, &.{});
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
                const a_word = try word_held(.{}, &.{});
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
                const a_word = try word_held(.{}, &.{});
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
        .name = "a footnote's mark opens its note in a panel and a tap above closes it, and " ++
            "holding a picture shows it whole until its button, the book reading on after both",
        .run = struct {
            fn run() !void {
                // Where the first page put its note's mark and its picture, as its log says
                const first = try play_on(.{ .book = .notes }, &.{});
                const mark_at = first.placed[@backingInt(placed.What.note)] orelse
                    return error.MarkNotPlaced;
                // The picture follows the mark on the first page, or on the next where a
                // small screen has no room left for it there
                const picture_kind = @backingInt(placed.What.picture);
                const on_first = first.placed[picture_kind] != null;
                const next = if (on_first) first else try play_on(.{ .book = .notes }, &.{forward});
                const picture = next.placed[picture_kind] orelse return error.PictureNotPlaced;
                const turns_to_picture: u32 = if (on_first) 0 else 1;
                const mark = tap_on(mark_at);
                // The note's panel open over the page, then closed by a tap above it
                const noted = try play_on(.{ .book = .notes, .snapshot = .note }, &.{mark});
                try expect(noted.looks_right, "the note's panel looks different");
                // Closed, the page turns again as before: a tap on an open panel would
                // only close it
                const turned = try play_on(.{ .book = .notes }, &.{forward});
                try expect(!same_place(turned.saved, first.saved), "the book didn't turn");
                const above = tap_on(places.page.top);
                const closed = try play_on(.{ .book = .notes }, &.{ mark, above, forward });
                try expect(same_place(closed.saved, turned.saved), "the note stayed open");
                // On the picture's page, the picture whole, then closed by its button; the
                // viewer follows a finger from its touch, and acts on its lift. Each list
                // starts with the turn to the picture's page, skipped when it's the first
                const close = tap_on(places.find("picture.close").?);
                const at = hold(picture.x, picture.y);
                const held_from_start = [_]Step{ forward, at, lift };
                const held = held_from_start[1 - turns_to_picture ..];
                const shown = try play_on(.{ .book = .notes, .snapshot = .picture }, held);
                try expect(shown.looks_right, "the picture shown whole looks different");
                const closed_from_start = held_from_start ++ .{ close, lift, forward };
                const closed_then_on = closed_from_start[1 - turns_to_picture ..];
                const put_back = try play_on(.{ .book = .notes }, closed_then_on);
                // A page on from the picture's
                const page_after: [2]Step = @splat(forward);
                const to_after = page_after[0 .. turns_to_picture + 1];
                const after = try play_on(.{ .book = .notes }, to_after);
                try expect(same_place(put_back.saved, after.saved), "the picture stayed open");
            }
        }.run,
    },
    .{
        .name = "a highlight chosen from Go To's notes brings its page back, a tap selects " ++
            "it, and its Delete bubble removes it",
        .run = struct {
            fn run() !void {
                const a_word = try word_held(.{ .dictionary = true }, &.{forward});
                const held_at = a_word.act.hold;
                const highlight_it = [_]Step{ a_word, lift, highlight_button, away_from_word };
                const highlighted = [_]Step{forward} ++ highlight_it;
                const notes_tab = tap_on(goto_ui.place(.{ .tab = .notes }));
                const first_note = tap_on(goto_ui.place(.{ .row = 0 }));
                const found = highlighted ++ .{ forward, top, tool(.goto), notes_tab, first_note };
                const on_its_page = try play_on(.{ .dictionary = true }, &highlighted);
                const returned = try play_on(.{ .dictionary = true }, &found);
                const brought_back = same_place(returned.saved, on_its_page.saved);
                try expect(brought_back, "Go To didn't bring it back");
                // Tapped, it's selected: its handles and its Delete bubble
                const selected_steps = found ++ .{tap(held_at.x, held_at.y)};
                const kindle: Kindle = .{ .dictionary = true, .snapshot = .highlight };
                const selected = try play_on(kindle, &selected_steps);
                try expect(selected.looks_right, "the selected highlight looks different");
                const bubble = selected.placed[@backingInt(placed.What.delete)] orelse
                    return error.DeleteNotPlaced;
                const removed = try play_on(.{ .dictionary = true }, &(selected_steps ++
                    .{tap_on(bubble)}));
                try expect(removed.highlights == 0, "the Delete bubble left the highlight");
            }
        }.run,
    },
    .{
        .name = "a highlight's handle still drags once the book is laid out behind it",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
                defer arena.deinit();
                // Read before, so it opens with its first pages and lays out the rest on
                // ticks, as a book opened again after a layout change does
                const read: Kindle = .{ .dictionary = true, .read_before = .{} };
                const a_word = try word_held(read, &.{});
                const held_at = a_word.act.hold;
                const highlighted = [_]Step{ a_word, lift, highlight_button, away_from_word };
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
};
