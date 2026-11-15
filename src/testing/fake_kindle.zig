//! A pretend Kindle for the scenario tests: it answers the Kindle's system tools (lipc,
//! date, the catalog and sync scripts) the way a healthy Kindle would, remembers what
//! was set, and starts nothing. With it the self-test can run on the reader's own
//! Kindle and change nothing on it, and a test can check what noface asked for.
const std = @import("std");
const assert = std.debug.assert;
const paths = @import("../kindle/paths.zig");
const process = @import("../sys/process.zig");
const lipc = @import("../kindle/lipc.zig");

const Prop = struct { key: []const u8, value: []const u8 };

/// What `date` prints when no clock is set, so tests see the same screen every run.
const date_fixed = "12:00 - 01 Jan 2026";

pub const FakeKindle = struct {
    alloc: std.mem.Allocator,
    props: std.ArrayList(Prop) = .empty,
    /// Every "service prop value" set, in order.
    sets: std.ArrayList([]const u8) = .empty,
    /// Every other program noface asked to run, by name.
    ran: std.ArrayList([]const u8) = .empty,
    /// What `date` prints, "12:00 - 01 Jan 2026", when set: the simulator's real clock.
    /// Otherwise a fixed time, so tests see the same screen every run. Returns how many
    /// bytes of `out` it wrote.
    clock: ?*const fn (out: []u8) u32 = null,
    /// A property that stops answering once it's been set once, as cmd can while it
    /// takes the radio down: reads time out, though the set went through.
    busy_after_set: ?[]const u8 = null,
    busy: bool = false,

    /// A Kindle awake, on Wi-Fi, Bluetooth off, not in airplane mode.
    pub fn init(alloc: std.mem.Allocator) !FakeKindle {
        var k = FakeKindle{ .alloc = alloc };
        // What the status bar reads, as lipc.zig's own table says a healthy Kindle answers
        for (lipc.readings) |r| {
            var buf: [96]u8 = undefined;
            const key = r.key(&buf);
            if (key.len > 0) try k.put(key, r.healthy);
        }
        // And what's asked on its own, elsewhere
        const others = [_][2][]const u8{
            .{ "com.lab126.powerd state", "active" },
            .{ "com.lab126.volumd useUsbForNetwork", "0" },
        };
        for (others) |d| try k.put(d[0], d[1]);
        // Each key once: a later put of the same key replaces it
        assert(k.props.items.len >= others.len);
        assert(k.props.items.len <= lipc.readings.len + others.len);
        assert(k.sets.items.len == 0); // Nothing set yet
        return k;
    }

    pub fn put(k: *FakeKindle, key: []const u8, value: []const u8) !void {
        assert(key.len > 0);
        assert(std.mem.indexOfScalar(u8, key, ' ') != null); // "service prop"
        for (k.props.items) |*p| {
            if (std.mem.eql(u8, p.key, key)) {
                p.value = try k.alloc.dupe(u8, value);
                return;
            }
        }
        try k.props.append(k.alloc, .{
            .key = try k.alloc.dupe(u8, key),
            .value = try k.alloc.dupe(u8, value),
        });
    }

    pub fn get(k: *const FakeKindle, key: []const u8) []const u8 {
        assert(key.len > 0);
        assert(std.mem.indexOfScalar(u8, key, ' ') != null); // "service prop"
        for (k.props.items) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return "";
    }

    /// Whether anything set matched "service prop value" exactly.
    pub fn was_set(k: *const FakeKindle, call: []const u8) bool {
        assert(call.len > 0);
        assert(std.mem.count(u8, call, " ") >= 2); // "service prop value"
        for (k.sets.items) |s| {
            if (std.mem.eql(u8, s, call)) return true;
        }
        return false;
    }

    pub fn did_run(k: *const FakeKindle, program: []const u8) bool {
        assert(program.len > 0);
        assert(std.mem.indexOfScalar(u8, program, '/') == null); // By name, as `ran` keeps them
        for (k.ran.items) |r| {
            if (std.mem.eql(u8, r, program)) return true;
        }
        return false;
    }

    /// Routes every program noface starts to this Kindle, until `release`.
    pub fn install(k: *FakeKindle) void {
        assert(process.fake == null); // One pretend Kindle at a time
        process.fake = .{ .ctx = k, .answer = answer };
        assert(process.fake.?.ctx == @as(*anyopaque, k));
    }

    pub fn release(_: *FakeKindle) void {
        assert(process.fake != null); // Released once, after install
        process.fake = null;
    }

    fn answer(ctx: *anyopaque, argv: []const []const u8, out: []u8) ?u32 {
        const k: *FakeKindle = @ptrCast(@alignCast(ctx));
        if (argv.len == 0) return null;
        const program = std.fs.path.basename(argv[0]);
        var args = argv[1..];
        if (args.len > 0 and std.mem.eql(u8, args[0], "-s")) args = args[1..];
        if (std.mem.eql(u8, program, "lipc-get-prop") and args.len >= 2) {
            return k.answer_get(args, out) orelse return null;
        }
        if (std.mem.eql(u8, program, "lipc-set-prop") and args.len >= 3) {
            return k.answer_set(args) orelse return null;
        }
        if (std.mem.eql(u8, program, "date")) {
            if (k.clock) |read| {
                const written = read(out);
                assert(written <= out.len);
                return written;
            }
            return answer_copy(date_fixed, out);
        }
        k.ran.append(k.alloc, k.alloc.dupe(u8, program) catch return null) catch return null;
        return 0;
    }

    /// `lipc-get-prop service prop`: its value, or null for one never set, as lipc fails.
    fn answer_get(k: *FakeKindle, args: []const []const u8, out: []u8) ?u32 {
        assert(args.len >= 2);
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ args[0], args[1] }) catch return null;
        assert(key.len == args[0].len + 1 + args[1].len); // "service prop"
        if (k.busy) {
            if (k.busy_after_set) |b| {
                if (std.mem.eql(u8, b, key)) {
                    k.busy = false; // Answers again next time
                    return null;
                }
            }
        }
        const value = k.get(key);
        if (value.len == 0) return null; // An unknown property: lipc fails
        return answer_copy(value, out);
    }

    /// `lipc-set-prop service prop value`: kept, and noted as set.
    fn answer_set(k: *FakeKindle, args: []const []const u8) ?u32 {
        assert(args.len >= 3);
        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s} {s}", .{ args[0], args[1] }) catch return null;
        assert(key.len == args[0].len + 1 + args[1].len); // "service prop"
        k.put(key, args[2]) catch return null;
        if (k.busy_after_set) |b| {
            if (std.mem.eql(u8, b, key)) k.busy = true;
        }
        const call = std.fmt.allocPrint(k.alloc, "{s} {s}", .{ key, args[2] }) catch return null;
        const sets_before = k.sets.items.len;
        k.sets.append(k.alloc, call) catch return null;
        assert(k.sets.items.len == sets_before + 1);
        return 0;
    }

    /// Copies an answer into `out`, cut short when it doesn't fit, as a pipe would be.
    fn answer_copy(value: []const u8, out: []u8) u32 {
        assert(value.len > 0); // An empty answer is a failure, said with null
        const n = @min(value.len, out.len);
        @memcpy(out[0..n], value[0..n]);
        assert(n <= out.len);
        return @intCast(n);
    }
};

test "the fake Kindle answers and remembers lipc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var k = try FakeKindle.init(arena.allocator());
    var out: [32]u8 = undefined;
    const get_argv = [_][]const u8{ "/usr/bin/lipc-get-prop", "com.lab126.cmd", "wirelessEnable" };
    const n = FakeKindle.answer(&k, &get_argv, &out).?;
    try std.testing.expectEqualStrings("1", out[0..n]);
    const set_argv = [_][]const u8{
        "/usr/bin/lipc-set-prop",
        "com.lab126.cmd",
        "wirelessEnable",
        "0",
    };
    _ = FakeKindle.answer(&k, &set_argv, &out);
    try std.testing.expect(k.was_set("com.lab126.cmd wirelessEnable 0"));
    try std.testing.expectEqualStrings("0", k.get("com.lab126.cmd wirelessEnable"));
    _ = FakeKindle.answer(&k, &.{ paths.launcher, "export" }, &out);
    try std.testing.expect(k.did_run("noface-launch"));
}
