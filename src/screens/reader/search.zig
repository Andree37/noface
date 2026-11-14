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

/// Searching the book: typing on the keyboard, then the results, a page of them at a
/// time. The page of the result tapped, or null when cancelled.
pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !?usize {
    assert(s.pages.len > 0);
    var search_screen = Search{ .a = a, .s = s, .alloc = alloc };
    const page = try screen.run(a, &search_screen) orelse return null;
    assert(page < s.pages.len);
    return page;
}

const Search = struct {
    pub const Result = u32;
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    typing: bool = true, // The keyboard is up; else the results are
    results: []const goto.Row = &.{},
    pages: goto.Pages = .{},

    /// The bar always; under it the keyboard or the results when all is drawn.
    pub fn draw(se: *Search, part: screen.Part) !void {
        assert(se.results.len <= results_max);
        // Results are shown only for a search that had words to look for
        if (!se.typing) assert(se.s.query.words().len > 0);
        const a = se.a;
        const page = a.page(a.screen.pixels);
        const top = toolbar.status_row;
        const query = se.s.query.slice();
        try search_sheet.render_bar(a.ui, page, top, query, "Search this book", .search);
        if (part == .all) {
            if (se.typing) {
                const keyboard_gap = keyboard.top - search_sheet.content_top;
                page.fill_rect(0, search_sheet.content_top, page.width, keyboard_gap, 0xff);
                try keyboard.render(a.ui, page);
            } else {
                try se.draw_results(page);
            }
        }
        const bottom: u32 = if (part == .all) a.screen.height else search_sheet.content_top;
        try a.show_band(top, bottom - top);
    }

    fn draw_results(se: *Search, page: Page) !void {
        assert(!se.typing);
        assert(se.results.len <= results_max);
        const a = se.a;
        const count_height = goto.list_top - search_sheet.content_top;
        page.fill_rect(0, search_sheet.content_top, page.width, count_height, 0xff);
        var count_buffer: [32]u8 = undefined;
        const n = se.results.len;
        var count: []const u8 = std.fmt.comptimePrint("{d}+ results", .{results_max});
        if (n < results_max) {
            const plural = if (n == 1) "" else "s";
            count = std.fmt.bufPrint(&count_buffer, "{d} result{s}", .{ n, plural }) catch "";
        }
        try a.ui.caption.draw(page, style.margin, search_sheet.content_top + 56, count);
        const empty = "No matches in this book.";
        try goto.render_list(a.ui, page, se.results, null, se.pages.page, empty);
    }

    pub fn on_tap(se: *Search, t: screen.Tap) !screen.Step(u32) {
        assert(se.results.len <= results_max);
        if (!se.typing) assert(se.s.query.words().len > 0);
        if (search_sheet.bar_hit(t.x, t.y)) |h| {
            if (h == .cancel) return .close;
            if (se.typing) return .stay;
            se.typing = true; // The field: the keyboard back over the results
            return .{ .redraw = .all };
        }
        if (t.y < search_sheet.top) return .close; // Above the sheet
        return if (se.typing) se.on_keyboard(t) else se.on_results(t);
    }

    fn on_keyboard(se: *Search, t: screen.Tap) !screen.Step(u32) {
        assert(se.typing);
        switch (typing.key(&se.s.query, t, typing.anything)) {
            .none => return .stay,
            .changed => return .{ .redraw = .changing },
            .enter => {
                const words = se.s.query.words();
                if (words.len == 0) return .stay;
                se.results = try find(se.alloc, se.s, words);
                assert(se.results.len <= results_max);
                std.debug.print("search: {d} results\n", .{se.results.len});
                se.typing = false;
                se.pages = .{};
                return .{ .redraw = .all };
            },
        }
    }

    fn on_results(se: *Search, t: screen.Tap) screen.Step(u32) {
        assert(!se.typing);
        return switch (se.pages.tap(t.x, t.y, se.results.len)) {
            .row => |i| row: {
                assert(i < se.results.len);
                break :row .{ .done = @intCast(se.results[i].page) };
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
        .page = sess.page_containing(s.pages, m.para, m.byte),
    };
    return rows;
}
