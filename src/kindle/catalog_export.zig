//! Writes the book list (library.tsv) from the Kindle's catalog: `noface-launch export`,
//! run before noface starts and by noface itself to refresh (src/kindle/catalog.zig).
//!
//! The catalog is copied first, so sqlite3 never holds Amazon's own open, and the list
//! is written beside the old one and renamed over it only when it has something in it.
const std = @import("std");
const assert = std.debug.assert;
const process = @import("../sys/process.zig");
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
/// Longest the whole export may take, the copy and the query: past it sqlite3 is
/// stopped and the copy removed, so whoever runs the export waits a little longer than
/// this and it always cleans up after itself. A catalog of thousands of books takes
/// well under a second.
pub const time_max_ms = 60_000;

/// One line per book: its file, title, author, progress, last opened, read state,
/// cover, modified, whether it's on the Kindle (0), in the cloud (1) or downloading
/// (2), its ids for the store, and whether it was copied onto the Kindle (1) rather
/// than bought or sent (0). src/kindle/catalog.zig reads it.
pub const query = columns ++ ", " ++ sideloaded_from_assets ++ from_entries;
/// The same without the stock library's record, where there's none to read: every
/// book counts as bought or sent, as Amazon names all but a copied one.
pub const query_without_assets = columns ++ ", 0" ++ from_entries;
/// Whether a book was copied onto the Kindle, by the stock library's own flag, read
/// from the copy attached as `assets` (`attach_assets`).
const sideloaded_from_assets = "coalesce((select SIDELOAD from assets.Nodes " ++
    "where ASIN = p_cdeKey limit 1), 0)";
/// `query` after attaching the copy of the stock library's record, in one sqlite3.
pub const query_attached = "attach '" ++ paths.assets_copy ++ "' as assets; " ++ query;
const from_entries = " from Entries where p_location like '%.kfx'" ++
    " or (p_isArchived = 1 and p_isVisibleInHome = 1 and p_type = 'Entry:Item')";
const columns = "select " ++
    one_line("coalesce(p_location, '')") ++ ", " ++
    one_line("p_titles_0_nominal") ++ ", " ++
    one_line("coalesce(json_extract(j_credits, '$[0].name.display'), '')") ++ ", " ++
    "coalesce(p_percentFinished, 0), coalesce(p_lastAccess, 0), " ++
    "coalesce(p_readState, 0), " ++
    one_line("coalesce(p_thumbnail, '')") ++ ", " ++
    "coalesce(p_modificationTime, 0), " ++
    "case when p_isDownloading = 1 then 2 " ++
    "when coalesce(p_location, '') = '' then 1 else 0 end, " ++
    one_line("coalesce(p_cdeKey, '')") ++ ", " ++
    one_line("coalesce(p_cdeType, '')") ++ ", " ++
    one_line("coalesce(p_guid, '')");

/// A text column with its tabs, line feeds and carriage returns made spaces: sqlite3
/// writes values as they are, so a title with a tab would shift every column after it,
/// and one with a line break would split its book in two.
fn one_line(comptime column: []const u8) []const u8 {
    const tab = "char(9)";
    const line_feed = "char(10)";
    const carriage_return = "char(13)";
    return "replace(replace(replace(" ++ column ++ ", " ++ tab ++ ", ' '), " ++ line_feed ++
        ", ' '), " ++ carriage_return ++ ", ' ')";
}

/// Where the catalog is copied for sqlite3 to read: RAM when it's small, as nearly
/// every account's is; else the data folder on the user drive, slower but large. /tmp
/// holds /var too, which Amazon's services write to, and is 64 MB with ~55 free: a
/// copy of at most 8 MB always leaves them room. A catalog that can't be measured
/// counts as large, so nothing goes to RAM unmeasured.
const copy_to_ram_bytes_max: u64 = 8 << 20;
const copy_in_ram: [*:0]const u8 = paths.catalog_copy;
const copy_on_drive: [*:0]const u8 = paths.data_dir ++ "/kf-cc.db";

/// What sqlite3 may leave beside a database it opened.
const sqlite_sidecars = [_][]const u8{ "-journal", "-wal", "-shm" };

comptime {
    // The copy goes to RAM first, which the Kindle has little of: it's removed straight
    // after, and taken only with room to spare
    assert(std.mem.startsWith(u8, paths.catalog_copy, "/tmp/"));
    assert(std.mem.endsWith(u8, library_tmp, ".tmp"));
    assert(copy_to_ram_bytes_max < 64 << 20);
}

