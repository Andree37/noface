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
/// (2), its ids for the store, whether it was copied onto the Kindle (1) rather than
/// bought or sent (0), and Amazon's latest place for it from any device, its position
/// and when, in ms (both empty when there's none). src/kindle/catalog.zig reads it.
/// Each copy the export could make of the stock library's record and of Amazon's
/// places is attached first, in the same sqlite3; without one, its columns are filled
/// as a book that has none.
pub fn query(comptime with: Attached) [:0]const u8 {
    const attach_assets = "attach '" ++ paths.assets_copy ++ "' as assets; ";
    const attach_notes = "attach '" ++ paths.annotations_copy ++ "' as notes; ";
    const sql = (if (with.assets) attach_assets else "") ++
        (if (with.notes) attach_notes else "") ++
        columns ++ ", " ++
        // Every book counts as bought or sent, as Amazon names all but a copied one
        (if (with.assets) sideloaded_from_assets else "0") ++ ", " ++
        (if (with.notes) outside_from_notes else "char(9)") ++ from_entries;
    // The attached copies come first, then one select over the catalog's books: each
    // check a step a byte, compared at build time
    @setEvalBranchQuota(2 * sql.len);
    const first = if (with.assets) attach_assets else if (with.notes) attach_notes else columns;
    comptime assert(std.mem.startsWith(u8, sql, first));
    comptime assert(std.mem.endsWith(u8, sql, from_entries));
    return sql;
}

/// Which copies the export made, to attach: the stock library's record, Amazon's places.
pub const Attached = struct { assets: bool, notes: bool };

/// Whether a book was copied onto the Kindle, by the stock library's own flag, read
/// from the copy attached as `assets`.
const sideloaded_from_assets = "coalesce((select SIDELOAD from assets.Nodes " ++
    "where ASIN = p_cdeKey limit 1), 0)";
/// Amazon's latest place for a book, `kindle.most_recent_read` from whichever device
/// made it (src/kindle/reading_place.zig), from the copy attached as `notes`: its
/// position, a tab and its time, two columns in one, or a tab alone for none.
const outside_from_notes = "coalesce((select " ++
    "json_extract(serialized_payload, '$.position.shortPosition') || char(9) || " ++
    "modified_time from notes.server_view where dataset = 4 and p_cdeKey != '' and " ++
    "substr(dataset_id, 1, length(p_cdeKey) + 1) = p_cdeKey || '-' " ++
    "order by modified_time desc limit 1), char(9))";
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
    // Which books were copied on, from the stock library's record, and where Amazon has
    // each from any device: copied too, and left out when there's none to copy, or it
    // wouldn't fit in RAM
    const with: Attached = .{
        .assets = copy_small(paths.assets, paths.assets_copy),
        .notes = copy_annotations(),
    };
    defer if (with.assets) remove_copy(paths.assets_copy);
    defer if (with.notes) remove_copy(paths.annotations_copy);
    if (with.notes) assert(file.exists(paths.annotations_copy));
    const sql: [*:0]const u8 = switch (with.assets) {
        inline else => |assets| switch (with.notes) {
            inline else => |notes| query(.{ .assets = assets, .notes = notes }),
        },
    };
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

/// Copies the database at `source` into RAM at `target`, when it's there and small
/// enough. Whether it did.
fn copy_small(source: [*:0]const u8, target: [*:0]const u8) bool {
    assert(std.mem.startsWith(u8, std.mem.sliceTo(target, 0), "/tmp/"));
    const bytes = file.size_of(source);
    if (bytes == 0) return false; // None, or not measured
    if (bytes > copy_to_ram_bytes_max) return false;
    return file.copy_file(source, target);
}

/// Copies Amazon's places, the current account's database: the one changed last, as
/// an earlier account's folder can be there too. Whether it did.
fn copy_annotations() bool {
    var newest: Newest = .{};
    // Ignored: a folder listed in part still names the newest database it saw
    _ = calls.each_entry(paths.annotations_dir, &newest, Newest.entry);
    const found = newest.found() orelse return false;
    return copy_small(found, paths.annotations_copy);
}

/// The database in the account folders changed last, as they're listed.
const Newest = struct {
    buffer: [annotations_path_bytes_max]u8 = undefined,
    len: u32 = 0,
    modified_s: i64 = std.math.minInt(i64),

    fn entry(n: *Newest, name: []const u8, is_dir: bool) void {
        assert(name.len > 0);
        if (!is_dir) return;
        if (name[0] == '.') return; // The folder itself and the one above it
        var buffer: [annotations_path_bytes_max]u8 = undefined;
        const named = .{ paths.annotations_dir, name, paths.annotations_name };
        const path = std.fmt.bufPrintSentinel(&buffer, "{s}/{s}/{s}", named, 0) catch return;
        const facts = calls.facts_at(path) orelse return; // No database in this one
        if (facts.modified_s <= n.modified_s) return;
        @memcpy(n.buffer[0 .. path.len + 1], path[0 .. path.len + 1]);
        n.len = @intCast(path.len);
        n.modified_s = facts.modified_s;
        assert(n.buffer[n.len] == 0);
    }

    fn found(n: *const Newest) ?[*:0]const u8 {
        if (n.len == 0) return null;
        assert(n.buffer[n.len] == 0);
        return n.buffer[0..n.len :0];
    }
};

/// Room for an account folder's database: the folder's name is Amazon's account id.
const annotations_path_bytes_max = 256;

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

test "every query lists the fourteen columns the library reads, the last two in one" {
    const queries = [_][]const u8{
        query(.{ .assets = true, .notes = true }),
        query(.{ .assets = true, .notes = false }),
        query(.{ .assets = false, .notes = true }),
        query(.{ .assets = false, .notes = false }),
    };
    for (queries) |q| {
        // Commas outside brackets part the columns
        const start = std.mem.indexOf(u8, q, "select ").?;
        const select = q[start..std.mem.indexOf(u8, q, " from Entries").?];
        var count: u32 = 1;
        var depth: u32 = 0;
        for (select) |c| {
            if (c == '(') depth += 1;
            if (c == ')') depth -= 1;
            if (c == ',' and depth == 0) count += 1;
        }
        try std.testing.expectEqual(@as(u32, 14), count);
    }
}

test "a title with a tab or a line break stays one line of fifteen columns" {
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
    const sql = query(.{ .assets = false, .notes = false });
    const asked = [_:null]?[*:0]const u8{ sqlite, "-separator", "\t", db, sql };
    const length = process.run(&asked, &out) orelse return error.CantQuery;
    const rows = std.mem.trimEnd(u8, out[0..length], "\n");
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rows, "\n")); // One book
    try std.testing.expectEqual(@as(usize, 14), std.mem.count(u8, rows, "\t")); // Fifteen columns
    try std.testing.expect(std.mem.indexOf(u8, rows, "One Two Three") != null);
}
