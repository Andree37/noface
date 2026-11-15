//! Laying out a whole book into pages. Kept apart from the rest of the reader because
//! saved page breaks are only valid for this code: a change that moves them raises
//! page_store's `layout_version` (a scenario says when).
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../../app.zig");
const book_model = @import("../../model/book.zig");
const check = @import("../../base/check.zig");
const text = @import("../../layout/text.zig");

/// The most pages a book may have: page indexes and counts are u32.
const book_pages_max = std.math.maxInt(u32);

/// Lays out the whole book so going backwards is exact.
pub fn book(
    a: *app.App,
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
) ![]const book_model.Pos {
    var pages: std.ArrayList(book_model.Pos) = .empty;
    const rest = try run(a, alloc, paragraphs, .{}, null, &pages, book_pages_max);
    // With no stop and no page limit worth the name, only the book's end stops it
    assert(rest == null);
    if (pages.items.len > 0) assert(std.meta.eql(pages.items[0], book_model.Pos{}));
    return pages.items;
}

/// Whether `first` comes strictly before `second` in the book.
fn is_before(first: book_model.Pos, second: book_model.Pos) bool {
    if (first.para != second.para) return first.para < second.para;
    return first.byte < second.byte;
}

/// Lays out up to `pages_max` pages from `from`, adding where each starts to `out`. A
/// page breaks at `stop` if it's reached. Returns where to carry on, or null once the
/// book or the stop is reached.
fn run(
    a: *app.App,
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    from: book_model.Pos,
    stop: ?book_model.Pos,
    out: *std.ArrayList(book_model.Pos),
    pages_max: u32,
) !?book_model.Pos {
    assert(pages_max > 0);
    assert(from.para <= paragraphs.len);
    const geometry = a.page(&.{});
    var layout = a.layout;
    layout.stop = stop;
    var position = from;
    for (0..pages_max) |_| {
        if (!run_continues(paragraphs, position, stop)) return null;
        try out.append(alloc, position);
        const next = try text.layout_page(
            a.body,
            null,
            geometry,
            paragraphs,
            position,
            layout,
            null,
        );
        // A page that fits nothing would repeat forever; layout always places something.
        check.thatf(is_before(position, next), "page at {d}:{d} moves forward", .{
            position.para,
            position.byte,
        });
        position = next;
    }
    if (!run_continues(paragraphs, position, stop)) return null;
    return position;
}

/// Whether a page starts at `position`: the book hasn't ended, nor the stop come.
fn run_continues(
    paragraphs: []const book_model.Paragraph,
    position: book_model.Pos,
    stop: ?book_model.Pos,
) bool {
    if (position.para >= paragraphs.len) return false;
    const stop_position = stop orelse return true;
    return is_before(position, stop_position);
}

/// A first open, laid out a little at a time so the reader's page shows at once.
/// Pages start at the reader's place and run forward; the pages before it follow,
/// with a break forced at that place so nothing already shown moves. While it runs,
/// `pages()` is the forward part alone, so page indexes count from the reader's place.
pub const Progressive = struct {
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    anchor: book_model.Pos,
    forward: std.ArrayList(book_model.Pos) = .empty,
    next_forward: ?book_model.Pos,
    before: std.ArrayList(book_model.Pos) = .empty,
    next_before: ?book_model.Pos,

    /// Pages laid out at the start: the reader's page and a few to turn to.
    const first_pages = 4;
    /// Pages per step, about 40 ms on the Kindle, so a tap waits no longer than that.
    pub const step_pages = 50;

    comptime {
        assert(first_pages > 0);
        assert(step_pages >= first_pages);
    }

    pub fn start(
        a: *app.App,
        alloc: std.mem.Allocator,
        paragraphs: []const book_model.Paragraph,
        anchor: book_model.Pos,
    ) !Progressive {
        assert(anchor.para <= paragraphs.len);
        const at_start = std.meta.eql(anchor, book_model.Pos{});
        var p = Progressive{
            .alloc = alloc,
            .paragraphs = paragraphs,
            .anchor = anchor,
            .next_forward = anchor,
            .next_before = if (at_start) null else book_model.Pos{},
        };
        p.next_forward = try run(a, alloc, paragraphs, anchor, null, &p.forward, first_pages);
        assert(p.forward.items.len <= first_pages);
        if (p.forward.items.len > 0) assert(std.meta.eql(p.forward.items[0], anchor));
        return p;
    }

    pub fn done(p: *const Progressive) bool {
        // The pages before the place are laid out only once the forward part is done
        if (p.before.items.len > 0) assert(p.next_forward == null);
        // Laying out from the place always places a page, unless the book ends there
        if (p.next_forward != null) assert(p.forward.items.len > 0);
        return p.next_forward == null and p.next_before == null;
    }

    /// Lays out one step: forward first, so turning on never waits, then before.
    pub fn step(p: *Progressive, a: *app.App) !void {
        const count_before = p.forward.items.len + p.before.items.len;
        if (p.next_forward) |from| {
            p.next_forward = try run(a, p.alloc, p.paragraphs, from, null, &p.forward, step_pages);
        } else if (p.next_before) |from| {
            const stop = p.anchor;
            p.next_before = try run(a, p.alloc, p.paragraphs, from, stop, &p.before, step_pages);
        }
        const count_after = p.forward.items.len + p.before.items.len;
        assert(count_after >= count_before);
        assert(count_after - count_before <= step_pages);
    }

    /// The pages so far: the forward part while running, the whole book once done.
    pub fn pages(p: *const Progressive) []const book_model.Pos {
        if (p.next_forward != null) assert(p.forward.items.len > 0);
        if (p.forward.items.len > 0) assert(std.meta.eql(p.forward.items[0], p.anchor));
        return p.forward.items;
    }

    /// The whole book's pages, once done, and how many come before the reader's place.
    pub fn joined(p: *Progressive) !struct { pages: []const book_model.Pos, before: u32 } {
        check.that(p.done(), "joined only once laid out");
        try p.before.appendSlice(p.alloc, p.forward.items);
        assert(p.before.items.len >= p.forward.items.len);
        if (p.before.items.len > 0) assert(std.meta.eql(p.before.items[0], book_model.Pos{}));
        const count_before = p.before.items.len - p.forward.items.len;
        return .{ .pages = p.before.items, .before = @intCast(count_before) };
    }
};
