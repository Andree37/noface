//! Finding the Kindle's hardware at startup instead of assuming one model's: the touch
//! panel, the power button, the battery and the charger, from what Linux says about
//! each device. Kindles name and number these differently from model to model.
const std = @import("std");
const assert = std.debug.assert;
const file = @import("../sys/file.zig");
const calls = @import("../sys/calls.zig");
const evdev = @import("input/evdev.zig");

/// A kernel `long`, the width of each word of a capability mask.
const MaskWord = c_ulong;
/// The most bits a mask has: the key mask's, the longest (KEY_CNT).
const mask_bits_max = 768;
/// The input devices looked at: event0 to event15.
const inputs_max = 16;
/// The power supplies looked at, and the longest name kept of each.
const supplies_max = 12;
const supply_name_bytes_max = 31;

comptime {
    // Every bit asked about is inside the words a mask is read into
    assert(evdev.abs_mt_x < mask_bits_max);
    assert(evdev.key_power < mask_bits_max);
    // An event number is kept in a u8
    assert(inputs_max <= std.math.maxInt(u8));
}

/// Whether bit `bit` is set in a sysfs capability mask: hex words separated by spaces,
/// the most significant first, each as wide as a kernel `long`.
/// Counted from the end, where the least significant word is, so a mask of any length
/// reads right.
pub fn has_bit(mask: []const u8, bit: u32) bool {
    const word_bits = @bitSizeOf(MaskWord);
    assert(bit < mask_bits_max);
    const index = bit / word_bits; // Words from the end
    var words = std.mem.splitBackwardsAny(u8, std.mem.trim(u8, mask, " \n"), " \n");
    var seen: u32 = 0;
    // Each turn passes a word, so this ends with the mask
    while (words.next()) |word| {
        if (word.len == 0) continue; // Two spaces: no word between them
        if (seen == index) {
            const value = std.fmt.parseInt(MaskWord, word, 16) catch return false;
            return (value >> @intCast(bit % word_bits)) & 1 == 1;
        }
        seen += 1;
    }
    assert(seen <= index); // Fewer words than the one asked about: not set
    return false;
}

/// A small sysfs file's contents, trimmed, at the path `format` makes of `arguments`.
fn read(comptime format: []const u8, arguments: anytype, buffer: []u8) []const u8 {
    comptime assert(format[0] == '/');
    assert(buffer.len > 0);
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, arguments, 0) catch return "";
    const text = std.mem.trim(u8, file.read_small(path, buffer), " \n");
    assert(text.len <= buffer.len);
    return text;
}

/// Which kind of input device eventN is: the touch panel reports multitouch positions,
/// a power button reports the power key. Virtual devices that claim every key (as
/// "kindle-input-pt" does) don't count as the button.
// Assertions: it reads the kernel's description of a device, which is outside data.
fn classify(name: []const u8, abs: []const u8, keys: []const u8) enum { touch, power, other } {
    if (has_bit(abs, evdev.abs_mt_x)) return .touch;
    if (!has_bit(keys, evdev.key_power)) return .other;
    var all_bits = true;
    var words = std.mem.tokenizeAny(u8, keys, " \n");
    while (words.next()) |word| all_bits = all_bits and std.mem.allEqual(u8, word, 'f');
    if (all_bits or std.mem.indexOf(u8, name, "input-pt") != null) return .other;
    return .power;
}

pub const Found = struct { touch: ?u8 = null, power: ?u8 = null };

/// The event numbers of the touch panel and the power button.
pub fn find_inputs() Found {
    var found = Found{};
    for (0..inputs_max) |number| {
        var name_buffer: [96]u8 = undefined;
        var abs_buffer: [128]u8 = undefined;
        var key_buffer: [512]u8 = undefined;
        const name = read("/sys/class/input/event{d}/device/name", .{number}, &name_buffer);
        if (name.len == 0) continue;
        const abs_format = "/sys/class/input/event{d}/device/capabilities/abs";
        const key_format = "/sys/class/input/event{d}/device/capabilities/key";
        const abs = read(abs_format, .{number}, &abs_buffer);
        const keys = read(key_format, .{number}, &key_buffer);
        switch (classify(name, abs, keys)) {
            .touch => if (found.touch == null) {
                found.touch = @intCast(number);
            },
            .power => if (found.power == null) {
                found.power = @intCast(number);
            },
            .other => {},
        }
    }
    // A device is given one kind only, so the two are never the same one
    if (found.touch) |touch_number| {
        if (found.power) |power_number| assert(touch_number != power_number);
    }
    return found;
}

