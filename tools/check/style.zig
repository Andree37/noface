//! Checks the rules of docs/TIGER_STYLE.md that a program can check, over every Zig
//! file in src/, tools/ and build.zig, and every script that isn't Zig.
//!
//!   style <repo root> check     Fails if any file breaks a rule more than the
//!                               baseline allows, or less (so progress is locked in).
//!   style <repo root> baseline  Writes the baseline from what's there now, but only
//!                               if no count went up.
//!
//! The baseline (tools/check/style_baseline.txt) lists, per rule and file, how many
//! times the code broke the rule when this check was introduced. It can only shrink:
//! new code must follow every rule from its first line, and old code is brought in
//! line file by file. Once a count reaches zero its line goes, and the rule holds there
//! for good.
const std = @import("std");
const assert = std.debug.assert;

pub const Rule = enum {
    /// A line over 100 columns: two files side by side must fit on a screen.
    line_length,
    /// A function over 70 lines, signature to closing brace: it must fit on a screen.
    function_length,
    /// A function named in camelCase: functions are snake_case, as variables and files
    /// are. A function returning a type keeps TitleCase, as Zig has it.
    function_name,
    /// Fewer than two assertions per function, counted per file: the shortfall.
    assertion_density,
    /// A function that calls itself: every execution must be bounded.
    recursion,
    /// `assert(a and b)`: split it, so a failure says which part broke.
    compound_assertion,
    /// An `if` or `else` whose body is on the next line without braces.
    if_without_braces,
    /// `catch {}` or `catch unreachable`: every error is handled, or its being
    /// impossible is asserted with a reason.
    error_ignored,
    /// A comment without a space after `//`, or whose first sentence doesn't start
    /// with a capital letter.
    comment_style,
    /// `while (true)`: every loop has a bound, or asserts why it has none.
    loop_unbounded,
    /// `usize`: sizes are explicit (u32, u64), except where the language needs usize
    /// (slice indexes and lengths).
    usize_used,
    /// A script that isn't Zig: tooling is Zig, so it runs the same everywhere.
    script_not_zig,
};

pub const rule_count = @typeInfo(Rule).@"enum".field_names.len;

pub const line_columns_max = 100;
pub const function_lines_max = 70;
pub const assertions_per_function_min = 2;

comptime {
    assert(line_columns_max == 100);
    assert(function_lines_max == 70);
    assert(assertions_per_function_min >= 2);
}

/// How many times each rule is broken in one file.
pub const Counts = [rule_count]u32;

/// One line of a Zig file, seen as code: its text with strings, characters and
/// comments blanked out, so braces and keywords in them don't count.
const Line = struct {
    text: []const u8, // As written
    code: []const u8, // Code only
    comment: []const u8, // The comment, from its `//`, or empty
};

/// Blanks strings, character literals and the comment out of `text` into `buffer`.
fn split_line(text: []const u8, buffer: []u8) Line {
    assert(buffer.len >= text.len);
    const trimmed = std.mem.trimStart(u8, text, " ");
    // A line of a multiline string is all string
    if (std.mem.startsWith(u8, trimmed, "\\\\")) {
        return .{ .text = text, .code = "", .comment = "" };
    }
    var index: u32 = 0;
    var in_string = false;
    var in_char = false;
    var comment_start: ?u32 = null;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        buffer[index] = c;
        if (in_string or in_char) {
            buffer[index] = ' ';
            if (c == '\\' and index + 1 < text.len) {
                index += 1;
                buffer[index] = ' ';
            } else if (in_string and c == '"') {
                in_string = false;
            } else if (in_char and c == '\'') {
                in_char = false;
            }
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '\'') {
            in_char = true;
        } else if (c == '/' and index + 1 < text.len and text[index + 1] == '/') {
            comment_start = index;
            break;
        }
    }
    const end = comment_start orelse @as(u32, @intCast(text.len));
    return .{
        .text = text,
        .code = buffer[0..end],
        .comment = if (comment_start) |start| text[start..] else "",
    };
}