/// Writes library.tsv afresh. A catalog that can't be read leaves the old list.
pub fn run() void {
    const deadline = os.now_us() + time_max_ms * std.time.us_per_ms;
    const sqlite = find_sqlite() orelse {
        std.debug.print("export: no sqlite3\n", .{});
        return;
    };
    const copy = copy_place(file.size_of(paths.catalog));
    if (!file.copy_file(paths.catalog, copy)) {
        std.debug.print("export: couldn't copy {s}\n", .{paths.catalog});
        return;
    }
    defer remove_copy(copy);
    // Which books were copied on, from the stock library's record: copied too, and
    // left out when there's none to copy, or it wouldn't fit in RAM
    const with_assets = copy_assets();
    defer if (with_assets) remove_copy(paths.assets_copy);
    const sql: [*:0]const u8 = if (with_assets) query_attached else query_without_assets;
    const argv = [_:null]?[*:0]const u8{ sqlite, "-separator", "\t", copy, sql };
    const envp = [_:null]?[*:0]const u8{};
    const finished = finished: {
        const pid = service.spawn_to_file(&argv, &envp, library_tmp, .replace, false) orelse
            break :finished false;
        // Its exit code isn't the measure, as it wasn't before: what it wrote is
        break :finished process.wait_until(pid, deadline) != null;
    };
    // Cut short, the list may be part of one: the old one stays
    if (!finished) {
        std.debug.print("export: sqlite3 didn't finish\n", .{});
        _ = calls.unlink(library_tmp); // Ignored: the next export replaces it
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
}

/// Copies the stock library's record into RAM, when there's one small enough.
fn copy_assets() bool {
    const bytes = file.size_of(paths.assets);
    if (bytes == 0) return false; // None, or not measured
    if (bytes > copy_to_ram_bytes_max) return false;
    assert(std.mem.startsWith(u8, paths.assets_copy, "/tmp/"));
    return file.copy_file(paths.assets, paths.assets_copy);
}

/// Where a catalog of `catalog_bytes` (0: not measured) is copied.
fn copy_place(catalog_bytes: u64) [*:0]const u8 {
    if (catalog_bytes == 0) return copy_on_drive;
    if (catalog_bytes > copy_to_ram_bytes_max) return copy_on_drive;
    return copy_in_ram;
}

/// Removes the copy and whatever sqlite3 left beside it.
fn remove_copy(copy: [*:0]const u8) void {
    assert(copy[0] == '/');
    const name = std.mem.sliceTo(copy, 0);
    _ = calls.unlink(copy); // Ignored: gone already: then there's nothing to remove
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

test "a small catalog is copied to RAM, a large or unmeasured one to the user drive" {
    try std.testing.expectEqual(copy_in_ram, copy_place(1 << 20));
    try std.testing.expectEqual(copy_in_ram, copy_place(copy_to_ram_bytes_max));
    try std.testing.expectEqual(copy_on_drive, copy_place(copy_to_ram_bytes_max + 1));
    try std.testing.expectEqual(copy_on_drive, copy_place(0));
}

test "both queries list the thirteen columns the library reads" {
    for ([_][]const u8{ query, query_without_assets }) |q| {
        // Commas outside brackets part the columns
        const select = q[0..std.mem.indexOf(u8, q, " from Entries").?];
        var count: u32 = 1;
        var depth: u32 = 0;
        for (select) |c| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (c == ',' and depth == 0) count += 1;
        }
        try std.testing.expectEqual(@as(u32, 13), count);
    }
}

test "a title with a tab or a line break stays one line of thirteen columns" {
    // Run by the sqlite3 there is, as on the Kindle: none on this computer, nothing to run
    const sqlite = for (sqlite_places) |place| {
        if (file.exists(place)) break place;
    } else return error.SkipZigTest;
    var path_buffer: [file.own_path_bytes_max]u8 = undefined;
    const db_format = "/tmp/noface-catalog-test-{d}";
    const db = try std.fmt.bufPrintSentinel(&path_buffer, db_format, .{calls.getpid()}, 0);
    defer _ = calls.unlink(db); // Ignored: only /tmp is left fuller
    const schema = "create table Entries (p_location, p_titles_0_nominal, j_credits, " ++
        "p_percentFinished, p_lastAccess, p_readState, p_thumbnail, p_modificationTime, " ++
        "p_isDownloading, p_cdeKey, p_cdeType, p_guid, p_isArchived, p_isVisibleInHome, p_type);" ++
        "insert into Entries (p_location, p_titles_0_nominal) values " ++
        "('/mnt/us/documents/a.kfx', 'One' || char(9) || 'Two' || char(10) || 'Three');";
    var out: [1024]u8 = undefined;
    const made = [_:null]?[*:0]const u8{ sqlite, db, schema };
    _ = process.run(&made, &out) orelse return error.CantMake;
    const asked = [_:null]?[*:0]const u8{ sqlite, "-separator", "\t", db, query_without_assets };
    const length = process.run(&asked, &out) orelse return error.CantQuery;
    const rows = std.mem.trimEnd(u8, out[0..length], "\n");
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rows, "\n")); // One book
    try std.testing.expectEqual(@as(usize, 12), std.mem.count(u8, rows, "\t")); // Thirteen columns
    try std.testing.expect(std.mem.indexOf(u8, rows, "One Two Three") != null);
}
