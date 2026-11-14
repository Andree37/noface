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
    /// are. A function returning a type keeps TitleCase, as Zig has it, and one copying
    /// a C macro keeps its capitals.
    function_name,
    /// Fewer than two assertions per function, counted per file: the shortfall.
    assertion_density,
    /// A function that calls itself: every execution must be bounded.
    recursion,
    /// `assert(a and b)`: split it, so a failure says which part broke.
    compound_assertion,
    /// An `if` or `else` whose body is on the next line without braces.
    if_without_braces,
    /// `catch {}` or `catch unreachable`: every error is handled. Ignoring one counts as
    /// handling it only with the reason on that line: `catch {}; // Ignored: …`.
    error_ignored,
    /// A comment without a space after `//`, or whose first sentence doesn't start
    /// with a capital letter.
    comment_style,
    /// `while (true)`: every loop has a bound. One that by design never ends (an event
    /// loop) says so in a comment just above it starting `// Unbounded: `, with why.
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
    const line: Line = .{
        .text = text,
        .code = buffer[0..end],
        .comment = if (comment_start) |start| text[start..] else "",
    };
    assert(line.code.len <= line.text.len);
    if (line.comment.len > 0) assert(std.mem.startsWith(u8, line.comment, "//"));
    return line;
}

fn columns(text: []const u8) u32 {
    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    assert(count <= text.len);
    return @intCast(count);
}

/// Whether a function name is snake_case, or all capitals: a C macro's name kept as C
/// has it (`IFEXITED`), so code written against the system's API reads the same.
fn is_snake_case(name: []const u8) bool {
    assert(name.len > 0);
    var lower = false;
    var upper = false;
    for (name) |c| {
        if (std.ascii.isUpper(c)) upper = true;
        if (std.ascii.isLower(c)) lower = true;
    }
    return !(upper and lower);
}

/// The name of the function a line declares, if it declares one.
fn function_name(code: []const u8) ?[]const u8 {
    var rest = std.mem.trimStart(u8, code, " ");
    // A C function declared with `extern` has no body here: nothing to count
    if (std.mem.indexOf(u8, code, "extern ") != null) return null;
    const prefixes = [_][]const u8{ "pub ", "export ", "inline ", "noinline " };
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
    assert(std.mem.indexOfScalar(u8, name, '(') == null);
    return name;
}

/// How much deeper `text` leaves the nesting of `open` and `close`: negative when it
/// closes more than it opens.
fn count_depth(text: []const u8, open: u8, close: u8) i32 {
    assert(open != close);
    var depth: i32 = 0;
    for (text) |c| {
        if (c == open) depth += 1;
        if (c == close) depth -= 1;
    }
    assert(@abs(depth) <= text.len);
    return depth;
}

