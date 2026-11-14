//! Prints the structure of a KFX book without its text: entity types with counts, and
//! the field layout of one type. Strings show as their length only.
//! Usage: kfxshape <book.kfx> [type [max entities]]
const std = @import("std");
const core = @import("core");
const ion = core.ion;

fn print(comptime f: []const u8, args: anytype) void {
    std.debug.print(f, args);
}

fn shape(v: ion.Value, depth: usize, max_items: usize) void {
    const pad = "                                                            ";
    const indent = pad[0..@min(depth * 2, pad.len)];
    switch (v.kind) {
        .struct_ => {
            print("{{\n", .{});
            var it = v.fields();
            while (it.next()) |f| {
                print("{s}  ${d}: ", .{ indent, f.key });
                shape(f.value, depth + 1, max_items);
            }
            print("{s}}}\n", .{indent});
        },
        .list, .sexp => {
            var it = v.items();
            var n: usize = 0;
            var count: usize = 0;
            var counter = v.items();
            while (counter.next()) |_| count += 1;
            print("[{d} items]\n", .{count});
            while (it.next()) |item| : (n += 1) {
                if (n >= max_items) break;
                print("{s}  - ", .{indent});
                shape(item, depth + 1, max_items);
            }
        },
        .string => print("string({d})\n", .{v.body.len}),
        .symbol => print("${d}\n", .{v.int}),
        .uint => print("{d}\n", .{v.int}),
        else => print("{s}\n", .{@tagName(v.kind)}),
    }
}

/// For every style field, how often each value shows up. Numbers are printed with
/// their unit symbol, so "1.5 $505" is 1.5 of unit $505.
fn style_summary(data: []const u8) !void {
    var seen: [256][64]u8 = undefined;
    var counts: [256]u32 = @splat(0);
    var used: usize = 0;
    var it = try core.kfx.entities(data);
    while (it.next()) |e| {
        if (e.kind != 157) continue;
        const v = core.kfx.entity_value(e.raw) orelse continue;
        var fields = v.fields();
        while (fields.next()) |f| {
            if (f.key == 173) continue; // The style's own name
            var line: [64]u8 = undefined;
            const desc = switch (f.value.kind) {
                .symbol => std.fmt.bufPrint(&line, "${d} = ${d}", .{ f.key, f.value.int }) catch continue,
                .struct_ => blk: {
                    const amount = (f.value.get(307) orelse break :blk std.fmt.bufPrint(&line, "${d} = struct", .{f.key}) catch continue).number() orelse 0;
                    const unit = if (f.value.get(306)) |u| u.symbol() orelse 0 else 0;
                    break :blk std.fmt.bufPrint(&line, "${d} = {d:.3} ${d}", .{ f.key, amount, unit }) catch continue;
                },
                .string => std.fmt.bufPrint(&line, "${d} = string", .{f.key}) catch continue,
                else => std.fmt.bufPrint(&line, "${d} = {s}", .{ f.key, @tagName(f.value.kind) }) catch continue,
            };
            var found = false;
            for (seen[0..used], counts[0..used]) |*k, *n| {
                if (std.mem.eql(u8, std.mem.sliceTo(k, 0), desc)) {
                    n.* += 1;
                    found = true;
                    break;
                }
            }
            if (!found and used < seen.len) {
                @memset(&seen[used], 0);
                @memcpy(seen[used][0..desc.len], desc);
                counts[used] = 1;
                used += 1;
            }
        }
    }
    for (seen[0..used], counts[0..used]) |*k, n| print("{d:>4}  {s}\n", .{ n, std.mem.sliceTo(k, 0) });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const argv = init.args.vector;
    if (argv.len < 2) return error.Usage;
    const data = try core.file.map(argv[1]);
    if (argv.len > 2 and std.mem.eql(u8, std.mem.sliceTo(argv[2], 0), "styles")) return style_summary(data);
    if (argv.len > 3 and std.mem.eql(u8, std.mem.sliceTo(argv[2], 0), "dump")) {
        // Writes one raw media entity's bytes to stdout, for testing decoders.
        const want_id = try std.fmt.parseInt(u32, std.mem.sliceTo(argv[3], 0), 10);
        var all = try core.kfx.entities(data);
        while (all.next()) |e| {
            if (e.kind != 417 or e.id != want_id) continue;
            const hdr = std.mem.readInt(u32, e.raw[6..10], .little);
            _ = std.os.linux.write(1, e.raw[hdr..].ptr, e.raw.len - hdr);
        }
        return;
    }
    if (argv.len > 2 and std.mem.eql(u8, std.mem.sliceTo(argv[2], 0), "media")) {
        // Raw media: id, size, header length and first bytes; resources: id, format, size, location length.
        var all = try core.kfx.entities(data);
        while (all.next()) |e| {
            if (e.kind == 417) {
                const hdr = if (e.raw.len >= 10) std.mem.readInt(u32, e.raw[6..10], .little) else 0;
                const body = if (hdr < e.raw.len) e.raw[hdr..] else "";
                print("media ${d}: {d} bytes, header {d}, starts {x}\n", .{ e.id, e.raw.len, hdr, body[0..@min(8, body.len)] });
            }
            if (e.kind == 164) {
                const v = core.kfx.entity_value(e.raw) orelse continue;
                const fmt = if (v.get(161)) |f| f.symbol() orelse 0 else 0;
                const loc = if (v.get(165)) |l| l.text() orelse "" else "";
                print("resource ${d}: format ${d}, {d}x{d}, location {d} chars\n", .{ e.id, fmt, if (v.get(422)) |x| x.int else 0, if (v.get(423)) |x| x.int else 0, loc.len });
            }
        }
        return;
    }
    var counts: [2048]u32 = @splat(0);
    var it = try core.kfx.entities(data);
    const want: ?u32 = if (argv.len > 2) try std.fmt.parseInt(u32, std.mem.sliceTo(argv[2], 0), 10) else null;
    const max: usize = if (argv.len > 3) try std.fmt.parseInt(usize, std.mem.sliceTo(argv[3], 0), 10) else 2;
    var shown: usize = 0;
    while (it.next()) |e| {
        if (e.kind < counts.len) counts[e.kind] += 1;
        if (want != null and e.kind == want.? and shown < max) {
            shown += 1;
            print("entity ${d} type ${d}: ", .{ e.id, e.kind });
            if (core.kfx.entity_value(e.raw)) |v| shape(v, 0, 4) else print("(not ion, {d} bytes)\n", .{e.raw.len});
        }
    }
    if (want == null) {
        for (counts, 0..) |n, k| {
            if (n > 0) print("type ${d}: {d}\n", .{ k, n });
        }
    }
}
