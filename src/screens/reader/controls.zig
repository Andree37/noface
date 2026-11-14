//! The reading toolbar and its Aa sheet.
const std = @import("std");
const autostart = @import("../../kindle/autostart.zig");
const card = @import("../../ui/card.zig");
const aa = @import("../../ui/aa.zig");
const toolbar = @import("../../ui/toolbar.zig");
const app = @import("../../app.zig");
const sess = @import("session.zig");
const lock = @import("../lock.zig");

/// Draws the toolbar over the current page.
pub fn drawToolbar(a: *app.App, s: *sess.Session, title: []const u8, sheet: bool, whole_page: bool) !void {
    @memcpy(a.overlay, try s.ensure(s.current, s.current));
    const total = if (s.layoutPending()) 0 else s.pages.len; // No page count until it's known
    var fonts = a.ui;
    if (sheet and a.tab == .font) fonts.families = a.familySamples();
    try toolbar.render(fonts, a.page(a.overlay), title, s.current, total, &a.quick, if (sheet) a.tab else null, a.settings, s.isBookmarked(s.current));
    @memcpy(a.screen.pixels, a.overlay);
    if (whole_page) {
        try a.showBand(0, a.screen.height);
        return;
    }
    // The tallest sheet's reach: switching from More to a shorter tab uncovers the page
    const top: u32 = if (sheet) aa.max_height else toolbar.top_height;
    const first = try a.screen.showRegion(0, 0, a.screen.width, top, .page);
    try a.showBand(toolbar.bottom_top, a.screen.height - toolbar.bottom_top);
    try a.screen.waitComplete(first);
}

pub fn closeToolbar(a: *app.App, s: *sess.Session, sheet: bool) !void {
    @memcpy(a.screen.pixels, try s.ensure(s.current, s.current));
    const top: u32 = if (sheet) aa.max_height else toolbar.top_height;
    const first = try a.screen.showRegion(0, 0, a.screen.width, top, .page);
    try a.showBand(toolbar.bottom_top, a.screen.height - toolbar.bottom_top);
    try a.screen.waitComplete(first);
}

/// Follows a finger along the page scrubber, then jumps there.
pub fn dragScrub(a: *app.App, s: *sess.Session, title: []const u8, sheet: bool, first_x: i32) !void {
    a.input.beginDrag();
    const band = a.screen.height - toolbar.scrub_top;
    const Follow = struct {
        a: *app.App,
        pages: usize,
        band: u32,
        target: *usize,
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            const next = toolbar.pageAt(x, f.pages);
            if (next == f.target.*) return null;
            f.target.* = next;
            try toolbar.drawScrub(f.a.ui, f.a.page(f.a.screen.pixels), next, f.pages, true);
            return try f.a.screen.showRegion(0, toolbar.scrub_top, f.a.screen.width, f.band, .quick);
        }
    };
    var target = toolbar.pageAt(first_x, s.pages.len);
    try toolbar.drawScrub(a.ui, a.page(a.screen.pixels), target, s.pages.len, true);
    const first = try a.screen.showRegion(0, toolbar.scrub_top, a.screen.width, band, .quick);
    _ = try app.followDrag(a, first, Follow{ .a = a, .pages = s.pages.len, .band = band, .target = &target });
    s.setPage(target);
    try drawToolbar(a, s, title, sheet, true);
    try app.cleanBand(a, toolbar.scrub_top, band);
}

pub fn rowSetting(a: *app.App, row: aa.Row) *usize {
    return switch (row.hit) {
        .text_size => &a.settings.size,
        .spacing => &a.settings.spacing,
        else => &a.settings.margin,
    };
}

