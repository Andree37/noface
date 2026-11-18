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
const stats = @import("model/stats.zig");
const cover = @import("gfx/image.zig");
const draw = @import("ui/draw.zig");
const state = @import("sys/state.zig");
const Fonts = @import("ui/fonts.zig").Fonts;
const input_mod = @import("kindle/input.zig");
const aa = @import("ui/aa.zig");
const file = @import("sys/file.zig");
const calls = @import("sys/calls.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const library = @import("ui/library.zig");
const covers_ui = @import("ui/covers.zig");
const library_view = @import("library/view.zig");
const clock = @import("sys/clock.zig");
const jpegxr = @import("kindle/jpegxr.zig");
const quick_model = @import("model/quick.zig");
const text = @import("layout/text.zig");
const hyphen = @import("layout/hyphen.zig");
const journal_model = @import("model/journal.zig");
const dictionary = @import("model/dictionary.zig");
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

/// Where the clock's text sits, down from the top of its band.
const clock_baseline_px = 38;

pub const notice_ms = 1800;

/// How many languages noface hyphenates and has dictionaries for.
const languages_count = @typeInfo(hyphen.Lang).@"enum".field_names.len;

comptime {
    // The clock's text is drawn inside the band its partial refresh covers.
    assert(clock_baseline_px < clock_height_px);
    assert(clock_height_px < clock_width_px);
    // A face's book size and the reader's size each fit a byte of a font's key
    assert(book_model.size_scales.len <= std.math.maxInt(u8));
    assert(settings_model.sizes.len <= std.math.maxInt(u8));
    // Every language has a dictionary file, named in `dictionary_for`.
    assert(languages_count == 2);
    // The interface's own family is the first, and always offered.
    assert(settings_model.builtin_families.len >= 1);
    // A face's book size starts at its normal step.
    assert(book_model.normal_size < book_model.size_scales.len);
}

pub const Slot = struct { page: ?u32 = null, buf: []u8, hits: text.Hits = .{} }; // Null: empty

/// What the Aa sheet keeps from one book to the next: only the reader's controls use
/// it (screens/reader/controls.zig).
pub const AaKept = struct {
    tab: aa.Tab = .font,
    family_first: u32 = 0, // The first typeface on the sheet's page of them
    family_sample_ptrs: [aa.family_cells_max]?*Font = @splat(null),
};

/// What the lock screen keeps from one lock to the next: only it uses it
/// (screens/lock.zig).
pub const LockKept = struct {
    saved: []u8, // The screen under it, to put back on waking
    cover: []u8, // What the lock screen last drew, full screen
    shown: ?LockShown = null, // What `cover` holds, so it isn't drawn again; null at first
    picture_bad: ?u64 = null, // A picture of the reader's that didn't decode, by its hash
};

/// What the lock screen shows: the reader's own picture, a book's cover (or its title,
/// for one without), or the title on white for no book. Pictures and books are told
/// apart by a hash, so a replaced picture or another book is drawn again.
pub const LockShown = union(enum) { picture: u64, book: u64, no_book };

pub const App = struct {
    alloc: std.mem.Allocator, // Lives as long as the app, counted by app_budget
    app_budget: *memory.Budget,
    decoders_budget: *memory.Budget,
    // Reserved at startup, like the app's: the library's list and covers (a budget
    // that outlives each list), what each EPUB is read for while the library is found,
    // the open book's memory, and one action's
    library_budget: *memory.Budget,
    covers: *covers_ui.Pool, // The library's, in its region, kept for good
    library_shared: *library_view.Shared, // The library's buffers, in its region, kept for good
    library_scratch_region: *memory.Region,
    book_region: *memory.Region,
    // An open book's pages after a settings change, emptied before each layout
    pages_budget: *memory.Budget,
    scratch_region: *memory.Region,
    screen: *hwtcon.Screen,
    input: *Input,
    body: *Font,
    // The reading face's fonts by family, face (bold, italic), reader size and book
    // size, and each family's name in itself for Aa: made on first use, the least used
    // given up past a fixed number
    typefaces: Typefaces = .{},
    aa_kept: AaKept = .{},
    note_font: *Font,
    footer: *Font,
    ui: Fonts,
    slots: [3]Slot,
    overlay: []u8,
    lock_kept: LockKept,
    state_dir: []const u8,
    library_path: [*:0]const u8,
    settings_path: [*:0]const u8,
    speed_path: [*:0]const u8,
    journal_path: [*:0]const u8,
    battery_path: [*:0]const u8,
    documents: []const u8 = paths.documents, // Where EPUBs copied over USB are found
    battery_last: ?battery_model.Sample = null, // Last level noted, so only changes are logged
    downloads_until: u64 = 0, // A download may still be running until then (now_us)
    dictionary_base: []const u8 = dict_download.default_base, // Where dictionaries download from
    wifi_hands_off: bool = false, // The reader took charge of airplane mode in this book
    /// When to turn Wi-Fi off while a book is read (kindle/wifi_saver.zig), null once
    /// that's settled: set as a book opens, and again by a dictionary's download that
    /// turned noface's pause back off.
    wifi_off_at: ?u64 = null,
    journal: journal_model.Journal = .{}, // What was read each day, for the stats screen
    speed: stats.Speed = .{}, // How fast this reader reads, across every book
    pictures: Pictures = .{}, // Pictures of the open book, ready to copy onto pages
    settings: settings_model.Settings,
    quick: quick_model.Quick = .{},
    utc_offset: i64,
    clock_minute: u64 = 0,
    layout: text.Layout,
    // Made the first time a book in that language opens, then kept
    hyphenators: [languages_count]?hyphen.Hyphenator = @splat(null),
    // Mapped the first time a word in that language is looked up, then kept
    dictionaries: [languages_count]?dictionary.Dictionary = @splat(null),

    /// Lets go of everything the App holds for its whole life: the buffers
    /// `setup.assemble` made, the hyphenation and pictures in `alloc`, and the font and
    /// dictionary files mapped. On the Kindle noface exits instead; the scenarios
    /// assemble an App for each, in turn, on the Kindle's own budget, so each gives
    /// all of it back for the next. Its book and library are closed by then.
    pub fn release(a: *App) void {
        assert(a.book_region.empty()); // The book let go of its own first
        a.typefaces.release();
        for (std.enums.values(hyphen.Lang)) |lang| a.forget_dictionary(lang);
        for (&a.hyphenators) |*slot| {
            if (slot.*) |*hyphenator| hyphenator.deinit();
            slot.* = null;
        }
        a.pictures.clear(a.alloc);
        for (&a.slots) |*slot| {
            assert(slot.buf.len == a.screen.pixels.len); // As assembled
            a.alloc.free(slot.buf);
        }
        a.alloc.free(a.overlay);
        a.alloc.free(a.lock_kept.saved);
        a.alloc.free(a.lock_kept.cover);
        a.* = undefined;
    }

    /// Forgets a language's dictionary, so the next lookup maps the file again: after
    /// one has just been downloaded.
    pub fn forget_dictionary(a: *App, lang: hyphen.Lang) void {
        const slot = &a.dictionaries[@backingInt(lang)];
        if (slot.*) |d| {
            assert(d.data.len > 0); // An empty file is an error from file.map
            file.unmap(d.data);
        }
        slot.* = null;
    }

    /// The dictionary for a book's language, from dict-en or dict-pt beside the
    /// settings. Null when the language isn't known or its file isn't there.
    pub fn dictionary_for(a: *App, lang: ?hyphen.Lang) ?dictionary.Dictionary {
        const l = lang orelse return null;
        const slot = &a.dictionaries[@backingInt(l)];
        if (slot.* == null) {
            var buf: [320]u8 = undefined;
            const name = switch (l) {
                .english => "dict-en",
                .portuguese => "dict-pt",
            };
            const path = std.fmt.bufPrintSentinel(
                &buf,
                "{s}/{s}",
                .{ a.state_dir, name },
                0,
            ) catch return null;
            const data = file.map(path) catch return null;
            assert(data.len > 0); // An empty file is an error from file.map
            slot.* = dictionary.Dictionary.open(data) orelse {
                file.unmap(data);
                std.debug.print("dictionary {s} unreadable\n", .{name});
                return null;
            };
            assert(slot.*.?.data.ptr == data.ptr);
        }
        assert(slot.* != null);
        return slot.*;
    }

    /// Today, as the journal counts days: the local calendar day.
    pub fn today(a: *const App) i32 {
        return journal_model.day_of(unix_time(), a.utc_offset);
    }

    /// Hyphenation for a book's language, or null to break only at spaces and dashes.
    pub fn hyphenator_for(a: *App, lang: ?hyphen.Lang) ?*const hyphen.Hyphenator {
        const l = lang orelse return null;
        const slot = &a.hyphenators[@backingInt(l)];
        if (slot.* == null) {
            slot.* = hyphen.Hyphenator.init(a.alloc, l) catch |err| {
                std.debug.print("hyphenation not loaded: {s}\n", .{@errorName(err)});
                return null;
            };
        }
        assert(slot.* != null);
        return &slot.*.?;
    }

    /// Fonts are kept per size, so stepping through sizes doesn't reload them.
    pub fn apply_settings(a: *App) !void {
        // Parsing clamps every setting to its steps: one past them is a bug of ours
        assert(a.settings.margin < settings_model.margins.len);
        a.body = try a.face(false, false, book_model.normal_size);
        a.layout.faces = .{ .ctx = a, .pick = pick_face };
        a.layout.images = .{ .ctx = a, .draw = draw_image };
        a.layout.margin_x = settings_model.margins[a.settings.margin];
        a.layout.justify = !a.settings.left_align;
        a.layout.bold_starts = a.settings.bold_starts;
        // The Aa sheet shows the page of typefaces with the one chosen
        a.aa_kept.family_first = aa.family_page_of(a.settings.family_index());
        assert(a.layout.margin_x > 0);
        assert(a.body.line_height > 0);
    }

    /// The typefaces on the Aa sheet's page of them, from `family_first`, at interface
    /// size, to show their names in themselves. One that can't be loaded is null, and
    /// its name shows in the interface font.
    pub fn load_family_samples(a: *App) []const ?*Font {
        const families_count = settings_model.families.len;
        assert(a.aa_kept.family_first < families_count);
        const shown = @min(aa.families_per_page(), families_count - a.aa_kept.family_first);
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
        assert(a.settings.size < settings_model.sizes.len);
        const bold = bold_text or a.settings.bold;
        const which: u2 = @as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1;
        const scale = book_model.size_scales[size];
        const key: typefaces.FaceKey = .{
            .family = a.settings.family_index(),
            .which = which,
            .size = @intCast(a.settings.size),
            .scale = size,
        };
        // The body font is in use between pages too, so it's never the one given up
        const font = try a.typefaces.face(key, a.settings.px() * scale, a.body);
        // Spacing can change without the font changing, so set it every time.
        const line_height_px: f32 = @floatFromInt(a.settings.line_height());
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

    pub fn page(a: *App, buf: []u8) Page {
        // A row of the screen's memory holds at least a row of pixels
        assert(a.screen.width > 0);
        assert(a.screen.stride >= a.screen.width);
        return .{
            .buf = buf,
            .width = a.screen.width,
            .height = a.screen.height,
            .stride = a.screen.stride,
        };
    }

    /// Outlines a book at once, using the fastest waveform, and waits so it can't
    /// collide with what's drawn next.
    pub fn flash(a: *App, r: library.Rect) void {
        const target = a.page(a.screen.pixels);
        const t = 6;
        // The outline's four bars lie inside the book, and the book on the screen
        assert(r.w >= t);
        assert(r.h >= t);
        assert(r.x + r.w <= a.screen.width);
        assert(r.y + r.h <= a.screen.height);
        target.fill_rect(r.x, r.y, r.w, t, 0x00);
        target.fill_rect(r.x, r.y + r.h - t, r.w, t, 0x00);
        target.fill_rect(r.x, r.y, t, r.h, 0x00);
        target.fill_rect(r.x + r.w - t, r.y, t, r.h, 0x00);
        const marker = a.screen.show_region(r.x, r.y, r.w, r.h, .quick) catch return;
        a.screen.wait_complete(marker) catch {}; // Ignored: the outline is shown either way.
    }

    /// Writes the time into the page on screen, without refreshing the panel.
    pub fn stamp_clock(a: *App) void {
        if (!a.settings.clock) return;
        assert(a.screen.width >= clock_width_px);
        assert(a.screen.height >= clock_top_px + clock_height_px);
        const target = a.page(a.screen.pixels);
        const left = (a.screen.width - clock_width_px) / 2;
        target.fill_rect(left, clock_top_px, clock_width_px, clock_height_px, 0xff);
        var buf: [8]u8 = undefined;
        const time = clock.format_clock(&buf, @intCast(unix_time()), a.utc_offset);
        const center_x: f32 = @floatFromInt(a.screen.width / 2);
        const baseline_y = clock_top_px + clock_baseline_px;
        const font = a.ui.caption;
        draw.centered(font, target, center_x, baseline_y, time) catch {}; // Ignored: a blank clock.
        a.clock_minute = unix_time() / 60;
    }

    /// Notes the battery level if it changed, for how long it will last.
    pub fn note_battery(a: *App) void {
        battery_log.note(a.battery_path, &a.battery_last);
    }

    /// Redraws just the clock, which is too small to need a flash.
    pub fn update_clock(a: *App) !void {
        if (!a.settings.clock) return;
        a.stamp_clock();
        const left = (a.screen.width - clock_width_px) / 2;
        assert(left + clock_width_px <= a.screen.width);
        const marker = try a.screen.show_region(
            left,
            clock_top_px,
            clock_width_px,
            clock_height_px,
            .clock,
        );
        try a.screen.wait_complete(marker);
    }

    /// Refreshes part of the screen with the page waveform, and waits for it.
    pub fn show_rect(a: *App, left: u32, top: u32, width: u32, height: u32) !void {
        // The same as the screen checks for every update, said where it's asked for
        assert(width > 0);
        assert(height > 0);
        assert(left + width <= a.screen.width);
        assert(top + height <= a.screen.height);
        try a.screen.wait_complete(try a.screen.show_region(left, top, width, height, .page));
    }

    /// Refreshes a full-width band of the screen, and waits for it.
    pub fn show_band(a: *App, top: u32, height: u32) !void {
        assert(height > 0);
        assert(top + height <= a.screen.height);
        try a.show_rect(0, top, a.screen.width, height);
    }

    /// The cached page buffer holding `page`, if any.
    pub fn slot_for(a: *App, page_index: u32) ?*Slot {
        assert(a.slots.len > 0);
        for (&a.slots) |*slot| {
            assert(slot.buf.len == a.screen.pixels.len); // Each holds a whole screen
            const held = slot.page orelse continue;
            if (held == page_index) return slot;
        }
        return null;
    }

    /// Drops every cached page, after anything that changes how pages look.
    pub fn forget_pages(a: *App) void {
        for (&a.slots) |*slot| {
            assert(slot.buf.len == a.screen.pixels.len); // Each holds a whole screen
            slot.page = null;
        }
    }

    /// Where a book's reading position is kept.
    pub fn state_path(a: *const App, buf: []u8, book_path: []const u8) ![:0]u8 {
        const path = try state.path_for(buf, a.state_dir, book_path);
        assert(std.mem.startsWith(u8, path, a.state_dir)); // Inside the data folder
        assert(path.len > a.state_dir.len);
        return path;
    }

    pub fn present(a: *App, buf: []const u8, refresh: hwtcon.Refresh) !void {
        assert(buf.len == a.screen.pixels.len); // A whole screen, drawn elsewhere
        assert(buf.ptr != a.screen.pixels.ptr); // Not the screen itself
        @memcpy(a.screen.pixels, buf);
        try a.screen.wait_complete(try a.screen.show(refresh));
    }
};

/// Says something went wrong, over the page, for a moment.
pub fn show_notice(a: *App, message: []const u8) !void {
    const screen_page = a.page(a.screen.pixels);
    const width: u32 = 760;
    const height: u32 = 100;
    const bottom_gap: u32 = 260; // From the box's top to the screen's bottom
    assert(message.len > 0);
    assert(a.screen.width >= width);
    assert(a.screen.height >= bottom_gap);
    const left = (a.screen.width - width) / 2;
    const top = a.screen.height - bottom_gap;
    draw.box(screen_page, left, top, width, height);
    const center_x: f32 = @floatFromInt(left + width / 2);
    try draw.centered(a.ui.small, screen_page, center_x, @intCast(top + 62), message);
    try a.show_rect(left, top, width, height);
    os.sleep_ms(notice_ms);
}

/// Settles a band after a drag: its smooth edges come back, without a flash. Full mode
/// would drive every pixel, but on this panel full mode always flashes.
pub fn clean_band(a: *App, top: u32, height: u32) !void {
    assert(height > 0);
    assert(top + height <= a.screen.height);
    try clean_rect(a, 0, top, a.screen.width, height);
}

pub fn clean_rect(a: *App, left: u32, top: u32, width: u32, height: u32) !void {
    // The same as the screen checks for every update, said where it's asked for
    assert(width > 0);
    assert(height > 0);
    assert(left + width <= a.screen.width);
    assert(top + height <= a.screen.height);
    try a.screen.wait_complete(try a.screen.show_region(left, top, width, height, .clean));
}

/// The journal saved at `path`: every day is in the file, which is mapped, never read
/// whole into memory; the journal keeps its latest days.
pub fn load_journal(path: [*:0]const u8) journal_model.Journal {
    const content = file.map(path) catch return .{};
    defer file.unmap(content);
    const journal = journal_model.parse(content);
    assert(journal.len <= journal.days.len); // The latest days, the rest in the file
    return journal;
}

/// Saves the journal: the days already in the file and older than memory holds, as
/// they are, then the days memory holds. Not saved when the file is there but can't be
/// read: written over, the days only it holds would be lost.
pub fn save_journal(a: *const App) void {
    var buf: [journal_model.max_format_bytes]u8 = undefined;
    assert(a.journal.len <= a.journal.days.len);
    const content = journal_model.format(&buf, &a.journal);
    assert(content.len >= journal_model.tag_line_bytes); // Sized for the longest journal
    const old: ?[]const u8 = file.map(a.journal_path) catch |err| switch (err) {
        // No file yet, or nothing in it: nothing older to keep
        error.NotFound, error.EmptyFile => null,
        error.OpenFailed, error.SeekFailed, error.MmapFailed => {
            log.info("journal not saved: {s}", .{@errorName(err)});
            return;
        },
    };
    defer if (old) |o| file.unmap(o);
    const first_day: ?i32 = if (a.journal.len > 0) a.journal.days[0].day else null;
    // No file, or nothing in it, has no day to keep
    const older = journal_model.older_lines(old orelse "", first_day);
    const parts = [_][]const u8{
        content[0..journal_model.tag_line_bytes],
        older[0],
        older[1], // A line break, when the file's last line had none
        content[journal_model.tag_line_bytes..],
    };
    file.write_parts(a.journal_path, &parts);
}

pub fn load_speed(path: [*:0]const u8) stats.Speed {
    var buf: [64]u8 = undefined;
    const speed = stats.parse(file.read_small(path, &buf));
    assert(speed.seconds >= 0); // Parsing starts over on anything else
    assert(speed.words >= 0);
    return speed;
}

pub fn save_speed(a: *const App) void {
    var buf: [64]u8 = undefined;
    assert(a.speed.seconds >= 0);
    assert(a.speed.words >= 0);
    file.write_small(a.speed_path, stats.format(&buf, a.speed));
}

pub fn load_settings(path: [*:0]const u8) settings_model.Settings {
    var buf: [settings_bytes_max]u8 = undefined;
    const settings = settings_model.parse(file.read_small(path, &buf));
    // Parsing clamps every value to its steps
    assert(settings.size < settings_model.sizes.len);
    assert(settings.font.len > 0);
    return settings;
}

/// Room for every setting with the longest typeface name a setting holds.
const settings_bytes_max = settings_model.family_bytes_max + 1024;

pub fn save_settings(path: [*:0]const u8, s: settings_model.Settings) void {
    assert(path[0] != 0);
    var buf: [settings_bytes_max]u8 = undefined;
    const content = settings_model.format(&buf, s);
    // Every setting but the name is a word or a number: the name is the only long one
    assert(content.len > 0);
    file.write_small(path, content);
}

/// The last few pictures drawn, decoded, scaled and dithered, so drawing a page
/// again doesn't decode them again. Keyed by where the picture's bytes sit in the
/// open book, so it must be cleared when the book closes.
pub const Pictures = struct {
    entries: [slots]?Entry = @splat(null), // Null until a picture is put there
    next: u32 = 0, // Which entry to replace next

    const slots = 8;
    const Entry = struct { key: [*]const u8, w: u32, h: u32, pixels: []u8 };

    pub fn get(p: *const Pictures, data: [*]const u8, w: u32, h: u32) ?[]const u8 {
        assert(p.next < slots);
        for (p.entries) |entry| {
            const e = entry orelse continue;
            if (e.key == data and e.w == w and e.h == h) {
                assert(e.pixels.len == @as(u64, w) * h); // As put
                return e.pixels;
            }
        }
        return null;
    }

    pub fn put(
        p: *Pictures,
        alloc: std.mem.Allocator,
        data: [*]const u8,
        w: u32,
        h: u32,
        pixels: []u8,
    ) void {
        assert(pixels.len == @as(u64, w) * h); // A whole picture at its size
        assert(p.next < slots);
        const slot = &p.entries[p.next];
        if (slot.*) |e| alloc.free(e.pixels);
        slot.* = .{ .key = data, .w = w, .h = h, .pixels = pixels };
        p.next = (p.next + 1) % slots;
    }

    pub fn clear(p: *Pictures, alloc: std.mem.Allocator) void {
        assert(p.next < slots);
        for (&p.entries) |*slot| {
            if (slot.*) |e| alloc.free(e.pixels);
            slot.* = null;
        }
        p.next = 0;
    }
};

test "pictures are kept until replaced or cleared" {
    const alloc = std.testing.allocator;
    var p = Pictures{};
    defer p.clear(alloc);
    const key = "abc";
    p.put(alloc, key.ptr, 2, 1, try alloc.dupe(u8, "xy"));
    try std.testing.expectEqualStrings("xy", p.get(key.ptr, 2, 1).?);
    try std.testing.expect(p.get(key.ptr, 4, 2) == null); // Another size
    for (0..Pictures.slots) |i| {
        p.put(alloc, @ptrFromInt(0x1000 + i), 1, 1, try alloc.dupe(u8, "z"));
    }
    try std.testing.expect(p.get(key.ptr, 2, 1) == null); // Pushed out
}

/// An App with only what saving the journal reads, its journal saved at "/tmp/<name>-<pid>".
fn journal_app(path_buffer: []u8, name: []const u8) !App {
    var a: App = undefined;
    a.journal = .{};
    const format = "/tmp/noface-{s}-{d}";
    const fields = .{ name, calls.getpid() };
    a.journal_path = try std.fmt.bufPrintSentinel(path_buffer, format, fields, 0);
    _ = calls.unlink(a.journal_path); // Ignored: only there after a run that stopped
    return a;
}

test "a journal that's there but can't be read is never written over" {
    var path_buffer: [64]u8 = undefined;
    var a = try journal_app(&path_buffer, "journal-unreadable");
    defer _ = calls.unlink(a.journal_path); // Ignored: only /tmp is left fuller
    a.journal.add(20_000, 600, 3);
    save_journal(&a);
    try std.testing.expectEqual(1, load_journal(a.journal_path).len);
    // A link to itself is there but can't be opened, as on a drive that fails a read
    _ = calls.unlink(a.journal_path); // Ignored: checked by the link made in its place
    try std.testing.expect(!os.failed(calls.symlink(a.journal_path, a.journal_path)));
    a.journal.add(20_001, 600, 3);
    save_journal(&a);
    // Still the link: nothing was renamed over it
    try std.testing.expectError(error.OpenFailed, file.map(a.journal_path));
}

test "the longest typeface name a setting holds saves and comes back" {
    defer settings_model.reset_families();
    var buffer: [64]u8 = undefined;
    const format = "/tmp/noface-settings-test-{d}";
    const path = try std.fmt.bufPrintSentinel(&buffer, format, .{calls.getpid()}, 0);
    defer _ = calls.unlink(path); // Ignored: only /tmp is left fuller
    // The longest a font file's name can make one: 255 characters, three bytes each
    const long: [255 * 3]u8 = comptime blk: {
        var name: [255 * 3]u8 = undefined;
        for (0..255) |i| name[i * 3 ..][0..3].* = "\u{6587}".*;
        break :blk name;
    };
    const kept = settings_model.builtin_families;
    settings_model.offer_families(&(kept ++ .{&long}));
    var s = settings_model.Settings{};
    s.font = settings_model.Family.of(&long).?;
    save_settings(path, s);
    try std.testing.expectEqual(s.font, load_settings(path).font);
    try std.testing.expect(s.family_index() + 1 == settings_model.families.len);
}
