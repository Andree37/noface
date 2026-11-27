//! The reader's three-dots menu: go to a page, back to the start, book details,
//! a screen refresh, and marking the book finished or unread.
const std = @import("std");
const assert = std.debug.assert;
const line_of = @import("../../text/line.zig").of;
const card_screen = @import("../card.zig");
const card = @import("../../ui/card.zig");
const catalog = @import("../../model/catalog.zig");
const stats = @import("../../model/stats.zig");
const app = @import("../../app.zig");
const display = @import("../../display.zig");
const book_actions = @import("../book_actions.zig");
const page_number = @import("page_number.zig");
const sess = @import("session.zig");
const highlights_model = @import("../../model/highlights.zig");
const screen = @import("../screen.zig");
const style = @import("../../ui/style.zig");

/// What the reader does after the menu.
pub const Outcome = union(enum) {
    stay, // Back to the toolbar
    page: u32, // Show this page
    refresh, // Show the current page with a full, clean refresh
    not_marked, // Marking it read or unread didn't land: said, then back to the toolbar
    started_over, // Marked unread: its first page, nothing behind it to go back to
};

pub const Option = enum { go_to_page, beginning, details, refresh, finished, unread, cancel };

/// The longest label, so each fits its row on one line.
const label_bytes_max = 32;

fn label(option: Option) []const u8 {
    const text = switch (option) {
        .go_to_page => "Go to page\u{2026}",
        .beginning => "Go to beginning",
        .details => "Book details",
        .refresh => "Refresh screen",
        .finished => "Mark as finished",
        .unread => "Mark as unread",
        .cancel => "Cancel",
    };
    assert(text.len > 0);
    assert(text.len <= label_bytes_max);
    return text;
}

/// The menu's rows, top to bottom: the last marks the book finished, or unread once it is.
const menu_rows = 5;

/// The middle of an option's row on the menu's card, for a script to tap: finishing
/// and marking unread share the last.
pub fn place(option: Option) style.Point {
    const row: u32 = switch (option) {
        .go_to_page => 0,
        .beginning => 1,
        .details => 2,
        .refresh => 3,
        .finished, .unread => menu_rows - 1,
        .cancel => unreachable, // Not on the menu: tapping above the card closes it
    };
    return card.place(menu_rows, row);
}

/// Starts the menu in `m`, where it stays while it's open (`screen.open`): its card
/// over the page, then Go to page's keyboard or the book's details. Done with what the
/// reader does after it.
pub fn begin(
    m: *More,
    a: *app.App,
    s: *sess.Session,
    entry: *const catalog.Entry,
    progress: *catalog.Progress,
) !void {
    assert(s.pages.len > 0);
    assert(s.current < s.pages.len);
    m.* = .{
        .a = a,
        .s = s,
        .entry = entry,
        .progress = progress,
        .background = try s.lend_current(),
    };
    // No Cancel: tapping above the sheet closes it
    const read_option: Option = if (progress.is_read()) .unread else .finished;
    m.list = .{ .go_to_page, .beginning, .details, .refresh, read_option };
    // Where `place` says each option is
    for (m.list, 0..) |option, row| {
        assert(place(option).y == card.place(menu_rows, @intCast(row)).y);
    }
    for (m.list, &m.rows) |option, *row| row.* = .{ .label = label(option) };
    assert(m.phase == .menu);
}

