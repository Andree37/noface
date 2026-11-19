//! The reading toolbar and its Aa sheet.
const std = @import("std");
const assert = std.debug.assert;
const card_screen = @import("../card.zig");
const drag = @import("../drag.zig");
const autostart = @import("../../kindle/autostart.zig");
const card = @import("../../ui/card.zig");
const aa = @import("../../ui/aa.zig");
const settings_model = @import("../../model/settings.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const display = @import("../../display.zig");
const sess = @import("session.zig");
const lock = @import("../lock.zig");
const screen = @import("../screen.zig");

comptime {
    // The toolbar's top bar, or the tallest sheet, ends above its bottom bar, and the
    // page scrubber sits inside that bottom bar
    assert(toolbar.top_height < toolbar.bottom_top);
    assert(aa.max_height < toolbar.bottom_top);
    assert(toolbar.scrub_top > toolbar.bottom_top);
}

/// What the toolbar shows of the open book: its title, and whether running mode is on,
/// which Aa's Running button says.
pub const Book = struct { title: []const u8, running: bool };

/// How the toolbar is drawn: with its Aa sheet open or not, and whether the whole
/// page is shown again or only the bars.
pub const Drawn = struct { sheet_open: bool, whole_page: bool };

/// Draws the toolbar over the current page.
pub fn draw_toolbar(a: *app.App, s: *sess.Session, book: Book, drawn: Drawn) !void {
    assert(s.current < s.pages.len);
    const page = a.display.compose(try s.lend_current());
    // No page count until the pages are known
    const at: ?toolbar.Position =
        if (s.layout_pending()) null else .{ .index = s.current, .total = s.page_count() };
    var fonts = a.ui;
    if (drawn.sheet_open and a.aa_kept.tab == .font) {
        fonts.families = a.load_family_samples();
        fonts.family_first = a.aa_kept.family_first;
    }
    try toolbar.render(
        fonts,
        page,
        book.title,
        at,
        &a.quick,
        if (drawn.sheet_open) a.aa_kept.tab else null,
        a.settings,
        book.running,
        s.is_bookmarked(s.current),
    );
    a.display.put_composed();
    if (drawn.whole_page) {
        try a.display.screen.wait_complete(try s.show_band(0, a.display.screen.height));
        return;
    }
    try show_bars(a, s, drawn.sheet_open);
}

pub fn close_toolbar(a: *app.App, s: *sess.Session, sheet_open: bool) !void {
    assert(s.current < s.pages.len);
    @memcpy(a.display.screen.pixels, try s.ensure(s.current, s.current));
    // The page under the bars is all that changed
    assert(a.display.screen.pixels.len > 0);
    try show_bars(a, s, sheet_open);
}

/// Shows the screen where the toolbar's bars are, or were: the top bar (or the
/// tallest sheet's reach, as switching from More to a shorter tab uncovers the
/// page) and the bottom bar.
fn show_bars(a: *app.App, s: *const sess.Session, sheet_open: bool) !void {
    const top: u32 = if (sheet_open) aa.max_height else toolbar.top_height;
    assert(top < a.display.screen.height);
    assert(toolbar.bottom_top < a.display.screen.height);
    const first = try s.show_band(0, top);
    const bottom_height = a.display.screen.height - toolbar.bottom_top;
    try a.display.screen.wait_complete(try s.show_band(toolbar.bottom_top, bottom_height));
    try a.display.screen.wait_complete(first);
}

/// What the toolbar's controls opened over the book, kept while it's open: the page
/// scrubber or an Aa slider following a finger, or a card asking before a switch turns
/// on. `resumed` finishes what was begun once it has ended. Each is made in place, as
/// what it opens points into it, and stays until it has ended.
pub const Pending = union(enum) {
    none,
    scrub: Scrub,
    setting: Setting,
    autostart: Ask, // Before starting with the Kindle: the startup file goes in
    lock_picture: Ask, // Before the lock screen shows the reader's picture: there is one

    /// The scrubber: the page under the finger.
    const Scrub = struct {
        target: u32,
        page_count: u32,
        drag: drag.Drag(ScrubFollow) = undefined,
        ending: ?screen.Ending(void) = null,
    };

    /// An Aa slider: its row, its step under the finger, and the step it began at.
    const Setting = struct {
        row: aa.Row,
        value: u32,
        started: u32,
        drag: drag.Drag(SettingFollow) = undefined,
        ending: ?screen.Ending(void) = null,
    };

    /// A card asking about turning switch `toggle` on, over the page.
    const Ask = struct {
        toggle: u32,
        background: display.Backdrop, // The page under the card
        card: card_screen.Card = undefined,
        ending: ?screen.Ending(u32) = null,
    };
};

const ScrubFollow = struct {
    a: *app.App,
    page_count: u32,
    target: *u32,

    pub fn moved(f: ScrubFollow, x: i32, _: i32) !?u32 {
        assert(f.target.* < f.page_count);
        const next = toolbar.page_at(x, f.page_count);
        assert(next < f.page_count);
        if (next == f.target.*) return null;
        f.target.* = next;
        const pixels = f.a.display.on_screen();
        try toolbar.draw_scrub(f.a.ui, pixels, .{ .index = next, .total = f.page_count }, true);
        return try show_scrub(f.a);
    }
};

/// Shows the scrubber's band, following a finger, and returns the update.
fn show_scrub(a: *app.App) !u32 {
    assert(toolbar.scrub_top < a.display.screen.height);
    const band = a.display.screen.height - toolbar.scrub_top;
    return a.display.screen.show_region(0, toolbar.scrub_top, a.display.screen.width, band, .quick);
}

/// Follows a finger along the page scrubber, then jumps there: the screen to open
/// over the book.
pub fn drag_scrub(p: *Pending, a: *app.App, s: *sess.Session, first_x: i32) !screen.Frame {
    assert(s.pages.len > 0);
    assert(p.* == .none);
    const page_count = s.page_count();
    p.* = .{ .scrub = .{
        .target = toolbar.page_at(first_x, page_count),
        .page_count = page_count,
    } };
    const scrub = &p.scrub;
    assert(scrub.target < page_count);
    const at: toolbar.Position = .{ .index = scrub.target, .total = page_count };
    try toolbar.draw_scrub(a.ui, a.display.on_screen(), at, true);
    const first = try show_scrub(a);
    const follow = ScrubFollow{ .a = a, .page_count = page_count, .target = &scrub.target };
    scrub.drag = .{ .a = a, .follow = follow, .marker = first };
    return screen.open(&scrub.drag, &scrub.ending);
}

/// The setting an Aa slider row changes.
fn row_value(a: *const app.App, row: aa.Row) u32 {
    assert(row.steps > 0);
    const value = switch (row.slider) {
        .text_size => a.settings.size,
        .spacing => a.settings.spacing,
        .margins => a.settings.margin,
    };
    // Settings are brought inside their steps as they're read
    assert(value < row.steps);
    return value;
}

fn row_value_set(a: *app.App, row: aa.Row, value: u32) void {
    assert(row.steps > 0);
    assert(value < row.steps);
    switch (row.slider) {
        .text_size => a.settings.size = value,
        .spacing => a.settings.spacing = value,
        .margins => a.settings.margin = value,
    }
    assert(row_value(a, row) == value);
}

const SettingFollow = struct {
    a: *app.App,
    row: aa.Row,
    value: *u32,

    pub fn moved(f: SettingFollow, x: i32, _: i32) !?u32 {
        assert(f.value.* < f.row.steps);
        const next = aa.step_at(f.row, x);
        assert(next < f.row.steps);
        if (next == f.value.*) return null;
        f.value.* = next;
        try aa.draw_row(f.a.ui, f.a.display.on_screen(), f.row, next, true);
        const width = f.a.display.screen.width;
        return try f.a.display.screen.show_region(0, f.row.top, width, aa.row_height, .quick);
    }
};

/// Follows a finger along an Aa slider, and applies it when lifted: the screen to open
/// over the book.
fn drag_setting(p: *Pending, a: *app.App, row: aa.Row, first_x: i32) !screen.Frame {
    assert(p.* == .none);
    p.* = .{ .setting = .{
        .row = row,
        .value = aa.step_at(row, first_x),
        .started = row_value(a, row),
    } };
    const setting = &p.setting;
    assert(setting.value < row.steps);
    try aa.draw_row(a.ui, a.display.on_screen(), row, setting.value, true);
    const eink = a.display.screen;
    const first = try eink.show_region(0, row.top, eink.width, aa.row_height, .quick);
    const follow = SettingFollow{ .a = a, .row = row, .value = &setting.value };
    setting.drag = .{ .a = a, .follow = follow, .marker = first };
    return screen.open(&setting.drag, &setting.ending);
}

/// What a tap inside the Aa sheet did: all of it already, a slider or a card to open
/// over the book, or running mode to turn on or off, which the reader does.
pub const SheetTap = union(enum) { done, opened: screen.Frame, running };

/// Handles a tap inside the Aa sheet.
pub fn tap_sheet(
    p: *Pending,
    a: *app.App,
    s: *sess.Session,
    book: Book,
    x: i32,
    y: i32,
) !SheetTap {
    assert(s.current < s.pages.len);
    const sheet_only: Drawn = .{ .sheet_open = true, .whole_page = false };
    switch (aa.hit(a.aa_kept.tab, x, y)) {
        .none => return .done,
        .tab => |tab| {
            a.aa_kept.tab = tab;
            try draw_toolbar(a, s, book, sheet_only);
            return .done;
        },
        .text_size => return .{ .opened = try drag_setting(p, a, aa.size_row, x) },
        .spacing => return .{ .opened = try drag_setting(p, a, aa.spacing_row, x) },
        .margins => return .{ .opened = try drag_setting(p, a, aa.margin_row, x) },
        .running => return .running,
        .theme => |index| {
            assert(index < aa.themes.len);
            const theme = aa.themes[index];
            a.settings.size = theme.size;
            a.settings.spacing = theme.spacing;
            a.settings.margin = theme.margin;
        },
        .family => |cell| {
            const family = a.aa_kept.family_first + cell;
            // The last page may have fewer typefaces than cells
            if (family >= settings_model.families.len) return .done;
            a.settings.font = settings_model.Family.of(settings_model.families[family]).?;
        },
        .more_families => {
            a.aa_kept.family_first = aa.next_family_page(a.aa_kept.family_first);
            try draw_toolbar(a, s, book, sheet_only);
            return .done;
        },
        .toggle => |index| {
            assert(index < aa.switches.len);
            const turning_on = !aa.is_on(index, a.settings);
            if (turning_on) {
                const guard = aa.switches[index].guard;
                if (try ask_first(p, a, s, guard, index)) |f| return .{ .opened = f };
            }
            try flip(a, s, book, index);
            return .done;
        },
    }
    try sess.relayout(a, s);
    try draw_toolbar(a, s, book, .{ .sheet_open = true, .whole_page = true });
    return .done;
}

/// Turns switch `index` over, and applies it.
fn flip(
    a: *app.App,
    s: *sess.Session,
    book: Book,
    index: u32,
) !void {
    assert(index < aa.switches.len);
    const switch_hit = aa.switches[index];
    const turning_on = !aa.is_on(index, a.settings);
    aa.flip(index, &a.settings);
    assert(aa.is_on(index, a.settings) == turning_on);
    switch (switch_hit.effect) {
        .relayout => {
            try sess.relayout(a, s);
            try draw_toolbar(a, s, book, .{ .sheet_open = true, .whole_page = true });
        },
        .footer, .nothing => {
            a.save_settings();
            // The footer is drawn into each page
            if (switch_hit.effect == .footer) a.display.forget_pages();
            try draw_toolbar(a, s, book, .{ .sheet_open = true, .whole_page = false });
        },
    }
}

/// Before a switch with this guard turns on: a card asking, or saying what's
/// missing, to open over the book; null when it may turn on at once.
fn ask_first(
    p: *Pending,
    a: *app.App,
    s: *sess.Session,
    guard: aa.Guard,
    index: u32,
) !?screen.Frame {
    assert(s.current < s.pages.len);
    assert(index < aa.switches.len);
    assert(p.* == .none);
    const ask: *Pending.Ask = switch (guard) {
        .none => return null,
        .autostart => ask: {
            // Turning it on needs the startup file in the system folder: ask first
            if (autostart.installed()) return null;
            const background = try s.lend_current();
            p.* = .{ .autostart = .{ .toggle = index, .background = background } };
            const title = "Open noface when the Kindle starts";
            const subtitle = "This adds one small startup file to the Kindle's system.";
            const rows = &turn_on_rows;
            p.autostart.card = card_screen.over(a, background, title, subtitle, rows, null);
            break :ask &p.autostart;
        },
        .lock_picture => ask: {
            // Turning it on needs a picture to show
            if (lock.has_picture(a)) return null;
            const background = try s.lend_current();
            p.* = .{ .lock_picture = .{ .toggle = index, .background = background } };
            const title = "Add your picture first";
            const subtitle = "Name it lockscreen.jpg or lockscreen.png, and put it in the " ++
                "noface-data folder.";
            p.lock_picture.card = card_screen.over(a, background, title, subtitle, &ok_rows, null);
            break :ask &p.lock_picture;
        },
    };
    return screen.open(&ask.card, &ask.ending);
}

const turn_on_rows = [_]card.Row{.{ .label = "Turn on" }};
const ok_rows = [_]card.Row{.{ .label = "OK" }};

/// What the scrubber, a slider or a card opened over the book does once it has ended.
pub fn resumed(
    p: *Pending,
    a: *app.App,
    s: *sess.Session,
    book: Book,
    sheet_open: bool,
) !void {
    const sheet_only: Drawn = .{ .sheet_open = true, .whole_page = false };
    // It has ended, whatever happens below
    defer p.* = .none;
    switch (p.*) {
        .none => unreachable, // Only called for something the controls opened
        .scrub => |*scrub| {
            // A drag cut short (the Kindle locking, noface leaving) was never let go
            // of: the page stays, and so does the place saved on the way out
            const lifted = try drag.ended(&scrub.drag, scrub.ending.?);
            if (lifted) s.set_page(scrub.target, .jump);
            assert(scrub.target < s.pages.len); // The pages it was dragged over, unchanged
            try draw_toolbar(a, s, book, .{ .sheet_open = sheet_open, .whole_page = true });
            // What locks or leaves covers the toolbar at once: a clean flash is for nothing
            if (lifted) {
                const scrub_height = a.display.screen.height - toolbar.scrub_top;
                try a.display.clean_band(toolbar.scrub_top, scrub_height);
            }
        },
        .setting => |*setting| {
            const lifted = try drag.ended(&setting.drag, setting.ending.?);
            // Only a slider let go of changes the setting: one cut short is left as it was
            if (lifted and setting.value != setting.started) {
                row_value_set(a, setting.row, setting.value);
                try sess.relayout(a, s);
            }
            try draw_toolbar(a, s, book, .{ .sheet_open = true, .whole_page = true });
            if (lifted) try a.display.clean_band(setting.row.top, aa.row_height);
        },
        .autostart => |ask| {
            try card_screen.closed(a, ask.background);
            if (ask.ending.? != .done) return draw_toolbar(a, s, book, sheet_only);
            if (autostart.install()) return flip(a, s, book, ask.toggle);
            try draw_toolbar(a, s, book, sheet_only);
            try app.show_notice(a, "Couldn't set up starting with the Kindle.");
        },
        .lock_picture => |ask| {
            try card_screen.closed(a, ask.background);
            try draw_toolbar(a, s, book, sheet_only);
        },
    }
}
