//! Every place on the Kindle noface reads or writes, in one list. The shell scripts in
//! device/ keep the same names in device/data.sh; a test below checks they agree.
//!
//! The app sits in `app_dir`, which an update replaces whole. What the reader keeps
//! (settings, places, stats, notes, dictionaries) sits in `data_dir`, which no update
//! touches. Scratch files go in /tmp, which is in RAM and empty after a reboot.

/// The app: the program, its scripts and helpers. Replaced whole by an update.
pub const app_dir = "/mnt/us/noface";
/// What the reader keeps. The app is told this folder when started (noface.sh).
pub const data_dir = "/mnt/us/noface-data";
/// The Kindle's books, and EPUBs copied over USB.
pub const documents = "/mnt/us/documents";
/// Typefaces the reader adds.
pub const own_fonts = "/mnt/us/fonts";

/// Writes the book list for the library (device/export.sh).
pub const export_script = app_dir ++ "/export.sh";
/// Decodes a JPEG XR picture with the Kindle's own library.
pub const jxr_helper = app_dir ++ "/jxr2pgm";
/// The startup file shipped with the app, copied into /etc when autostart is on.
pub const autostart_conf = app_dir ++ "/noface-autostart.conf";

/// The names of what noface keeps in the data folder.
pub const data = struct {
    pub const settings = "settings";
    pub const speed = "speed";
    pub const journal = "journal";
    pub const battery = "battery";
    /// There while noface has Wi-Fi off for reading, so it's put back after a crash.
    pub const wifi_paused = "wifi-paused";
};

/// Refreshed every 30 s while noface's loop runs; noface.sh's watchdog reads it.
pub const heartbeat = "/tmp/noface-alive";
/// While this exists, noface writes no notes to Amazon's database and asks no sync.
pub const dry_run = "/tmp/noface-dry-run";
/// Scratch: the SQL handed to sqlite3, and a picture handed to jxr2pgm.
pub const annotation_sql = "/tmp/noface-annotation.sql";
pub const jxr_input = "/tmp/noface-picture.jxr";

const std = @import("std");

test "device/data.sh names the same places" {
    const script = @embedFile("data_sh");
    const expected = [_][]const u8{
        "APP=" ++ app_dir,
        "DATA=" ++ data_dir,
        "HEARTBEAT=" ++ heartbeat,
        "WIFI_PAUSED=$DATA/" ++ data.wifi_paused,
    };
    for (expected) |line| {
        if (std.mem.indexOf(u8, script, line) == null) {
            std.debug.print("device/data.sh is missing: {s}\n", .{line});
            return error.TestExpectedEqual;
        }
    }
}
