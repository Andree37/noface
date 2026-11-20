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
const whole_percent = 100; // A book read through
const screen_width = style.screen_width;
const gutter = style.space.tiny + style.space.roomy;
const cell_step = cover.width + gutter;
/// As many covers as fit across between the margins.
const columns = (screen_width - 2 * margin + gutter) / cell_step;
/// A cover, its bar and its title under it, and a gap before the next row.
const row_height = cover.height + style.space.wide + cell_title_below;
const cell_title_below = style.space.roomy; // From the bar under a cover to its title's baseline
/// A grid cell's parts: the bar's gap under its cover and its drop and thickness, the
/// title's line step, and the corner icons' middles in from the cover's corners.
const cell = struct {
    const bar_gap = style.space.tiny;
    const bar_drop = 2;
    const bar_thick = style.space.tiny;
    const title_step = style.space.roomy;
    const cloud_inset = style.space.small + style.space.medium;
    const tick_inset = style.space.roomy;
};
pub const status_height = style.status_height;

// Page one always leads with the current book, on every tab and sort: under the status
// strip, the hero's place, then the tabs row, then the grid; later pages start with the
// tabs row. The grid takes as many rows as fit above the notice over the pager.
const hero_gap = style.space.snug; // Above the hero, and between its place and the tabs row
const hero_pad_below = style.space.roomy; // Under the hero's cover, inside its place
const hero_top = status_height + hero_gap;
const hero_bottom = hero_top + cover.hero_height + hero_pad_below;
const hero_tabs_top = hero_bottom + hero_gap;
const plain_tabs_gap = style.space.hair; // Above the tabs row on later pages
const plain_tabs_top = status_height + plain_tabs_gap;
const tabs_height = style.space.snug + style.space.wider;
const grid_gap = style.space.medium; // Between the tabs row and the grid
const hero_grid_top = hero_tabs_top + tabs_height + grid_gap;
const plain_grid_top = plain_tabs_top + tabs_height + grid_gap;
const hero_rows = (message_baseline - hero_grid_top) / row_height;
const plain_rows = (message_baseline - plain_grid_top) / row_height;
/// The most books a page shows: a page without the hero, whole.
pub const page_books_max: u32 = plain_rows * columns;
const hero_title_lines = 3;
const hero_title_step = style.space.wider;
/// The column of text beside the hero's cover, down from the hero's top unless said:
/// its gap from the cover, the "Continue reading" line (its fade stopping short of the
/// dots), the dots, the title, the author's rise above the title's next line, the line
/// under the author, and the progress bar's rise from the cover's foot, its clearance
/// and the percent under it. The quiet lines are faded over their own line.
const hero_text = struct {
    const gap = style.space.wide;
    const kicker_drop = style.space.roomy;
    const kicker_clear = style.space.tiny + style.space.roomy;
    const dots_inset = style.space.tiny;
    const dots_drop = style.space.medium;
    const title_drop = style.space.band;
    const author_rise = style.space.small;
    const line_step = style.space.wide;
    const bar_rise = style.space.tiny + style.space.roomy;
    const bar_clear = style.space.medium;
    const bar_thick = style.space.small;
    const percent_drop = style.space.snug + style.space.medium;
};
/// The hero's dots take a fingertip's taps in from the right margin, near its top: down
/// to this far under the hero's top.
const hero_dots_left = screen_width - margin - style.fingertip;
const hero_dots_reach_below = style.space.band;
const hero_dots_bottom = hero_top + hero_dots_reach_below;
/// A notice's baseline, between the grid and the pager.
const message_above_pager = style.space.roomy;
const empty_drop = style.space.wider; // "No books here yet.", under the grid's top
const message_baseline = footer.top - message_above_pager;
/// The menu takes taps left of here, in the status strip.
const menu_right = style.space.band + style.space.tall;
const status_menu_rise = style.space.small; // The menu's lines' top over it
const battery_reach = style.button_width; // And the battery this far from the right edge

