//! Writes the table a release's notes open with: each Kindle it carries a zip for, the
//! zip's name, and that it was tested on a real one, as build.zig ships only those
//! that were (`shipped`).
//!
//!   kindles <out.md> <version> <model>...
//!
//! Each model is a src/model/device.zig `Model` name, as the zip is named by.
const std = @import("std");
const assert = std.debug.assert;
const device = @import("core").device;

/// The most Kindles one release carries: every one noface knows.
const models_max = std.meta.fieldNames(device.Model).len;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 4 or args.len - 3 > models_max) {
        std.debug.print("usage: kindles <out.md> <version> <model>...\n", .{});
        std.process.exit(2);
    }
    assert(args.len >= 4);
    var models: [models_max]device.Model = undefined;
    for (args[3..], 0..) |name, index| {
        models[index] = std.meta.stringToEnum(device.Model, name) orelse {
            std.debug.print("kindles: no Kindle is named {s}\n", .{name});
            std.process.exit(2);
        };
    }
    const table = try write(gpa, args[2], models[0 .. args.len - 3]);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = table });
}

/// The table, in Markdown, under its own heading.
fn write(gpa: std.mem.Allocator, version: []const u8, models: []const device.Model) ![]u8 {
    assert(version.len > 0);
    assert(models.len > 0);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, "## Which zip\n\n");
    try out.appendSlice(gpa, "| Kindle | Download | Tested on a real one |\n");
    try out.appendSlice(gpa, "|---|---|---|\n");
    for (models) |model| {
        const row = try std.fmt.allocPrint(gpa, "| {s} | noface-{s}-{s}.zip | Yes |\n", .{
            device.name(model), version, @tagName(model),
        });
        try out.appendSlice(gpa, row);
    }
    try out.appendSlice(gpa, "\n");
    assert(out.items.len > 0);
    return out.items;
}

test "the table names each Kindle, its zip, and that it was tested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = try write(arena.allocator(), "1.2.3", &.{.paperwhite_12});
    const row = "| Kindle Paperwhite (12th generation) | noface-1.2.3-paperwhite_12.zip | Yes |\n";
    try std.testing.expect(std.mem.indexOf(u8, table, row) != null);
    try std.testing.expect(std.mem.startsWith(u8, table, "## Which zip\n"));
}
