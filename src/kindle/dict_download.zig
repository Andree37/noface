//! Fetching a dictionary from noface's GitHub release, in the background: curl into a
//! partial file, unzip into a folder of its own, then the file moved into place, so a
//! download cut short never leaves a broken dictionary where noface looks.
const std = @import("std");
const process = @import("../sys/process.zig");
const file = @import("../sys/file.zig");
const linux = @import("../sys/calls.zig");

/// Where the release keeps them; NOFACE_DICT_URL replaces it, to test against a
/// computer on the USB link.
pub const default_base = "https://github.com/Andree37/noface/releases/download/dictionaries";

/// A dictionary's file name and how big it is, for the question and the progress.
pub const Language = struct { file: []const u8, name: []const u8, download_mb: u32, size_mb: u32 };

pub const Download = struct {
    pid: i32,
    part: [320]u8 = undefined,
    part_len: usize = 0,

    /// Megabytes downloaded so far.
    pub fn megabytes(d: *const Download) u64 {
        var buf: [321]u8 = undefined;
        @memcpy(buf[0..d.part_len], d.part[0..d.part_len]);
        buf[d.part_len] = 0;
        return file.size_of(@ptrCast(&buf)) / (1024 * 1024);
    }

    /// Null while it runs, then whether the dictionary is in place.
    pub fn done(d: *const Download) ?bool {
        return process.exited(d.pid);
    }

    pub fn cancel(d: *const Download) void {
        process.stop(d.pid);
    }
};

/// Starts fetching `lang` into `data_dir`. Null when it couldn't start.
pub fn start(data_dir: []const u8, base: []const u8, lang: Language) ?Download {
    var d = Download{ .pid = 0 };
    const part = std.fmt.bufPrint(&d.part, "{s}/{s}.zip.part", .{ data_dir, lang.file }) catch return null;
    d.part_len = part.len;
    var script_buf: [1024]u8 = undefined;
    // The zip holds the dictionary and its license, both kept beside each other
    const script = std.fmt.bufPrintSentinel(&script_buf,
        \\set -e
        \\cd '{s}'
        \\rm -rf .dict-new '{s}.zip.part'
        \\curl -fsSL --retry 2 --connect-timeout 20 -o '{s}.zip.part' '{s}/{s}.zip'
        \\mkdir .dict-new
        \\unzip -o -q '{s}.zip.part' -d .dict-new
        \\test -s '.dict-new/{s}'
        \\mv -f '.dict-new/{s}' '{s}'
        \\mv -f '.dict-new/{s}-LICENSE.txt' '{s}-LICENSE.txt' 2>/dev/null || true
        \\rm -rf .dict-new '{s}.zip.part'
    , .{ data_dir, lang.file, lang.file, base, lang.file, lang.file, lang.file, lang.file, lang.file, lang.file, lang.file, lang.file }, 0) catch return null;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
    const child = process.spawn(&argv) orelse return null;
    _ = linux.close(child.out); // It prints nothing
    d.pid = child.pid;
    return d;
}
