//! Renders the quick panel to a PGM image on stdout, so it can be checked by eye.
//! Usage: panelshot [panel | notes | toolbar [sheet] | library [page [read]]]
const std = @import("std");
const assert = std.debug.assert;
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

/// The panel noface is drawn for.
const screen_width = 1272;
const screen_height = 1696;
const font_folder = "/usr/java/lib/fonts/";
const library_path = "/mnt/us/noface-data/library.tsv";
const stdout_fd = 1;
/// The page dimmed behind the toolbar and its sheets.
const dimmed_gray = 0xe8;
/// The toolbar's invented book: its title, the page showing, and how many there are.
const sample_title = "A sample book title";
const sample_page_index = 36;
const sample_page_count = 280;
/// A body page's layout, as the reader sets one.
const body_layout = text.Layout{
    .margin_x = 100,
    .margin_top = 90,
    .margin_bottom = 150,
    .indent = 60,
};

const filler = "Sample body words stand in for a real page and fill the lines around the marks. ";
const sample = filler ++ filler ++
    "One reference2 sits inside a word and a [3] mark stands apart so both shapes can be " ++
    "checked. " ++ filler ++ filler;
const note_line =
    "This is invented text for checking the note panel, long enough to wrap over several lines. ";
const sample_note = note_line ++ note_line ++ note_line;

/// The format preview's text, with a run in bold and one in italics.
const format_body = "This sample paragraph has a few words in bold and some in italics, " ++
    "then carries on as ordinary body text for a line or two more.";
const format_runs = [_]core.book.Run{
    .{ .start = 26, .end = 39, .bold = true, .italic = false },
    .{ .start = 44, .end = 59, .bold = false, .italic = true },
};

/// The two references in `sample`: a digit on a word, and a bracketed mark.
const word_reference = std.mem.indexOf(u8, sample, "reference2").? + "reference".len;
const word_reference_size = 1;
const mark_reference = std.mem.indexOf(u8, sample, "[3]").?;
const mark_reference_size = 3;

comptime {
    assert(menu.height <= screen_height);
    assert(std.mem.eql(u8, sample[word_reference..][0..word_reference_size], "2"));
    assert(std.mem.eql(u8, sample[mark_reference..][0..mark_reference_size], "[3]"));
    assert(sample_page_index < sample_page_count);
    for (format_runs) |run| {
        assert(run.start < run.end);
        assert(run.end <= format_body.len);
    }
}

/// What every shot draws with, and on.
const Shot = struct {
    allocator: std.mem.Allocator,
    covers: *core.covers.Pool,
    argv: std.process.Args.Vector,
    fonts: Fonts,
    page: Page,
    quick: *core.quick.Quick,
    now: library.Moment,
    /// The book's regular typeface, for the shots of a page.
    book_regular: []const u8,
};

/// Writes a grayscale screen to stdout as a PGM image.
fn write_image(pixels: []const u8, width: u32, height: u32) void {
    assert(width > 0);
    assert(pixels.len == @as(u64, width) * height);
    var head: [32]u8 = undefined;
    const header = std.fmt.bufPrint(&head, "P5\n{d} {d}\n255\n", .{ width, height }) catch return;
    // Each part as far as stdout takes it: a part cut short doesn't stop the next.
    for ([_][]const u8{ header, pixels }) |data| {
        assert(data.len > 0);
        var at: u32 = 0;
        while (at < data.len) {
            const n = linux.write(stdout_fd, data[at..].ptr, data.len - at);
            if (core.os.failed(n) or n == 0) break;
            at += @intCast(n);
        }
        assert(at <= data.len);
    }
}

