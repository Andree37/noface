//! Go To: the contents, or the bookmarks and highlights, over the page.
//! Returns the page to jump to, if any.
const std = @import("std");
const book_model = @import("../../model/book.zig");
const goto = @import("../../ui/goto.zig");
const highlights = @import("../../model/highlights.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const screen = @import("../screen.zig");

const excerpt_bytes = 160;

pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator, chapters: []const book_model.Chapter) !?usize {
    const reading = goto.current(chapters, s.pages[s.current].para);
    var go = GoTo{
        .a = a,
        .background = try s.ensure(s.current, s.current),
        .contents = try contents_rows(alloc, s, chapters),
        .notes = try notes_rows(alloc, s),
        .reading = reading,
        .pages = .{ .page = if (reading) |r| goto.list_page_of(r) else 0 },
    };
    return screen.run(a, &go);
}

/// Two lists under the toolbar: the contents, with the chapter being read marked, and
/// the bookmarks and highlights. The page of the row tapped.
const GoTo = struct {
    pub const Result = usize;
    a: *app.App,
    background: []const u8, // The page under it
    contents: []const goto.Row,
    notes: []const goto.Row,
    reading: ?usize, // The chapter being read, in the contents
    tab: goto.Tab = .contents,
    pages: goto.Pages,

    fn list(go: *const GoTo) []const goto.Row {
        return if (go.tab == .contents) go.contents else go.notes;
    }

    pub fn draw(go: *GoTo, _: screen.Part) !void {
        const a = go.a;
        @memcpy(a.overlay, go.background);
        // The toolbar stays drawn above, from what's on screen now
        @memcpy(a.overlay[0 .. goto.top * a.screen.stride], a.screen.pixels[0 .. goto.top * a.screen.stride]);
        try goto.render(a.ui, a.page(a.overlay), go.tab, go.list(), if (go.tab == .contents) go.reading else null, go.pages.page);
        @memcpy(a.screen.pixels, a.overlay);
        try a.show_band(goto.top, a.screen.height - goto.top);
    }

    pub fn on_tap(go: *GoTo, t: screen.Tap) !screen.Step(usize) {
        const rows = go.list();
        switch (go.pages.tap(t.x, t.y, rows.len)) {
            .none => return .stay,
            .close => return .close,
            .turned => return .{ .redraw = .all },
            .row => |i| {
                std.debug.print("goto {s} row {d} of {d}: page {d}\n", .{ @tagName(go.tab), i + 1, rows.len, rows[i].page + 1 });
                return .{ .done = rows[i].page };
            },
            .tab => |tab| {
                if (tab == go.tab) return .stay;
                go.tab = tab;
                go.pages.page = if (tab == .contents) (if (go.reading) |r| goto.list_page_of(r) else 0) else 0;
                return .{ .redraw = .all };
            },
        }
    }
};

fn contents_rows(alloc: std.mem.Allocator, s: *const sess.Session, chapters: []const book_model.Chapter) ![]goto.Row {
    const out = try alloc.alloc(goto.Row, chapters.len);
    for (chapters, out) |c, *r| r.* = .{ .label = c.title, .page = sess.page_containing(s.pages, c.para, 0), .depth = c.depth };
    return out;
}

const Placed = struct { para: u32, byte: u32, row: goto.Row };

fn before(_: void, x: Placed, y: Placed) bool {
    return x.para < y.para or (x.para == y.para and x.byte < y.byte);
}

/// Bookmarks and highlights in reading order, each with the text where it starts.
fn notes_rows(alloc: std.mem.Allocator, s: *const sess.Session) ![]goto.Row {
    var placed: std.ArrayList(Placed) = .empty;
    for (s.bookmarks.items) |b| {
        const words = highlights.excerpt(s.paragraphs[b.para].text[b.byte..], excerpt_bytes);
        try placed.append(alloc, .{ .para = b.para, .byte = b.byte, .row = .{ .label = words, .page = sess.page_containing(s.pages, b.para, b.byte), .mark = .bookmark } });
    }
    // A highlight has a mark per paragraph it covers; list it once, from its start.
    for (s.highlights.items, 0..) |h, i| {
        if (!highlights.first_of_id(s.highlights.items, i)) continue;
        const span = highlights.extent(s.highlights.items, h.id) orelse continue;
        const para = s.paragraphs[span.first_para].text;
        const end = @min(if (span.last_para == span.first_para) span.last_byte else para.len, para.len);
        const start = @min(span.first_byte, end); // A damaged record can end before it starts
        const words = highlights.excerpt(para[start..end], excerpt_bytes);
        try placed.append(alloc, .{ .para = span.first_para, .byte = span.first_byte, .row = .{ .label = words, .page = sess.page_containing(s.pages, span.first_para, span.first_byte), .mark = .highlight } });
    }
    std.mem.sort(Placed, placed.items, {}, before);
    const out = try alloc.alloc(goto.Row, placed.items.len);
    for (placed.items, out) |p, *r| r.* = p.row;
    return out;
}
