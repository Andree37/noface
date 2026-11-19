//! Notes shown in a panel over the page, from a tapped reference. The reader keeps a
//! Footnote while one is open and brings it the taps on it.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const Page = @import("../../gfx/page.zig").Page;
const note_rules = @import("../../model/notes.zig");
const notes = @import("../../ui/notes.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

/// The note open over the page: its paragraphs, copied to be drawn as a note's text,
/// and the panel on screen.
pub const Footnote = struct {
    parts: [note_rules.max_note_parts]book_model.Paragraph = undefined,
    len: u32 = 0,
    /// The panel's top on screen.
    top: u32 = 0,
    /// Where the next part of a note too long for the panel starts.
    next: ?book_model.Pos = null,

    /// Opens the note at paragraph `target`, a reference's, in a panel over the page.
    pub fn open(f: *Footnote, a: *app.App, s: *sess.Session, target: u32) !void {
        // Layout keeps only references to paragraphs of the book
        assert(target < s.paragraphs.len);
        f.len = note_rules.note_length(s.paragraphs, target);
        assert(f.len > 0);
        assert(f.len <= f.parts.len);
        const sources = s.paragraphs[target..][0..f.len];
        for (sources, f.parts[0..f.len]) |source, *part| {
            part.* = source;
            part.note = false;
            part.note_start = false;
            part.links = &.{};
        }
        try f.show(a, s, .{}, null);
    }

    /// A tap at height `y`: on the panel of a note with more to it, shows the next part
    /// in a panel the same height, and is true; false when the tap closes the note.
    pub fn tap(f: *Footnote, a: *app.App, s: *sess.Session, y: i32) !bool {
        assert(f.len > 0);
        assert(f.top <= a.screen.height);
        if (y < f.top) return false;
        const next = f.next orelse return false;
        try f.show(a, s, next, a.screen.height - f.top);
        return true;
    }

    /// Puts the page back where the panel was.
    pub fn close(f: *Footnote, a: *app.App, s: *sess.Session) !void {
        assert(f.top <= a.screen.height);
        assert(s.current < s.pages.len);
        std.debug.print("note closed\n", .{});
        @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
        try a.screen.wait_complete(try s.show_band(f.top, a.screen.height - f.top));
        f.* = .{};
    }

    /// Shows the note from `start`, in a panel of the height it needs or `fixed`.
    fn show(
        f: *Footnote,
        a: *app.App,
        s: *sess.Session,
        start: book_model.Pos,
        fixed: ?u32,
    ) !void {
        assert(f.len > 0);
        assert(f.len <= f.parts.len);
        if (fixed) |height| assert(height <= a.screen.height);
        const font = a.note_font;
        const parts = f.parts[0..f.len];
        const whole = a.compose(try s.lend_current());
        const stride = a.screen.stride;
        const fitted = try notes.fit(font, parts, start, a.screen.width, stride, fixed);
        assert(fitted.height <= a.screen.height);
        const top = a.screen.height - fitted.height;
        const panel = Page{
            .buf = whole.buf[top * stride ..],
            .width = a.screen.width,
            .height = fitted.height,
            .stride = stride,
        };
        try notes.render(font, a.ui, panel, parts, start, fitted.next != null);
        a.put_composed();
        try a.screen.wait_complete(try s.show_band(top, fitted.height));
        f.top = top;
        f.next = fitted.next;
        std.debug.print(
            "note parts {d} panel {d} more {}\n",
            .{ f.len, fitted.height, fitted.next != null },
        );
    }
};
