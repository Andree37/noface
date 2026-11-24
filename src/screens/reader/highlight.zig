//! Making, extending and deleting highlights on the page.
const std = @import("std");
const assert = std.debug.assert;
const drag = @import("../drag.zig");
const book_model = @import("../../model/book.zig");
const draw = @import("../../ui/draw.zig");
const style = @import("../../ui/style.zig");
const highlights = @import("../../model/highlights.zig");
const selection = @import("../../ui/selection.zig");
const app = @import("../../app.zig");
const placed = @import("../placed.zig");
const screen = @import("../screen.zig");
const sess = @import("session.zig");
const records = @import("records.zig");

pub const bubble_width = style.space.band + style.space.tall;
pub const bubble_height = style.space.band;
/// Between the selection and the Delete bubble.
const bubble_gap = style.space.small;
/// The white edge cleared around the bubble, so it stands off the text under it.
const bubble_border = style.space.hair;
/// How far a glyph may reach past its word's box, at either side.
const glyph_overhang = style.space.hair;
/// Kept clear at the bottom of the screen: a bubble that would reach into it goes
/// above the selection instead.
const bubble_bottom_clear = style.space.tall;

comptime {
    assert(bubble_width + 2 * bubble_border <= style.screen_width);
    assert(bubble_height + bubble_gap + bubble_bottom_clear < style.screen_height);
}

pub fn save_highlight(
    s: *sess.Session,
    id: []const u8,
    span: highlights.Span,
) bool {
    assert(span.first_para < s.paragraphs.len);
    assert(span.last_para < s.paragraphs.len);
    const start = records.point_for(s, span.first_para, span.first_byte) orelse return false;
    const end = records.point_for(s, span.last_para, span.last_byte) orelse return false;
    return s.notes.store.put(.highlight, id, start, end);
}

