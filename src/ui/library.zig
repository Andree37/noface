//! Book list, read from the tab-separated file the launcher exports from the
//! Kindle's own database: path, title, author, percent, last opened.
const std = @import("std");
const assert = std.debug.assert;
const Page = @import("../gfx/page.zig").Page;
const Font = @import("../gfx/font.zig").Font;
const draw = @import("draw.zig");
const style = @import("style.zig");
const cover = @import("../gfx/image.zig");
const icons = @import("icons.zig");
const quick_model = @import("../model/quick.zig");
const catalog = @import("../model/catalog.zig");
const stats = @import("../model/stats.zig");
const Fonts = @import("fonts.zig").Fonts;
const covers = @import("covers.zig");

const margin = style.margin;
const gutter = 40;
const columns = 4;
const cell_step = cover.width + gutter;
const row_height = 410;
const cell_title_below = 34; // From the bar under a cover to its title's baseline
pub const status_height = style.status_height;

// Page one always leads with the current book, on every tab and sort.
const hero_top = 112;
const hero_bottom = 500;
const hero_tabs_top = 516;
const hero_grid_top = 622;
const plain_tabs_top = 100;
const plain_grid_top = 206;
const tabs_height = 84;
const hero_rows = 2;
const plain_rows = 3;
/// The most books a page shows: a page without the hero, whole.
pub const page_books_max: u32 = plain_rows * columns;
const hero_title_lines = 3;
const hero_title_step = 66;
const hero_dots_left = 1100; // The hero's dots take taps right of here, near its top
const hero_dots_bottom = hero_top + 90; // From the status strip down to here
const message_baseline = 1500; // A notice, between the grid and the pager
const menu_right = 220; // The menu takes taps left of here, in the status strip
const battery_reach = 300; // And the battery this far from the right edge

/// A filter's tab: `left` and `right` bound its taps, and its label starts at `label_left`.
const Tab = struct {
    filter: catalog.Filter,
    label: []const u8,
    left: i32,
    label_left: i32,
    right: i32,
};
// Inside one rounded button that starts with a funnel, each at least a fingertip (about
// 100 px) wide. The first takes the funnel's taps too, as it's drawn as part of it.
const tabs = [_]Tab{
    .{ .filter = .all, .label = "All", .left = margin, .label_left = 172, .right = 260 },
    .{ .filter = .unread, .label = "Unread", .left = 260, .label_left = 276, .right = 432 },
    .{ .filter = .read, .label = "Read", .left = 432, .label_left = 448, .right = 564 },
};

// Filter, search and sort buttons fill the tabs row: a fingertip tall
const button_top = 0;
const button_height = tabs_height;
const icon_inset = 46; // From a button's rounded end to its icon's centre

const footer = draw.bottom_pager;
const sort_left = 860;

// A cover set in type, for a book with no picture: its title from the top down, a short
// rule under it, and the author along the bottom.
const type_title_top = 72; // From the cover's top to the title's first baseline
const type_title_step = 44;
const type_rule_height = 3;
const type_author_above = 34; // From the cover's bottom up to the author's baseline
/// How high the author's letters reach above their baseline, at most: the size of the
/// caption font it's set in (26 px, setup.zig), which none of its letters outgrows.
const type_author_reach = 26;
const type_rule_gap = 8; // At least this between the rule and the author's letters

/// The moment a frame is drawn for, read once so every part of it agrees.
pub const Moment = struct { unix: u64, utc_offset: i64 };

pub const Hit = union(enum) {
    none,
    hero,
    hero_dots,
    book: u32,
    prev,
    next,
    sort,
    menu,
    battery,
    search,
    stats,
    clear_search,
    tab: catalog.Filter,
};

// The round search button, a clear gap right of the filter button
const search_cx = 564 + 36 + button_height / 2;
const search_reach = 56; // Taps this far either side of its centre: a fingertip and more
// The round stats button, beside search, their taps just short of meeting
const stats_cx = search_cx + 2 * search_reach + 4;

