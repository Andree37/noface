//! A line of noface's own made from a format: a label, a count, a line of a file. Its
//! buffer is sized for the longest the format can make, so it never fails: for a
//! format of numbers only, the build checks that against the largest each can be;
//! with text in it (noface's own, never a book's), every line is checked as it's
//! made, and one that wouldn't fit stops noface, a bug of its own, not a blank label.
const std = @import("std");
const assert = std.debug.assert;
const check = @import("../base/check.zig");

/// `format` of `args`, in `buffer`, a fixed-size array of bytes.
pub fn of(buffer: anytype, comptime format: []const u8, args: anytype) []const u8 {
    const Pointer = @TypeOf(buffer);
    const Buffer = switch (@typeInfo(Pointer)) {
        .pointer => |p| p.child,
        else => @compileError("a line is made in a buffer, given " ++ @typeName(Pointer)),
    };
    // Of a size known here, so it can be held to the longest line
    if (@typeInfo(Buffer) != .array) {
        @compileError("a line's buffer has a size: " ++ @typeName(Pointer));
    }
    const room = @typeInfo(Buffer).array.len;
    if (comptime longest(format, @TypeOf(args))) |most| {
        // Numbers only: the longest they can make fits, whatever they are
        comptime if (most > room) @compileError(std.fmt.comptimePrint(
            "a line of \"{s}\" can take {d} bytes, its buffer holds {d}",
            .{ format, most, room },
        ));
    }
    const needed = std.fmt.count(format, args);
    check.that(needed <= room, "a line's buffer holds it");
    const made = std.fmt.bufPrint(buffer, format, args) catch unreachable; // Ignored: checked
    assert(made.len == needed);
    return made;
}

/// The longest `format` makes of arguments of `Args`, when they're all numbers (or
/// bools); null when one is text or anything whose length isn't known here.
fn longest(comptime format: []const u8, comptime Args: type) ?usize { // usize: std.fmt's
    const info = @typeInfo(Args).@"struct";
    // A value known where it's written (a comptime field) can't be set to another:
    // such a line is checked as it's made
    for (info.field_attrs) |attrs| {
        if (attrs.@"comptime") return null;
    }
    var widest: Args = undefined;
    inline for (info.field_names, info.field_types) |name, T| {
        @field(widest, name) = switch (@typeInfo(T)) {
            // The longest a number of its type writes: its most, or its least if signed
            .int => if (@typeInfo(T).int.signedness == .signed)
                std.math.minInt(T)
            else
                std.math.maxInt(T),
            .comptime_int => return null, // Known only where it's written: counted there
            .bool => false,
            else => return null,
        };
    }
    return std.fmt.count(format, widest);
}

test "a line of numbers fits a buffer sized for the largest, and is made whole" {
    var buffer: [24]u8 = undefined;
    const page: u32 = 12;
    const pages: u32 = 300;
    try std.testing.expectEqualStrings("12 of 300", of(&buffer, "{d} of {d}", .{ page, pages }));
    // Its longest: two u32s at their largest, and " of "
    try std.testing.expect(longest("{d} of {d}", struct { u32, u32 }).? == 24);
    try std.testing.expect(longest("{s} left", struct { []const u8 }) == null);
}
