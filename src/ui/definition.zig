//! The sheet that rises when a word is held: what the dictionary says about it, and a
//! button to highlight it instead. Tapping above the sheet closes it.
const std = @import("std");
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const draw = @import("draw.zig");
const style = @import("style.zig");
const dictionary = @import("../model/dictionary.zig");
const Fonts = @import("fonts.zig").Fonts;

pub const height = 860;
pub const top = style.screen_height - height;
const number_width = 44; // Room for "1" before a sense, so its lines hang together
const line_step = 46;
const actions_top = style.screen_height - 150;
const button_height = 84;
const button_width = 300;

pub const Hit = enum { close, highlight, get_dictionary, none };

/// Where "Get dictionary" sits, beside Highlight, when there's none to show.
const get_left = style.margin + button_width + 32;
const get_width = 400;

pub fn hit(x: i32, y: i32) Hit {
    if (y < top) return .close;
    const on_row = y >= actions_top and y < actions_top + button_height + 20;
    if (on_row and x >= style.margin - 10 and x < style.margin + button_width + 10) return .highlight;
    if (on_row and x >= get_left - 10 and x < get_left + get_width + 10) return .get_dictionary;
    return .none;
}

/// What to show: the entry found (if any), and the entry for the word it's a form of.
pub const Found = struct {
    word: []const u8, // As held in the book, trimmed
    entry: ?dictionary.Entry = null,
    base: ?dictionary.Entry = null,
    no_dictionary: bool = false,
    /// With no dictionary: the one that could be downloaded, like "English".
    can_get: ?[]const u8 = null,
};

/// Bytes of `s` that fit in `avail`, ending at a space when it can.
const Writer = struct {
    fonts: Fonts,
    page: Page,
    y: i32,
    full: bool = false,

    fn room(w: *const Writer) bool {
        return w.y + line_step <= actions_top - 16;
    }

    /// A part of speech, small and gray, with a little space above.
    fn pos(w: *Writer, name: []const u8) !void {
        w.y += 12;
        if (!w.room()) return w.stop();
        try w.fonts.caption.draw(w.page, style.margin, w.y, name);
        w.page.tint(style.margin, @intCast(w.y - 26), w.page.width - 2 * style.margin, 34, style.faded);
        w.y += line_step - 4;
    }

    /// A numbered sense, wrapped, its lines lined up after the number.
    fn sense(w: *Writer, number: []const u8, text: []const u8) !void {
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
        w.full = true;
    }

    /// An entry's lines, until the sheet is full.
    fn entry(w: *Writer, e: dictionary.Entry) !void {
        var lines = std.mem.tokenizeScalar(u8, e.text, '\n');
        while (lines.next()) |l| {
            if (w.full) return;
            if (l[0] == '=') continue; // "Form of" link, shown as the next entry
            if (std.ascii.isDigit(l[0])) {
                const space = std.mem.indexOfScalar(u8, l, ' ') orelse l.len;
                try w.sense(l[0..space], if (space < l.len) l[space + 1 ..] else "");
            } else try w.pos(l);
        }
    }
};

/// Draws the sheet over `page`, which holds the book page; that gets dimmed.
pub fn render(fonts: Fonts, page: Page, found: Found) !void {
    page.dim(0, 0, page.width, top);
    draw.sheet(page, top);
    const avail: f32 = @floatFromInt(page.width - 2 * style.margin);

    const shown = if (found.entry) |e| e.word else found.word;
    try draw.clipped(fonts.hero, page, style.margin, top + 104, shown, avail);
    var w = Writer{ .fonts = fonts, .page = page, .y = top + 170 };
    if (found.no_dictionary) {
        if (found.can_get) |name| {
            var buf: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "The {s} dictionary isn't on this Kindle yet.", .{name}) catch "";
            try fonts.small.draw(page, style.margin, w.y, line);
        } else try fonts.small.draw(page, style.margin, w.y, "No dictionary for this book's language.");
    } else if (found.entry) |e| {
        try w.entry(e);
        if (found.base) |b| {
            if (!w.full and w.room()) {
                w.y += 20;
                try fonts.title.draw(page, style.margin, w.y, b.word);
                w.y += line_step;
                try w.entry(b);
            }
        }
    } else {
        try fonts.small.draw(page, style.margin, w.y, "This word isn't in the dictionary.");
    }

    // Actions along the bottom: Highlight, and where the words come from
    page.fill_rect(style.margin, actions_top - 12, page.width - 2 * style.margin, 1, style.rule);
    draw.box(page, style.margin, actions_top + 4, button_width, button_height);
    try draw.centered(fonts.small, page, style.margin + button_width / 2, actions_top + 4 + button_height / 2 + 12, "Highlight");
    if (found.no_dictionary and found.can_get != null) {
        draw.box(page, get_left, actions_top + 4, get_width, button_height);
        try draw.centered(fonts.small, page, get_left + get_width / 2, actions_top + 4 + button_height / 2 + 12, "Get dictionary");
    }
    const credit = "Wiktionary, CC BY-SA";
    const right: f32 = @floatFromInt(page.width - style.margin);
    const baseline = actions_top + 4 + button_height / 2 + 12; // In line with "Highlight"
    try fonts.caption.draw(page, right - try fonts.caption.measure(credit), baseline, credit);
    page.tint(@intFromFloat(right - 360), baseline - 28, 360, 36, style.faded);
}

test "taps above close, the button highlights, the rest stays" {
    try std.testing.expectEqual(Hit.close, hit(600, top - 10));
    try std.testing.expectEqual(Hit.highlight, hit(style.margin + 50, actions_top + 50));
    try std.testing.expectEqual(Hit.none, hit(600, top + 300));
    try std.testing.expectEqual(Hit.get_dictionary, hit(get_left + 100, actions_top + 50));
    try std.testing.expect(button_height >= 84 and button_width >= 100);
}
