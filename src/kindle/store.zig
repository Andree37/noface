//! Amazon's store actions on a book: download, remove from the device, mark as read.
const std = @import("std");
const assert = std.debug.assert;
const process = @import("../sys/process.zig");
const safe = @import("safe.zig");

const command_size_max = 320;

/// Asks the store to act on a book, through lipc. Every value in `args` must have
/// passed safe.safe_id, as they go into a shell command.
fn read_now_action(comptime prop: []const u8, comptime fields: []const u8, args: anytype) void {
    const format = "echo '{{ " ++ fields ++ " }}' | /usr/bin/lipc-hash-prop com.lab126.readnow " ++
        prop;
    const values = @typeInfo(@TypeOf(args)).@"struct".field_names.len;
    // The command fits its buffer with every value, in place of its "{s}", at its longest.
    comptime assert(format.len + values * (safe.id_size_max - "{s}".len) < command_size_max);
    // Paired with the callers' checks: nothing unchecked reaches the shell.
    inline for (args) |value| assert(safe.safe_id(value));
    var buf: [command_size_max]u8 = undefined;
    const command = std.fmt.bufPrintSentinel(&buf, format, args, 0) catch return;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", command };
    var out: [64]u8 = undefined;
    // Ignored: the store answers nothing worth reading; the book's state shows in the catalog.
    _ = process.run(&argv, &out);
}

/// Queues a cloud book for download.
pub fn download_book(key: []const u8, kind: []const u8) void {
    if (!safe.safe_id(key) or !safe.safe_id(kind)) return;
    read_now_action("kppDownloadAction", "kppItems = \"{s},{s}\"", .{ key, kind });
}

/// Removes the local copy. Never sets kppFrom: "cloud" there revokes samples.
pub fn remove_download(key: []const u8, kind: []const u8) void {
    if (!safe.safe_id(key) or !safe.safe_id(kind)) return;
    const fields = "kppCdeKey = \"{s}\", kppCdeType = \"{s}\"";
    read_now_action("kppDeleteItemAction", fields, .{ key, kind });
}

pub fn mark_read(key: []const u8, kind: []const u8, read_it: bool) void {
    if (!safe.safe_id(key) or !safe.safe_id(kind)) return;
    const value = if (read_it) "actionRead" else "actionUnread";
    const fields = "kppCdeKey = \"{s}\", kppCdeType = \"{s}\", kppMAR = \"{s}\"";
    read_now_action("kppMarkAsReadAction", fields, .{ key, kind, value });
}
