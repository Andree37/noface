//! Every place on the Kindle noface reads or writes, in one list, for the app and its
//! launcher alike. The two files that start the launcher, KPM's launch.sh and the
//! startup file, name it too; a test below checks they agree.
//!
//! The app sits in `app_dir`, which an update replaces whole. What the reader keeps
//! (settings, places, stats, notes, dictionaries) sits in `data_dir`, which no update
//! touches. Scratch files go in /tmp, which is in RAM and empty after a reboot.
const std = @import("std");
const assert = std.debug.assert;

/// The app: the program, its launcher and helpers. Replaced whole by an update.
pub const app_dir = "/mnt/us/noface";
/// What the reader keeps. The app is told this folder when started (src/launch.zig).
pub const data_dir = "/mnt/us/noface-data";
/// The Kindle's books, and EPUBs copied over USB.
pub const documents = "/mnt/us/documents";
/// Typefaces the reader adds.
pub const own_fonts = "/mnt/us/fonts";
/// The variable naming a test run's books (`noface-launch e2e`): set only for a run on
/// a test folder, never the reader's own.
pub const test_documents_env = "NOFACE_DOCUMENTS";

/// The app itself.
pub const reader = app_dir ++ "/noface";
/// What the reader is started with after its own name, by position: what src/main.zig
/// reads and the launcher (supervisor.zig) gives. Its fonts it knows (fonts.zig).
pub const ReaderArg = enum(u8) { library = 1, data = 2 };
/// The reader's whole command line: its own name, then each `ReaderArg`.
pub const reader_args_count = 1 + @typeInfo(ReaderArg).@"enum".field_names.len;

comptime {
    // Positions 1 to N, each once: argv's own after the program's name
    for (std.enums.values(ReaderArg), 1..) |arg, position| assert(@backingInt(arg) == position);
}
/// Starts the app, puts the Kindle's own screens back after it, starts it at boot and
/// writes the book list for the library (src/launch.zig).
pub const launcher = app_dir ++ "/noface-launch";
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
    /// The book list, from the Kindle's catalog.
    pub const library = "library.tsv";
    /// What noface prints, and the copy kept from before it last grew too large.
    pub const log = "noface.log";
    pub const log_old = "noface.log.old";
    /// What the launcher prints.
    pub const launch_log = "launch.log";
    /// Boots in a row that started noface without it running a minute.
    pub const boot_attempts = "boot-attempts";
};

/// The Kindle's own typefaces, which noface sets its text in.
pub const kindle_fonts = "/usr/java/lib/fonts";
/// The Kindle's Chinese typeface: a serif, as the reading fonts mostly are.
pub const fallback_font = kindle_fonts ++ "/STSongMedium.ttf";
/// Amazon's catalog of books, and the copy read so Amazon's own is never held open.
pub const catalog = "/var/local/cc.db";
pub const catalog_copy = "/tmp/kf-cc.db";
/// There once the launcher has looked at starting noface this boot (/tmp is in RAM).
pub const autostart_ran = "/tmp/noface-autostart-ran";

/// Refreshed every 30 s while noface's loop runs; the launcher's watchdog reads it.
pub const heartbeat = "/tmp/noface-alive";
/// While this exists, noface writes no notes to Amazon's database and asks no sync.
pub const dry_run = "/tmp/noface-dry-run";
/// Scratch: the SQL handed to sqlite3, and a picture handed to jxr2pgm.
pub const annotation_sql = "/tmp/noface-annotation.sql";
pub const jxr_input = "/tmp/noface-picture.jxr";

test "KPM's launch.sh and the startup file start the launcher named here" {
    const starters = [_][]const u8{ @embedFile("launch_sh"), @embedFile("autostart_conf") };
    for (starters) |starter| {
        if (std.mem.indexOf(u8, starter, launcher) == null) {
            std.debug.print("a starter doesn't name {s}:\n{s}\n", .{ launcher, starter });
            return error.TestExpectedEqual;
        }
    }
}