/// A filter's tab: `left` and `right` bound its taps, and its label starts at `label_left`.
const Tab = struct {
    filter: catalog.Filter,
    label: []const u8,
    left: i32,
    label_left: i32,
    right: i32,
};
/// The funnel's part of the first tab, before its label, and a label's room in from its
/// tab's left otherwise.
const funnel_width = style.space.band;
const tab_label_pad = style.space.snug;
/// Each tab's own room past the funnel: its label's, and a fingertip's at least.
const tab_width = style.space.band + style.space.wide;
// Inside one rounded button that starts with a funnel, side by side from the margin,
// each at least a fingertip wide, as wide as its label needs. The first takes the
// funnel's taps too, as it's drawn as part of it.
const tabs = tabs: {
    const Each = struct { filter: catalog.Filter, label: []const u8, width: i32 };
    const each = [_]Each{
        .{ .filter = .all, .label = "All", .width = funnel_width + tab_width },
        .{ .filter = .unread, .label = "Unread", .width = tab_width },
        .{ .filter = .read, .label = "Read", .width = tab_width },
    };
    var placed: [each.len]Tab = undefined;
    var left: i32 = margin;
    for (each, 0..) |t, i| {
        const label_in: i32 = if (i == 0) funnel_width else tab_label_pad;
        placed[i] = .{
            .filter = t.filter,
            .label = t.label,
            .left = left,
            .label_left = left + label_in,
            .right = left + t.width,
        };
        left += t.width;
    }
    break :tabs placed;
};

// Filter, search and sort buttons fill the tabs row: a fingertip tall
const button_top = 0;
const button_height = tabs_height;
const icon_inset = style.space.wide; // From a button's rounded end to its icon's centre
/// The tabs row's labels, centred in its buttons: the line under the chosen one, down
/// from the row's top; the others faded.
const tab_underline = style.space.wider;
/// The sort button's room: right of its label, its arrows' width and their gaps.
const sort_label_pad = style.space.roomy;
const sort_arrows_width = style.space.snug;
const sort_arrows_gap = style.space.small;
/// While searching, in the hero's place, down from its top: the query, the count, and
/// the button that clears it, its label's room either side.
const search_head = struct {
    const query_drop = style.space.tall;
    const count_drop = style.space.wide + style.space.tall;
    const button_drop = style.space.band + style.space.tall;
    const button_pad = style.space.roomy;
};

const footer = draw.bottom_pager;

// A cover set in type, for a book with no picture: its title from the top down, a short
// rule under it, and the author along the bottom.
const type_title_top = style.space.wider; // From the cover's top to the title's first baseline
const type_title_step = style.line_step(style.text.sample); // The cover type's lines
const type_rule_height = style.space.hair;
const type_rule_width = style.space.wide;
const type_inset = style.space.medium; // The title and author in from the cover's sides
const type_edge = 2; // Its outline
const type_paper = 0xf0; // A shade off white, so the cover reads as one
const type_author_above = style.space.roomy; // From the cover's bottom up to the author's baseline
/// How high the author's letters reach above their baseline, at most: the size of the
/// caption font it's set in (26 px, setup.zig), which none of its letters outgrows.
const type_author_reach = style.space.medium;
const type_rule_gap = style.space.tiny; // At least this between the rule and the author's letters

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
const search_gap = style.space.roomy;
const search_cx = tabs[tabs.len - 1].right + search_gap + button_height / 2;
/// Taps this far either side of its centre: a fingertip across.
const search_reach = style.space.wide;
// The round stats button, beside search, their taps just short of meeting
const stats_cx = search_cx + 2 * search_reach + style.space.hair;
/// The sort button takes taps from a gap right of the stats button's.
const sort_gap = style.space.wide;
const sort_left = stats_cx + search_reach + sort_gap;

