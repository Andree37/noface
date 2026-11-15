//! Fetching a dictionary from noface's GitHub release, in the background: curl into a
//! partial file, unzip into a folder of its own, then the file moved into place, so a
//! download cut short never leaves a broken dictionary where noface looks.
const std = @import("std");
const assert = std.debug.assert;
const process = @import("../sys/process.zig");
const file = @import("../sys/file.zig");
const linux = @import("../sys/calls.zig");

/// Where the release keeps them; NOFACE_DICT_URL replaces it, to test against a
/// computer on the USB link.
pub const default_base = "https://github.com/Andree37/noface/releases/download/dictionaries";

/// A dictionary's file name and how big it is, for the question and the progress.
pub const Language = struct {
    file: []const u8,
    name: []const u8,
    download_mb: u32,
    size_mb: u32,
};

const part_size_max = 320;

/// The longest one try of curl's may take, connecting included: 27 MB in this time is
/// about 40 KB a second, slower than any Wi-Fi worth downloading on. A retry starts
/// its own clock, so the reader's side (`download_s_max`) is what bounds the whole.
pub const curl_s_max = 12 * 60;
/// The longest unzipping and moving the file into place may take after it, on the
/// Kindle's slow drive: the biggest dictionary is under 100 MB.
pub const unpack_s_max = 2 * 60;
/// The longest a download may take, from start to the dictionary in place.
pub const download_s_max = curl_s_max + unpack_s_max;

comptime {
    assert(curl_s_max > 0);
    assert(unpack_s_max > 0);
    assert(download_s_max > curl_s_max);
}

pub const Download = struct {
    pid: i32,
    part: [part_size_max]u8 = undefined,
    part_size: u32 = 0,

    /// Megabytes downloaded so far.
    pub fn megabytes(d: *const Download) u64 {
        assert(d.part_size > 0);
        assert(d.part_size <= part_size_max);
        var path: [part_size_max + 1]u8 = undefined;
        @memcpy(path[0..d.part_size], d.part[0..d.part_size]);
        path[d.part_size] = 0;
        return @divFloor(file.size_of(path[0..d.part_size :0]), 1024 * 1024);
    }

    /// Null while it runs, then whether the dictionary is in place.
    pub fn done(d: *const Download) ?bool {
        assert(d.pid > 0);
        assert(d.part_size > 0);
        return process.exited(d.pid);
    }

    pub fn cancel(d: *const Download) void {
        assert(d.pid > 0);
        assert(d.part_size > 0);
        process.stop(d.pid);
    }
};

/// The steps, each stopping the script if it fails. The zip holds the dictionary and
/// its license, both kept beside each other.
const script_format =
    \\set -e
    \\cd '{[data_dir]s}'
    \\rm -rf .dict-new '{[file]s}.zip.part'
    \\curl -fsSL --retry 2 --connect-timeout 20 --max-time {[curl_s_max]d} \
    \\  -o '{[file]s}.zip.part' '{[base]s}/{[file]s}.zip'
    \\mkdir .dict-new
    \\unzip -o -q '{[file]s}.zip.part' -d .dict-new
    \\test -s '.dict-new/{[file]s}'
    \\mv -f '.dict-new/{[file]s}' '{[file]s}'
    \\mv -f '.dict-new/{[file]s}-LICENSE.txt' '{[file]s}-LICENSE.txt' 2>/dev/null || true
    \\rm -rf .dict-new '{[file]s}.zip.part'
;

/// Starts fetching `lang` into `data_dir`. Null when it couldn't start.
pub fn start(data_dir: []const u8, base: []const u8, lang: Language) ?Download {
    assert(lang.file.len > 0);
    assert(data_dir.len > 0);
    var d = Download{ .pid = 0 };
    const part_format = "{s}/{s}.zip.part";
    const part = std.fmt.bufPrint(&d.part, part_format, .{ data_dir, lang.file }) catch return null;
    d.part_size = @intCast(part.len);
    var script_buf: [1024]u8 = undefined;
    const script = std.fmt.bufPrintSentinel(&script_buf, script_format, .{
        .data_dir = data_dir,
        .file = lang.file,
        .base = base,
        .curl_s_max = curl_s_max,
    }, 0) catch return null;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script };
    const child = process.spawn(&argv) orelse return null;
    // It prints nothing, so its output is closed unread.
    _ = linux.close(child.out);
    d.pid = child.pid;
    assert(d.pid > 0);
    assert(d.part_size > 0);
    return d;
}