/// Rebuilds the marks drawn on pages, after highlights change.
pub fn refresh_marks(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !void {
    try s.notes.rebuild_marks(alloc);
    assert(s.notes.marks.items.len == s.notes.highlights.items.len);
    a.display.forget_pages(); // Drawn again with the marks as they are now
}

/// Shows the page, with handles on a highlight when one is active.
pub fn show_page(a: *app.App, s: *sess.Session, active: ?[]const u8) !?u32 {
    assert(s.current < s.pages.len);
    @memcpy(a.display.screen.pixels, try s.ensure(s.current, s.current));
    a.stamp_clock();
    var delete_top: ?u32 = null;
    if (active) |id| {
        const words = s.page_words();
        if (highlights.word_range(words, s.notes.highlights.items, id)) |range| {
            assert(range.lo <= range.hi);
            assert(range.hi < words.len);
            const screen_page = a.display.on_screen();
            const chosen = words[range.lo .. range.hi + 1];
            selection.draw(screen_page, chosen);
            const band = selection.band(chosen);
            delete_top = try draw_delete_bubble(a, band, words);
            if (a.logs_placed) placed.note(.delete, delete_place(a, delete_top.?));
        }
    }
    try a.display.screen.wait_complete(try a.display.screen.show(.page));
    if (delete_top) |top| assert(top < a.display.screen.height);
    return delete_top;
}

/// Takes a failed selection back off the page and says so.
pub fn highlight_not_saved(a: *app.App, s: *sess.Session) !void {
    assert(s.current < s.pages.len);
    _ = try show_page(a, s, null);
    app.show_notice(a, "This highlight couldn't be saved.");
    _ = try show_page(a, s, null);
}

/// Draws the Delete bubble under the selection, or above it when there's no room
/// below, over `words`, the page's. Returns its top, for in_delete_bubble.
pub fn draw_delete_bubble(
    a: *app.App,
    band: selection.Band,
    words: []const book_model.Word,
) !u32 {
    assert(a.display.screen.width >= bubble_width + 2 * bubble_border);
    assert(band.height > 0);
    const screen_page = a.display.on_screen();
    const top = bubble_top(band, words, a.display.screen.height);
    assert(top + bubble_height <= a.display.screen.height);
    const left = (a.display.screen.width - bubble_width) / 2;
    const border_width = bubble_width + 2 * bubble_border;
    const border_height = bubble_height + 2 * bubble_border;
    // Saturating: a highlight from the page's first line to near its last puts the
    // bubble at the very top, where `top - bubble_border` would overflow and stop noface
    const border_top = top -| bubble_border;
    const clear = Box{
        .left = left - bubble_border,
        .top = border_top,
        .width = border_width,
        .height = border_height,
    };
    // Words it would cut across go whole, so no line shows through half its height
    for (words) |w| {
        const word_box = Box.of_word(w);
        if (!word_box.overlaps(clear)) continue;
        // A glyph may reach a pixel or two past its word's box: cleared too, inside the
        // space between words
        const left_wide = word_box.left -| glyph_overhang;
        const width_wide = word_box.width + (word_box.left - left_wide) + glyph_overhang;
        screen_page.fill_rect(left_wide, word_box.top, width_wide, word_box.height, style.white);
    }
    screen_page.fill_rect(clear.left, clear.top, clear.width, clear.height, style.white);
    draw.box(screen_page, left, top, bubble_width, bubble_height);
    const center_x: f32 = @floatFromInt(a.display.screen.width / 2);
    const label_y = a.ui.small.centred_baseline(@intCast(top), bubble_height);
    try draw.centered(a.ui.small, screen_page, center_x, label_y, "Delete");
    return top;
}

/// Where the Delete bubble's top goes: on the line grid, so its edges fall between
/// lines rather than through one. Below the selection and its handles, at the first
/// line clear of them; else above, ending with the last line clear of them.
fn bubble_top(band: selection.Band, words: []const book_model.Word, screen_height: u32) u32 {
    assert(band.height > 0);
    assert(screen_height > bubble_height + bubble_gap + bubble_bottom_clear);
    const band_bottom = band.top + band.height;
    var line_below: ?u32 = null; // The top of the first line under the band
    var line_above: ?u32 = null; // The bottom of the last line over it
    for (words) |w| {
        const box = Box.of_word(w);
        const bottom = box.top + box.height;
        if (box.top >= band_bottom) line_below = @min(line_below orelse box.top, box.top);
        if (bottom <= band.top) line_above = @max(line_above orelse bottom, bottom);
    }
    // No line there (a picture, the page's edge): a gap's distance from the band
    const below = (line_below orelse band_bottom + bubble_gap) + bubble_border;
    if (below + bubble_height + bubble_border < screen_height - bubble_bottom_clear) return below;
    const above = (line_above orelse band.top -| bubble_gap) -| (bubble_height + bubble_border);
    assert(above + bubble_height <= screen_height);
    return above;
}

/// A rectangle on the screen, for what the Delete bubble clears.
const Box = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,

    fn of_word(w: book_model.Word) Box {
        assert(w.w >= 0);
        assert(w.h >= 0);
        return .{
            .left = @intCast(@max(w.x, 0)),
            .top = @intCast(@max(w.y, 0)),
            .width = @intCast(w.w),
            .height = @intCast(w.h),
        };
    }

    fn overlaps(b: Box, other: Box) bool {
        // The bubble's: never empty, so a word touching it is found
        assert(other.width > 0);
        assert(other.height > 0);
        const across = b.left < other.left + other.width and other.left < b.left + b.width;
        const down = b.top < other.top + other.height and other.top < b.top + b.height;
        return across and down;
    }
};

/// The middle of the Delete bubble's taps, drawn with its top at `top`.
fn delete_place(a: *app.App, top: u32) style.Point {
    const point: style.Point = .{
        .x = @intCast(a.display.screen.width / 2),
        .y = @intCast(top + bubble_height / 2),
    };
    assert(in_delete_bubble(a, top, point.x, point.y));
    return point;
}

pub fn in_delete_bubble(a: *app.App, top: u32, x: i32, y: i32) bool {
    // Where draw_delete_bubble put it: across the middle, inside the screen
    assert(a.display.screen.width >= bubble_width);
    assert(top + bubble_height <= a.display.screen.height);
    const left: i32 = @intCast((a.display.screen.width - bubble_width) / 2);
    const t: i32 = @intCast(top);
    return x >= left and x < left + bubble_width and y >= t and y < t + bubble_height;
}