fn count_token(code: []const u8, token: []const u8) u32 {
    assert(token.len > 0);
    var count: u32 = 0;
    var at: u32 = 0;
    while (std.mem.indexOfPos(u8, code, at, token)) |index| {
        at = @intCast(index + token.len);
        assert(at <= code.len);
        const before_ok = index == 0 or !is_word(code[index - 1]);
        const after_ok = at >= code.len or !is_word(code[at]) or !is_word(token[token.len - 1]);
        if (before_ok and after_ok) count += 1;
    }
    // Matches don't overlap.
    assert(count * token.len <= code.len);
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

/// How many times a line calls the function `name` itself: not a method or field of
/// the same name.
fn count_calls(code: []const u8, name: []const u8, gpa: std.mem.Allocator) !u32 {
    assert(name.len > 0);
    const call = try std.fmt.allocPrint(gpa, "{s}(", .{name});
    defer gpa.free(call);
    var count: u32 = 0;
    var at: u32 = 0;
    while (std.mem.indexOfPos(u8, code, at, call)) |index| {
        at = @intCast(index + call.len);
        const before = if (index == 0) ' ' else code[index - 1];
        if (!is_word(before) and before != '.') count += 1;
    }
    assert(count * call.len <= code.len);
    return count;
}

/// Whether an assertion on this line joins conditions with `and` at its top level.
fn has_compound_assertion(code: []const u8) bool {
    const openers = [_][]const u8{ "assert(", "that(", "thatf(" };
    for (openers) |opener| {
        var at: u32 = 0;
        while (std.mem.indexOfPos(u8, code, at, opener)) |index| {
            at = @intCast(index + opener.len);
            assert(at <= code.len);
            if (index > 0 and is_word(code[index - 1])) continue;
            if (top_level_and(code[at..])) return true;
        }
    }
    return false;
}

/// Whether the first argument of a call, from just after its `(`, has a top-level `and`.
fn top_level_and(arguments: []const u8) bool {
    var depth: i32 = 0;
    for (arguments, 0..) |c, index| {
        if (c == '(' or c == '[' or c == '{') depth += 1;
        if (c == ')' or c == ']' or c == '}') {
            if (depth == 0) return false;
            depth -= 1;
        }
        assert(depth >= 0);
        if (depth == 0 and c == ',') return false;
        if (depth == 0 and std.mem.startsWith(u8, arguments[index..], " and ")) return true;
    }
    return false;
}

/// Whether a line is an `if (…)`, `else` or `else if (…)` whose body follows on the
/// next line without braces. `after_statement` says the line of code before ended a
/// statement (with `;`): only then is a lone `else` a statement's. After a value, it's
/// part of an `if` expression, which takes no braces.
fn opens_unbraced(code: []const u8, after_statement: bool) bool {
    const line = std.mem.trim(u8, code, " ");
    if (line.len == 0) return false;
    if (std.mem.eql(u8, line, "else")) return after_statement;
    const starts_if = std.mem.startsWith(u8, line, "if (") or
        std.mem.startsWith(u8, line, "} else if (") or
        std.mem.startsWith(u8, line, "else if (");
    if (!starts_if) return false;
    // Ends right after its condition (and capture): the body is on the next line
    if (line[line.len - 1] == ')') return count_depth(line, '(', ')') == 0;
    if (line[line.len - 1] == '|') {
        const capture = std.mem.lastIndexOf(u8, line[0 .. line.len - 1], "|") orelse return false;
        // Past the `if (` the line starts with, which has no `|`.
        assert(capture >= "if (".len);
        const condition = line[0 .. capture - 1];
        return line[capture - 1] == ' ' and line[capture - 2] == ')' and
            count_depth(condition, '(', ')') == 0;
    }
    return false;
}

/// Whether a comment breaks the style. One on a line of its own is a sentence (a space
/// after `//`, a capital, unless it carries on the sentence above); one after code may
/// be a phrase, so only the space is asked of it.
fn bad_comment(comment: []const u8, own_line: bool, previous_was_comment: bool) bool {
    if (comment.len == 0) return false;
    assert(std.mem.startsWith(u8, comment, "//"));
    // `///` and `//!` are doc comments; their text follows the third character
    const doc = comment.len > 2 and (comment[2] == '/' or comment[2] == '!');
    const marker: u32 = if (doc) 3 else 2;
    assert(marker <= comment.len);
    const body = comment[marker..];
    if (body.len == 0) return false; // An empty comment line, between paragraphs
    if (body[0] != ' ') return true;
    if (!own_line) return false; // A phrase after code
    if (previous_was_comment) return false; // A sentence carried on from the line above
    const first = std.mem.trimStart(u8, body, " ");
    if (first.len == 0) return false;
    return std.ascii.isLower(first[0]);
}

/// What `check_zig` carries from one line to the next.
const Scan = struct {
    counts: Counts = @splat(0),
    functions: u32 = 0,
    assertions: u32 = 0,
    depth: i32 = 0,
    test_depth: ?i32 = null, // Inside a test block: its depth
    // The functions being read, innermost last: a struct inside a function has its own
    open: [open_max]Function = undefined,
    open_count: u32 = 0,
    previous_comment: bool = false,
    unbounded_next: bool = false,
    after_statement: bool = false, // The last line of code ended with `;`

    /// A function being read: its name, first line, and depth outside it.
    const Function = struct { name: []const u8, start_line: u32, depth: i32 };
    const open_max = 16;
};

/// Counts the rules broken in one Zig file.
pub fn check_zig(source: []const u8, gpa: std.mem.Allocator) !Counts {
    const buffer = try gpa.alloc(u8, source.len);
    defer gpa.free(buffer);
    var scan: Scan = .{};
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| : (line_number += 1) {
        const line = split_line(text, buffer[@intFromPtr(text.ptr) - @intFromPtr(source.ptr) ..]);
        const unbounded_said = check_zig_text(&scan, &line);
        const trimmed = std.mem.trimStart(u8, line.code, " ");
        const test_start = std.mem.startsWith(u8, trimmed, "test \"") or
            std.mem.startsWith(u8, trimmed, "test {");
        if (scan.test_depth == null and test_start) scan.test_depth = scan.depth;
        if (scan.test_depth == null) {
            try check_zig_code(&scan, &line, line_number, unbounded_said, gpa);
        }
        scan.depth += count_depth(line.code, '{', '}');
        close_functions(&scan, line_number);
        if (scan.test_depth) |test_depth| {
            if (scan.depth <= test_depth) scan.test_depth = null; // Its closing brace
        }
    }
    // Even an empty file is one line.
    assert(line_number > 0);
    const wanted = scan.functions * assertions_per_function_min;
    scan.counts[@backingInt(Rule.assertion_density)] = wanted -| scan.assertions;
    assert(scan.counts[@backingInt(Rule.assertion_density)] <= wanted);
    return scan.counts;
}

/// Ends every open function whose closing brace this line holds, counting its length.
fn close_functions(scan: *Scan, line_number: u32) void {
    assert(scan.open_count <= Scan.open_max);
    for (0..Scan.open_max) |_| {
        if (scan.open_count == 0) return;
        const open = scan.open[scan.open_count - 1];
        // A function opens at a depth of zero or more: a file's braces never go below it.
        assert(open.depth >= 0);
        if (scan.depth > open.depth) return;
        assert(open.start_line <= line_number);
        const length = line_number - open.start_line + 1;
        if (length > function_lines_max) scan.counts[@backingInt(Rule.function_length)] += 1;
        scan.open_count -= 1;
    }
}

/// Counts what a line breaks as text: its length and its comment. Returns whether a
/// `// Unbounded:` comment just above it vouches for a loop on it.
fn check_zig_text(scan: *Scan, line: *const Line) bool {
    assert(line.code.len <= line.text.len);
    const counts = &scan.counts;
    const trimmed = std.mem.trimStart(u8, line.code, " ");
    if (columns(line.text) > line_columns_max) counts[@backingInt(Rule.line_length)] += 1;
    const own_line_comment = line.comment.len > 0 and trimmed.len == 0;
    const continued = scan.previous_comment and own_line_comment;
    if (bad_comment(line.comment, own_line_comment, continued)) {
        counts[@backingInt(Rule.comment_style)] += 1;
    }
    scan.previous_comment = own_line_comment;
    // Set by a `// Unbounded:` comment, for the loop on the next line of code
    const unbounded_said = scan.unbounded_next;
    if (own_line_comment) {
        const said = std.mem.trimStart(u8, line.comment, "/ ");
        if (std.mem.startsWith(u8, said, "Unbounded: ")) scan.unbounded_next = true;
    } else if (trimmed.len > 0) {
        scan.unbounded_next = false;
    }
    return unbounded_said;
}

/// Counts what a line of code outside the tests breaks, and the functions and
/// assertions it adds.
fn check_zig_code(
    scan: *Scan,
    line: *const Line,
    line_number: u32,
    unbounded_said: bool,
    gpa: std.mem.Allocator,
) !void {
    assert(scan.test_depth == null);
    const counts = &scan.counts;
    const code = line.code;
    if (function_name(code)) |name| {
        scan.functions += 1;
        const returns_type = std.mem.indexOf(u8, code, ") type") != null;
        if (!returns_type and !is_snake_case(name)) counts[@backingInt(Rule.function_name)] += 1;
        const has_body = std.mem.indexOfScalar(u8, code, '{') != null;
        if (has_body and scan.open_count < Scan.open_max) {
            scan.open[scan.open_count] = .{
                .name = name,
                .start_line = line_number,
                .depth = scan.depth,
            };
            scan.open_count += 1;
        }
    } else if (scan.open_count > 0) {
        // A call to the function being read, from inside it: the innermost one
        const open = scan.open[scan.open_count - 1];
        assert(open.start_line < line_number);
        counts[@backingInt(Rule.recursion)] += try count_calls(code, open.name, gpa);
    }
    scan.assertions += count_assertions(code);
    if (has_compound_assertion(code)) counts[@backingInt(Rule.compound_assertion)] += 1;
    if (opens_unbraced(code, scan.after_statement)) {
        counts[@backingInt(Rule.if_without_braces)] += 1;
    }
    const ending = std.mem.trimEnd(u8, code, " ");
    if (ending.len > 0) scan.after_statement = ending[ending.len - 1] == ';';
    // Ignoring an error is handling it only when the line says why: `// Ignored: …`
    if (!std.mem.startsWith(u8, line.comment, "// Ignored: ")) {
        counts[@backingInt(Rule.error_ignored)] += count_token(code, "catch {}") +
            count_token(code, "catch unreachable");
    }
    // A loop that never ends by design says so just above it: `// Unbounded: …`
    if (!unbounded_said) {
        counts[@backingInt(Rule.loop_unbounded)] += count_token(code, "while (true)");
    }
    counts[@backingInt(Rule.usize_used)] += count_token(code, "usize");
}

/// One line of the baseline: a rule, a file, and how many times it may break it.
pub const Entry = struct { rule: Rule, path: []const u8, count: u32 };

const baseline_header =
    "# Tiger Style debt: rule, times broken, file. It may only shrink; see docs/TIGER_STYLE.md.\n";

comptime {
    // The header is a comment, which reading the baseline skips.
    assert(baseline_header[0] == '#');
}

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
        assert(path.len > 0);
        try entries.append(gpa, .{ .rule = rule, .path = path, .count = count });
    }
    return entries.items;
}

