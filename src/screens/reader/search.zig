//! Search: type a word, see where it appears, and jump there. Returns the page to
//! go to, if any. The last query stays for the next search in this book.
const std = @import("std");
const goto = @import("../../ui/goto.zig");
const keyboard = @import("../../ui/keyboard.zig");
const search_sheet = @import("../../ui/search_sheet.zig");
const style = @import("../../ui/style.zig");
const toolbar = @import("../../ui/toolbar.zig");
const search = @import("../../model/search.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const screen = @import("../screen.zig");
const typing = @import("../typing.zig");

const max_results = 500;
const snippet_bytes = 160;

/// Searching the book: typing on the keyboard, then the results, a page of them at a
/// time. The page of the result tapped, or null when cancelled.
pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !?usize {
    var search_screen = Search{ .a = a, .s = s, .alloc = alloc };
    return screen.run(a, &search_screen);
}

const Search = struct {
    pub const Result = usize;
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    typing: bool = true, // The keyboard is up; else the results are
    results: []const goto.Row = &.{},
    pages: goto.Pages = .{},

    /// The bar always; under it the keyboard or the results when all is drawn.
    pub fn draw(se: *Search, part: screen.Part) !void {
        const a = se.a;
        const page = a.page(a.screen.pixels);
        try search_sheet.renderBar(a.ui, page, toolbar.status_row, se.s.query.slice(), "Search this book", .search);
        if (part == .all) {
            if (se.typing) {
                page.fillRect(0, search_sheet.content_top, page.width, keyboard.top - search_sheet.content_top, 0xff);
                try keyboard.render(a.ui, page);
            } else try se.drawResults(page);
        }
        const bottom: u32 = if (part == .all) a.screen.height else search_sheet.content_top;
        try a.showBand(toolbar.status_row, bottom - toolbar.status_row);
    }

    fn drawResults(se: *Search, page: @import("../../gfx/page.zig").Page) !void {
        const a = se.a;
        page.fillRect(0, search_sheet.content_top, page.width, goto.list_top - search_sheet.content_top, 0xff);
        var count_buf: [32]u8 = undefined;
        const n = se.results.len;
        const count = if (n >= max_results) "500+ results" else std.fmt.bufPrint(&count_buf, "{d} result{s}", .{ n, if (n == 1) "" else "s" }) catch "";
        try a.ui.caption.draw(page, style.margin, search_sheet.content_top + 56, count);
        try goto.renderList(a.ui, page, se.results, null, se.pages.page, "No matches in this book.");
    }

    pub fn onTap(se: *Search, t: screen.Tap) !screen.Step(usize) {
        if (search_sheet.barHit(t.x, t.y)) |h| {
            if (h == .cancel) return .close;
            if (se.typing) return .stay;
            se.typing = true; // The field: the keyboard back over the results
            return .{ .redraw = .all };
        }
        if (t.y < search_sheet.top) return .close; // Above the sheet
        return if (se.typing) se.onKeyboard(t) else se.onResults(t);
    }

    fn onKeyboard(se: *Search, t: screen.Tap) !screen.Step(usize) {
        switch (typing.key(&se.s.query, t, typing.anything)) {
            .none => return .stay,
            .changed => return .{ .redraw = .changing },
            .enter => {
                const words = se.s.query.words();
                if (words.len == 0) return .stay;
                se.results = try find(se.alloc, se.s, words);
                std.debug.print("search: {d} results\n", .{se.results.len});
                se.typing = false;
                se.pages = .{};
                return .{ .redraw = .all };
            },
        }
    }

    fn onResults(se: *Search, t: screen.Tap) screen.Step(usize) {
        return switch (se.pages.tap(t.x, t.y, se.results.len)) {
            .row => |i| .{ .done = se.results[i].page },
            .turned => .{ .redraw = .all },
            .close, .none, .tab => .stay, // The sheet's bar is above the list, not a close
        };
    }
};

fn find(alloc: std.mem.Allocator, s: *const sess.Session, query: []const u8) ![]const goto.Row {
    const matches = try search.find(alloc, s.paragraphs, query, max_results);
    const rows = try alloc.alloc(goto.Row, matches.len);
    for (matches, rows) |m, *r| r.* = .{
        .label = search.snippet(s.paragraphs[m.para].text, m.byte, snippet_bytes),
        .page = sess.pageContaining(s.pages, m.para, m.byte),
    };
    return rows;
}
