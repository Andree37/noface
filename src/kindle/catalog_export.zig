//! Writes the book list (library.tsv) from the Kindle's catalog: `noface-launch export`,
//! run before noface starts and by noface itself to refresh (src/kindle/catalog.zig).
//!
//! The catalog is copied first, so sqlite3 never holds Amazon's own open, and the list
//! is written beside the old one and renamed over it only when it has something in it.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("paths.zig");
const service = @import("../sys/service.zig");
const calls = @import("../sys/calls.zig");
const file = @import("../sys/file.zig");
const os = @import("../sys/os.zig");

const failed = os.failed;

const library_path = paths.data_dir ++ "/" ++ paths.data.library;
const library_tmp = library_path ++ ".tmp";
/// Where sqlite3 may be: busybox sh's own search path when none is set, which is how
/// noface ran it before.
const sqlite_places = [_][*:0]const u8{
    "/sbin/sqlite3",
    "/usr/sbin/sqlite3",
    "/bin/sqlite3",
    "/usr/bin/sqlite3",
};
/// Longest the query may take. A catalog of thousands of books takes well under a second.
const query_timeout_ms = 60_000;

/// One line per book: its file, title, author, progress, last opened, read state,
/// cover, modified, whether it's on the Kindle (0), in the cloud (1) or downloading
/// (2), and its ids for the store. src/kindle/catalog.zig reads it.
pub const query =
    \\select coalesce(p_location, ''), p_titles_0_nominal,
    \\            coalesce(json_extract(j_credits, '$[0].name.display'), ''),
    \\            coalesce(p_percentFinished, 0), coalesce(p_lastAccess, 0),
    \\            coalesce(p_readState, 0), coalesce(p_thumbnail, ''),
    \\            coalesce(p_modificationTime, 0),
    \\            case when p_isDownloading = 1 then 2
    \\                 when coalesce(p_location, '') = '' then 1
    \\                 else 0 end,
    \\            coalesce(p_cdeKey, ''), coalesce(p_cdeType, ''), coalesce(p_guid, '')
    \\     from Entries
    \\     where p_location like '%.kfx'
    \\        or (p_isArchived = 1 and p_isVisibleInHome = 1 and p_type = 'Entry:Item')
;

/// Where the catalog is copied for sqlite3 to read, first choice first: RAM, as before,
/// when it has room to spare; else the data folder on the user drive, slower but large.
/// /tmp holds /var too, which Amazon's services write to, so it's never filled: a
/// large account's catalog can be tens of megabytes, and /tmp is 64.
const copy_places = [_]CopyPlace{
    .{ .path = paths.catalog_copy, .folder = "/tmp" },
    .{ .path = paths.data_dir ++ "/kf-cc.db", .folder = paths.data_dir },
};
const CopyPlace = struct { path: [*:0]const u8, folder: [*:0]const u8 };

/// What a copy leaves free on its file system, at least, for everything else there.
const copy_room_spare_bytes: u64 = 16 << 20;

/// What sqlite3 may leave beside a database it opened.
const sqlite_sidecars = [_][]const u8{ "-journal", "-wal", "-shm" };

comptime {
    // The copy goes to RAM first, which the Kindle has little of: it's removed straight
    // after, and taken only with room to spare
    assert(std.mem.startsWith(u8, paths.catalog_copy, "/tmp/"));
    assert(std.mem.endsWith(u8, library_tmp, ".tmp"));
    assert(copy_room_spare_bytes < 64 << 20);
}

/// Writes library.tsv afresh. A catalog that can't be read leaves the old list.
pub fn run() void {
    const sqlite = find_sqlite() orelse {
        std.debug.print("export: no sqlite3\n", .{});
        return;
    };
    const copy = copy_place(file.size_of(paths.catalog), calls.free_bytes) orelse {
        std.debug.print("export: no room to copy {s}\n", .{paths.catalog});
        return;
    };
    if (!service.copy_file(paths.catalog, copy)) {
        std.debug.print("export: couldn't copy {s}\n", .{paths.catalog});
        return;
    }
    defer remove_copy(copy);
    const argv = [_:null]?[*:0]const u8{ sqlite, "-separator", "\t", copy, query };
    const envp = [_:null]?[*:0]const u8{};
    const finished = finished: {
        const pid = service.spawn_to_file(&argv, &envp, library_tmp, .replace, false) orelse
            break :finished false;
        const deadline = os.now_us() + query_timeout_ms * std.time.us_per_ms;
        // Its exit code isn't the measure, as it wasn't before: what it wrote is
        break :finished service.wait_until(pid, deadline) != null;
    };
    // Cut short, the list may be part of one: the old one stays
    if (!finished) {
        std.debug.print("export: sqlite3 didn't finish\n", .{});
        return;
    }
    if (file.size_of(library_tmp) == 0) return;
    // The same list as before is left as it was, so the library sees nothing changed
    // (by its size and change time) and needn't read every book again
    if (same_contents(library_tmp, library_path)) {
        _ = calls.unlink(library_tmp); // Ignored: the next export replaces it
        return;
    }
    if (failed(calls.rename(library_tmp, library_path))) {
        std.debug.print("export: couldn't replace {s}\n", .{library_path});
    }
    assert(finished);
}

