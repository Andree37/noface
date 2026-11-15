//! What every screen shares: the screen, input, fonts, settings and page buffers.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("kindle/paths.zig");
const card = @import("ui/card.zig");
const memory = @import("base/memory.zig");
const fonts_db = @import("kindle/fonts.zig");
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
const screen = @import("screens/screen.zig");
const aa = @import("ui/aa.zig");
const file = @import("sys/file.zig");
const hwtcon = @import("kindle/hwtcon.zig");
const library = @import("ui/library.zig");
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

pub const clock_top_px = 16;

pub const clock_height_px = 56;

pub const clock_width_px = 160;

/// Where the clock's text sits, down from the top of its band.
const clock_baseline_px = 38;

pub const notice_ms = 1800;

/// The faces of a family: regular, bold, italic and bold italic, indexed by
/// bold | italic << 1.
const faces_per_family = 4;

/// How many languages noface hyphenates and has dictionaries for.
const languages_count = @typeInfo(hyphen.Lang).@"enum".field_names.len;

/// A family's body fonts in one face, by reader size and book size.
const FaceFontsBySize = [settings_model.sizes.len][book_model.size_scales.len]?Font;

comptime {
    // The clock's text is drawn inside the band its partial refresh covers.
    assert(clock_baseline_px < clock_height_px);
    assert(clock_height_px < clock_width_px);
    // Bold and italic, one bit each, pick one of the faces.
    assert(faces_per_family == 1 << 2);
    // Every language has a dictionary file, named in `dictionary_for`.
    assert(languages_count == 2);
    // The interface's own family is the first, and always offered.
    assert(settings_model.builtin_families.len >= 1);
    assert(settings_model.builtin_families.len <= settings_model.max_families);
    // A face's book size starts at its normal step.
    assert(book_model.normal_size < book_model.size_scales.len);
}

pub const Slot = struct { page: i64 = -1, buf: []u8, hits: text.Hits = .{} };