comptime {
    // The grid's four columns between the margins
    assert(margin + columns * cell_step - gutter <= style.screen_width - margin);
    // A cover, its progress bar and its title fit in a row
    assert(cover.height + cell.bar_gap + cell_title_below < row_height);
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
    for (tabs) |t| assert(t.right - t.left >= style.fingertip);
    assert(2 * search_reach >= style.fingertip);
    assert(tabs[tabs.len - 1].right < search_cx - search_reach);
    assert(search_cx + search_reach < stats_cx - search_reach);
    assert(stats_cx + search_reach < sort_left);
    // The hero's dots are drawn where they take taps, a fingertip tall
    assert(style.screen_width - margin - hero_text.dots_inset >= hero_dots_left);
    assert(hero_top + hero_text.dots_drop < hero_dots_bottom);
    assert(hero_dots_bottom - status_height >= style.fingertip);
    assert(margin < menu_right);
    // The tabs row takes taps a fingertip tall and more, across the gaps around it
    assert(hero_grid_top - hero_bottom >= style.fingertip);
    assert(plain_grid_top - status_height >= style.fingertip);
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

/// The middle of a control's taps on the library's first page, the hero's: a book's,
/// of the grid's `book`th; the clear-search's, the hero's place while searching.
pub fn place(h: Hit) style.Point {
    const status_middle = status_height / 2;
    const band = tabs_band(true);
    const tabs_middle = @divTrunc(band.top + band.bottom, 2);
    const hero_middle = (status_height + hero_bottom) / 2;
    const point: style.Point = switch (h) {
        .menu => .{ .x = menu_right / 2, .y = status_middle },
        .battery => .{ .x = screen_width - battery_reach / 2, .y = status_middle },
        .hero, .clear_search => .{ .x = (margin + hero_dots_left) / 2, .y = hero_middle },
        .hero_dots => .{
            .x = (hero_dots_left + screen_width) / 2,
            .y = (status_height + hero_dots_bottom) / 2,
        },
        .tab => |filter| for (tabs) |t| {
            const middle = @divTrunc(t.left + t.right, 2);
            if (t.filter == filter) break .{ .x = middle, .y = tabs_middle };
        } else unreachable, // Every filter has its tab
        .search => .{ .x = search_cx, .y = tabs_middle },
        .stats => .{ .x = stats_cx, .y = tabs_middle },
        .sort => .{ .x = @divTrunc(sort_left + screen_width, 2), .y = tabs_middle },
        .prev => footer.place(.prev),
        .next => footer.place(.next),
        .book => |index| book: {
            const r = book_rect(index, 0);
            break :book .{ .x = @intCast(r.x + r.w / 2), .y = @intCast(r.y + r.h / 2) };
        },
        .none => unreachable, // Not a control
    };
    assert(point.x >= 0);
    assert(point.y < style.screen_height);
    return point;
}

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
    const read: f32 = @floatFromInt(@min(percent, whole_percent));
    const filled = @as(f32, @floatFromInt(w)) * read / whole_percent;
    page.pill(left + r, left + @max(filled - r, r), cy, r, 0x00);
}

/// "32%" in a small white pill over a cover's bottom left corner.
fn percent_badge(font: *Font, page: Page, x: u32, y: u32, percent: u32) !void {
    assert(x >= margin);
    assert(y >= plain_grid_top + cover.height);
    var label: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&label, "{d}%", .{@min(percent, whole_percent)}) catch return;
    const r: f32 = badge.radius;
    const cy: f32 = @as(f32, @floatFromInt(y)) - badge.inset - r;
    try draw_badge(font, page, x, cy, s);
}

/// A corner badge's pill: its radius, in from its cover's corner, and its label's room
/// either side; the label is centred on its middle.
const badge = struct {
    const radius = style.space.snug;
    const inset = style.space.small;
    const label_pad = style.space.small;
};