/// The first of `copy_places` with room for a catalog of `catalog_bytes` and to spare,
/// by `free_bytes`; null when none has. A catalog that can't be measured counts as
/// large, so it never goes to RAM unmeasured.
fn copy_place(catalog_bytes: u64, free_bytes: fn ([*:0]const u8) ?u64) ?[*:0]const u8 {
    assert(copy_places.len > 0);
    const needed = (if (catalog_bytes == 0) 64 << 20 else catalog_bytes) +| copy_room_spare_bytes;
    for (copy_places) |place| {
        const free = free_bytes(place.folder) orelse continue;
        if (free >= needed) return place.path;
    }
    assert(needed > copy_room_spare_bytes);
    return null;
}

/// Removes the copy and whatever sqlite3 left beside it.
fn remove_copy(copy: [*:0]const u8) void {
    assert(copy[0] == '/');
    const name = std.mem.sliceTo(copy, 0);
    _ = calls.unlink(copy); // Gone already: then there's nothing to remove
    for (sqlite_sidecars) |suffix| {
        var buffer: [128]u8 = undefined;
        const beside = std.fmt.bufPrintSentinel(&buffer, "{s}{s}", .{ name, suffix }, 0) catch
            continue;
        assert(std.mem.startsWith(u8, beside, name));
        _ = calls.unlink(beside); // Ignored: most are never made
    }
}

/// Whether the files at `a` and `b` hold the same bytes; false when either can't be read.
fn same_contents(a: [*:0]const u8, b: [*:0]const u8) bool {
    assert(a[0] == '/');
    assert(b[0] == '/');
    const data_a = file.map(a) catch return false;
    defer file.unmap(data_a);
    const data_b = file.map(b) catch return false;
    defer file.unmap(data_b);
    return std.mem.eql(u8, data_a, data_b);
}

fn find_sqlite() ?[*:0]const u8 {
    for (sqlite_places) |place| {
        assert(place[0] == '/');
        if (file.exists(place)) return place;
    }
    return null;
}

test "the catalog is copied to RAM only with room to spare, else to the user drive" {
    const Free = struct {
        fn tight(folder: [*:0]const u8) ?u64 {
            return if (std.mem.eql(u8, std.mem.sliceTo(folder, 0), "/tmp")) 20 << 20 else 8 << 30;
        }
        fn roomy(_: [*:0]const u8) ?u64 {
            return 60 << 20;
        }
        fn none(_: [*:0]const u8) ?u64 {
            return null;
        }
    };
    try std.testing.expectEqual(copy_places[0].path, copy_place(1 << 20, Free.roomy).?);
    try std.testing.expectEqual(copy_places[1].path, copy_place(10 << 20, Free.tight).?);
    // A catalog that can't be measured is taken as large: never to RAM unmeasured
    try std.testing.expect(copy_place(0, Free.roomy) == null);
    try std.testing.expectEqual(copy_places[1].path, copy_place(0, Free.tight).?);
    try std.testing.expect(copy_place(1 << 20, Free.none) == null);
    try std.testing.expect(copy_place(50 << 20, Free.roomy) == null);
}

test "the query lists the twelve columns the library reads" {
    // Commas outside brackets part the columns
    const select = query[0..std.mem.indexOf(u8, query, "from Entries").?];
    var columns: u32 = 1;
    var depth: u32 = 0;
    for (select) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (c == ',' and depth == 0) columns += 1;
    }
    try std.testing.expectEqual(@as(u32, 12), columns);
}