comptime {
    // The grid's four columns between the margins
    assert(margin + columns * cell_step - gutter <= style.screen_width - margin);
    // A cover, its progress bar and its title fit in a row
    assert(cover.height + 8 + cell_title_below < row_height);
    // The strips, top to bottom, with page one's hero above its tabs
    assert(status_height <= plain_tabs_top);
    assert(status_height <= hero_top);
    assert(hero_top + cover.hero_height <= hero_bottom);
    assert(hero_bottom <= hero_tabs_top);
    assert(hero_tabs_top + tabs_height <= hero_grid_top);
    assert(plain_tabs_top + tabs_height <= plain_grid_top);
    // Both grids end above the notice, which is above the pager
    assert(hero_grid_top + hero_rows * row_height < message_baseline);
    assert(plain_grid_top + plain_rows * row_height < message_baseline);
    assert(message_baseline < footer.top);
    assert(footer.bottom <= style.screen_height);
    // The filter's tabs side by side, each a fingertip, then search, stats and sort apart
    for (tabs[0 .. tabs.len - 1], tabs[1..]) |left, right| assert(left.right == right.left);
    for (tabs) |t| assert(t.right - t.left >= 100);
    assert(2 * search_reach >= 100);
    assert(tabs[tabs.len - 1].right < search_cx - search_reach);
    assert(search_cx + search_reach < stats_cx - search_reach);
    assert(stats_cx + search_reach < sort_left);
    // The hero's dots are drawn where they take taps, a fingertip tall
    assert(style.screen_width - margin - 8 >= hero_dots_left);
    assert(hero_top + 24 < hero_dots_bottom);
    assert(hero_dots_bottom - status_height >= 100);
    assert(margin < menu_right);
    // The tabs row takes taps a fingertip tall and more, across the gaps around it
    assert(hero_grid_top - hero_bottom >= 100);
    assert(plain_grid_top - status_height >= 100);
    // The filter's taps cover its whole button, funnel and all, each label inside its tab
    assert(tabs[0].left == margin);
    assert(margin + icon_inset < tabs[0].label_left);
    for (tabs) |t| assert(t.left < t.label_left);
    for (tabs) |t| assert(t.label_left < t.right);
    // On a cover set in type, the title's last line, its rule and the author never
    // meet, on the grid's covers and the hero's
    for ([_]u32{ cover.height, cover.hero_height }) |h| {
        const lines = type_title_lines(h);
        assert(lines >= 3);
        const rule_bottom = type_title_top + lines * type_title_step + type_rule_height;
        assert(rule_bottom + type_rule_gap <= h - type_author_above - type_author_reach);
    }
}

/// The most lines a cover `h` tall set in type has room for its title in, above its
/// rule and the author.
fn type_title_lines(h: u32) u32 {
    const below = type_rule_height + type_rule_gap + type_author_reach + type_author_above;
    assert(h > type_title_top + below);
    const lines = (h - type_title_top - below) / type_title_step;
    assert(lines > 0);
    return lines;
}

fn grid_size(hero: bool) u32 {
    const result: u32 = (if (hero) @as(u32, hero_rows) else plain_rows) * columns;
    assert(result > 0);
    assert(result % columns == 0);
    return result;
}

/// Index of the first grid book on a page.
fn first_book(page: u32) u32 {
    if (page == 0) return 0;
    const result = grid_size(true) + (page - 1) * grid_size(false);
    assert(result >= grid_size(true));
    return result;
}

/// Range of grid books on a page, for logging what's shown.
pub fn page_range(page: u32, books: u32) struct { first: u32, end: u32 } {
    const first = @min(first_book(page), books);
    const end = @min(first + grid_size(page == 0), books);
    assert(first <= end);
    assert(end <= books);
    return .{ .first = first, .end = end };
}

pub fn page_count(books: u32) u32 {
    if (books <= grid_size(true)) return 1;
    const later = books - grid_size(true); // On the pages after the first
    const result = 1 + (later + grid_size(false) - 1) / grid_size(false);
    // The last page holds the last book, and the page after it would hold none
    assert(first_book(result - 1) < books);
    assert(first_book(result) >= books);
    return result;
}

/// Where the tabs row takes taps: from what's over it (the hero's place, or the status
/// strip) down to the grid, more than the pills drawn, so a tap just off one still counts.
fn tabs_band(hero: bool) struct { top: i32, bottom: i32 } {
    const top: i32 = if (hero) hero_bottom else status_height;
    const bottom = grid_top(hero);
    assert(top <= tabs_top(hero));
    assert(tabs_top(hero) + tabs_height <= bottom);
    return .{ .top = top, .bottom = bottom };
}

