//! What can be done to a book from the library: its sheet of actions (download,
//! remove, mark read), and the card offering the next of a series.
const std = @import("std");
const assert = std.debug.assert;
const card_screen = @import("card.zig");
const card = @import("../ui/card.zig");
const catalog = @import("../model/catalog.zig");
const book_actions = @import("../ui/book_actions.zig");
const state = @import("../sys/state.zig");
const file = @import("../sys/file.zig");
const store = @import("../kindle/store.zig");
const app = @import("../app.zig");
const display = @import("../display.zig");
const series_screen = @import("series.zig");
const books = @import("books.zig");
const cover_image = @import("../gfx/image.zig");
const style = @import("../ui/style.zig");
const screen = @import("screen.zig");
const input_mod = @import("../kindle/input.zig");

/// The rounds a book's sheet can take: its actions, then, for a removal, the question
/// whether to remove it.
const sheet_rounds_max = 2;

comptime {
    // The card's small cover is half the grid's, so it's never empty
    assert(style.cover.width / 2 > 0);
    assert(style.cover.height / 2 > 0);
}

/// Marks a book read or unread, from its sheet here or the reader's menu. The Kindle
/// keeps this for its own books; an EPUB's is kept with its place. Marked unread, it
/// starts again from the beginning: a book at its last page is read, marked or not.
/// Whether it was marked: an EPUB whose place can't be saved isn't, and then nothing
/// changes, its journal neither.
pub fn mark_read(a: *app.App, e: *catalog.Entry, done: bool) bool {
    const counted = e.finished; // The journal counts a book while it's marked finished
    if (e.is_epub() or (!done and e.is_local())) {
        save_marked(a, e, done) catch |err| {
            std.debug.print("mark not saved with its place: {s}\n", .{@errorName(err)});
            // An EPUB's mark is kept with its place alone; a Kindle book's, by the
            // Kindle, stands without its place started again
            if (e.is_epub()) return false;
        };
    }
    store.mark_read(e.key, e.kind, done);
    e.finished = done;
    if (!done) {
        e.percent = 0;
        e.words_left = null; // Counted from the old place: known again once read
    }
    assert(e.is_read() == done);
    assert(e.percent <= 100);
    if (done != counted) {
        if (done) a.user.journal.finish(a.today()) else a.user.journal.unfinish(a.today());
        a.user.save_journal();
    }
    std.debug.print("marked {s}\n", .{if (done) "read" else "unread"});
    return true;
}

/// What the library and the reader say when `mark_read` didn't mark a book.
pub const not_marked_notice = "Couldn't mark it: its place couldn't be saved.";

/// Saves whether the book is finished with its place, in one write. Unread, the place
/// is its beginning, dated just after the last time it was opened anywhere: newer than
/// stock's place and percent, so ours win, without moving it up in recent order.
fn save_marked(a: *app.App, e: *const catalog.Entry, done: bool) !void {
    assert(e.is_epub() or e.is_local()); // A file of its own to keep its place by
    var path_buffer: [file.own_path_bytes_max]u8 = undefined;
    var kept = file.Kept.at(try a.state_path(&path_buffer, e.path));
    var saved = state.load(&kept);
    saved.finished = done;
    if (!done) {
        saved.para = 0;
        saved.byte = 0;
        saved.percent = 0;
        saved.words_left = null;
        saved.back_para = null; // Nowhere to go back to from a fresh start
        // Saturating: both times come from files, and a broken one mustn't stop this
        saved.opened = @max(saved.opened, e.kindle_last) +| 1;
        assert(!state.prefer_kindle(saved, e.kindle_last));
    }
    if (!state.save(&kept, saved)) return error.PlaceNotSaved;
}

/// What a book's actions changed, which decides what the library does next: `reload`
/// re-reads the library (a series set by hand), `redraw` only repaints it (a screen of
/// its own was shown and nothing changed), `not_marked` says a mark didn't land.
pub const Change = enum { none, downloading, other, reload, redraw, not_marked };

