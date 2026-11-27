//! What noface asks of the device's own software, for the family the build is for
//! (model/models.zig `Family`): one module per family, chosen here at build time, so the
//! reader and the library never ask which device they're on. Every family's module has
//! the same declarations, checked below for all of them, not only the one built, so a
//! family missing one, or with one of another shape, fails every build.
const std = @import("std");
const models = @import("model/models.zig");
const device = @import("model/device.zig");
const book_model = @import("model/book.zig");
const catalog = @import("model/catalog.zig");
const place = @import("model/place.zig");
const kindle_reading_place = @import("kindle/reading_place.zig");

/// A book's reading place as the device keeps it.
pub const reading_place = reading_place_of(models.family(device.target));

fn reading_place_of(comptime family: models.Family) type {
    return switch (family) {
        .kindle => kindle_reading_place,
    };
}

/// What every family's reading place module has. `Book` is the family's own name for a
/// book, copied as it opens; the rest is in noface's own numbering.
fn expect_reading_place(comptime M: type) void {
    const Book = M.Book;
    expect(M, "look", fn (*const catalog.Entry, []const book_model.Paragraph) M.Found);
    expect(M, "keep", fn (*const Book, []const book_model.Paragraph, book_model.Pos, u64) bool);
    expect(M, "send", fn () void);
    if (@FieldType(M.Found, "answer") != place.Answer) {
        @compileError(@typeName(M) ++ ".Found.answer isn't a place.Answer");
    }
    if (@FieldType(M.Found, "book") != ?Book) {
        @compileError(@typeName(M) ++ ".Found.book isn't an optional Book");
    }
}

fn expect(comptime M: type, comptime name: []const u8, comptime T: type) void {
    if (!@hasDecl(M, name)) @compileError(@typeName(M) ++ " has no " ++ name);
    if (@TypeOf(@field(M, name)) != T) {
        @compileError(@typeName(M) ++ "." ++ name ++ " isn't a " ++ @typeName(T));
    }
}

comptime {
    for (std.enums.values(models.Family)) |family| {
        expect_reading_place(reading_place_of(family));
    }
}