/// A power supply's role, from its type. USB_WET is a moisture sensor in the port, not
/// a charger, though it says it's online.
pub fn is_charger(kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "USB_WET")) return false;
    const usb = std.mem.startsWith(u8, kind, "USB");
    return usb or std.mem.eql(u8, kind, "Mains") or std.mem.eql(u8, kind, "Wireless");
}

pub const Power = struct { level: u32, plugged: bool };

/// The battery's level, and whether any charger is plugged in. Null without a battery.
pub fn power() ?Power {
    var names: [supplies_max][supply_name_bytes_max + 1]u8 = undefined;
    var lengths: [supplies_max]u8 = undefined;
    const count = list_supplies(&names, &lengths);
    assert(count <= names.len);
    var level: ?u32 = null;
    var plugged = false;
    for (names[0..count], lengths[0..count]) |*name_buffer, length| {
        assert(length <= supply_name_bytes_max);
        const name = name_buffer[0..length];
        var kind_buffer: [32]u8 = undefined;
        var value_buffer: [16]u8 = undefined;
        const kind = read("/sys/class/power_supply/{s}/type", .{name}, &kind_buffer);
        if (std.mem.eql(u8, kind, "Battery")) {
            if (level == null) {
                const capacity_format = "/sys/class/power_supply/{s}/capacity";
                const capacity = read(capacity_format, .{name}, &value_buffer);
                level = std.fmt.parseInt(u32, capacity, 10) catch null;
            }
        } else if (is_charger(kind)) {
            const online = read("/sys/class/power_supply/{s}/online", .{name}, &value_buffer);
            if (std.mem.eql(u8, online, "1")) plugged = true;
        }
    }
    return .{ .level = level orelse return null, .plugged = plugged };
}

/// The names under /sys/class/power_supply, with their lengths; returns how many.
fn list_supplies(
    names: *[supplies_max][supply_name_bytes_max + 1]u8,
    lengths: *[supplies_max]u8,
) u32 {
    const Into = struct {
        names: *[supplies_max][supply_name_bytes_max + 1]u8,
        lengths: *[supplies_max]u8,
        count: u32 = 0,
        fn add(into: *@This(), name: []const u8, _: bool) void {
            // `each_entry` passes no empty names, so there's a first character
            assert(name.len > 0);
            assert(into.count <= into.names.len);
            const hidden = name[0] == '.';
            if (hidden or name.len > supply_name_bytes_max or into.count == into.names.len) {
                return;
            }
            @memcpy(into.names[into.count][0..name.len], name);
            into.lengths[into.count] = @intCast(name.len);
            into.count += 1;
        }
    };
    var into = Into{ .names = names, .lengths = lengths };
    calls.each_entry("/sys/class/power_supply", &into, Into.add);
    assert(into.count <= names.len);
    return into.count;
}

test "capability masks read from the right word" {
    // The PW12's touch panel (32-bit words) and power button
    const touch = if (@bitSizeOf(usize) == 32) "2618000 0" else "261800000000000";
    try std.testing.expect(has_bit(touch, evdev.abs_mt_x));
    try std.testing.expect(!has_bit(touch, 0));
    const pwr = if (@bitSizeOf(usize) == 32) "100000 0 0 0" else "10000000000000 0";
    try std.testing.expect(has_bit(pwr, evdev.key_power));
    // A mask longer than sixteen words (a 32-bit Kindle's key mask has 24), a key set
    // in its first: the power key is still read from its word from the end
    const long = if (@bitSizeOf(usize) == 32)
        "1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100000 0 0 0"
    else
        "1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 10000000000000 0";
    try std.testing.expect(has_bit(long, evdev.key_power));
    try std.testing.expect(!has_bit(long, evdev.key_power + 1));
}

test "the touch panel, the power button, and a device that claims every key" {
    const touch = if (@bitSizeOf(usize) == 32) "2618000 0" else "261800000000000";
    const pwr = if (@bitSizeOf(usize) == 32) "100000 0 0 0" else "10000000000000 0";
    const every_key = "ffffffff ffffffff ffffffff ffffffff";
    try std.testing.expectEqual(.touch, classify("fts_ts", touch, "400 0 0 0 0 0 0 0 0 0 0"));
    try std.testing.expectEqual(.power, classify("bd71828-pwrkey", "0", pwr));
    try std.testing.expectEqual(.other, classify("kindle-input-pt", "0", every_key));
}

test "a moisture sensor isn't a charger" {
    try std.testing.expect(is_charger("USB_CDP"));
    try std.testing.expect(is_charger("Mains"));
    try std.testing.expect(!is_charger("USB_WET"));
    try std.testing.expect(!is_charger("Battery"));
}
