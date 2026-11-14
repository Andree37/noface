//! Making, extending and deleting highlights on the page.
const std = @import("std");
const book_model = @import("../../model/book.zig");
const draw = @import("../../ui/draw.zig");
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

pub fn save_highlight(s: *sess.Session, entry: *const catalog.Entry, id: []const u8, span: highlights.Span) bool {
    const start = records.point_for(s, span.first_para, span.first_byte) orelse return false;
    const end = records.point_for(s, span.last_para, span.last_byte) orelse return false;
    return records.write(s, entry, .highlight, id, start, end);
}

pub fn page_words(a: *app.App, s: *const sess.Session) []const book_model.Word {
    const slot = a.slot_for(s.current) orelse return &.{};
    return slot.hits.words[0..slot.hits.word_count];
}

/// Rebuilds the marks drawn on pages, after highlights change.
pub fn refresh_marks(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !void {
    s.marks.clearRetainingCapacity(); // One list, reused, rather than a new one each time
    for (s.highlights.items) |h| try s.marks.append(alloc, h.mark);
    a.layout.marks = s.marks.items;
    a.forget_pages();
}

/// Shows the page, with handles on a highlight when one is active.
pub fn show_page(a: *app.App, s: *sess.Session, active: ?[]const u8) !?usize {
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    a.stamp_clock();
    var delete_top: ?usize = null;
    if (active) |id| {
        const words = page_words(a, s);
        if (highlights.word_range(words, s.highlights.items, id)) |r| {
            const screen_page = a.page(a.screen.pixels);
            const chosen = words[r.lo .. r.hi + 1];
            selection.draw(screen_page, chosen);
            const band = selection.band(chosen);
            delete_top = try draw_delete_bubble(a, band);
        }
    }
    try a.screen.wait_complete(try a.screen.show(.page));
    return delete_top;
}

/// Takes a failed selection back off the page and says so.
pub fn highlight_not_saved(a: *app.App, s: *sess.Session) !void {
    _ = try show_page(a, s, null);
    try app.show_notice(a, "This highlight couldn't be saved.");
    _ = try show_page(a, s, null);
}

pub const bubble_width = 240;

pub const bubble_height = 96;

pub fn draw_delete_bubble(a: *app.App, band: selection.Band) !usize {
    const screen_page = a.page(a.screen.pixels);
    const below = band.top + band.height + 12;
    const top: u32 = if (below + bubble_height < a.screen.height - 130) below else band.top -| (bubble_height + 12);
    const left = (a.screen.width - bubble_width) / 2;
    screen_page.fill_rect(left - 4, top - 4, bubble_width + 8, bubble_height + 8, 0xff);
    draw.box(screen_page, left, top, bubble_width, bubble_height);
    try draw.centered(a.ui.small, screen_page, @floatFromInt(a.screen.width / 2), @intCast(top + 62), "Delete");
    return top;
}

pub fn in_delete_bubble(a: *app.App, top: usize, x: i32, y: i32) bool {
    const left: i32 = @intCast((a.screen.width - bubble_width) / 2);
    const t: i32 = @intCast(top);
    return x >= left and x < left + bubble_width and y >= t and y < t + bubble_height;
}

/// Follows a finger, keeping `fixed` in place, and returns where it stopped; null
/// when the selection was cut short, by the Kindle locking say, and isn't one.
pub fn drag_selection(a: *app.App, words: []const book_model.Word, fixed: usize, moving: usize) !?usize {
    var head = moving;
    @memcpy(a.lock_cover, a.screen.pixels);
    a.page(a.lock_cover).threshold(0, a.screen.height); // Pure black and white for A2
    var previous = try paint_selection(a, words, fixed, head, .{ .top = 0, .height = 0 });
    const Follow = struct {
        a: *app.App,
        words: []const book_model.Word,
        fixed: usize,
        head: *usize,
        previous: *selection.Band,
        pub fn moved(f: @This(), x: i32, y: i32) !?u32 {
            const next = selection.word_at(f.words, x, y) orelse return null;
            if (next == f.head.*) return null;
            f.head.* = next;
            f.previous.* = try paint_selection(f.a, f.words, f.fixed, next, f.previous.*);
            return f.a.screen.next_marker - 1;
        }
    };
    a.lock_cover_key = 0; // Used as scratch above: the lock screen's cover is gone
    if (!try app.follow_drag(a, a.screen.next_marker - 1, Follow{ .a = a, .words = words, .fixed = fixed, .head = &head, .previous = &previous })) return null;
    return head;
}

/// Underlines from `first` to `last`, redrawing the band the old and new selections cover.
fn paint_selection(a: *app.App, list: []const book_model.Word, first: usize, last: usize, old: selection.Band) !selection.Band {
    const lo = @min(first, last);
    const hi = @max(first, last);
    const chosen = list[lo .. hi + 1];
    const now = selection.band(chosen);
    const top = if (old.height == 0) now.top else @min(old.top, now.top);
    const bottom = @min(@max(old.top + old.height, now.top + now.height), a.screen.height);
    const stride = a.screen.stride;
    @memcpy(a.screen.pixels[top * stride .. bottom * stride], a.lock_cover[top * stride .. bottom * stride]);
    selection.draw(a.page(a.screen.pixels), chosen);
    _ = try a.screen.show_region(0, top, a.screen.width, bottom - top, .quick);
    return now;
}

/// Press and hold: follows the finger from the word held, and says which words it
/// covered when it lifted. Null when the hold wasn't on a word.
pub fn select_from_hold(a: *app.App, s: *sess.Session, hold_x: i32, hold_y: i32) !?struct { fixed: usize, head: usize } {
    const words = page_words(a, s);
    const fixed = selection.word_at(words, hold_x, hold_y) orelse return null;
    const head = try drag_selection(a, words, fixed, fixed) orelse {
        _ = try show_page(a, s, null); // Takes the unfinished selection off
        return null;
    };
    return .{ .fixed = fixed, .head = head };
}

/// Makes a new highlight of the page's words from `fixed` to `head`, either way round.
pub fn new_highlight(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry, fixed: usize, head: usize) !?[]const u8 {
    const words = page_words(a, s);
    const lo = words[@min(fixed, head)];
    const hi = words[@max(fixed, head)];
    const start = records.point_for(s, lo.para, lo.start) orelse {
        try highlight_not_saved(a, s);
        return null;
    };
    const id = try highlights.free_id(alloc, s.highlights.items, start.short);
    const saved = save_highlight(s, entry, id, highlights.Span.of(lo, hi));
    if (saved) records.sync();
    std.debug.print("highlight {s}: {d} words, saved {}\n", .{ id, @max(fixed, head) - @min(fixed, head) + 1, saved });
    if (!saved) {
        try highlight_not_saved(a, s);
        return null;
    }
    try highlights.add(&s.highlights, alloc, s.paragraphs, id, highlights.Span.of(lo, hi));
    try refresh_marks(a, s, alloc);
    return id;
}

/// Drags one end of a highlight. The record keeps its ID, so it extends in place.
pub fn extend_highlight(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry, id: []const u8, grab_start: bool) !void {
    const words = page_words(a, s);
    const range = highlights.word_range(words, s.highlights.items, id) orelse return;
    const whole = highlights.extent(s.highlights.items, id) orelse return;
    a.input.begin_drag();
    const fixed = if (grab_start) range.hi else range.lo;
    const moving = if (grab_start) range.lo else range.hi;
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
}

/// Deletes a highlight here and, through sync, everywhere.
pub fn remove_highlight(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, entry: *const catalog.Entry, id: []const u8) !void {
    const removed = records.delete(s, entry, .highlight, id);
    std.debug.print("highlight removed: {}\n", .{removed});
    if (!removed) return app.show_notice(a, "This highlight couldn't be deleted.");
    records.sync();
    highlights.remove(&s.highlights, id);
    try refresh_marks(a, s, alloc);
}
