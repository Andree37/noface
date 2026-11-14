//! Opening noface when the Kindle starts needs one small file in the system's startup
//! folder, /etc/upstart. It ships in noface's folder; switching the setting on copies
//! it there (after the reader agrees), so nobody edits system files by hand. The file
//! only runs noface's autostart.sh, which does nothing while the setting is off, so
//! switching it off leaves the file in place, idle.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const process = @import("../sys/process.zig");
const state = @import("../sys/state.zig");

const shipped = paths.autostart_conf;
const installed_path = "/etc/upstart/noface-autostart.conf";
/// The startup file is a few lines: more than this is read as a different file.
const conf_size_max = 2048;

comptime {
    assert(shipped[0] == '/');
    assert(installed_path[0] == '/');
    assert(!std.mem.eql(u8, shipped, installed_path));
    assert(std.mem.endsWith(u8, shipped, ".conf"));
    assert(std.mem.endsWith(u8, installed_path, ".conf"));
}

/// Whether the system's copy is there and the same as the one noface ships.
pub fn installed() bool {
    var want_buffer: [conf_size_max]u8 = undefined;
    var have_buffer: [conf_size_max]u8 = undefined;
    const want = state.read_small(shipped, &want_buffer);
    const have = state.read_small(installed_path, &have_buffer);
    assert(want.len <= want_buffer.len);
    assert(have.len <= have_buffer.len);
    return want.len > 0 and std.mem.eql(u8, want, have);
}

/// Whether the system's copy is there but differs from the one noface ships: one from
/// an older version, which may run a script that no longer reads the settings. Not
/// when either is missing: a reader may have deleted the system's copy on purpose.
pub fn outdated() bool {
    var want_buffer: [conf_size_max]u8 = undefined;
    var have_buffer: [conf_size_max]u8 = undefined;
    const want = state.read_small(shipped, &want_buffer);
    const have = state.read_small(installed_path, &have_buffer);
    assert(want.len <= want_buffer.len);
    assert(have.len <= have_buffer.len);
    return want.len > 0 and have.len > 0 and !std.mem.eql(u8, want, have);
}

/// Runs one step of the install. What it prints and how it ends aren't needed:
/// `install` compares the files afterwards, which is what counts.
fn install_run(argv: [*:null]const ?[*:0]const u8) void {
    assert(argv[0] != null);
    assert(argv[1] != null);
    var out: [256]u8 = undefined;
    const length = process.run(argv, &out);
    if (length) |count| assert(count <= out.len);
}

/// Copies the startup file into place. The system partition is read-only, so it's
/// remounted writable for the copy, and read-only again straight after. True when the
/// file is in place.
pub fn install() bool {
    if (installed()) return true;
    install_run(&.{ "/usr/sbin/mntroot", "rw" });
    install_run(&.{ "/bin/cp", shipped, installed_path });
    install_run(&.{ "/usr/sbin/mntroot", "ro" });
    const ok = installed();
    std.debug.print("autostart: startup file {s}\n", .{if (ok) "installed" else "not installed"});
    return ok;
}
