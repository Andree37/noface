//! Holding a word without dragging: its definition, in a sheet over the page.
const std = @import("std");
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

/// "Get dictionary" on the sheet: downloads it, and shows the sheet again, with the
/// definition if it came.
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

    pub fn draw(sh: *Sheet, _: screen.Part) !void {
        const a = sh.a;
        @memcpy(a.screen.pixels, sh.page_copy); // Not over a card that was just answered
        try definition.render(a.ui, a.page(a.screen.pixels), sh.found);
        try a.showBand(0, a.screen.height);
    }

    pub fn onTap(sh: *Sheet, t: screen.Tap) !screen.Step(Choice) {
        return switch (definition.hit(t.x, t.y)) {
            .close => .close,
            .highlight => .{ .done = .highlight },
            .get_dictionary => if (try sh.getDictionary()) .{ .redraw = .all } else .stay,
            .none => .stay,
        };
    }

    /// Downloads the book's dictionary from "Get dictionary". True when the sheet
    /// needs drawing again (the download's cards were over it).
    fn getDictionary(sh: *Sheet) !bool {
        const l = sh.lang orelse return false;
        if (!sh.found.no_dictionary) return false;
        if (try dict_get.get(sh.a, sh.page_copy, l)) sh.found = find(sh.a, sh.s, sh.word, sh.lang);
        if (sh.found.no_dictionary) sh.found.can_get = dict_get.languageOf(l).name;
        return true;
    }
};

/// What the dictionary has for a word of the book.
pub fn find(a: *app.App, s: *const sess.Session, word: book_model.Word, lang: ?hyphen.Lang) definition.Found {
    const text = dictionary.trimmed(s.paragraphs[word.para].text[word.start..word.end]);
    var found = definition.Found{ .word = text };
    const d = a.dictionaryFor(lang) orelse {
        found.no_dictionary = true;
        return found;
    };
    found.entry = d.lookup(text);
    if (found.entry) |e| {
        if (e.baseForm()) |b| found.base = d.lookup(b);
    }
    return found;
}

/// Shows the sheet until it's closed or Highlight is pressed. What was on screen
/// is put back either way.
pub fn run(a: *app.App, s: *const sess.Session, word: book_model.Word, lang: ?hyphen.Lang) !Choice {
    var found = find(a, s, word, lang);
    std.debug.print("lookup: found {}, form of another {}\n", .{ found.entry != null, found.base != null });
    // The page as it was: what the sheet and any card about getting a dictionary sit
    // over, and what's put back when they close
    const page_copy = try a.alloc.dupe(u8, a.screen.pixels);
    defer a.alloc.free(page_copy);
    if (found.no_dictionary) if (lang) |l| {
        found.can_get = dict_get.languageOf(l).name;
        // The first time, ask; after "Not now", the sheet offers it instead
        if (a.settings.offer_dictionary and try dict_get.ask(a, page_copy, l) == .download) {
            if (try dict_get.get(a, page_copy, l)) found = find(a, s, word, lang);
        }
    };
    var sheet = Sheet{ .a = a, .s = s, .word = word, .lang = lang, .page_copy = page_copy, .found = found };
    const choice = try screen.run(a, &sheet) orelse .close; // Closed, locked or leaving
    @memcpy(a.screen.pixels, page_copy); // The cards drew into the overlay; this is the page
    try a.showBand(0, a.screen.height);
    return choice;
}
