//! Reading toolbar: a single tap at the top of a page opens it.
const std = @import("std");
const assert = std.debug.assert;
const settings_model = @import("../model/settings.zig");
const Page = @import("../gfx/page.zig").Page;
const draw = @import("draw.zig");
const style = @import("style.zig");
const Fonts = @import("fonts.zig").Fonts;
const aa = @import("aa.zig");
const icons = @import("icons.zig");
const slider = @import("slider.zig");
const quick_model = @import("../model/quick.zig");
const text = @import("../layout/text.zig");

const screen_width = style.screen_width;
const screen_height = style.screen_height;
const margin = style.margin;

// The top bar, three bands down from the screen's top: the status strip (the clock and
// battery), the tools' row, and the book's title under them.
const status_band = 66;
const tools_band = 90;
const title_band = 72;
pub const status_row = status_band;
const tool_row = status_row + tools_band;
pub const top_height = tool_row + title_band;
/// The tools' icons' middles, on Home's line, which sits under the status line as every
/// back link sits under the strip above it.
const tool_icon_y = status_row + draw.back_link.drop;
const tool_reach = 56; // Taps this far either side of a tool's centre
/// The tools take taps this far into the title's band under them.
const tool_taps_below = 12;
/// The clock's baseline and the status icons' middle, down from the screen's top.
const status_text_y = 54;
const status_icons_y = 45;
/// The book's title, faded: its baseline, down from the title band's top.
const title_baseline_drop = 54;
const tool_spacing = 120; // From one tool's centre to the next
/// The last tool's centre, in from the screen's right edge past the margin.
const last_tool_inset = margin + 24;
const home_right = 300; // Home takes taps left of here

// The bottom bar, up from the screen's foot: the chapter buttons' band, then the
// scrubber's under it.
const bottom_band = 286;
const chapters_band = 90;
pub const bottom_top = screen_height - bottom_band;
pub const scrub_top = bottom_top + chapters_band;
/// The chapter buttons' icons' middles, down from the bottom bar's top.
const chapter_icon_drop = 46;
/// From each edge to the middle of a chapter button's icon, and to an end of the
/// scrubber's bar under it; the buttons take taps out to twice that from each edge.
const skip_inset = style.slider_inset;
const chapter_prev_right = 2 * skip_inset;
const chapter_next_left = screen_width - 2 * skip_inset;
/// The scrubber's bar and its label, down from the scrubber's band's top.
const scrub_drop = 110;
const scrub_label_drop = 56;
const scrub = slider.Slider{
    .left = skip_inset,
    .right = screen_width - skip_inset,
    .y = scrub_top + scrub_drop,
};
/// The scrubber takes taps this far above its bar, and all the way below it: a tap
/// meant for a chapter button that lands a little low must not jump the book.
const scrub_reach = 60;

pub const Hit = enum {
    close,
    stay,
    home,
    text,
    goto,
    bookmark,
    search,
    more,
    chapter_prev,
    chapter_next,
    scrub,
    sheet,
};

const Tool = struct { hit: Hit, x: i32 };
/// The tools, left to right, `tool_spacing` apart, the last `last_tool_inset` in from
/// the right edge.
const tools = tools: {
    const order = [_]Hit{ .text, .goto, .bookmark, .search, .more };
    var placed: [order.len]Tool = undefined;
    for (order, 0..) |h, i| {
        const from_last: i32 = @intCast(order.len - 1 - i);
        placed[i] = .{ .hit = h, .x = screen_width - last_tool_inset - from_last * tool_spacing };
    }
    break :tools placed;
};

comptime {
    // The bands, top to bottom, each inside the screen
    assert(status_row < tool_row);
    assert(tool_row < top_height);
    assert(top_height < aa.max_height);
    assert(aa.max_height < bottom_top);
    assert(bottom_top < scrub_top);
    assert(scrub_top < scrub.y);
    assert(scrub.y < screen_height);
    assert(scrub.left < scrub.right);
    assert(scrub.right <= style.screen_width);
    // Each tool takes a fingertip, apart from Home and its neighbours, and on screen
    assert(2 * tool_reach >= style.fingertip);
    assert(home_right <= tools[0].x - tool_reach);
    for (tools[0 .. tools.len - 1], tools[1..]) |left, right| {
        assert(left.x + tool_reach <= right.x - tool_reach);
    }
    assert(tools[tools.len - 1].x + tool_reach <= style.screen_width);
    // Icons are drawn where they take taps
    assert(tool_icon_y >= status_row);
    assert(tool_icon_y < tool_row + tool_taps_below);
    assert(skip_inset < chapter_prev_right);
    assert(style.screen_width - skip_inset >= chapter_next_left);
    assert(chapter_prev_right < chapter_next_left);
    // The chapter buttons take a fingertip of height above the scrubber's taps, and
    // those start inside the band the scrubber is drawn in
    assert(scrub.y - scrub_reach - bottom_top >= style.fingertip);
    assert(scrub.y - scrub_reach >= scrub_top);
    assert(2 * scrub_reach >= style.fingertip);
}

