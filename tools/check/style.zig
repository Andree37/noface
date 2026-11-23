//! Checks the rules of docs/TIGER_STYLE.md that a program can check, over every Zig
//! file in src/, tools/ and build.zig, and every script that isn't Zig.
//!
//!   style <repo root>   Lists every break, by file and line, and fails if there's one.
//!
//! Nothing is allowed for: every rule holds in every file. The few genuine exceptions
//! are marked in the code where they are, with the reason, and the check accepts those
//! markers and nothing else:
//!
//!   `// Unbounded: …`   just above a loop that by design never ends;
//!   `// Ignored: …`     on the line of an error that may be ignored;
//!   `// usize: …`       on a line (or just above it) whose usize the language, C or
//!                       the kernel's ABI needs;
//!   `// Assertions: …`  just above a function that can't honestly make two assertions;
//!   `// Not a size: …`  on a line of the screens' code (or just above it) whose number
//!                       isn't a length on the screen: a step of a setting, a row's
//!                       place in a list, a test page's own size.
//!
//! A marker with nothing to excuse is a break too, so none outlives its reason.
const std = @import("std");
const assert = std.debug.assert;

pub const Rule = enum {
    /// A line over 100 columns: two files side by side must fit on a screen.
    line_length,
    /// A function over 70 lines, signature to closing brace: it must fit on a screen.
    function_length,
    /// A function named in camelCase: functions are snake_case, as variables and files
    /// are. A function returning a type keeps TitleCase, as Zig has it, one copying
    /// a C macro keeps its capitals, and one the standard library looks up in the
    /// program's root by name (`handleSegfault`) is named as it asks.
    function_name,
    /// Fewer than two assertions per function on average, over a file. Each function
    /// below two is listed, as the places to add them. One that can't honestly make
    /// two says why in a comment just above it starting `// Assertions: `, and is left
    /// out of the average.
    assertion_density,
    /// A function that calls itself: every execution must be bounded.
    recursion,
    /// `assert(a and b)`: split it, so a failure says which part broke.
    compound_assertion,
    /// An assertion of what the line of code above just made true, so it can never
    /// fail and only pads the count: `x = v;` then `assert(x == v);`, or `if (c)
    /// return …;` (or `continue`, `break`) then `assert(!c);` or, for one comparison,
    /// its opposite.
    assertion_restated,
    /// `x == true` or `x == false`: on a bool it says nothing `x` doesn't; on an
    /// optional one (`?bool`, a question the Kindle may not answer) it quietly decides
    /// what no answer means. Say so: `x orelse false`, with why.
    bool_compared,
    /// An `if` or `else` whose body is on the next line without braces.
    if_without_braces,
    /// `catch {}` or `catch unreachable`, or a system call's result thrown away
    /// (`_ = linux.close(fd)`): every error is handled. Ignoring one counts as handling
    /// it only with the reason, on that line or the comment just above it:
    /// `catch {}; // Ignored: …`.
    error_ignored,
    /// A comment without a space after `//`, or whose first sentence doesn't start
    /// with a capital letter.
    comment_style,
    /// `while (true)`: every loop has a bound. One that by design never ends (an event
    /// loop) says so in a comment just above it starting `// Unbounded: `, with why.
    loop_unbounded,
    /// `usize`: sizes are explicit (u32, u64). Where the language, C or the kernel's ABI
    /// needs a usize, a comment on that line or just above it starting `// usize: `
    /// says which.
    usize_used,
    /// A script that isn't Zig: tooling is Zig, so it runs the same everywhere.
    script_not_zig,
    /// A `// Unbounded: `, `// usize: ` or `// Assertions: ` marker with nothing below
    /// (or on its line) for it to excuse.
    marker_unused,
    /// An `@import` inside a function, a test or an expression: a file's imports are all
    /// at its top, where a reader sees what it depends on. `_ = @import(…)`, which only
    /// lists a file's tests, is the exception.
    import_inline,
    /// A file's import that nothing in it uses.
    import_unused,
    /// A bare number of 3 or more for a size in the screens' code (see `is_layout`):
    /// in a declaration named like one (a width, a gap, an inset…), or given to a drawing
    /// call. Sizes come from style.zig's scale, in points, so they're the same on every
    /// Kindle; there, and in the icons' own grid, numbers are the point. A divisor
    /// (sharing room), an array's length, a number in an assertion, a number times a
    /// dotted name (a count of a size named elsewhere), and one marked `// Not a size:
    /// …` are left alone.
    layout_number,
};

pub const rule_count = @typeInfo(Rule).@"enum".field_names.len;

/// One break of a rule: which, and on which line (counting from 1).
pub const Break = struct { rule: Rule, line: u32 };

pub const line_columns_max = 100;
/// The longest a function is, signature to closing brace, and still left out of the
/// assertion average: five lines of body.
const short_function_lines_max = 7;
pub const function_lines_max = 70;
pub const assertions_per_function_min = 2;

comptime {
    assert(line_columns_max == 100);
    assert(function_lines_max == 70);
    assert(assertions_per_function_min >= 2);
}

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
    // Paired with function_name, which ends the name before its `(`.
    assert(std.mem.indexOfScalar(u8, name, '(') == null);
    var lower = false;
    var upper = false;
    for (name) |c| {
        if (std.ascii.isUpper(c)) upper = true;
        if (std.ascii.isLower(c)) lower = true;
    }
    return !(upper and lower);
}

/// Functions the standard library looks up in a program's root by their own names
/// (`root.debug.handleSegfault`): named as it asks, or it never finds them.
const std_hooks = [_][]const u8{"handleSegfault"};

