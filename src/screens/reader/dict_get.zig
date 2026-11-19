//! Getting a dictionary that isn't on the Kindle: asked the first time a word is held
//! in a book whose dictionary is missing, or from "Get dictionary" on the sheet. It
//! downloads over Wi-Fi, showing how far it's got, and can be cancelled.
const std = @import("std");
const assert = std.debug.assert;
const card_screen = @import("../card.zig");
const input_mod = @import("../../kindle/input.zig");
const app = @import("../../app.zig");
const card = @import("../../ui/card.zig");
const hyphen = @import("../../layout/hyphen.zig");
const lipc = @import("../../kindle/lipc.zig");
const wifi_saver = @import("../../kindle/wifi_saver.zig");
const dict_download = @import("../../kindle/dict_download.zig");
const os = @import("../../sys/os.zig");
const screen = @import("../screen.zig");

/// How long the Kindle is kept awake for a download.
const awake_us_max = 15 * 60 * 1_000_000;
/// How long to wait for Wi-Fi to connect before giving up.
const connect_us_max = 30 * 1_000_000;

comptime {
    // Connecting is part of the download, so the Kindle stays awake through it
    assert(connect_us_max < awake_us_max);
    assert(connect_us_max + dict_download.download_s_max * 1_000_000 < awake_us_max);
    // The card shows how far it's got every second, many times before the deadline
    assert(Progress.tick_us == 1_000_000);
    // The card shows the wait at least once before giving up
    assert(Progress.tick_us < connect_us_max);
}

/// The download for a book's language.
pub fn language_of(lang: hyphen.Lang) dict_download.Language {
    const language: dict_download.Language = switch (lang) {
        .english => .{ .file = "dict-en", .name = "English", .download_mb = 27, .size_mb = 94 },
        .portuguese => .{
            .file = "dict-pt",
            .name = "Portuguese",
            .download_mb = 6,
            .size_mb = 38,
        },
    };
    // Compressed for the download, so smaller than on the Kindle
    assert(language.download_mb > 0);
    assert(language.download_mb < language.size_mb);
    return language;
}

pub const Answer = enum { download, not_now, dismissed };

/// The first time, the card asking whether to download it, to open over `background`
/// (`screen.open`), its text in `ask`. Once it has ended, `asked` says the answer.
pub fn ask(
    a: *app.App,
    background: app.Backdrop,
    lang: hyphen.Lang,
    asking: *Asking,
) card_screen.Card {
    assert(background.holds(a));
    const l = language_of(lang);
    const title = std.fmt.bufPrint(&asking.title_buffer, "Get the {s} dictionary?", .{
        l.name,
    }) catch "";
    const subtitle = std.fmt.bufPrint(
        &asking.subtitle_buffer,
        "A {d} MB download over Wi-Fi, {d} MB on the Kindle. Definitions from Wiktionary.",
        .{ l.download_mb, l.size_mb },
    ) catch "";
    assert(title.len > 0);
    return card_screen.over(a, background, title, subtitle, &ask_rows, null);
}

/// The answer to the card from `ask`, which has ended. "Not now" stops the asking; the
/// sheet still offers it.
pub fn asked(a: *app.App, background: app.Backdrop, ending: screen.Ending(u32)) !Answer {
    assert(background.holds(a));
    try card_screen.closed(a, background);
    const picked = switch (ending) {
        .done => |picked| picked,
        .closed, .interrupted => return .dismissed,
    };
    assert(picked < ask_rows.len);
    if (picked == 0) return .download;
    // Only "Not now" itself stops the asking; a tap beside the card, or locking, doesn't
    a.settings.offer_dictionary = false;
    a.save_settings();
    return .not_now;
}

const ask_rows = [_]card.Row{ .{ .label = "Download" }, .{ .label = "Not now" } };

/// What `ask`'s card says, kept while it's open.
pub const Asking = struct {
    title_buffer: [64]u8 = undefined,
    subtitle_buffer: [128]u8 = undefined,
};

/// Starts getting the dictionary for `lang` in `g`, where it stays while it's open
/// (`screen.open`), over `background`: a card saying how far it's got, connecting and
/// then downloading, which Cancel stops, and a card saying what went wrong if it did.
/// Done with true when the dictionary is in place and ready to use.
pub fn begin(g: *Getting, a: *app.App, background: app.Backdrop, lang: hyphen.Lang) void {
    assert(background.holds(a));
    g.* = .{ .a = a, .background = background, .lang = lang, .l = language_of(lang) };
    assert(g.phase == .starting);
    assert(g.put_back == null);
}

