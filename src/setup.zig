//! Putting an App together: its fonts at their sizes, its screen buffers, the files
//! it keeps in the data folder, and the page layout's margins. The Kindle (main.zig)
//! and the scenario tests (scenarios.zig) both start here, so a size or margin changed
//! here changes in both.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("app.zig");
const display = @import("display.zig");
const user_data = @import("user_data.zig");
const paths = @import("kindle/paths.zig");
const memory = @import("base/memory.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const Input = @import("kindle/input.zig").Input;
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const text = @import("layout/text.zig");
const books = @import("screens/books.zig");
const library_view = @import("library/view.zig");
const covers = @import("ui/covers.zig");
const book_model = @import("model/book.zig");
const glyph_cache = @import("gfx/glyph_cache.zig");
const workspace = @import("gfx/workspace.zig");
const image = @import("gfx/image.zig");
const decoder_memory = @import("gfx/decoder_memory.zig");
const device = @import("model/device.zig");
const style = @import("ui/style.zig");

/// What each memory region reserves, taken once at startup (`memory.Region`). Pages
/// come in as they're first touched, so a region costs what's used, not its size.
/// Sized from the peaks logged opening eight books of 1 to 70 MB (the
/// largest used 78 MB of the book's region), with room to spare.
pub const region_bytes = struct {
    /// Screen buffers (seven, 2 MB each), fonts and their glyphs, the open book's
    /// eight pictures and hyphenation: 16 to 24 MB measured, so 64 leaves room for
    /// glyphs of many sizes and a full picture cache.
    pub const app: u32 = 64 << 20;
    /// The glyph cache: its table and its log of bitmaps (`glyph_cache.Config`), at
    /// most 16 MB however many glyphs, fonts and sizes are drawn.
    pub const glyphs: u32 =
        std.mem.alignForward(u32, glyph_cache.Config.default.bytes(), memory.unit_bytes);
    /// Where a glyph is drawn before it's kept: its outline, the lines its curves are
    /// cut into, and its bitmap. Emptied before each glyph.
    pub const glyph_scratch: u32 = glyph_cache.scratch_bytes;
    /// Pictures being decoded: 15 MB for a large cover, but kept at
    /// the 128 MB the stb C libraries had, so every picture they decoded still decodes.
    /// The Zig decoders hand a picture on row by row, scaled as it comes: drawing an
    /// 8000x6000 JPEG takes 300 KB, where stb needed 120 MB; a progressive one keeps
    /// two bytes a pixel, and one past `workspace.bytes_max` is decoded smaller.
    pub const decoders: u32 = 128 << 20;
    /// The library: an item for every book it can hold (8 bytes each, touched only for
    /// the books there are), the buffers its index is built with, its books read back,
    /// and the pool the covers shown are kept in.
    pub const library: u32 = std.mem.alignForward(
        u32,
        books.shared_bytes_max + books.library_bytes + library_covers + library_slack,
        memory.unit_bytes,
    );
    /// What an EPUB is read for while the library is found: its zip directory, its
    /// package document and, the first time, its cover's bytes. Emptied after each
    /// book, so it holds one book's at a time; a larger cover is left for type.
    pub const library_scratch: u32 = 32 << 20;
    /// An open book: its text, pages and pictures' bytes. 12 to 78 MB measured (the
    /// 78 from a 70 MB EPUB); kept at the old limit, so every book that opened still
    /// does. A larger one shows a notice instead of opening, as before.
    pub const book: u32 = 128 << 20;
    /// An open book's pages after a text setting changed: emptied before each layout,
    /// so changing settings again and again takes no more. A layout's two lists of
    /// where pages start, joined, and the copy saved (see `book_bytes_per_page_min`).
    pub const pages: u32 = 32 << 20;
    /// One action's: a Go To list (27 KB measured) or search results (500 at most).
    pub const scratch: u32 = 8 << 20;
};

/// A page holds at least this many bytes of a book's text, at the largest type: the
/// pages region is sized for a book region full of text cut that finely.
const book_bytes_per_page_min = 128;

/// Room in the library's region for the cover pool, and for each of its two blocks
/// being rounded up to whole units.
const library_covers: u32 = covers.bytes + 2 * memory.unit_bytes;
/// Each block of the library's region rounded up to whole units, and room to spare.
const library_slack: u32 = 4 << 20;

comptime {
    // Every Kindle whose screen noface knows is one it starts on (hwtcon.supported_size),
    // and every layout is worked out for one screen (style.screen): until the layout
    // follows the screen it runs on, each known Kindle must have that screen, so adding
    // one with another stops the build here rather than drawing it the wrong size.
    for (std.enums.values(device.Model)) |model| {
        const s = device.screen(model);
        assert(s.width_px == style.screen.width_px);
        assert(s.height_px == style.screen.height_px);
        assert(s.dpi == style.screen.dpi);
    }
}

comptime {
    // Every region fits in the ~480 MB a Kindle has free beside Amazon's services
    const b = region_bytes;
    const reading_bytes = b.library + b.library_scratch + b.book + b.pages + b.scratch;
    const glyphs_bytes = b.glyphs + b.glyph_scratch;
    assert(b.app + b.decoders + glyphs_bytes + reading_bytes < 480 << 20);
    // Regions are whole units
    assert(b.glyphs % memory.unit_bytes == 0);
    assert(b.glyph_scratch % memory.unit_bytes == 0);
    assert(b.library % memory.unit_bytes == 0);
    assert(b.library_scratch % memory.unit_bytes == 0);
    // A book's region holds the largest book measured, with room to spare
    assert(b.book > 78 << 20);
    // A layout's lists of pages, joined and saved, fit for the most pages a book has
    const pages_most = b.book / book_bytes_per_page_min;
    assert(4 * pages_most * @sizeOf(book_model.Pos) <= b.pages);
    assert(b.pages % memory.unit_bytes == 0);
    // The decoders have what the stb C libraries had
    assert(b.decoders >= 128 << 20);
    // A picture's workspace leaves a quarter of the decoders' region to glyphs
    assert(workspace.bytes_max * 4 <= b.decoders * 3);
}

/// The regions an App reads in, reserved by the first `assemble` and kept for good:
/// the Kindle assembles one App, and the scenario tests one per scenario, in turn, each
/// reading in the same regions.
var reading: Reading = undefined;
var reading_reserved = false;

const Reading = struct {
    library: memory.Region,
    covers: covers.Pool, // In the library's region, for good
    covers_bytes: u64, // What the pool and the shared buffers take of the library's budget
    library_shared: library_view.Shared, // In the library's region, for good
    library_budget: memory.Budget, // Shared by a library list and the one reloaded after it
    library_scratch: memory.Region,
    book: memory.Region,
    pages: memory.Region,
    pages_budget: memory.Budget, // Emptied before each layout after a settings change
    scratch: memory.Region,
};

fn reserve_reading() !*Reading {
    if (reading_reserved) {
        // The last App closed its book and its library, so the next starts with
        // nothing open
        assert(reading.book.empty());
        assert(reading.pages.empty());
        assert(reading.pages_budget.live == 0);
        assert(reading.scratch.empty());
        assert(reading.library_scratch.empty());
        // Every library let go of, only the cover pool and the shared buffers left
        assert(reading.library_budget.live == reading.covers_bytes);
        reading.covers.clear(); // The next App's covers may differ under the same names
        return &reading;
    }
    reading.library = try .reserve("library", .heap, region_bytes.library);
    reading.library_budget = .{
        .name = "library",
        .region = &reading.library,
        .limit = region_bytes.library,
    };
    try reading.covers.init(&reading.library_budget);
    try reading.library_shared.init(&reading.library_budget);
    reading.covers_bytes = reading.library_budget.live;
    assert(reading.covers_bytes >= covers.bytes);
    reading.library_scratch = try .reserve("library scratch", .bump, region_bytes.library_scratch);
    reading.book = try .reserve("book", .bump, region_bytes.book);
    reading.pages = try .reserve("pages", .bump, region_bytes.pages);
    reading.pages_budget = .{
        .name = "pages",
        .region = &reading.pages,
        .limit = region_bytes.pages,
    };
    reading.scratch = try .reserve("scratch", .bump, region_bytes.scratch);
    reading_reserved = true;
    return &reading;
}

/// The decoders' region and budget, reserved by the first call and kept for good: the
/// Kindle and the scenario tests decode in the same region, so a
/// picture or font with no room shows off the Kindle too.
var decoders_region: memory.Region = undefined;
var decoders_budget: memory.Budget = undefined;
var decoders_reserved = false;

/// The budget the font and picture decoders take their memory from, for
/// `decoder_memory.use`.
pub fn decoders() !*memory.Budget {
    if (!decoders_reserved) {
        decoders_region = try .reserve("decoders", .heap, region_bytes.decoders);
        decoders_budget = .{
            .name = "decoders",
            .region = &decoders_region,
            .limit = region_bytes.decoders,
        };
        decoders_reserved = true;
    }
    assert(decoders_budget.region == &decoders_region);
    assert(decoders_budget.limit == decoders_region.bytes.len);
    return &decoders_budget;
}

/// The glyph cache and its regions, made by the first call and kept for good, as the
/// decoders' are: the Kindle and the scenario tests draw through the
/// same one.
var glyphs: glyph_cache.Reserved = undefined;
var glyphs_reserved = false;

/// Gives every font the glyph cache, reserved by the first call: before any text is
/// measured or drawn.
pub fn use_glyph_cache() !void {
    if (!glyphs_reserved) {
        try glyphs.reserve(.default, region_bytes.glyphs, region_bytes.glyph_scratch);
        glyphs_reserved = true;
    }
    // The cache took its table and cells once, and nothing since
    assert(glyphs.budgets[0].live <= region_bytes.glyphs);
    assert(glyphs.cache.scratch == &glyphs.budgets[1]);
    glyph_cache.use(&glyphs.cache);
}

/// The font files the interface and a book's fallback text are drawn with.
pub const FontFiles = struct {
    book: []const u8, // The book's regular face, for text with no typeface of its own
    book_bold: []const u8, // For titles set in the reading face
    ui: []const u8, // The interface's regular face
    ui_bold: []const u8,
};

/// The fonts an App points at, at their sizes. Lives as long as the App.
pub const Kit = struct {
    body: Font,
    note_font: Font,
    footer: Font, // Under the page: interface text
    reference: Font, // Note marks in the text: the book's own face
    title: Font,
    small: Font,
    caption: Font,
    hero: Font,
    cover_type: Font,

    pub fn init(files: FontFiles) !Kit {
        const kit: Kit = .{
            .body = try Font.init(files.book, 46, 1.35),
            .note_font = try Font.init(files.book, 36, 1.3),
            .footer = try Font.init(files.ui, 28, 1.2),
            .reference = try Font.init(files.book, 28, 1.2),
            .title = try Font.init(files.ui_bold, 34, 1.2),
            .small = try Font.init(files.ui, 34, 1.2),
            .caption = try Font.init(files.ui, 26, 1.2),
            .hero = try Font.init(files.book_bold, 56, 1.2),
            .cover_type = try Font.init(files.book_bold, 36, 1.2),
        };
        // Line heights come from the sizes above: a note sets smaller than the page,
        // and the footer smaller still
        assert(kit.note_font.line_height < kit.body.line_height);
        assert(kit.footer.line_height < kit.note_font.line_height);
        return kit;
    }
};

/// The files an App keeps in its data folder, by full path.
pub const DataFiles = struct {
    buffers: [4][320]u8 = undefined,
    settings: [:0]const u8 = "",
    speed: [:0]const u8 = "",
    journal: [:0]const u8 = "",
    battery: [:0]const u8 = "",

    /// Fills in the paths for data folder `dir`. `files` must stay where it is after.
    pub fn init(files: *DataFiles, dir: []const u8) !void {
        assert(files.settings.len == 0); // Filled in once
        files.settings = try init_path(&files.buffers[0], dir, paths.data.settings);
        files.speed = try init_path(&files.buffers[1], dir, paths.data.speed);
        files.journal = try init_path(&files.buffers[2], dir, paths.data.journal);
        files.battery = try init_path(&files.buffers[3], dir, paths.data.battery);
        // Each in its own buffer, so none overwrites another
        assert(files.settings.ptr != files.battery.ptr);
    }

    fn init_path(buffer: []u8, dir: []const u8, comptime name: []const u8) ![:0]const u8 {
        const path = try std.fmt.bufPrintSentinel(buffer, "{s}/" ++ name, .{dir}, 0);
        assert(std.mem.endsWith(u8, path, name));
        assert(path.len > name.len); // The folder, then the name
        return path;
    }
};

/// Where an App's parts come from. Everything here must outlive the App.
pub const Parts = struct {
    alloc: std.mem.Allocator, // Counted by app_budget
    app_budget: *memory.Budget,
    decoders_budget: *memory.Budget,
    screen: *hwtcon.Screen,
    input: *Input,
    kit: *Kit,
    data_dir: []const u8,
    files: *const DataFiles,
    library_path: [*:0]const u8,
};

/// An App with its buffers made and its saved settings, speed and journal read. The
/// caller may change what differs (where books are, the clock's offset, fonts) and
/// then calls `apply_settings`.
pub fn assemble(p: Parts) !app.App {
    const k = p.kit;
    const pixels = p.screen.pixels.len;
    assert(pixels > 0);
    assert(p.files.settings.len > 0); // DataFiles.init ran
    const regions = try reserve_reading();
    const speeds = user_data.load_speed(p.files.speed);
    const ui = Fonts{
        .title = &k.title,
        .small = &k.small,
        .caption = &k.caption,
        .hero = &k.hero,
        .cover = &k.cover_type,
    };
    const layout: text.Layout = .{
        .margin_x = 100,
        .margin_top = 90,
        .margin_bottom = 150,
        .indent = 60,
        .reference = &k.reference,
    };
    return .{
        .alloc = p.alloc,
        .app_budget = p.app_budget,
        .decoders_budget = p.decoders_budget,
        .library_budget = &regions.library_budget,
        .covers = &regions.covers,
        .library_shared = &regions.library_shared,
        .library_scratch_region = &regions.library_scratch,
        .book_region = &regions.book,
        .pages_budget = &regions.pages_budget,
        .scratch_region = &regions.scratch,
        .display = try display.Display.init(p.alloc, p.screen),
        .input = p.input,
        .body = &k.body,
        .note_font = &k.note_font,
        .footer = &k.footer,
        .ui = ui,
        .lock_kept = .{
            .saved = try p.alloc.alloc(u8, pixels),
            .cover = try p.alloc.alloc(u8, pixels),
        },
        .state_dir = p.data_dir,
        .library_path = p.library_path,
        .settings_path = p.files.settings,
        .speed_path = p.files.speed,
        .journal_path = p.files.journal,
        .battery_path = p.files.battery,
        .settings = user_data.load_settings(p.files.settings),
        .speed = speeds.speed,
        .running_pace = speeds.running_pace,
        .journal = user_data.load_journal(p.files.journal),
        .utc_offset = 0,
        .layout = layout,
    };
}

/// A JPEG of `width` x `height`, mid gray, in YCbCr at 4:2:0 as cameras write them:
/// every coefficient zero, so its scans are all zero bytes. A progressive one has a
/// scan of every component's DC, then one of the brightness's AC.
fn test_jpeg(alloc: std.mem.Allocator, width: u16, height: u16, progressive: bool) ![]u8 {
    assert(width > 0);
    assert(height > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const jfif = [_]u8{ 0xff, 0xe0, 0, 16, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0 };
    try out.appendSlice(alloc, &(.{ 0xff, 0xd8 } ++ jfif ++ .{ 0xff, 0xdb, 0, 67, 0 }));
    try out.appendNTimes(alloc, 1, 64); // Every quantizer 1
    const w: [2]u8 = @bitCast(std.mem.nativeToBig(u16, width));
    const h: [2]u8 = @bitCast(std.mem.nativeToBig(u16, height));
    const frame: u8 = if (progressive) 0xc2 else 0xc0;
    try out.appendSlice(alloc, &.{ 0xff, frame, 0, 17, 8, h[0], h[1], w[0], w[1], 3 });
    try out.appendSlice(alloc, &.{ 1, 0x22, 0, 2, 0x11, 0, 3, 0x11, 0 });
    // One code each, a 0 bit: for DC "no change", for AC "end of block"
    try out.appendSlice(alloc, &.{ 0xff, 0xc4, 0, 2 + 2 * 18 });
    for ([_]u8{ 0x00, 0x10 }) |table| {
        try out.appendSlice(alloc, &.{ table, 1 });
        try out.appendNTimes(alloc, 0, 16); // 15 more lengths, none; then the symbol 0
    }
    const mcus = @as(u64, (width + 15) / 16) * ((height + 15) / 16);
    const all = [_]u8{ 0xff, 0xda, 0, 12, 3, 1, 0, 2, 0, 3, 0 };
    if (progressive) {
        try test_jpeg_scan(alloc, &out, &(all ++ .{ 0, 0, 0 }), mcus * 6);
        const luma_blocks = @as(u64, (width + 7) / 8) * ((height + 7) / 8);
        const luma = [_]u8{ 0xff, 0xda, 0, 8, 1, 1, 0, 1, 63, 0 };
        try test_jpeg_scan(alloc, &out, &luma, luma_blocks);
    } else {
        try test_jpeg_scan(alloc, &out, &(all ++ .{ 0, 63, 0 }), mcus * 6 * 2);
    }
    try out.appendSlice(alloc, &.{ 0xff, 0xd9 });
    return out.toOwnedSlice(alloc);
}

fn test_jpeg_scan(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    header: []const u8,
    bits: u64,
) !void {
    assert(header.len >= 10);
    assert(bits > 0);
    try out.appendSlice(alloc, header);
    try out.appendNTimes(alloc, 0, @intCast((bits + 7) / 8));
}

/// A `side` x `side` RGB PNG, black, its data stored uncompressed in IDAT chunks of
/// `chunk` bytes, as libpng writes them: a joined copy is as large as the pixels' data.
fn test_png(alloc: std.mem.Allocator, side: u32, chunk: u32) ![]u8 {
    assert(side > 0);
    assert(chunk > 0);
    const raw_size = side * (1 + side * 3); // Each row: filter 0, then its samples
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(alloc);
    try stream.appendSlice(alloc, &.{ 0x78, 0x01 });
    var left = raw_size;
    for (0..raw_size / 65535 + 1) |_| {
        const length: u16 = @intCast(@min(left, 65535));
        left -= length;
        const last: u8 = if (left == 0) 1 else 0;
        const l: [2]u8 = @bitCast(std.mem.nativeToLittle(u16, length));
        try stream.appendSlice(alloc, &.{ last, l[0], l[1], ~l[0], ~l[1] });
        try stream.appendNTimes(alloc, 0, length);
        if (left == 0) break;
    }
    try stream.appendNTimes(alloc, 0, 4); // The checksum, which nothing reads
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\x89PNG\r\n\x1a\n");
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], side, .big);
    std.mem.writeInt(u32, header[4..8], side, .big);
    header[8] = 8; // Bits per sample
    header[9] = 2; // RGB
    try test_png_chunk(alloc, &out, "IHDR", &header);
    const chunks: u32 = @intCast((stream.items.len + chunk - 1) / chunk);
    for (0..chunks) |index| {
        const at = index * chunk;
        const end = @min(at + chunk, stream.items.len);
        try test_png_chunk(alloc, &out, "IDAT", stream.items[at..end]);
    }
    try test_png_chunk(alloc, &out, "IEND", "");
    return out.toOwnedSlice(alloc);
}