/// Starts a book's actions in `s`, where they stay while open (`screen.open`): a card
/// of them over `background`, then for a removal the question whether to remove it,
/// or the series lists. Ends with what they changed.
pub fn begin_sheet(
    s: *Sheet,
    a: *app.App,
    e: *catalog.Entry,
    lib: *books.Library,
    background: display.Backdrop,
) void {
    assert(background.holds(&a.display));
    s.* = .{ .a = a, .e = e, .lib = lib, .background = background };
    assert(s.round == 0);
    assert(s.phase == .card);
}

pub const Sheet = struct {
    pub const Result = Change;
    /// Taken by the series lists and keyboard it opens, so a row or key pressed a little
    /// long acts as it lands, never as a hold the library's touches would make of it.
    pub const touches = input_mod.Input.Modes.sheet;
    a: *app.App,
    e: *catalog.Entry,
    lib: *books.Library,
    background: display.Backdrop,
    round: u32 = 0, // Its actions, then for a removal the question
    phase: enum { card, series } = .card,
    list_buffer: [4]book_actions.Option = undefined,
    row_buffer: [4]card.Row = undefined,
    subtitle_buffer: [file.own_path_bytes_max]u8 = undefined,
    list: []const book_actions.Option = &.{},
    card: card_screen.Card = undefined,
    card_ending: ?screen.Ending(u32) = null,
    series: series_screen.Series = undefined,
    series_ending: ?screen.Ending(bool) = null,

    /// Never shown itself: its card is.
    pub fn draw(s: *Sheet, part: screen.Part) !void {
        assert(part == .all);
        assert(s.round == 0);
    }

    pub fn on_tap(s: *Sheet, _: screen.Tap) !screen.Step(Change) {
        assert(s.round < sheet_rounds_max);
        unreachable; // Never in front: its card or the series lists always are
    }

    pub fn on_open(s: *Sheet) !screen.Step(Change) {
        std.debug.print("sheet: {s}\n", .{s.e.title});
        assert(s.round == 0);
        return s.show_round();
    }

    /// The card for this round: the book's actions, or the question.
    fn show_round(s: *Sheet) screen.Step(Change) {
        assert(s.round < sheet_rounds_max);
        const confirming = s.round == 1;
        const e = s.e;
        s.list = book_actions.options(e, confirming, &s.list_buffer);
        assert(s.list.len <= s.list_buffer.len);
        // A book being downloaded has nothing to pick: its card says so, and a tap
        // above it closes it
        const subtitle = book_actions.subtitle(&s.subtitle_buffer, e, confirming);
        const rows = book_actions.rows(s.list, &s.row_buffer);
        s.card = card_screen.over(s.a, s.background, e.title, subtitle, rows, null);
        s.phase = .card;
        return .{ .push = screen.open(&s.card, &s.card_ending) };
    }

    pub fn on_resume(s: *Sheet) !screen.Step(Change) {
        assert(s.background.holds(&s.a.display)); // What its cards sit over
        switch (s.phase) {
            .card => {
                const picked = switch (s.card_ending.?) {
                    .done => |picked| picked,
                    .closed, .interrupted => {
                        try card_screen.closed(s.a, s.background);
                        return .{ .done = .none };
                    },
                };
                assert(picked < s.list.len);
                const option = s.list[picked];
                // Shown again only when nothing else is drawn after: every other choice
                // opens a card or a screen, or has the library drawn afresh
                if (option == .cancel) {
                    try card_screen.closed(s.a, s.background);
                } else {
                    card_screen.closed_quietly(s.a, s.background);
                }
                return s.act(option);
            },
            .series => {
                s.a.regions.library_scratch_budget.reset(.give_back);
                const changed = switch (s.series_ending.?) {
                    .done => |changed| changed,
                    .closed, .interrupted => false,
                };
                return .{ .done = if (changed) .reload else .redraw };
            },
        }
    }

    /// The books on this Kindle, their ids in the library's scratch, where the series
    /// lists are made too, all emptied when they end: null, the log saying so, when
    /// there's no room there for them all.
    fn local_books(s: *Sheet) ?books.LocalBooks {
        const scratch = &s.a.regions.library_scratch_budget;
        assert(scratch.live == 0); // The library is read in it only between screens
        assert(s.a.regions.book.empty()); // Never beside an open book, as setup.zig counts
        const listed = s.lib.local_books(scratch.allocator()) catch |err| {
            std.debug.print("series: books not listed ({s})\n", .{@errorName(err)});
            scratch.reset(.give_back);
            return null;
        };
        assert(listed.count() == s.lib.local_count());
        return listed;
    }

    /// What the action picked on the card does.
    fn act(s: *Sheet, option: book_actions.Option) screen.Step(Change) {
        const a = s.a;
        const e = s.e;
        const confirming = s.round == 1;
        switch (option) {
            .cancel => return .{ .done = .none },
            .remove => {
                assert(!confirming);
                s.round += 1;
                return s.show_round();
            },
            .series => {
                const listed = s.local_books() orelse return .{ .done = .redraw };
                s.phase = .series;
                const scratch = a.regions.library_scratch_budget.allocator();
                series_screen.begin(&s.series, a, listed, e, scratch);
                return .{ .push = screen.open(&s.series, &s.series_ending) };
            },
            .confirm_remove => {
                assert(confirming);
                store.remove_download(e.key, e.kind);
                std.debug.print("removed download: {s}\n", .{e.title});
                return .{ .done = .other };
            },
            .download => {
                store.download_book(e.key, e.kind);
                std.debug.print("download requested: {s}\n", .{e.title});
                return .{ .done = .downloading };
            },
            .mark_read, .mark_unread => |choice| {
                const marked = mark_read(a, e, choice == .mark_read);
                return .{ .done = if (marked) .other else .not_marked };
            },
        }
    }
};