pub const Getting = struct {
    pub const Result = bool; // In place and ready
    a: *app.App,
    background: app.Backdrop,
    lang: hyphen.Lang,
    l: dict_download.Language,
    phase: enum { starting, waiting, telling } = .starting,
    /// Once Wi-Fi is turned on for it and the Kindle kept awake, how to put both back
    /// as it ends.
    put_back: ?PutBack = null,
    progress: Progress = undefined,
    progress_ending: ?screen.Ending(Waited) = null,
    told: card_screen.Card = undefined,
    told_ending: ?screen.Ending(u32) = null,

    /// What getting a dictionary changed, to undo: Wi-Fi turned back on from noface's
    /// own pause (off again after, by the book's own Wi-Fi timer), and what kept the
    /// Kindle awake before.
    const PutBack = struct { wifi_paused: bool, downloads_until: u64 };

    /// Never shown itself: its cards are.
    pub fn draw(g: *Getting, part: screen.Part) !void {
        assert(part == .all);
        assert(g.phase == .starting);
    }

    pub fn on_tap(g: *Getting, _: screen.Tap) !screen.Step(bool) {
        assert(g.phase == .starting);
        unreachable; // Never in front: one of its cards always is
    }

    /// Up to half a minute to connect, then the download, each shown on the card.
    pub fn on_open(g: *Getting) !screen.Step(bool) {
        const a = g.a;
        assert(g.phase == .starting);
        assert(g.background.holds(a));
        // The reader's own airplane mode is theirs to turn off. Unknown: tried, and the
        // connection's wait says if Wi-Fi came
        switch (wifi_saver.airplane()) {
            .reader => return g.tell(
                "Airplane mode is on",
                "Turn it off in the light panel, then try again.",
            ),
            .noface, .off, .unknown => {},
        }
        // The pause noface made, known by its note whatever the Kindle answered, is undone
        const paused = wifi_saver.marked();
        if (paused) wifi_saver.restore();
        // Kept on until it's done, then back to whatever else was keeping it on
        g.put_back = .{ .wifi_paused = paused, .downloads_until = a.downloads_until };
        a.downloads_until = os.now_us() + awake_us_max;
        g.phase = .waiting;
        var title_buffer: [64]u8 = undefined;
        const title_format = "Getting the {s} dictionary";
        const title = std.fmt.bufPrint(&title_buffer, title_format, .{g.l.name}) catch "";
        g.progress = .{
            .a = a,
            .background = g.background,
            .l = g.l,
            .title_buffer = title_buffer,
            .title_size = @intCast(title.len),
            .connect_until = os.now_us() + connect_us_max,
        };
        // No answer: not yet, and the card asks again each second
        if (lipc.wifi_connected() orelse false) {
            if (!g.progress.start()) return g.cant_start();
        }
        return .{ .push = screen.open(&g.progress, &g.progress_ending) };
    }

    pub fn on_resume(g: *Getting) !screen.Step(bool) {
        assert(g.background.holds(g.a)); // What its cards sit over
        switch (g.phase) {
            .starting => unreachable, // Nothing is open before it starts
            .waiting => {
                const waited: Waited = switch (g.progress_ending.?) {
                    .done => |waited| waited,
                    // Locked, or leaving: stopped, as Cancel does
                    .closed, .interrupted => .cancelled,
                };
                if (waited == .cancelled) g.progress.cancel();
                std.debug.print("dictionary {s} download: {s}\n", .{ g.l.file, @tagName(waited) });
                return g.after_waiting(waited);
            },
            .telling => {
                try card_screen.closed(g.a, g.background);
                return g.finish(false);
            },
        }
    }

    fn after_waiting(g: *Getting, w: Waited) screen.Step(bool) {
        assert(g.phase == .waiting);
        assert(g.put_back != null); // Waiting has Wi-Fi on for it
        return switch (w) {
            .finished => {
                g.a.forget_dictionary(g.lang);
                return g.finish(g.a.dictionary_for(g.lang) != null);
            },
            .cancelled => g.finish(false),
            .cant_start => g.cant_start(),
            .no_wifi => g.tell(
                "No Wi-Fi connection",
                "Connect to Wi-Fi and try again, or copy the dictionary over USB " ++
                    "(see noface's release page).",
            ),
            .failed => g.tell("The download didn't finish", "Check the Wi-Fi and try again."),
            .too_long => g.tell(
                "The download took too long",
                "The Wi-Fi may be too slow. Try again somewhere faster.",
            ),
        };
    }

    fn cant_start(g: *Getting) screen.Step(bool) {
        assert(g.put_back != null);
        assert(g.phase == .waiting);
        return g.tell("Couldn't start the download", "Try again in a moment.");
    }

    /// A card saying what went wrong, with OK.
    fn tell(g: *Getting, title: []const u8, subtitle: []const u8) screen.Step(bool) {
        assert(title.len > 0);
        assert(g.phase != .telling);
        g.phase = .telling;
        g.told = card_screen.over(g.a, g.background, title, subtitle, &ok_rows, null);
        return .{ .push = screen.open(&g.told, &g.told_ending) };
    }

    /// Done: Wi-Fi and the Kindle's waking put back as they were.
    fn finish(g: *Getting, ready: bool) screen.Step(bool) {
        assert(g.phase != .starting); // Something it opened has ended
        assert(g.background.holds(g.a));
        if (g.put_back) |back| {
            g.a.downloads_until = back.downloads_until;
            // Off again for reading, by the book's timer, which tries again until it can
            if (back.wifi_paused) g.a.wifi_off_at = os.now_us();
        }
        return .{ .done = ready };
    }
};

