//! Opening noface when the Kindle starts needs one small file in the system's startup
//! folder, /etc/upstart. It ships in noface's folder; switching the setting on copies
//! it there (after the reader agrees), so nobody edits system files by hand. The file
//! only runs noface's autostart.sh, which does nothing while the setting is off, so
//! switching it off leaves the file in place, idle.
const std = @import("std");
const paths = @import("paths.zig");
const process = @import("../sys/process.zig");
const state = @import("../sys/state.zig");

const shipped = paths.autostart_conf;
const installed_path = "/etc/upstart/noface-autostart.conf";

/// Whether the system's copy is there and the same as the one noface ships.
pub fn installed() bool {
    var a: [2048]u8 = undefined;
    var b: [2048]u8 = undefined;
    const want = state.read_small(shipped, &a);
    const have = state.read_small(installed_path, &b);
    return want.len > 0 and std.mem.eql(u8, want, have);
}

/// Whether the system's copy is there but differs from the one noface ships: one from
/// an older version, which may run a script that no longer reads the settings. Not
/// when either is missing: a reader may have deleted the system's copy on purpose.
pub fn outdated() bool {
    var a: [2048]u8 = undefined;
    var b: [2048]u8 = undefined;
    const want = state.read_small(shipped, &a);
    const have = state.read_small(installed_path, &b);
    return want.len > 0 and have.len > 0 and !std.mem.eql(u8, want, have);
}

fn run(argv: [*:null]const ?[*:0]const u8) void {
    var out: [256]u8 = undefined;
    _ = process.run(argv, &out);
}

/// Copies the startup file into place. The system partition is read-only, so it's
/// remounted writable for the copy, and read-only again straight after. True when the
/// file is in place.
pub fn install() bool {
    if (installed()) return true;
    run(&.{ "/usr/sbin/mntroot", "rw" });
    run(&.{ "/bin/cp", shipped, installed_path });
    run(&.{ "/usr/sbin/mntroot", "ro" });
    const ok = installed();
    std.debug.print("autostart: startup file {s}\n", .{if (ok) "installed" else "not installed"});
    return ok;
}
