//! Renders the quick panel to a PGM image on stdout, so it can be checked by eye.
//! Usage: panelshot [panel | notes | toolbar [sheet] | library [page [read]]]
const std = @import("std");
const catalog_db = core.catalog_db;
const Page = core.page.Page;
const Font = core.font.Font;
const book_model = core.book;
const catalog = core.catalog;
const Fonts = core.fonts.Fonts;
const core = @import("core");
const linux = std.os.linux;
const cover = core.cover;
const file = core.file;
const kfx = core.kfx;
const library = core.library;
const menu = core.menu;
const notes = core.notes;
const sheet = core.book_actions;
const lipc = core.lipc;
const text = core.text;
const toolbar = core.toolbar;

/// Writes a grayscale screen to stdout as a PGM image.
fn writeImage(pixels: []const u8, w: usize, h: usize) void {
    var head: [32]u8 = undefined;
    write(std.fmt.bufPrint(&head, "P5\n{d} {d}\n255\n", .{ w, h }) catch return);
    write(pixels);
}

fn write(data: []const u8) void {
    var at: usize = 0;
    while (at < data.len) {
        const n = linux.write(1, data[at..].ptr, data.len - at);
        if (n > std.math.maxInt(usize) - 4096 or n == 0) break;
        at += n;
    }
}

const filler = "Sample body words stand in for a real page and fill the lines around the marks. ";
const sample = filler ++ filler ++ "One reference2 sits inside a word and a [3] mark stands apart so both shapes can be checked. " ++ filler ++ filler;
const note_line = "This is invented text for checking the note panel, long enough to wrap over several lines. ";
const sample_note = note_line ++ note_line ++ note_line;