/// `sheet` is the Aa tab open, if the sheet is.
pub fn hit(x: i32, y: i32, sheet: ?aa.Tab) Hit {
    if (y < status_row) return .stay;
    if (y < top_height) {
        if (y >= tool_row + tool_taps_below) return .stay;
        if (x < home_right) return .home;
        for (tools) |t| {
            if (@abs(x - t.x) < tool_reach) return t.hit;
        }
        return .stay;
    }
    if (sheet) |tab| {
        // The sheet hangs under the toolbar and clear of the bottom bar
        assert(aa.height_for(tab) > top_height);
        assert(aa.height_for(tab) < bottom_top);
        if (y < aa.height_for(tab)) return .sheet;
    }
    if (y < bottom_top) return .close;
    if (y >= scrub.y - scrub_reach) return .scrub;
    if (x < chapter_prev_right) return .chapter_prev;
    if (x >= chapter_next_left) return .chapter_next;
    return .stay;
}

/// Where a tap closes the toolbar with the Aa sheet open on any tab: between the sheet's
/// foot, at its tallest, and the bottom bar.
pub fn close_under_sheet() style.Point {
    var sheet_foot: u32 = 0;
    for (std.enums.values(aa.Tab)) |tab| sheet_foot = @max(sheet_foot, aa.height_for(tab));
    assert(sheet_foot < bottom_top);
    const middle: i32 = @intCast((sheet_foot + bottom_top) / 2);
    const point: style.Point = .{ .x = screen_width / 2, .y = middle };
    for (std.enums.values(aa.Tab)) |tab| assert(hit(point.x, point.y, tab) == .close);
    return point;
}

/// The middle of a control's taps, with the Aa sheet closed. The scrubber's is its
/// middle, a page halfway through the book.
pub fn place(h: Hit) style.Point {
    const tools_middle = status_row + (tool_row + tool_taps_below - status_row) / 2;
    const bottom_middle = bottom_top + (scrub.y - scrub_reach - bottom_top) / 2;
    const point: style.Point = switch (h) {
        .home => .{ .x = home_right / 2, .y = tools_middle },
        .text, .goto, .bookmark, .search, .more => for (tools) |t| {
            if (t.hit == h) break .{ .x = t.x, .y = tools_middle };
        } else unreachable, // Every tool is in the row
        .close => .{ .x = screen_width / 2, .y = (top_height + bottom_top) / 2 },
        .chapter_prev => .{ .x = chapter_prev_right / 2, .y = bottom_middle },
        .chapter_next => .{ .x = (chapter_next_left + screen_width) / 2, .y = bottom_middle },
        .scrub => .{ .x = (scrub.left + scrub.right) / 2, .y = scrub.y },
        // Not a control: what's left between them, and the sheet's own controls
        .stay, .sheet => unreachable,
    };
    assert(point.x >= 0);
    assert(point.y < screen_height);
    return point;
}

/// Page index for a finger at `x` on the scrubber.
pub fn page_at(x: i32, total: u32) u32 {
    if (total <= 1) return 0;
    const page = slider.value_at(scrub, x, total - 1);
    assert(page < total);
    return page;
}

/// Page where the chapter before or after the current one starts.
/// `sections` holds each page's section. Back goes to this chapter's start first.
pub fn chapter_target(sections: []const u32, current: u32, forward: bool) u32 {
    assert(current < sections.len);
    assert(sections.len <= std.math.maxInt(u32));
    const page = current;
    var target: u32 = undefined;
    if (forward) {
        target = chapter_target_next(sections, page);
        assert(target >= page);
    } else {
        target = chapter_target_previous(sections, page);
        assert(target <= page);
    }
    assert(target < sections.len);
    return target;
}

fn chapter_target_next(sections: []const u32, current: u32) u32 {
    assert(current < sections.len);
    var page = current + 1;
    while (page < sections.len) : (page += 1) {
        if (sections[page] != sections[current]) return page;
    }
    return current;
}

