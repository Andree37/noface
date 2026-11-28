//! What noface asks of the Kindle itself: Wi-Fi while reading, airplane mode, Bluetooth, and the
//! quick panel's controls.
const std = @import("std");
const input_mod = @import("../kindle/input.zig");
const menu_ui = @import("../ui/menu.zig");
const harness = @import("harness.zig");
const Scenario = harness.Scenario;
const expect = harness.expect;
const levels_set = harness.levels_set;
const play = harness.play;
const play_on = harness.play_on;
const Kindle = harness.Kindle;
const same_place = harness.same_place;
const taps = @import("taps.zig");
const Step = taps.Step;
const forward = taps.forward;
const lift = taps.lift;
const panel_kindle = taps.panel_kindle;
const pull_down = taps.pull_down;
const tap_on = taps.tap_on;
const wait = taps.wait;

pub const all = [_]Scenario{
    .{
        .name = "Sync starts the Kindle's archive service first when it has stopped, " ++
            "and leaves it alone when it runs",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const sync = [_]Step{ pull_down, wait(100), tap_on(menu_ui.place(.sync).?) };
                const alloc = arena.allocator();
                const stopped: Kindle = .{ .archive_stopped = true, .sets_into = alloc };
                const restarted = try play_on(stopped, &sync);
                try expect(restarted.archive_started, "archive wasn't started again");
                try expect(restarted.sets.len > 0, "no sync was asked for");
                const running = try play_on(.{}, &sync);
                try expect(!running.archive_started, "archive was started though it ran");
            }
        }.run,
    },
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
        .name = "the quick panel's sliders, each dragged from its start to its end, set " ++
            "the Kindle's brightness and warmth to their highest",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const r = try play_on(.{ .sets_into = arena.allocator() }, &(.{pull_down} ++
                    along(menu_ui.brightness_row) ++ along(menu_ui.warmth_row) ++
                    .{tap_on(menu_ui.place(.close).?)}));
                const rows = [_]struct { []const u8, menu_ui.Row }{
                    .{ "flIntensity", menu_ui.brightness_row },
                    .{ "currentAmberLevel", menu_ui.warmth_row },
                };
                for (rows) |row| {
                    const levels = try levels_set(arena.allocator(), r.sets, row[0]);
                    try expect(levels.len > 0, "a slider set no level");
                    try expect(levels[levels.len - 1] == row[1].max, "a drag stopped short");
                }
            }

            /// A finger down at a slider's start, moved along to its end, and lifted.
            fn along(row: menu_ui.Row) [3]Step {
                const end = menu_ui.level_place(row, row.max);
                const to: input_mod.Point = .{ .x = end.x, .y = end.y };
                return .{ tap_on(menu_ui.level_place(row, 0)), .{ .act = .{ .drag = to } }, lift };
            }
        }.run,
    },
    .{
        .name = "the panel's Wi-Fi tile turns the radio on where it is, noface staying, and " ++
            "it stays on through a book, as the reader chose",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                // In airplane mode, as noface leaves it a while into a book
                const kindle: Kindle = .{ .airplane = true, .sets_into = arena.allocator() };
                const r = try play_on(kindle, &.{
                    pull_down,
                    wait(100), // Seen, and its status read, before a finger reaches it
                    tap_on(menu_ui.place(.wifi).?),
                    tap_on(menu_ui.place(.close).?),
                    wait(150_000), // Past when noface would turn Wi-Fi off while reading
                    forward,
                });
                var turned_on = false;
                for (r.sets) |set| {
                    // Only noface's own screens: the Kindle's settings never asked for
                    try expect(std.mem.indexOf(u8, set, "appmgrd") == null, "noface left");
                    if (std.mem.eql(u8, set, "com.lab126.cmd wirelessEnable 1")) turned_on = true;
                }
                try expect(turned_on, "the Wi-Fi tile didn't turn the radio on");
                try expect(!r.airplane_at_end, "Wi-Fi was turned off again while reading");
                try expect(!r.wifi_note_left, "noface took the reader's choice for its own");
            }
        }.run,
    },
    .{
        .name = "Wi-Fi noface paused while reading comes back with one tap on its tile, and " ++
            "stays on; airplane mode tapped then is the reader's own",
        .run = struct {
            fn run() !void {
                // A couple of minutes into the book: noface has paused Wi-Fi
                const paused = [_]Step{ wait(150_000), forward, pull_down, wait(100) };
                const later = [_]Step{ tap_on(menu_ui.place(.close).?), wait(150_000), forward };
                const back_on = try play(&(paused ++ .{tap_on(menu_ui.place(.wifi).?)} ++ later));
                try expect(back_on.airplane_asked_on, "noface didn't pause Wi-Fi to begin with");
                try expect(!back_on.airplane_at_end, "Wi-Fi didn't come back on, or didn't stay");
                try expect(!back_on.wifi_note_left, "noface still counts it as its own pause");
                // Airplane mode, shown off while paused: tapped, it's on, and the reader's
                const plane_tapped = paused ++ .{tap_on(menu_ui.place(.airplane).?)} ++ later;
                const kept_off = try play(&plane_tapped);
                try expect(kept_off.airplane_at_end, "the airplane tile turned the radio on");
                try expect(!kept_off.wifi_note_left, "noface would turn the reader's airplane " ++
                    "mode off on leaving the book");
            }
        }.run,
    },
    .{
        .name = "with Bluetooth on, turning Wi-Fi off warns first, and a second tap does it",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const kindle: Kindle = .{ .bluetooth = true, .sets_into = arena.allocator() };
                const wifi = tap_on(menu_ui.place(.wifi).?);
                const once = try play_on(kindle, &.{ pull_down, wait(100), wifi });
                try expect(!once.airplane_asked_on, "the radio went off without a warning");
                const twice = try play_on(kindle, &.{ pull_down, wait(100), wifi, wifi });
                try expect(twice.airplane_asked_on, "the second tap didn't turn the radio off");
            }
        }.run,
    },
    .{
        .name = "the quick panel's controls each ask the Kindle for what they show: a " ++
            "step of brightness and of warmth, the warmth's schedule, airplane mode, " ++
            "Bluetooth and a sync",
        .run = struct {
            fn run() !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const panel = struct {
                    fn tap_panel(h: menu_ui.Hit) Step {
                        return tap_on(menu_ui.place(h).?);
                    }
                }.tap_panel;
                const r = try play_on(.{ .sets_into = arena.allocator() }, &.{
                    pull_down,
                    panel(.brighter),
                    panel(.dimmer),
                    panel(.warmer),
                    panel(.cooler),
                    panel(.schedule),
                    panel(.airplane),
                    panel(.airplane),
                    panel(.bluetooth),
                    panel(.sync),
                    tap_on(menu_ui.place(.close).?),
                });
                // Brightness and warmth a step up, then back down, each
                for ([_][]const u8{ "flIntensity", "currentAmberLevel" }) |level| {
                    const steps = try levels_set(arena.allocator(), r.sets, level);
                    try expect(steps.len == 2, "a level wasn't stepped twice");
                    try expect(steps[0] > steps[1], "a level didn't step up, then down");
                }
                // The rest in order, from the pretend Kindle's readings: the schedule off,
                // Wi-Fi on, Bluetooth off
                const asked = [_][]const u8{
                    "com.lab126.powerd amberSchedEnable 1",
                    "com.lab126.cmd wirelessEnable 0",
                    "com.lab126.cmd wirelessEnable 1",
                    "com.lab126.btfd BTenable 1:2",
                    "com.lab126.quickactions syncAndCheck 1",
                };
                var at: u32 = 0;
                for (r.sets) |set| {
                    if (at < asked.len and std.mem.eql(u8, set, asked[at])) at += 1;
                }
                try expect(at == asked.len, "a control didn't ask the Kindle, or not in turn");
            }
        }.run,
    },
};
