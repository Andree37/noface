//! Getting a dictionary that isn't on the Kindle: asked the first time a word is held
//! in a book whose dictionary is missing, or from "Get dictionary" on the sheet. It
//! downloads over Wi-Fi, showing how far it's got, and can be cancelled.
const std = @import("std");
const input_mod = @import("../../kindle/input.zig");
const app = @import("../../app.zig");
const card = @import("../../ui/card.zig");
const hyphen = @import("../../layout/hyphen.zig");
const lipc = @import("../../kindle/lipc.zig");
const wifi_saver = @import("../../kindle/wifi_saver.zig");
const dict_download = @import("../../kindle/dict_download.zig");
const os = @import("../../sys/os.zig");

/// The download for a book's language.
pub fn languageOf(lang: hyphen.Lang) dict_download.Language {
    return switch (lang) {
        .english => .{ .file = "dict-en", .name = "English", .download_mb = 27, .size_mb = 94 },
        .portuguese => .{ .file = "dict-pt", .name = "Portuguese", .download_mb = 6, .size_mb = 38 },
    };
}

pub const Answer = enum { download, not_now, dismissed };

/// The first time: whether to download it. "Not now" stops the asking; the sheet
/// still offers it.
pub fn ask(a: *app.App, background: []const u8, lang: hyphen.Lang) !Answer {
    const l = languageOf(lang);
    var title_buf: [64]u8 = undefined;
    var sub_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Get the {s} dictionary?", .{l.name}) catch "";
    const subtitle = std.fmt.bufPrint(&sub_buf, "A {d} MB download over Wi-Fi, {d} MB on the Kindle. Definitions from Wiktionary.", .{ l.download_mb, l.size_mb }) catch "";
    const rows = [_]card.Row{ .{ .label = "Download" }, .{ .label = "Not now" } };
    const picked = try app.chooseFromCard(a, background, title, subtitle, &rows) orelse return .dismissed;
    if (picked == 0) return .download;
    // Only "Not now" itself stops the asking; a tap beside the card, or locking, doesn't
    a.settings.offer_dictionary = false;
    app.saveSettings(a.settings_path, a.settings);
    return .not_now;
}

/// Downloads it, over `background`. True when it's in place and ready to use.
pub fn get(a: *app.App, background: []const u8, lang: hyphen.Lang) !bool {
    const l = languageOf(lang);
    // The reader's own airplane mode is theirs to turn off; noface's own pause it undoes
    const ours = wifi_saver.marked();
    if (lipc.airplaneOn() == true and !ours) {
        try tell(a, background, "Airplane mode is on", "Turn it off in the light panel, then try again.");
        return false;
    }
    if (ours) wifi_saver.restore();
    // Kept on until it's done, then back to whatever else was keeping it on
    const downloads_until = a.downloads_until;
    a.downloads_until = os.nowUs() + 15 * 60 * 1_000_000;
    defer a.downloads_until = downloads_until;
    defer if (ours) {
        _ = wifi_saver.pause(false); // Off again for reading
    };

    // Up to half a minute to connect, then the download, each shown on the card
    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Getting the {s} dictionary", .{l.name}) catch "";
    const rows = [_]card.Row{.{ .label = "Cancel" }};
    const connect_until = os.nowUs() + 30 * 1_000_000;
    while (lipc.wifiConnected() != true) {
        if (os.nowUs() >= connect_until) {
            try tell(a, background, "No Wi-Fi connection", "Connect to Wi-Fi and try again, or copy the dictionary over USB (see noface's release page).");
            return false;
        }
        if (try showProgress(a, background, title, "Connecting to Wi-Fi\u{2026}", &rows)) return false;
    }
    var download = dict_download.start(a.state_dir, a.dictionary_base, l) orelse {
        try tell(a, background, "Couldn't start the download", "Try again in a moment.");
        return false;
    };
    const ok = while (true) {
        if (download.done()) |finished| break finished;
        var sub_buf: [64]u8 = undefined;
        const subtitle = std.fmt.bufPrint(&sub_buf, "{d} MB of about {d}", .{ download.megabytes(), l.download_mb }) catch "";
        if (try showProgress(a, background, title, subtitle, &rows)) {
            download.cancel();
            std.debug.print("dictionary download cancelled\n", .{});
            return false;
        }
    };
    std.debug.print("dictionary {s} downloaded: {}\n", .{ l.file, ok });
    if (!ok) {
        try tell(a, background, "The download didn't finish", "Check the Wi-Fi and try again.");
        return false;
    }
    a.forgetDictionary(lang);
    return a.dictionaryFor(lang) != null;
}

/// Shows the card for about a second. True when Cancel was tapped.
fn showProgress(a: *app.App, background: []const u8, title: []const u8, subtitle: []const u8, rows: []const card.Row) !bool {
    @memcpy(a.overlay, background);
    try card.renderWith(a.ui, a.page(a.overlay), title, subtitle, rows, null);
    @memcpy(a.screen.pixels, a.overlay);
    try a.showBand(0, a.screen.height);
    const was = a.input.use(input_mod.Input.Modes.sheet);
    defer a.input.restore(was);
    const tick = a.input.tick_us;
    defer a.input.tick_us = tick;
    a.input.tick_us = 1_000_000; // Back to the caller in a second, to show progress
    a.input.last_tick = os.nowUs();
    while (a.input.nextFor()) |action| switch (action) {
        .tick => return false,
        .tap => |t| if (card.hitWith(t.x, t.y, rows.len, null) == 0) return true, // Cancel
        else => {},
    };
    return true; // Locked, or leaving: stop the download
}

fn tell(a: *app.App, background: []const u8, title: []const u8, subtitle: []const u8) !void {
    const rows = [_]card.Row{.{ .label = "OK" }};
    _ = try app.chooseFromCard(a, background, title, subtitle, &rows);
}
