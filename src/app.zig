//! What every screen shares: the screen, input, fonts, settings and page buffers.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("kindle/paths.zig");
const memory = @import("base/memory.zig");
const typefaces = @import("typefaces.zig");
const Typefaces = typefaces.Typefaces;
const settings_model = @import("model/settings.zig");
const Page = @import("gfx/page.zig").Page;
const Font = @import("gfx/font.zig").Font;
const book_model = @import("model/book.zig");
const cover = @import("gfx/image.zig");
const picture_cache = @import("gfx/picture_cache.zig");
const draw = @import("ui/draw.zig");
const style = @import("ui/style.zig");
const state = @import("sys/state.zig");
const user_data = @import("user_data.zig");
const Fonts = @import("ui/fonts.zig").Fonts;
const input_mod = @import("kindle/input.zig");
const aa = @import("ui/aa.zig");
const lock = @import("ui/lock.zig");
const display_mod = @import("display.zig");
const Display = display_mod.Display;
const Regions = @import("regions.zig").Regions;
const Languages = @import("languages.zig").Languages;
const clock = @import("sys/clock.zig");
const jpegxr = @import("kindle/jpegxr.zig");
const quick_model = @import("model/quick.zig");
const text = @import("layout/text.zig");
const journal_model = @import("model/journal.zig");
const os = @import("sys/os.zig");
const battery_model = @import("model/battery.zig");
const battery_log = @import("kindle/battery_log.zig");
const dict_download = @import("kindle/dict_download.zig");
const Input = input_mod.Input;
const unix_time = os.unix_time;
/// Lines for noface's log, which the tests keep quiet (main.zig's `std_options`).
const log = std.log.scoped(.app);

pub const clock_top_px = 16;

pub const clock_height_px = 56;

pub const clock_width_px = 160;

pub const notice_ms = 1800;
/// The notice's box over the page, its text centred in it: its size, and its top from
/// the screen's bottom.
const notice_width_px = 760;
const notice_height_px = 100;
const notice_above_bottom_px = 260;

comptime {
    // The clock's text is drawn inside the band its partial refresh covers.
    assert(clock_height_px < clock_width_px);
    assert(notice_height_px < notice_above_bottom_px);
    assert(notice_width_px < style.screen.width_px);
    // A face's book size and the reader's size each fit a byte of a font's key
    assert(book_model.size_scales.len <= std.math.maxInt(u8));
    assert(settings_model.sizes.len <= std.math.maxInt(u8));
    // The interface's own family is the first, and always offered.
    assert(settings_model.builtin_families.len >= 1);
    // A face's book size starts at its normal step.
    assert(book_model.normal_size < book_model.size_scales.len);
}