fn tabs_top(hero: bool) i32 {
    const result: i32 = if (hero) hero_tabs_top else plain_tabs_top;
    assert(result + tabs_height <= grid_top(hero));
    return result;
}

fn grid_top(hero: bool) i32 {
    const result: i32 = if (hero) hero_grid_top else plain_grid_top;
    assert(result > status_height);
    return result;
}

/// What a tap on this library page lands on. While `searching`, the hero's place
/// holds the search, and tapping it clears the search.
pub fn hit(x: i32, y: i32, page: u32, books: u32, searching: bool) Hit {
    const hero = page == 0;
    if (y < status_height) {
        if (x < menu_right) return .menu;
        // The battery and its percent, with room for a fingertip
        if (x >= style.screen_width - battery_reach) return .battery;
        return .none;
    }
    // The hero's place takes taps from the status strip down
    if (hero and y < hero_bottom) {
        if (searching) return .clear_search;
        if (x >= hero_dots_left and y < hero_dots_bottom) return .hero_dots;
        return .hero;
    }

    const band = tabs_band(hero);
    if (y >= band.top and y < band.bottom) return hit_tabs(x);
    if (footer.hit(x, y)) |h| return switch (h) {
        .prev => .prev,
        .next => .next,
    };
    if (y >= footer.top and y < footer.bottom) return .none;
    const top = grid_top(hero);
    if (y < top or x < margin) return .none;
    const column: u32 = @intCast(@divTrunc(x - margin, cell_step));
    const row: u32 = @intCast(@divTrunc(y - top, row_height));
    if (column >= columns or row >= grid_size(hero) / columns) return .none;
    const first = first_book(page);
    const index = first + row * columns + column;
    if (index >= books) return .none;
    assert(index - first < grid_size(hero));
    // A book's actions come from pressing and holding it, so the whole cell is the book
    return .{ .book = index };
}

/// Which button in the tabs row a tap at `x` lands on.
fn hit_tabs(x: i32) Hit {
    if (x >= sort_left) return .sort;
    if (@abs(x - search_cx) <= search_reach) return .search;
    if (@abs(x - stats_cx) <= search_reach) return .stats;
    for (tabs) |t| {
        if (x >= t.left and x < t.right) return .{ .tab = t.filter };
    }
    return .none;
}

pub const Rect = style.Rect;

/// Screen area of the hero, for tap feedback.
pub fn hero_rect(width: u32) Rect {
    return .{ .x = margin, .y = hero_top, .w = width - 2 * margin, .h = cover.hero_height };
}

/// Where the `slot`th cover on a page of the grid sits (counting along rows).
fn cell_origin(slot: u32, with_hero: bool) struct { x: u32, y: u32 } {
    assert(slot < grid_size(with_hero));
    const top: u32 = @intCast(grid_top(with_hero));
    const x = margin + slot % columns * cell_step;
    const y = top + slot / columns * row_height;
    assert(x + cover.width <= style.screen_width - margin);
    assert(y + row_height < message_baseline);
    return .{ .x = x, .y = y };
}

/// Screen area of a grid book, for tap feedback.
pub fn book_rect(index: u32, page: u32) Rect {
    const first = first_book(page);
    assert(index >= first);
    const at = cell_origin(index - first, page == 0);
    return .{ .x = at.x, .y = at.y, .w = cover.width, .h = cover.height };
}

/// A thin gray track with a thick rounded black fill. Any progress at all shows as
/// at least a dot.
fn progress_bar(page: Page, x: u32, y: u32, w: u32, percent: u32, thick: f32) void {
    assert(thick > 0);
    assert(@as(f32, @floatFromInt(w)) > thick);
    const left: f32 = @floatFromInt(x);
    const cy: f32 = @floatFromInt(y);
    const r = thick / 2;
    page.pill(left + r, left + @as(f32, @floatFromInt(w)) - r, cy, r / 2, 0xb8);
    if (percent == 0) return;
    const filled = @as(f32, @floatFromInt(w)) * @as(f32, @floatFromInt(@min(percent, 100))) / 100;
    page.pill(left + r, left + @max(filled - r, r), cy, r, 0x00);
}