fn test_png_chunk(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    kind: *const [4]u8,
    body: []const u8,
) !void {
    assert(body.len <= std.math.maxInt(u32));
    assert(kind[0] >= 'A');
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(body.len), .big);
    try out.appendSlice(alloc, &length);
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, body);
    try out.appendNTimes(alloc, 0, 4); // Its checksum, which stb_image never read
}

test "the decoders' region decodes the largest pictures stb decoded in its 128 MB" {
    var region = try memory.Region.reserve("decoders", .heap, region_bytes.decoders);
    defer region.release();
    var budget = memory.Budget{
        .name = "decoders",
        .region = &region,
        .limit = region_bytes.decoders,
    };
    // Through the app's own way in: its workspace limit, and the smaller decode it
    // falls back to, which a picture's full width below shows wasn't needed
    decoder_memory.use(&budget);
    defer decoder_memory.stop_using(&budget);
    const alloc = std.testing.allocator;
    const Kind = enum { baseline, progressive, png };
    const Case = struct { width: u16, height: u16, kind: Kind };
    const cases = [_]Case{
        // Turned down by a 64 MB region: stb took 28 to 65 MB for these
        .{ .width = 4000, .height = 6000, .kind = .baseline },
        .{ .width = 3000, .height = 4000, .kind = .progressive },
        .{ .width = 3000, .height = 3000, .kind = .png },
        // Near the largest stb read in 128 MB: it took 120 MB, and 114
        .{ .width = 8000, .height = 6000, .kind = .baseline },
        .{ .width = 4000, .height = 5200, .kind = .progressive },
    };
    for (cases) |case| {
        const data = switch (case.kind) {
            .baseline => try test_jpeg(alloc, case.width, case.height, false),
            .progressive => try test_jpeg(alloc, case.width, case.height, true),
            .png => try test_png(alloc, case.width, 8 << 10),
        };
        defer alloc.free(data);
        budget.peak = 0;
        const picture = image.decode_gray(budget.allocator(), data) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u32, case.width), picture.width);
        try std.testing.expectEqual(@as(u32, case.height), picture.height);
        budget.allocator().free(picture.pixels);
        try std.testing.expectEqual(@as(u64, 0), budget.live);
        try std.testing.expect(budget.peak < region_bytes.decoders / 2); // 61 MB at most
    }
}