fn chapter_target_previous(sections: []const u32, current: u32) u32 {
    assert(current < sections.len);
    var start = current;
    while (start > 0 and sections[start - 1] == sections[current]) start -= 1;
    if (start != current or start == 0) return start;
    start -= 1;
    while (start > 0 and sections[start - 1] == sections[current - 1]) start -= 1;
    assert(start < current);
    return start;
}

/// Where the reader is in the book: a page of how many.
pub const Position = struct { index: u32, total: u32 };

/// Band that changes while dragging, redrawn alone in pure black and white when `mono`.
/// The page slider, at `at`, or null while the pages are still being laid out: it
/// says so, and has no knob until there's a place to put it.
pub fn draw_scrub(fonts: Fonts, page: Page, at: ?Position, mono: bool) !void {
    assert(page.height > scrub_top);
    page.fill_rect(0, scrub_top, page.width, screen_height - scrub_top, 0xff);
    const centre: f32 = @floatFromInt(page.width / 2);
    const p = at orelse {
        const y = scrub_top + scrub_label_drop;
        try draw.centered(fonts.small, page, centre, y, "Laying out pages\u{2026}");
        // The label faded, as nothing can be done with it yet
        fonts.small.fade(page, 0, y, page.width, style.faded);
        if (mono) page.threshold(scrub_top, screen_height - scrub_top);
        return;
    };
    assert(p.index < p.total);
    var label: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&label, "Page {d} of {d}", .{ p.index + 1, p.total }) catch "";
    try draw.centered(fonts.small, page, centre, scrub_top + scrub_label_drop, s);
    const knob = slider.knob_at(scrub, p.index, p.total - 1);
    slider.draw(page, scrub, knob);
    if (mono) page.threshold(scrub_top, screen_height - scrub_top);
}

pub fn render(
    fonts: Fonts,
    page: Page,
    title: []const u8,
    at: ?Position,
    quick: *const quick_model.Quick,
    sheet: ?aa.Tab,
    chosen: settings_model.Settings,
    running: bool,
    bookmarked: bool,
) !void {
    assert(page.width > 2 * margin);
    const w: f32 = @floatFromInt(page.width);
    page.fill_rect(0, 0, page.width, top_height, 0xff);

    const clock = quick.clock_text();
    const time = clock[0 .. std.mem.indexOfScalar(u8, clock, ' ') orelse clock.len];
    // Centred, as on the page and in the library
    try draw.centered(fonts.caption, page, w / 2, status_text_y, time);
    const right = w - margin;
    const status_y = status_icons_y;
    try icons.status_cluster(page, fonts.caption, right, status_y, status_text_y, quick, false);

    try draw.draw_back_link(fonts.small, page, tool_icon_y, "Home");
    // Each tool drawn where its entry says it takes taps
    for (tools) |t| try draw_tool(fonts, page, t, bookmarked);

    const title_y = tool_row + title_baseline_drop;
    try draw.clipped(fonts.caption, page, margin, title_y, title, w - 2 * margin);
    fonts.caption.fade(page, margin, title_y, page.width - 2 * margin, style.faded);
    page.fill_rect(0, top_height - 4, page.width, 4, 0x00);
    if (sheet) |tab| try aa.render(fonts, page, tab, chosen, running);

    page.fill_rect(0, bottom_top, page.width, screen_height - bottom_top, 0xff);
    page.fill_rect(0, bottom_top, page.width, 4, 0x00);
    icons.skip(page, skip_inset, bottom_top + chapter_icon_drop, false);
    icons.skip(page, w - skip_inset, bottom_top + chapter_icon_drop, true);
    try draw_scrub(fonts, page, at, false);
}

/// One tool's icon, at its place in `tools`.
fn draw_tool(fonts: Fonts, page: Page, t: Tool, bookmarked: bool) !void {
    const x: f32 = @floatFromInt(t.x);
    assert(t.x >= home_right); // Right of Home, as the tools are
    switch (t.hit) {
        .text => {
            // Centred on the tool, to the whole pixel, as the icons beside it are
            const half = @floor(try fonts.title.measure("Aa") / 2);
            // Its capitals' middle on the icons' line, as every label beside an icon
            try fonts.title.draw(page, x - half, fonts.title.centred_on(tool_icon_y), "Aa");
        },
        .goto => icons.lines(page, x, tool_icon_y),
        .bookmark => if (bookmarked) {
            icons.bookmark_filled(page, x, tool_icon_y);
        } else {
            icons.bookmark(page, x, tool_icon_y);
        },
        .search => icons.search(page, x, tool_icon_y),
        .more => icons.dots(page, x, tool_icon_y),
        // Only the five above are in `tools`; these are the toolbar's other parts
        .close, .stay, .home, .chapter_prev, .chapter_next, .scrub, .sheet => unreachable,
    }
}