/// "32%" in a small white pill over a cover's bottom left corner.
fn percent_badge(font: *Font, page: Page, x: u32, y: u32, percent: u32) !void {
    assert(x >= margin);
    assert(y >= plain_grid_top + cover.height);
    var label: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&label, "{d}%", .{@min(percent, 100)}) catch return;
    const r: f32 = 19;
    const left: f32 = @floatFromInt(x + 12);
    const cy: f32 = @as(f32, @floatFromInt(y)) - 12 - r;
    const w = try font.measure(s) + 26;
    const ends = [2]f32{ left + r, left + @max(w - r, r) };
    page.pill(ends[0], ends[1], cy, r, 0x00);
    page.pill(ends[0], ends[1], cy, r - 2, 0xff);
    try font.draw(page, left + 13, @intFromFloat(cy + 9), s);
}

/// "#2" in a small white pill over a cover's top left corner, for a book in a series.
fn series_badge(font: *Font, page: Page, x: u32, y: u32, index: f32) !void {
    assert(x >= margin);
    assert(y >= plain_grid_top);
    var label: [12]u8 = undefined;
    var s: []const u8 = undefined;
    if (@floor(index) == index) {
        const whole: u32 = @intFromFloat(@min(@max(index, 0), catalog.max_index));
        s = std.fmt.bufPrint(&label, "#{d}", .{whole}) catch return;
    } else {
        s = std.fmt.bufPrint(&label, "#{d:.1}", .{index}) catch return;
    }
    const r: f32 = 19;
    const left: f32 = @floatFromInt(x + 12);
    const cy: f32 = @as(f32, @floatFromInt(y)) + 12 + r;
    const w = try font.measure(s) + 26;
    const ends = [2]f32{ left + r, left + @max(w - r, r) };
    page.pill(ends[0], ends[1], cy, r, 0x00);
    page.pill(ends[0], ends[1], cy, r - 2, 0xff);
    try font.draw(page, left + 13, @intFromFloat(cy + 9), s);
}

/// A rounded outline around a control, so it reads as something to press.
fn button_outline(page: Page, left: f32, right: f32, top: i32) void {
    assert(right > left);
    assert(left >= margin);
    const r: f32 = button_height / 2;
    const cy: f32 = @floatFromInt(top + button_top + button_height / 2);
    page.pill(left + r, right - r, cy, r, 0x00);
    page.pill(left + r, right - r, cy, r - 2, 0xff);
}

/// A book with no thumbnail still gets a real cover: its title set in type.
fn type_cover(
    fonts: Fonts,
    page: Page,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    e: *const catalog.Entry,
) !void {
    // Room inside for the title, its rule and the author
    assert(w > 56);
    assert(h > 72 + 34);
    page.fill_rect(x, y, w, h, 0xf0);
    page.fill_rect(x, y, w, 2, 0x00);
    page.fill_rect(x, y + h - 2, w, 2, 0x00);
    page.fill_rect(x, y, 2, h, 0x00);
    page.fill_rect(x + w - 2, y, 2, h, 0x00);
    const left: f32 = @floatFromInt(x + 28);
    const avail: f32 = @floatFromInt(w - 56);
    const top: i32 = @intCast(y + type_title_top);
    const step = type_title_step;
    const lines = type_title_lines(h);
    const used = try draw.wrapped(fonts.cover, page, left, top, step, e.title, avail, lines);
    assert(used <= lines);
    const rule_y = y + type_title_top + used * type_title_step;
    page.fill_rect(x + 28, rule_y, 48, type_rule_height, 0x00);
    const author_y: i32 = @intCast(y + h - type_author_above);
    try draw.clipped(fonts.caption, page, left, author_y, e.author, avail);
}

fn draw_cover(
    pool: *covers.Pool,
    fonts: Fonts,
    page: Page,
    e: *catalog.Entry,
    x: u32,
    y: u32,
) !void {
    assert(x >= margin);
    if (pool.grid_cover(e.thumbnail)) |c| {
        assert(c.len == cover.width * cover.height);
        page.copy_image(x, y, c, cover.width, cover.height);
    } else {
        try type_cover(fonts, page, x, y, cover.width, cover.height, e);
    }
}

