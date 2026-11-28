//! The Kindle's `archive` service, which turns what's new in the reader's Amazon
//! library into the catalog's books in the cloud, as a sync asks it (`archive.sync`,
//! sent by the delivery service, which doesn't ask again if it isn't there). Upstart
//! starts it at boot, once lab126 and dpmd have started, and stops it with dpmd; when
//! dpmd is started again on its own (as it was once, the Kindle out of memory), archive
//! stays stopped until the next boot, and sent books stop arriving, in noface and in
//! the Kindle's own screens alike. So before every sync it's started again if it's
//! stopped, and only as its own job would be: with dpmd running, and taken as started
//! once it answers.
const std = @import("std");
const assert = std.debug.assert;
const process = @import("../sys/process.zig");
const os = @import("../sys/os.zig");

const initctl = "/sbin/initctl";
const lipc_probe = "/usr/bin/lipc-probe";
const job = "archive";
/// What upstart says of a job stopped and not on its way anywhere: one being stopped
/// (stop/stopping, stop/killed, stop/post-stop) is left to finish.
const stopped_line = job ++ " stop/waiting";
/// Its service, and the property the delivery service sends it the sync by: there once
/// it has started.
const service = "com.lab126.archive";
const sync_property = "handleToDoItem";

/// How long upstart takes to say how a job is, with room to spare (about 10 ms).
const status_ms_max = 1000;
/// How long a start may take, from asking to its service answering: about 130 ms on a
/// Paperwhite 12, the delivery service asking for it about 1.2 s into a sync.
const start_ms_max = 1000;
const answer_check_ms = 20;
const answer_checks_max = start_ms_max / answer_check_ms;

comptime {
    assert(initctl[0] == '/'); // Never found through a search path
    assert(lipc_probe[0] == '/');
    assert(answer_checks_max * answer_check_ms <= start_ms_max);
}

/// Starts `archive` if it's stopped, dpmd is running and nothing else is under way,
/// and waits until it answers; else does nothing. Logged when it had to, so a Kindle
/// that keeps losing it is seen.
pub fn ensure_running() void {
    var out: [128]u8 = undefined;
    const archive = status_of(job, &out) orelse return; // Upstart can't say: left alone
    if (!std.mem.eql(u8, archive, stopped_line)) return;
    // As its job starts it: never without dpmd, which a later dpmd start wouldn't fix
    const dpmd = status_of("dpmd", &out) orelse "";
    if (!std.mem.startsWith(u8, dpmd, "dpmd start/running")) {
        std.debug.print("archive: stopped, left so while dpmd isn't running\n", .{});
        return;
    }
    const deadline = os.now_us() + start_ms_max * std.time.us_per_ms;
    const start = [_:null]?[*:0]const u8{ initctl, "start", job };
    // Started, upstart prints its new status; refused, it says why on stderr only
    const printed = process.run_until(&start, &out, deadline) orelse 0;
    assert(printed <= out.len);
    const said = std.mem.trim(u8, out[0..printed], " \n");
    if (!std.mem.startsWith(u8, said, job ++ " start/")) {
        std.debug.print("archive: was stopped, not started\n", .{});
        return;
    }
    const answers = answers_by(deadline);
    const how = if (answers) "" else ", not answering";
    std.debug.print("archive: was stopped, started{s}\n", .{how});
}

/// What upstart says of `name`, its status line trimmed, in `out`; null if it can't say.
fn status_of(comptime name: [:0]const u8, out: *[128]u8) ?[]const u8 {
    const deadline = os.now_us() + status_ms_max * std.time.us_per_ms;
    const status = [_:null]?[*:0]const u8{ initctl, "status", name ++ "" };
    const printed = process.run_until(&status, out, deadline) orelse return null;
    assert(printed <= out.len);
    const line = std.mem.trim(u8, out[0..printed], " \n");
    if (line.len == 0) return null; // Refused: an unknown job, said on stderr
    assert(line.len <= printed);
    return line;
}

/// Whether archive's service answers by `deadline`: its sync property listed.
fn answers_by(deadline: u64) bool {
    comptime assert(answer_checks_max > 0);
    var out: [512]u8 = undefined;
    const probe = [_:null]?[*:0]const u8{ lipc_probe, service };
    for (0..answer_checks_max) |_| {
        if (os.now_us() >= deadline) return false;
        const printed = process.run_until(&probe, &out, deadline) orelse return false;
        assert(printed <= out.len);
        if (std.mem.indexOf(u8, out[0..printed], sync_property) != null) return true;
        os.sleep_ms(answer_check_ms);
    }
    return false;
}
