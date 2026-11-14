//! Putting an App together: its fonts at their sizes, its screen buffers, the files
//! it keeps in the data folder, and the page layout's margins. The Kindle (main.zig),
//! the simulator (sim.zig) and the scenario tests (scenarios.zig) all start here, so
//! a size or margin changed here changes in all three.
const std = @import("std");
const app = @import("app.zig");
const paths = @import("kindle/paths.zig");
const memory = @import("base/memory.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const Input = @import("kindle/input.zig").Input;
const Font = @import("gfx/font.zig").Font;
const Fonts = @import("ui/fonts.zig").Fonts;
const text = @import("layout/text.zig");

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

    pub fn init(alloc: std.mem.Allocator, f: FontFiles) !Kit {
        return .{
            .body = try Font.init(alloc, f.book, 46, 1.35),
            .note_font = try Font.init(alloc, f.book, 36, 1.3),
            .footer = try Font.init(alloc, f.ui, 28, 1.2),
            .reference = try Font.init(alloc, f.book, 28, 1.2),
            .title = try Font.init(alloc, f.ui_bold, 34, 1.2),
            .small = try Font.init(alloc, f.ui, 34, 1.2),
            .caption = try Font.init(alloc, f.ui, 26, 1.2),
            .hero = try Font.init(alloc, f.book_bold, 56, 1.2),
            .cover_type = try Font.init(alloc, f.book_bold, 36, 1.2),
        };
    }
};

/// The files an App keeps in its data folder, by full path.
pub const DataFiles = struct {
    bufs: [4][320]u8 = undefined,
    settings: [:0]const u8 = "",
    speed: [:0]const u8 = "",
    journal: [:0]const u8 = "",
    battery: [:0]const u8 = "",

    /// Fills in the paths for data folder `dir`. `d` must stay where it is after.
    pub fn init(d: *DataFiles, dir: []const u8) !void {
        d.settings = try std.fmt.bufPrintSentinel(&d.bufs[0], "{s}/" ++ paths.data.settings, .{dir}, 0);
        d.speed = try std.fmt.bufPrintSentinel(&d.bufs[1], "{s}/" ++ paths.data.speed, .{dir}, 0);
        d.journal = try std.fmt.bufPrintSentinel(&d.bufs[2], "{s}/" ++ paths.data.journal, .{dir}, 0);
        d.battery = try std.fmt.bufPrintSentinel(&d.bufs[3], "{s}/" ++ paths.data.battery, .{dir}, 0);
    }
};

/// Where an App's parts come from. Everything here must outlive the App.
pub const Parts = struct {
    alloc: std.mem.Allocator, // Counted by app_budget
    app_budget: *memory.Budget,
    stb_budget: *memory.Budget,
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
    var slots: [3]app.Slot = undefined;
    for (&slots) |*s| s.* = .{ .buf = try p.alloc.alloc(u8, pixels) };
    return .{
        .alloc = p.alloc,
        .app_budget = p.app_budget,
        .stb_budget = p.stb_budget,
        .screen = p.screen,
        .input = p.input,
        .body = &k.body,
        .note_font = &k.note_font,
        .footer = &k.footer,
        .ui = Fonts{ .title = &k.title, .small = &k.small, .caption = &k.caption, .hero = &k.hero, .cover = &k.cover_type },
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
        .layout = .{ .margin_x = 100, .margin_top = 90, .margin_bottom = 150, .indent = 60, .reference = &k.reference },
    };
}