/// The book to continue: its cover, then beside it its title, author, when it was last
/// read and how far.
fn draw_hero(
    pool: *covers.Pool,
    fonts: Fonts,
    page: Page,
    e: *catalog.Entry,
    now: Moment,
) !void {
    if (pool.hero_cover(e.thumbnail)) |c| {
        assert(c.len == cover.hero_width * cover.hero_height);
        page.copy_image(margin, hero_top, c, cover.hero_width, cover.hero_height);
    } else {
        const h = cover.hero_height;
        try type_cover(fonts, page, margin, hero_top, cover.hero_width, h, e);
    }

    const left_px: u32 = margin + cover.hero_width + 48;
    const left: f32 = @floatFromInt(left_px);
    const avail: f32 = @floatFromInt(page.width - left_px - margin);
    try fonts.caption.draw(page, left, hero_top + 34, "Continue reading");
    icons.dots(page, @floatFromInt(page.width - margin - 8), hero_top + 24);
    page.tint(left_px, hero_top + 8, @intFromFloat(avail - 40), 36, style.quiet);

    const title_y = hero_top + 104;
    const step = hero_title_step;
    const lines = hero_title_lines;
    const used = try draw.wrapped(fonts.hero, page, left, title_y, step, e.title, avail, lines);
    assert(used <= hero_title_lines);
    const author_y: i32 = title_y + @as(i32, @intCast(used)) * hero_title_step - 12;
    const has_byline = try draw_hero_byline(fonts, page, e, left_px, author_y, avail);
    const bar_y = hero_top + cover.hero_height - 40;
    // The author, even under the longest title, is clear of the bar
    assert(author_y < bar_y);
    // Under the author (or the title, when there's no author): when it was last read,
    // and how long in noface, so the card says more than the cover does. Only for a
    // book really opened, as stock also dates downloads, and only clear of the bar.
    const line_y = if (has_byline) author_y + 56 else author_y;
    if (e.was_opened() and line_y < bar_y - 22) {
        var when_buf: [24]u8 = undefined;
        if (stats.ago(&when_buf, e.last, now.unix, now.utc_offset)) |when| {
            try draw_hero_last_read(fonts, page, e, when, left_px, line_y, avail);
        }
    }

    progress_bar(page, left_px, bar_y, @intFromFloat(avail), e.percent, 12);
    var label: [24]u8 = undefined;
    const pct = std.fmt.bufPrint(&label, "{d}% read", .{e.percent}) catch "";
    try fonts.caption.draw(page, left, bar_y + 42, pct);
    page.tint(left_px, bar_y + 16, @intFromFloat(avail), 34, style.faded);
}

/// The author, and the series when there is one: "Liu, Cixin  ·  Three-Body #2".
/// False when there's neither, and the line is empty.
fn draw_hero_byline(
    fonts: Fonts,
    page: Page,
    e: *const catalog.Entry,
    left_px: u32,
    author_y: i32,
    avail: f32,
) !bool {
    assert(left_px > margin + cover.hero_width);
    assert(author_y > hero_top);
    var byline_buf: [256]u8 = undefined;
    var series_buf: [160]u8 = undefined;
    var byline: []const u8 = e.author;
    if (catalog.series_label(&series_buf, e.*)) |series| {
        if (e.author.len == 0) {
            byline = series;
        } else {
            const both = .{ e.author, series };
            byline = std.fmt.bufPrint(&byline_buf, "{s}  \u{b7}  {s}", both) catch e.author;
        }
    }
    const left: f32 = @floatFromInt(left_px);
    try draw.clipped(fonts.small, page, left, author_y, byline, avail);
    page.tint(left_px, @intCast(author_y - 30), @intFromFloat(avail), 44, style.faded);
    return byline.len > 0;
}

/// "Last read 3 days ago", and how long it was read here when known, in gray.
fn draw_hero_last_read(
    fonts: Fonts,
    page: Page,
    e: *const catalog.Entry,
    when: []const u8,
    left_px: u32,
    line_y: i32,
    avail: f32,
) !void {
    assert(when.len > 0);
    assert(line_y > hero_top);
    var time_buf: [32]u8 = undefined;
    var line_buf: [96]u8 = undefined;
    var line: []const u8 = "";
    if (stats.reading_time(&time_buf, e.seconds_read)) |time| {
        const format = "Last read {s}  \u{b7}  read here for {s}";
        line = std.fmt.bufPrint(&line_buf, format, .{ when, time }) catch "";
    } else {
        line = std.fmt.bufPrint(&line_buf, "Last read {s}", .{when}) catch "";
    }
    const left: f32 = @floatFromInt(left_px);
    try draw.clipped(fonts.caption, page, left, line_y, line, avail);
    // Gray, like the author
    page.tint(left_px, @intCast(line_y - 26), @intFromFloat(avail), 34, style.faded);
}

