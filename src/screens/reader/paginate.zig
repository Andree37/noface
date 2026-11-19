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
    assert(paragraphs.len > 0); // Parsing refuses a book without any
    var pages: std.ArrayList(book_model.Pos) = .empty;
    const rest = try run(a, alloc, paragraphs, .{}, null, &pages, book_pages_max);
    // With no stop and no page limit worth the name, only the book's end stops it
    assert(rest == null);
    assert(std.meta.eql(pages.items[0], book_model.Pos{})); // A book's first page starts it
    return pages.items;
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
    const geometry = a.display.page(&.{});
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
            &layout,
            null,
        );
        // A page that fits nothing would repeat forever; layout always places something.
        check.thatf(position.is_before(next), "page at {d}:{d} moves forward", .{
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
    return position.is_before(stop_position);
}

/// A first open, laid out a little at a time so the reader's page shows at once.
/// Pages start at the reader's place and run forward; the pages before it follow,
/// with a break forced at that place so nothing already shown moves. While it runs,
/// `pages()` is the forward part alone, so page indexes count from the reader's place.
pub const Progressive = struct {
    alloc: std.mem.Allocator,
    paragraphs: []const book_model.Paragraph,
    anchor: book_model.Pos,
    forward: std.ArrayList(book_model.Pos) = .empty, // From the place on: never empty
    before: std.ArrayList(book_model.Pos) = .empty, // From the book's start to the place
    phase: Phase,

    /// Where the layout carries on: forward from the place first, so turning on never
    /// waits, then the pages before it, then nothing.
    const Phase = union(enum) { forward: book_model.Pos, before: book_model.Pos, done };

    /// Pages laid out at the start: the reader's page and a few to turn to.
    const first_pages = 4;
    /// Pages per step, about 40 ms on the Kindle, so a tap waits no longer than that.
    pub const step_pages = 50;

    comptime {
        assert(first_pages > 0);
        assert(step_pages >= first_pages);
    }

    /// The first few pages from `anchor`, or null when the book ends there and there's
    /// nothing to show from it.
    pub fn start(
        a: *app.App,
        alloc: std.mem.Allocator,
        paragraphs: []const book_model.Paragraph,
        anchor: book_model.Pos,
    ) !?Progressive {
        assert(anchor.para <= paragraphs.len);
        var p = Progressive{
            .alloc = alloc,
            .paragraphs = paragraphs,
            .anchor = anchor,
            .phase = .done,
        };
        const rest = try run(a, alloc, paragraphs, anchor, null, &p.forward, first_pages);
        if (p.forward.items.len == 0) return null;
        p.phase = p.after_forward(rest);
        assert(p.forward.items.len <= first_pages);
        assert(std.meta.eql(p.forward.items[0], anchor));
        return p;
    }

    /// What follows a forward step that left off at `rest`: more forward, or the
    /// pages before the place, or nothing when the place is the book's start.
    fn after_forward(p: *const Progressive, rest: ?book_model.Pos) Phase {
        if (rest) |from| return .{ .forward = from };
        if (std.meta.eql(p.anchor, book_model.Pos{})) return .done;
        return .{ .before = .{} };
    }

    pub fn done(p: *const Progressive) bool {
        return p.phase == .done;
    }

    /// Whether every page from the place on is laid out.
    pub fn forward_done(p: *const Progressive) bool {
        return p.phase != .forward;
    }

    /// Lays out one step: forward first, so turning on never waits, then before.
    pub fn step(p: *Progressive, a: *app.App) !void {
        const count_before = p.forward.items.len + p.before.items.len;
        switch (p.phase) {
            .forward => |from| {
                const rest = try run(a, p.alloc, p.paragraphs, from, null, &p.forward, step_pages);
                p.phase = p.after_forward(rest);
            },
            .before => |from| {
                const stop = p.anchor;
                const rest = try run(a, p.alloc, p.paragraphs, from, stop, &p.before, step_pages);
                p.phase = if (rest) |at| .{ .before = at } else .done;
            },
            .done => {},
        }
        const count_after = p.forward.items.len + p.before.items.len;
        assert(count_after >= count_before);
        assert(count_after - count_before <= step_pages);
    }

    /// The pages so far: the forward part while running, the whole book once done.
    pub fn pages(p: *const Progressive) []const book_model.Pos {
        assert(std.meta.eql(p.forward.items[0], p.anchor));
        return p.forward.items;
    }

    /// The whole book's pages, once done, and how many come before the reader's place.
    pub fn joined(p: *Progressive) !struct { pages: []const book_model.Pos, before: u32 } {
        check.that(p.done(), "joined only once laid out");
        const count_before = p.before.items.len;
        try p.before.appendSlice(p.alloc, p.forward.items);
        assert(std.meta.eql(p.before.items[0], book_model.Pos{})); // The book's start
        assert(p.before.items.len == count_before + p.forward.items.len);
        return .{ .pages = p.before.items, .before = @intCast(count_before) };
    }
};