/// Whether `text` is one of `list`.
fn listed(list: []const []const u8, text: []const u8) bool {
    assert(text.len > 0);
    for (list) |item| {
        if (std.mem.eql(u8, text, item)) return true;
    }
    return false;
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
    assert(name.len < code.len); // At least `fn ` and `(` aren't part of it
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

/// How many times `name` is named in `code` by itself: not after a dot, where it's
/// another thing's field of the same name (`style.cover` names no `cover`).
fn count_name(code: []const u8, name: []const u8) u32 {
    assert(name.len > 0);
    var count: u32 = 0;
    var at: u32 = 0;
    while (std.mem.indexOfPos(u8, code, at, name)) |index| {
        at = @intCast(index + name.len);
        const before_ok = index == 0 or (!is_word(code[index - 1]) and code[index - 1] != '.');
        const after_ok = at >= code.len or !is_word(code[at]);
        if (before_ok and after_ok) count += 1;
    }
    assert(count * name.len <= code.len);
    return count;
}

fn is_word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// How many assertions a line makes: `assert(`, `check.that(`, `check.thatf(`,
/// compile-time `@compileError(`, which asserts at build time, and a call to
/// `invariants()`, the method that asserts what holds of a struct between any two
/// calls (`Input.invariants`). In the scenarios, `expect(` too (see
/// `expects_assert_path`).
fn count_assertions(code: []const u8, expects_assert: bool) u32 {
    const expects = if (expects_assert) count_token(code, "expect(") else 0;
    return count_token(code, "assert(") + count_token(code, "that(") +
        count_token(code, "thatf(") + count_token(code, "@compileError(") +
        count_token(code, "invariants()") + expects;
}

/// Whether `path` lays out the screen: the code in src/ui/, src/screens/, src/layout/,
/// src/gfx/ and src/ itself (the app, its display, its setup), but for the scale
/// itself, the icons, whose shapes are drawn in a grid of their own, and the file
/// formats' decoders, whose numbers are the formats' (JPEG's 8 by 8 blocks, a font's
/// table offsets), not sizes on the screen.
fn is_layout(path: []const u8) bool {
    assert(path.len > 0);
    if (listed(&own_points, path)) return true;
    const screens = std.mem.startsWith(u8, path, "src/ui/") or
        std.mem.startsWith(u8, path, "src/screens/") or
        std.mem.startsWith(u8, path, "src/layout/") or
        std.mem.startsWith(u8, path, "src/gfx/") or is_src_root(path);
    if (!screens) return false;
    return !listed(&layout_exempt, path);
}

/// Files below the interface that lay out in points too, though they may not import
/// the scale (kindle/ may not import ui/): each turns points into pixels with its own
/// `pt(`, so a number given to it is on the scale, and any other is bare.
const own_points = [_][]const u8{"src/kindle/touch.zig"};

/// Whether `path` is a file of src/ itself, in no folder under it.
fn is_src_root(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    const rest = path["src/".len..];
    assert(rest.len > 0);
    return std.mem.indexOfScalar(u8, rest, '/') == null;
}

const layout_exempt = [_][]const u8{
    "src/ui/style.zig",
    "src/ui/icons.zig",
    "src/ui/run_icons.zig",
    "src/gfx/jpeg.zig",
    "src/gfx/png.zig",
    "src/gfx/truetype.zig",
    "src/gfx/cff.zig",
};

/// The words that name a size, as the last part of a declaration's name: `row_gap`,
/// `title_y`; `step_pages` counts pages.
const size_words = [_][]const u8{
    "width",  "height", "top",    "bottom",  "left",     "right",    "inset",  "gap",
    "drop",   "rise",   "reach",  "radius",  "band",     "pad",      "margin", "step",
    "thick",  "stroke", "offset", "below",   "above",    "clear",    "corner", "edge",
    "indent", "outset", "arm",    "spacing", "baseline", "distance", "half",   "px",
    "x",      "y",      "w",      "h",       "zone",     "slop",     "strip",
};

/// The drawing calls a size is given to.
const draw_calls = [_][]const u8{
    "fill_rect(", "pill(", "disc(", "round_rect(", "box_with(", "tint(",
};

/// How many bare sizes a line of the screens' code writes: numbers of 3 or more in a
/// declaration named like a size, or given to a drawing call. A divisor, an array's
/// length and a number in an assertion aren't sizes.
fn bare_sizes(code: []const u8, in_points: bool) u32 {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line
    if (std.mem.indexOf(u8, code, "assert(") != null) return 0;
    if (std.mem.indexOf(u8, code, "parseInt(") != null) return 0; // A number's base
    var draws = false;
    for (draw_calls) |call| draws = draws or std.mem.indexOf(u8, code, call) != null;
    const declares = declares_size(code);
    if (!draws and !declares) return 0;
    const small: u32 = if (declares) @intFromBool(sets_small(code)) else small_arguments(code);
    return big_numbers(code, in_points) + small;
}

/// Whether a size's declaration sets it to a bare 1 or 2: `const edge = 2;`, a length
/// in the screen's pixels that's too small for `big_numbers` to see.
fn sets_small(code: []const u8) bool {
    const equals = std.mem.indexOf(u8, code, " = ") orelse return false;
    const value = std.mem.trim(u8, code[equals + " = ".len ..], " ");
    const end = std.mem.indexOfScalar(u8, value, ';') orelse return false;
    const literal = value[0..end];
    return std.mem.eql(u8, literal, "1") or std.mem.eql(u8, literal, "2");
}

/// Whether the innermost bracket left open in `before` opens a call's arguments
/// (`pill(`), not a group of a sum (`(count - 1)`).
fn in_call_arguments(before: []const u8) bool {
    var depth: u32 = 0;
    var at: u32 = @intCast(before.len);
    // Back a character a pass, to the line's start at most
    while (at > 0) {
        at -= 1;
        if (before[at] == ')') depth += 1;
        if (before[at] != '(') continue;
        if (depth > 0) {
            depth -= 1;
            continue;
        }
        return at > 0 and is_word(before[at - 1]);
    }
    return false;
}

/// How many 1s and 2s a drawing call is given as lengths: an argument of its own, or
/// the last term of one, added or taken off (`r - 2, style.white`). A count of gaps or
/// a last index (`n - 1` inside a sum) ends no argument, so isn't one.
fn small_arguments(code: []const u8) u32 {
    var count: u32 = 0;
    var i: u32 = 1;
    // Each pass moves on by a character
    while (i + 1 < code.len) : (i += 1) {
        const c = code[i];
        if (c != '1' and c != '2') continue;
        if (is_word(code[i - 1]) or code[i - 1] == '.') continue;
        if (is_word(code[i + 1]) or code[i + 1] == '.') continue;
        const before = std.mem.trimEnd(u8, code[0..i], " ");
        const after = std.mem.trimStart(u8, code[i + 1 ..], " ");
        assert(before.len > 0);
        if (after.len == 0) continue;
        const ends_argument = after[0] == ',' or after[0] == ')';
        const last = before[before.len - 1];
        const stands = last == ',' or last == '(' or last == '+' or last == '-';
        // `@divTrunc(w, 2)` shares out, as `/ 2` does; `(count - 1) * gap` counts gaps
        const in_call = in_call_arguments(before);
        if (ends_argument and stands and in_call and !divides_in_call(before)) count += 1;
    }
    return count;
}

/// Whether a line declares a constant or variable named like a size: `const row_gap =`.
fn declares_size(code: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line
    const trimmed = std.mem.trimStart(u8, code, " ");
    assert(trimmed.len <= code.len);
    const after_pub = if (std.mem.startsWith(u8, trimmed, "pub ")) trimmed[4..] else trimmed;
    var rest: []const u8 = after_pub;
    if (std.mem.startsWith(u8, rest, "const ")) {
        rest = rest["const ".len..];
    } else if (std.mem.startsWith(u8, rest, "var ")) {
        rest = rest["var ".len..];
    } else {
        return false;
    }
    var end: u32 = 0;
    while (end < rest.len and is_word(rest[end])) end += 1;
    assert(end <= rest.len);
    const name = rest[0..end];
    const last_start = if (std.mem.lastIndexOfScalar(u8, name, '_')) |at| at + 1 else 0;
    return is_size_word(name[last_start..]);
}

fn is_size_word(word: []const u8) bool {
    for (size_words) |size_word| {
        if (std.mem.eql(u8, word, size_word)) return true;
    }
    return false;
}

/// The decimal numbers of 3 or more on a line that aren't a divisor, a count of a named
/// size from another file or an array's length: `[16]u8`, `/ 4` and
/// `3 * style.fingertip` share out or count, they don't size. `2 * 150` and `100 * n`
/// size, and count.
fn big_numbers(code: []const u8, in_points: bool) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    // Each pass moves on by a character at least
    while (i < code.len) {
        const c = code[i];
        const after_word = i > 0 and (is_word(code[i - 1]) or code[i - 1] == '.');
        if (!std.ascii.isDigit(c) or after_word) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < code.len and (is_word(code[end]) or code[end] == '.')) end += 1;
        assert(end > i);
        const literal = code[i..end];
        // A tone or a flag, in hex, isn't a size
        const hex = std.mem.startsWith(u8, literal, "0x");
        const value = if (hex) 0 else std.fmt.parseFloat(f64, literal) catch 0;
        const before = std.mem.trimEnd(u8, code[0..i], " ");
        const divided = before.len > 0 and before[before.len - 1] == '/';
        // `@divTrunc(x, 3)` and its kind divide too
        const divisor = divided or divides_in_call(before);
        const after = std.mem.trimStart(u8, code[end..], " ");
        assert(after.len <= code.len - end);
        const counts_size = after.len > 0 and after[0] == '*' and
            names_size_elsewhere(std.mem.trimStart(u8, after[1..], " "));
        const length = before.len > 0 and before[before.len - 1] == '[' and
            end < code.len and code[end] == ']';
        // In a file of points of its own, a number given to its `pt(` is on the scale
        const points = in_points and gives_to_pt(before);
        if (value >= 3 and !divisor and !counts_size and !length and !points) count += 1;
        i = end;
    }
    return count;
}

/// Whether the code `before` a number leaves it the first argument of a call to `pt`
/// itself (`pt(48)`, `pt(-36)`), not of one whose name ends with it (`adapt(`).
fn gives_to_pt(before: []const u8) bool {
    const call = std.mem.trimEnd(u8, std.mem.trimEnd(u8, before, "-"), " ");
    if (!std.mem.endsWith(u8, call, "pt(")) return false;
    const name_start = call.len - "pt(".len;
    return name_start == 0 or !is_word(call[name_start - 1]);
}