fn draw_cell(
    pool: *covers.Pool,
    fonts: Fonts,
    page: Page,
    e: *catalog.Entry,
    x: u32,
    y: u32,
) !void {
    assert(x >= margin);
    assert(y >= plain_grid_top);
    try draw_cover(pool, fonts, page, e, x, y);
    const bar_y = y + cover.height + 8;
    const title_y: i32 = @intCast(bar_y + cell_title_below);
    const title_width: f32 = cover.width;
    const left: f32 = @floatFromInt(x);
    if (!e.is_local()) {
        page.tint(x, y, cover.width, cover.height, style.finished_cover);
        const cloud_x: f32 = @floatFromInt(x + cover.width - 38);
        icons.cloud(page, cloud_x, @floatFromInt(y + cover.height - 38));
        const label = if (e.availability == .downloading) "Downloading" else e.title;
        _ = try draw.wrapped(fonts.caption, page, left, title_y, 30, label, title_width, 1);
        return;
    }
    if (e.in_progress()) {
        progress_bar(page, x, bar_y + 2, cover.width, e.percent, 10);
        try percent_badge(fonts.caption, page, x, y + cover.height, e.percent);
    }
    if (e.is_read()) {
        icons.check(page, @floatFromInt(x + cover.width - 32), @floatFromInt(y + 32));
    }
    if (e.series) |s| try series_badge(fonts.caption, page, x, y, s.index);
    _ = try draw.wrapped(fonts.caption, page, left, title_y, 30, e.title, title_width, 1);
}

fn draw_status(fonts: Fonts, page: Page, quick: *const quick_model.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    // One centre line for everything in the strip.
    const centre = 48;
    const baseline = centre + 9;
    comptime assert(baseline < status_height);
    comptime assert(centre - 14 > 0);
    icons.menu(page, margin, centre - 14);
    const clock = quick.clock_text();
    const time = clock[0 .. std.mem.indexOfScalar(u8, clock, ' ') orelse clock.len];
    try draw.centered(fonts.caption, page, w / 2, baseline, time);
    try icons.status_cluster(page, fonts.caption, w - margin, centre, baseline, quick, false);
}

/// In the hero's place while searching: what was searched for, how many books have
/// it, and a button to clear it.
fn draw_search_header(fonts: Fonts, page: Page, query: []const u8, found: u32) !void {
    assert(query.len > 0);
    const left: f32 = margin;
    const avail: f32 = @floatFromInt(page.width - 2 * margin);
    try fonts.caption.draw(page, left, hero_top + 34, "Search results");
    page.tint(margin, hero_top + 8, @intFromFloat(avail), 36, style.quiet);
    var quoted: [80]u8 = undefined;
    const shown = std.fmt.bufPrint(&quoted, "\u{201c}{s}\u{201d}", .{query}) catch query;
    try draw.clipped(fonts.hero, page, left, hero_top + 120, shown, avail);
    var count: [32]u8 = undefined;
    const plural = if (found == 1) "" else "s";
    const books = std.fmt.bufPrint(&count, "{d} book{s}", .{ found, plural }) catch "";
    try fonts.small.draw(page, left, hero_top + 190, books);
    const label = "Clear search";
    const w = try fonts.small.measure(label);
    const top: i32 = hero_top + 236 - button_top;
    // The button stays inside the hero's place, where its taps go
    comptime assert(hero_top + 236 + button_height <= hero_bottom);
    button_outline(page, left, left + w + 60, top);
    try fonts.small.draw(page, left + 30, top + 55, label);
}

