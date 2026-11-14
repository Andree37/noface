//! Go To: the contents, or the bookmarks and highlights, over the page.
//! Returns the page to jump to, if any.
const std = @import("std");
const assert = std.debug.assert;
const book_model = @import("../../model/book.zig");
const goto = @import("../../ui/goto.zig");
const highlights = @import("../../model/highlights.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const screen = @import("../screen.zig");

const excerpt_bytes = 160;

pub fn run(
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    chapters: []const book_model.Chapter,
) !?usize {
    assert(s.current < s.pages.len);
    assert(chapters.len <= std.math.maxInt(u32));
    const current = goto.current(chapters, s.pages[s.current].para);
    const reading: ?u32 = if (current) |r| @intCast(r) else null;
    if (reading) |r| assert(r < chapters.len);
    var go = GoTo{
        .a = a,
        .background = try s.ensure(s.current, s.current),
        .contents = try contents_rows(alloc, s, chapters),
        .notes = try notes_rows(alloc, s),
        .reading = reading,
        .pages = .{ .page = if (reading) |r| goto.list_page_of(r) else 0 },
    };
    const page = try screen.run(a, &go) orelse return null;
    assert(page < s.pages.len);
    return page;
}

/// Two lists under the toolbar: the contents, with the chapter being read marked, and
/// the bookmarks and highlights. The page of the row tapped.
const GoTo = struct {
    pub const Result = u32;
    a: *app.App,
    background: []const u8, // The page under it
    contents: []const goto.Row,
    notes: []const goto.Row,
    reading: ?u32, // The chapter being read, in the contents
    tab: goto.Tab = .contents,
    pages: goto.Pages,

    fn list(go: *const GoTo) []const goto.Row {
        if (go.reading) |r| assert(r < go.contents.len);
        return if (go.tab == .contents) go.contents else go.notes;
    }

    pub fn draw(go: *GoTo, _: screen.Part) !void {
        const a = go.a;
        assert(go.background.len == a.overlay.len);
        assert(goto.top < a.screen.height);
        @memcpy(a.overlay, go.background);
        // The toolbar stays drawn above, from what's on screen now
        const toolbar_bytes = goto.top * a.screen.stride;
        @memcpy(a.overlay[0..toolbar_bytes], a.screen.pixels[0..toolbar_bytes]);
        const page = a.page(a.overlay);
        // The chapter being read is marked in the contents only
        const marked = go.tab == .contents and go.reading != null;
        try goto.render(
            a.ui,
            page,
            go.tab,
            go.list(),
            if (marked) go.reading.? else null,
            go.pages.page,
        );
        @memcpy(a.screen.pixels, a.overlay);
        try a.show_band(goto.top, a.screen.height - goto.top);
    }

    pub fn on_tap(go: *GoTo, t: screen.Tap) !screen.Step(u32) {
        const rows = go.list();
        // Pages turn only within the list, and open on one of its rows
        assert(go.pages.page <= goto.list_page_of(rows.len));
        switch (go.pages.tap(t.x, t.y, rows.len)) {
            .none => return .stay,
            .close => return .close,
            .turned => return .{ .redraw = .all },
            .row => |i| {
                assert(i < rows.len);
                const page = rows[i].page;
                std.debug.print(
                    "goto {s} row {d} of {d}: page {d}\n",
                    .{ @tagName(go.tab), i + 1, rows.len, page + 1 },
                );
                return .{ .done = @intCast(page) };
            },
            .tab => |tab| {
                if (tab == go.tab) return .stay;
                go.tab = tab;
                const reading_page = if (go.reading) |r| goto.list_page_of(r) else 0;
                go.pages.page = if (tab == .contents) reading_page else 0;
                return .{ .redraw = .all };
            },
        }
    }
};

fn contents_rows(
    alloc: std.mem.Allocator,
    s: *const sess.Session,
    chapters: []const book_model.Chapter,
) ![]goto.Row {
    assert(s.pages.len > 0);
    const out = try alloc.alloc(goto.Row, chapters.len);
    for (chapters, out) |c, *r| {
        const page = sess.page_containing(s.pages, c.para, 0);
        assert(page < s.pages.len);
        r.* = .{ .label = c.title, .page = page, .depth = c.depth };
    }
    return out;
}

const Placed = struct { para: u32, byte: u32, row: goto.Row };

fn before(_: void, x: Placed, y: Placed) bool {
    if (x.para != y.para) return x.para < y.para;
    return x.byte < y.byte;
}

/// Bookmarks and highlights in reading order, each with the text where it starts.
fn notes_rows(alloc: std.mem.Allocator, s: *const sess.Session) ![]goto.Row {
    assert(s.pages.len > 0);
    var placed: std.ArrayList(Placed) = .empty;
    for (s.bookmarks.items) |b| {
        const words = highlights.excerpt(s.paragraphs[b.para].text[b.byte..], excerpt_bytes);
        const page = sess.page_containing(s.pages, b.para, b.byte);
        try placed.append(alloc, .{
            .para = b.para,
            .byte = b.byte,
            .row = .{ .label = words, .page = page, .mark = .bookmark },
        });
    }
    // A highlight has a mark per paragraph it covers; list it once, from its start.
    for (s.highlights.items, 0..) |h, i| {
        if (!highlights.first_of_id(s.highlights.items, i)) continue;
        const span = highlights.extent(s.highlights.items, h.id) orelse continue;
        const para = s.paragraphs[span.first_para].text;
        const last = if (span.last_para == span.first_para) span.last_byte else para.len;
        const end = @min(last, para.len);
        const start = @min(span.first_byte, end); // A damaged record can end before it starts
        assert(start <= end);
        const words = highlights.excerpt(para[start..end], excerpt_bytes);
        const page = sess.page_containing(s.pages, span.first_para, span.first_byte);
        try placed.append(alloc, .{
            .para = span.first_para,
            .byte = span.first_byte,
            .row = .{ .label = words, .page = page, .mark = .highlight },
        });
    }
    std.mem.sort(Placed, placed.items, {}, before);
    if (placed.items.len > 1) {
        const earlier = placed.items[0 .. placed.items.len - 1];
        for (earlier, placed.items[1..]) |x, y| assert(!before({}, y, x));
    }
    const out = try alloc.alloc(goto.Row, placed.items.len);
    for (placed.items, out) |p, *r| r.* = p.row;
    assert(out.len == placed.items.len);
    return out;
}
