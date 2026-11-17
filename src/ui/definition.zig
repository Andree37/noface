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
const actions_top = style.screen_height - 150;
const button_height = 84;
const button_width = 300;
const text_top = top + 170; // The first line under the word
/// The buttons' labels and the credit share one baseline.
const actions_baseline = actions_top + 4 + button_height / 2 + 12;

pub const Hit = enum { close, highlight, get_dictionary, none };

/// Where "Get dictionary" sits, beside Highlight, when there's none to show.
const get_left = style.margin + button_width + 32;
const get_width = 400;

comptime {
    // The text has room under the word, above the buttons.
    assert(top > style.status_height);
    assert(text_top + line_step < actions_top);
    // The two buttons' tap areas (each 10 px wider than drawn) don't overlap, and fit.
    assert(style.margin + button_width + 10 <= get_left - 10);
    assert(get_left + get_width + 10 <= style.screen_width);
    assert(actions_top + button_height + 20 <= style.screen_height);
    assert(button_height >= 84); // A fingertip
}

pub fn hit(x: i32, y: i32) Hit {
    if (y < top) return .close;
    const on_row = y >= actions_top and y < actions_top + button_height + 20;
    const on_highlight = x >= style.margin - 10 and x < style.margin + button_width + 10;
    const on_get = x >= get_left - 10 and x < get_left + get_width + 10;
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
        return w.y + line_step <= actions_top - 16;
    }

    /// A part of speech, small and gray, with a little space above.
    fn pos(w: *Writer, name: []const u8) !void {
        assert(!w.full);
        assert(name.len > 0); // A line of a tokenized entry
        w.y += 12;
        if (!w.room()) return w.stop();
        try w.fonts.caption.draw(w.page, style.margin, w.y, name);
        const width = w.page.width - 2 * style.margin;
        w.page.tint(style.margin, @intCast(w.y - 26), width, 34, style.faded);
        w.y += line_step - 4;
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
    try draw.clipped(fonts.hero, page, style.margin, top + 104, shown, avail);
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
                    w.y += 20;
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
    page.fill_rect(style.margin, actions_top - 12, page.width - 2 * style.margin, 1, style.rule);
    draw.box(page, style.margin, actions_top + 4, button_width, button_height);
    const highlight_x = style.margin + button_width / 2;
    try draw.centered(fonts.small, page, highlight_x, actions_baseline, "Highlight");
    if (gettable(found) != null) {
        draw.box(page, get_left, actions_top + 4, get_width, button_height);
        const get_x = get_left + get_width / 2;
        try draw.centered(fonts.small, page, get_x, actions_baseline, "Get dictionary");
    }
    const credit = "Wiktionary, CC BY-SA";
    const right: f32 = @floatFromInt(page.width - style.margin);
    const baseline = actions_baseline; // In line with "Highlight"
    try fonts.caption.draw(page, right - try fonts.caption.measure(credit), baseline, credit);
    page.tint(@intFromFloat(right - 360), baseline - 28, 360, 36, style.faded);
}

/// The dictionary the sheet offers to download, if it offers one.
pub fn gettable(found: Found) ?Gettable {
    return switch (found.looked_up) {
        .no_dictionary => |g| g,
        .not_found, .found => null,
    };
}

test "taps above close, the button highlights, the rest stays" {
    try std.testing.expectEqual(Hit.close, hit(600, top - 10));
    try std.testing.expectEqual(Hit.highlight, hit(style.margin + 50, actions_top + 50));
    try std.testing.expectEqual(Hit.none, hit(600, top + 300));
    try std.testing.expectEqual(Hit.get_dictionary, hit(get_left + 100, actions_top + 50));
    try std.testing.expect(button_height >= 84);
    try std.testing.expect(button_width >= 100);
}