fn allowed(entries: []const Entry, rule: Rule, path: []const u8) u32 {
    assert(path.len > 0);
    for (entries) |e| {
        if (e.rule == rule and std.mem.eql(u8, e.path, path)) return e.count;
    }
    return 0;
}

const Found = struct { path: []const u8, counts: Counts };

/// The one script that isn't counted: KPM, the launcher noface is opened from, runs
/// only a shell file, so device/kpm/launch.sh stays shell (docs/TIGER_STYLE.md). It is
/// accepted only as a shim: its `#!` line, comments, and one line that runs the Zig.
const kpm_shim_path = "device/kpm/launch.sh";
const kpm_shim_code_lines_max = 1;

/// Whether a script is the KPM shim, small enough to stay one.
fn is_kpm_shim(path: []const u8, source: []const u8) bool {
    assert(path.len > 0);
    if (!std.mem.eql(u8, path, kpm_shim_path)) return false;
    var code_lines: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue; // `#!` and comments
        code_lines += 1;
    }
    assert(code_lines <= source.len);
    return code_lines <= kpm_shim_code_lines_max;
}

const baseline_path = "tools/check/style_baseline.txt";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.Usage;
    const io = init.io;
    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer root.close(io);
    const write_baseline = std.mem.eql(u8, args[2], "baseline");

    const found = try find_counts(io, root, gpa);
    const baseline_text = root.readFileAlloc(io, baseline_path, gpa, .limited(4 << 20)) catch "";
    const entries = try parse_baseline(baseline_text, gpa);

    var out: std.ArrayList(u8) = .empty;
    var worse: u32 = 0;
    var better: u32 = 0;
    var totals: Counts = @splat(0);
    for (found) |f| {
        for (f.counts, 0..) |count, i| {
            const rule: Rule = @fromBackingInt(@intCast(i));
            const limit = allowed(entries, rule, f.path);
            totals[i] += count;
            if (count > limit) {
                worse += 1;
                const format = "{s}: {s} {d}, allowed {d}\n";
                try out.print(gpa, format, .{ f.path, @tagName(rule), count, limit });
            } else if (count < limit) {
                better += 1;
            }
        }
    }
    assert(worse + better <= found.len * rule_count);
    if (write_baseline) {
        // The very first baseline records the debt as found; after that, it only shrinks
        if (worse > 0 and baseline_text.len > 0) {
            const message = "baseline not written: the code above breaks rules more than before";
            std.debug.print("{s}{s}\n", .{ out.items, message });
            std.process.exit(1);
        }
        try main_write_baseline(io, root, found, gpa);
        return;
    }
    if (worse > 0) {
        const message = "breaks a Tiger Style rule more than allowed (docs/TIGER_STYLE.md)";
        std.debug.print("{s}{d} {s}\n", .{ out.items, worse, message });
        std.process.exit(1);
    }
    if (better > 0) {
        const message = "counts went down: run `zig build style-baseline` to lock that in";
        std.debug.print("{d} {s}\n", .{ better, message });
        std.process.exit(1);
    }
    std.debug.print("style ok, debt left:", .{});
    for (totals, 0..) |total, i| {
        const rule: Rule = @fromBackingInt(@intCast(i));
        if (total > 0) std.debug.print(" {s} {d}", .{ @tagName(rule), total });
    }
    std.debug.print("\n", .{});
}