/// `s` in a small white pill, its middle at `cy`, in from the cover's left at `x`.
fn draw_badge(font: *Font, page: Page, x: u32, cy: f32, s: []const u8) !void {
    assert(s.len > 0);
    const r: f32 = badge.radius;
    const left: f32 = @floatFromInt(x + badge.inset);
    const w = try font.measure(s) + 2 * badge.label_pad;
    const ends = [2]f32{ left + r, left + @max(w - r, r) };
    page.pill(ends[0], ends[1], cy, r, 0x00);
    page.pill(ends[0], ends[1], cy, r - 2, 0xff);
    try font.draw(page, left + badge.label_pad, font.centred_on(@intFromFloat(cy)), s);
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
    const cy: f32 = @as(f32, @floatFromInt(y)) + badge.inset + badge.radius;
    try draw_badge(font, page, x, cy, s);
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
    assert(w > 2 * type_inset);
    assert(h > type_title_top + type_author_above);
    page.fill_rect(x, y, w, h, type_paper);
    page.fill_rect(x, y, w, type_edge, 0x00);
    page.fill_rect(x, y + h - type_edge, w, type_edge, 0x00);
    page.fill_rect(x, y, type_edge, h, 0x00);
    page.fill_rect(x + w - type_edge, y, type_edge, h, 0x00);
    const left: f32 = @floatFromInt(x + type_inset);
    const avail: f32 = @floatFromInt(w - 2 * type_inset);
    const top: i32 = @intCast(y + type_title_top);
    const step = type_title_step;
    const lines = type_title_lines(h);
    const used = try draw.wrapped(fonts.cover, page, left, top, step, e.title, avail, lines);
    assert(used <= lines);
    const rule_y = y + type_title_top + used * type_title_step;
    page.fill_rect(x + type_inset, rule_y, type_rule_width, type_rule_height, 0x00);
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

    const left_px: u32 = margin + cover.hero_width + hero_text.gap;
    const left: f32 = @floatFromInt(left_px);
    const avail: f32 = @floatFromInt(page.width - left_px - margin);
    try fonts.caption.draw(page, left, hero_top + hero_text.kicker_drop, "Continue reading");
    const dots_x: f32 = @floatFromInt(page.width - margin - hero_text.dots_inset);
    icons.dots(page, dots_x, hero_top + hero_text.dots_drop);
    const kicker_width: u32 = @intFromFloat(avail - hero_text.kicker_clear);
    const kicker_y = hero_top + hero_text.kicker_drop;
    fonts.caption.fade(page, left_px, kicker_y, kicker_width, style.quiet);

    const title_y = hero_top + hero_text.title_drop;
    const step = hero_title_step;
    const lines = hero_title_lines;
    const used = try draw.wrapped(fonts.hero, page, left, title_y, step, e.title, avail, lines);
    assert(used <= hero_title_lines);
    const below_title: i32 = @as(i32, @intCast(used)) * hero_title_step - hero_text.author_rise;
    const author_y: i32 = title_y + below_title;
    const has_byline = try draw_hero_byline(fonts, page, e, left_px, author_y, avail);
    const bar_y = hero_top + cover.hero_height - hero_text.bar_rise;
    // The author, even under the longest title, is clear of the bar
    assert(author_y < bar_y);
    // Under the author (or the title, when there's no author): when it was last read,
    // and how long in noface, so the card says more than the cover does. Only for a
    // book really opened, as stock also dates downloads, and only clear of the bar.
    const line_y = if (has_byline) author_y + hero_text.line_step else author_y;
    if (e.was_opened() and line_y < bar_y - hero_text.bar_clear) {
        var when_buf: [24]u8 = undefined;
        if (stats.ago(&when_buf, e.last, now.unix, now.utc_offset)) |when| {
            try draw_hero_last_read(fonts, page, e, when, left_px, line_y, avail);
        }
    }

    progress_bar(page, left_px, bar_y, @intFromFloat(avail), e.percent, hero_text.bar_thick);
    var label: [24]u8 = undefined;
    const pct = std.fmt.bufPrint(&label, "{d}% read", .{e.percent}) catch "";
    const pct_y: i32 = @intCast(bar_y + hero_text.percent_drop);
    try fonts.caption.draw(page, left, pct_y, pct);
    fonts.caption.fade(page, left_px, pct_y, @intFromFloat(avail), style.faded);
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
    fonts.small.fade(page, left_px, author_y, @intFromFloat(avail), style.faded);
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
    fonts.caption.fade(page, left_px, line_y, @intFromFloat(avail), style.faded);
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
    const bar_y = y + cover.height + cell.bar_gap;
    const title_y: i32 = @intCast(bar_y + cell_title_below);
    const title_width: f32 = cover.width;
    const left: f32 = @floatFromInt(x);
    if (!e.is_local()) {
        page.tint(x, y, cover.width, cover.height, style.finished_cover);
        const cloud_x: f32 = @floatFromInt(x + cover.width - cell.cloud_inset);
        icons.cloud(page, cloud_x, @floatFromInt(y + cover.height - cell.cloud_inset));
        const label = if (e.availability == .downloading) "Downloading" else e.title;
        const step = cell.title_step;
        _ = try draw.wrapped(fonts.caption, page, left, title_y, step, label, title_width, 1);
        return;
    }
    if (e.in_progress()) {
        progress_bar(page, x, bar_y + cell.bar_drop, cover.width, e.percent, cell.bar_thick);
        try percent_badge(fonts.caption, page, x, y + cover.height, e.percent);
    }
    if (e.is_read()) {
        const tick = cell.tick_inset;
        icons.check(page, @floatFromInt(x + cover.width - tick), @floatFromInt(y + tick));
    }
    if (e.series) |s| try series_badge(fonts.caption, page, x, y, s.index);
    const step = cell.title_step;
    _ = try draw.wrapped(fonts.caption, page, left, title_y, step, e.title, title_width, 1);
}