fn columns(text: []const u8) u32 {
    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @intCast(count);
}

fn is_snake_case(name: []const u8) bool {
    for (name) |c| {
        if (std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// The name of the function a line declares, if it declares one.
fn function_name(code: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, code, " ");
    const prefixes = [_][]const u8{ "pub ", "export ", "extern ", "inline ", "noinline " };
    var stripped = true;
    while (stripped) {
        stripped = false;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, rest, prefix)) {
                rest = rest[prefix.len..];
                stripped = true;
            }
        }
    }
    if (!std.mem.startsWith(u8, rest, "fn ")) return null;
    rest = rest["fn ".len..];
    const end = std.mem.indexOfScalar(u8, rest, '(') orelse return null;
    const name = std.mem.trim(u8, rest[0..end], " ");
    if (name.len == 0) return null;
    return name;
}

fn count_braces(code: []const u8) i32 {
    var depth: i32 = 0;
    for (code) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
    }
    return depth;
}

fn count_token(code: []const u8, token: []const u8) u32 {
    var count: u32 = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, code, at, token)) |index| {
        at = index + token.len;
        const before_ok = index == 0 or !is_word(code[index - 1]);
        const after_ok = at >= code.len or !is_word(code[at]) or !is_word(token[token.len - 1]);
        if (before_ok and after_ok) count += 1;
    }
    return count;
}

fn is_word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// How many assertions a line makes: `assert(`, `check.that(`, `check.thatf(`, and
/// compile-time `@compileError(`, which asserts at build time.
fn count_assertions(code: []const u8) u32 {
    return count_token(code, "assert(") + count_token(code, "that(") +
        count_token(code, "thatf(") + count_token(code, "@compileError(");
}

/// Whether an assertion on this line joins conditions with `and` at its top level.
fn has_compound_assertion(code: []const u8) bool {
    const openers = [_][]const u8{ "assert(", "that(", "thatf(" };
    for (openers) |opener| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, code, at, opener)) |index| {
            at = index + opener.len;
            if (index > 0 and is_word(code[index - 1])) continue;
            if (top_level_and(code[at..])) return true;
        }
    }
    return false;
}

/// Whether the first argument of a call, from just after its `(`, has a top-level `and`.
fn top_level_and(arguments: []const u8) bool {
    var depth: i32 = 0;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const c = arguments[index];
        if (c == '(' or c == '[' or c == '{') depth += 1;
        if (c == ')' or c == ']' or c == '}') {
            if (depth == 0) return false;
            depth -= 1;
        }
        if (depth == 0 and c == ',') return false;
        if (depth == 0 and std.mem.startsWith(u8, arguments[index..], " and ")) return true;
    }
    return false;
}

/// Whether a line is an `if (…)`, `else` or `else if (…)` whose body follows on the
/// next line without braces.
fn opens_unbraced(code: []const u8) bool {
    const line = std.mem.trim(u8, code, " ");
    if (line.len == 0) return false;
    if (std.mem.eql(u8, line, "else")) return true;
    const starts_if = std.mem.startsWith(u8, line, "if (") or std.mem.startsWith(u8, line, "} else if (") or
        std.mem.startsWith(u8, line, "else if (");
    if (!starts_if) return false;
    // Ends right after its condition (and capture): the body is on the next line
    if (line[line.len - 1] == ')') return balanced(line);
    if (line[line.len - 1] == '|') {
        const capture = std.mem.lastIndexOf(u8, line[0 .. line.len - 1], "|") orelse return false;
        return line[capture - 1] == ' ' and line[capture - 2] == ')' and balanced(line[0 .. capture - 1]);
    }
    return false;
}

fn balanced(text: []const u8) bool {
    var depth: i32 = 0;
    for (text) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
    }
    return depth == 0;
}