/// Whether `code` starts with a size named in another file, `style.fingertip` say: a
/// name with a dot in it, which a number times it counts out.
fn names_size_elsewhere(code: []const u8) bool {
    var end: u32 = 0;
    while (end < code.len and (is_word(code[end]) or code[end] == '.')) end += 1;
    assert(end <= code.len);
    const name = code[0..end];
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    return std.mem.indexOfScalar(u8, name, '.') != null;
}

/// Whether the code `before` a number leaves it the second argument of the innermost
/// call still open, and that call is a `@div…`: `@divTrunc(x, 3)`, not `f(@divTrunc(a,
/// b), 3)` nor `@divTrunc(f(a, 3), b)`.
fn divides_in_call(before: []const u8) bool {
    if (before.len == 0 or before[before.len - 1] != ',') return false;
    var depth: u32 = 0;
    var commas: u32 = 0;
    assert(before.len <= std.math.maxInt(u32)); // One line of a file
    var at: u32 = @intCast(before.len);
    // Back to the innermost open bracket, a character a pass
    while (at > 0) {
        at -= 1;
        assert(at < before.len);
        switch (before[at]) {
            ')', ']', '}' => depth += 1,
            '(', '[', '{' => {
                if (depth == 0) {
                    if (before[at] != '(' or commas != 1) return false;
                    const name_end = at;
                    var name_start = name_end;
                    while (name_start > 0 and is_word(before[name_start - 1])) name_start -= 1;
                    assert(name_start <= name_end);
                    if (name_start == 0 or before[name_start - 1] != '@') return false;
                    return std.mem.startsWith(u8, before[name_start..name_end], "div");
                }
                depth -= 1;
            },
            ',' => {
                if (depth == 0) commas += 1;
            },
            else => {},
        }
    }
    return false;
}

/// Whether a line imports somewhere other than at the file's top: an `@import` in
/// its code (strings are blanked in it), on an indented line or after other code on a
/// top-level one. `_ = @import(…)` lists a file's tests, and is left alone.
fn imports_inline(code: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line of the file
    const at = std.mem.indexOf(u8, code, "@import(") orelse return false;
    assert(at < code.len);
    const start = std.mem.trimStart(u8, code, " ");
    if (std.mem.startsWith(u8, start, "_ = @import(")) return false;
    if (start.len != code.len) return true; // Indented: inside a block
    // At the top level, the import is the whole value of a declaration
    const declared = std.mem.startsWith(u8, code, "const ") or
        std.mem.startsWith(u8, code, "pub const ");
    return !declared;
}

/// Whether a top-level line declares an import: its value is an `@import(…)`, maybe
/// followed by a field (`@import("x.zig").T`), and nothing else.
fn declares_import(code: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line of the file
    const at = std.mem.indexOf(u8, code, "= @import(") orelse return false;
    const close = std.mem.indexOfScalarPos(u8, code, at, ')') orelse return false;
    assert(close > at);
    const rest = std.mem.trimEnd(u8, code[close + 1 ..], " ");
    for (rest, 0..) |c, index| {
        const last = index + 1 == rest.len;
        if (last) return c == ';';
        if (c != '.' and c != '_' and !std.ascii.isAlphanumeric(c)) return false;
    }
    return false; // Wrapped onto the next line: not one this check reads
}

/// Whether a top-level line begins what follows a file's imports: a function, a test, a
/// type or a comptime block.
fn starts_body(code: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line of the file
    const openers = [_][]const u8{
        "fn ", "pub fn ", "export fn ", "inline fn ", "test ", "comptime {",
    };
    for (openers) |opener| {
        if (std.mem.startsWith(u8, code, opener)) return true;
    }
    const types = [_][]const u8{
        "= struct", "= extern struct", "= packed struct", "= union", "= enum", "= opaque",
    };
    for (types) |kind| {
        if (std.mem.indexOf(u8, code, kind) != null) return true;
    }
    return false;
}

/// Notes each file-level import (`const name = @import(…)…;`) whose name `code`, the
/// file with its strings blanked, never mentions again.
fn note_unused_imports(scan: *Scan, source: []const u8, code: []const u8) !void {
    assert(code.len == source.len);
    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| : (line_number += 1) {
        if (!std.mem.startsWith(u8, text, "const ")) continue; // `pub` ones are used outside
        const equals = std.mem.indexOf(u8, text, " = @import(") orelse continue;
        const name = text["const ".len..equals];
        assert(name.len > 0);
        // Named only on its own line, where `@import(…).name` names it a second time
        const offset = @intFromPtr(text.ptr) - @intFromPtr(source.ptr);
        const own = count_name(code[offset..][0..text.len], name);
        assert(own >= 1);
        if (count_name(code, name) == own) try scan.note(.import_unused, line_number, 1);
    }
    assert(line_number > 1);
}

/// The scenarios (src/scenarios.zig and the files in src/scenarios/) are tests that
/// also ship, as `noface selftest`: each is a function, not a test block, and states
/// what must hold with `expect`, which reports a failure and goes on to the next
/// scenario, where an assertion would stop the Kindle's selftest at the first. There,
/// `expect(` is the assertion, and counts as one, its conditions split as an
/// assertion's are; a scenario that checks nothing still counts as a function without
/// any.
fn is_scenarios(path: []const u8) bool {
    assert(path.len > 0);
    return std.mem.eql(u8, path, "src/scenarios.zig") or
        std.mem.startsWith(u8, path, "src/scenarios/");
}

/// How many times a line calls the function `name` itself: by its name, or as a method
/// through its first parameter `receiver`, `Self` or `@This()`; not another's method
/// or field of the same name.
fn count_calls(
    code: []const u8,
    name: []const u8,
    receiver: []const u8,
    gpa: std.mem.Allocator,
) !u32 {
    assert(name.len > 0);
    const call = try std.fmt.allocPrint(gpa, "{s}(", .{name});
    defer gpa.free(call);
    var count: u32 = 0;
    var at: u32 = 0;
    while (std.mem.indexOfPos(u8, code, at, call)) |index| {
        at = @intCast(index + call.len);
        const before = if (index == 0) ' ' else code[index - 1];
        if (!is_word(before) and before != '.') {
            count += 1;
        } else if (before == '.' and calls_itself_through(code[0 .. index - 1], receiver)) {
            count += 1;
        }
    }
    assert(count * call.len <= code.len);
    return count;
}

/// Whether `before`, the code up to a `.name(` call's dot, ends with the function's
/// own receiver: its first parameter, `Self` or `@This()`.
fn calls_itself_through(before: []const u8, receiver: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, receiver, '.') == null); // A name, not a path
    if (before.len == 0) return false; // A dot first on the line: no receiver
    const owners = [_][]const u8{ "Self", "@This()" };
    for (owners) |owner| {
        if (ends_with_word(before, owner)) return true;
    }
    return receiver.len > 0 and ends_with_word(before, receiver);
}

/// Whether `text` ends with `word` as a whole word.
fn ends_with_word(text: []const u8, word: []const u8) bool {
    assert(word.len > 0);
    assert(std.mem.indexOfScalar(u8, word, ' ') == null); // One word
    if (!std.mem.endsWith(u8, text, word)) return false;
    const start = text.len - word.len;
    return start == 0 or !is_word(text[start - 1]);
}

/// The name of the first parameter in `params`, a signature's text after its `(`, or
/// "" when there's none there (none at all, or on the next line).
fn first_parameter(params: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, params, " ");
    assert(trimmed.len <= params.len);
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return "";
    const name = std.mem.trim(u8, trimmed[0..colon], " ");
    for (name) |c| {
        if (!is_word(c)) return ""; // Not a name: `comptime T`, or not a parameter
    }
    assert(name.len < params.len); // Its colon at least comes after it
    return name;
}

/// Notes a function named not in snake_case, unless it returns a type (TitleCase, as
/// Zig has it) or the standard library looks it up by its name: `code` is the line
/// its signature ends on, which says what it returns.
fn check_function_name(scan: *Scan, name: []const u8, code: []const u8, line_number: u32) !void {
    assert(name.len > 0);
    assert(line_number > 0);
    const returns_type = std.mem.indexOf(u8, code, ") type") != null;
    if (!returns_type and !is_snake_case(name) and !listed(&std_hooks, name)) {
        try scan.note(.function_name, line_number, 1);
    }
}

