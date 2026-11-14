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

pub const Choice = enum { close, highlight };

/// "Get dictionary" on the sheet: downloads it, and shows the sheet again, with the
/// definition if it came.
fn getDictionary(a: *app.App, s: *const sess.Session, word: book_model.Word, lang: ?hyphen.Lang, page_copy: []const u8, found: *definition.Found) !void {
    const l = lang orelse return;
    if (!found.no_dictionary) return;
    if (try dict_get.get(a, page_copy, l)) found.* = find(a, s, word, lang);
    if (found.no_dictionary) found.can_get = dict_get.languageOf(l).name;
    @memcpy(a.screen.pixels, page_copy);
    try definition.render(a.ui, a.page(a.screen.pixels), found.*);
    try a.showBand(0, a.screen.height);
}

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
    @memcpy(a.screen.pixels, page_copy); // Not over a card that was just answered
    try definition.render(a.ui, a.page(a.screen.pixels), found);
    try a.showBand(0, a.screen.height);
    const was = a.input.use(input_mod.Input.Modes.sheet); // Highlight sits on the bottom edge
    defer a.input.restore(was);
    const choice: Choice = while (a.input.nextTap()) |t| {
        switch (definition.hit(t.x, t.y)) {
            .close => break .close,
            .highlight => break .highlight,
            .get_dictionary => try getDictionary(a, s, word, lang, page_copy, &found),
            .none => {},
        }
    } else .close; // Locked, or leaving
    @memcpy(a.screen.pixels, page_copy); // The cards drew into the overlay; this is the page
    try a.showBand(0, a.screen.height);
    return choice;
}
