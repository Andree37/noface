//! Laying out a whole book into pages. Kept apart from the rest of the reader because
//! saved page breaks are only valid for this code: page_store fingerprints this file.
const std = @import("std");
const app = @import("../../app.zig");
const book_model = @import("../../model/book.zig");
const check = @import("../../base/check.zig");
const text = @import("../../layout/text.zig");

/// Lays out the whole book so going backwards is exact.
pub fn book(a: *app.App, alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph) ![]const book_model.Pos {
    var pages: std.ArrayList(book_model.Pos) = .empty;
    _ = try run(a, alloc, paragraphs, .{}, null, &pages, std.math.maxInt(usize));
    return pages.items;
}

/// Lays out up to `max` pages from `from`, adding where each starts to `out`. A page
/// breaks at `stop` if it's reached. Returns where to carry on, or null once the book
/// or the stop is reached.
fn run(a: *app.App, alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, from: book_model.Pos, stop: ?book_model.Pos, out: *std.ArrayList(book_model.Pos), max: usize) !?book_model.Pos {
    const geometry = a.page(&.{});
    var layout = a.layout;
    layout.stop = stop;
    var pos = from;
    var added: usize = 0;
    while (pos.para < paragraphs.len) {
        if (stop) |st| {
            if (pos.para > st.para or (pos.para == st.para and pos.byte >= st.byte)) return null;
        }
        if (added == max) return pos;
        try out.append(alloc, pos);
        added += 1;
        const next = try text.layout_page(a.body, null, geometry, paragraphs, pos, layout, null);
        // A page that fits nothing would repeat forever; layout always places something.
        check.thatf(next.para > pos.para or (next.para == pos.para and next.byte > pos.byte), "page at {d}:{d} moves forward", .{ pos.para, pos.byte });
        pos = next;
    }
    return null;
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

    pub fn start(a: *app.App, alloc: std.mem.Allocator, paragraphs: []const book_model.Paragraph, anchor: book_model.Pos) !Progressive {
        var p = Progressive{
            .alloc = alloc,
            .paragraphs = paragraphs,
            .anchor = anchor,
            .next_forward = anchor,
            .next_before = if (anchor.para == 0 and anchor.byte == 0) null else book_model.Pos{},
        };
        p.next_forward = try run(a, alloc, paragraphs, anchor, null, &p.forward, first_pages);
        return p;
    }

    pub fn done(p: *const Progressive) bool {
        return p.next_forward == null and p.next_before == null;
    }

    /// Lays out one step: forward first, so turning on never waits, then before.
    pub fn step(p: *Progressive, a: *app.App) !void {
        if (p.next_forward) |from| {
            p.next_forward = try run(a, p.alloc, p.paragraphs, from, null, &p.forward, step_pages);
        } else if (p.next_before) |from| {
            p.next_before = try run(a, p.alloc, p.paragraphs, from, p.anchor, &p.before, step_pages);
        }
    }

    /// The pages so far: the forward part while running, the whole book once done.
    pub fn pages(p: *const Progressive) []const book_model.Pos {
        return p.forward.items;
    }

    /// The whole book's pages, once done, and how many come before the reader's place.
    pub fn joined(p: *Progressive) !struct { pages: []const book_model.Pos, before: usize } {
        check.that(p.done(), "joined only once laid out");
        try p.before.appendSlice(p.alloc, p.forward.items);
        return .{ .pages = p.before.items, .before = p.before.items.len - p.forward.items.len };
    }
};
