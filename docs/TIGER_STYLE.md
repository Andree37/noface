# Tiger Style in noface

noface follows [TigerBeetle's Tiger Style](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
Read it first; this page is how its rules apply here, which a program checks, and the
few places noface can't follow it, each with the reason.

The goals are TigerBeetle's, in the same order: **safety, performance, developer
experience**. On a Kindle, safety means the reader never loses their place, their notes
or their Kindle: noface takes over the screen and the touch panel, and if it goes wrong
the reader is left with a device that doesn't answer.

## How it's kept

`zig build check` (run by CI on every push, and before every release) runs
`tools/check/style.zig` over every Zig file in `src/`, `tools/` and `build.zig`, and
`zig fmt --check`. The rules it checks are marked **[checked]** below.

Code from before Tiger Style was adopted breaks some rules. `tools/check/style_baseline.txt`
records how often, per rule and file. The check fails if any file breaks a rule more
often than its baseline allows: **new code follows every rule from its first line**. It
also fails if a file breaks a rule *less* often, until `zig build style-baseline` lowers
the baseline to match, so progress can't quietly be lost. The baseline only ever
shrinks; `style-baseline` refuses to raise it. When you touch a file, leave it with
less debt than you found it.

## Safety

- **Simple, explicit control flow. No recursion [checked].** Every execution that
  should be bounded is bounded. A tree (an EPUB's table of contents, a KFX structure)
  is walked with an explicit stack of fixed depth, and a depth past it is an error.

- **A limit on everything.** Every loop and every queue has a fixed upper bound.
  `while (true)` is counted **[checked]**: write the bound in the loop
  (`for (0..attempts_max)`), or, for a loop that by design never ends (the reader's
  event loop), assert so and say why.

- **Explicitly sized types** (`u32`, `u64`, `i32`). `usize` is counted **[checked]**: use
  it only where the language needs it (indexing a slice, a slice's length), and convert
  at that edge. A position in a book, a count of pages, a size on disk: `u32` or `u64`,
  chosen by the largest value it can hold, which the code asserts.

- **Assertions.** At least **two per function on average [checked]**, counted per
  file. `std.debug.assert` for invariants; `check.that` / `check.thatf` (`src/base/check.zig`)
  when a message helps whoever reads the crash log. noface builds in ReleaseSafe, so
  both are checked on the Kindle. They state *our* invariants. Data from outside
  (a book, the catalog, settings files, lipc answers) is never asserted: it's handled
  as an error, because a broken book must not take the reader down.
  - Assert every function's arguments and return value, its pre- and postconditions,
    and invariants.
  - Pair assertions: check a property where it's produced and where it's used (a page
    break when saved and when loaded).
  - Assert the positive space and the negative space: what must be true, and what
    must not.
  - Split compound assertions **[checked]**: `assert(a); assert(b);`, not
    `assert(a and b)`.
  - `if (a) assert(b)` for an implication.
  - Assert relationships between constants at compile time
    (`comptime { assert(rows * row_height <= screen_height); }`), which checks the
    design before it runs.

- **Memory is reserved at startup.** noface reserves its budgets once (`base/memory.zig`:
  the app, a book, scratch, the font and picture decoders) and nothing outside them.
  *Where noface is today:* the budgets cap memory but still allocate from the system as
  they go; the book's budget is filled when a book opens and emptied when it closes.
  The target is Tiger Style's: each budget a fixed region taken at startup, and
  allocation inside it never failing for lack of memory the design didn't plan for.

- **Smallest possible scope** for every variable, and as few in scope as possible.

- **Functions of at most 70 lines [checked].** Keep control flow (every `if` and
  `switch`) in the parent, and push work into helpers that don't branch; keep state in
  the parent and let helpers compute, not change it.

- **Every compiler warning, at the strictest setting.**

- **Don't act directly on outside events.** noface runs at its own pace: touches, power
  events and lipc answers are read into its loop and handled there, never in a
  callback. (A signal only sets a flag the loop reads.)

- **Split compound conditions** into nested `if`/`else`; state invariants positively
  (`if (index < count)`); give an `if` its `else` when the other case matters too.

- **Every error is handled [checked: `catch {}` and `catch unreachable`].** An error
  that can't happen is asserted with the reason; one that doesn't matter says why in a
  comment on that line, and is counted until it does.

- **Always say why.** In comments, in commit messages, in this file.

- **Pass options explicitly** to library functions instead of relying on defaults.

## Performance

- Sketch first: the screen (a full refresh is ~450 ms, a partial one ~120 ms), the user
  drive (a FUSE file system, slow for small reads; map files instead), memory (~480 MB
  free, shared with Amazon's services), the CPU (two Cortex-A53 cores, 32-bit). Optimise
  the slowest first, by how often it's used.
- Batch: lay out a chapter at a time, read every status value in one go
  (`lipc.read`), draw a page whole and show it with one refresh.
- Hot loops in standalone functions with plain arguments, not `self`, so the compiler
  keeps values in registers and the reader sees what's recomputed.

## Developer experience

### Names

- **snake_case** for functions, variables and files **[checked for functions]**. A
  function returning a type keeps Zig's TitleCase (`fn Step(comptime T: type) type`).
- No abbreviations (`index`, not `idx`), except the loop counter of a short numeric loop.
- Units and qualifiers last, most significant first: `latency_ms_max`, `page_index`,
  `width_px`.
- Names that line up: `source` and `target`, not `src` and `dest`.
- A helper called from one function is named after it: `read_sector`,
  `read_sector_callback`.
- Callbacks last in a parameter list.
- In a struct: fields, then types, then functions. Important things near the top.
- One meaning per name.
- An options struct when arguments could be mixed up (two `u32`s).

### Comments and commits

- Comments are sentences: a capital letter, a full stop **[checked: the space after `//`
  and the capital]**. A comment after code may be a phrase.
- Commit messages say what changed and why, in a line a reader can scan in `git log`.

### Avoiding cache bugs

- Don't copy state or keep aliases of it.
- Pass arguments over 16 bytes as `*const`.
- Build large structs in place, through an out pointer.
- Compute a value next to where it's used.
- Simple return types: `void` over `bool`, `bool` over `u32`, `u32` over `?u32`, and
  `?u32` over `!u32`.

### Off-by-one

- An `index`, a `count` and a `size` are different things, and their names say which.
- Division states its rounding: `@divExact`, `@divFloor`, `std.math.divCeil`.

### By the numbers

- `zig fmt` **[checked]**, 4 spaces.
- **At most 100 columns per line [checked]**, no exceptions. Add a trailing comma and
  let `zig fmt` wrap.
- Braces on an `if` unless it fits on one line **[checked]**.

## Dependencies and tooling

- **Zero dependencies but the Zig toolchain**, as Tiger Style asks. *Where noface is
  today:* fonts and pictures are decoded by the stb libraries in `third_party/`; they're
  to be replaced by our own Zig.
- **Tooling is Zig.** Scripts that aren't Zig are counted **[checked]**: the Python
  tools and the device's shell scripts are to become Zig. One exception will stay: KPM,
  the launcher noface is started from, runs `device/kpm/launch.sh` and nothing else, so
  that one line of shell remains, and its count in the baseline stays at one.
