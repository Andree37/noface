//! What the reader shows, the page alone or something over it, and what each view
//! means for the rest of the reader: how it takes touches, and which actions wait for
//! the whole book to be laid out. The reader (screens/reader.zig) keeps the view.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const aa = @import("../../ui/aa.zig");
const toolbar = @import("../../ui/toolbar.zig");
const touch_zones = @import("../../kindle/touch.zig");
const input_mod = @import("../../kindle/input.zig");
const paginate = @import("paginate.zig");
const sess = @import("session.zig");

/// What the reader shows: the page alone, or something over it, with what that one
/// holds: the toolbar whether its Aa sheet is open below it, the highlight view which
/// highlight is selected.
pub const View = union(enum) {
    page,
    toolbar: struct { sheet_open: bool = false },
    note,
    highlight: struct {
        id: []const u8,
        delete_top: ?u32 = null, // Where its Delete bubble is, when there is one
    },

    /// The Aa sheet's tab, while it's open.
    pub fn sheet(v: View, kept: aa.Tab) ?aa.Tab {
        return switch (v) {
            .toolbar => |t| if (t.sheet_open) kept else null,
            .page, .note, .highlight => null,
        };
    }
};

/// What a view means for the rest of the reader. While `reading`, the page alone is in
/// front of the reader: the reading clock runs, the clock in the corner keeps time,
/// Wi-Fi may go off, and the Back button can be tapped. On the page a press may become
/// a hold, so taps wait for the finger to lift; controls that sit where a thumb rests
/// turn the thumb filter off; a highlight's handles can reach the screen's edges.
/// While running, the page takes a touch anywhere: no thumb rests on a treadmill.
/// How each view takes touches.
// Assertions: a table, which the switch keeps complete.
pub fn touches_for(view: View, running: bool) input_mod.Input.Modes {
    const modes: input_mod.Input.Modes = switch (view) {
        // Taps on the lift, so a press can become a hold; a resting thumb is ignored
        .page => .{ .grips = !running, .deferred = true, .edge_zones = true },
        .toolbar => input_mod.Input.Modes.sheet,
        // The handles can sit at the screen edges
        .highlight => .{ .grips = true, .deferred = false, .edge_zones = false },
        .note => .{ .grips = true, .deferred = false, .edge_zones = true },
    };
    // Only the page waits for a lift, as only there a press may become a hold
    assert(modes.deferred == (view == .page));
    return modes;
}

/// Whether an action needs every page laid out first: anything but reading on, as
/// menus, Go To and page numbers count from the start of the book.
pub fn needs_all_pages(
    action: input_mod.Action,
    view: View,
    sheet: ?aa.Tab,
    s: *const sess.Session,
) bool {
    assert(s.layout_pending());
    assert(s.current < s.pages.len);
    return switch (action) {
        .tick, .drag, .drag_end => false,
        .tap => |t| switch (view) {
            // The toolbar, going back from the first page, or the Back button: all count pages
            .page => t.y < touch_zones.top_zone or s.on_back(t.x, t.y) or
                (input_mod.turn_direction(t.x, s.app.input.width) < 0 and s.current == 0),
            // Text settings and closing don't count pages; the toolbar's other buttons do
            .toolbar => switch (toolbar.hit(t.x, t.y, sheet)) {
                .sheet, .close, .stay, .text => false,
                .home, .goto, .bookmark, .search, .more => true,
                .chapter_prev, .chapter_next, .scrub => true,
            },
            // A note's panel and a highlight's handles act on the page on screen
            .note, .highlight => false,
        },
        .swipe => |swipe| swipe.direction < 0 and s.current == 0,
        // Locking, waking and leaving don't count pages, and must not wait for them;
        // nor does holding a word, which looks it up on the page on screen, the
        // charger's bolt, or the quick panel, which only covers the page
        .lock, .unlock, .power, .computer, .stop, .hold, .charger, .pull => false,
    };
}

test "the charger, the quick panel, and taps on a note or a highlight never wait for layout" {
    // A first open still being laid out: none of these reads the session's app or layout
    var progress: paginate.Progressive = undefined;
    const pages = [_]book_model.Pos{.{}};
    const s = sess.Session{
        .app = undefined,
        .paragraphs = &.{},
        .pages = &pages,
        .current = 0,
        .anchor = .{},
        .progress = &progress,
        .place = undefined, // Never saved: only taps are asked of it
    };
    try std.testing.expect(!needs_all_pages(.charger, .page, null, &s));
    try std.testing.expect(!needs_all_pages(.pull, .page, null, &s));
    const tap: input_mod.Action = .{ .tap = .{ .x = 0, .y = 0, .us = 0 } }; // Anywhere
    try std.testing.expect(!needs_all_pages(tap, .note, null, &s));
    const highlight: View = .{ .highlight = .{ .id = "h1" } };
    try std.testing.expect(!needs_all_pages(tap, highlight, null, &s));
}