fn draw_status(fonts: Fonts, page: Page, quick: *const quick_model.Quick) !void {
    const w: f32 = @floatFromInt(page.width);
    // One centre line for everything in the strip: the text's capitals centred on it,
    // the menu's lines from a little over it
    const centre = status_height / 2;
    const baseline = fonts.caption.centred_on(centre);
    assert(baseline < status_height);
    comptime assert(centre > status_menu_rise);
    icons.menu(page, margin, centre - status_menu_rise);
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
    try fonts.caption.draw(page, left, hero_top + hero_text.kicker_drop, "Search results");
    const kicker_y = hero_top + hero_text.kicker_drop;
    fonts.caption.fade(page, margin, kicker_y, @intFromFloat(avail), style.quiet);
    var quoted: [80]u8 = undefined;
    const shown = std.fmt.bufPrint(&quoted, "\u{201c}{s}\u{201d}", .{query}) catch query;
    try draw.clipped(fonts.hero, page, left, hero_top + search_head.query_drop, shown, avail);
    var count: [32]u8 = undefined;
    const plural = if (found == 1) "" else "s";
    const books = std.fmt.bufPrint(&count, "{d} book{s}", .{ found, plural }) catch "";
    try fonts.small.draw(page, left, hero_top + search_head.count_drop, books);
    const label = "Clear search";
    const w = try fonts.small.measure(label);
    const top: i32 = hero_top + search_head.button_drop - button_top;
    // The button stays inside the hero's place, where its taps go
    comptime assert(hero_top + search_head.button_drop + button_height <= hero_bottom);
    const pad = search_head.button_pad;
    button_outline(page, left, left + w + 2 * pad, top);
    const baseline = fonts.small.centred_baseline(top + button_top, button_height);
    try fonts.small.draw(page, left + pad, baseline, label);
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
    const y = fonts.small.centred_baseline(top + button_top, button_height);
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
        try draw.choice(fonts, page, x, .left, y, t.label, active, @intCast(top + tab_underline));
        // Over its label alone, clear of the pill's outline round the tabs
        const width: u32 = @intFromFloat(@ceil(try fonts.small.measure(t.label)));
        if (!active) fonts.small.fade(page, left, y, width, style.faded);
    }
    try draw_tabs_sort(fonts, page, top, order);
}

/// The sort button at the right of the tabs row, saying the order in use.
fn draw_tabs_sort(fonts: Fonts, page: Page, top: i32, order: catalog.Order) !void {
    assert(top == hero_tabs_top or top == plain_tabs_top);
    assert(order.label().len > 0);
    const y = fonts.small.centred_baseline(top + button_top, button_height);
    const cy: f32 = @floatFromInt(top + button_top + button_height / 2);
    const right: f32 = @floatFromInt(page.width - margin);
    // One width for every order, sized to the longest label, so the button stays put
    // as it cycles; the label sits centred in the room right of the arrows.
    var widest: f32 = 0;
    for (std.enums.values(catalog.Order)) |o| {
        widest = @max(widest, try fonts.small.measure(o.label()));
    }
    const arrows = sort_arrows_width + sort_arrows_gap;
    const button_left = right - sort_label_pad - widest - arrows - icon_inset;
    button_outline(page, button_left, right, top);
    icons.sort_arrows(page, button_left + icon_inset, cy);
    const label_left = button_left + icon_inset + arrows;
    const label_w = try fonts.small.measure(order.label());
    const label_x = label_left + (right - sort_label_pad - label_left - label_w) / 2;
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
        try fonts.small.draw(page, margin, @intCast(top + empty_drop), empty);
    }
    try footer.render(fonts, page, index, page_count(books.count));
    if (message.len > 0) try fonts.caption.draw(page, margin, message_baseline, message);
}