/// Whether an assertion on this line joins conditions with `and` at its top level.
fn has_compound_assertion(code: []const u8, expects_assert: bool) bool {
    const openers = [_][]const u8{ "assert(", "that(", "thatf(", "expect(" };
    for (openers) |opener| {
        if (!expects_assert and std.mem.eql(u8, opener, "expect(")) continue;
        var at: u32 = 0;
        while (std.mem.indexOfPos(u8, code, at, opener)) |index| {
            at = @intCast(index + opener.len);
            assert(at <= code.len);
            if (index > 0 and is_word(code[index - 1])) continue;
            // Paired with top_level_and, which reads from just after the `(`.
            assert(code[at - 1] == '(');
            if (top_level_and(code[at..])) return true;
        }
    }
    return false;
}

/// Whether `code` asserts only what `before`, the line of code above it, made true: the
/// value it just set, or the opposite of the condition it just left on.
// Assertions: it reads two lines of a file, which are outside data to the check.
fn restates(before: []const u8, code: []const u8) bool {
    const line = std.mem.trim(u8, code, " ");
    if (!std.mem.startsWith(u8, line, "assert(") or !std.mem.endsWith(u8, line, ");")) {
        return false;
    }
    const claim = line["assert(".len .. line.len - ");".len];
    const above = std.mem.trim(u8, before, " ");
    if (std.mem.startsWith(u8, above, "if (")) {
        const condition = condition_of(above["if (".len..]) orelse return false;
        const rest = std.mem.trimStart(u8, above["if (".len + condition.len + 1 ..], " ");
        const leaves = std.mem.startsWith(u8, rest, "return") or
            std.mem.startsWith(u8, rest, "continue") or std.mem.startsWith(u8, rest, "break");
        return leaves and is_opposite(condition, claim);
    }
    // `x = v;`: its claim `x == v`
    if (!std.mem.endsWith(u8, above, ";")) return false;
    const at = std.mem.indexOf(u8, above, " = ") orelse return false;
    const name = above[0..at];
    const value = above[at + " = ".len .. above.len - 1];
    if (std.mem.indexOfScalar(u8, name, ' ') != null) return false; // A declaration
    return claim.len == name.len + " == ".len + value.len and
        std.mem.startsWith(u8, claim, name) and std.mem.endsWith(u8, claim, value) and
        std.mem.eql(u8, claim[name.len..][0..4], " == ");
}

/// An `if`'s condition, from just after its `(`, to before the `)` that closes it.
fn condition_of(after_open: []const u8) ?[]const u8 {
    assert(std.mem.indexOfScalar(u8, after_open, '\n') == null); // One line
    var depth: u32 = 0;
    for (after_open, 0..) |c, index| {
        if (c == '(') depth += 1;
        if (c != ')') continue;
        if (depth == 0) return after_open[0..index];
        depth -= 1;
    }
    return null;
}

/// Whether `claim` says exactly that `condition` is false: `!c`, `!(c)`, or the one
/// comparison `a < b` as `a >= b`, and so on.
// Assertions: it compares two pieces of a file's text, outside data to the check.
fn is_opposite(condition: []const u8, claim: []const u8) bool {
    if (claim.len == condition.len + 1 and claim[0] == '!') {
        if (std.mem.eql(u8, claim[1..], condition)) return true;
    }
    if (claim.len == condition.len + 3 and std.mem.startsWith(u8, claim, "!(")) {
        if (std.mem.eql(u8, claim[2 .. claim.len - 1], condition)) return true;
    }
    if (std.mem.indexOf(u8, condition, " and ") != null) return false;
    if (std.mem.indexOf(u8, condition, " or ") != null) return false;
    const opposites = [_][2][]const u8{
        .{ " < ", " >= " }, .{ " > ", " <= " },  .{ " <= ", " > " },
        .{ " >= ", " < " }, .{ " == ", " != " }, .{ " != ", " == " },
    };
    for (opposites) |pair| {
        const at = std.mem.indexOf(u8, condition, pair[0]) orelse continue;
        const left = condition[0..at];
        const right = condition[at + pair[0].len ..];
        if (claim.len != left.len + pair[1].len + right.len) continue;
        if (!std.mem.startsWith(u8, claim, left)) continue;
        if (!std.mem.endsWith(u8, claim, right)) continue;
        return std.mem.eql(u8, claim[left.len..][0..pair[1].len], pair[1]);
    }
    return false;
}

/// Whether the first argument of a call, from just after its `(`, has a top-level `and`.
fn top_level_and(arguments: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, arguments, '\n') == null); // One line
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
// Assertions: it reads a line of a file, which is outside data to the check; the one
// assertion, on where a capture starts, follows from the line's `if (`.
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

/// The markers on the comment lines just above a line of code, each by the line it's on.
const Said = struct {
    unbounded_at: ?u32 = null,
    ignored_at: ?u32 = null,
    assertions_at: ?u32 = null,
    usize_at: ?u32 = null,
    not_size_at: ?u32 = null,
};

/// What `check_zig` carries from one line to the next.
const Scan = struct {
    breaks: std.ArrayList(Break) = .empty,
    gpa: std.mem.Allocator,
    depth: i32 = 0,
    test_depth: ?i32 = null, // Inside a test block: its depth
    /// Past the imports: a function, test, type or comptime block has begun at the top
    /// level, and an import from here on is no longer at the file's top.
    past_imports: bool = false,
    // The functions being read, innermost last: a struct inside a function has its own
    open: [open_max]Function = undefined,
    open_count: u32 = 0,
    // A function whose signature runs over several lines, until the line with its `{`
    pending: ?Function = null,
    previous_comment: bool = false,
    said: Said = .{}, // For the next line of code
    after_statement: bool = false, // The last line of code ended with `;`
    last_code: []const u8 = "", // The last line with code on it, outside tests
    after_catch: bool = false, // The last line of code ended with `catch`, wrapped
    // The file's functions and their assertions (and those outside any, at compile
    // time), but for the functions excused from them
    functions: u32 = 0,
    assertions: u32 = 0,
    light: std.ArrayList(u32) = .empty, // Where each function with fewer than two starts
    expects_assert: bool, // In the scenarios, where `expect(` is the assertion
    lays_out: bool, // In the screens' code, where a size comes from style.zig's scale
    in_points: bool, // In a file of points of its own (`own_points`)

    /// A function being read: its name, first line, depth outside it, the assertions
    /// made in it so far, and the line of the `// Assertions:` marker above it, if any.
    const Function = struct {
        name: []const u8,
        /// Its first parameter's name: a method calling itself does so through it.
        receiver: []const u8 = "",
        start_line: u32,
        depth: i32,
        assertions: u32 = 0,
        excused_at: ?u32,
    };
    const open_max = 16;

    fn note(scan: *Scan, rule: Rule, line_number: u32, times: u32) !void {
        assert(line_number > 0);
        for (0..times) |_| {
            try scan.breaks.append(scan.gpa, .{ .rule = rule, .line = line_number });
        }
    }
};