fn bad_comment(comment: []const u8, previous_was_comment: bool) bool {
    if (comment.len == 0) return false;
    // `///` and `//!` are doc comments; their text follows the third character
    const marker: usize = if (comment.len > 2 and (comment[2] == '/' or comment[2] == '!')) 3 else 2;
    const body = comment[marker..];
    if (body.len == 0) return false; // An empty comment line, between paragraphs
    if (body[0] != ' ') return true;
    if (previous_was_comment) return false; // A sentence carried on from the line above
    const first = std.mem.trimStart(u8, body, " ");
    if (first.len == 0) return false;
    return std.ascii.isLower(first[0]);
}

/// Counts the rules broken in one Zig file.
pub fn check_zig(source: []const u8, gpa: std.mem.Allocator) !Counts {
    var counts: Counts = @splat(0);
    const buffer = try gpa.alloc(u8, source.len);
    defer gpa.free(buffer);

    var functions: u32 = 0;
    var assertions: u32 = 0;
    var depth: i32 = 0;
    var test_depth: ?i32 = null; // Inside a test block: its depth
    var open: ?struct { name: []const u8, start_line: u32, depth: i32 } = null;
    var previous_comment = false;
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| : (line_number += 1) {
        const line = split_line(text, buffer[@intFromPtr(text.ptr) - @intFromPtr(source.ptr) ..]);
        const trimmed = std.mem.trimStart(u8, line.code, " ");
        if (columns(text) > line_columns_max) counts[@backingInt(Rule.line_length)] += 1;
        const own_line_comment = line.comment.len > 0 and trimmed.len == 0;
        if (bad_comment(line.comment, previous_comment and own_line_comment)) {
            counts[@backingInt(Rule.comment_style)] += 1;
        }
        previous_comment = own_line_comment;

        const in_test = test_depth != null;
        if (!in_test and (std.mem.startsWith(u8, trimmed, "test \"") or std.mem.startsWith(u8, trimmed, "test {"))) {
            test_depth = depth;
        }
        if (test_depth == null) {
            if (function_name(line.code)) |name| {
                functions += 1;
                const returns_type = std.mem.indexOf(u8, line.code, ") type") != null;
                if (!returns_type and !is_snake_case(name)) counts[@backingInt(Rule.function_name)] += 1;
                if (open == null and std.mem.indexOfScalar(u8, line.code, '{') != null) {
                    open = .{ .name = name, .start_line = line_number, .depth = depth };
                }
            } else if (open) |f| {
                const call = try std.fmt.allocPrint(gpa, "{s}(", .{f.name});
                defer gpa.free(call);
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, line.code, at, call)) |index| {
                    at = index + call.len;
                    const before = if (index == 0) ' ' else line.code[index - 1];
                    if (!is_word(before) and before != '.') {
                        counts[@backingInt(Rule.recursion)] += 1;
                    }
                }
            }
            assertions += count_assertions(line.code);
            if (has_compound_assertion(line.code)) counts[@backingInt(Rule.compound_assertion)] += 1;
            if (opens_unbraced(line.code)) counts[@backingInt(Rule.if_without_braces)] += 1;
            counts[@backingInt(Rule.error_ignored)] += count_token(line.code, "catch {}") +
                count_token(line.code, "catch unreachable");
            counts[@backingInt(Rule.loop_unbounded)] += count_token(line.code, "while (true)");
            counts[@backingInt(Rule.usize_used)] += count_token(line.code, "usize");
        }
        depth += count_braces(line.code);
        if (open) |f| {
            if (depth <= f.depth) {
                const length = line_number - f.start_line + 1;
                if (length > function_lines_max) counts[@backingInt(Rule.function_length)] += 1;
                open = null;
            }
        }
        if (test_depth) |d| {
            if (depth <= d) test_depth = null; // Its closing brace
        }
    }
    const wanted = functions * assertions_per_function_min;
    counts[@backingInt(Rule.assertion_density)] = wanted -| assertions;
    return counts;
}

/// One line of the baseline: a rule, a file, and how many times it may break it.
pub const Entry = struct { rule: Rule, path: []const u8, count: u32 };