/// Where tests tap: the middle of the `slot`th cover on a page, of a filter's tab, of the
/// tabs row, of each pager arrow, and inside the hero's place clear of its dots.
fn test_book(slot: u32, hero: bool) [2]i32 {
    const at = cell_origin(slot, hero);
    return .{ @intCast(at.x + cover.width / 2), @intCast(at.y + cover.height / 2) };
}
fn test_tab_x(t: Tab) i32 {
    return @divTrunc(t.label_left + t.right, 2);
}
fn test_tabs_y(hero: bool) i32 {
    return tabs_top(hero) + tabs_height / 2;
}
const test_pager_y = (footer.top + footer.bottom) / 2;
const test_prev_x = draw.Pager.prev_left + 1;
const test_next_x = draw.Pager.next_left + 1;
const test_hero_x = margin + cover.hero_width;
const test_hero_y = (hero_top + hero_bottom) / 2;
const test_dots_x = screen_width - margin - 1;
const test_books = 79; // More than fill page one

test "the current book stays on page one of every view" {
    try std.testing.expectEqual(Hit.hero, hit(test_hero_x, test_hero_y, 0, test_books, false));
    for ([_]u32{ 0, columns - 1, columns }) |slot| {
        const at = test_book(slot, true);
        try std.testing.expectEqual(Hit{ .book = slot }, hit(at[0], at[1], 0, test_books, false));
    }
}

test "later pages lead on from page one's last book" {
    const first = test_book(0, false);
    const first_index = grid_size(true);
    const expected: Hit = .{ .book = first_index };
    try std.testing.expectEqual(expected, hit(first[0], first[1], 1, test_books, false));
    const last_slot = grid_size(false) - 1;
    const last = test_book(last_slot, false);
    const last_hit: Hit = .{ .book = first_index + last_slot };
    try std.testing.expectEqual(last_hit, hit(last[0], last[1], 1, test_books, false));
}

test "every control's place is a tap on it" {
    const books = grid_size(true) + grid_size(false); // A second page, for the pager
    const filters = std.enums.values(catalog.Filter);
    var controls: [12 + filters.len]Hit = undefined;
    const last_on_page = grid_size(true) - 1;
    const fixed = [_]Hit{
        .hero,    .hero_dots, .prev,  .next,          .sort,                     .menu,
        .battery, .search,    .stats, .{ .book = 0 }, .{ .book = last_on_page }, .clear_search,
    };
    @memcpy(controls[0..fixed.len], &fixed);
    for (controls[fixed.len..], filters) |*c, f| c.* = .{ .tab = f };
    for (controls) |h| {
        const p = place(h);
        const searching = h == .clear_search;
        try std.testing.expectEqual(h, hit(p.x, p.y, 0, books, searching));
    }
}

test "header and footer controls" {
    try std.testing.expectEqual(Hit.menu, hit(margin, status_height / 2, 0, test_books, false));
    const y = test_tabs_y(true);
    for (tabs) |t| {
        const expected: Hit = .{ .tab = t.filter };
        try std.testing.expectEqual(expected, hit(test_tab_x(t), y, 0, test_books, false));
    }
    // Between stats and sort
    const gap_x = stats_cx + search_reach + 1;
    try std.testing.expectEqual(Hit.none, hit(gap_x, y, 0, test_books, false));
    try std.testing.expectEqual(Hit.sort, hit(sort_left, y, 0, test_books, false));
    try std.testing.expectEqual(Hit.prev, hit(test_prev_x, test_pager_y, 0, test_books, false));
    try std.testing.expectEqual(Hit.next, hit(test_next_x, test_pager_y, 0, test_books, false));
}

test "tapping past the last book does nothing" {
    const fourth = test_book(3, true);
    try std.testing.expectEqual(Hit.none, hit(fourth[0], fourth[1], 0, 3, false));
}

test "page count follows the layout" {
    const one = grid_size(true);
    const later = grid_size(false);
    try std.testing.expectEqual(@as(u32, 1), page_count(0));
    try std.testing.expectEqual(@as(u32, 1), page_count(one));
    try std.testing.expectEqual(@as(u32, 2), page_count(one + 1));
    try std.testing.expectEqual(@as(u32, 2), page_count(one + later));
    try std.testing.expectEqual(@as(u32, 3), page_count(one + later + 1));
}

