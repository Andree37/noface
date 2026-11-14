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
const input_mod = @import("../../kindle/input.zig");

const max_results = 500;
const snippet_bytes = 160;

/// Searching the book: typing on the keyboard, then the results, a page of them at a
/// time. The page of the result tapped, or null when cancelled.
pub fn run(a: *app.App, s: *sess.Session, alloc: std.mem.Allocator) !?usize {
    var screen = Search{ .a = a, .s = s, .alloc = alloc };
    while (true) {
        try screen.draw();
        const t = a.input.nextTap() orelse return null; // Locked, or leaving
        switch (try screen.onTap(t)) {
            .stay => {},
            .close => return null,
            .go => |page| return page,
        }
    }
}

const After = union(enum) { stay, close, go: usize };

const Search = struct {
    a: *app.App,
    s: *sess.Session,
    alloc: std.mem.Allocator,
    typing: bool = true, // The keyboard is up; else the results are
    results: []const goto.Row = &.{},
    list_page: usize = 0,
    whole: bool = true, // Draw the keyboard or the results again, not just the bar

    fn draw(se: *Search) !void {
        const a = se.a;
        const page = a.page(a.screen.pixels);
        try search_sheet.renderBar(a.ui, page, toolbar.status_row, se.s.query.slice(), "Search this book", .search);
        if (se.whole) {
            if (se.typing) {
                page.fillRect(0, search_sheet.content_top, page.width, keyboard.top - search_sheet.content_top, 0xff);
                try keyboard.render(a.ui, page);
            } else try se.drawResults(page);
        }
        const bottom: u32 = if (se.whole) a.screen.height else search_sheet.content_top;
        try a.showBand(toolbar.status_row, bottom - toolbar.status_row);
        se.whole = false;
    }

    fn drawResults(se: *Search, page: @import("../../gfx/page.zig").Page) !void {
        const a = se.a;
        page.fillRect(0, search_sheet.content_top, page.width, goto.list_top - search_sheet.content_top, 0xff);
        var count_buf: [32]u8 = undefined;
        const n = se.results.len;
        const count = if (n >= max_results) "500+ results" else std.fmt.bufPrint(&count_buf, "{d} result{s}", .{ n, if (n == 1) "" else "s" }) catch "";
        try a.ui.caption.draw(page, style.margin, search_sheet.content_top + 56, count);
        try goto.renderList(a.ui, page, se.results, null, se.list_page, "No matches in this book.");
    }

    fn onTap(se: *Search, t: input_mod.Tap) !After {
        if (search_sheet.barHit(t.x, t.y)) |h| return se.onBar(h);
        if (t.y < search_sheet.top) return .close; // Above the sheet
        return if (se.typing) se.onKeyboard(t) else se.onResults(t);
    }

    /// Cancel closes; the field brings the keyboard back over the results.
    fn onBar(se: *Search, hit: search_sheet.Hit) After {
        if (hit == .cancel) return .close;
        if (!se.typing) {
            se.typing = true;
            se.whole = true;
        }
        return .stay;
    }

    fn onKeyboard(se: *Search, t: input_mod.Tap) !After {
        const q = &se.s.query;
        switch (keyboard.hit(t.x, t.y) orelse return .stay) {
            .char => |c| q.push(c),
            .space => q.push(' '),
            .backspace => q.pop(),
            .enter => {
                if (q.words().len == 0) return .stay;
                se.results = try find(se.alloc, se.s, q.words());
                std.debug.print("search: {d} results\n", .{se.results.len});
                se.typing = false;
                se.list_page = 0;
                se.whole = true;
            },
        }
        return .stay;
    }

    fn onResults(se: *Search, t: input_mod.Tap) After {
        switch (goto.hit(t.x, t.y, se.list_page, se.results.len)) {
            .row => |i| return .{ .go = se.results[i].page },
            .prev => se.list_page -|= 1,
            .next => se.list_page = @min(se.list_page + 1, goto.pageCount(se.results.len) - 1),
            .close, .none, .tab => return .stay,
        }
        se.whole = true;
        return .stay;
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