test "every control's place is a tap on it" {
    for (std.enums.values(Hit)) |h| {
        if (h == .stay or h == .sheet) continue;
        const p = place(h);
        try std.testing.expectEqual(h, hit(p.x, p.y, null));
    }
}

test "toolbar buttons map to actions" {
    const y = tool_icon_y;
    try std.testing.expectEqual(Hit.home, hit(margin, y, null));
    for (tools) |t| try std.testing.expectEqual(t.hit, hit(t.x, y, null));
    // Between Home and the first tool
    try std.testing.expectEqual(Hit.stay, hit(home_right + 1, y, null));
    const middle_y = (top_height + bottom_top) / 2;
    try std.testing.expectEqual(Hit.close, hit(screen_width / 2, middle_y, null));
    const chapters_y = bottom_top + chapter_icon_drop;
    try std.testing.expectEqual(Hit.chapter_prev, hit(skip_inset, chapters_y, null));
    try std.testing.expectEqual(Hit.chapter_next, hit(screen_width - skip_inset, chapters_y, null));
    try std.testing.expectEqual(Hit.scrub, hit(screen_width / 2, scrub.y, null));
    try std.testing.expectEqual(Hit.scrub, hit(0, screen_height - 1, null));
}

test "a chapter button takes a fingertip, and a low tap on it never jumps the book" {
    // Where the scrubber's taps once began, under the chapter buttons
    const low = scrub_top + 5;
    try std.testing.expectEqual(Hit.chapter_prev, hit(skip_inset, low, null));
    try std.testing.expectEqual(Hit.chapter_next, hit(screen_width - skip_inset, low, null));
    try std.testing.expectEqual(Hit.stay, hit(screen_width / 2, low, null));
    try std.testing.expectEqual(Hit.chapter_prev, hit(skip_inset, bottom_top, null));
    const below = scrub.y - scrub_reach;
    try std.testing.expectEqual(Hit.chapter_prev, hit(skip_inset, below - 1, null));
    try std.testing.expectEqual(Hit.scrub, hit(skip_inset, below, null));
}

test "text sheet takes taps only while open" {
    // Inside every tab's sheet; below Layout's but inside Font's; below Font's
    const layout_foot: i32 = @intCast(aa.height_for(.layout));
    const font_foot: i32 = @intCast(aa.height_for(.font));
    const under = @divTrunc(top_height + layout_foot, 2);
    try std.testing.expectEqual(Hit.close, hit(screen_width / 4, under, null));
    try std.testing.expectEqual(Hit.sheet, hit(screen_width / 4, under, .font));
    const low = @divTrunc(layout_foot + font_foot, 2);
    try std.testing.expectEqual(Hit.sheet, hit(screen_width / 2, low, .font));
    try std.testing.expectEqual(Hit.close, hit(screen_width / 2, low, .layout));
    const past = @divTrunc(font_foot + bottom_top, 2);
    try std.testing.expectEqual(Hit.close, hit(screen_width / 2, past, .font));
}

test "scrubber maps position to page" {
    try std.testing.expectEqual(@as(u32, 0), page_at(0, 280));
    try std.testing.expectEqual(@as(u32, 279), page_at(screen_width, 280));
    try std.testing.expectEqual(@as(u32, 140), page_at(screen_width / 2, 280));
    try std.testing.expectEqual(@as(u32, 0), page_at(screen_width / 2, 1));
}

test "chapter skipping" {
    const sections = [_]u32{ 1, 1, 2, 2, 2, 3, 3 };
    try std.testing.expectEqual(@as(u32, 2), chapter_target(&sections, 0, true));
    try std.testing.expectEqual(@as(u32, 5), chapter_target(&sections, 3, true));
    try std.testing.expectEqual(@as(u32, 6), chapter_target(&sections, 6, true));
    // Back to the start of this one, then to the one before
    try std.testing.expectEqual(@as(u32, 2), chapter_target(&sections, 4, false));
    try std.testing.expectEqual(@as(u32, 0), chapter_target(&sections, 2, false));
    try std.testing.expectEqual(@as(u32, 0), chapter_target(&sections, 0, false));
}
