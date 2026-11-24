//! Opening a book: its text and contents parsed from its file, its pages (saved,
//! laid out a little from the reader's place, or all at once), the page it opens at,
//! and what's kept with it (its words counted for time left, its highlights and
//! bookmarks). The reader (screens/reader.zig) puts what's found here into its session.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("../../app.zig");
const book_model = @import("../../model/book.zig");
const catalog = @import("../../model/catalog.zig");
const epub = @import("../../epub/epub.zig");
const kfx = @import("../../kindle/kfx.zig");
const hyphen = @import("../../layout/hyphen.zig");
const state = @import("../../sys/state.zig");
const file = @import("../../sys/file.zig");
const page_store = @import("page_store.zig");
const note_store = @import("note_store.zig");
const paginate = @import("paginate.zig");
const sess = @import("session.zig");
const hl = @import("highlight.zig");

/// The book's text and contents, from its file, and its language, as far as its text
/// tells.
pub fn parse(
    a: *app.App,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    data: []const u8,
) !struct { book: book_model.Book, lang: ?hyphen.Lang } {
    const book = if (entry.is_epub())
        try epub.parse(alloc, &a.regions.scratch, data)
    else
        try kfx.parse(alloc, data);
    // Positions are u32: a book's paragraphs fit its memory budget, far below that
    assert(book.paragraphs.len <= std.math.maxInt(u32));
    // Both parsers point the contents inside the book, as Go To relies on
    for (book.chapters) |chapter| assert(chapter.para < book.paragraphs.len);
    book_model.plain_body(book.paragraphs);
    const lang = hyphen.detect(book.paragraphs);
    std.debug.print("language {s}\n", .{if (lang) |l| @tagName(l) else "unknown"});
    return .{ .book = book, .lang = lang };
}

/// Where a book's pages came from as it opened.
pub const PagesSource = enum { @"saved pages", @"first pages", @"laid out" };

/// A book's pages as it opens, and the page to open it at.
pub const Opened = struct {
    pages: []const book_model.Pos,
    pages_path: [:0]const u8,
    start: u32,
    seconds_read: u64,
    source: PagesSource,
    back: ?book_model.Pos, // The Back button's place, as the book was closed
    back_turns: u32,
    place: file.Kept, // The place's file, as read: never saved over if unreadable
    /// The place as read, renumbered as the book is now: what each save changes.
    saved: state.State,
};

/// The pages: saved ones, or a first few laid out from the reader's place (the rest
/// follow in idle moments), or all of them at once.
pub fn find_pages(
    a: *app.App,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    book_text: paginate.Text,
    options: struct {
        book_bytes: u64,
        state_path: [:0]const u8,
        adopted: state.Adopted, // Which of 0.2.0's files are settled: the place's or not
        progress: *?paginate.Progressive,
    },
) !Opened {
    assert(options.progress.* == null);
    const paragraphs = book_text.paragraphs;
    assert(paragraphs.len > 0); // Parsing refuses a book without any
    var pages_buffer: [file.own_path_bytes_max]u8 = undefined;
    const pages_name = try page_store.path_for(&pages_buffer, options.state_path);
    const pages_path = try alloc.dupeSentinel(u8, pages_name, 0);
    const pages_key = page_store.key(a, options.book_bytes, book_text);
    const stored_pages = page_store.load(alloc, pages_path, pages_key, paragraphs);
    // The place's file, its path in the book's memory, as long as the book is open; read
    // once, here: whether it can be saved over is decided as the book opens
    var place = options.adopted.kept(.state, try alloc.dupeSentinel(u8, options.state_path, 0));
    const saved = renumbered(state.load(&place), paragraphs);
    const from_kindle = state.prefer_kindle(saved, entry.kindle_last);
    // Without saved breaks, lay out a little from the reader's place and show it at
    // once; the rest follows in idle moments. Stock's place is a percent of the
    // pages, so that one needs them all first.
    if (stored_pages == null and !from_kindle) {
        options.progress.* = try progressive(a, alloc, book_text, saved);
    }
    var pages: []const book_model.Pos = &.{};
    var source: PagesSource = .@"laid out";
    if (options.progress.*) |*p| {
        pages = p.pages();
        source = .@"first pages";
    } else if (stored_pages) |stored| {
        pages = stored;
        source = .@"saved pages";
    } else {
        pages = try paginate.book(a, alloc, book_text);
    }
    // Saved pages are never none, and a book with paragraphs lays out a page at least
    assert(pages.len > 0);
    if (source == .@"laid out") page_store.save(alloc, pages_path, pages_key, pages);
    // A first open is laid out only from the reader's own place, never stock's
    const from: StartFrom = if (source == .@"first pages")
        .first_laid_out
    else if (from_kindle) .kindle_percent else .saved_place;
    const start = start_page(pages, paragraphs, entry, &saved, from);
    assert(start < pages.len);
    // Stock's reader on the book since: its place is elsewhere, and so is Back's
    var back: ?book_model.Pos = null;
    if (saved.back_para) |para| {
        if (!from_kindle) back = place_in(paragraphs, para, saved.back_byte);
    }
    return .{
        .pages = pages,
        .pages_path = pages_path,
        .start = start,
        .seconds_read = saved.seconds,
        .source = source,
        .back = back,
        .back_turns = saved.back_turns,
        .place = place,
        .saved = saved,
    };
}