/// Every Zig file's counts, and every script's, sorted by path.
fn find_counts(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator) ![]const Found {
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
                const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20));
                if (!is_kpm_shim(path, source)) counts[@backingInt(Rule.script_not_zig)] = 1;
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
    assert(found.items.len > 0);
    // Each file is found once, so the order is strict.
    for (found.items[1..], found.items[0 .. found.items.len - 1]) |f, previous| {
        assert(std.mem.lessThan(u8, previous.path, f.path));
    }
    return found.items;
}

/// Writes the baseline from the counts found: every rule a file breaks, and how often.
fn main_write_baseline(
    io: std.Io,
    root: std.Io.Dir,
    found: []const Found,
    gpa: std.mem.Allocator,
) !void {
    assert(found.len > 0);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, baseline_header);
    for (found) |f| {
        for (f.counts, 0..) |count, i| {
            if (count == 0) continue;
            const rule: Rule = @fromBackingInt(@intCast(i));
            try text.print(gpa, "{s} {d} {s}\n", .{ @tagName(rule), count, f.path });
        }
    }
    assert(std.mem.startsWith(u8, text.items, baseline_header));
    try root.writeFile(io, .{ .sub_path = baseline_path, .data = text.items });
    std.debug.print("baseline written\n", .{});
}