/// Faces for the format preview: the four Bookerly files at any size, made on first use.
const PreviewFaces = struct {
    files: [4][]const u8,
    fonts: [4][5]?Font = @splat(@splat(null)),
    alloc: std.mem.Allocator,

    fn pick(ctx: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*Font {
        const f: *PreviewFaces = @ptrCast(@alignCast(ctx));
        const which: usize = @as(usize, @intFromBool(bold)) | @as(usize, @intFromBool(italic)) << 1;
        const slot = &f.fonts[which][size];
        if (slot.* == null) slot.* = try Font.init(f.alloc, f.files[which], 46 * core.book.size_scales[size], 1.35);
        return &slot.*.?;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const alloc = std.heap.page_allocator;
    const dir = "/usr/java/lib/fonts/";
    const regular = try file.map(dir ++ "Bookerly-Regular.ttf");
    const book_bold = try file.map(dir ++ "Bookerly-Bold.ttf");
    const ui_regular = try file.map(dir ++ "Amazon-Ember-Regular.ttf");
    const ui_bold = try file.map(dir ++ "Amazon-Ember-Bold.ttf");
    var title = try Font.init(alloc, ui_bold, 34, 1.2);
    var small = try Font.init(alloc, ui_regular, 34, 1.2);
    var caption = try Font.init(alloc, ui_regular, 26, 1.2);
    var hero = try Font.init(alloc, book_bold, 56, 1.2);
    var cover_type = try Font.init(alloc, book_bold, 36, 1.2);
    const fonts = Fonts{ .title = &title, .small = &small, .caption = &caption, .hero = &hero, .cover = &cover_type };
    const w = 1272;
    const h = 1696;
    const buf = try alloc.alloc(u8, w * h);
    @memset(buf, 0xff);
    const page = Page{ .buf = buf, .width = w, .height = h, .stride = w };
    const mode = if (argv.len > 1) std.mem.sliceTo(argv[1], 0) else "panel";
    var quick = lipc.read(.{});

    if (std.mem.eql(u8, mode, "library")) {
        const entries = try catalog_db.parse(alloc, try file.map("/mnt/us/noface-data/library.tsv"));
        catalog.sort(entries, .recent);
        const visible = try alloc.alloc(usize, entries.len);
        const filter: catalog.Filter = if (argv.len > 3) .read else .all;
        const lead = catalog.pickHero(entries);
        const count = catalog.select(entries, filter, lead, "", visible);
        const index: usize = if (argv.len > 2) try std.fmt.parseInt(usize, std.mem.sliceTo(argv[2], 0), 10) else 0;
        try library.render(alloc, fonts, page, entries, lead, visible[0..count], index, filter, .recent, "", "", &quick, .{ .unix = core.os.unixTime(), .utc_offset = core.clock.utcOffset() });
        writeImage(buf, w, h);
        return;
    }

    // The library with a search showing: the filled search button and the results
    // header. `panelshot library-search [query]`, "the" by default.
    if (std.mem.eql(u8, mode, "library-search")) {
        const entries = try catalog_db.parse(alloc, try file.map("/mnt/us/noface-data/library.tsv"));
        catalog.sort(entries, .recent);
        const visible = try alloc.alloc(usize, entries.len);
        const query = if (argv.len > 2) std.mem.sliceTo(argv[2], 0) else "the";
        const count = catalog.select(entries, .all, null, query, visible);
        try library.render(alloc, fonts, page, entries, catalog.pickHero(entries), visible[0..count], 0, .all, .recent, query, "", &quick, .{ .unix = core.os.unixTime(), .utc_offset = core.clock.utcOffset() });
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "notes")) {
        var body = try Font.init(alloc, regular, 46, 1.35);
        var note_font = try Font.init(alloc, regular, 36, 1.3);
        var mark = try Font.init(alloc, regular, 28, 1.2);
        const ref1 = std.mem.indexOf(u8, sample, "reference2").? + "reference".len;
        const ref2 = std.mem.indexOf(u8, sample, "[3]").?;
        const links = [_]book_model.Link{ .{ .start = ref1, .end = ref1 + 1, .target = 1 }, .{ .start = ref2, .end = ref2 + 3, .target = 2 } };
        const paras = [_]book_model.Paragraph{
            .{ .text = sample, .style = 0, .links = &links },
            .{ .text = sample_note, .style = 0, .note = true, .note_start = true },
            .{ .text = sample_note, .style = 0, .note = true, .note_start = true },
        };
        _ = try text.renderPage(&body, page, &paras, .{}, .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &mark }, null);
        const parts = [_]book_model.Paragraph{.{ .text = sample_note, .style = 0 }};
        const fitted = try notes.fit(&note_font, &parts, .{}, w, w, null);
        const top = h - fitted.height;
        try notes.render(&note_font, fonts, .{ .buf = buf[top * w ..], .width = w, .height = fitted.height, .stride = w }, &parts, .{}, false);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "sheet")) {
        const entries = try catalog_db.parse(alloc, try file.map("/mnt/us/noface-data/library.tsv"));
        catalog.sort(entries, .recent);
        const lead = catalog.pickHero(entries);
        const visible = try alloc.alloc(usize, entries.len);
        const count = catalog.select(entries, .all, lead, "", visible);
        try library.render(alloc, fonts, page, entries, lead, visible[0..count], 0, .all, .recent, "", "", &quick, .{ .unix = core.os.unixTime(), .utc_offset = core.clock.utcOffset() });
        var list: [4]sheet.Option = undefined;
        const confirming = argv.len > 2;
        const opts = sheet.options(&entries[visible[0]], confirming, &list);
        var row_buf: [3]core.card.Row = undefined;
        var subtitle_buf: [320]u8 = undefined;
        const e = &entries[visible[0]];
        try core.card.render(fonts, page, e.title, sheet.subtitle(&subtitle_buf, e, confirming), sheet.rows(opts, &row_buf));
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "lock")) {
        const data = try file.map(argv[2]);
        const jpeg = kfx.coverImage(data) orelse return error.NoCover;
        std.debug.print("jpeg {d} bytes\n", .{jpeg.len});
        if (!cover.fillScreen(alloc, jpeg, buf, w, h, w)) return error.DecodeFailed;
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "format")) {
        // Invented text, set the way a chapter opening is.
        var faces = PreviewFaces{ .alloc = alloc, .files = undefined };
        const font_root = "/usr/java/lib/fonts/";
        for ([_][*:0]const u8{ font_root ++ "Bookerly-Regular.ttf", font_root ++ "Bookerly-Bold.ttf", font_root ++ "Bookerly-Italic.ttf", font_root ++ "Bookerly-BoldItalic.ttf" }, &faces.files) |path, *f| f.* = try file.map(path);
        const body_text = "This sample paragraph has a few words in bold and some in italics, then carries on as ordinary body text for a line or two more.";
        const runs = [_]core.book.Run{
            .{ .start = 26, .end = 39, .bold = true, .italic = false },
            .{ .start = 44, .end = 59, .bold = false, .italic = true },
        };
        const sample_paras = [_]core.book.Paragraph{
            .{ .text = "Chapter One", .style = 0, .look = .{ .bold = true, .size = 4, .alignment = .center, .space_after = 10 } },
            .{ .text = "A subtitle in italics", .style = 0, .look = .{ .italic = true, .alignment = .center, .space_after = 10 } },
            .{ .text = body_text, .style = 0, .runs = &runs },
            .{ .text = body_text, .style = 0 },
            .{ .text = "A Section Heading", .style = 0, .look = .{ .bold = true, .size = 2, .space_before = 10, .space_after = 4 } },
            .{ .text = body_text, .style = 0 },
        };
        const base = try PreviewFaces.pick(&faces, false, false, core.book.normal_size);
        _ = try text.renderPage(base, page, &sample_paras, .{}, .{ .faces = .{ .ctx = &faces, .pick = PreviewFaces.pick }, .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60 }, null);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "search")) {
        @memset(buf, 0xe8);
        try toolbar.render(fonts, page, "A sample book title", 36, 280, &quick, null, .{}, false);
        try core.search_sheet.renderBar(fonts, page, core.toolbar.status_row, "lighthouse", "Search this book", .search);
        try core.keyboard.render(fonts, page);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "goto")) {
        // Invented rows, nested and marked the way books are.
        const names = [_][]const u8{ "Cover", "Part One", "A first chapter title", "A second chapter", "Interlude", "A much longer chapter title that has to be clipped at the edge of the page", "Part Two", "Short", "Another chapter", "Notes" };
        const notes_tab = argv.len > 2;
        var list: [24]core.goto.Row = undefined;
        for (&list, 0..) |*r, i| {
            r.* = .{ .label = names[i % names.len], .page = i * 17, .depth = if (!notes_tab and (i % 5 == 2 or i % 5 == 3)) 1 else 0 };
            if (notes_tab) r.mark = if (i % 3 == 0) .bookmark else .highlight;
        }
        @memset(buf, 0xe8);
        try toolbar.render(fonts, page, "A sample book title", 36, 280, &quick, null, .{}, false);
        try core.goto.render(fonts, page, if (notes_tab) .notes else .contents, &list, if (notes_tab) null else 3, 0);
        writeImage(buf, w, h);
        return;
    }

    if (std.mem.eql(u8, mode, "toolbar")) {
        const tab: ?core.aa.Tab = if (argv.len > 2) @fromBackingInt(@intCast(argv[2][0] - '0')) else null;
        @memset(buf, 0xe8);
        try toolbar.render(fonts, page, "A sample book title", 36, 280, &quick, tab, .{}, tab != null and tab.? == .font);
        writeImage(buf, w, h);
        return;
    }

    quick.brightness = 11;
    try menu.render(fonts, page, &quick);
    writeImage(buf[0 .. w * menu.height], w, menu.height);
}