/// Faces for the format preview: the four Bookerly files at any size, made on first use.
const PreviewFaces = struct {
    files: [4][]const u8,
    fonts: [4][core.book.size_scales.len]?Font = @splat(@splat(null)),
    allocator: std.mem.Allocator,

    fn pick(context: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*Font {
        const faces: *PreviewFaces = @ptrCast(@alignCast(context));
        assert(size < core.book.size_scales.len);
        const which: u2 = @as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1;
        const slot = &faces.fonts[which][size];
        if (slot.* == null) {
            const size_px = 46 * core.book.size_scales[size];
            slot.* = try Font.init(faces.allocator, faces.files[which], size_px, 1.35);
        }
        assert(slot.* != null);
        return &slot.*.?;
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    const allocator = std.heap.page_allocator;
    const book_regular = try file.map(font_folder ++ "Bookerly-Regular.ttf");
    const book_bold = try file.map(font_folder ++ "Bookerly-Bold.ttf");
    const ui_regular = try file.map(font_folder ++ "Amazon-Ember-Regular.ttf");
    const ui_bold = try file.map(font_folder ++ "Amazon-Ember-Bold.ttf");
    var title = try Font.init(allocator, ui_bold, 34, 1.2);
    var small = try Font.init(allocator, ui_regular, 34, 1.2);
    var caption = try Font.init(allocator, ui_regular, 26, 1.2);
    var hero = try Font.init(allocator, book_bold, 56, 1.2);
    var cover_type = try Font.init(allocator, book_bold, 36, 1.2);
    const pixels = try allocator.alloc(u8, screen_width * screen_height);
    @memset(pixels, 0xff);
    const mode = if (argv.len > 1) std.mem.sliceTo(argv[1], 0) else "panel";
    var quick = lipc.read(.{});
    var covers: core.covers.Pool = undefined;
    try covers.init(allocator);
    const shot = Shot{
        .allocator = allocator,
        .covers = &covers,
        .argv = argv,
        .fonts = .{
            .title = &title,
            .small = &small,
            .caption = &caption,
            .hero = &hero,
            .cover = &cover_type,
        },
        .page = .{
            .buf = pixels,
            .width = screen_width,
            .height = screen_height,
            .stride = screen_width,
        },
        .quick = &quick,
        .now = .{ .unix = core.os.unix_time(), .utc_offset = core.clock.utc_offset() },
        .book_regular = book_regular,
    };

    if (std.mem.eql(u8, mode, "library")) return render_library(&shot);
    if (std.mem.eql(u8, mode, "library-search")) return render_library_search(&shot);
    if (std.mem.eql(u8, mode, "notes")) return render_notes(&shot);
    if (std.mem.eql(u8, mode, "sheet")) return render_sheet(&shot);
    if (std.mem.eql(u8, mode, "lock")) return render_lock(&shot);
    if (std.mem.eql(u8, mode, "format")) return render_format(&shot);
    if (std.mem.eql(u8, mode, "search")) return render_search(&shot);
    if (std.mem.eql(u8, mode, "goto")) return render_goto(&shot);
    if (std.mem.eql(u8, mode, "toolbar")) return render_toolbar(&shot);

    quick.brightness = 11;
    try menu.render(shot.fonts, shot.page, &quick);
    write_image(pixels[0 .. screen_width * menu.height], screen_width, menu.height);
}

/// Page `index` of the books `visible` lets through, as the library draws it.
fn page_books(
    entries: []catalog.Entry,
    lead: ?u32,
    visible: []const u32,
    index: u32,
) !library.Books {
    assert(visible.len <= entries.len);
    const Shown = struct {
        var books: [library.page_books_max]catalog.Entry = undefined;
    };
    if (index >= library.page_count(@intCast(visible.len))) return error.NoSuchPage;
    const range = library.page_range(index, @intCast(visible.len));
    for (visible[range.first..range.end], 0..) |entry_index, i| {
        Shown.books[i] = entries[entry_index];
    }
    assert(range.end - range.first <= Shown.books.len);
    return .{
        .shown = Shown.books[0 .. range.end - range.first],
        .hero = if (lead) |l| &entries[l] else null,
        .count = @intCast(visible.len),
    };
}

/// The library, at page `index` when given, of the books read when a third argument is.
fn render_library(shot: *const Shot) !void {
    const entries = try catalog_db.parse(shot.allocator, try file.map(library_path));
    catalog.sort(entries, .recent);
    const visible = try shot.allocator.alloc(u32, entries.len);
    const filter: catalog.Filter = if (shot.argv.len > 3) .read else .all;
    const lead = catalog.pick_hero(entries);
    const count = catalog.select(entries, filter, lead, "", visible);
    assert(count <= entries.len);
    for (visible[0..count]) |entry_index| assert(entry_index < entries.len);
    if (lead) |lead_index| assert(lead_index < entries.len);
    var index: u32 = 0;
    if (shot.argv.len > 2) {
        index = try std.fmt.parseInt(u32, std.mem.sliceTo(shot.argv[2], 0), 10);
    }
    try library.render(
        shot.covers,
        shot.fonts,
        shot.page,
        try page_books(entries, lead, visible[0..count], index),
        index,
        filter,
        .recent,
        "",
        "",
        shot.quick,
        shot.now,
    );
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The library with a search showing: the filled search button and the results
/// header. `panelshot library-search [query]`, "the" by default.
fn render_library_search(shot: *const Shot) !void {
    const entries = try catalog_db.parse(shot.allocator, try file.map(library_path));
    catalog.sort(entries, .recent);
    const visible = try shot.allocator.alloc(u32, entries.len);
    const query = if (shot.argv.len > 2) std.mem.sliceTo(shot.argv[2], 0) else "the";
    const count = catalog.select(entries, .all, null, query, visible);
    assert(count <= entries.len);
    for (visible[0..count]) |entry_index| assert(entry_index < entries.len);
    try library.render(
        shot.covers,
        shot.fonts,
        shot.page,
        try page_books(entries, catalog.pick_hero(entries), visible[0..count], 0),
        0,
        .all,
        .recent,
        query,
        "",
        shot.quick,
        shot.now,
    );
    write_image(shot.page.buf, screen_width, screen_height);
}

/// A page with both shapes of note reference, and a note's panel open over it.
fn render_notes(shot: *const Shot) !void {
    var body = try Font.init(shot.allocator, shot.book_regular, 46, 1.35);
    var note_font = try Font.init(shot.allocator, shot.book_regular, 36, 1.3);
    var mark = try Font.init(shot.allocator, shot.book_regular, 28, 1.2);
    const links = [_]book_model.Link{
        .{ .start = word_reference, .end = word_reference + word_reference_size, .target = 1 },
        .{ .start = mark_reference, .end = mark_reference + mark_reference_size, .target = 2 },
    };
    const paragraphs = [_]book_model.Paragraph{
        .{ .text = sample, .style = 0, .links = &links },
        .{ .text = sample_note, .style = 0, .note = true, .note_start = true },
        .{ .text = sample_note, .style = 0, .note = true, .note_start = true },
    };
    var layout = body_layout;
    layout.reference = &mark;
    _ = try text.render_page(&body, shot.page, &paragraphs, .{}, layout, null);
    const parts = [_]book_model.Paragraph{.{ .text = sample_note, .style = 0 }};
    const fitted = try notes.fit(&note_font, &parts, .{}, screen_width, screen_width, null);
    assert(fitted.height > 0);
    assert(fitted.height <= screen_height);
    const top = screen_height - fitted.height;
    const panel = Page{
        .buf = shot.page.buf[top * screen_width ..],
        .width = screen_width,
        .height = fitted.height,
        .stride = screen_width,
    };
    try notes.render(&note_font, shot.fonts, panel, &parts, .{}, false);
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The library with the first book's sheet open, asking to confirm when a second
/// argument is given.
fn render_sheet(shot: *const Shot) !void {
    const entries = try catalog_db.parse(shot.allocator, try file.map(library_path));
    catalog.sort(entries, .recent);
    const lead = catalog.pick_hero(entries);
    const visible = try shot.allocator.alloc(u32, entries.len);
    const count = catalog.select(entries, .all, lead, "", visible);
    if (count == 0) return error.EmptyLibrary;
    assert(count <= entries.len);
    assert(visible[0] < entries.len);
    try library.render(
        shot.covers,
        shot.fonts,
        shot.page,
        try page_books(entries, lead, visible[0..count], 0),
        0,
        .all,
        .recent,
        "",
        "",
        shot.quick,
        shot.now,
    );
    var list: [4]sheet.Option = undefined;
    const confirming = shot.argv.len > 2;
    const entry = &entries[visible[0]];
    const options = sheet.options(entry, confirming, &list);
    var row_buffer: [3]core.card.Row = undefined;
    var subtitle_buffer: [320]u8 = undefined;
    const subtitle = sheet.subtitle(&subtitle_buffer, entry, confirming);
    const rows = sheet.rows(options, &row_buffer);
    try core.card.render(shot.fonts, shot.page, entry.title, subtitle, rows);
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The lock screen: the cover of the book named on the command line, filling the screen.
fn render_lock(shot: *const Shot) !void {
    if (shot.argv.len < 3) return error.Usage;
    const data = try file.map(shot.argv[2]);
    const jpeg = kfx.cover_image(data) orelse return error.NoCover;
    std.debug.print("jpeg {d} bytes\n", .{jpeg.len});
    const pixels = shot.page.buf;
    assert(pixels.len == screen_width * screen_height);
    const filled = cover.fill_screen(
        shot.allocator,
        jpeg,
        pixels,
        screen_width,
        screen_height,
        screen_width,
    );
    if (!filled) return error.DecodeFailed;
    write_image(pixels, screen_width, screen_height);
}

/// Invented text, set the way a chapter opening is.
fn render_format(shot: *const Shot) !void {
    var faces = PreviewFaces{ .allocator = shot.allocator, .files = undefined };
    const paths = [_][*:0]const u8{
        font_folder ++ "Bookerly-Regular.ttf",
        font_folder ++ "Bookerly-Bold.ttf",
        font_folder ++ "Bookerly-Italic.ttf",
        font_folder ++ "Bookerly-BoldItalic.ttf",
    };
    for (paths, &faces.files) |path, *face_file| face_file.* = try file.map(path);
    const chapter_look: core.book.Look = .{
        .bold = true,
        .size = 4,
        .alignment = .center,
        .space_after = 10,
    };
    const subtitle_look: core.book.Look = .{
        .italic = true,
        .alignment = .center,
        .space_after = 10,
    };
    const heading_look: core.book.Look = .{
        .bold = true,
        .size = 2,
        .space_before = 10,
        .space_after = 4,
    };
    const paragraphs = [_]core.book.Paragraph{
        .{ .text = "Chapter One", .style = 0, .look = chapter_look },
        .{ .text = "A subtitle in italics", .style = 0, .look = subtitle_look },
        .{ .text = format_body, .style = 0, .runs = &format_runs },
        .{ .text = format_body, .style = 0 },
        .{ .text = "A Section Heading", .style = 0, .look = heading_look },
        .{ .text = format_body, .style = 0 },
    };
    const base = try PreviewFaces.pick(&faces, false, false, core.book.normal_size);
    assert(base == &faces.fonts[0][core.book.normal_size].?);
    var layout = body_layout;
    layout.faces = .{ .ctx = &faces, .pick = PreviewFaces.pick };
    _ = try text.render_page(base, shot.page, &paragraphs, .{}, layout, null);
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The toolbar with the search bar and keyboard over the dimmed page.
fn render_search(shot: *const Shot) !void {
    @memset(shot.page.buf, dimmed_gray);
    try render_sample_toolbar(shot, null);
    try core.search_sheet.render_bar(
        shot.fonts,
        shot.page,
        core.toolbar.status_row,
        "lighthouse",
        "Search this book",
        .search,
    );
    try core.keyboard.render(shot.fonts, shot.page);
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The contents, or the notes when a second argument is given: invented rows, nested
/// and marked the way books are.
fn render_goto(shot: *const Shot) !void {
    const names = [_][]const u8{
        "Cover",
        "Part One",
        "A first chapter title",
        "A second chapter",
        "Interlude",
        "A much longer chapter title that has to be clipped at the edge of the page",
        "Part Two",
        "Short",
        "Another chapter",
        "Notes",
    };
    const notes_tab = shot.argv.len > 2;
    var list: [24]core.goto.Row = undefined;
    comptime assert(list.len > names.len);
    for (&list, 0..) |*row, index| {
        const nested = !notes_tab and (index % 5 == 2 or index % 5 == 3);
        row.* = .{
            .label = names[index % names.len],
            .page = index * 17,
            .depth = if (nested) 1 else 0,
        };
        if (notes_tab) row.mark = if (index % 3 == 0) .bookmark else .highlight;
    }
    @memset(shot.page.buf, dimmed_gray);
    try render_sample_toolbar(shot, null);
    const tab: core.goto.Tab = if (notes_tab) .notes else .contents;
    try core.goto.render(shot.fonts, shot.page, tab, &list, if (notes_tab) null else 3, 0);
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The toolbar, with one of its sheets open when a second argument names it by number.
fn render_toolbar(shot: *const Shot) !void {
    var tab: ?core.aa.Tab = null;
    if (shot.argv.len > 2) tab = @fromBackingInt(@intCast(shot.argv[2][0] - '0'));
    @memset(shot.page.buf, dimmed_gray);
    try render_sample_toolbar(shot, tab);
    write_image(shot.page.buf, screen_width, screen_height);
}

/// The toolbar over the invented book, with `tab`'s sheet open if there is one.
fn render_sample_toolbar(shot: *const Shot, tab: ?core.aa.Tab) !void {
    assert(shot.page.width == screen_width);
    assert(shot.page.height == screen_height);
    const font_sheet = tab != null and tab.? == .font;
    try toolbar.render(
        shot.fonts,
        shot.page,
        sample_title,
        sample_page_index,
        sample_page_count,
        shot.quick,
        tab,
        .{},
        font_sheet,
    );
}