/// How many times `source` breaks `rule`.
fn count_in(source: []const u8, rule: Rule) !u32 {
    const counts = try check_zig(source, std.testing.allocator);
    return counts[@backingInt(rule)];
}

test "long lines and camelCase functions count; type functions keep their case" {
    const long_string: [100]u8 = @splat('a');
    const source =
        \\fn goodName() void {}
        \\fn good_name() void {}
        \\fn IFEXITED() void {}
        \\fn Step(comptime T: type) type {
        \\    return T;
        \\}
        \\
    ++ "const x = \"" ++ long_string ++ "\";";
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .function_name));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .line_length));
}

test "assertions are counted against functions" {
    const two =
        \\fn f(a: u32) u32 {
        \\    assert(a > 0);
        \\    check.that(a < 9, "small");
        \\    return a;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(two, .assertion_density));
    const none = "fn f() void {}\nfn g() void {}\n";
    try std.testing.expectEqual(@as(u32, 4), try count_in(none, .assertion_density));
}

test "tests don't count as functions or toward any rule" {
    const source =
        \\test "x" {
        \\    const a = 1;
        \\    while (true) {}
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .assertion_density));
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .loop_unbounded));
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
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .compound_assertion));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .if_without_braces));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .error_ignored));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .recursion));
}

test "comments start with a capital after a space; a continued sentence needn't" {
    const source =
        \\// A sentence that goes
        \\// on to the next line.
        \\//no space
        \\const b = 2;
        \\// lowercase start
        \\const a = 1; // a phrase after code is fine
    ;
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .comment_style));
}

test "long functions count" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "fn long() void {\n");
    for (0..70) |_| try source.appendSlice(std.testing.allocator, "    _ = 1;\n");
    try source.appendSlice(std.testing.allocator, "}\n");
    try std.testing.expectEqual(@as(u32, 1), try count_in(source.items, .function_length));
}

test "braces and keywords inside strings and comments don't count" {
    const source =
        \\fn f() void {
        \\    const s = "{ while (true) }";
        \\    // while (true) {
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .loop_unbounded));
}

test "the baseline reads back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try parse_baseline("# note\nline_length 3 src/a.zig\n", arena.allocator());
    try std.testing.expect(entries.len == 1);
    try std.testing.expectEqual(Rule.line_length, entries[0].rule);
    try std.testing.expectEqual(@as(u32, 3), allowed(entries, .line_length, "src/a.zig"));
    try std.testing.expectEqual(@as(u32, 0), allowed(entries, .line_length, "src/b.zig"));
}

test "a loop or an ignored error with its reason given doesn't count" {
    const source =
        \\fn f() void {
        \\    // Unbounded: the reader's loop runs until noface quits.
        \\    while (true) {}
        \\    while (true) {}
        \\    g() catch {}; // Ignored: a missing cover only means no picture.
        \\    g() catch {};
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .loop_unbounded));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .error_ignored));
}

test "an if expression's else, a phrase after code, and C declarations don't count" {
    const source =
        \\extern fn ft_open(data: [*]const u8) ?*anyopaque;
        \\fn pick(c: bool) u32 {
        \\    assert(@TypeOf(c) == bool);
        \\    assert(@sizeOf(u32) == 4);
        \\    const x = if (c)
        \\        1
        \\    else
        \\        2;
        \\    return x; // a phrase is fine here
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .if_without_braces));
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .comment_style));
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .assertion_density));
}

test "a function inside a struct inside a function is checked for calling itself" {
    const source =
        \\fn outer() void {
        \\    const S = struct {
        \\        fn inner(n: u32) u32 {
        \\            return inner(n - 1);
        \\        }
        \\    };
        \\    _ = S;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .recursion));
}

test "only KPM's launch.sh may stay shell, and only as a one-line shim" {
    const shim = "#!/bin/sh\n# Why it's shell.\nexec /mnt/us/noface/noface-launch \"$0\"\n";
    try std.testing.expect(is_kpm_shim("device/kpm/launch.sh", shim));
    try std.testing.expect(!is_kpm_shim("device/start.sh", shim));
    const grown = shim ++ "sleep 2\n";
    try std.testing.expect(!is_kpm_shim("device/kpm/launch.sh", grown));
}
