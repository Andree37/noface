//! The scenarios' touches, by what they're on: a page's turns and top, the toolbar's
//! tools, a card's rows, the keyboard's keys, running's taps. Each is worked out from
//! where its screen says its control is (screens/places.zig), so the scenarios follow
//! the layout.
const std = @import("std");
const assert = std.debug.assert;
const input_mod = @import("../kindle/input.zig");
const library_ui = @import("../ui/library.zig");
const card = @import("../ui/card.zig");
const menu_ui = @import("../ui/menu.zig");
const style = @import("../ui/style.zig");
const toolbar = @import("../ui/toolbar.zig");
const aa = @import("../ui/aa.zig");
const book_model = @import("../model/book.zig");
const goto_ui = @import("../ui/goto.zig");
const run_mode = @import("../screens/reader/run.zig");
const places = @import("../screens/places.zig");
const run_view = @import("../screens/reader/run_view.zig");
const definition_ui = @import("../ui/definition.zig");
const keyboard = @import("../ui/keyboard.zig");

pub const Step = input_mod.Step;
pub const width = style.screen_width;
pub const height = style.screen_height;

/// Row `i` of a card of `rows`.
pub fn card_row(rows: u32, i: u32) Step {
    assert(rows > 0);
    assert(i < rows);
    return tap_on(card.place(rows, i));
}
/// A control, tapped in the middle of its taps (screens/places.zig).
pub fn tap_on(p: style.Point) Step {
    return tap(p.x, p.y);
}
/// A tool of the toolbar's top row.
pub fn tool(h: toolbar.Hit) Step {
    return tap_on(toolbar.place(h));
}
pub const highlight_button = tap_on(definition_ui.place(.highlight)); // On the definition sheet
pub const above_sheet = tap_on(card.place_above());
/// A tap on the Aa sheet's text size slider, on step `step`; the Font tab's open.
pub fn size_step(comptime step: u32) Step {
    return tap_on(aa.step_place(aa.size_row, step));
}
pub const largest_size = size_step(aa.size_row.steps - 1);

pub fn tap(x: i32, y: i32) Step {
    // A tap the script makes lands on the screen
    assert(x >= 0);
    assert(x < width);
    assert(y >= 0);
    assert(y < height);
    return .{ .act = .{ .tap = .{ .x = x, .y = y, .us = 0 } } };
}
pub fn hold(x: i32, y: i32) Step {
    // A hold the script makes lands on the screen
    assert(x >= 0);
    assert(x < width);
    assert(y >= 0);
    assert(y < height);
    return .{ .act = .{ .hold = .{ .x = x, .y = y } } };
}
/// The finger leaving the glass, as it does after a hold.
pub const lift: Step = .{ .act = .drag_end };
pub fn swipe(direction: i32) Step {
    assert(direction != 0); // Forward or back, never neither
    assert(direction >= -1);
    assert(direction <= 1);
    return .{ .act = .{ .swipe = .{ .direction = direction, .us = 0 } } };
}
pub fn wait(ms: u64) Step {
    assert(ms > 0);
    assert(ms <= 3_600_000); // A scenario spans minutes, not hours
    return .{ .wait_ms = ms };
}
pub const lock_it: Step = .{ .act = .lock };

