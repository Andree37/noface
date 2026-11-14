//! Typing on the on-screen keyboard: what a key does to the text being typed. The
//! screens that take typing (searching the library or a book, a page number, a series
//! name) draw the keyboard once and their field as it changes; this is what they share.
const std = @import("std");
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
    switch (keyboard.hit(t.x, t.y) orelse return .none) {
        .char => |c| {
            if (!accepts(c)) return .none;
            text.push(c);
        },
        .space => text.push(' '),
        .backspace => text.pop(),
        .enter => return .enter,
    }
    return .changed;
}

pub fn anything(_: u8) bool {
    return true;
}

pub fn digits(c: u8) bool {
    return std.ascii.isDigit(c);
}