/// Lists the rules broken in one Zig file, in order of line. The caller frees the list.
pub fn check_zig(path: []const u8, source: []const u8, gpa: std.mem.Allocator) ![]Break {
    const buffer = try gpa.alloc(u8, source.len);
    defer gpa.free(buffer);
    @memset(buffer, ' '); // Comments and multiline strings stay blank in it
    assert(path.len > 0);
    var scan: Scan = .{
        .gpa = gpa,
        .expects_assert = is_scenarios(path),
        .lays_out = is_layout(path),
        .in_points = listed(&own_points, path),
    };
    errdefer scan.breaks.deinit(gpa);
    defer scan.light.deinit(gpa);
    var line_number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| : (line_number += 1) {
        const offset = @intFromPtr(text.ptr) - @intFromPtr(source.ptr);
        const line = split_line(text, buffer[offset..]);
        const said = try check_zig_text(&scan, &line, line_number);
        if (imports_inline(line.code)) try scan.note(.import_inline, line_number, 1);
        if (scan.depth == 0 and starts_body(line.code)) scan.past_imports = true;
        const top_import = scan.depth == 0 and declares_import(line.code);
        if (scan.past_imports and top_import) {
            try scan.note(.import_inline, line_number, 1);
        }
        const trimmed = std.mem.trimStart(u8, line.code, " ");
        const test_start = std.mem.startsWith(u8, trimmed, "test \"") or
            std.mem.startsWith(u8, trimmed, "test {");
        if (scan.test_depth == null and test_start) scan.test_depth = scan.depth;
        if (scan.test_depth == null) {
            if (said) |above| try check_zig_code(&scan, &line, line_number, above);
        }
        scan.depth += count_depth(line.code, '{', '}');
        try close_functions(&scan, line_number);
        if (scan.test_depth) |test_depth| {
            if (scan.depth <= test_depth) scan.test_depth = null; // Its closing brace
        }
    }
    // Even an empty file is one line.
    assert(line_number > 1);
    // Now the whole file's code is in `buffer`, its strings blanked: an import's own path
    // can't count as a use of its name
    try note_unused_imports(&scan, source, buffer);
    try marked_for_nothing(&scan, scan.said);
    if (scan.assertions < scan.functions * assertions_per_function_min) {
        // Short on average: each function below two is where to add them
        assert(scan.light.items.len > 0);
        for (scan.light.items) |start_line| try scan.note(.assertion_density, start_line, 1);
    }
    std.mem.sort(Break, scan.breaks.items, {}, struct {
        fn before(_: void, a: Break, b: Break) bool {
            assert(a.line > 0);
            assert(b.line > 0);
            return a.line < b.line;
        }
    }.before);
    return scan.breaks.toOwnedSlice(gpa);
}

/// Ends every open function whose closing brace this line holds: its length, and its
/// assertions toward the file's, unless it's excused from them.
fn close_functions(scan: *Scan, line_number: u32) !void {
    assert(scan.open_count <= Scan.open_max);
    for (0..Scan.open_max) |_| {
        if (scan.open_count == 0) return;
        const open = scan.open[scan.open_count - 1];
        // A function opens at a depth of zero or more: a file's braces never go below it.
        assert(open.depth >= 0);
        if (scan.depth > open.depth) return;
        assert(open.start_line <= line_number);
        const length = line_number - open.start_line + 1;
        if (length > function_lines_max) try scan.note(.function_length, open.start_line, 1);
        const light = open.assertions < assertions_per_function_min;
        // A short function does one thing: asserting there mostly repeats its line, so
        // it's left out of the average, its assertions with it, as a marked one is
        const short = length <= short_function_lines_max;
        if (open.excused_at) |marker_line| {
            if (!light or short) try scan.note(.marker_unused, marker_line, 1);
        } else if (short) {
            assert(length <= function_lines_max);
        } else {
            scan.functions += 1;
            scan.assertions += open.assertions;
            if (light) try scan.light.append(scan.gpa, open.start_line);
        }
        scan.open_count -= 1;
    }
}

/// Whether a comment is a marker: it starts with `prefix`, and gives a reason after it.
/// The calls that reach the system, whose results say whether they worked.
const system_calls = [_][]const u8{
    "linux.",      "calls.",        "std.posix.", "std.os.linux.", "process.",
    // As the tools reach the same calls, through src/core.zig
    "core.calls.", "core.process.",
};

/// How many of a line's catches give up without a word (`catch return;`, `catch break`,
/// `catch continue`): a reason may be given for them, as for an error ignored.
fn gives_up_quietly(code: []const u8) u32 {
    const quiet = count_token(code, "catch return") + count_token(code, "catch break") +
        count_token(code, "catch continue");
    assert(quiet <= code.len);
    return quiet;
}

/// How many system calls' results a line throws away: `_ = linux.close(fd)`.
fn system_results_dropped(code: []const u8) u32 {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line
    var dropped: u32 = 0;
    for (system_calls) |prefix| {
        var at: u32 = 0;
        while (std.mem.indexOfPos(u8, code, at, "_ = ")) |index| {
            at = @intCast(index + "_ = ".len);
            if (!std.mem.startsWith(u8, code[at..], prefix)) continue;
            // `_ = run(…) orelse return …`: the failure is handled after all
            const rest = code[at..];
            const handled = std.mem.indexOf(u8, rest, " orelse ") != null or
                std.mem.indexOf(u8, rest, " catch ") != null;
            if (!handled) dropped += 1;
        }
    }
    assert(dropped <= code.len);
    return dropped;
}

fn is_marker(comment: []const u8, prefix: []const u8) bool {
    assert(std.mem.startsWith(u8, prefix, "// "));
    assert(prefix[prefix.len - 1] == ' ');
    if (!std.mem.startsWith(u8, comment, prefix)) return false;
    return std.mem.trim(u8, comment[prefix.len..], " ").len > 0;
}

/// Notes every marker that reached no line of code for it to excuse.
fn marked_for_nothing(scan: *Scan, said: Said) !void {
    assert(scan.open_count <= Scan.open_max);
    const lines = [_]?u32{
        said.unbounded_at, said.ignored_at, said.assertions_at, said.usize_at, said.not_size_at,
    };
    comptime assert(lines.len == @typeInfo(Said).@"struct".field_names.len);
    for (lines) |marker_line| {
        if (marker_line) |at| try scan.note(.marker_unused, at, 1);
    }
}

/// Notes what a line breaks as text: its length and its comment. Returns, for a line
/// of code, the markers on the comment lines just above it; null for any other line.
fn check_zig_text(scan: *Scan, line: *const Line, line_number: u32) !?Said {
    assert(line.code.len <= line.text.len);
    assert(line_number > 0);
    const trimmed = std.mem.trimStart(u8, line.code, " ");
    if (columns(line.text) > line_columns_max) try scan.note(.line_length, line_number, 1);
    const own_line_comment = line.comment.len > 0 and trimmed.len == 0;
    const continued = scan.previous_comment and own_line_comment;
    // A `// usize:` marker names the type it excuses, so it starts in lowercase
    const usize_marker = is_marker(line.comment, "// usize: ");
    if (bad_comment(line.comment, own_line_comment, continued) and !usize_marker) {
        try scan.note(.comment_style, line_number, 1);
    }
    scan.previous_comment = own_line_comment;
    if (own_line_comment) {
        if (is_marker(line.comment, "// Unbounded: ")) scan.said.unbounded_at = line_number;
        if (is_marker(line.comment, "// Ignored: ")) scan.said.ignored_at = line_number;
        if (is_marker(line.comment, "// Assertions: ")) scan.said.assertions_at = line_number;
        if (usize_marker) scan.said.usize_at = line_number;
        if (is_marker(line.comment, "// Not a size: ")) scan.said.not_size_at = line_number;
        return null;
    }
    const above = scan.said;
    scan.said = .{};
    if (trimmed.len > 0) return above;
    // A blank line, or one of a multiline string: the markers above it mark nothing
    if (scan.test_depth == null) try marked_for_nothing(scan, above);
    return null;
}

