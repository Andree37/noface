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

**Zero tolerance.** There is no baseline and no debt: any break of any checked rule,
in any file, fails the check, which lists each one by file and line. Code follows every
rule from its first line.

The few genuine exceptions are marked in the code, at the exact spot, with the reason.
The check accepts these five markers and nothing else, and a marker with nothing to
excuse is itself a break, so none outlives its reason. A reviewer finds them all with
`grep -rn "// usize:\|// Assertions:\|// Unbounded:\|// Ignored:\|// Not a size:" src tools build.zig`.

| Marker | Where | Allowed only for |
|---|---|---|
| `// Unbounded: <why>` | just above the loop | a loop that by design never ends: an event loop |
| `// Ignored: <why>` | on the line | an error whose only effect is something missing, nothing worse |
| `// usize: <why>` | on the line, or just above it | a `usize` the language, C or the kernel's ABI requires: a syscall's signature, C's `size_t`, the panic handler's or `std.mem.Allocator`'s interface |
| `// Assertions: <why>` | just above the function (with its doc comment) | a function that can't honestly make two assertions, when its file's average needs it: it only reads outside data, or is a one-line call to C or lipc, or reads or sets fields every value of which is valid |
| `// Not a size: <why>` | on the line, or just above it | a number in the screens' code that the size check takes for a length on the screen but isn't one: a step of a setting, a row's place, a test page's own size |

An `// Assertions:` function is left out of its file's average, its assertions with
it. Never pad a function with assertions that check nothing to avoid one; never assert
on outside data to avoid one either.

Test blocks are checked for their imports, line length and comments only: a test
states what must hold with `expect`, builds odd inputs on purpose and may drop what it
doesn't look at, so the rules for the code it tests (assertions, ignored errors,
`usize`, loops) don't apply inside one.

## Safety

