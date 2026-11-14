//! Notes shown in a panel over the page, from a tapped reference.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const Page = @import("../../gfx/page.zig").Page;
const note_rules = @import("../../model/notes.zig");
const notes = @import("../../ui/notes.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// Shows a note, or the next part of a long one.
pub fn show_note(a: *app.App, s: *sess.Session, start: book_model.Pos, fixed: ?u32) !void {
    assert(s.note_len > 0);
    assert(s.note_len <= s.note_parts.len);
    if (fixed) |height| assert(height <= a.screen.height);
    const font = a.note_font;
    const parts = s.note_parts[0..s.note_len];
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    const stride = a.screen.stride;
    const fitted = try notes.fit(font, parts, start, a.screen.width, stride, fixed);
    assert(fitted.height <= a.screen.height);
    const top = a.screen.height - fitted.height;
    const panel = Page{
        .buf = a.overlay[top * stride ..],
        .width = a.screen.width,
        .height = fitted.height,
        .stride = stride,
    };
    try notes.render(font, a.ui, panel, parts, start, fitted.next != null);
    @memcpy(a.screen.pixels, a.overlay);
    try a.show_band(top, fitted.height);
    s.note_top = top;
    s.note_next = fitted.next;
    std.debug.print(
        "note parts {d} panel {d} more {}\n",
        .{ s.note_len, fitted.height, fitted.next != null },
    );
}

pub fn open_note(a: *app.App, s: *sess.Session, target: u32) !void {
    // Layout keeps only references to paragraphs of the book
    assert(target < s.paragraphs.len);
    s.note_len = note_rules.note_length(s.paragraphs, target);
    assert(s.note_len > 0);
    assert(s.note_len <= s.note_parts.len);
    const sources = s.paragraphs[target..][0..s.note_len];
    for (sources, s.note_parts[0..s.note_len]) |source, *target_part| {
        target_part.* = source;
        target_part.note = false;
        target_part.note_start = false;
        target_part.links = &.{};
    }
    try show_note(a, s, .{}, null);
}

pub fn close_note(a: *app.App, s: *sess.Session) !void {
    assert(s.note_top <= a.screen.height);
    assert(s.current < s.pages.len);
    std.debug.print("note closed\n", .{});
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    try a.show_band(s.note_top, a.screen.height - s.note_top);
}