/// `saved`'s places numbered as the book is now: those 0.2.0 saved, which numbered
/// without the chapters and pictures it couldn't find, mapped past them.
fn renumbered(saved: state.State, paragraphs: []const book_model.Paragraph) state.State {
    if (saved.numbering != state.numbering_0_2) return saved;
    if (!book_model.numbered_otherwise_by_0_2(paragraphs)) return saved; // Read the same
    var now = saved;
    now.para = book_model.text_index_from_0_2(paragraphs, saved.para);
    if (saved.back_para) |p| now.back_para = book_model.text_index_from_0_2(paragraphs, p);
    now.numbering = state.numbering_now;
    assert(now.para >= saved.para); // Paragraphs only come in before it, never go
    return now;
}

/// A first open's layout, from the reader's saved place, or null when nothing is
/// laid out from there and the whole book is to be laid out instead.
fn progressive(
    a: *app.App,
    alloc: std.mem.Allocator,
    book_text: paginate.Text,
    saved: state.State,
) !?paginate.Progressive {
    const paragraphs = book_text.paragraphs;
    // One outside the book starts it from the beginning
    const place = place_in(paragraphs, saved.para, saved.byte) orelse book_model.Pos{};
    assert(place.para <= paragraphs.len);
    // Nothing from there on: null, and it's all laid out instead
    const progress = try paginate.Progressive.start(a, alloc, book_text, place) orelse return null;
    assert(std.meta.eql(progress.pages()[0], place));
    return progress;
}

/// A place saved in a file, by its paragraph's text index, in the book: null for one
/// outside it, as the file may be from another edition or damaged.
fn place_in(paragraphs: []const book_model.Paragraph, text_para: u32, byte: u32) ?book_model.Pos {
    const para = book_model.from_text_index(paragraphs, text_para);
    if (para >= paragraphs.len) return null;
    if (byte > paragraphs[para].text.len) return null;
    return .{ .para = para, .byte = byte };
}

/// Where the page a book opens at comes from: the first page laid out on a first open
/// (laid out from the reader's place), stock's percent when the Kindle's own reader
/// was on the book last, else the saved place.
const StartFrom = enum { first_laid_out, kindle_percent, saved_place };

/// The page to open at, from `from`.
fn start_page(
    pages: []const book_model.Pos,
    paragraphs: []const book_model.Paragraph,
    entry: *const catalog.Entry,
    saved: *const state.State,
    from: StartFrom,
) u32 {
    assert(pages.len > 0);
    assert(entry.kindle_percent <= 100);
    return switch (from) {
        .first_laid_out => 0,
        .kindle_percent => @intCast(@min(pages.len * entry.kindle_percent / 100, pages.len - 1)),
        .saved_place => @intCast(book_model.page_containing(
            pages,
            book_model.from_text_index(paragraphs, saved.para),
            saved.byte,
        )),
    };
}

/// What the reader counts and keeps with the book: words before each paragraph, for
/// time left, and the highlights and bookmarks, from the Kindle's database or, for
/// a book Amazon doesn't sync, from noface's own notes.
pub fn read_notes(
    a: *app.App,
    alloc: std.mem.Allocator,
    entry: *const catalog.Entry,
    files: note_store.Files,
    session: *sess.Session,
) !void {
    const paragraphs = session.paragraphs;
    assert(paragraphs.len > 0); // Parsing refuses a book without any
    session.words = try .count(alloc, paragraphs);
    assert(session.words.before.len == paragraphs.len + 1);
    try session.notes.load(alloc, entry, files, paragraphs);
    try hl.refresh_marks(a, session, alloc);
}
