//! The sheet that rises when a word is held: what the dictionary says about it, and a
//! button to highlight it instead. Tapping above the sheet closes it.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const hyphen = @import("../layout/hyphen.zig");
const dictionary = @import("../model/dictionary.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const height = 860;
pub const top = style.screen_height - height;
const number_width = 44; // Room for "1" before a sense, so its lines hang together
const line_step = 46;
/// The word's baseline, and the first line's under it, down from the sheet's top.
const word_drop = 104;
const text_drop = 170;
const text_top = top + text_drop;
/// The text stops this far over the buttons' row's rule.
const text_clear = 16;
/// A part of speech: the gap over it, its gray band's rise over its baseline and its
/// height, and how much closer the next line follows it.
const pos_gap = 12;
const pos_tint_rise = 26;
const pos_tint_height = 34;
const pos_tighter = 4;
/// The gap over the entry for the word a held word is a form of.
const base_gap = 20;

/// The buttons' row along the sheet's foot: a rule over it, the buttons drawn a little
/// under its top and taking taps a little round what's drawn.
const actions_band = 150;
const actions_top = style.screen_height - actions_band;
const actions_rule_rise = 12;
const button_height = 84;
const button_width = 300;
const button_drop = 4;
const button_reach = 10;
const row_taps_height = button_height + 2 * button_reach;
/// The buttons' labels and the credit share one baseline, a little under the buttons'
/// middle.
const label_drop = 12;
const actions_baseline = actions_top + button_drop + button_height / 2 + label_drop;
/// The credit's gray band: its width in from the right margin, its rise and height.
const credit_tint_width = 360;
const credit_tint_rise = 28;
const credit_tint_height = 36;

pub const Hit = enum { close, highlight, get_dictionary, none };

/// Where "Get dictionary" sits, beside Highlight, when there's none to show.
const get_gap = 32;
const get_left = style.margin + button_width + get_gap;
const get_width = 400;

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

pub fn hit(x: i32, y: i32) Hit {
    if (y < top) return .close;
    const reach = button_reach;
    const on_row = y >= actions_top and y < actions_top + row_taps_height;
    const on_highlight = x >= style.margin - reach and x < style.margin + button_width + reach;
    const on_get = x >= get_left - reach and x < get_left + get_width + reach;
    if (on_row and on_highlight) return .highlight;
    if (on_row and on_get) return .get_dictionary;
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
        const tint_top: u32 = @intCast(w.y - pos_tint_rise);
        w.page.tint(style.margin, tint_top, width, pos_tint_height, style.faded);
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
            const line = std.fmt.bufPrint(&buffer, missing, .{g.name}) catch "";
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
    page.fill_rect(style.margin, rule_y, page.width - 2 * style.margin, 1, style.rule);
    const button_top = actions_top + button_drop;
    draw.box(page, style.margin, button_top, button_width, button_height);
    const highlight_x = style.margin + button_width / 2;
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
    const tint_top = baseline - credit_tint_rise;
    page.tint(tint_left, tint_top, credit_tint_width, credit_tint_height, style.faded);
}

/// The dictionary the sheet offers to download, if it offers one.
pub fn gettable(found: Found) ?Gettable {
    return switch (found.looked_up) {
        .no_dictionary => |g| g,
        .not_found, .found => null,
    };
}

test "taps above close, the button highlights, the rest stays" {
    const x = style.screen_width / 2;
    const row_y = actions_top + row_taps_height / 2;
    try std.testing.expectEqual(Hit.close, hit(x, top - 1));
    const highlight_x = style.margin + button_width / 2;
    try std.testing.expectEqual(Hit.highlight, hit(highlight_x, row_y));
    try std.testing.expectEqual(Hit.none, hit(x, text_top));
    try std.testing.expectEqual(Hit.get_dictionary, hit(get_left + get_width / 2, row_y));
    // Between the two buttons' taps
    const between = get_left - button_reach - 1;
    try std.testing.expectEqual(Hit.none, hit(between, row_y));
}
