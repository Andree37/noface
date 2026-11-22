//! Typing on the on-screen keyboard: what a key does to the text being typed, and to
//! the keyboard itself (its layer, shift, a held letter's accents). The screens that
//! take typing (searching the library or a book, a page number, a series name) each
//! keep a `Typist`, draw the keyboard as it says, and their field as it changes.
const std = @import("std");
const assert = std.debug.assert;
const keyboard = @import("../ui/keyboard.zig");
const Query = @import("../model/search.zig").Query;
const input_mod = @import("../kindle/input.zig");

/// How a typing screen takes touches: every touch counts, along the bottom edge too
/// where the keys are, and a key acts as the finger lifts, so one held shows its
/// accents instead; held, a key without any types as if tapped.
pub const touches = input_mod.Input.Modes{ .grips = false, .deferred = true, .edge_zones = true };

/// What a key did: the text changed (its field to draw again), the keyboard changed
/// (its keys to draw again), or Enter, for the screen to act on.
pub const Edit = struct {
    text: bool = false,
    keys: bool = false,
    enter: bool = false,

    pub fn any(e: Edit) bool {
        return e.text or e.keys or e.enter;
    }
};

/// What a screen typing on the keyboard keeps of it.
pub const Typist = struct {
    keys: keyboard.State = .{},
    /// The keys changed since they were last drawn (`redraw_keys`).
    keys_changed: bool = false,

    /// For a page number: the digits shown from the start.
    pub const digits_first: Typist = .{ .keys = .{ .layer = .symbols } };

    /// A tap at (`x`, `y`): a character added to `text` (if `accepts` takes it), a space,
    /// one taken back, Enter, or the keyboard changed (shift, another layer, a held
    /// letter's accents put away).
    pub fn tap(t: *Typist, text: *Query, x: i32, y: i32, accepts: *const fn (u21) bool) Edit {
        const edit = t.tapped(text, x, y, accepts);
        if (edit.keys) t.keys_changed = true;
        return edit;
    }

    /// Whether the keys are to be drawn now: all of the screen is, or they changed
    /// since. Either way, they're counted as drawn from here.
    pub fn redraw_keys(t: *Typist, all: bool) bool {
        const due = all or t.keys_changed;
        t.keys_changed = false;
        assert(!t.keys_changed);
        return due;
    }

    fn tapped(t: *Typist, text: *Query, x: i32, y: i32, accepts: *const fn (u21) bool) Edit {
        assert(text.len <= text.buf.len);
        if (t.keys.accents != null) {
            // A held letter's accents show: a tap on one types it, any other puts them away
            const form = keyboard.accent_at(t.keys, x, y);
            t.keys.accents = null;
            var edit: Edit = .{ .keys = true };
            if (form) |f| edit.text = t.type_char(text, f, accepts);
            return edit;
        }
        const key = keyboard.hit(t.keys, x, y) orelse return .{};
        var edit: Edit = .{};
        switch (key) {
            .char => |c| {
                edit.text = t.type_char(text, c, accepts);
                if (edit.text and t.keys.shift == .once) {
                    t.keys.shift = .off; // A capital typed: the next letter is small
                    edit.keys = true;
                }
            },
            .space => edit.text = accepts(' ') and text.push(' '),
            .backspace => edit.text = text.pop(),
            .enter => edit.enter = true,
            .shift => {
                // Once for the next letter, again to lock capitals, again to stop
                t.keys.shift = switch (t.keys.shift) {
                    .off => .once,
                    .once => .locked,
                    .locked => .off,
                };
                edit.keys = true;
            },
            .layer => |to| {
                t.keys.layer = to;
                edit.keys = true;
            },
        }
        assert(text.len <= text.buf.len);
        return edit;
    }

    /// A hold at (`x`, `y`): a letter with accented forms shows them, to tap; any other
    /// key types as if tapped.
    pub fn hold(t: *Typist, text: *Query, x: i32, y: i32, accepts: *const fn (u21) bool) Edit {
        assert(text.len <= text.buf.len);
        assert(y >= 0); // A hold on the screen
        if (t.keys.accents == null) {
            if (keyboard.held_letter(t.keys, x, y)) |held| {
                t.keys.accents = held;
                t.keys_changed = true;
                return .{ .keys = true };
            }
        }
        return t.tap(text, x, y, accepts);
    }

    /// Types `c`, a capital while shifted, if `accepts` takes it and it fits.
    fn type_char(t: *const Typist, text: *Query, c: u21, accepts: *const fn (u21) bool) bool {
        assert(text.len <= text.buf.len);
        const cp = keyboard.typed(c, t.keys.shift);
        if (!accepts(cp)) return false;
        return text.push(cp);
    }
};

/// Takes any character.
pub fn anything(c: u21) bool {
    assert(c <= 0x10ffff);
    return true;
}

/// Takes digits only, for a page number.
pub fn digits(c: u21) bool {
    assert(c <= 0x10ffff);
    return c >= '0' and c <= '9';
}

test "letters, capitals once or locked, symbols and accents type as on the Kindle's keyboard" {
    var text: Query = .{};
    var t: Typist = .{};
    const p = keyboard.place;
    // Shift once: one capital, then small letters
    _ = t.tap(&text, p(.shift).x, p(.shift).y, anything);
    _ = t.tap(&text, p(.{ .char = 'a' }).x, p(.{ .char = 'a' }).y, anything);
    _ = t.tap(&text, p(.{ .char = 'a' }).x, p(.{ .char = 'a' }).y, anything);
    try std.testing.expectEqualStrings("Aa", text.slice());
    // Held, a letter shows its accents; one tapped is typed
    const c = p(.{ .char = 'c' });
    const shown = t.hold(&text, c.x, c.y, anything);
    try std.testing.expect(shown.keys);
    try std.testing.expect(!shown.text);
    const cedilla = keyboard.accent_place(t.keys.accents.?, 0);
    _ = t.tap(&text, cedilla.x, cedilla.y, anything);
    try std.testing.expectEqualStrings("Aa\u{e7}", text.slice());
    try std.testing.expect(t.keys.accents == null);
    // The digits, then back to the letters; backspace takes a whole character back
    _ = t.tap(&text, p(.{ .layer = .symbols }).x, p(.{ .layer = .symbols }).y, anything);
    _ = t.tap(&text, p(.{ .char = '7' }).x, p(.{ .char = '7' }).y, anything);
    try std.testing.expectEqualStrings("Aa\u{e7}7", text.slice());
    _ = t.tap(&text, p(.backspace).x, p(.backspace).y, anything);
    _ = t.tap(&text, p(.backspace).x, p(.backspace).y, anything);
    try std.testing.expectEqualStrings("Aa", text.slice());
    // Held, a key without accents types as tapped
    t = .{};
    _ = t.hold(&text, p(.{ .char = 't' }).x, p(.{ .char = 't' }).y, anything);
    try std.testing.expectEqualStrings("Aat", text.slice());
}

test "a page number takes digits only, and starts on them" {
    var text: Query = .{};
    var t = Typist.digits_first;
    const p = keyboard.place;
    _ = t.tap(&text, p(.{ .char = '4' }).x, p(.{ .char = '4' }).y, digits);
    _ = t.tap(&text, p(.{ .char = '-' }).x, p(.{ .char = '-' }).y, digits);
    try std.testing.expectEqualStrings("4", text.slice());
}