/// A selection following a finger, kept while it's open over the page: `fixed` stays
/// in place, and `head` is the word the finger is on.
pub const Selecting = struct {
    /// The page under a selection, in pure black and white for quick refreshes: the
    /// book's own, taken as it opens (`Reader.open`).
    clean: []u8 = &.{},
    words: []const book_model.Word = &.{},
    fixed: u32 = 0,
    moving: u32 = 0, // Where the head began
    head: u32 = 0,
    previous: selection.Band = .{ .top = 0, .height = 0 },
    drag: drag.Drag(SelectionFollow) = undefined,
    ending: ?screen.Ending(void) = null,
    /// While a highlight's end is dragged: which highlight, all of it, and which end.
    extending: ?struct { id: []const u8, whole: highlights.Span, grab_start: bool } = null,
};

const SelectionFollow = struct {
    a: *app.App,
    clean: []const u8,
    words: []const book_model.Word,
    fixed: u32,
    head: *u32,
    previous: *selection.Band,

    pub fn moved(f: SelectionFollow, x: i32, y: i32) !?u32 {
        assert(f.fixed < f.words.len);
        const next = selection.word_at(f.words, x, y) orelse return null;
        assert(next < f.words.len);
        if (next == f.head.*) return null;
        f.head.* = next;
        f.previous.* = try paint_selection(f.a, f.clean, f.words, f.fixed, f.head.*, f.previous.*);
        return f.a.display.screen.next_marker - 1;
    }
};

/// Starts following a finger, keeping `fixed` in place: the screen to open over the
/// page. `drag_selection_ended` says where it stopped.
fn drag_selection(
    sel: *Selecting,
    a: *app.App,
    words: []const book_model.Word,
    fixed: u32,
    moving: u32,
) !screen.Frame {
    assert(fixed < words.len);
    assert(moving < words.len);
    sel.words = words;
    sel.fixed = fixed;
    sel.moving = moving;
    sel.head = moving;
    assert(sel.clean.len == a.display.screen.pixels.len); // The book's, taken as it opened
    @memcpy(sel.clean, a.display.screen.pixels);
    a.display.page(sel.clean).threshold(0, a.display.screen.height); // Pure black and white for A2
    const none = selection.Band{ .top = 0, .height = 0 };
    sel.previous = try paint_selection(a, sel.clean, words, fixed, sel.head, none);
    const follow = SelectionFollow{
        .a = a,
        .clean = sel.clean,
        .words = words,
        .fixed = fixed,
        .head = &sel.head,
        .previous = &sel.previous,
    };
    sel.drag = .{ .a = a, .follow = follow, .marker = a.display.screen.next_marker - 1 };
    return screen.open(&sel.drag, &sel.ending);
}

/// Where the selection stopped; null when it was cut short, by the Kindle locking
/// say, and isn't one.
fn drag_selection_ended(sel: *Selecting) !?u32 {
    if (!try drag.ended(&sel.drag, sel.ending.?)) return null;
    assert(sel.head < sel.words.len);
    assert(sel.fixed < sel.words.len);
    return sel.head;
}
/// Underlines from `first` to `last`, redrawing the band the old and new selections cover.
fn paint_selection(
    a: *app.App,
    clean: []const u8,
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
    const bottom = @min(@max(old.top + old.height, now.top + now.height), a.display.screen.height);
    assert(top <= bottom);
    const stride = a.display.screen.stride;
    const band_start = top * stride;
    const band_end = bottom * stride;
    assert(clean.len == a.display.screen.pixels.len);
    @memcpy(a.display.screen.pixels[band_start..band_end], clean[band_start..band_end]);
    selection.draw(a.display.on_screen(), chosen);
    _ = try a.display.screen.show_region(0, top, a.display.screen.width, bottom - top, .quick);
    return now;
}

/// The words a press and hold covered: the one held, and the one it reached.
pub const Held = struct { fixed: u32, head: u32 };

/// Press and hold: follows the finger from the word held, the screen to open over the
/// page; null when the hold wasn't on a word. `hold_ended` says which words it covered.
pub fn select_from_hold(
    sel: *Selecting,
    a: *app.App,
    s: *sess.Session,
    hold_x: i32,
    hold_y: i32,
) !?screen.Frame {
    const words = s.page_words();
    const fixed = selection.word_at(words, hold_x, hold_y) orelse return null;
    assert(fixed < words.len);
    return try drag_selection(sel, a, words, fixed, fixed);
}

/// The words a hold covered when it lifted; null when it was cut short.
pub fn hold_ended(sel: *Selecting, a: *app.App, s: *sess.Session) !?Held {
    const head = try drag_selection_ended(sel) orelse {
        _ = try show_page(a, s, null); // Takes the unfinished selection off
        return null;
    };
    assert(head < sel.words.len);
    assert(sel.fixed == sel.moving); // A hold starts and stays from one word
    return .{ .fixed = sel.fixed, .head = head };
}

