//! What opens over a book: its search, bookmarks, Go To, Go to page and Aa.
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("../model/settings.zig");
const toolbar = @import("../ui/toolbar.zig");
const aa = @import("../ui/aa.zig");
const goto_ui = @import("../ui/goto.zig");
const more = @import("../screens/reader/more.zig");
const keyboard = @import("../ui/keyboard.zig");
const search_sheet = @import("../ui/search_sheet.zig");
const harness = @import("harness.zig");
const Kindle = harness.Kindle;
const Scenario = harness.Scenario;
const expect = harness.expect;
const play = harness.play;
const play_on = harness.play_on;
const same_place = harness.same_place;
const taps = @import("taps.zig");
const Step = taps.Step;
const backspace = taps.backspace;
const forward = taps.forward;
const lift = taps.lift;
const page_middle = taps.page_middle;
const tap = taps.tap;
const tap_on = taps.tap_on;
const text_settings_button = taps.text_settings_button;
const themes_tab = taps.themes_tab;
const tool = taps.tool;
const top = taps.top;
const typed = taps.typed;
const width = taps.width;

pub const all = [_]Scenario{
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
    .{
        .name = "with more bookmarks than Go To's list has rows, its next page lists the " ++
            "rest and its first row jumps to the next bookmark, and back again to the first",
        .run = struct {
            const marked = goto_ui.rows + 1; // One more than a page of the list holds
            /// Each of the first `marked` pages bookmarked, ending on the page after.
            const marking = steps: {
                var steps: [marked * 4]Step = undefined;
                for (0..marked) |i| {
                    steps[i * 4 ..][0..4].* = .{ top, tool(.bookmark), page_middle, forward };
                }
                break :steps steps;
            };
            /// The largest text, so the book has a page to mark for each, on any screen
            const largest: Kindle = .{ .text_size = settings_model.sizes.len - 1 };
            fn run() !void {
                const all_marked = try play_on(largest, &marking);
                try expect(all_marked.bookmarks == marked, "not every page was bookmarked");
                const notes = [_]Step{
                    top, tool(.goto), tap_on(goto_ui.place(.{ .tab = .notes })),
                };
                const first_row = tap_on(goto_ui.place(.{ .row = 0 }));
                const next_page = tap_on(goto_ui.place(.next));
                const prev_page = tap_on(goto_ui.place(.prev));
                // The last bookmark is on the page `marked - 1` turns on
                const turns: [marked - 1]Step = @splat(forward);
                const last_page = try play_on(largest, &turns);
                const on = try play_on(largest, &(marking ++ notes ++ .{ next_page, first_row }));
                try expect(same_place(on.saved, last_page.saved), "next didn't list the rest");
                const start = try play_on(largest, &.{});
                const there_and_back = [_]Step{ next_page, prev_page, first_row };
                const returned = try play_on(largest, &(marking ++ notes ++ there_and_back));
                try expect(same_place(returned.saved, start.saved), "prev didn't list the first");
            }
        }.run,
    },
    .{
        .name = "Go to page from the ⋮ menu lands on the page typed, and a page past the " ++
            "book's end is turned down, the place kept",
        .run = struct {
            fn run() !void {
                const go_to_page = [_]Step{ top, tool(.more), tap_on(more.place(.go_to_page)) };
                const search_key = tap_on(keyboard.place(.enter));
                const third = try play(&.{ forward, forward });
                const typed_third = try play(&(go_to_page ++ typed("3") ++ .{search_key}));
                try expect(same_place(typed_third.saved, third.saved), "page 3 wasn't reached");
                // A digit typed too many, taken back
                const fixed = try play(&(go_to_page ++ typed("39") ++ .{ backspace, search_key }));
                try expect(same_place(fixed.saved, third.saved), "backspace didn't take back 9");
                const second = try play(&.{forward});
                const past = try play(&(.{forward} ++ go_to_page ++ typed("999") ++ .{search_key}));
                try expect(same_place(past.saved, second.saved), "a page past the end moved");
            }
        }.run,
    },
    .{
        .name = "a theme and a switch from Aa are kept and saved, the place kept with them",
        .run = struct {
            fn run() !void {
                const aa_sheet = [_]Step{ forward, forward, top, text_settings_button };
                const compact = tap_on(aa.place(.themes, .{ .theme = 0 }));
                const read = try play(&.{ forward, forward });
                const themed = try play(&(aa_sheet ++ .{ themes_tab, compact }));
                const size = aa.themes[0].size;
                try expect(themed.settings.size == size, "the theme wasn't used");
                try expect(themed.saved_settings.size == size, "the theme wasn't saved");
                try expect(same_place(themed.saved, read.saved), "the theme moved the place");
                const bold_index = comptime aa.switch_for(.bold);
                const font_tab = tap_on(aa.place(.themes, .{ .tab = .font }));
                const bold = tap_on(aa.place(.font, .{ .toggle = bold_index }));
                const bolded = try play(&(aa_sheet ++ .{ font_tab, bold }));
                try expect(bolded.settings.bold, "bold wasn't turned on");
                try expect(bolded.saved_settings.bold, "bold wasn't saved");
                try expect(same_place(bolded.saved, read.saved), "bold moved the place");
            }
        }.run,
    },
    .{
        .name = "a typeface, line spacing and margins chosen in Aa are kept and saved, " ++
            "the place kept with them",
        .run = struct {
            fn run() !void {
                // The sheet opens on its Font tab, with the typefaces' grid
                const aa_sheet = [_]Step{ forward, forward, top, text_settings_button };
                const read = try play(&.{ forward, forward });
                const bookerly = comptime settings_model.Families.named(.{}, "Bookerly").?;
                const typeface = tap_on(aa.family_place(.{}, bookerly));
                const chosen = try play(&(aa_sheet ++ .{typeface}));
                try expect(std.mem.eql(u8, chosen.settings.font.name(), "Bookerly"), "not chosen");
                const saved = chosen.saved_settings.font.name();
                try expect(std.mem.eql(u8, saved, "Bookerly"), "the typeface wasn't saved");
                try expect(same_place(chosen.saved, read.saved), "the typeface moved the place");
                const layout_tab = tap_on(aa.place(.themes, .{ .tab = .layout }));
                const widest = aa.spacing_row.steps - 1;
                const spaced = tap_on(aa.step_place(aa.spacing_row, widest));
                const narrow = tap_on(aa.step_place(aa.margin_row, 0));
                const laid = try play(&(aa_sheet ++ .{ layout_tab, spaced, lift, narrow, lift }));
                try expect(laid.settings.spacing == widest, "the spacing wasn't set");
                try expect(laid.saved_settings.spacing == widest, "the spacing wasn't saved");
                try expect(laid.settings.margin == 0, "the margins weren't set");
                try expect(laid.saved_settings.margin == 0, "the margins weren't saved");
                try expect(same_place(laid.saved, read.saved), "the layout moved the place");
            }
        }.run,
    },
    .{
        .name = "with more typefaces than the Aa grid has cells, its last cell turns it to " ++
            "the next page, whose typefaces are chosen and saved like the first's",
        .run = struct {
            const own = 10; // With the Kindle's four, more than two pages of five
            fn run() !void {
                const families = comptime offered_families();
                const per_page = aa.families_per_page(families);
                // The grid's last cell turns the page; the next page's first is chosen
                const pager = tap_on(aa.family_place(families, per_page));
                const first_of_next = tap_on(aa.family_place(families, 0));
                const kindle: Kindle = .{ .own_typefaces = own };
                const aa_sheet = [_]Step{ top, text_settings_button };
                const r = try play_on(kindle, &(aa_sheet ++ .{ pager, first_of_next }));
                const expected = families.names[per_page];
                try expect(std.mem.eql(u8, r.settings.font.name(), expected), "not chosen");
                try expect(std.mem.eql(u8, r.saved_settings.font.name(), expected), "not saved");
            }

            /// The typefaces the scenario offers, by name, as `own_offered` names them.
            fn offered_families() settings_model.Families {
                const builtin = settings_model.builtin_families;
                var names: [builtin.len + own][]const u8 = undefined;
                for (builtin, names[0..builtin.len]) |b, *n| n.* = b;
                for (names[builtin.len..], 1..) |*n, i| {
                    n.* = std.fmt.comptimePrint("Own {d}", .{i});
                }
                const final = names;
                return .offer(&final);
            }
        }.run,
    },
};
