//! Holding a word without dragging: its definition, in a sheet over the page.
const std = @import("std");
const assert = std.debug.assert;
const card_screen = @import("../card.zig");
const input_mod = @import("../../kindle/input.zig");
const definition = @import("../../ui/definition.zig");
const dictionary = @import("../../model/dictionary.zig");
const book_model = @import("../../model/book.zig");
const hyphen = @import("../../layout/hyphen.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const dict_get = @import("dict_get.zig");
const screen = @import("../screen.zig");

pub const Choice = enum { close, highlight };

/// The sheet with what the dictionary says, over the page. Highlight sits on the
/// bottom edge, so it takes touches as a sheet.
const Sheet = struct {
    pub const Result = Choice;
    pub const touches = input_mod.Input.Modes.sheet;
    a: *app.App,
    s: *const sess.Session,
    word: book_model.Word,
    lang: ?hyphen.Lang,
    page_copy: []const u8, // The page under it
    found: definition.Found,
    /// Getting the dictionary from "Get dictionary", over the sheet.
    getting: dict_get.Getting = undefined,
    getting_ending: ?screen.Ending(bool) = null,

    pub fn draw(sh: *Sheet, _: screen.Part) !void {
        const a = sh.a;
        assert(sh.page_copy.len == a.screen.pixels.len);
        if (sh.found.no_dictionary) assert(sh.found.entry == null);
        @memcpy(a.screen.pixels, sh.page_copy); // Not over a card that was just answered
        try definition.render(a.ui, a.page(a.screen.pixels), sh.found);
        try a.show_band(0, a.screen.height);
    }

    pub fn on_tap(sh: *Sheet, t: screen.Tap) !screen.Step(Choice) {
        assert(sh.page_copy.len == sh.a.screen.pixels.len);
        assert(sh.word.para < sh.s.paragraphs.len);
        return switch (definition.hit(t.x, t.y)) {
            .close => .close,
            .highlight => .{ .done = .highlight },
            .get_dictionary => sh.get_dictionary(),
            .none => .stay,
        };
    }

    /// Downloads the book's dictionary from "Get dictionary".
    fn get_dictionary(sh: *Sheet) screen.Step(Choice) {
        const l = sh.lang orelse return .stay;
        if (!sh.found.no_dictionary) return .stay;
        assert(sh.found.entry == null); // Nothing found without a dictionary
        assert(sh.found.can_get != null); // Offered, as it was tapped
        dict_get.begin(&sh.getting, sh.a, sh.page_copy, l);
        return .{ .push = screen.open(&sh.getting, &sh.getting_ending) };
    }

    /// The download's cards were over it: drawn again, with the definition if it came.
    pub fn on_resume(sh: *Sheet) !screen.Step(Choice) {
        const l = sh.lang.?; // Only a book's known language is downloaded
        assert(sh.page_copy.len == sh.a.screen.pixels.len);
        const ready = switch (sh.getting_ending.?) {
            .done => |ready| ready,
            .closed, .interrupted => false,
        };
        if (ready) sh.found = find(sh.a, sh.s, sh.word, sh.lang);
        if (sh.found.no_dictionary) sh.found.can_get = dict_get.language_of(l).name;
        // Offered again exactly when it's still missing
        assert((sh.found.can_get != null) == sh.found.no_dictionary);
        return .{ .redraw = .all };
    }
};

/// What the dictionary has for a word of the book.
pub fn find(
    a: *app.App,
    s: *const sess.Session,
    word: book_model.Word,
    lang: ?hyphen.Lang,
) definition.Found {
    assert(word.para < s.paragraphs.len);
    assert(word.start <= word.end);
    assert(word.end <= s.paragraphs[word.para].text.len);
    const text = dictionary.trimmed(s.paragraphs[word.para].text[word.start..word.end]);
    var found = definition.Found{ .word = text };
    const d = a.dictionary_for(lang) orelse {
        found.no_dictionary = true;
        assert(found.entry == null);
        return found;
    };
    found.entry = d.lookup(text);
    if (found.entry) |e| {
        if (e.base_form()) |b| found.base = d.lookup(b);
    }
    // Only a word that was found can be the form of another
    if (found.base != null) assert(found.entry != null);
    assert(!found.no_dictionary);
    return found;
}

/// Starts looking up `word` in `d`, where it stays while it's open (`screen.open`):
/// the sheet with its definition, and first, without the book's dictionary, the
/// question whether to get it. Done with the choice made on the sheet (closed, or
/// Highlight); what was on screen is put back either way.
pub fn begin(
    d: *Define,
    a: *app.App,
    s: *const sess.Session,
    word: book_model.Word,
    lang: ?hyphen.Lang,
) !void {
    assert(word.para < s.paragraphs.len);
    const found = find(a, s, word, lang);
    std.debug.print(
        "lookup: found {}, form of another {}\n",
        .{ found.entry != null, found.base != null },
    );
    // The page as it was: what the sheet and any card about getting a dictionary sit
    // over, and what's put back when they close
    const page_copy = try a.alloc.dupe(u8, a.screen.pixels);
    d.* = .{ .a = a, .s = s, .word = word, .lang = lang, .page_copy = page_copy, .found = found };
    assert(d.phase == .asking);
}

pub const Define = struct {
    pub const Result = Choice;
    a: *app.App,
    s: *const sess.Session,
    word: book_model.Word,
    lang: ?hyphen.Lang,
    page_copy: []u8, // Let go of as it ends
    found: definition.Found,
    phase: enum { asking, getting, sheet } = .asking,
    asking: dict_get.Asking = .{},
    ask_card: card_screen.Card = undefined,
    ask_ending: ?screen.Ending(u32) = null,
    getting: dict_get.Getting = undefined,
    getting_ending: ?screen.Ending(bool) = null,
    sheet: Sheet = undefined,
    sheet_ending: ?screen.Ending(Choice) = null,

    /// Never shown itself: the sheet and the cards are.
    pub fn draw(d: *Define, part: screen.Part) !void {
        assert(part == .all);
        assert(d.phase == .asking);
    }

    pub fn on_tap(d: *Define, _: screen.Tap) !screen.Step(Choice) {
        assert(d.phase == .asking);
        unreachable; // Never in front: the sheet or a card always is
    }

    /// Without the dictionary, the first time, asks whether to get it; after "Not now"
    /// the sheet offers it instead.
    pub fn on_open(d: *Define) !screen.Step(Choice) {
        assert(d.phase == .asking);
        assert(d.page_copy.len == d.a.screen.pixels.len);
        if (d.found.no_dictionary) if (d.lang) |l| {
            d.found.can_get = dict_get.language_of(l).name;
            if (d.a.settings.offer_dictionary) {
                d.ask_card = dict_get.ask(d.a, d.page_copy, l, &d.asking);
                return .{ .push = screen.open(&d.ask_card, &d.ask_ending) };
            }
        };
        return d.show_sheet();
    }

    pub fn on_resume(d: *Define) !screen.Step(Choice) {
        assert(d.page_copy.len == d.a.screen.pixels.len);
        switch (d.phase) {
            .asking => {
                const answer = try dict_get.asked(d.a, d.page_copy, d.ask_ending.?);
                if (answer != .download) return d.show_sheet();
                d.phase = .getting;
                dict_get.begin(&d.getting, d.a, d.page_copy, d.lang.?);
                return .{ .push = screen.open(&d.getting, &d.getting_ending) };
            },
            .getting => {
                const ready = d.getting_ending.? == .done and d.getting_ending.?.done;
                if (ready) d.found = find(d.a, d.s, d.word, d.lang);
                return d.show_sheet();
            },
            .sheet => {
                // Closed, locked or leaving
                const choice: Choice = switch (d.sheet_ending.?) {
                    .done => |choice| choice,
                    .closed, .interrupted => .close,
                };
                const a = d.a;
                assert(d.page_copy.len == a.screen.pixels.len);
                // The cards drew into the overlay; this is the page
                @memcpy(a.screen.pixels, d.page_copy);
                a.alloc.free(d.page_copy);
                try a.show_band(0, a.screen.height);
                return .{ .done = choice };
            },
        }
    }

    fn show_sheet(d: *Define) screen.Step(Choice) {
        if (d.found.can_get != null) assert(d.found.no_dictionary);
        assert(d.phase != .sheet);
        d.phase = .sheet;
        d.sheet = .{
            .a = d.a,
            .s = d.s,
            .word = d.word,
            .lang = d.lang,
            .page_copy = d.page_copy,
            .found = d.found,
        };
        return .{ .push = screen.open(&d.sheet, &d.sheet_ending) };
    }
};