test "search button sits beside the filter, and the search takes the hero's place" {
    const y = test_tabs_y(true);
    try std.testing.expectEqual(Hit.search, hit(search_cx, y, 0, test_books, false));
    // The gap between the filter and search
    const gap_x = tabs[tabs.len - 1].right + 1;
    try std.testing.expectEqual(Hit.none, hit(gap_x, y, 0, test_books, false));
    try std.testing.expectEqual(Hit.stats, hit(stats_cx, y, 0, test_books, false));
    const search_edge = search_cx + search_reach;
    try std.testing.expectEqual(Hit.search, hit(search_edge, y, 0, test_books, false));
    try std.testing.expectEqual(Hit.stats, hit(stats_cx - search_reach, y, 0, test_books, false));
    const later_y = test_tabs_y(false);
    try std.testing.expectEqual(Hit.search, hit(search_cx, later_y, 1, test_books, false));
    for (tabs) |t| try std.testing.expect(t.right - t.left >= style.fingertip);
    try std.testing.expect(2 * search_reach >= style.fingertip);
    const cleared = hit(test_hero_x, test_hero_y, 0, test_books, true);
    try std.testing.expectEqual(Hit.clear_search, cleared);
}

test "a book's title is part of the book, and the hero keeps its dots" {
    const at = cell_origin(0, true);
    const title_y: i32 = @intCast(at.y + cover.height + cell.bar_gap + cell_title_below);
    const left_x: i32 = @intCast(at.x);
    try std.testing.expectEqual(Hit{ .book = 0 }, hit(left_x, title_y, 0, test_books, false));
    const dots_y = hero_top + hero_text.dots_drop;
    try std.testing.expectEqual(Hit.hero_dots, hit(test_dots_x, dots_y, 0, test_books, false));
    // A fingertip tall: from just under the status strip to well under the dots
    const top_hit = hit(test_dots_x, status_height, 0, test_books, false);
    try std.testing.expectEqual(Hit.hero_dots, top_hit);
    const foot_hit = hit(test_dots_x, hero_dots_bottom - 1, 0, test_books, false);
    try std.testing.expectEqual(Hit.hero_dots, foot_hit);
    const under = hit(test_dots_x, hero_dots_bottom, 0, test_books, false);
    try std.testing.expectEqual(Hit.hero, under);
}

test "the tabs row takes taps just off its pills, and the filter's from its funnel" {
    // Page one: from the hero's place down to the grid
    const all: Hit = .{ .tab = .all };
    const x = test_tab_x(tabs[0]);
    try std.testing.expectEqual(all, hit(x, hero_bottom, 0, test_books, false));
    try std.testing.expectEqual(all, hit(x, hero_grid_top - 1, 0, test_books, false));
    try std.testing.expectEqual(Hit.sort, hit(sort_left, hero_grid_top - 1, 0, test_books, false));
    const first = cell_origin(0, true);
    const first_x: i32 = @intCast(first.x);
    const grid_hit = hit(first_x, hero_grid_top, 0, test_books, false);
    try std.testing.expectEqual(Hit{ .book = 0 }, grid_hit);
    // Later pages: from the status strip down to the grid
    try std.testing.expectEqual(all, hit(x, status_height, 1, test_books, false));
    try std.testing.expectEqual(all, hit(x, plain_grid_top - 1, 1, test_books, false));
    try std.testing.expectEqual(Hit.menu, hit(margin, status_height - 1, 1, test_books, false));
    // The funnel, at the button's rounded end, is part of the first tab
    const y = test_tabs_y(true);
    try std.testing.expectEqual(all, hit(margin + icon_inset, y, 0, test_books, false));
    try std.testing.expectEqual(all, hit(margin, y, 0, test_books, false));
    try std.testing.expectEqual(Hit.none, hit(margin - 1, y, 0, test_books, false));
}

test "a cover set in type has room for its title's lines above the author" {
    // A long title's four lines at least, on a grid cover and the hero's
    try std.testing.expect(type_title_lines(cover.height) >= 4);
    try std.testing.expect(type_title_lines(cover.hero_height) >= 4);
}