/// Notes what a line of code outside the tests breaks, and adds its assertions to the
/// function they're in. `said` is the markers on the comment lines just above it.
fn check_zig_code(scan: *Scan, line: *const Line, line_number: u32, said: Said) !void {
    assert(scan.test_depth == null);
    assert(line_number > 0);
    const code = line.code;
    var excuse_used = false;
    if (function_name(code)) |name| {
        const opens = std.mem.indexOfScalar(u8, code, '{') != null;
        // A signature wrapped over lines says what it returns on its last: judged there
        if (opens) try check_function_name(scan, name, code, line_number);
        const function: Scan.Function = .{
            .name = name,
            .receiver = first_parameter(code[std.mem.indexOfScalar(u8, code, '(').? + 1 ..]),
            .start_line = line_number,
            .depth = scan.depth,
            .excused_at = said.assertions_at,
        };
        excuse_used = true;
        scan.pending = null;
        if (std.mem.indexOfScalar(u8, code, '{') != null) {
            open_function(scan, function);
        } else {
            scan.pending = function;
        }
    } else if (scan.pending) |pending| {
        // The rest of a signature: the function opens on the line with its `{`
        if (pending.receiver.len == 0) scan.pending.?.receiver = first_parameter(code);
        if (std.mem.indexOfScalar(u8, code, '{') != null) {
            var function = scan.pending.?;
            function.depth = scan.depth;
            try check_function_name(scan, function.name, code, function.start_line);
            open_function(scan, function);
            scan.pending = null;
        } else if (std.mem.endsWith(u8, std.mem.trimEnd(u8, code, " "), ";")) {
            scan.pending = null; // A declaration without a body
        }
    } else if (scan.open_count > 0) {
        // A call to the function being read, from inside it: the innermost one
        const open = scan.open[scan.open_count - 1];
        assert(open.start_line < line_number);
        const calls = try count_calls(code, open.name, open.receiver, scan.gpa);
        try scan.note(.recursion, line_number, calls);
    }
    if (!excuse_used) {
        if (said.assertions_at) |at| try scan.note(.marker_unused, at, 1);
    }
    const assertions = count_assertions(code, scan.expects_assert);
    if (scan.open_count > 0) {
        scan.open[scan.open_count - 1].assertions += assertions;
    } else {
        scan.assertions += assertions; // At compile time, outside any function
    }
    try check_zig_statement(scan, line, line_number, said);
}

/// Starts reading a function's body.
fn open_function(scan: *Scan, function: Scan.Function) void {
    assert(function.depth >= 0);
    assert(function.assertions == 0);
    // Deeper than any code here nests functions: those past it go unchecked
    if (scan.open_count == Scan.open_max) return;
    scan.open[scan.open_count] = function;
    scan.open_count += 1;
}

/// Whether a line, following one that ended in `catch`, ignores the error:
/// `{}` or `unreachable` as the first thing on it.
fn ignores_wrapped_catch(after_catch: bool, code: []const u8) bool {
    assert(std.mem.indexOfScalar(u8, code, '\n') == null); // One line, split before
    if (!after_catch) return false;
    const start = std.mem.trimStart(u8, code, " ");
    assert(start.len <= code.len);
    return std.mem.startsWith(u8, start, "{}") or std.mem.startsWith(u8, start, "unreachable");
}

/// Notes what a line of code breaks within a statement: compound assertions, unbraced
/// ifs, ignored errors, unbounded loops and usize, each unless marked as an exception.
fn check_zig_statement(scan: *Scan, line: *const Line, line_number: u32, said: Said) !void {
    assert(line_number > 0);
    assert(scan.test_depth == null);
    const code = line.code;
    if (has_compound_assertion(code, scan.expects_assert)) {
        try scan.note(.compound_assertion, line_number, 1);
    }
    if (restates(scan.last_code, code)) try scan.note(.assertion_restated, line_number, 1);
    const compared = count_token(code, "== true") + count_token(code, "== false") +
        count_token(code, "!= true") + count_token(code, "!= false");
    try scan.note(.bool_compared, line_number, compared);
    if (std.mem.trim(u8, code, " ").len > 0) scan.last_code = code;
    if (opens_unbraced(code, scan.after_statement)) {
        try scan.note(.if_without_braces, line_number, 1);
    }
    const ending = std.mem.trimEnd(u8, code, " ");
    if (ending.len > 0) scan.after_statement = ending[ending.len - 1] == ';';
    // Ignoring an error is handling it only when the line says why: `// Ignored: …`.
    // A `catch` wrapped onto the next line counts the same as one on a single line.
    const wrapped = ignores_wrapped_catch(scan.after_catch, code);
    if (ending.len > 0) scan.after_catch = std.mem.endsWith(u8, ending, " catch");
    const inline_count = count_token(code, "catch {}") +
        count_token(code, "catch unreachable") + count_token(code, "else |_| {}") +
        system_results_dropped(code);
    const ignored = inline_count + @intFromBool(wrapped);
    // The reason on the line, or on the comment just above it, as a long one is
    const on_line = is_marker(line.comment, "// Ignored: ");
    if (!on_line and said.ignored_at == null) {
        try scan.note(.error_ignored, line_number, ignored);
    } else if (ignored + gives_up_quietly(code) == 0) {
        // A reason for ignoring nothing: the error it was for is handled now, or gone
        try scan.note(.marker_unused, if (on_line) line_number else said.ignored_at.?, 1);
    }
    // A loop that never ends by design says so just above it: `// Unbounded: …`
    // `for (0..)` counts with no end, as `while (true)` does
    const loops = count_token(code, "while (true)") + count_token(code, "for (0..)");
    if (said.unbounded_at) |at| {
        if (loops == 0) try scan.note(.marker_unused, at, 1);
    } else {
        try scan.note(.loop_unbounded, line_number, loops);
    }
    // A size in the screens' code comes from the scale, or says why it isn't one
    if (scan.lays_out) {
        const bare = bare_sizes(code, scan.in_points);
        const marked = is_marker(line.comment, "// Not a size: ") or said.not_size_at != null;
        if (marked) {
            if (bare == 0) try scan.note(.marker_unused, said.not_size_at orelse line_number, 1);
        } else {
            try scan.note(.layout_number, line_number, bare);
        }
    } else if (said.not_size_at) |at| {
        try scan.note(.marker_unused, at, 1);
    }
    // A usize the language, C or the kernel needs says so on its line or just above
    const sizes = count_token(code, "usize");
    const usize_here = is_marker(line.comment, "// usize: ");
    if (usize_here or said.usize_at != null) {
        if (sizes == 0) try scan.note(.marker_unused, said.usize_at orelse line_number, 1);
    } else {
        try scan.note(.usize_used, line_number, sizes);
    }
}

/// Every Zig file's breaks, and every script's, by path.
const Found = struct { path: []const u8, breaks: []const Break };

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

/// What to do about a break of each rule, printed once for every rule broken.
// Assertions: a table, which the switch keeps complete.
fn advice(rule: Rule) []const u8 {
    return switch (rule) {
        .line_length => "lines are at most 100 columns",
        .function_length => "functions are at most 70 lines: split it",
        .function_name => "functions are snake_case",
        .assertion_density => "two assertions per function on average: add them where listed," ++
            " or say above one why it can't: `// Assertions: <why>`",
        .recursion => "no recursion: walk with an explicit, bounded stack",
        .compound_assertion => "split it: `assert(a); assert(b);`",
        .assertion_restated => "remove it, or assert something the line above doesn't say",
        .bool_compared => "use the bool itself, or `orelse` with why no answer means that",
        .if_without_braces => "a body on its own line takes braces",
        .error_ignored => "handle the error, or say why on that line: `// Ignored: <why>`",
        .comment_style => "comments start with a space, and a sentence with a capital",
        .loop_unbounded => "bound the loop, or say why above it: `// Unbounded: <why>`",
        .usize_used => "size it (u32, u64), or `// usize: <why>` where the ABI needs it",
        .script_not_zig => "tooling is Zig",
        .marker_unused => "the marker excuses nothing: remove it",
        .import_inline => "move the import to the top of the file",
        .import_unused => "remove the import",
        .layout_number => "take it from style.zig's scale (style.space, style.text, " ++
            "style.fingertip…) or work it out from the parts it sits by; in a file of " ++
            "points of its own (src/kindle/touch.zig), give it to its pt( in points",
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) return error.Usage;
    const io = init.io;
    var root = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer root.close(io);
    const found = try find_breaks(io, root, gpa);
    assert(found.len > 0);

    var total: u32 = 0;
    var rules_broken: std.EnumSet(Rule) = .empty;
    for (found) |f| {
        for (f.breaks) |b| {
            std.debug.print("{s}:{d}: {s}\n", .{ f.path, b.line, @tagName(b.rule) });
            rules_broken.insert(b.rule);
            total += 1;
        }
    }
    assert(rules_broken.count() <= total);
    if (total > 0) {
        var rules = rules_broken.iterator();
        while (rules.next()) |rule| {
            std.debug.print("  {s}: {s}\n", .{ @tagName(rule), advice(rule) });
        }
        std.debug.print("{d} Tiger Style breaks (docs/TIGER_STYLE.md)\n", .{total});
        std.process.exit(1);
    }
    std.debug.print("style ok\n", .{});
}