/// Taps on the keyboard typing `word`: its letters' keys, and the space bar for a space.
pub fn typed(comptime word: []const u8) [word.len]Step {
    var steps: [word.len]Step = undefined;
    for (word, &steps) |char, *step| {
        const key: keyboard.Key = if (char == ' ') .space else .{ .char = char };
        step.* = tap_on(keyboard.place(key));
    }
    return steps;
}
pub const backspace = tap_on(keyboard.place(.backspace));
pub const wake: Step = .{ .act = .unlock };
/// The quick panel pulled down from the top, and its Kindle button, which leaves noface.
pub const pull_down: Step = .{ .act = .pull };
pub const panel_kindle = tap_on(menu_ui.place(.kindle));
/// Series… on a book's card, held in the library: its third row, after Remove and Mark
/// as read. Then the series lists' second row, "Not in a series", and "Library" along
/// their top.
pub const book_series = card_row(3, 2);
pub const not_in_a_series = tap_on(goto_ui.place(.{ .row = 1 }));
pub const list_back_to_library = tap_on(goto_ui.place(.close));
pub const forward = tap_on(places.page.forward);
pub const back = tap_on(places.page.back);
pub const top = tap_on(places.page.top);
pub const page_middle = tap_on(places.page.middle);
/// A tap on the page clear of a held word near its top and the handles of its
/// highlight, which lets the highlight go: the page's middle (checked by `word_held`).
pub const away_from_word = page_middle;
/// The middle column while running, which pauses and carries on.
pub const running_middle = tap_on(places.running_mode.middle);
/// Running mode on, from the page: the toolbar, its Aa sheet, the Themes tab, and the
/// Running button under its tiles. Then, while running, a tap in the pause band and the
/// pause card's rows.
pub const text_settings_button = tool(.text);
pub const themes_tab = tap_on(aa.place(.themes, .{ .tab = .themes }));
pub const running_button = tap_on(aa.place(.themes, .running));
pub const start_running = [_]Step{ top, text_settings_button, themes_tab, running_button };
pub const pause_tap = tap_on(places.running_mode.top);
/// The pause button, at the left of running's footer (screens/reader/run.zig).
pub const pause_button = tap_on(run_view.pause_place(height));
pub const pause_resume = card_row(3, 0);
pub const pause_stop = card_row(3, 2);

/// A finger moved, still down, to the middle of `word`.
pub fn drag_to(word: book_model.Word) Step {
    assert(word.w > 0);
    assert(word.h > 0);
    const x = word.x + @divTrunc(word.w, 2);
    const y = word.y + @divTrunc(word.h, 2);
    return .{ .act = .{ .drag = .{ .x = x, .y = y } } };
}

/// A tap in the middle of `r`.
pub fn tap_in(r: library_ui.Rect) Step {
    assert(r.w > 0);
    assert(r.h > 0);
    return tap(@intCast(r.x + r.w / 2), @intCast(r.y + r.h / 2));
}

/// A hold in the middle of `r`.
pub fn hold_in(r: library_ui.Rect) Step {
    assert(r.w > 0);
    assert(r.h > 0);
    return hold(@intCast(r.x + r.w / 2), @intCast(r.y + r.h / 2));
}

comptime {
    // A tap on the left third of a page goes back, the rest forward
    assert(back.act.tap.x < width / 3);
    assert(forward.act.tap.x >= width / 3);
    // `top` opens the toolbar; the middle of the page is outside it, and closes it
    assert(top.act.tap.y < toolbar.top_height);
    assert(page_middle.act.tap.y > toolbar.top_height);
    assert(page_middle.act.tap.y < toolbar.bottom_top);
    // A tap above a card of up to two rows closes it
    assert(above_sheet.act.tap.y < card.top(2));
    // The panel's Kindle button is where the scenarios tap it
    assert(menu_ui.hit(panel_kindle.act.tap.x, panel_kindle.act.tap.y) == .kindle);
    // The series lists' rows and their way back are where the scenarios tap them
    const none = not_in_a_series.act.tap;
    assert(goto_ui.hit(none.x, none.y, 0, 2).row == 1);
    const back_to_library = list_back_to_library.act.tap;
    assert(goto_ui.hit(back_to_library.x, back_to_library.y, 0, 2) == .close);
    // Aa's Themes tab, and the Running button on it
    const text = text_settings_button.act.tap;
    assert(toolbar.hit(text.x, text.y, null) == .text);
    const tab = themes_tab.act.tap;
    assert(std.meta.eql(aa.hit(.themes, .{}, tab.x, tab.y), aa.Hit{ .tab = .themes }));
    const run = running_button.act.tap;
    assert(aa.hit(.themes, .{}, run.x, run.y) == .running);
    // While running, taps in the top band pause, as `forward` and `back` turn
    assert(pause_tap.act.tap.y < run_mode.pause_band_px);
    assert(forward.act.tap.y >= run_mode.pause_band_px);
}
