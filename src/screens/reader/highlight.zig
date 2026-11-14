//! Making, extending and deleting highlights on the page.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const draw = @import("../../ui/draw.zig");
const style = @import("../../ui/style.zig");
const catalog = @import("../../model/catalog.zig");
const os = @import("../../sys/os.zig");
const highlights = @import("../../model/highlights.zig");
const selection = @import("../../ui/selection.zig");
const annotation_db = @import("../../kindle/annotation_db.zig");
const lipc = @import("../../kindle/lipc.zig");
const failed = os.failed;
const app = @import("../../app.zig");
const sess = @import("session.zig");
const records = @import("records.zig");

pub const bubble_width = 240;
pub const bubble_height = 96;
/// Between the selection and the Delete bubble.
const bubble_gap = 12;
/// The white edge cleared around the bubble, so it stands off the text under it.
const bubble_border = 4;
/// Where "Delete" sits, down from the bubble's top.
const bubble_label_baseline = 62;
/// Kept clear at the bottom of the screen: a bubble that would reach into it goes
/// above the selection instead.
const bubble_bottom_clear = 130;

comptime {
    assert(bubble_width + 2 * bubble_border <= style.screen_width);
    assert(bubble_label_baseline < bubble_height);
    assert(bubble_height + bubble_gap + bubble_bottom_clear < style.screen_height);
}

pub fn save_highlight(
    s: *sess.Session,
    entry: *const catalog.Entry,
    id: []const u8,
    span: highlights.Span,
) bool {
    assert(span.first_para < s.paragraphs.len);
    assert(span.last_para < s.paragraphs.len);
    const start = records.point_for(s, span.first_para, span.first_byte) orelse return false;
    const end = records.point_for(s, span.last_para, span.last_byte) orelse return false;
    return records.write(s, entry, .highlight, id, start, end);
}

pub fn page_words(a: *app.App, s: *const sess.Session) []const book_model.Word {
    assert(s.current < s.pages.len);
    const slot = a.slot_for(s.current) orelse return &.{};
    assert(slot.hits.word_count <= slot.hits.words.len);
    return slot.hits.words[0..slot.hits.word_count];
}