pub fn parse_baseline(text: []const u8, gpa: std.mem.Allocator) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const rule_name = words.next() orelse continue;
        const count_text = words.next() orelse return error.BadBaseline;
        const path = words.next() orelse return error.BadBaseline;
        const rule = std.meta.stringToEnum(Rule, rule_name) orelse return error.BadBaseline;
        const count = std.fmt.parseInt(u32, count_text, 10) catch return error.BadBaseline;
        try entries.append(gpa, .{ .rule = rule, .path = path, .count = count });
    }
    return entries.items;
}

fn allowed(entries: []const Entry, rule: Rule, path: []const u8) u32 {
    for (entries) |e| {
        if (e.rule == rule and std.mem.eql(u8, e.path, path)) return e.count;
    }
    return 0;
}

const Found = struct { path: []const u8, counts: Counts };

const baseline_path = "tools/check/style_baseline.txt";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.Usage;
    const io = init.io;
    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer root.close(io);
    const write_baseline = std.mem.eql(u8, args[2], "baseline");

    var found: std.ArrayList(Found) = .empty;
    for ([_][]const u8{ "src", "tools", "device" }) |folder| {
        var dir = try root.openDir(io, folder, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, entry.path });
            var counts: Counts = @splat(0);
            if (std.mem.endsWith(u8, path, ".zig")) {
                const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(8 << 20));
                counts = try check_zig(source, gpa);
            } else if (std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".py")) {
                counts[@backingInt(Rule.script_not_zig)] = 1;
            } else continue;
            try found.append(gpa, .{ .path = path, .counts = counts });
        }
    }
    const build_source = try root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20));
    try found.append(gpa, .{ .path = "build.zig", .counts = try check_zig(build_source, gpa) });
    std.mem.sort(Found, found.items, {}, struct {
        fn before(_: void, a: Found, b: Found) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.before);

    const baseline_text = root.readFileAlloc(io, baseline_path, gpa, .limited(4 << 20)) catch "";
    const entries = try parse_baseline(baseline_text, gpa);

    var out: std.ArrayList(u8) = .empty;
    var worse: u32 = 0;
    var better: u32 = 0;
    var totals: Counts = @splat(0);
    for (found.items) |f| {
        for (f.counts, 0..) |count, i| {
            const rule: Rule = @fromBackingInt(@intCast(i));
            const limit = allowed(entries, rule, f.path);
            totals[i] += count;
            if (count > limit) {
                worse += 1;
                try out.print(gpa, "{s}: {s} {d}, allowed {d}\n", .{ f.path, @tagName(rule), count, limit });
            } else if (count < limit) {
                better += 1;
            }
        }
    }
    if (write_baseline) {
        // The very first baseline records the debt as found; after that, it only shrinks
        if (worse > 0 and baseline_text.len > 0) {
            std.debug.print("{s}baseline not written: the code above breaks rules more than before\n", .{out.items});
            std.process.exit(1);
        }
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(gpa, "# Tiger Style debt: rule, times broken, file. It may only shrink; see docs/TIGER_STYLE.md.\n");
        for (found.items) |f| {
            for (f.counts, 0..) |count, i| {
                if (count == 0) continue;
                try text.print(gpa, "{s} {d} {s}\n", .{ @tagName(@as(Rule, @fromBackingInt(@intCast(i)))), count, f.path });
            }
        }
        try root.writeFile(io, .{ .sub_path = baseline_path, .data = text.items });
        std.debug.print("baseline written\n", .{});
        return;
    }
    if (worse > 0) {
        std.debug.print("{s}{d} breaks a Tiger Style rule more than allowed (docs/TIGER_STYLE.md)\n", .{ out.items, worse });
        std.process.exit(1);
    }
    if (better > 0) {
        std.debug.print("{d} counts went down: run `zig build style-baseline` to lock that in\n", .{better});
        std.process.exit(1);
    }
    std.debug.print("style ok, debt left:", .{});
    for (totals, 0..) |t, i| {
        if (t > 0) std.debug.print(" {s} {d}", .{ @tagName(@as(Rule, @fromBackingInt(@intCast(i)))), t });
    }
    std.debug.print("\n", .{});
}