/// Makes a new highlight of the page's words from `fixed` to `head`, either way round.
pub fn new_highlight(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    fixed: u32,
    head: u32,
) !?[]const u8 {
    const words = s.page_words();
    assert(fixed < words.len);
    assert(head < words.len);
    const lo = words[@min(fixed, head)];
    const hi = words[@max(fixed, head)];
    const start = records.point_for(s, lo.para, lo.start) orelse {
        try highlight_not_saved(a, s);
        return null;
    };
    const taken = s.notes.stored_highlight_ids;
    const id = highlights.free_id(alloc, s.notes.highlights.items, taken, start.short) catch |err| {
        if (err != error.PositionTooLarge) return err;
        try highlight_not_saved(a, s);
        return null;
    };
    const span = highlights.Span.of(lo, hi); // As saved, so as shown
    const saved = save_highlight(s, id, span);
    if (saved) s.notes.store.sync();
    const word_count = @max(fixed, head) - @min(fixed, head) + 1;
    std.debug.print("highlight {s}: {d} words, saved {}\n", .{ id, word_count, saved });
    if (!saved) {
        try highlight_not_saved(a, s);
        return null;
    }
    try highlights.add(&s.notes.highlights, alloc, s.paragraphs, id, span);
    try refresh_marks(a, s, alloc);
    assert(highlights.extent(s.notes.highlights.items, id) != null);
    return id;
}

/// Drags one end of a highlight: the screen to open over the page, or null when it
/// isn't on the page. The record keeps its ID, so it extends in place
/// (`extend_ended`).
pub fn extend_highlight(
    sel: *Selecting,
    a: *app.App,
    s: *sess.Session,
    id: []const u8,
    grab_start: bool,
) !?screen.Frame {
    const words = s.page_words();
    const range = highlights.word_range(words, s.notes.highlights.items, id) orelse return null;
    const whole = highlights.extent(s.notes.highlights.items, id) orelse return null;
    assert(range.lo <= range.hi);
    assert(range.hi < words.len);
    sel.extending = .{ .id = id, .whole = whole, .grab_start = grab_start };
    const fixed = if (grab_start) range.hi else range.lo;
    const moving = if (grab_start) range.lo else range.hi;
    return try drag_selection(sel, a, words, fixed, moving);
}

/// A highlight's end dragged, saved where it stopped.
pub fn extend_ended(
    sel: *Selecting,
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
) !void {
    const extending = sel.extending.?; // Set as the drag began, by `extend_highlight`
    sel.extending = null;
    const id = extending.id;
    assert(id.len > 0);
    const head = try drag_selection_ended(sel) orelse {
        _ = try show_page(a, s, id); // Back to the highlight as it was
        return;
    };
    if (head == sel.moving) return; // Touched without moving, so nothing changed
    const fixed = sel.fixed;
    const words = sel.words;
    const grab_start = extending.grab_start;
    const crossed = if (grab_start) head > fixed else head < fixed;
    const whole = extending.whole;
    const span = highlights.dragged(whole, words[fixed], words[head], grab_start, crossed);
    const saved = save_highlight(s, id, span);
    if (saved) s.notes.store.sync();
    std.debug.print("highlight extended: saved {}\n", .{saved});
    if (!saved) return app.show_notice(a, "This highlight couldn't be changed.");
    highlights.remove(&s.notes.highlights, id);
    try highlights.add(&s.notes.highlights, alloc, s.paragraphs, id, span);
    try refresh_marks(a, s, alloc);
    assert(highlights.extent(s.notes.highlights.items, id) != null);
}

/// Deletes a highlight here and, through sync, everywhere.
pub fn remove_highlight(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    id: []const u8,
) !void {
    // Only a highlight on the page has a Delete bubble to tap
    assert(highlights.extent(s.notes.highlights.items, id) != null);
    const removed = s.notes.store.remove(.highlight, id);
    std.debug.print("highlight removed: {}\n", .{removed});
    if (!removed) return app.show_notice(a, "This highlight couldn't be deleted.");
    s.notes.store.sync();
    highlights.remove(&s.notes.highlights, id);
    try refresh_marks(a, s, alloc);
    assert(highlights.extent(s.notes.highlights.items, id) == null);
}
