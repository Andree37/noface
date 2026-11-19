//! The Back button: where the reader was before jumping elsewhere (Go To, a search, a
//! chapter, the slider, a link), and the button on the page that returns there. The
//! first place is kept through several jumps, and let go after `turns_max` turns from
//! the jump, or on arriving back there. This file keeps the place and draws the button;
//! the session says when the reader moves and puts the button on its pages.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const Page = @import("../../gfx/page.zig").Page;
const Font = @import("../../gfx/font.zig").Font;
const draw = @import("../../ui/draw.zig");
const icons = @import("../../ui/icons.zig");
const style = @import("../../ui/style.zig");
const Zone = @import("../../kindle/input.zig").Zone;

/// Turns from a jump after which the button goes: the reader is reading there.
const turns_max = 10;
/// The button, at the bottom left over the footer.
const x_px = 40;
const width_px = 330;
const height_px = 84;
pub const above_bottom_px = 112; // From the button's top to the screen's bottom
/// A fingertip's margin around the button, where a touch still counts.
const reach_px = 12;
/// Inside the button: its arrow's middle and its label's left, in from its left.
const arrow_inset_px = 44;
const label_inset_px = 80;
/// The footer cleared round it: from this far over it, to this far right of it.
pub const clear_above_px = 8;
const clear_right_px = 24;

comptime {
    assert(turns_max > 0);
    // The button and its fingertip margin stay on the screen
    assert(x_px >= reach_px);
    assert(above_bottom_px > height_px);
    assert(x_px + width_px + clear_right_px < style.screen.width_px);
    assert(arrow_inset_px < label_inset_px);
    assert(label_inset_px < width_px);
}

/// How the reader got to a page: reading on, a page at a time, or a jump (Go To, a
/// search, a chapter, the slider, Back), which the button remembers.
pub const Move = enum { turn, jump };

pub const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

pub const Back = struct {
    /// Where the reader was before the first jump kept; null with no button.
    place: ?book_model.Pos = null,
    turns_since_jump: u32 = 0,

    /// Keeps the place up to date for a move from page `from` to page `to`: a jump
    /// remembers where the reader was (unless an earlier jump's place is still kept),
    /// arriving back there lets go of it, and so does reading on a while. `settled` is
    /// whether page numbers are final (the whole book laid out): until then an earlier
    /// place would look like page 0, so nothing is let go of on arriving. True when the
    /// button came or went, so pages drawn with or without it are stale.
    pub fn note_move(
        b: *Back,
        pages: []const book_model.Pos,
        from: u32,
        to: u32,
        move: Move,
        settled: bool,
    ) bool {
        assert(from < pages.len);
        assert(to < pages.len);
        const shown_before = b.place != null;
        const turning = move == .turn;
        if (b.place) |kept| {
            if (settled and book_model.page_containing(pages, kept.para, kept.byte) == to) {
                b.place = null; // Back where they were, however they got there
            } else if (to == from) {
                // Drawn again in place: nothing moved
            } else if (turning) {
                b.turns_since_jump += 1;
                if (b.turns_since_jump >= turns_max) b.place = null; // Reading here now
            } else {
                b.turns_since_jump = 0; // Another jump: the count starts again from here
            }
        } else if (!turning and to != from) {
            b.place = pages[from];
            b.turns_since_jump = 0;
        }
        if (b.place == null) assert(shown_before or turning or to == from);
        return shown_before != (b.place != null);
    }

    /// The page the button returns to.
    pub fn page(b: Back, pages: []const book_model.Pos) ?u32 {
        const kept = b.place orelse return null;
        const index = book_model.page_containing(pages, kept.para, kept.byte);
        assert(index < pages.len);
        return index;
    }

    /// Where touches count as the button although the thumb filter is on there: its
    /// rectangle and a fingertip around it. Null with no button.
    pub fn zone(b: Back, screen_height: u32) ?Zone {
        if (b.place == null) return null;
        const r = rect(screen_height);
        assert(r.x >= reach_px);
        assert(r.y >= reach_px);
        return .{
            .x = @as(i32, @intCast(r.x)) - reach_px,
            .y = @as(i32, @intCast(r.y)) - reach_px,
            .w = @intCast(r.width + 2 * reach_px),
            .h = @intCast(r.height + 2 * reach_px),
        };
    }

    /// Whether a touch at x, y is on the button, a fingertip's margin around it counted.
    pub fn hit(b: Back, screen_height: u32, x: i32, y: i32) bool {
        const z = b.zone(screen_height) orelse return false;
        assert(z.w > 0);
        assert(z.h > 0);
        return x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h;
    }

    /// Draws the button over the footer of a page: "Back to p. 12" once page numbers
    /// are final, "Back" until then.
    pub fn draw_on(
        b: Back,
        target: Page,
        font: *Font,
        pages: []const book_model.Pos,
        settled: bool,
    ) !void {
        // Drawn only while there's somewhere to go back to
        assert(b.place != null);
        const r = rect(target.height);
        assert(r.y >= clear_above_px);
        // Over the footer's text there
        const clear_top = r.y - clear_above_px;
        const clear_width = r.x + r.width + clear_right_px;
        target.fill_rect(0, clear_top, clear_width, target.height - clear_top, style.white);
        draw.box(target, r.x, r.y, r.width, r.height);
        var label_buffer: [32]u8 = undefined;
        var label: []const u8 = "Back";
        if (settled) {
            const number = b.page(pages).? + 1;
            label = std.fmt.bufPrint(&label_buffer, "Back to p. {d}", .{number}) catch "Back";
        }
        const center_y: f32 = @floatFromInt(r.y + r.height / 2);
        icons.back(target, @floatFromInt(r.x + arrow_inset_px), center_y);
        const label_x: f32 = @floatFromInt(r.x + label_inset_px);
        const baseline: i32 = @intFromFloat(center_y + draw.back_link.label_drop);
        try font.draw(target, label_x, baseline, label);
    }
};

