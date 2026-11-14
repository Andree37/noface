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

comptime {
    // The copy goes to RAM, which the Kindle has little of: it's removed straight after
    assert(std.mem.startsWith(u8, paths.catalog_copy, "/tmp/"));
    assert(std.mem.endsWith(u8, library_tmp, ".tmp"));
}

/// Writes library.tsv afresh. A catalog that can't be read leaves the old list.
pub fn run() void {
    const sqlite = find_sqlite() orelse {
        std.debug.print("export: no sqlite3\n", .{});
        return;
    };
    if (!service.copy_file(paths.catalog, paths.catalog_copy)) {
        std.debug.print("export: couldn't copy {s}\n", .{paths.catalog});
        return;
    }
    const argv = [_:null]?[*:0]const u8{ sqlite, "-separator", "\t", paths.catalog_copy, query };
    const envp = [_:null]?[*:0]const u8{};
    const finished = finished: {
        const pid = service.spawn_to_file(&argv, &envp, library_tmp, .replace, false) orelse
            break :finished false;
        const deadline = os.now_us() + query_timeout_ms * std.time.us_per_ms;
        // Its exit code isn't the measure, as it wasn't before: what it wrote is
        break :finished service.wait_until(pid, deadline) != null;
    };
    _ = calls.unlink(paths.catalog_copy); // Gone already: then there's nothing to remove
    // Cut short, the list may be part of one: the old one stays
    if (!finished) {
        std.debug.print("export: sqlite3 didn't finish\n", .{});
        return;
    }
    if (file.size_of(library_tmp) == 0) return;
    if (failed(calls.rename(library_tmp, library_path))) {
        std.debug.print("export: couldn't replace {s}\n", .{library_path});
    }
    assert(finished);
}

fn find_sqlite() ?[*:0]const u8 {
    for (sqlite_places) |place| {
        assert(place[0] == '/');
        if (file.exists(place)) return place;
    }
    return null;
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