/// Folders of the repository that hold nothing of its own: what builds and git keep.
const not_ours = [_][]const u8{ ".git", "zig-out", ".zig-cache", "zig-pkg" };
/// What scripts are written as, by their file's ending.
const script_endings = [_][]const u8{ ".sh", ".bash", ".py", ".js", ".rb", ".pl", ".lua" };

/// Every script anywhere in the repository but the KPM shim: a file ending as one, or
/// starting `#!`, which runs it whatever its name.
fn find_scripts(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    found: *std.ArrayList(Found),
) !void {
    const before = found.items.len;
    assert(before > 0); // The Zig files, found first
    var walker = try root.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const slash = std.mem.indexOfScalar(u8, entry.path, '/') orelse entry.path.len;
        if (listed(&not_ours, entry.path[0..slash])) continue;
        if (!is_script(io, root, entry.path)) continue;
        const source = try root.readFileAlloc(io, entry.path, gpa, .limited(1 << 20));
        if (is_kpm_shim(entry.path, source)) continue;
        const path = try gpa.dupe(u8, entry.path);
        const breaks = try gpa.dupe(Break, &.{.{ .rule = .script_not_zig, .line = 1 }});
        try found.append(gpa, .{ .path = path, .breaks = breaks });
    }
    assert(found.items.len >= before);
}

/// Whether the file at `path` is a script: named as one, or starting `#!`.
fn is_script(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    assert(path.len > 0);
    for (script_endings) |ending| {
        if (std.mem.endsWith(u8, path, ending)) return true;
    }
    var head: [2]u8 = undefined;
    // Ignored: a file that can't be read can't be run either
    const start = root.readFile(io, path, &head) catch return false;
    assert(start.len <= head.len);
    return std.mem.eql(u8, start, "#!");
}

/// Every Zig file's breaks, and every script's, sorted by path.
fn find_breaks(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator) ![]const Found {
    var found: std.ArrayList(Found) = .empty;
    for ([_][]const u8{ "src", "tools", "device" }) |folder| {
        var dir = try root.openDir(io, folder, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, entry.path });
            var breaks: []const Break = &.{};
            if (std.mem.endsWith(u8, path, ".zig")) {
                const source = try dir.readFileAlloc(io, entry.path, gpa, .limited(8 << 20));
                breaks = try check_zig(path, source, gpa);
            } else continue;
            try found.append(gpa, .{ .path = path, .breaks = breaks });
        }
    }
    try find_scripts(io, root, gpa, &found);
    const build_source = try root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20));
    const build_breaks = try check_zig("build.zig", build_source, gpa);
    try found.append(gpa, .{ .path = "build.zig", .breaks = build_breaks });
    std.mem.sort(Found, found.items, {}, struct {
        fn before(_: void, a: Found, b: Found) bool {
            assert(a.path.len > 0);
            assert(b.path.len > 0);
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

/// How many times `source` breaks `rule`.
fn count_in(source: []const u8, rule: Rule) !u32 {
    const breaks = try check_zig("src/sys/a.zig", source, std.testing.allocator);
    defer std.testing.allocator.free(breaks);
    var count: u32 = 0;
    for (breaks) |b| {
        if (b.rule == rule) count += 1;
    }
    return count;
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

test "assertions are counted against functions; a short function is left out" {
    const two =
        \\fn f(a: u32) u32 {
        \\    assert(a > 0);
        \\    check.that(a < 9, "small");
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    return a;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(two, .assertion_density));
    const none =
        \\fn f() void {
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\fn g() void {
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), try count_in(none, .assertion_density));
    // Five lines of body or fewer: left out of the average, as a marked function is
    const short = "fn f() void {}\nfn g(a: u32) void {\n    _ = a;\n}\n";
    try std.testing.expectEqual(@as(u32, 0), try count_in(short, .assertion_density));
}

test "assertions average per file; a signature may run over lines; nesting" {
    // Four assertions in one function make up for none in the other, as an average
    const even =
        \\fn f(a: u32) void {
        \\    assert(a > 0);
        \\    assert(a < 9);
        \\    assert(a != 3);
        \\    assert(a != 4);
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\fn g(
        \\    a: u32,
        \\) void {
        \\    _ = a;
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(even, .assertion_density));
    // Short once one goes: the function below two is listed, at the line it starts
    const short = comptime even[0..std.mem.indexOf(u8, even, "    assert(a != 4);").?] ++
        even[std.mem.indexOf(u8, even, "    assert(a != 4);").? + "    assert(a != 4);\n".len ..];
    const breaks = try check_zig("src/sys/a.zig", short, std.testing.allocator);
    defer std.testing.allocator.free(breaks);
    try std.testing.expect(breaks.len == 1);
    try std.testing.expectEqual(Break{ .rule = .assertion_density, .line = 12 }, breaks[0]);
    // An inner function's assertions are its own: its outer one has none
    const nested =
        \\fn outer() void {
        \\    const S = struct {
        \\        fn inner(n: u32) void {
        \\            assert(n > 0);
        \\            assert(n < 9);
        \\        }
        \\    };
        \\    _ = S;
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(nested, .assertion_density));
}

test "a call to invariants() asserts; its definition isn't one" {
    const source =
        \\fn invariants(in: *const Input) void {
        \\    assert(in.a > 0);
        \\    assert(in.b > 0);
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\fn handle(in: *Input) void {
        \\    in.invariants();
        \\    defer in.invariants();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\fn idle(in: *Input) void {
        \\    _ = in;
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
    ;
    // Four of six: idle, without any, is where they're missing
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .assertion_density));
}

test "in the scenarios, and only there, `expect(` is an assertion" {
    const source =
        \\fn run() !void {
        \\    try expect(a, "a");
        \\    try expect(b and c, "b and c");
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
    ;
    for ([_][]const u8{ "src/scenarios.zig", "src/scenarios/reading.zig" }) |path| {
        const in_scenarios = try check_zig(path, source, std.testing.allocator);
        defer std.testing.allocator.free(in_scenarios);
        try std.testing.expect(in_scenarios.len == 1);
        try std.testing.expectEqual(Rule.compound_assertion, in_scenarios[0].rule);
    }
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .assertion_density));
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .compound_assertion));
}

test "a function marked `// Assertions:` is excused; a marker excusing nothing counts" {
    const source =
        \\/// A wrapper.
        \\// Assertions: a wrapper over outside data.
        \\fn f() void {
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\// Assertions: this one has its two.
        \\fn g(a: u32) void {
        \\    assert(a > 0);
        \\    assert(a < 9);
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\// Assertions: this one is short, so left out anyway.
        \\fn s() void {}
        \\// Assertions:
        \\fn h() void {
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
        \\fn i(a: u32) void {
        \\    assert(a > 0);
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\    work();
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .assertion_density));
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .marker_unused));
}

test "usize counts unless `// usize:` on its line or just above says why" {
    const source =
        \\const a: usize = 1;
        \\const b: usize = 2; // usize: the kernel's ABI
        \\// usize: C's size_t
        \\const c: usize = 3;
        \\// usize: nothing here
        \\const d: u32 = 4;
        \\const e: u32 = 5; // usize: nor here
        \\// usize: a blank line ends what a marker covers
        \\
        \\const f: usize = 6;
        \\const g: u32 = 7; // usize_used isn't usize
    ;
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .usize_used));
    try std.testing.expectEqual(@as(u32, 3), try count_in(source, .marker_unused));
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .comment_style));
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
        \\    const x = foo() catch
        \\        unreachable;
        \\    return walk(n - 1);
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .compound_assertion));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .if_without_braces));
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .error_ignored));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .recursion));
}

test "an assertion of what the line above just made true counts" {
    const source =
        \\fn walk(w: *W, n: u32) u32 {
        \\    w.fd = -1;
        \\    assert(w.fd == -1);
        \\    if (n < 3) return 0;
        \\    assert(n >= 3);
        \\    if (n == 4) return 1;
        \\    // A comment between
        \\    assert(!(n == 4));
        \\    if (n > 9 or n == 7) return 2;
        \\    assert(n != 7);
        \\    w.fd = 2;
        \\    assert(w.fd > 0);
        \\    const m = n * 2;
        \\    assert(m == n * 2);
        \\    return n;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 3), try count_in(source, .assertion_restated));
}

