//! Search: type a word, see where it appears, and jump there. Returns the page to
//! go to, if any. The last query stays for the next search in this book.
const std = @import("std");
const assert = std.debug.assert;
const goto = @import("../../ui/goto.zig");
const keyboard = @import("../../ui/keyboard.zig");
const search_sheet = @import("../../ui/search_sheet.zig");
const style = @import("../../ui/style.zig");
const toolbar = @import("../../ui/toolbar.zig");
const search = @import("../../model/search.zig");
const book_model = @import("../../model/book.zig");
const Page = @import("../../gfx/page.zig").Page;
const app = @import("../../app.zig");
const sess = @import("session.zig");
const screen = @import("../screen.zig");
const typing = @import("../typing.zig");

const results_max = 500;
const snippet_bytes = 160;

comptime {
    // Top to bottom: the bar, then the keyboard or the count and the list of results
    assert(toolbar.status_row < search_sheet.content_top);
    assert(search_sheet.content_top < keyboard.top);
    assert(search_sheet.content_top < goto.list_top);
}

/// Searching the book, to open over the page (`screen.open`), its results in `alloc`:
/// typing on the keyboard, then the results, a page of them at a time. Done with the
/// page of the result tapped; closed when cancelled.
pub fn make(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) Search {
    assert(s.pages.len > 0);
    assert(s.current < s.pages.len);
    return .{ .a = a, .s = s, .alloc = alloc };
}

pub const Search = struct {
    pub const Result = u32;
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    shown: Shown = .keyboard,

    /// Under the bar: the keyboard, or a search's results, a page of them at a time.
    const Shown = union(enum) {
        keyboard,
        results: struct { rows: []const goto.Row, pages: goto.Pages = .{} },
    };

    /// The bar always; under it the keyboard or the results when all is drawn.
    pub fn draw(se: *Search, part: screen.Part) !void {
        const a = se.a;
        assert(a.screen.height > search_sheet.content_top);
        const page = a.page(a.screen.pixels);
        const top = toolbar.status_row;
        const query = se.s.query.slice();
        try search_sheet.render_bar(a.ui, page, top, query, "Search this book", .search);
        if (part == .all) switch (se.shown) {
            .keyboard => {
                const keyboard_gap = keyboard.top - search_sheet.content_top;
                page.fill_rect(0, search_sheet.content_top, page.width, keyboard_gap, 0xff);
                try keyboard.render(a.ui, page);
            },
            .results => |r| try se.draw_results(page, r.rows, r.pages),
        };
        const bottom: u32 = if (part == .all) a.screen.height else search_sheet.content_top;
        try a.show_band(top, bottom - top);
    }

    fn draw_results(se: *Search, page: Page, rows: []const goto.Row, pages: goto.Pages) !void {
        assert(rows.len <= results_max);
        const a = se.a;
        const count_height = goto.list_top - search_sheet.content_top;
        page.fill_rect(0, search_sheet.content_top, page.width, count_height, 0xff);
        var count_buffer: [32]u8 = undefined;
        const n = rows.len;
        var count: []const u8 = std.fmt.comptimePrint("{d}+ results", .{results_max});
        if (n < results_max) {
            const plural = if (n == 1) "" else "s";
            count = std.fmt.bufPrint(&count_buffer, "{d} result{s}", .{ n, plural }) catch "";
        }
        try a.ui.caption.draw(page, style.margin, search_sheet.content_top + 56, count);
        const empty = "No matches in this book.";
        try goto.render_list(a.ui, page, rows, null, pages.page, empty);
    }

    pub fn on_tap(se: *Search, t: screen.Tap) !screen.Step(u32) {
        assert(se.s.current < se.s.pages.len);
        if (search_sheet.bar_hit(t.x, t.y)) |h| {
            if (h == .cancel) return .close;
            if (se.shown == .keyboard) return .stay;
            se.shown = .keyboard; // The field: the keyboard back over the results
            return .{ .redraw = .all };
        }
        if (t.y < search_sheet.top) return .close; // Above the sheet
        return switch (se.shown) {
            .keyboard => se.on_keyboard(t),
            .results => |*r| se.on_results(t, r.rows, &r.pages),
        };
    }

    fn on_keyboard(se: *Search, t: screen.Tap) !screen.Step(u32) {
        assert(se.shown == .keyboard);
        switch (typing.key(&se.s.query, t, typing.anything)) {
            .none => return .stay,
            .changed => return .{ .redraw = .changing },
            .enter => {
                const words = se.s.query.words();
                if (words.len == 0) return .stay;
                const rows = try find(se.alloc, se.s, words);
                assert(rows.len <= results_max);
                std.debug.print("search: {d} results\n", .{rows.len});
                se.shown = .{ .results = .{ .rows = rows } };
                return .{ .redraw = .all };
            },
        }
    }

    fn on_results(
        se: *const Search,
        t: screen.Tap,
        rows: []const goto.Row,
        pages: *goto.Pages,
    ) screen.Step(u32) {
        assert(rows.len <= results_max);
        assert(se.s.pages.len > 0);
        return switch (pages.tap(t.x, t.y, @intCast(rows.len))) {
            .row => |i| row: {
                assert(i < rows.len);
                assert(rows[i].page < se.s.pages.len); // A page of the book
                break :row .{ .done = rows[i].page };
            },
            .turned => .{ .redraw = .all },
            .close, .none, .tab => .stay, // The sheet's bar is above the list, not a close
        };
    }
};

fn find(alloc: std.mem.Allocator, s: *const sess.Session, query: []const u8) ![]const goto.Row {
    assert(query.len > 0);
    const matches = try search.find(alloc, s.paragraphs, query, results_max);
    assert(matches.len <= results_max);
    const rows = try alloc.alloc(goto.Row, matches.len);
    for (matches, rows) |m, *r| r.* = .{
        .label = search.snippet(s.paragraphs[m.para].text, m.byte, snippet_bytes),
        .page = book_model.page_containing(s.pages, m.para, m.byte),
    };
    return rows;
}