pub const App = struct {
    alloc: std.mem.Allocator, // Lives as long as the app, counted by app_budget
    app_budget: *memory.Budget,
    decoders_budget: *memory.Budget,
    /// The memory it reads in, reserved at startup like the app's (regions.zig).
    regions: *Regions,
    /// The screen, the page cache and the overlay (display.zig).
    display: Display,
    input: *Input,
    body: *Font,
    // The reading face's fonts by family, face (bold, italic), reader size and book
    // size, and each family's name in itself for Aa: made on first use, the least used
    // given up past a fixed number
    typefaces: Typefaces = .{},
    aa_kept: aa.Kept = .{},
    note_font: *Font,
    footer: *Font,
    ui: Fonts,
    /// What the lock screen keeps between locks (ui/lock.zig).
    lock_kept: lock.Kept,
    state_dir: []const u8,
    library_path: [*:0]const u8,
    battery_path: [*:0]const u8,
    documents: []const u8 = paths.documents, // Where EPUBs copied over USB are found
    /// A test run, on a test folder's books: where what moves with the text was drawn
    /// goes in the log for its tests to tap (screens/placed.zig). Never the reader's own.
    logs_placed: bool = false,
    battery_last: ?battery_model.Sample = null, // Last level noted, so only changes are logged
    downloads_until: u64 = 0, // A download may still be running until then (now_us)
    dictionary_base: []const u8 = dict_download.default_base, // Where dictionaries download from
    wifi_hands_off: bool = false, // The reader took charge of airplane mode in this book
    /// When to turn Wi-Fi off while a book is read (kindle/wifi_saver.zig), null once
    /// that's settled: set as a book opens, and again by a dictionary's download that
    /// turned noface's pause back off.
    wifi_off_at: ?u64 = null,
    pictures: picture_cache.Pictures = .{}, // Pictures of the open book, ready to copy onto pages
    /// The reader's settings, speed and journal, and their files (user_data.zig).
    user: user_data.UserData,
    quick: quick_model.Quick = .{},
    utc_offset: i64,
    clock_minute: u64 = 0,
    layout: text.Layout,
    /// Hyphenation and dictionaries, by language (languages.zig).
    languages: Languages,

    /// Lets go of everything the App holds for its whole life: the buffers
    /// `setup.assemble` made, the hyphenation and pictures in `alloc`, and the font and
    /// dictionary files mapped. On the Kindle noface exits instead; the scenarios
    /// assemble an App for each, in turn, on the Kindle's own budget, so each gives
    /// all of it back for the next. Its book and library are closed by then.
    pub fn release(a: *App) void {
        assert(a.regions.book.empty()); // The book let go of its own first
        a.typefaces.release();
        a.languages.release();
        a.pictures.clear(a.alloc);
        a.display.release(a.alloc);
        a.lock_kept.release(a.alloc);
        a.* = undefined;
    }

    /// The typefaces on offer: the Kindle's, then the reader's own.
    pub fn families(a: *const App) settings_model.Families {
        return a.typefaces.offered.families;
    }

    /// Today, as the journal counts days: the local calendar day.
    pub fn today(a: *const App) i32 {
        return journal_model.day_of(unix_time(), a.utc_offset);
    }

    /// Fonts are kept per size, so stepping through sizes doesn't reload them.
    pub fn apply_settings(a: *App) !void {
        // Parsing clamps every setting to its steps: one past them is a bug of ours
        assert(a.user.settings.margin < settings_model.margins.len);
        a.body = try a.face(false, false, book_model.normal_size);
        a.layout.faces = .{ .ctx = a, .pick = pick_face };
        a.layout.images = .{ .ctx = a, .draw = draw_image };
        a.layout.margin_x = settings_model.margins[a.user.settings.margin];
        a.layout.justify = !a.user.settings.left_align;
        a.layout.bold_starts = a.user.settings.bold_starts;
        assert(a.layout.margin_x > 0);
        assert(a.body.line_height > 0);
    }

    /// The typefaces on the Aa sheet's page of them, from `family_first`, at interface
    /// size, to show their names in themselves. One that can't be loaded is null, and
    /// its name shows in the interface font.
    pub fn load_family_samples(a: *App) []const ?*Font {
        const offered = a.families();
        const first = a.aa_kept.family_first;
        assert(first < offered.count());
        const shown = @min(aa.families_per_page(offered), offered.count() - first);
        assert(shown <= a.aa_kept.family_sample_ptrs.len);
        for (a.aa_kept.family_sample_ptrs[0..shown], a.aa_kept.family_first..) |*sample, family| {
            sample.* = a.typefaces.sample(@intCast(family));
        }
        return a.aa_kept.family_sample_ptrs[0..shown];
    }

    /// The body font for a weight, slant and book size, in the reader's family and size.
    /// The reader's Bold setting makes everything bold.
    pub fn face(a: *App, bold_text: bool, italic: bool, size: u8) !*Font {
        assert(size < book_model.size_scales.len);
        // Parsing clamps every setting to its steps: one past them is a bug of ours
        assert(a.user.settings.size < settings_model.sizes.len);
        const bold = bold_text or a.user.settings.bold;
        const which: u2 = @as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1;
        const scale = book_model.size_scales[size];
        const key: typefaces.FaceKey = .{
            .family = a.user.settings.family_index(a.families()),
            .which = which,
            .size = @intCast(a.user.settings.size),
            .scale = size,
        };
        // The body font is in use between pages too, so it's never the one given up
        const font = try a.typefaces.face(key, a.user.settings.px() * scale, a.body);
        // Spacing can change without the font changing, so set it every time.
        const line_height_px: f32 = @floatFromInt(a.user.settings.line_height());
        font.line_height = @intFromFloat(line_height_px * scale);
        assert(font.line_height > 0);
        return font;
    }

    fn draw_image(
        ctx: *anyopaque,
        page_buf: Page,
        image: book_model.Image,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        // Only apply_settings installs this, with the App as its context
        assert(a.layout.images != null);
        assert(a.layout.images.?.ctx == ctx);
        const ready = a.pictures.get(image.data.ptr, w, h) orelse blk: {
            var made: ?[]u8 = null;
            if (image.inflate_to == null and jpegxr.is_jpeg_xr(image.data)) {
                made = prepared_jpeg_xr(a.alloc, image.data, w, h);
            } else {
                const encoded: cover.Encoded =
                    .{ .bytes = image.data, .inflate_to = image.inflate_to };
                made = cover.prepare_from(a.alloc, encoded, w, h);
            }
            const pixels = made orelse {
                // Not kept, so a picture that fails for want of memory is tried again
                std.debug.print("picture not drawn: {d}x{d}\n", .{ image.width, image.height });
                cover.placeholder(page_buf, x, y, w, h);
                return;
            };
            assert(pixels.len == @as(u64, w) * h); // Prepared at the size asked for
            a.pictures.put(a.alloc, image.data.ptr, w, h, pixels);
            break :blk pixels;
        };
        cover.blit(page_buf, ready, x, y, w, h);
    }

    fn prepared_jpeg_xr(alloc: std.mem.Allocator, data: []const u8, w: u32, h: u32) ?[]u8 {
        assert(jpegxr.is_jpeg_xr(data)); // Only called for JPEG XR, by draw_image
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const gray = jpegxr.decode_jpeg_xr(arena.allocator(), data, w, h) orelse return null;
        const pixels = cover.prepare(alloc, gray.pixels, gray.width, gray.height, w, h);
        if (pixels) |p| assert(p.len == @as(u64, w) * h);
        return pixels;
    }

    fn pick_face(ctx: *anyopaque, bold: bool, italic: bool, size: u8) anyerror!*Font {
        const a: *App = @ptrCast(@alignCast(ctx));
        // Only apply_settings installs this, with the App as its context
        assert(a.layout.faces != null);
        assert(a.layout.faces.?.ctx == ctx);
        return a.face(bold, italic, size) catch a.face(false, false, size);
    }

    /// Writes the time into the page on screen, without refreshing the panel.
    pub fn stamp_clock(a: *App) void {
        if (!a.user.settings.clock) return;
        assert(a.display.screen.width >= clock_width_px);
        assert(a.display.screen.height >= clock_top_px + clock_height_px);
        const target = a.display.on_screen();
        const left = (a.display.screen.width - clock_width_px) / 2;
        target.fill_rect(left, clock_top_px, clock_width_px, clock_height_px, 0xff);
        var buf: [8]u8 = undefined;
        const time = clock.format_clock(&buf, @intCast(unix_time()), a.utc_offset);
        const center_x: f32 = @floatFromInt(a.display.screen.width / 2);
        const font = a.ui.caption;
        const baseline_y = font.centred_baseline(clock_top_px, clock_height_px);
        draw.centered(font, target, center_x, baseline_y, time) catch {}; // Ignored: a blank clock.
        a.clock_minute = unix_time() / 60;
    }

    /// Notes the battery level if it changed, for how long it will last.
    pub fn note_battery(a: *App) void {
        battery_log.note(a.battery_path, &a.battery_last);
    }

    /// Redraws just the clock, which is too small to need a flash.
    pub fn update_clock(a: *App) !void {
        if (!a.user.settings.clock) return;
        a.stamp_clock();
        const left = (a.display.screen.width - clock_width_px) / 2;
        assert(left + clock_width_px <= a.display.screen.width);
        const marker = try a.display.screen.show_region(
            left,
            clock_top_px,
            clock_width_px,
            clock_height_px,
            .clock,
        );
        try a.display.screen.wait_complete(marker);
    }

    /// Where a book's reading position is kept.
    pub fn state_path(a: *const App, buf: []u8, book_path: []const u8) ![:0]u8 {
        const path = try state.path_for(buf, a.state_dir, book_path);
        assert(std.mem.startsWith(u8, path, a.state_dir)); // Inside the data folder
        assert(path.len > a.state_dir.len);
        return path;
    }
};

/// Says something went wrong, over the page, for a moment.
pub fn show_notice(a: *App, message: []const u8) !void {
    const d = &a.display;
    const screen_page = d.page(d.screen.pixels);
    assert(message.len > 0);
    assert(d.screen.width >= notice_width_px);
    assert(d.screen.height >= notice_above_bottom_px);
    const left = (d.screen.width - notice_width_px) / 2;
    const top = d.screen.height - notice_above_bottom_px;
    draw.box(screen_page, left, top, notice_width_px, notice_height_px);
    const center_x: f32 = @floatFromInt(left + notice_width_px / 2);
    const baseline = a.ui.small.centred_baseline(@intCast(top), notice_height_px);
    try draw.centered(a.ui.small, screen_page, center_x, baseline, message);
    try d.show_rect(left, top, notice_width_px, notice_height_px);
    os.sleep_ms(notice_ms);
}