- **Simple, explicit control flow. No recursion [checked: a function calling itself
  by name].** Every execution that should be bounded is bounded. A tree (an EPUB's table of contents, a KFX structure)
  is walked with an explicit stack of fixed depth, and a depth past it is an error.

- **A limit on everything.** Every loop and every queue has a fixed upper bound.
  `while (true)` is counted **[checked]**: write the bound in the loop
  (`for (0..attempts_max)`, asserting what running out means). A loop that by design
  never ends (the reader's event loop) says so in a comment just above it, starting
  `// Unbounded: ` and saying why; the check accepts that and nothing else.

- **Explicitly sized types** (`u32`, `u64`, `i32`). `usize` is a break **[checked]**:
  slice indexes and lengths are usize without being written, so convert at that edge.
  Where a signature must say `usize` (a Linux syscall, C's `size_t`, the panic handler,
  `std.mem.Allocator`'s interface), mark it `// usize: <why>`. A position in a book, a count of pages, a size on disk: `u32` or `u64`,
  chosen by the largest value it can hold, which the code asserts.

- **Assertions.** At least **two per function on average [checked]**, counted per
  file, as Tiger Style has it. A file short of that fails with each of its functions
  below two listed, as the places to add them; one that can't honestly have two is
  marked `// Assertions: <why>` (above). A function of at most five lines of body is
  left out of the average, as a marked one is: it does one thing, and an assertion
  there mostly repeats its line. Never pad a function to meet the average; an
  assertion states something that would be a bug if false. Counted as assertions: `assert`, `check.that`,
  `check.thatf`, `@compileError`, and a call to `invariants()`, a struct's method that
  asserts what holds of it between calls. In `src/scenarios.zig` and `src/scenarios/`, `expect` too: the
  scenarios are tests that also ship as `noface selftest`, so a failed check reports
  and goes on to the next scenario instead of stopping, and `expect` is their
  assertion. `std.debug.assert` for invariants; `check.that` / `check.thatf` (`src/base/check.zig`)
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
  - Never assert what the line above just made true **[checked]**: `x = v;` then
    `assert(x == v);`, or `if (c) return;` then `assert(!c);`. It can't fail.
  - `if (a) assert(b)` for an implication.
  - Assert relationships between constants at compile time
    (`comptime { assert(rows * row_height <= screen_height); }`), which checks the
    design before it runs.

- **Memory is reserved at startup.** Each budget (`base/memory.zig`) hands out memory
  from a fixed region of address space taken from the system once, at startup, with
  sizes set in `setup.zig`: the app (64 MB) in `main.zig`, the picture decoders
  (128 MB) by `setup.decoders`, the glyphs fonts draw (a fixed cache of ~17 MB that
  gives up the least recently drawn, and 1 MB each glyph is drawn in) by
  `setup.use_glyph_cache`; the library (44 MB: 8 bytes for each book it can hold, sorted
  there, the buffers its index on the user drive is built through, a page of books
  read back, and a pool of 68 covers), what each EPUB is read for while the library is
  found (32 MB), an open book (128 MB), its pages after a settings change (32 MB) and
  one action's scratch (8 MB) by `setup.assemble`; ~450 MB of address space in all, of which only
  what's touched is memory. Then `memory.seal()`, and nothing more is asked of the
  system: a region that runs out is an error the caller handles (a book too big shows
  a notice), never a crash. The app's, the decoders' and the library's regions free
  and reuse blocks in any order; the others hand out one block after another, as
  arenas, emptied whole at a named point: the book's when it closes, the pages' before
  each layout, the scratch after each action, the library scratch after each EPUB,
  the glyphs' scratch before each glyph.
  Something that lives inside one of those lifetimes goes on top of its arena and is
  rewound when it ends: the picture viewer on the book's. Pages come in as they're
  first touched, and an emptied region hands its pages back (`madvise`), still
  reserved, so an idle noface holds no more than before. What grows with the reader's
  data is never capped in memory: a book's notes, however many, are rewritten through
  a fixed buffer on the stack. A budget without a region asking the system for memory
  after `seal` is a bug: a crash in a debug build and in the tests, a failed scenario
  (they run sealed, as the Kindle does), else counted and logged. The picture
  decoders have no memory until they're given a budget (`decoder_memory.use`). A
  glyph the cache can't keep is drawn again when next needed, so text never depends
  on what fits.

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

- **Every error is handled [checked: `catch {}`, `catch unreachable` and
  `else |_| {}`].** An error
  that can't happen is asserted with the reason. One that may be ignored (a cover that
  won't decode means no picture, nothing worse) says so on that line, in a comment
  starting `// Ignored: ` with the reason; the check accepts that and nothing else.

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

### Imports

- **All of a file's imports at its top [checked]**, where a reader sees at once what it
  depends on: never inside a function, a test or an expression, and never below the
  file's first function, test, type or comptime block. `_ = @import(…)`, which only
  lists a file's tests, is the exception.
- **No import a file doesn't use [checked]**: one named only on its own line, as
  `const failed = @import("os.zig").failed;` with nothing else using `failed`, is unused.

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
- **No bare sizes in the screens' code [checked]** (`src/ui/`, `src/screens/`,
  `src/layout/`, `src/gfx/` and the files of `src/` itself): every
  width, gap, inset and band comes from `src/ui/style.zig`, where sizes are written in
  points and turned into the screen's pixels by its density (`style.space`,
  `style.text`, `style.fingertip`, `style.button_width`), or is worked out from the
  parts it sits by or the screen's size (a share of the width, rows that fit the
  height). So a layout is the same physical size on any Kindle and fills a bigger
  screen with more, not with bigger gaps. The check flags a number of 3 or more in a
  declaration named like a size or given to a drawing call; a divisor, an array's
  length, a number in an assertion and a number times a dotted name, taken for a
  count of a size named elsewhere (`3 * style.fingertip`, `2 * line.height`), are left
  alone. The icons draw in their own grid, and the file formats' decoders (JPEG, PNG,
  TrueType, CFF) keep the formats' own numbers. `src/layout/` may not import the
  scale, so the page's sizes reach it in its `Layout`, set from the scale by whoever
  lays out. The touch zones (`src/kindle/touch.zig`), below the interface, are written
  in points too, turned into pixels by the same density (`model/device.zig`) with a
  `pt(` of their own, and checked the same way: a number given to that `pt(` is on
  the scale, any other is bare.

## Dependencies and tooling

- **One dependency besides the Zig toolchain**, where Tiger Style asks for none:
  uucode (<https://github.com/jacobsandlund/uucode>, MIT, pure Zig, used by Ghostty),
  for Unicode's tables. What a character is (a letter, a mark, a space) and its plain
  form are Unicode's to say, and its tables change with each Unicode version; copied
  by hand they were partial (Latin only) and went stale. It is pinned by commit and
  hash in `build.zig.zon`, only the fields noface reads are built in (build.zig
  `unicode_fields`), and only `src/text/unicode.zig` imports it **[checked]**, so it
  is one file to read when it's bumped. Nothing else comes from outside: fonts and
  pictures are read by noface's own Zig in `src/gfx/`, ports of stb_truetype and
  stb_image (see `THIRD_PARTY_NOTICES.md`).
- **Tooling is Zig.** Scripts that aren't Zig are counted **[checked]**, and there are
  none: the tools that run on a computer (`tools/build_dictionary.zig`,
  `tools/pgm2png.zig`, `tools/package.zig`) and everything that runs on the Kindle
  besides the app (`src/launch.zig`, built as `noface-launch`) are Zig.

  *The one exception:* KPM, the launcher noface is opened from, runs a package's
  `launch.sh` and nothing else, so `device/kpm/launch.sh` stays shell. It is a shim:
  comments, then one line that execs `noface-launch`. The check accepts that file by
  its path, and only while it has one line of code; a second line counts it again.
  The startup file, `device/noface-autostart.conf`, is an upstart job rather than a
  script: its one line runs `noface-launch autostart`.