/// Rebuilds the marks drawn on pages, after highlights change.
pub fn refresh_marks(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !void {
    s.marks.clearRetainingCapacity(); // One list, reused, rather than a new one each time
    for (s.highlights.items) |h| try s.marks.append(alloc, h.mark);
    assert(s.marks.items.len == s.highlights.items.len);
    a.layout.marks = s.marks.items;
    // Layout reads the session's list itself, so the two can't drift apart
    assert(a.layout.marks.ptr == s.marks.items.ptr);
    a.forget_pages();
}

/// Shows the page, with handles on a highlight when one is active.
pub fn show_page(a: *app.App, s: *sess.Session, active: ?[]const u8) !?usize {
    assert(s.current < s.pages.len);
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    a.stamp_clock();
    var delete_top: ?u32 = null;
    if (active) |id| {
        const words = page_words(a, s);
        if (highlights.word_range(words, s.highlights.items, id)) |range| {
            assert(range.lo <= range.hi);
            assert(range.hi < words.len);
            const screen_page = a.page(a.screen.pixels);
            const chosen = words[range.lo .. range.hi + 1];
            selection.draw(screen_page, chosen);
            const band = selection.band(chosen);
            delete_top = try draw_delete_bubble(a, band);
        }
    }
    try a.screen.wait_complete(try a.screen.show(.page));
    return if (delete_top) |top| top else null;
}

/// Takes a failed selection back off the page and says so.
pub fn highlight_not_saved(a: *app.App, s: *sess.Session) !void {
    assert(s.current < s.pages.len);
    _ = try show_page(a, s, null);
    try app.show_notice(a, "This highlight couldn't be saved.");
    _ = try show_page(a, s, null);
}

/// Draws the Delete bubble under the selection, or above it when there's no room
/// below. Returns its top, for in_delete_bubble.
pub fn draw_delete_bubble(a: *app.App, band: selection.Band) !u32 {
    assert(a.screen.width >= bubble_width + 2 * bubble_border);
    const screen_page = a.page(a.screen.pixels);
    const below = band.top + band.height + bubble_gap;
    const room_below = below + bubble_height < a.screen.height - bubble_bottom_clear;
    const top: u32 = if (room_below) below else band.top -| (bubble_height + bubble_gap);
    assert(top + bubble_height <= a.screen.height);
    const left = (a.screen.width - bubble_width) / 2;
    const border_width = bubble_width + 2 * bubble_border;
    const border_height = bubble_height + 2 * bubble_border;
    // Saturating: a highlight from the page's first line to near its last puts the
    // bubble at the very top, where `top - 4` would overflow and stop noface
    const border_top = top -| bubble_border;
    screen_page.fill_rect(left - bubble_border, border_top, border_width, border_height, 0xff);
    draw.box(screen_page, left, top, bubble_width, bubble_height);
    const center_x: f32 = @floatFromInt(a.screen.width / 2);
    const label_y: i32 = @intCast(top + bubble_label_baseline);
    try draw.centered(a.ui.small, screen_page, center_x, label_y, "Delete");
    return top;
}

pub fn in_delete_bubble(a: *app.App, top: usize, x: i32, y: i32) bool {
    // Where draw_delete_bubble put it: across the middle, inside the screen
    assert(a.screen.width >= bubble_width);
    assert(top + bubble_height <= a.screen.height);
    const left: i32 = @intCast((a.screen.width - bubble_width) / 2);
    const t: i32 = @intCast(top);
    return x >= left and x < left + bubble_width and y >= t and y < t + bubble_height;
}

/// Follows a finger, keeping `fixed` in place, and returns where it stopped; null
/// when the selection was cut short, by the Kindle locking say, and isn't one.
pub fn drag_selection(
    a: *app.App,
    words: []const book_model.Word,
    fixed: u32,
    moving: u32,
) !?u32 {
    assert(fixed < words.len);
    assert(moving < words.len);
    var head = moving;
    @memcpy(a.lock_cover, a.screen.pixels);
    a.page(a.lock_cover).threshold(0, a.screen.height); // Pure black and white for A2
    var previous = try paint_selection(a, words, fixed, head, .{ .top = 0, .height = 0 });
    const Follow = struct {
        a: *app.App,
        words: []const book_model.Word,
        fixed: u32,
        head: *u32,
        previous: *selection.Band,
        pub fn moved(f: @This(), x: i32, y: i32) !?u32 {
            assert(f.fixed < f.words.len);
            const next = selection.word_at(f.words, x, y) orelse return null;
            assert(next < f.words.len);
            if (next == f.head.*) return null;
            f.head.* = @intCast(next);
            f.previous.* = try paint_selection(f.a, f.words, f.fixed, f.head.*, f.previous.*);
            return f.a.screen.next_marker - 1;
        }
    };
    a.lock_cover_key = 0; // Used as scratch above: the lock screen's cover is gone
    const follow = Follow{
        .a = a,
        .words = words,
        .fixed = fixed,
        .head = &head,
        .previous = &previous,
    };
    if (!try app.follow_drag(a, a.screen.next_marker - 1, follow)) return null;
    assert(head < words.len);
    return head;
}

/// Underlines from `first` to `last`, redrawing the band the old and new selections cover.
fn paint_selection(
    a: *app.App,
    words: []const book_model.Word,
    first: u32,
    last: u32,
    old: selection.Band,
) !selection.Band {
    assert(first < words.len);
    assert(last < words.len);
    const chosen = words[@min(first, last) .. @max(first, last) + 1];
    const now = selection.band(chosen);
    const top = if (old.height == 0) now.top else @min(old.top, now.top);
    const bottom = @min(@max(old.top + old.height, now.top + now.height), a.screen.height);
    assert(top <= bottom);
    const stride = a.screen.stride;
    const band_start = top * stride;
    const band_end = bottom * stride;
    @memcpy(a.screen.pixels[band_start..band_end], a.lock_cover[band_start..band_end]);
    selection.draw(a.page(a.screen.pixels), chosen);
    _ = try a.screen.show_region(0, top, a.screen.width, bottom - top, .quick);
    return now;
}

/// Press and hold: follows the finger from the word held, and says which words it
/// covered when it lifted. Null when the hold wasn't on a word.
pub fn select_from_hold(
    a: *app.App,
    s: *sess.Session,
    hold_x: i32,
    hold_y: i32,
) !?struct { fixed: usize, head: usize } {
    const words = page_words(a, s);
    const fixed = selection.word_at(words, hold_x, hold_y) orelse return null;
    assert(fixed < words.len);
    const head = try drag_selection(a, words, @intCast(fixed), @intCast(fixed)) orelse {
        _ = try show_page(a, s, null); // Takes the unfinished selection off
        return null;
    };
    assert(head < words.len);
    return .{ .fixed = fixed, .head = head };
}

/// Makes a new highlight of the page's words from `fixed` to `head`, either way round.
pub fn new_highlight(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    fixed: usize,
    head: usize,
) !?[]const u8 {
    const words = page_words(a, s);
    assert(fixed < words.len);
    assert(head < words.len);
    const lo = words[@min(fixed, head)];
    const hi = words[@max(fixed, head)];
    const start = records.point_for(s, lo.para, lo.start) orelse {
        try highlight_not_saved(a, s);
        return null;
    };
    const id = try highlights.free_id(alloc, s.highlights.items, start.short);
    const saved = save_highlight(s, entry, id, highlights.Span.of(lo, hi));
    if (saved) records.sync();
    const word_count = @max(fixed, head) - @min(fixed, head) + 1;
    std.debug.print("highlight {s}: {d} words, saved {}\n", .{ id, word_count, saved });
    if (!saved) {
        try highlight_not_saved(a, s);
        return null;
    }
    try highlights.add(&s.highlights, alloc, s.paragraphs, id, highlights.Span.of(lo, hi));
    try refresh_marks(a, s, alloc);
    assert(highlights.extent(s.highlights.items, id) != null);
    return id;
}

/// Drags one end of a highlight. The record keeps its ID, so it extends in place.
pub fn extend_highlight(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    id: []const u8,
    grab_start: bool,
) !void {
    const words = page_words(a, s);
    const range = highlights.word_range(words, s.highlights.items, id) orelse return;
    const whole = highlights.extent(s.highlights.items, id) orelse return;
    assert(range.lo <= range.hi);
    assert(range.hi < words.len);
    a.input.begin_drag();
    const fixed: u32 = @intCast(if (grab_start) range.hi else range.lo);
    const moving: u32 = @intCast(if (grab_start) range.lo else range.hi);
    const head = try drag_selection(a, words, fixed, moving) orelse {
        _ = try show_page(a, s, id); // Back to the highlight as it was
        return;
    };
    if (head == moving) return; // Touched without moving, so nothing changed
    const crossed = if (grab_start) head > fixed else head < fixed;
    const span = highlights.dragged(whole, words[fixed], words[head], grab_start, crossed);
    const saved = save_highlight(s, entry, id, span);
    if (saved) records.sync();
    std.debug.print("highlight extended: saved {}\n", .{saved});
    if (!saved) return app.show_notice(a, "This highlight couldn't be changed.");
    highlights.remove(&s.highlights, id);
    try highlights.add(&s.highlights, alloc, s.paragraphs, id, span);
    try refresh_marks(a, s, alloc);
    assert(highlights.extent(s.highlights.items, id) != null);
}

/// Deletes a highlight here and, through sync, everywhere.
pub fn remove_highlight(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    id: []const u8,
) !void {
    // Only a highlight on the page has a Delete bubble to tap
    assert(highlights.extent(s.highlights.items, id) != null);
    const removed = records.delete(s, entry, .highlight, id);
    std.debug.print("highlight removed: {}\n", .{removed});
    if (!removed) return app.show_notice(a, "This highlight couldn't be deleted.");
    records.sync();
    highlights.remove(&s.highlights, id);
    try refresh_marks(a, s, alloc);
    assert(highlights.extent(s.highlights.items, id) == null);
}
