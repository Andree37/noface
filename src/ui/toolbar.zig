//! Reading toolbar: a single tap at the top of a page opens it.
const std = @import("std");
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
const scrub = slider.Slider{ .left = 110, .right = 1162, .y = 1610 };

pub const Hit = enum { close, stay, home, text, goto, bookmark, search, more, chapter_prev, chapter_next, scrub, sheet };

const Tool = struct { hit: Hit, x: i32 };
const tools = [_]Tool{
    .{ .hit = .text, .x = 696 },
    .{ .hit = .goto, .x = 816 },
    .{ .hit = .bookmark, .x = 936 },
    .{ .hit = .search, .x = 1056 },
    .{ .hit = .more, .x = 1176 },
};

/// `sheet` is the Aa tab open, if the sheet is.
pub fn hit(x: i32, y: i32, sheet: ?aa.Tab) Hit {
    if (y < status_row) return .stay;
    if (y < top_height) {
        if (y >= tool_row + 12) return .stay;
        if (x < 300) return .home;
        for (tools) |t| {
            if (@abs(x - t.x) < 56) return t.hit;
        }
        return .stay;
    }
    if (sheet) |tab| if (y < aa.heightFor(tab)) return .sheet;
    if (y < bottom_top) return .close;
    if (y >= scrub_top) return .scrub;
    if (x < 220) return .chapter_prev;
    if (x >= 1052) return .chapter_next;
    return .stay;
}

/// Page index for a finger at `x` on the scrubber.
pub fn pageAt(x: i32, total: usize) usize {
    if (total <= 1) return 0;
    return slider.valueAt(scrub, x, @intCast(total - 1));
}

/// Page where the chapter before or after the current one starts.
/// `sections` holds each page's section. Back goes to this chapter's start first.
pub fn chapterTarget(sections: []const u32, current: usize, forward: bool) usize {
    if (forward) {
        var i = current + 1;
        while (i < sections.len) : (i += 1) {
            if (sections[i] != sections[current]) return i;
        }
        return current;
    }
    var start = current;
    while (start > 0 and sections[start - 1] == sections[current]) start -= 1;
    if (start != current or start == 0) return start;
    start -= 1;
    while (start > 0 and sections[start - 1] == sections[current - 1]) start -= 1;
    return start;
}

/// Band that changes while dragging, redrawn alone in pure black and white when `mono`.
/// The page slider. A `total` of 0 means the pages are still being laid out: it says
/// so, and has no knob until there's a place to put it.
pub fn drawScrub(fonts: Fonts, page: Page, index: usize, total: usize, mono: bool) !void {
    page.fillRect(0, scrub_top, page.width, screen_height - scrub_top, 0xff);
    var label: [32]u8 = undefined;
    const s = if (total == 0) "Laying out pages\u{2026}" else std.fmt.bufPrint(&label, "Page {d} of {d}", .{ index + 1, total }) catch "";
    try draw.centered(fonts.small, page, @floatFromInt(page.width / 2), scrub_top + 56, s);
    if (total == 0) {
        page.tint(0, scrub_top + 20, page.width, 50, style.faded);
        if (mono) page.threshold(scrub_top, screen_height - scrub_top);
        return;
    }
    slider.draw(page, scrub, slider.knobAt(scrub, @intCast(index), @intCast(@max(total, 1) - 1)));
    if (mono) page.threshold(scrub_top, screen_height - scrub_top);
}

pub fn render(fonts: Fonts, page: Page, title: []const u8, index: usize, total: usize, quick: *const quick_model.Quick, sheet: ?aa.Tab, chosen: settings_model.Settings, bookmarked: bool) !void {
    const w: f32 = @floatFromInt(page.width);
    page.fillRect(0, 0, page.width, top_height, 0xff);

    const clock = quick.clockText();
    const time = clock[0 .. std.mem.indexOfScalar(u8, clock, ' ') orelse clock.len];
    try draw.centered(fonts.caption, page, w / 2, 54, time); // Centred, as on the page and in the library
    try icons.statusCluster(page, fonts.caption, w - margin, 45, 54, quick, false);

    icons.back(page, margin + 18, 118);
    try fonts.small.draw(page, margin + 56, 130, "Home");
    try fonts.title.draw(page, tools[0].x - 34, 132, "Aa");
    icons.lines(page, tools[1].x, 118);
    if (bookmarked) icons.bookmarkFilled(page, tools[2].x, 118) else icons.bookmark(page, tools[2].x, 118);
    icons.search(page, tools[3].x, 118);
    icons.dots(page, tools[4].x, 118);

    try draw.clipped(fonts.caption, page, margin, tool_row + 54, title, w - 2 * margin);
    page.tint(margin, tool_row + 20, page.width - 2 * margin, 46, style.faded);
    page.fillRect(0, top_height - 4, page.width, 4, 0x00);
    if (sheet) |tab| try aa.render(fonts, page, tab, chosen);

    page.fillRect(0, bottom_top, page.width, screen_height - bottom_top, 0xff);
    page.fillRect(0, bottom_top, page.width, 4, 0x00);
    icons.skip(page, 110, bottom_top + 46, false);
    icons.skip(page, w - 110, bottom_top + 46, true);
    try drawScrub(fonts, page, index, total, false);
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
    try std.testing.expectEqual(@as(usize, 0), pageAt(0, 280));
    try std.testing.expectEqual(@as(usize, 279), pageAt(1272, 280));
    try std.testing.expectEqual(@as(usize, 140), pageAt(636, 280));
    try std.testing.expectEqual(@as(usize, 0), pageAt(600, 1));
}

test "chapter skipping" {
    const sections = [_]u32{ 1, 1, 2, 2, 2, 3, 3 };
    try std.testing.expectEqual(@as(usize, 2), chapterTarget(&sections, 0, true));
    try std.testing.expectEqual(@as(usize, 5), chapterTarget(&sections, 3, true));
    try std.testing.expectEqual(@as(usize, 6), chapterTarget(&sections, 6, true));
    try std.testing.expectEqual(@as(usize, 2), chapterTarget(&sections, 4, false)); // Start of this one
    try std.testing.expectEqual(@as(usize, 0), chapterTarget(&sections, 2, false)); // Then the one before
    try std.testing.expectEqual(@as(usize, 0), chapterTarget(&sections, 0, false));
}
