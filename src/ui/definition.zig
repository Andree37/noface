//! The sheet that rises when a word is held: what the dictionary says about it, and a
//! button to highlight it instead. Tapping above the sheet closes it.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../text/line.zig").of;
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const hyphen = @import("../layout/hyphen.zig");
const dictionary = @import("../model/dictionary.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const height = style.screen_height / 2;
pub const top = style.screen_height - height;
const number_width = style.space.wide; // Room for "1" before a sense, so its lines hang together
const line_step = style.space.wide;
/// The word's baseline, and the first line's under it, down from the sheet's top.
const word_drop = style.space.band;
const text_drop = style.space.roomy + style.space.tall;
const text_top = top + text_drop;
/// The text stops where its next line's baseline would come within this of the buttons'
/// row's top (under its rule).
const text_clear = style.space.snug;
/// A part of speech, faded: the gap over it, and how much closer the next line follows it.
const pos_gap = style.space.small;
const pos_tighter = style.space.hair;
/// The gap over the entry for the word a held word is a form of.
const base_gap = style.space.snug;

/// The buttons' row along the sheet's foot: a rule over it, the buttons drawn a little
/// under its top and taking taps a little round what's drawn.
const actions_band = style.space.tall;
const actions_top = style.screen_height - actions_band;
const actions_rule_rise = style.space.small;
const button_height = style.space.snug + style.space.wider;
const button_width = style.button_width;
const button_drop = style.space.hair;
const button_reach = style.space.tiny;
const row_taps_height = button_height + 2 * button_reach;
/// The credit, faded: as far in from the right margin as it fades.
const credit_tint_width = style.button_width + style.space.wide;

pub const Hit = enum { close, highlight, get_dictionary, none };

/// Where "Get dictionary" sits, beside Highlight, when there's none to show.
const get_gap = style.space.roomy;
const get_left = style.margin + button_width + get_gap;
const get_width = style.button_width + style.space.band;

comptime {
    // The text has room under the word, above the buttons.
    assert(top > style.status_height);
    assert(text_top + line_step < actions_top);
    // The two buttons' tap areas (each wider than drawn) don't overlap, and fit.
    assert(style.margin + button_width + button_reach <= get_left - button_reach);
    assert(get_left + get_width + button_reach <= style.screen_width);
    assert(actions_top + row_taps_height <= style.screen_height);
    assert(row_taps_height >= style.fingertip);
    assert(button_width >= style.fingertip);
}

/// The middle of a button's taps, on the row along the sheet's foot.
pub fn place(h: Hit) style.Point {
    const y = actions_top + row_taps_height / 2;
    const point: style.Point = switch (h) {
        .highlight => .{ .x = style.margin + button_width / 2, .y = y },
        .get_dictionary => .{ .x = get_left + get_width / 2, .y = y },
        .close => .{ .x = style.screen_width / 2, .y = top / 2 },
        .none => unreachable, // Not a control
    };
    assert(hit_buttons(true, point.x, point.y) == h); // On a sheet that offers both
    return point;
}

test "every button's place is a tap on it" {
    for ([_]Hit{ .highlight, .get_dictionary, .close }) |h| {
        const p = place(h);
        try std.testing.expectEqual(h, hit_buttons(true, p.x, p.y));
    }
}

/// What a tap on the sheet showing `found` is on: "Get dictionary" only where it's drawn.
pub fn hit(found: Found, x: i32, y: i32) Hit {
    return hit_buttons(gettable(found) != null, x, y);
}

fn hit_buttons(offers_dictionary: bool, x: i32, y: i32) Hit {
    if (y < top) return .close;
    const reach = button_reach;
    const on_row = y >= actions_top and y < actions_top + row_taps_height;
    const on_highlight = x >= style.margin - reach and x < style.margin + button_width + reach;
    const on_get = x >= get_left - reach and x < get_left + get_width + reach;
    if (on_row and on_highlight) return .highlight;
    if (on_row and on_get and offers_dictionary) return .get_dictionary;
    return .none;
}

/// What to show for a word held in the book.
pub const Found = struct {
    word: []const u8, // As held in the book, trimmed
    looked_up: Lookup,
};

/// What the dictionary said: there's none for the book's language on the Kindle (with
/// the one that could be downloaded, if any), it hasn't the word, or its entry, with
/// the entry for the word it's a form of.
pub const Lookup = union(enum) {
    no_dictionary: ?Gettable,
    not_found,
    found: struct { entry: dictionary.Entry, base: ?dictionary.Entry },
};

/// A dictionary that can be downloaded: for the book's language, named like "English".
pub const Gettable = struct { lang: hyphen.Lang, name: []const u8 };

/// Writes a dictionary entry's lines down the sheet until it's full.
const Writer = struct {
    fonts: Fonts,
    page: Page,
    y: i32,
    full: bool = false,

    fn room(w: *const Writer) bool {
        assert(w.y >= text_top);
        assert(w.y <= actions_top + line_step); // It stops at the first line that won't fit
        return w.y + line_step <= actions_top - text_clear;
    }

    /// A part of speech, small and gray, with a little space above.
    fn pos(w: *Writer, name: []const u8) !void {
        assert(!w.full);
        assert(name.len > 0); // A line of a tokenized entry
        w.y += pos_gap;
        if (!w.room()) return w.stop();
        try w.fonts.caption.draw(w.page, style.margin, w.y, name);
        const width = w.page.width - 2 * style.margin;
        w.fonts.caption.fade(w.page, style.margin, w.y, width, style.faded);
        w.y += line_step - pos_tighter;
    }

    /// A numbered sense, wrapped, its lines lined up after the number.
    fn sense(w: *Writer, number: []const u8, text: []const u8) !void {
        assert(!w.full);
        assert(number.len > 0); // A sense's line starts with a digit
        const left: f32 = style.margin + number_width;
        const avail: f32 = @as(f32, @floatFromInt(w.page.width - style.margin)) - left;
        var rest = text;
        var first = true;
        while (rest.len > 0) {
            if (!w.room()) return w.stop();
            if (first) try w.fonts.small.draw(w.page, style.margin, w.y, number);
            const n = try draw.line_end(w.fonts.small, rest, avail);
            try w.fonts.small.draw(w.page, left, w.y, rest[0..n]);
            rest = std.mem.trimStart(u8, rest[n..], " ");
            w.y += line_step;
            first = false;
        }
    }

    fn stop(w: *Writer) void {
        assert(!w.full);
        assert(!w.room());
        w.full = true;
    }

    /// An entry's lines, until the sheet is full.
    fn entry(w: *Writer, e: dictionary.Entry) !void {
        assert(!w.full);
        assert(w.y >= text_top);
        var lines = std.mem.tokenizeScalar(u8, e.text, '\n');
        while (lines.next()) |l| {
            if (w.full) return;
            if (l[0] == '=') continue; // "Form of" link, shown as the next entry
            if (std.ascii.isDigit(l[0])) {
                const space = std.mem.indexOfScalar(u8, l, ' ') orelse l.len;
                try w.sense(l[0..space], if (space < l.len) l[space + 1 ..] else "");
            } else {
                try w.pos(l);
            }
        }
        if (w.full) assert(!w.room());
    }
};

/// Draws the sheet over `page`, which holds the book page; that gets dimmed.
pub fn render(fonts: Fonts, page: Page, found: Found) !void {
    assert(page.height > top);
    assert(page.width > 2 * style.margin);
    page.dim(0, 0, page.width, top);
    draw.sheet(page, top);
    const avail: f32 = @floatFromInt(page.width - 2 * style.margin);

    const shown = switch (found.looked_up) {
        .found => |f| f.entry.word,
        .no_dictionary, .not_found => found.word,
    };
    try draw.clipped(fonts.hero, page, style.margin, top + word_drop, shown, avail);
    var w = Writer{ .fonts = fonts, .page = page, .y = text_top };
    switch (found.looked_up) {
        .no_dictionary => |to_get| if (to_get) |g| {
            var buffer: [96]u8 = undefined;
            const missing = "The {s} dictionary isn't on this Kindle yet.";
            const line = line_of(&buffer, missing, .{g.name});
            try fonts.small.draw(page, style.margin, w.y, line);
        } else {
            const none = "No dictionary for this book's language.";
            try fonts.small.draw(page, style.margin, w.y, none);
        },
        .found => |f| {
            try w.entry(f.entry);
            if (f.base) |b| {
                if (!w.full and w.room()) {
                    w.y += base_gap;
                    try fonts.title.draw(page, style.margin, w.y, b.word);
                    w.y += line_step;
                    try w.entry(b);
                }
            }
        },
        .not_found => {
            try fonts.small.draw(page, style.margin, w.y, "This word isn't in the dictionary.");
        },
    }

    // Actions along the bottom: Highlight, and where the words come from
    const rule_y = actions_top - actions_rule_rise;
    draw.rule(page, rule_y);
    const button_top = actions_top + button_drop;
    draw.box(page, style.margin, button_top, button_width, button_height);
    const highlight_x = style.margin + button_width / 2;
    // The buttons' labels centred in them, and the credit on their line
    const actions_baseline = fonts.small.centred_baseline(button_top, button_height);
    try draw.centered(fonts.small, page, highlight_x, actions_baseline, "Highlight");
    if (gettable(found) != null) {
        draw.box(page, get_left, button_top, get_width, button_height);
        const get_x = get_left + get_width / 2;
        try draw.centered(fonts.small, page, get_x, actions_baseline, "Get dictionary");
    }
    const credit = "Wiktionary, CC BY-SA";
    const right: f32 = @floatFromInt(page.width - style.margin);
    const baseline = actions_baseline; // In line with "Highlight"
    try fonts.caption.draw(page, right - try fonts.caption.measure(credit), baseline, credit);
    const tint_left: u32 = @intFromFloat(right - credit_tint_width);
    fonts.caption.fade(page, tint_left, baseline, credit_tint_width, style.faded);
}

/// The dictionary the sheet offers to download, if it offers one.
pub fn gettable(found: Found) ?Gettable {
    return switch (found.looked_up) {
        .no_dictionary => |g| g,
        .not_found, .found => null,
    };
}

test "taps above close, the button highlights, the rest stays" {
    const offering: Found = .{
        .word = "word",
        .looked_up = .{ .no_dictionary = .{ .lang = .english, .name = "English" } },
    };
    const x = style.screen_width / 2;
    const row_y = actions_top + row_taps_height / 2;
    try std.testing.expectEqual(Hit.close, hit(offering, x, top - 1));
    const highlight_x = style.margin + button_width / 2;
    try std.testing.expectEqual(Hit.highlight, hit(offering, highlight_x, row_y));
    try std.testing.expectEqual(Hit.none, hit(offering, x, text_top));
    const get_x = get_left + get_width / 2;
    try std.testing.expectEqual(Hit.get_dictionary, hit(offering, get_x, row_y));
    // Between the two buttons' taps
    const between = get_left - button_reach - 1;
    try std.testing.expectEqual(Hit.none, hit(offering, between, row_y));
    // Where no "Get dictionary" is drawn, its place is no button
    const not_offering: Found = .{ .word = "word", .looked_up = .not_found };
    try std.testing.expectEqual(Hit.none, hit(not_offering, get_x, row_y));
    const none_to_get: Found = .{ .word = "word", .looked_up = .{ .no_dictionary = null } };
    try std.testing.expectEqual(Hit.none, hit(none_to_get, get_x, row_y));
    try std.testing.expectEqual(Hit.highlight, hit(not_offering, highlight_x, row_y));
}
