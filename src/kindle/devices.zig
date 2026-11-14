//! Finding the Kindle's hardware at startup instead of assuming one model's: the touch
//! panel, the power button, the battery and the charger, from what Linux says about
//! each device. Kindles name and number these differently from model to model.
const std = @import("std");
const state = @import("../sys/state.zig");

/// Whether bit `bit` is set in a sysfs capability mask: hex words separated by spaces,
/// the most significant first, each as wide as a kernel `long`.
pub fn has_bit(mask: []const u8, bit: usize) bool {
    const word_bits = @bitSizeOf(usize);
    var words: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, mask, " \n");
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    const index = bit / word_bits;
    if (index >= n) return false;
    const word = std.fmt.parseInt(usize, words[n - 1 - index], 16) catch return false;
    return (word >> @intCast(bit % word_bits)) & 1 == 1;
}

const abs_mt_position_x = 0x35;
const key_power = 116;

pub const Input = struct { path: [24]u8 = undefined, len: usize = 0, name: [64]u8 = undefined, name_len: usize = 0 };

fn read(comptime fmt: []const u8, args: anytype, buf: []u8) []const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, fmt, args, 0) catch return "";
    return std.mem.trim(u8, state.read_small(path, buf), " \n");
}

/// Which kind of input device eventN is: the touch panel reports multitouch positions,
/// a power button reports the power key. Virtual devices that claim every key (as
/// "kindle-input-pt" does) don't count as the button.
fn classify(name: []const u8, abs: []const u8, keys: []const u8) enum { touch, power, other } {
    if (has_bit(abs, abs_mt_position_x)) return .touch;
    if (!has_bit(keys, key_power)) return .other;
    var all_bits = true;
    var words = std.mem.tokenizeAny(u8, keys, " \n");
    while (words.next()) |w| all_bits = all_bits and std.mem.allEqual(u8, w, 'f');
    if (all_bits or std.mem.indexOf(u8, name, "input-pt") != null) return .other;
    return .power;
}

pub const Found = struct { touch: ?u8 = null, power: ?u8 = null };

/// The event numbers of the touch panel and the power button.
pub fn find_inputs() Found {
    var found = Found{};
    for (0..16) |i| {
        var name_buf: [96]u8 = undefined;
        var abs_buf: [128]u8 = undefined;
        var key_buf: [512]u8 = undefined;
        const name = read("/sys/class/input/event{d}/device/name", .{i}, &name_buf);
        if (name.len == 0) continue;
        const abs = read("/sys/class/input/event{d}/device/capabilities/abs", .{i}, &abs_buf);
        const keys = read("/sys/class/input/event{d}/device/capabilities/key", .{i}, &key_buf);
        switch (classify(name, abs, keys)) {
            .touch => if (found.touch == null) {
                found.touch = @intCast(i);
            },
            .power => if (found.power == null) {
                found.power = @intCast(i);
            },
            .other => {},
        }
    }
    return found;
}

/// A power supply's role, from its type. USB_WET is a moisture sensor in the port, not
/// a charger, though it says it's online.
pub fn is_charger(kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "USB_WET")) return false;
    return std.mem.startsWith(u8, kind, "USB") or std.mem.eql(u8, kind, "Mains") or std.mem.eql(u8, kind, "Wireless");
}

pub const Power = struct { level: u32, plugged: bool };

/// The battery's level, and whether any charger is plugged in. Null without a battery.
pub fn power() ?Power {
    var names: [12][32]u8 = undefined;
    var lens: [12]usize = undefined;
    const n = list_supplies(&names, &lens);
    var level: ?u32 = null;
    var plugged = false;
    for (names[0..n], lens[0..n]) |*name_buf, len| {
        const name = name_buf[0..len];
        var kind_buf: [32]u8 = undefined;
        var value_buf: [16]u8 = undefined;
        const kind = read("/sys/class/power_supply/{s}/type", .{name}, &kind_buf);
        if (std.mem.eql(u8, kind, "Battery")) {
            if (level == null) level = std.fmt.parseInt(u32, read("/sys/class/power_supply/{s}/capacity", .{name}, &value_buf), 10) catch null;
        } else if (is_charger(kind)) {
            if (std.mem.eql(u8, read("/sys/class/power_supply/{s}/online", .{name}, &value_buf), "1")) plugged = true;
        }
    }
    return .{ .level = level orelse return null, .plugged = plugged };
}

/// The names under /sys/class/power_supply.
fn list_supplies(names: *[12][32]u8, lens: *[12]usize) usize {
    const Into = struct {
        names: *[12][32]u8,
        lens: *[12]usize,
        n: usize = 0,
        fn add(into: *@This(), name: []const u8, _: bool) void {
            if (name[0] == '.' or name.len > 31 or into.n == into.names.len) return;
            @memcpy(into.names[into.n][0..name.len], name);
            into.lens[into.n] = name.len;
            into.n += 1;
        }
    };
    var into = Into{ .names = names, .lens = lens };
    @import("../sys/calls.zig").each_entry("/sys/class/power_supply", &into, Into.add);
    return into.n;
}

test "capability masks read from the right word" {
    // The PW12's touch panel (32-bit words) and power button
    const touch = if (@bitSizeOf(usize) == 32) "2618000 0" else "261800000000000";
    try std.testing.expect(has_bit(touch, abs_mt_position_x));
    try std.testing.expect(!has_bit(touch, 0));
    const pwr = if (@bitSizeOf(usize) == 32) "100000 0 0 0" else "10000000000000 0";
    try std.testing.expect(has_bit(pwr, key_power));
}

test "the touch panel, the power button, and a device that claims every key" {
    const touch = if (@bitSizeOf(usize) == 32) "2618000 0" else "261800000000000";
    const pwr = if (@bitSizeOf(usize) == 32) "100000 0 0 0" else "10000000000000 0";
    try std.testing.expectEqual(.touch, classify("fts_ts", touch, "400 0 0 0 0 0 0 0 0 0 0"));
    try std.testing.expectEqual(.power, classify("bd71828-pwrkey", "0", pwr));
    try std.testing.expectEqual(.other, classify("kindle-input-pt", "0", "ffffffff ffffffff ffffffff ffffffff"));
}

test "a moisture sensor isn't a charger" {
    try std.testing.expect(is_charger("USB_CDP"));
    try std.testing.expect(is_charger("Mains"));
    try std.testing.expect(!is_charger("USB_WET"));
    try std.testing.expect(!is_charger("Battery"));
}