test "a bool compared with true or false counts" {
    const source =
        \\fn ask(on: ?bool, b: bool) bool {
        \\    assert(b or !b);
        \\    if (on == true) return b == false;
        \\    return on orelse false;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .bool_compared));
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

test "a loop or an ignored error with its reason given doesn't count" {
    const source =
        \\fn f() void {
        \\    // Unbounded: the reader's loop runs until noface quits.
        \\    while (true) {}
        \\    while (true) {}
        \\    g() catch {}; // Ignored: a missing cover only means no picture.
        \\    g() catch {};
        \\    // Unbounded: but the loop below is bounded.
        \\    for (0..9) |_| {}
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .loop_unbounded));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .error_ignored));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .marker_unused));
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

test "imports are at a file's top, and each is used" {
    const source =
        \\const std = @import("std");
        \\const unused = @import("unused.zig");
        \\fn f() void {
        \\    const inner = @import("inner.zig");
        \\    _ = inner;
        \\    _ = std;
        \\    const text = "@import(\\"in a string\\")";
        \\    _ = text;
        \\}
        \\test {
        \\    _ = @import("listed.zig");
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .import_inline));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .import_unused));
}

test "an import below the file's first function or type is out of place" {
    const source =
        \\const std = @import("std");
        \\const T = @import("t.zig").T;
        \\const is_root = @import("root") == @This();
        \\pub const Kind = enum { a, b };
        \\const late = @import("late.zig");
        \\fn f() void {
        \\    _ = std;
        \\    _ = T;
        \\    _ = is_root;
        \\    _ = late;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .import_inline));
}

test "an import named only by its own line, field and all, is unused" {
    const source =
        \\const failed = @import("os.zig").failed;
        \\const used = @import("used.zig").used;
        \\fn f() void {
        \\    _ = used;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .import_unused));
}

test "an error dropped by an empty else capture is ignored unless it says why" {
    const source =
        \\fn f() void {
        \\    if (g()) |_| {} else |_| {}
        \\    if (g()) |_| {} else |_| {} // Ignored: nothing to undo
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .error_ignored));
}

test "a size in the screens' code comes from the scale, and a marked number may stay" {
    const source =
        \\const style = @import("style.zig");
        \\const row_gap = 24;
        \\const row_height = style.space.band;
        \\const half_width = style.screen_width / 4;
        \\const tries_max = 40;
        \\fn draw(page: Page) void {
        \\    page.fill_rect(0, 0, 4, 4, style.black);
        \\    page.fill_rect(0, 0, style.border, 2, style.black);
        \\    var label: [16]u8 = undefined;
        \\    // Not a size: the fourth row
        \\    row(page, 3);
        \\    assert(row_gap >= 3);
        \\    page.fill_rect(0, 0, @divTrunc(page.width, 3), 3 * style.fingertip, style.black);
        \\    page.fill_rect(@divTrunc(page.width, 2), 0, 12, 1, style.black);
        \\    page.fill_rect(0, 0, @divTrunc(f(page.width, 5), 2), 1, style.black);
        \\    page.fill_rect(0, 0, 2 * 150, 100 * n, style.black);
        \\    page.pill(x, x, y, r - 2, style.white);
        \\    page.fill_rect(0, 0, (count - 1) * gap, style.stroke, style.rule);
        \\}
        \\const edge_px = 2;
        \\const parts_max = 2;
    ;
    const in_ui = try check_zig("src/ui/menu.zig", source, std.testing.allocator);
    defer std.testing.allocator.free(in_ui);
    var bare: u32 = 0;
    var unused: u32 = 0;
    for (in_ui) |b| {
        if (b.rule == .layout_number) bare += 1;
        if (b.rule == .marker_unused) unused += 1;
    }
    // 24, the two 4s, the 12 after a `@div` call, the 5 inside one, 150 and 100; and
    // the small lengths: the border's 2 high, the two 1s high, `r - 2` and `edge_px`.
    // The gaps' count `count - 1` and `parts_max`, no size, are let be
    try std.testing.expectEqual(@as(u32, 12), bare);
    try std.testing.expectEqual(@as(u32, 1), unused); // `row(page, 3)` writes no size
    const in_style = try check_zig("src/ui/style.zig", source, std.testing.allocator);
    defer std.testing.allocator.free(in_style);
    for (in_style) |b| try std.testing.expect(b.rule != .layout_number);
}

test "the size rule covers the code that lays out the screen, and only that" {
    for ([_][]const u8{
        "src/ui/menu.zig",   "src/screens/reader.zig", "src/layout/text.zig",
        "src/gfx/image.zig", "src/app.zig",            "src/display.zig",
        "src/kindle/touch.zig", // Below the interface, in points of its own
    }) |path| try std.testing.expect(is_layout(path));
    for ([_][]const u8{
        "src/ui/style.zig",     "src/ui/icons.zig", "src/gfx/jpeg.zig",
        "src/gfx/truetype.zig", "src/sys/os.zig",   "src/kindle/input.zig",
        "src/model/book.zig",   "tools/e2e.zig",    "build.zig",
    }) |path| try std.testing.expect(!is_layout(path));
}

test "a file of points of its own gives its numbers to its pt(, and no number bare" {
    const source =
        \\const top_zone = pt(48);
        \\const hold_slop = 36;
        \\const bottom_strip = pt(28.8);
        \\const corner_width = 300;
        \\const pull_distance = pt(-19.2);
        \\const swipe_distance = adapt(200);
    ;
    const in_points = try check_zig("src/kindle/touch.zig", source, std.testing.allocator);
    defer std.testing.allocator.free(in_points);
    var bare: u32 = 0;
    for (in_points) |b| {
        if (b.rule == .layout_number) bare += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), bare); // 36, 300 and 200: adapt( isn't pt(
    // Elsewhere a number given to a `pt(` is as bare as any: sizes come from style.zig
    const in_ui = try check_zig("src/ui/menu.zig", source, std.testing.allocator);
    defer std.testing.allocator.free(in_ui);
    bare = 0;
    for (in_ui) |b| {
        if (b.rule == .layout_number) bare += 1;
    }
    try std.testing.expectEqual(@as(u32, 6), bare);
}

test "a method calling itself through its receiver, Self or @This() is recursion" {
    const source =
        \\const Tree = struct {
        \\    fn walk(t: *Tree) void {
        \\        assert(t.depth > 0);
        \\        assert(t.depth < 9);
        \\        t.walk();
        \\        Self.walk(t);
        \\        t.child.walk(); // Another's walk: not counted
        \\    }
        \\};
    ;
    try std.testing.expectEqual(@as(u32, 2), try count_in(source, .recursion));
}

test "an open range is a loop without a bound, as while (true) is" {
    const source =
        \\fn f() void {
        \\    assert(true);
        \\    assert(true);
        \\    for (0..) |_| {}
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .loop_unbounded));
}

test "an import named only after a dot elsewhere is still unused" {
    const source =
        \\const cover = @import("cover.zig");
        \\const style = @import("style.zig");
        \\fn f() u32 {
        \\    assert(true);
        \\    assert(true);
        \\    return style.cover.width;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .import_unused));
}

test "a wrapped signature returning a type keeps its TitleCase" {
    const source =
        \\fn Wrapped(
        \\    comptime T: type,
        \\) type {
        \\    assert(@sizeOf(T) > 0);
        \\    assert(@sizeOf(T) < 9);
        \\    return T;
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 0), try count_in(source, .function_name));
}

test "a system call's result thrown away needs its reason, above or on the line" {
    const source =
        \\fn f(fd: i32) void {
        \\    assert(fd >= 0);
        \\    assert(fd < 9);
        \\    _ = linux.close(fd);
        \\    // Ignored: only read
        \\    _ = linux.close(fd);
        \\    _ = linux.close(fd); // Ignored: only read
        \\    _ = process.run(&argv, &out) orelse return;
        \\    const x = 1; // Ignored: nothing here to ignore
        \\}
    ;
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .error_ignored));
    try std.testing.expectEqual(@as(u32, 1), try count_in(source, .marker_unused));
}