/// The middle of the button, on a screen this tall.
pub fn place(screen_height: u32) style.Point {
    const r = rect(screen_height);
    return .{ .x = @intCast(r.x + r.width / 2), .y = @intCast(r.y + r.height / 2) };
}

/// The button's place on a screen: the bottom left, over the footer.
fn rect(screen_height: u32) Rect {
    assert(screen_height > above_bottom_px);
    assert(above_bottom_px >= clear_above_px);
    return .{
        .x = x_px,
        .y = screen_height - above_bottom_px,
        .width = width_px,
        .height = height_px,
    };
}

test "a jump keeps the place left, arriving back or reading on lets go of it" {
    // Ten pages of one paragraph each: the place left is page 2's start
    var pages: [20]book_model.Pos = undefined;
    for (&pages, 0..) |*p, i| p.* = .{ .para = @intCast(i) };
    var b: Back = .{};
    try std.testing.expect(!b.note_move(&pages, 2, 3, .turn, true)); // Turning: no button
    try std.testing.expect(b.note_move(&pages, 2, 9, .jump, true)); // The button comes
    try std.testing.expectEqual(@as(?u32, 2), b.page(&pages));
    // A second jump keeps the first place
    try std.testing.expect(!b.note_move(&pages, 9, 5, .jump, true));
    try std.testing.expectEqual(@as(?u32, 2), b.page(&pages));
    // Arriving back, by turning even, lets go of it
    try std.testing.expect(!b.note_move(&pages, 5, 4, .turn, true));
    try std.testing.expect(b.note_move(&pages, 4, 2, .turn, true));
    try std.testing.expectEqual(@as(?u32, null), b.page(&pages));
    // Reading on for `turns_max` turns lets go of it too
    try std.testing.expect(b.note_move(&pages, 2, 9, .jump, true));
    for (0..turns_max - 1) |i| {
        const from: u32 = @intCast(9 + i);
        try std.testing.expect(!b.note_move(&pages, from, from + 1, .turn, true));
    }
    try std.testing.expect(b.note_move(&pages, 18, 19, .turn, true));
    try std.testing.expectEqual(@as(?u32, null), b.page(&pages));
}

test "the button's place is a touch on it" {
    const b: Back = .{ .place = .{} };
    const p = place(style.screen_height);
    try std.testing.expect(b.hit(style.screen_height, p.x, p.y));
}

test "the button takes a fingertip's touches around it, and none with no place kept" {
    const height = style.screen.height_px;
    var b: Back = .{};
    const r = rect(height);
    const middle_x: i32 = @intCast(r.x + r.width / 2);
    const middle_y: i32 = @intCast(r.y + r.height / 2);
    try std.testing.expect(!b.hit(height, middle_x, middle_y));
    b.place = .{};
    try std.testing.expect(b.hit(height, middle_x, middle_y));
    try std.testing.expect(b.hit(height, @intCast(r.x - reach_px), middle_y));
    try std.testing.expect(!b.hit(height, @intCast(r.x - reach_px - 1), middle_y));
}
