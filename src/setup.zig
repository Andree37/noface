//! Putting an App together: its fonts at their sizes, its screen buffers, the files
//! it keeps in the data folder, and the page layout's margins. The Kindle (main.zig),
//! the simulator (sim.zig) and the scenario tests (scenarios.zig) all start here, so
//! a size or margin changed here changes in all three.
const std = @import("std");
const assert = std.debug.assert;
const app = @import("app.zig");
const paths = @import("kindle/paths.zig");
const memory = @import("base/memory.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const Input = @import("kindle/input.zig").Input;
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const text = @import("layout/text.zig");

/// What each memory region reserves, taken once at startup (`memory.Region`). Pages
/// come in as they're first touched, so a region costs what's used, not its size.
/// Sized from the peaks the simulator logged opening eight books of 1 to 70 MB (the
/// largest used 78 MB of the book's region), with room to spare.
pub const region_bytes = struct {
    /// Screen buffers (seven, 2 MB each), fonts and their glyphs, the open book's
    /// eight pictures and hyphenation: 16 to 24 MB measured, so 64 leaves room for
    /// glyphs of many sizes and a full picture cache.
    pub const app: u32 = 64 << 20;
    /// Glyph bitmaps and pictures decoded by the stb C libraries: 15 MB measured at
    /// most (a large cover), so 64 for a picture four times that.
    pub const decoders: u32 = 64 << 20;
    /// The library's list and its covers, 84 KB each once seen; a reload holds two
    /// lists for a moment. A cover that doesn't fit is drawn as type instead.
    pub const library: u32 = 32 << 20;
    /// An open book: its text, pages and pictures' bytes. 12 to 78 MB measured (the
    /// 78 from a 70 MB EPUB); kept at the old limit, so every book that opened still
    /// does. A larger one shows a notice instead of opening, as before.
    pub const book: u32 = 128 << 20;
    /// One action's: a Go To list (27 KB measured) or search results (500 at most).
    pub const scratch: u32 = 8 << 20;
};

comptime {
    // Every region fits in the ~480 MB a Kindle has free beside Amazon's services
    const b = region_bytes;
    assert(b.app + b.decoders + b.library + b.book + b.scratch < 480 << 20);
    // A book's region holds the largest book measured, with room to spare
    assert(b.book > 78 << 20);
}

/// The regions an App reads in, reserved by the first `assemble` and kept for good:
/// the Kindle assembles one App, and the scenario tests one per scenario, in turn, each
/// reading in the same regions.
var reading: Reading = undefined;
var reading_reserved = false;

const Reading = struct {
    library: memory.Region,
    library_budget: memory.Budget, // Shared by a library list and the one reloaded after it
    book: memory.Region,
    scratch: memory.Region,
};

fn reserve_reading() !*Reading {
    if (reading_reserved) {
        // The last App closed its book and its library, so the next starts with
        // nothing open
        assert(reading.book.empty());
        assert(reading.scratch.empty());
        assert(reading.library_budget.live == 0);
        return &reading;
    }
    reading.library = try .reserve("library", .heap, region_bytes.library);
    reading.library_budget = .{
        .name = "library",
        .region = &reading.library,
        .limit = region_bytes.library,
    };
    reading.book = try .reserve("book", .bump, region_bytes.book);
    reading.scratch = try .reserve("scratch", .bump, region_bytes.scratch);
    reading_reserved = true;
    return &reading;
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

    pub fn init(alloc: std.mem.Allocator, files: FontFiles) !Kit {
        const kit: Kit = .{
            .body = try Font.init(alloc, files.book, 46, 1.35),
            .note_font = try Font.init(alloc, files.book, 36, 1.3),
            .footer = try Font.init(alloc, files.ui, 28, 1.2),
            .reference = try Font.init(alloc, files.book, 28, 1.2),
            .title = try Font.init(alloc, files.ui_bold, 34, 1.2),
            .small = try Font.init(alloc, files.ui, 34, 1.2),
            .caption = try Font.init(alloc, files.ui, 26, 1.2),
            .hero = try Font.init(alloc, files.book_bold, 56, 1.2),
            .cover_type = try Font.init(alloc, files.book_bold, 36, 1.2),
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
    var slots: [3]app.Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try p.alloc.alloc(u8, pixels) };
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
        .book_region = &regions.book,
        .scratch_region = &regions.scratch,
        .screen = p.screen,
        .input = p.input,
        .body = &k.body,
        .note_font = &k.note_font,
        .footer = &k.footer,
        .ui = ui,
        .slots = slots,
        .overlay = try p.alloc.alloc(u8, pixels),
        .lock_saved = try p.alloc.alloc(u8, pixels),
        .lock_cover = try p.alloc.alloc(u8, pixels),
        .state_dir = p.data_dir,
        .library_path = p.library_path,
        .settings_path = p.files.settings,
        .speed_path = p.files.speed,
        .journal_path = p.files.journal,
        .battery_path = p.files.battery,
        .settings = app.load_settings(p.files.settings),
        .speed = app.load_speed(p.files.speed),
        .journal = app.load_journal(p.files.journal),
        .utc_offset = 0,
        .layout = layout,
    };
}