pub const App = struct {
    alloc: std.mem.Allocator, // Lives as long as the app, counted by app_budget
    app_budget: *memory.Budget,
    decoders_budget: *memory.Budget,
    // Reserved at startup, like the app's: the library's list and covers (a budget
    // that outlives each list), what each EPUB is read for while the library is found,
    // the open book's memory, and one action's
    library_budget: *memory.Budget,
    library_scratch_region: *memory.Region,
    book_region: *memory.Region,
    scratch_region: *memory.Region,
    screen: *hwtcon.Screen,
    input: *Input,
    body: *Font,
    // Body fonts by family, face (bold, italic), reader size and book size, made on first use.
    face_fonts: [settings_model.max_families][faces_per_family]FaceFontsBySize =
        @splat(@splat(@splat(@splat(null)))),
    face_files: [settings_model.max_families][faces_per_family]?[]const u8 = @splat(@splat(null)),
    // Each family's regular at interface size, for its name in Aa; made on first use
    family_samples: [settings_model.max_families]?Font = @splat(null),
    family_sample_ptrs: [settings_model.max_families]?*Font = @splat(null),
    tab: aa.Tab = .font,
    turns: u32 = 0,
    note_font: *Font,
    footer: *Font,
    ui: Fonts,
    slots: [3]Slot,
    overlay: []u8,
    lock_saved: []u8,
    lock_cover: []u8,
    // Which book's lock screen lock_cover holds, so it isn't decoded again; 0 for none
    lock_cover_key: u64 = 0,
    lock_picture_bad: u64 = 0, // A lock screen picture that didn't decode, not to try again
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
        assert(a.settings.font < settings_model.max_families);
        a.body = try a.face(false, false, book_model.normal_size);
        a.layout.faces = .{ .ctx = a, .pick = pick_face };
        a.layout.images = .{ .ctx = a, .draw = draw_image };
        a.layout.margin_x = settings_model.margins[a.settings.margin];
        a.layout.justify = !a.settings.left_align;
        a.layout.bold_starts = a.settings.bold_starts;
        assert(a.layout.margin_x > 0);
        assert(a.body.line_height > 0);
    }

    /// Each typeface offered, at interface size, to show its name in itself. One that
    /// can't be loaded is null, and its name shows in the interface font.
    pub fn load_family_samples(a: *App) []const ?*Font {
        const families_count = settings_model.families.len;
        assert(families_count >= settings_model.builtin_families.len);
        assert(families_count <= settings_model.max_families);
        for (0..families_count) |i| {
            if (a.family_sample_ptrs[i] != null) {
                assert(a.family_samples[i] != null); // The pointer points at it
                continue;
            }
            const file_slot = &a.face_files[i][0];
            if (file_slot.* == null) {
                file_slot.* = file.map(fonts_db.path(@intCast(i), false, false)) catch continue;
            }
            a.family_samples[i] = Font.init(a.alloc, file_slot.*.?, 36, 1.2) catch continue;
            a.family_sample_ptrs[i] = &a.family_samples[i].?;
        }
        return a.family_sample_ptrs[0..families_count];
    }

    /// The body font for a weight, slant and book size, in the reader's family and size.
    /// The reader's Bold setting makes everything bold.
    pub fn face(a: *App, bold_text: bool, italic: bool, size: u8) !*Font {
        assert(size < book_model.size_scales.len);
        // Parsing clamps every setting to its steps: one past them is a bug of ours
        assert(a.settings.font < settings_model.max_families);
        assert(a.settings.size < settings_model.sizes.len);
        const bold = bold_text or a.settings.bold;
        const which: u2 = @as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1;
        const file_slot = &a.face_files[a.settings.font][which];
        if (file_slot.* == null) {
            file_slot.* = try file.map(fonts_db.path(a.settings.font, bold, italic));
        }
        const scale = book_model.size_scales[size];
        const slot = &a.face_fonts[a.settings.font][which][a.settings.size][size];
        if (slot.* == null) {
            slot.* = try Font.init(a.alloc, file_slot.*.?, a.settings.px() * scale, 1);
        }
        // Spacing can change without the font changing, so set it every time.
        const line_height_px: f32 = @floatFromInt(a.settings.line_height());
        slot.*.?.line_height = @intFromFloat(line_height_px * scale);
        assert(slot.*.?.line_height > 0);
        return &slot.*.?;
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
            if (jpegxr.is_jpeg_xr(image.data)) {
                made = prepared_jpeg_xr(a.alloc, image.data, w, h);
            } else {
                made = cover.decode_and_prepare(a.alloc, image.data, w, h);
            }
            const pixels = made orelse {
                std.debug.print("picture not drawn\n", .{});
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
        const wanted: i64 = page_index;
        assert(wanted >= 0); // -1 marks an empty slot, never a page asked for
        for (&a.slots) |*slot| {
            assert(slot.buf.len == a.screen.pixels.len); // Each holds a whole screen
            if (slot.page == wanted) return slot;
        }
        return null;
    }

    /// Drops every cached page, after anything that changes how pages look.
    pub fn forget_pages(a: *App) void {
        for (&a.slots) |*slot| {
            assert(slot.buf.len == a.screen.pixels.len); // Each holds a whole screen
            assert(slot.page >= -1); // A page, or -1 for none
            slot.page = -1;
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

/// A card of rows over `background`, to open over a screen (`screen.open`): it ends
/// with the row tapped, or closes with a tap above it. Once it has ended, whatever
/// way, `card_closed` puts back what was under it.
pub fn card_over(
    a: *App,
    background: []const u8,
    title: []const u8,
    subtitle: []const u8,
    rows: []const card.Row,
    book_cover: ?card.Cover,
) Card {
    assert(background.len == a.screen.pixels.len); // Put back over the whole screen
    assert(a.overlay.len == a.screen.pixels.len); // The card is drawn there first
    return .{
        .a = a,
        .background = background,
        .title = title,
        .subtitle = subtitle,
        .rows = rows,
        .cover = book_cover,
    };
}

/// What was under a card, back on the whole screen.
pub fn card_closed(a: *App, background: []const u8) !void {
    assert(background.len == a.screen.pixels.len);
    assert(background.ptr != a.screen.pixels.ptr); // Kept apart from what's shown
    @memcpy(a.screen.pixels, background);
    try a.show_band(0, a.screen.height);
}

/// A card of rows over a dimmed screen: the row tapped, or closed by a tap above it.
pub const Card = struct {
    a: *App,
    background: []const u8,
    title: []const u8,
    subtitle: []const u8,
    rows: []const card.Row,
    cover: ?card.Cover,

    pub const Result = u32;
    pub const touches = input_mod.Input.Modes.sheet;

    pub fn draw(c: *Card, _: screen.Part) !void {
        const a = c.a;
        assert(a.overlay.len == a.screen.pixels.len);
        assert(c.background.len == a.overlay.len); // Both a whole screen
        @memcpy(a.overlay, c.background);
        try card.render_with(a.ui, a.page(a.overlay), c.title, c.subtitle, c.rows, c.cover);
        @memcpy(a.screen.pixels, a.overlay);
        try a.show_band(0, a.screen.height); // The whole screen dims behind it
    }

    pub fn on_tap(c: *Card, t: screen.Tap) !screen.Step(Result) {
        const rows: u32 = @intCast(c.rows.len);
        const index = card.hit_with(t.x, t.y, rows, c.cover) orelse return .close; // Above it
        return if (index < c.rows.len) .{ .done = index } else .stay; // Its title: nothing
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

/// Follows the dragged finger until it lifts, as a screen over the one the drag began
/// on (`screen.open`), made with the update that drew where it began (`marker`).
/// `follow.moved(x, y)` redraws for a new position and returns the update to wait on,
/// or null when nothing changed. Only one update runs at a time: overlapping ones
/// smear on the panel. Done when the finger lifts; interrupted when the Kindle locks.
/// Once it has ended, `drag_ended` waits for its last update.
pub fn Drag(comptime Follow: type) type {
    return struct {
        const D = @This();
        pub const Result = void;
        a: *App,
        follow: Follow,
        marker: ?u32,

        /// Where it began is drawn as it begins.
        pub fn draw(d: *D, part: screen.Part) !void {
            assert(part == .all);
            if (d.marker) |m| assert(m < d.a.screen.next_marker);
        }

        /// A tap while a finger is followed: nothing to do.
        pub fn on_tap(d: *D, _: screen.Tap) !screen.Step(void) {
            if (d.marker) |m| assert(m < d.a.screen.next_marker);
            assert(d.a.input.tick_us == 0); // It never ticks
            return .stay;
        }

        pub fn on_action(d: *D, action: input_mod.Action) !screen.Step(void) {
            switch (action) {
                .drag => |x0| {
                    if (d.marker) |m| try d.a.screen.wait_complete(m);
                    const x = d.a.input.latest_drag() orelse x0;
                    d.marker = try d.follow.moved(x, d.a.input.drag_y);
                    if (d.marker) |m| assert(m < d.a.screen.next_marker);
                    return .stay;
                },
                .drag_end => return .{ .done = {} },
                else => return .stay,
            }
        }
    };
}

/// A drag that has ended: its last update waited for. True when the finger lifted,
/// false when the drag was cut short (the Kindle locking, say).
pub fn drag_ended(d: anytype, ending: screen.Ending(void)) !bool {
    if (d.marker) |m| {
        assert(m < d.a.screen.next_marker);
        try d.a.screen.wait_complete(m);
    }
    d.marker = null;
    // A drag ends when the finger lifts, or the Kindle locks or noface leaves
    assert(ending != .closed);
    return ending == .done;
}

pub fn load_journal(path: [*:0]const u8) journal_model.Journal {
    var buf: [journal_model.max_format_bytes]u8 = undefined;
    const journal = journal_model.parse(state.read_small(path, &buf));
    assert(journal.len <= journal.days.len); // Parsing keeps what fits, dropping the rest
    return journal;
}

pub fn save_journal(a: *const App) void {
    var buf: [journal_model.max_format_bytes]u8 = undefined;
    assert(a.journal.len <= a.journal.days.len);
    const content = journal_model.format(&buf, &a.journal);
    assert(content.len > 0); // The buffer is sized for the longest journal
    state.write_small(a.journal_path, content);
}

pub fn load_speed(path: [*:0]const u8) stats.Speed {
    var buf: [64]u8 = undefined;
    const speed = stats.parse(state.read_small(path, &buf));
    assert(speed.seconds >= 0); // Parsing starts over on anything else
    assert(speed.words >= 0);
    return speed;
}

pub fn save_speed(a: *const App) void {
    var buf: [64]u8 = undefined;
    assert(a.speed.seconds >= 0);
    assert(a.speed.words >= 0);
    state.write_small(a.speed_path, stats.format(&buf, a.speed));
}

pub fn load_settings(path: [*:0]const u8) settings_model.Settings {
    var buf: [settings_bytes_max]u8 = undefined;
    const settings = settings_model.parse(state.read_small(path, &buf));
    // Parsing clamps every value to its steps
    assert(settings.size < settings_model.sizes.len);
    assert(settings.font < settings_model.max_families);
    return settings;
}

/// Room for every setting with the longest typeface name a file can give it: 255
/// characters of up to three bytes each, as a FAT folder holds them.
const settings_bytes_max = 1024;

/// Writes the settings to `path`. A typeface's name comes from its file, so one too
/// long to write leaves the file as it was, and says so in the log.
pub fn save_settings(path: [*:0]const u8, s: settings_model.Settings) void {
    assert(path[0] != 0);
    var buf: [settings_bytes_max]u8 = undefined;
    const content = settings_model.format(&buf, s);
    if (content.len == 0) {
        const message = "settings: not saved, the typeface's name is too long\n";
        if (!@import("builtin").is_test) std.debug.print(message, .{});
        return;
    }
    assert(content.len <= buf.len);
    state.write_small(path, content);
}

/// The last few pictures drawn, decoded, scaled and dithered, so drawing a page
/// again doesn't decode them again. Keyed by where the picture's bytes sit in the
/// open book, so it must be cleared when the book closes.
pub const Pictures = struct {
    entries: [slots]Entry = @splat(.{}),
    next: u32 = 0, // Which entry to replace next

    const slots = 8;
    const Entry = struct { key: u64 = 0, w: u32 = 0, h: u32 = 0, pixels: []u8 = &.{} };

    pub fn get(p: *const Pictures, data: [*]const u8, w: u32, h: u32) ?[]const u8 {
        const key: u64 = @intFromPtr(data);
        assert(key != 0); // 0 marks an empty entry
        for (p.entries) |e| {
            if (e.key == key and e.w == w and e.h == h) {
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
        const key: u64 = @intFromPtr(data);
        assert(key != 0); // 0 marks an empty entry
        assert(pixels.len == @as(u64, w) * h); // A whole picture at its size
        assert(p.next < slots);
        const e = &p.entries[p.next];
        if (e.key != 0) alloc.free(e.pixels);
        e.* = .{ .key = key, .w = w, .h = h, .pixels = pixels };
        p.next = (p.next + 1) % slots;
    }

    pub fn clear(p: *Pictures, alloc: std.mem.Allocator) void {
        assert(p.next < slots);
        for (&p.entries) |*e| {
            if (e.key != 0) alloc.free(e.pixels);
            e.* = .{};
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

test "a typeface's long name saves, and one too long to is left out, never a crash" {
    const linux = @import("sys/calls.zig");
    defer settings_model.reset_families();
    var buffer: [64]u8 = undefined;
    const format = "/tmp/noface-settings-test-{d}";
    const path = try std.fmt.bufPrintSentinel(&buffer, format, .{linux.getpid()}, 0);
    defer _ = linux.unlink(path); // Ignored: only /tmp is left fuller
    // The longest a font file's name can make one: 255 characters, three bytes each
    const long: [255 * 3]u8 = comptime blk: {
        var name: [255 * 3]u8 = undefined;
        for (0..255) |i| name[i * 3 ..][0..3].* = "\u{6587}".*;
        break :blk name;
    };
    try std.testing.expect(settings_model.add_family(&long));
    var s = settings_model.Settings{};
    s.font = @intCast(settings_model.families.len - 1);
    save_settings(path, s);
    try std.testing.expectEqual(s.font, load_settings(path).font);
    // Longer than any file's name: the settings stay as they were
    const longer: [2000]u8 = @splat('x');
    try std.testing.expect(settings_model.add_family(&longer));
    var other = s;
    other.font = @intCast(settings_model.families.len - 1);
    save_settings(path, other);
    try std.testing.expectEqual(s.font, load_settings(path).font);
}