const ok_rows = [_]card.Row{.{ .label = "OK" }};
const cancel_rows = [_]card.Row{.{ .label = "Cancel" }};

/// How waiting for a download ended.
const Waited = enum { finished, failed, cancelled, too_long, no_wifi, cant_start };

/// The download's card, how far it's got in its subtitle: connecting, then the
/// megabytes downloaded, looked at again every second. Cancel is its only row. It
/// ends when the download does, when Wi-Fi doesn't connect in time, or when the
/// download runs past `download_s_max`, when it's stopped.
const Progress = struct {
    pub const Result = Waited;
    pub const touches = input_mod.Input.Modes.sheet;
    pub const tick_us = 1_000_000;
    a: *app.App,
    background: app.Backdrop,
    l: dict_download.Language,
    title_buffer: [64]u8,
    title_size: u32,
    connect_until: u64,
    /// Once started, the download and when it's given up on.
    running: ?struct { download: dict_download.Download, deadline_us: u64 } = null,
    subtitle_buffer: [64]u8 = undefined,

    pub fn draw(p: *Progress, _: screen.Part) !void {
        const a = p.a;
        assert(p.background.holds(a));
        const title = p.title_buffer[0..p.title_size];
        const page = a.compose(p.background);
        try card.render_with(a.ui, page, title, p.subtitle(), &cancel_rows, null);
        a.put_composed();
        try a.show_band(0, a.screen.height);
    }

    fn subtitle(p: *Progress) []const u8 {
        const r = p.running orelse return "Connecting to Wi-Fi\u{2026}";
        const d = r.download;
        assert(d.pid > 0);
        assert(r.deadline_us > 0); // Set as it started
        return std.fmt.bufPrint(
            &p.subtitle_buffer,
            "{d} MB of about {d}",
            .{ d.megabytes(), p.l.download_mb },
        ) catch "";
    }

    pub fn on_tap(p: *Progress, t: screen.Tap) !screen.Step(Waited) {
        assert(std.mem.eql(u8, cancel_rows[0].label, "Cancel"));
        assert(p.title_size > 0);
        const rows: u32 = cancel_rows.len;
        assert(rows == 1);
        return if (card.hit_with(t.x, t.y, rows, null) == 0) .{ .done = .cancelled } else .stay;
    }

    /// Every second: connected yet, or the download further along, or over.
    pub fn on_tick(p: *Progress) !screen.Step(Waited) {
        const now = os.now_us();
        assert(p.connect_until > 0);
        assert(p.background.holds(p.a)); // What its card is drawn over
        const r = p.running orelse {
            // No answer: not yet, asked again next second until `connect_until`
            if (lipc.wifi_connected() orelse false) {
                if (!p.start()) return .{ .done = .cant_start };
            } else if (now >= p.connect_until) {
                return .{ .done = .no_wifi };
            }
            return .{ .redraw = .all };
        };
        if (r.download.done()) |ok| return .{ .done = if (ok) .finished else .failed };
        if (now >= r.deadline_us) {
            r.download.cancel();
            return .{ .done = .too_long };
        }
        return .{ .redraw = .all };
    }

    /// Starts the download. False when it couldn't.
    fn start(p: *Progress) bool {
        assert(p.running == null);
        const a = p.a;
        const d = dict_download.start(a.state_dir, a.dictionary_base, p.l) orelse return false;
        const download_us = @as(u64, dict_download.download_s_max) * 1_000_000;
        p.running = .{ .download = d, .deadline_us = os.now_us() + download_us };
        assert(d.pid > 0);
        return true;
    }

    /// Stops the download, if it started.
    fn cancel(p: *const Progress) void {
        const r = p.running orelse return;
        assert(r.download.pid > 0);
        assert(r.deadline_us > 0); // Set as it started
        r.download.cancel();
    }
};