/// The card offering `next`, the next of a series just finished, to read now, over
/// the screen as it is (the page just left); null when it isn't on the Kindle. Its
/// small cover is let go of with `up_next_closed`.
pub fn up_next(a: *app.App, next: *const catalog.Entry, offer: *UpNext) ?screen.Frame {
    if (next.availability != .local) return null;
    // The next of a series (`next_in_series`), so always in one
    const label = catalog.series_label(&offer.label_buffer, next.*).?;
    offer.subtitle = std.fmt.bufPrint(&offer.subtitle_buffer, "Up next in {s}", .{label}) catch
        "Up next";
    std.debug.print("up next: {s}\n", .{next.title});
    // Over the page just left, kept apart from the screen for the card's dimming
    offer.under = a.display.keep_screen();
    // Its cover beside the title, half the grid's size, when it has one
    const cover_width = style.cover.width / 2;
    const cover_height = style.cover.height / 2;
    offer.small = null;
    if (next.thumbnail) |t| {
        offer.small = cover_image.load(a.alloc, t, cover_width, cover_height);
    }
    var book_cover: ?card.Cover = null;
    if (offer.small) |pixels| {
        assert(pixels.len == cover_width * cover_height);
        book_cover = .{ .pixels = pixels, .width = cover_width, .height = cover_height };
    }
    const rows = &up_next_rows;
    offer.card = card_screen.over(a, offer.under, next.title, offer.subtitle, rows, book_cover);
    return screen.open(&offer.card, &offer.ending);
}

/// Once the up-next card has ended: whether to read the book now. Either way the
/// screen is drawn afresh after (the book, or the library), so nothing's shown here.
pub fn up_next_closed(a: *app.App, offer: *UpNext) bool {
    if (offer.small) |pixels| a.alloc.free(pixels);
    offer.small = null;
    card_screen.closed_quietly(a, offer.under);
    switch (offer.ending.?) {
        .done => |row| {
            assert(row < up_next_rows.len);
            return true;
        },
        .closed, .interrupted => return false,
    }
}

const up_next_rows = [_]card.Row{.{ .label = "Read it now" }};

/// The up-next card and what it shows, kept while it's open.
pub const UpNext = struct {
    label_buffer: [160]u8 = undefined,
    subtitle_buffer: [200]u8 = undefined,
    subtitle: []const u8 = "",
    small: ?[]u8 = null, // Its cover, half the grid's size
    under: display.Backdrop = undefined, // The page just left, kept as the card opens
    card: card_screen.Card = undefined,
    ending: ?screen.Ending(u32) = null,
};