fn draw_tabs(
    fonts: Fonts,
    page: Page,
    top: i32,
    filter: catalog.Filter,
    order: catalog.Order,
    searching: bool,
) !void {
    assert(top == hero_tabs_top or top == plain_tabs_top);
    const y = top + 54;
    const cy: f32 = @floatFromInt(top + button_top + button_height / 2);
    const r: f32 = button_height / 2;
    if (searching) {
        // Filled while a search is showing, like a toggle that's on
        page.pill(search_cx, search_cx, cy, r, 0x00);
        const magnifier = icons.Magnifier{ .scale = 0.8 };
        const size = button_height;
        try icons.draw_white(page, size, size, search_cx, @intFromFloat(cy), magnifier);
    } else {
        button_outline(page, search_cx - r, search_cx + r, top);
        icons.search_scaled(page, search_cx, cy, 0.8);
    }
    button_outline(page, stats_cx - r, stats_cx + r, top);
    icons.bar_chart(page, stats_cx, cy);
    button_outline(page, margin, @floatFromInt(tabs[tabs.len - 1].right), top);
    icons.funnel(page, margin + icon_inset, cy);
    for (tabs) |t| {
        const left: u32 = @intCast(t.label_left);
        const active = t.filter == filter;
        const x: f32 = @floatFromInt(left);
        try draw.choice(fonts, page, x, .left, y, t.label, active, @intCast(top + 62));
        const width: u32 = @intCast(t.right - t.label_left - 4);
        if (!active) page.tint(left, @intCast(top + 22), width, 44, style.faded);
    }
    try draw_tabs_sort(fonts, page, top, order);
}

/// The sort button at the right of the tabs row, saying the order in use.
fn draw_tabs_sort(fonts: Fonts, page: Page, top: i32, order: catalog.Order) !void {
    assert(top == hero_tabs_top or top == plain_tabs_top);
    assert(order.label().len > 0);
    const y = top + 54;
    const cy: f32 = @floatFromInt(top + button_top + button_height / 2);
    const right: f32 = @floatFromInt(page.width - margin);
    // One width for every order, sized to the longest label, so the button stays put
    // as it cycles; the label sits centred in the room right of the arrows.
    var widest: f32 = 0;
    for (std.enums.values(catalog.Order)) |o| {
        widest = @max(widest, try fonts.small.measure(o.label()));
    }
    const button_left = right - 32 - widest - 18 - icon_inset - 14;
    button_outline(page, button_left, right, top);
    icons.sort_arrows(page, button_left + icon_inset, cy);
    const label_left = button_left + icon_inset + 18 + 14;
    const label_w = try fonts.small.measure(order.label());
    const label_x = label_left + (right - 32 - label_left - label_w) / 2;
    try fonts.small.draw(page, label_x, y, order.label());
}

/// The books to draw: those on page `index` (`shown`) of the `count` let through, and
/// the book to continue, which page one leads with.
pub const Books = struct {
    shown: []catalog.Entry,
    hero: ?*catalog.Entry,
    count: u32,
};

pub fn render(
    pool: *covers.Pool,
    fonts: Fonts,
    page: Page,
    books: Books,
    index: u32,
    filter: catalog.Filter,
    order: catalog.Order,
    query: []const u8,
    message: []const u8,
    quick: *const quick_model.Quick,
    now: Moment,
) !void {
    const with_hero = index == 0;
    assert(books.shown.len <= grid_size(with_hero));
    assert(books.shown.len <= books.count);
    @memset(page.buf, 0xff);
    try draw_status(fonts, page, quick);

    var hero_drawn = false;
    if (with_hero) {
        if (query.len > 0) {
            try draw_search_header(fonts, page, query, books.count);
        } else if (books.hero) |h| {
            try draw_hero(pool, fonts, page, h, now);
            hero_drawn = true;
        }
    }
    try draw_tabs(fonts, page, tabs_top(with_hero), filter, order, query.len > 0);

    const top: u32 = @intCast(grid_top(with_hero));
    for (books.shown, 0..) |*e, i| {
        const at = cell_origin(@intCast(i), with_hero);
        try draw_cell(pool, fonts, page, e, at.x, at.y);
    }
    // Nothing at all shown: the hero, when there is one, is a book here too
    if (books.count == 0 and !hero_drawn) {
        const empty = if (query.len > 0) "No books match." else "No books here yet.";
        try fonts.small.draw(page, margin, @intCast(top + 60), empty);
    }
    try footer.render(fonts, page, index, page_count(books.count));
    if (message.len > 0) try fonts.caption.draw(page, margin, message_baseline, message);
}