/// Follows a finger along an Aa slider, and applies it when lifted.
pub fn dragSetting(a: *app.App, alloc: std.mem.Allocator, s: *sess.Session, title: []const u8, row: aa.Row, first_x: i32) !void {
    var value = aa.stepAt(row, first_x);
    const started = rowSetting(a, row).*;
    a.input.beginDrag();
    try aa.drawRow(a.ui, a.page(a.screen.pixels), row, value, true);
    const first = try a.screen.showRegion(0, row.top, a.screen.width, aa.row_height, .quick);
    const Follow = struct {
        a: *app.App,
        row: aa.Row,
        value: *usize,
        pub fn moved(f: @This(), x: i32, _: i32) !?u32 {
            const next = aa.stepAt(f.row, x);
            if (next == f.value.*) return null;
            f.value.* = next;
            try aa.drawRow(f.a.ui, f.a.page(f.a.screen.pixels), f.row, next, true);
            return try f.a.screen.showRegion(0, f.row.top, f.a.screen.width, aa.row_height, .quick);
        }
    };
    _ = try app.followDrag(a, first, Follow{ .a = a, .row = row, .value = &value });
    if (value != started) {
        rowSetting(a, row).* = value;
        try sess.relayout(a, alloc, s);
    }
    try drawToolbar(a, s, title, true, true);
    try app.cleanBand(a, row.top, aa.row_height);
}

/// Whether a switch with this guard may turn on: asks, or says what's missing, first.
/// False when it may not; the sheet is drawn again either way.
fn ready(a: *app.App, s: *sess.Session, title: []const u8, guard: aa.Guard) !bool {
    switch (guard) {
        .none => return true,
        .autostart => {
            // Turning it on needs the startup file in the system folder: ask first
            if (autostart.installed()) return true;
            const page = try s.ensure(s.current, s.current);
            const rows = [_]card.Row{.{ .label = "Turn on" }};
            const agreed = try app.chooseFromCard(a, page, "Open noface when the Kindle starts", "This adds one small startup file to the Kindle's system.", &rows) != null;
            if (!agreed) {
                try drawToolbar(a, s, title, true, false);
                return false;
            }
            if (autostart.install()) return true;
            try drawToolbar(a, s, title, true, false);
            try app.showNotice(a, "Couldn't set up starting with the Kindle.");
            return false;
        },
        .lock_picture => {
            // Turning it on needs a picture to show
            if (lock.hasPicture(a)) return true;
            const page = try s.ensure(s.current, s.current);
            const rows = [_]card.Row{.{ .label = "OK" }};
            _ = try app.chooseFromCard(a, page, "Add your picture first", "Name it lockscreen.jpg or lockscreen.png, and put it in the noface-data folder.", &rows);
            try drawToolbar(a, s, title, true, false);
            return false;
        },
    }
}

/// Handles a tap inside the Aa sheet.
pub fn tapSheet(a: *app.App, alloc: std.mem.Allocator, s: *sess.Session, title: []const u8, x: i32, y: i32) !void {
    switch (aa.hit(a.tab, x, y)) {
        .none => return,
        .tab => |tab| {
            a.tab = tab;
            return drawToolbar(a, s, title, true, false);
        },
        .text_size => return dragSetting(a, alloc, s, title, aa.size_row, x),
        .spacing => return dragSetting(a, alloc, s, title, aa.spacing_row, x),
        .margins => return dragSetting(a, alloc, s, title, aa.margin_row, x),
        .theme => |i| {
            const t = aa.themes[i];
            a.settings.size = t.size;
            a.settings.spacing = t.spacing;
            a.settings.margin = t.margin;
        },
        .family => |i| a.settings.font = i,
        .toggle => |i| {
            const sw = aa.switches[i];
            const turning_on = !aa.isOn(i, a.settings);
            if (turning_on and !try ready(a, s, title, sw.guard)) return;
            aa.flip(i, &a.settings);
            switch (sw.effect) {
                .relayout => {}, // Below
                .footer, .nothing => {
                    app.saveSettings(a.settings_path, a.settings);
                    if (sw.effect == .footer) a.forgetPages(); // The footer is drawn into each page
                    return drawToolbar(a, s, title, true, false);
                },
            }
        },
    }
    try sess.relayout(a, alloc, s);
    try drawToolbar(a, s, title, true, true);
}