pub const More = struct {
    pub const Result = Outcome;
    a: *app.App,
    s: *sess.Session,
    entry: *const catalog.Entry,
    progress: *catalog.Progress, // The open book's, which marking it changes
    background: display.Backdrop, // The page under it
    phase: enum { menu, page_number, details } = .menu,
    list: [menu_rows]Option = undefined,
    rows: [menu_rows]card.Row = undefined,
    card: card_screen.Card = undefined,
    card_ending: ?screen.Ending(u32) = null,
    page_entry: page_number.PageEntry = undefined,
    page_ending: ?screen.Ending(u32) = null,
    /// The details' lines.
    progress_buffer: [64]u8 = undefined,
    read_buffer: [64]u8 = undefined,
    left_buffer: [64]u8 = undefined,
    counts_buffer: [96]u8 = undefined,
    details_rows: [4]card.Row = undefined,

    /// Never shown itself: its card is.
    pub fn draw(m: *More, part: screen.Part) !void {
        assert(part == .all);
        assert(m.phase == .menu);
    }

    pub fn on_tap(m: *More, _: screen.Tap) !screen.Step(Outcome) {
        assert(m.phase == .menu);
        unreachable; // Never in front: its card or the keyboard always is
    }

    pub fn on_open(m: *More) !screen.Step(Outcome) {
        assert(m.phase == .menu);
        return m.show_card(&m.rows, m.entry.title, m.entry.author);
    }

    fn show_card(
        m: *More,
        rows: []const card.Row,
        title: []const u8,
        subtitle: []const u8,
    ) screen.Step(Outcome) {
        assert(rows.len > 0);
        assert(m.phase != .page_number);
        m.card = card_screen.over(m.a, m.background, title, subtitle, rows, null);
        return .{ .push = screen.open(&m.card, &m.card_ending) };
    }

    pub fn on_resume(m: *More) !screen.Step(Outcome) {
        switch (m.phase) {
            .menu => {
                const picked = switch (m.card_ending.?) {
                    .done => |picked| picked,
                    .closed, .interrupted => {
                        // The reader draws the toolbar and its page whole next
                        card_screen.closed_quietly(m.a, m.background);
                        return .{ .done = .stay };
                    },
                };
                assert(picked < m.list.len);
                const option = m.list[picked];
                // Go to page opens its keys over part of the screen: the rest shown first.
                // Every other choice ends in the reader drawing the screen whole, or in a
                // card drawn whole over the same page
                if (option == .go_to_page) {
                    try card_screen.closed(m.a, m.background);
                } else {
                    card_screen.closed_quietly(m.a, m.background);
                }
                return m.chosen(option);
            },
            .page_number => {
                const index = switch (m.page_ending.?) {
                    .done => |index| index,
                    .closed, .interrupted => return .{ .done = .stay },
                };
                assert(index < m.s.pages.len);
                return .{ .done = .{ .page = index } };
            },
            .details => {
                // The reader draws the toolbar and its page whole next
                card_screen.closed_quietly(m.a, m.background);
                return .{ .done = .stay };
            },
        }
    }

    fn chosen(m: *More, option: Option) screen.Step(Outcome) {
        assert(m.phase == .menu);
        switch (option) {
            .cancel => return .{ .done = .stay },
            .go_to_page => {
                m.phase = .page_number;
                m.page_entry = page_number.make(m.a, m.s);
                return .{ .push = screen.open(&m.page_entry, &m.page_ending) };
            },
            .beginning => return .{ .done = .{ .page = 0 } },
            .refresh => return .{ .done = .refresh },
            .details => {
                m.phase = .details;
                m.details();
                return m.show_card(&m.details_rows, m.entry.title, m.entry.author);
            },
            .finished => {
                const open: book_actions.Place = .{ .open = m.s };
                const marked = book_actions.mark_read(m.a, m.entry, m.progress, true, open);
                return .{ .done = if (marked) .stay else .not_marked };
            },
            // Unread starts again from the beginning, so the place saved on closing
            // isn't the last page, which would count it read again
            .unread => {
                const open: book_actions.Place = .{ .open = m.s };
                const marked = book_actions.mark_read(m.a, m.entry, m.progress, false, open);
                return .{ .done = if (marked) .started_over else .not_marked };
            },
        }
    }

    /// A sheet of facts about the book. Any tap closes it.
    fn details(m: *More) void {
        const s = m.s;
        assert(s.pages.len > 0);
        assert(s.current < s.pages.len);
        // Opened over the whole book laid out (`needs_all_pages`), so the pages say
        const percent = s.percent().?;
        assert(percent <= 100);
        const progress = line_of(
            &m.progress_buffer,
            "Page {d} of {d}, {d}%",
            .{ s.current + 1, s.pages.len, percent },
        );
        var time_read_buffer: stats.Minutes = undefined;
        var read: []const u8 = "Not read here yet";
        if (stats.reading_time(&time_read_buffer, s.seconds_read_total())) |time| {
            read = line_of(&m.read_buffer, "Read here for {s}", .{time});
        }
        var time_left_buffer: stats.Minutes = undefined;
        var left: []const u8 = "Learning your reading speed";
        if (s.time_left(s.current).book) |minutes| {
            const time = stats.format_minutes(&time_left_buffer, minutes);
            left = line_of(&m.left_buffer, "{s} left in the book", .{time});
        }
        const highlights = highlights_model.count(s.notes.highlights.items);
        const counts = line_of(
            &m.counts_buffer,
            "{d} chapters, {d} highlights, {d} bookmarks",
            .{ s.chapters.len, highlights, s.notes.bookmarks.items.len },
        );
        m.details_rows = .{
            .{ .quiet = true, .label = progress },
            .{ .quiet = true, .label = read },
            .{ .quiet = true, .label = left },
            .{ .quiet = true, .label = counts },
        };
    }
};