test "the current book stays on page one of every view" {
    try std.testing.expectEqual(Hit.hero, hit(300, 200, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(100, 700, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 3 }, hit(1000, 700, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 4 }, hit(100, 1100, 0, 79, false));
}

test "later pages are four by three" {
    try std.testing.expectEqual(Hit{ .book = 8 }, hit(100, 300, 1, 79, false));
    try std.testing.expectEqual(Hit{ .book = 19 }, hit(1000, 1100, 1, 79, false));
}

test "header and footer controls" {
    try std.testing.expectEqual(Hit.menu, hit(100, 50, 0, 79, false));
    try std.testing.expectEqual(Hit{ .tab = .all }, hit(200, 560, 0, 79, false));
    try std.testing.expectEqual(Hit{ .tab = .unread }, hit(340, 560, 0, 79, false));
    try std.testing.expectEqual(Hit{ .tab = .read }, hit(500, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.none, hit(840, 560, 0, 79, false)); // Between stats and sort
    try std.testing.expectEqual(Hit.sort, hit(1100, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.prev, hit(400, 1600, 0, 79, false));
    try std.testing.expectEqual(Hit.next, hit(800, 1600, 0, 79, false));
}

test "tapping past the last book does nothing" {
    try std.testing.expectEqual(Hit.none, hit(1000, 1100, 0, 3, false));
}

test "page count follows the layout" {
    try std.testing.expectEqual(@as(u32, 1), page_count(0));
    try std.testing.expectEqual(@as(u32, 1), page_count(8));
    try std.testing.expectEqual(@as(u32, 2), page_count(9));
    try std.testing.expectEqual(@as(u32, 7), page_count(78));
}

test "search button sits beside the filter, and the search takes the hero's place" {
    try std.testing.expectEqual(Hit.search, hit(search_cx, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.none, hit(570, 560, 0, 79, false)); // The gap between them
    try std.testing.expectEqual(Hit.stats, hit(stats_cx, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.search, hit(search_cx + search_reach, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.stats, hit(search_cx + search_reach + 4, 560, 0, 79, false));
    try std.testing.expectEqual(Hit.search, hit(search_cx, 140, 1, 79, false));
    for (tabs) |t| try std.testing.expect(t.right - t.left >= 100);
    try std.testing.expect(2 * search_reach >= 100);
    try std.testing.expectEqual(Hit.clear_search, hit(300, 300, 0, 79, true));
    try std.testing.expectEqual(Hit.hero, hit(300, 300, 0, 79, false));
}

test "a book's title is part of the book, and the hero keeps its dots" {
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(300, 975, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(120, 975, 0, 79, false));
    try std.testing.expectEqual(Hit.hero_dots, hit(1180, 130, 0, 79, false));
    // A fingertip tall: from just under the status strip to well under the dots
    try std.testing.expectEqual(Hit.hero_dots, hit(1180, status_height, 0, 79, false));
    try std.testing.expectEqual(Hit.hero_dots, hit(1180, hero_dots_bottom - 1, 0, 79, false));
    try std.testing.expectEqual(Hit.hero, hit(1180, hero_dots_bottom, 0, 79, false));
}

test "the tabs row takes taps just off its pills, and the filter's from its funnel" {
    // Page one: 10 px above and below the pills drawn
    const all: Hit = .{ .tab = .all };
    try std.testing.expectEqual(all, hit(200, hero_tabs_top - 10, 0, 79, false));
    try std.testing.expectEqual(all, hit(200, hero_tabs_top + tabs_height + 10, 0, 79, false));
    try std.testing.expectEqual(Hit.sort, hit(1100, hero_grid_top - 1, 0, 79, false));
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(100, hero_grid_top, 0, 79, false));
    // Later pages: from the status strip, just above the pills, to 10 px below them
    try std.testing.expectEqual(all, hit(200, status_height, 1, 79, false));
    try std.testing.expectEqual(all, hit(200, plain_tabs_top + tabs_height + 10, 1, 79, false));
    try std.testing.expectEqual(Hit.menu, hit(200, status_height - 1, 1, 79, false));
    // The funnel, at the button's rounded end, is part of the first tab
    try std.testing.expectEqual(all, hit(margin + icon_inset, 558, 0, 79, false));
    try std.testing.expectEqual(all, hit(margin, 558, 0, 79, false));
    try std.testing.expectEqual(Hit.none, hit(margin - 1, 558, 0, 79, false));
}

test "a cover set in type has room for its title's lines above the author" {
    try std.testing.expectEqual(@as(u32, 4), type_title_lines(cover.height));
    try std.testing.expectEqual(@as(u32, 4), type_title_lines(cover.hero_height));
}
