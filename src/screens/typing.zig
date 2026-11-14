//! Typing on the on-screen keyboard: what a key does to the text being typed. The
//! screens that take typing (searching the library or a book, a page number, a series
//! name) draw the keyboard once and their field as it changes; this is what they share.
const std = @import("std");
const assert = std.debug.assert;
const keyboard = @import("../ui/keyboard.zig");
const Query = @import("../model/search.zig").Query;
const Tap = @import("../kindle/input.zig").Tap;

pub const Edit = enum {
    none, // Not on a key, or a key that means nothing here
    changed, // The text changed: its field needs drawing again
    enter, // Enter, for the screen to act on
};

/// What a tap does to `text`: a character added (if `accepts` takes it), a space added,
/// one taken back.
pub fn key(text: *Query, t: Tap, accepts: *const fn (u8) bool) Edit {
    assert(text.len <= text.buf.len);
    const length_before = text.len;
    switch (keyboard.hit(t.x, t.y) orelse return .none) {
        .char => |c| {
            if (!accepts(c)) return .none;
            text.push(c);
        },
        .space => text.push(' '),
        .backspace => text.pop(),
        .enter => return .enter,
    }
    // One character more or one fewer, or none when the text was full or empty
    assert(text.len <= text.buf.len);
    assert(text.len <= length_before + 1);
    assert(text.len + 1 >= length_before);
    return .changed;
}

/// Takes any key. The keyboard has letters and digits only, in lower case.
pub fn anything(c: u8) bool {
    assert(std.ascii.isAlphanumeric(c));
    assert(!std.ascii.isUpper(c));
    return true;
}

/// Takes digits only, for a page number.
pub fn digits(c: u8) bool {
    assert(std.ascii.isAlphanumeric(c));
    assert(!std.ascii.isUpper(c));
    return std.ascii.isDigit(c);
}
