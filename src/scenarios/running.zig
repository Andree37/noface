//! Running mode: moving on by itself, its taps, its pause, and holding the Kindle awake.
const std = @import("std");
const settings_model = @import("../model/settings.zig");
const running_model = @import("../model/running.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const Scenario = harness.Scenario;
const expect = harness.expect;
const play = harness.play;
const play_on = harness.play_on;
const same_place = harness.same_place;
const word_held = harness.word_held;
const taps = @import("taps.zig");
const Step = taps.Step;
const back = taps.back;
const forward = taps.forward;
const lift = taps.lift;
const lock_it = taps.lock_it;
const pause_button = taps.pause_button;
const pause_resume = taps.pause_resume;
const pause_stop = taps.pause_stop;
const pause_tap = taps.pause_tap;
const running_middle = taps.running_middle;
const start_running = taps.start_running;
const wait = taps.wait;
const wake = taps.wake;

pub const all = [_]Scenario{
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
                const on_pace = on.running_pace orelse
                    return expect(false, "no pace after going on");
                try expect(on_pace > first, "going on early didn't quicken the pace");
                const went_back = try play(&(turned ++ [_]Step{ wait(1_000), back }));
                const back_pace = went_back.running_pace orelse
                    return expect(false, "no pace after going back");
                try expect(back_pace < on_pace, "going back didn't slow it");
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
                const a_word = try word_held(.{ .dictionary = true }, &.{});
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
        .name = "locking while the pause card is up leaves running paused, and the Kindle " ++
            "free to sleep under the lock",
        .run = struct {
            fn run() !void {
                const card_up = start_running ++ [_]Step{ wait(2_000), pause_tap };
                const locked = try play(&(card_up ++ [_]Step{lock_it}));
                try expect(!locked.awake_at_end, "the Kindle was held awake under the lock");
                // Unlocked a while later: still where the card stopped it
                const before = try play(&card_up);
                const unlocked = try play(&(card_up ++ [_]Step{ lock_it, wake, wait(120_000) }));
                const kept = same_place(unlocked.saved, before.saved);
                try expect(kept, "running went on after the lock");
                try expect(!unlocked.awake_at_end, "the Kindle was held awake while paused");
            }
        }.run,
    },
    .{
        .name = "locking while running lets the Kindle sleep, and it's held awake again " ++
            "once unlocked",
        .run = struct {
            fn run() !void {
                const going = start_running ++ [_]Step{wait(2_000)};
                const locked = try play(&(going ++ [_]Step{lock_it}));
                try expect(!locked.awake_at_end, "the Kindle was held awake under the lock");
                const unlocked = try play(&(going ++ [_]Step{ lock_it, wake, wait(2_000) }));
                try expect(unlocked.awake_at_end, "running after unlocking let the Kindle sleep");
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
                const backed_pace = backed.running_pace orelse
                    return expect(false, "no pace after a back tap");
                try expect(backed_pace == first, "a back tap with nothing before slowed");
            }
        }.run,
    },
};
