//! The open book's place outside noface, as the device's own software keeps it
//! (src/platform.zig picks the code for the device): read once as the book opens, kept
//! there as the book closes or the device locks, so its own reader and other devices
//! go on from where noface left off. When another device read the book since, a card
//! asks whether to go to its place, as the stock reader asks.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../../app.zig");
const platform = @import("../../platform.zig");
const book_model = @import("../../model/book.zig");
const place = @import("../../model/place.zig");
const card = @import("../../ui/card.zig");
const line_of = @import("../../text/line.zig").of;
const card_screen = @import("../card.zig");
const screen = @import("../screen.zig");
const sess = @import("session.zig");
/// Lines for noface's log, which the tests keep quiet (main.zig's `std_options`).
const log = std.log.scoped(.place);

const reading_place = platform.reading_place;

/// The offer's rows, in the order of its choices.
const offer_rows = [_]card.Row{
    .{ .label = "Go there" },
    .{ .label = "Stay here" },
};
const Offered = enum { go, stay };

comptime {
    assert(offer_rows.len == std.enums.values(Offered).len);
}

pub const OutsidePlace = struct {
    /// The book as the device names it, its place kept by that: null when nothing may
    /// be written (no counterpart on the device, device tests, or an answer that
    /// wasn't whole, as a place written then could replace a later one unseen).
    book: ?reading_place.Book = null,
    /// Another device's later place, asked about once as the book opens.
    offer: ?place.Outside = null,
    /// The page kept under the card, in the book's memory, made when it opens.
    under: []u8 = &.{},
    title: [title_bytes_max]u8 = undefined,
    note: [note_bytes_max]u8 = undefined,

    /// Keeps the session's place outside noface, stamped with the time its own save
    /// just gave it, so it never reads back as a later one.
    pub fn keep(o: *const OutsidePlace, s: *const sess.Session) void {
        assert(s.anchor.para < s.paragraphs.len);
        assert(s.saved.opened > 0); // Kept only after a save landed
        const book = if (o.book) |*b| b else return;
        if (!reading_place.keep(book, s.paragraphs, s.anchor, s.saved.opened)) {
            log.info("place not kept outside noface", .{});
        }
    }

    /// Asks the device to send what was kept, as the book closes.
    pub fn send(o: *const OutsidePlace) void {
        if (o.book == null) return; // Nothing was kept
        reading_place.send();
    }

    /// The card asking whether to go to the offered place, over the page as it is.
    pub fn open_offer(
        o: *OutsidePlace,
        a: *app.App,
        alloc: std.mem.Allocator,
        s: *const sess.Session,
    ) !card_screen.Card {
        const offer = o.offer.?;
        assert(offer.at.para < s.paragraphs.len);
        const pixels = a.display.screen.pixels.len;
        if (o.under.len == 0) o.under = try alloc.alloc(u8, pixels);
        assert(o.under.len == pixels);
        @memcpy(o.under, a.display.screen.pixels);
        const percent = s.words_percent(s.book_words_left(offer.at)) orelse 0;
        const title = line_of(&o.title, "Go to {d}%?", .{percent});
        const device = switch (offer.from) {
            .elsewhere => |*name| name.text(),
            .this_device => unreachable, // Only another device's place is offered
        };
        const note = line_of(&o.note, "Last read on {s}", .{device});
        return card_screen.over(a, .{ .pixels = o.under }, title, note, &offer_rows, null);
    }

    /// The card closed: the page back as it was, and the place to go to, if chosen.
    pub fn offered(o: *OutsidePlace, a: *app.App, ending: screen.Ending(u32)) !?book_model.Pos {
        assert(o.offer != null);
        assert(o.under.len == a.display.screen.pixels.len);
        const offer = o.offer.?;
        o.offer = null; // Asked once
        const choice: Offered = switch (ending) {
            .done => |row| @fromBackingInt(@intCast(row)),
            // Tapped above it, or locked: the reader stays where noface had it
            .closed, .interrupted => .stay,
        };
        return switch (choice) {
            .go => {
                card_screen.closed_quietly(a, .{ .pixels = o.under }); // The page is drawn next
                return offer.at;
            },
            .stay => {
                try card_screen.closed(a, .{ .pixels = o.under });
                return null;
            },
        };
    }
};

/// Room for "Go to <percent>%?", the percent of any size `line_of` checks.
const title_bytes_max = std.fmt.count("Go to {d}%?", .{std.math.maxInt(u32)});
/// Room for "Last read on " and the longest name kept.
const note_bytes_max = 16 + place.name_bytes_max;
