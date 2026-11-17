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

pub const top_height = 228;
pub const bottom_top = 1410;
pub const scrub_top = 1500;
const screen_height = style.screen_height;
const margin = style.margin;
pub const status_row = 66; // The clock and battery strip at the very top
const tool_row = 156;
const tool_reach = 56; // Taps this far either side of a tool's centre
const tool_icon_y = 118; // The middle of the tools' icons, and of Home's
const home_right = 300; // Home takes taps left of here
const chapter_prev_right = 220; // The chapter buttons take taps out to here from each edge
const chapter_next_left = 1052;
const skip_inset = 110; // From each edge to the middle of a chapter button's icon
const scrub = slider.Slider{ .left = 110, .right = 1162, .y = 1610 };

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
const tools = [_]Tool{
    .{ .hit = .text, .x = 696 },
    .{ .hit = .goto, .x = 816 },
    .{ .hit = .bookmark, .x = 936 },
    .{ .hit = .search, .x = 1056 },
    .{ .hit = .more, .x = 1176 },
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
    assert(2 * tool_reach >= 100);
    assert(home_right <= tools[0].x - tool_reach);
    for (tools[0 .. tools.len - 1], tools[1..]) |left, right| {
        assert(left.x + tool_reach <= right.x - tool_reach);
    }
    assert(tools[tools.len - 1].x + tool_reach <= style.screen_width);
    // Icons are drawn where they take taps
    assert(tool_icon_y >= status_row);
    assert(tool_icon_y < tool_row + 12);
    assert(skip_inset < chapter_prev_right);
    assert(style.screen_width - skip_inset >= chapter_next_left);
    assert(chapter_prev_right < chapter_next_left);
}

/// `sheet` is the Aa tab open, if the sheet is.
pub fn hit(x: i32, y: i32, sheet: ?aa.Tab) Hit {
    if (y < status_row) return .stay;
    if (y < top_height) {
        if (y >= tool_row + 12) return .stay;
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
    if (y >= scrub_top) return .scrub;
    if (x < chapter_prev_right) return .chapter_prev;
    if (x >= chapter_next_left) return .chapter_next;
    return .stay;
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
        try draw.centered(fonts.small, page, centre, scrub_top + 56, "Laying out pages\u{2026}");
        page.tint(0, scrub_top + 20, page.width, 50, style.faded);
        if (mono) page.threshold(scrub_top, screen_height - scrub_top);
        return;
    };
    assert(p.index < p.total);
    var label: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&label, "Page {d} of {d}", .{ p.index + 1, p.total }) catch "";
    try draw.centered(fonts.small, page, centre, scrub_top + 56, s);
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
    bookmarked: bool,
) !void {
    assert(page.width > 2 * margin);
    const w: f32 = @floatFromInt(page.width);
    page.fill_rect(0, 0, page.width, top_height, 0xff);

    const clock = quick.clock_text();
    const time = clock[0 .. std.mem.indexOfScalar(u8, clock, ' ') orelse clock.len];
    // Centred, as on the page and in the library
    try draw.centered(fonts.caption, page, w / 2, 54, time);
    try icons.status_cluster(page, fonts.caption, w - margin, 45, 54, quick, false);

    icons.back(page, margin + 18, tool_icon_y);
    try fonts.small.draw(page, margin + 56, 130, "Home");
    // Each tool drawn where its entry says it takes taps
    for (tools) |t| try draw_tool(fonts, page, t, bookmarked);

    try draw.clipped(fonts.caption, page, margin, tool_row + 54, title, w - 2 * margin);
    page.tint(margin, tool_row + 20, page.width - 2 * margin, 46, style.faded);
    page.fill_rect(0, top_height - 4, page.width, 4, 0x00);
    if (sheet) |tab| try aa.render(fonts, page, tab, chosen);

    page.fill_rect(0, bottom_top, page.width, screen_height - bottom_top, 0xff);
    page.fill_rect(0, bottom_top, page.width, 4, 0x00);
    icons.skip(page, skip_inset, bottom_top + 46, false);
    icons.skip(page, w - skip_inset, bottom_top + 46, true);
    try draw_scrub(fonts, page, at, false);
}

/// One tool's icon, at its place in `tools`.
fn draw_tool(fonts: Fonts, page: Page, t: Tool, bookmarked: bool) !void {
    const x: f32 = @floatFromInt(t.x);
    assert(t.x >= home_right); // Right of Home, as the tools are
    switch (t.hit) {
        .text => try fonts.title.draw(page, x - 34, 132, "Aa"),
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

test "toolbar buttons map to actions" {
    try std.testing.expectEqual(Hit.home, hit(120, 118, null));
    try std.testing.expectEqual(Hit.text, hit(696, 118, null));
    try std.testing.expectEqual(Hit.goto, hit(816, 118, null));
    try std.testing.expectEqual(Hit.bookmark, hit(936, 118, null));
    try std.testing.expectEqual(Hit.search, hit(1056, 118, null));
    try std.testing.expectEqual(Hit.more, hit(1176, 118, null));
    try std.testing.expectEqual(Hit.stay, hit(500, 118, null));
    try std.testing.expectEqual(Hit.close, hit(600, 800, null));
    try std.testing.expectEqual(Hit.chapter_prev, hit(110, 1450, null));
    try std.testing.expectEqual(Hit.chapter_next, hit(1162, 1450, null));
    try std.testing.expectEqual(Hit.scrub, hit(600, 1610, null));
    try std.testing.expectEqual(Hit.scrub, hit(100, 1650, null));
}

test "text sheet takes taps only while open" {
    try std.testing.expectEqual(Hit.close, hit(350, 320, null));
    try std.testing.expectEqual(Hit.sheet, hit(350, 320, .font));
    try std.testing.expectEqual(Hit.sheet, hit(700, 800, .font)); // Font and More reach lower
    try std.testing.expectEqual(Hit.close, hit(700, 800, .layout));
    try std.testing.expectEqual(Hit.close, hit(700, 900, .font));
}

test "scrubber maps position to page" {
    try std.testing.expectEqual(@as(u32, 0), page_at(0, 280));
    try std.testing.expectEqual(@as(u32, 279), page_at(1272, 280));
    try std.testing.expectEqual(@as(u32, 140), page_at(636, 280));
    try std.testing.expectEqual(@as(u32, 0), page_at(600, 1));
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