fn check_text(source: []const u8) !Counts {
    return check_zig(source, std.testing.allocator);
}

fn count_of(counts: Counts, rule: Rule) u32 {
    return counts[@backingInt(rule)];
}

test "long lines and camelCase functions count; type functions keep their case" {
    const source =
        \\fn goodName() void {}
        \\fn good_name() void {}
        \\fn Step(comptime T: type) type {
        \\    return T;
        \\}
        \\const x = "a very long string literal that goes on and on and on past one hundred columns, surely, it does";
    ;
    const counts = try check_text(source);
    try std.testing.expectEqual(@as(u32, 1), count_of(counts, .function_name));
    try std.testing.expectEqual(@as(u32, 1), count_of(counts, .line_length));
}

test "assertions are counted against functions" {
    const two =
        \\fn f(a: u32) u32 {
        \\    assert(a > 0);
        \\    check.that(a < 9, "small");
        \\    return a;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), count_of(try check_text(two), .assertion_density));
    const none = "fn f() void {}\nfn g() void {}\n";
    try std.testing.expectEqual(@as(u32, 4), count_of(try check_text(none), .assertion_density));
}

test "tests don't count as functions or toward any rule" {
    const source =
        \\test "x" {
        \\    const a = 1;
        \\    while (true) {}
        \\}
    ;
    const counts = try check_text(source);
    try std.testing.expectEqual(@as(u32, 0), count_of(counts, .assertion_density));
    try std.testing.expectEqual(@as(u32, 0), count_of(counts, .loop_unbounded));
}

test "compound assertions, unbraced ifs, ignored errors and recursion count" {
    const source =
        \\fn walk(n: u32) u32 {
        \\    assert(n > 0 and n < 9);
        \\    assert(n > 0);
        \\    if (n == 1)
        \\        return 1;
        \\    foo() catch {};
        \\    return walk(n - 1);
        \\}
    ;
    const counts = try check_text(source);
    try std.testing.expectEqual(@as(u32, 1), count_of(counts, .compound_assertion));
    try std.testing.expectEqual(@as(u32, 1), count_of(counts, .if_without_braces));
    try std.testing.expectEqual(@as(u32, 1), count_of(counts, .error_ignored));
    try std.testing.expectEqual(@as(u32, 1), count_of(counts, .recursion));
}

test "comments start with a capital after a space; a continued sentence needn't" {
    const source =
        \\// A sentence that goes
        \\// on to the next line.
        \\//no space
        \\// lowercase start
        \\const a = 1; // a phrase after code is fine
    ;
    try std.testing.expectEqual(@as(u32, 2), count_of(try check_text(source), .comment_style));
}

test "long functions count" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "fn long() void {\n");
    for (0..70) |_| try source.appendSlice(std.testing.allocator, "    _ = 1;\n");
    try source.appendSlice(std.testing.allocator, "}\n");
    try std.testing.expectEqual(@as(u32, 1), count_of(try check_text(source.items), .function_length));
}

test "braces and keywords inside strings and comments don't count" {
    const source =
        \\fn f() void {
        \\    const s = "{ while (true) }";
        \\    // while (true) {
        \\}
    ;
    const counts = try check_text(source);
    try std.testing.expectEqual(@as(u32, 0), count_of(counts, .loop_unbounded));
}

test "the baseline reads back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parse_baseline("# note\nline_length 3 src/a.zig\n", arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(Rule.line_length, entries[0].rule);
    try std.testing.expectEqual(@as(u32, 3), allowed(entries, .line_length, "src/a.zig"));
    try std.testing.expectEqual(@as(u32, 0), allowed(entries, .line_length, "src/b.zig"));
}
