//! Go To: the contents, or the bookmarks and highlights, over the page.
//! Returns the page to jump to, if any.
const std = @import("std");
const book_model = @import("../../model/book.zig");
const goto = @import("../../ui/goto.zig");
const highlights = @import("../../model/highlights.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");

const excerpt_bytes = 160;

pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, chapters: []const book_model.Chapter) !?usize {
    const chapter_rows = try contentsRows(alloc, s, chapters);
    const note_rows = try notesRows(alloc, s);
    const reading = goto.current(chapters, s.pages[s.current].para);
    var tab: goto.Tab = .contents;
    var list_page: usize = if (reading) |r| goto.listPageOf(r) else 0;
    const background = try s.ensure(s.current, s.current);
    while (true) {
        const list = if (tab == .contents) chapter_rows else note_rows;
        @memcpy(a.overlay, background);
        // The toolbar stays drawn above, from what's on screen now.
        @memcpy(a.overlay[0 .. goto.top * a.screen.stride], a.screen.pixels[0 .. goto.top * a.screen.stride]);
        try goto.render(a.ui, a.page(a.overlay), tab, list, if (tab == .contents) reading else null, list_page);
        @memcpy(a.screen.pixels, a.overlay);
        try a.showBand(goto.top, a.screen.height - goto.top);
        const choice = while (a.input.nextTap()) |t| {
            switch (goto.hit(t.x, t.y, list_page, list.len)) {
                .none => {},
                else => |h| break h,
            }
        } else return null; // Locked, or leaving
        switch (choice) {
            .close, .none => return null,
            .tab => |t| {
                if (t == tab) continue;
                tab = t;
                list_page = if (t == .contents) (if (reading) |r| goto.listPageOf(r) else 0) else 0;
            },
            .row => |i| {
                std.debug.print("goto {s} row {d} of {d}: page {d}\n", .{ @tagName(tab), i + 1, list.len, list[i].page + 1 });
                return list[i].page;
            },
            .prev => list_page -|= 1,
            .next => list_page = @min(list_page + 1, goto.pageCount(list.len) - 1),
        }
    }
}

fn contentsRows(alloc: std.mem.Allocator, s: *const sess.Session, chapters: []const book_model.Chapter) ![]goto.Row {
    const out = try alloc.alloc(goto.Row, chapters.len);
    for (chapters, out) |c, *r| r.* = .{ .label = c.title, .page = sess.pageContaining(s.pages, c.para, 0), .depth = c.depth };
    return out;
}

const Placed = struct { para: u32, byte: u32, row: goto.Row };

fn before(_: void, x: Placed, y: Placed) bool {
    return x.para < y.para or (x.para == y.para and x.byte < y.byte);
}

/// Bookmarks and highlights in reading order, each with the text where it starts.
fn notesRows(alloc: std.mem.Allocator, s: *const sess.Session) ![]goto.Row {
    var placed: std.ArrayList(Placed) = .empty;
    for (s.bookmarks.items) |b| {
        const words = highlights.excerpt(s.paragraphs[b.para].text[b.byte..], excerpt_bytes);
        try placed.append(alloc, .{ .para = b.para, .byte = b.byte, .row = .{ .label = words, .page = sess.pageContaining(s.pages, b.para, b.byte), .mark = .bookmark } });
    }
    // A highlight has a mark per paragraph it covers; list it once, from its start.
    for (s.highlights.items, 0..) |h, i| {
        var seen = false;
        for (s.highlights.items[0..i]) |earlier| seen = seen or std.mem.eql(u8, earlier.id, h.id);
        if (seen) continue;
        const span = highlights.extent(s.highlights.items, h.id) orelse continue;
        const para = s.paragraphs[span.first_para].text;
        const end = @min(if (span.last_para == span.first_para) span.last_byte else para.len, para.len);
        const start = @min(span.first_byte, end); // A damaged record can end before it starts
        const words = highlights.excerpt(para[start..end], excerpt_bytes);
        try placed.append(alloc, .{ .para = span.first_para, .byte = span.first_byte, .row = .{ .label = words, .page = sess.pageContaining(s.pages, span.first_para, span.first_byte), .mark = .highlight } });
    }
    std.mem.sort(Placed, placed.items, {}, before);
    const out = try alloc.alloc(goto.Row, placed.items.len);
    for (placed.items, out) |p, *r| r.* = p.row;
    return out;
}
