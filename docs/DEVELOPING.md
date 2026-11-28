# Developing noface

## Style

noface follows Tiger Style, checked by `zig build check`: see
[TIGER_STYLE.md](TIGER_STYLE.md).

## Building

Needs [Zig](https://ziglang.org) 0.17.

- `zig build`: the app (`zig-out/bin/noface`), its launcher (`noface-launch`) and the
  picture helper (`jxr2pgm`), for the Kindle (32-bit ARM, static).
- `zig build test`: unit tests.
- `zig build check`: the ownership boundaries below, that every file with tests
  is listed in `src/tests.zig` (a file left out would have its tests never run),
  `zig fmt`, and Tiger Style with zero tolerance: any break anywhere fails, listed by
  file and line, short of an exception marked in the code with its reason
  ([TIGER_STYLE.md](TIGER_STYLE.md#how-its-kept)).
- `zig build scenarios`: scripted runs of the real app (see Tests).
- `zig build tools`: development tools, also for the Kindle.
- `zig build layouts`: the whole interface laid out for every other Kindle's screen
  (`device.Model`: the Basic, the Scribe, a 167 dpi Kindle), built, with the unit
  tests and the scenarios run on each: a test takes its numbers from the layout,
  never one Kindle's pixels. Every layout checks as it's built that it fits (nothing
  overlaps or runs off the screen, every control takes a fingertip), so a build that
  passes fits that Kindle. Sizes are
  points turned into pixels by the screen's density (`src/ui/style.zig`), never pixels.
  A build is laid out for one Kindle, `-Dlayout=<model>` (the Paperwhite unless
  asked), and starts only on that one's screen.
- `zig build gates`: all of the above at once, as every change passes before it's
  committed. Its exit status is the answer: read that, not what scrolls past.
- `zig build clean`: empties the build cache (`.zig-cache`). Zig keeps every version
  it has built and never removes one, so it grows by gigabytes as the code changes;
  everything is rebuilt as it's next needed.
- `zig build host-tools`: the tools that run on this computer, in `zig-out/bin`: the
  dictionary builder, the snapshot converter and the packer.
- `zig build package -Dversion=1.2.3`: the release zips, one per shipped Kindle (see
  Packaging).

Before pushing, run them all; CI does the same (`.github/workflows/ci.yml`).

## Trying a build on your Kindle

With SSH to the Kindle (a jailbroken one, over Wi-Fi or USB networking), replace the
app and start it again. noface is stopped first, and its launcher puts the Kindle's
own screens back as it goes, so nothing is left half-switched:

```sh
zig build
cat zig-out/bin/noface | ssh root@kindle 'cat > /mnt/us/noface/noface.new && chmod +x /mnt/us/noface/noface.new;
  killall noface; sleep 3; mv /mnt/us/noface/noface.new /mnt/us/noface/noface;
  /mnt/us/noface/noface-launch now'
```

`noface-launch now` returns at once and opens noface in the background; a changed
launcher is copied over the same way (`noface-launch`, while noface isn't running).
`/mnt/us/noface-data/noface.log` is what noface printed, and `launch.log` what the
launcher did. `zig build tools` makes the
development tools for the Kindle too: copy one over and run it there (for instance
`fbcap` to capture the screen, `touchsim` to tap it). Keep their output out of `/tmp`
when it's large: it's a small RAM disk the Kindle needs for itself.

To try it end to end without touching the reader's own books, places or settings,
`noface-launch e2e <folder>` (a full path) runs noface on the EPUBs in
`<folder>/documents`, keeping everything it writes, its log too, in `<folder>/data`.

`tools/e2e` plays a script of touches against it and checks what noface logs and how
soon it draws: `tools/e2e/reader.e2e` takes every gesture the reader has (turning by
tap and swipe, the toolbar, a bookmark, the quick panel, looking up and highlighting,
locking, Home) with time budgets for each, and `tools/e2e/library.e2e` every control
the library has (paging, the filter, each sort, stats, search typed on its keyboard, a
book's actions, the quick panel), `tools/e2e/running.e2e` running mode (turned on
from Aa's Themes tab: its phrases, its taps, a drip let go, pausing, the card, and
stopping from it), and `tools/e2e/sheets.e2e` what opens over a book and the library
(a book's series list, Go To, the chapter skips, the book's search, the ⋮ menu and its
Go to page, Aa's tabs, themes and switches). Every control is tapped by its name
(`screens/places.zig`); what moves with the text, a footnote's mark, a picture, a
highlight's Delete bubble, is tapped where noface's log says it drew it
(`tap placed note`, `screens/placed.zig`); only words on a page are tapped where they
are. `tools/e2e/goto.e2e` bookmarks one page more than Go To's list holds and pages
the list on and back, and `tools/e2e/notes.e2e` opens a footnote's panel and shows a
picture whole.

`e2e all <folder>` plays every script, built into the tool, each on the test folder it
needs, which it makes in `<folder>` with the test books built in too
(`src/testdata/books.zig`): `books/`, holding `Scenario Book.epub` and numbered
copies from `Scenario Book 02.epub`, one more book than a later library page holds, so
the library has two pages (copies past those, left by an older build, are removed),
and `notes/`, holding `Notes and Pictures.epub`. Copy the tool to `/mnt/us` (a file made executable
in `/tmp` can't be run) and play them all, with the reader's own noface stopped first
and started again after:

```sh
kill -TERM $(pidof noface)                       # the reader's noface, stopped
/mnt/us/noface-e2e/e2e all /mnt/us/noface-e2e
/mnt/us/noface/noface-launch now &              # and started again
```

`e2e <script> <test folder>` plays one script, while one is being written, on a test
folder whose `documents/` already hold its books, such as one `all` made
(`/mnt/us/noface-e2e/books`).

For each script the tool wakes the Kindle and holds it awake, makes the folder's
`data` fresh, starts noface on its books, waits for it to say it's idle on its
library, plays the script, and stops noface, also when a step fails; one script
failing doesn't stop the rest. In a test run noface logs `idle: lifted at <time>` each
time it goes back to waiting with everything it read handled
(`src/kindle/input/idle.zig`); `still` and `shot` wait for that line, from after the
last touch's lift, so the next touch is never made before its screen is shown. Each step prints `ok` or `FAIL`; `drawn` steps print what they
measured, and `shot` steps leave PGM screenshots in `out`.

## Which Kindles

The Kindles noface supports, and those it's working towards, are listed in
[DEVICES.md](DEVICES.md), the one list of them. A release carries one zip per Kindle
that's been run through `e2e all` on a real one (build.zig `shipped`); `zig build
layouts` only shows a layout fits. A Kindle joins `shipped` and DEVICES.md's
supported table together.

## The one dependency

uucode, Unicode's tables in Zig, is pinned in `build.zig.zon` by commit and hash, and
fetched by `zig build` into Zig's cache the first time (its tables are generated
then, in a few seconds, and cached). Only `src/text/unicode.zig` imports it, and only
the fields in build.zig `unicode_fields` are built in; a field used without being
listed is a compile error naming it. To move to a newer uucode, read what changed
upstream since the pinned commit, then
`zig fetch --save=uucode git+https://github.com/jacobsandlund/uucode#<commit>`, and
run the gates and `e2e all` on a Kindle: a new Unicode version can fold a few more
letters, so a dictionary built before it is rebuilt with `build_dictionary` to match.

## Reading a crash

The app on the Kindle carries no symbols, so a crash logs where it came from as
addresses, in `noface.log`: why (`panic: <why>`, or `Segmentation fault`, `Bus error`,
`Illegal instruction` with the address read), then `crash in build <id> at: 0x… 0x…`,
the innermost first (`src/sys/crash.zig` walks the frame pointers the app is built
with). The app is built once with its symbols and lines, and the Kindle's copy is
that file stripped (`tools/strip.zig`), so the code is the same, byte for byte, and
both carry the same build ID. `zig build` writes it as `zig-out/bin/noface-symbols`
beside `zig-out/bin/noface`, and each release carries it as
`noface-<version>-<model>-symbols`. Read the addresses in the one whose build ID is
the crash's (LLVM's tools: `brew install llvm` on a Mac, which leaves them out of the
`PATH`):

```sh
llvm=$(brew --prefix llvm)/bin
$llvm/llvm-readelf -n noface-symbols | grep "Build ID"   # the same as the crash's
$llvm/llvm-symbolizer --obj=noface-symbols --inlining 0x2a1f3 0x3b0c7
```

## Packaging and releases

`zig build package -Dversion=1.2.3` builds everything and packs one zip per shipped
Kindle, `zig-out/noface-1.2.3-<model>.zip` (`tools/package.zig`), laid out for that
Kindle's screen, and `zig-out/KINDLES.md`, the table of them (`tools/kindles.zig`).
build.zig's `shipped` lists the Kindles: one joins only after `e2e all` passed on a
real one. Pushing a tag like `v1.2.3` has GitHub build and publish them
(`.github/workflows/release.yml`), with one `SHA256SUMS` for all, and notes made of
`docs/releases/1.2.3.md`, the table, and `docs/RELEASE_NOTES.md`'s install steps.
The dictionaries are built and published by hand from the Actions tab
(`dictionaries.yml`).

On the Kindle, the app lives in `/mnt/us/noface/` and opens with `;kpm launch noface`
(the launcher entry is `kmc/kpm/packages/noface/launch.sh`, a one-line shim that runs
`noface-launch`). What noface keeps lives in `/mnt/us/noface-data/`, so replacing the
app folder never loses anything.

`noface-launch` (`src/launch.zig`) is a program of its own, apart from the app, so
nothing the app does can take it down. It writes the book list, pauses the Kindle's
own screens, runs noface with its output in `noface.log`, and puts the screens back
however noface ends (it leaves, crashes, is killed, or hangs: a watchdog ends noface
when its heartbeat stops for 2 minutes with the Kindle awake). A crash of the launcher
itself puts them back too, from its panic handler.

"Open noface when the Kindle starts" (Aa > More) installs
`/etc/upstart/noface-autostart.conf` itself, after asking; at boot it runs
`noface-launch autostart`. Three failed starts in a row turn it off again by
themselves, and the Kindle button in the drag-down panel always returns to the stock
home screen.

## Dictionaries

The Kindle's own dictionaries are DRM protected, so noface uses Wiktionary instead.
Build the files from the extracts at [kaikki.org](https://kaikki.org):

```
zig build host-tools
curl -LO https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz
curl -LO https://kaikki.org/dictionary/Portuguese/kaikki.org-dictionary-Portuguese.jsonl.gz
zig-out/bin/build_dictionary kaikki.org-dictionary-English.jsonl.gz dict-en
zig-out/bin/build_dictionary kaikki.org-dictionary-Portuguese.jsonl.gz dict-pt
```

Then put `dict-en` (about 95 MB) and `dict-pt` (about 38 MB) in `/mnt/us/noface-data/`.
A book's language is worked out from its text.

## Reading places on a device

Where a book was left is kept by the device's own software too, so its reader and
other devices go on from noface's place, and noface from theirs. `src/platform.zig`
picks each device family's code for it at build time (`model/models.zig` `Family`);
every family's module has the same declarations, which the build checks for all of
them. The reader only sees places in its own numbering (`model/place.zig`): one asked
once as a book opens, which is taken when this device's own reader made it later than
noface's save, and offered on a card when another device did; and noface's own, kept
as the book closes or the device locks, stamped with its save's time so it never reads
back as a later one.

On a Kindle (`kindle/reading_place.zig`, found on firmware 5.20) a book's places are
rows of its annotation database:

- `kindle.local_most_recent_read` (dataset 8, in `nonsyncable_annotations`): this
  Kindle's own, never sent.
- `kindle.most_recent_read` (dataset 4) and `kindle.last_read` (dataset 9, the furthest
  read, which only moves forward): Amazon's, from every device, with the device's name
  (`Local` for this Kindle). They're sent from the `local_edit` outbox, a row the same
  shape as Amazon's own, as highlights are.

A book is named as the database already names it: its dataset id (whose last digit is
whether you own it) and its `book_data` are copied from its own rows, so one the Kindle
has never named is left alone. The database is asked once, read-only, with a short wait
for a write: a reader that holds it makes the stock reader's own saves fail. The stock
reader on the same Kindle opens at a place of its own, in each book's `.sdr` sidecar,
not at these, so a place noface keeps reaches it only through Amazon.

The library shows a place made on another device too, without opening the book. The
catalog export (`noface-launch export`, run as noface starts
and as the Kindle wakes) copies the database to RAM, as it copies the catalog, and
lists each book's latest `kindle.most_recent_read`: its position and time. Each time
noface saves a place it also saves where the book ends in the device's numbering
(`outside_end` in the book's state file), and the library turns a place newer than
both the stock reader's and noface's into a percent by it (`library/builder.zig`
`merged`). A book noface hasn't opened since has no end saved and shows the catalog's
percent.

## Layout

Code is split by who owns it. `zig build check` fails if a file imports across these lines.

- `src/kindle/`: everything that knows Amazon: the KFX format, lipc services, the
  store, annotation sync, the catalog export, fonts, the screen and input devices.
  Screens ask the display for a kind of refresh (`.page`, `.screen`, `.flash`,
  `.quick`, `.clock`, `.clean`); `hwtcon.Refresh` turns those into this panel's
  waveforms, the one table a different panel would change.
- `src/sys/`: the system: files, processes with timeouts, time. `sys/calls.zig` is the
  system calls under Linux's names: Linux's own on the Kindle, the C library's on a
  Mac (`sys/calls_portable.zig`), so everything but the Kindle's screen and touch
  drivers builds and runs on a computer too.
- `src/model/`: our data, with no I/O: books, settings, the library, highlights,
  bookmarks, search, the dictionary format, the reading journal, reading stats.
- `src/gfx/`: pixels, fonts and pictures.
- `src/layout/`: setting a book's text into pages, and hyphenation.
- `src/ui/`: drawing screens and mapping taps to controls.
- `src/epub/`: the open EPUB format, read into our model.
- `src/library/`: the library's index on the user drive: built from the catalog, the
  EPUBs found and the series set by hand, mapped, and its books' ids sorted in memory
  (8 bytes a book) by the comparisons `model/catalog.zig` sorts a list with.
- `src/base/`: building blocks every folder may use: memory budgets, checks.
- `src/screens/`: the flow of each screen. Of the folders, the only one that calls
  into `kindle/`.
- `src/testing/`: the pretend Kindle the scenario tests run against.
  No other folder may import it.
- Files at the top of `src/`: the App (`app.zig`, what screens share) and what it's
  made of, each owning its part: `display.zig` (the screen, the page cache and the
  overlay sheets are composed in), `user_data.zig` (the reader's settings, speed and
  journal, and their files), `regions.zig` (the memory read into), `languages.zig`
  (hyphenation and dictionaries) and `typefaces.zig` (the reading fonts). These may
  import anything but `screens/` and `testing/`, as screens build on them. The roots
  put a program together and may import anything: `setup.zig` (assembling an App, the
  same way for the Kindle and the tests), `main.zig` (startup), `scenarios.zig` (the
  scenario tests, also run on the Kindle as `noface selftest`; the scenarios
  themselves are in `scenarios/`, by what they're about, with `harness.zig`, which
  plays them, and `taps.zig`, their touches by name), `core.zig` (what the
  tools share) and `tests.zig` (every unit test). The scenarios stay at the top
  because a Zig program's main file can only import files below it.
- What a screen keeps between openings sits beside the drawing it serves, in `ui/`
  (`aa.Kept`, `lock.Kept`), and the App holds it.
- Every place on the Kindle noface reads or writes is named in `src/kindle/paths.zig`,
  for the app and its launcher alike; a test checks that KPM's `launch.sh` and the
  startup file name the launcher it does.

The exact rules are at the top of `tools/check/boundaries.zig`.
- `device/`: what's installed on the Kindle besides the programs: KPM's `launch.sh`
  shim and the startup file, and `jxr2pgm`, the picture helper that decodes JPEG XR
  with the Kindle's own library.
- `tools/`: development tools, not part of the app. `tools/check/` holds the boundary
  check, `build_dictionary` builds the dictionaries, `pgm2png` converts snapshots,
  `package` packs a release, and `fbrec`, `touchsim` and `xtap` record the screen and
  fake taps, for timing and demos.

## How a screen works

noface has one event loop, `screen.run_root` (`screens/screen.zig`), and every screen
runs on it. The screens open are a stack of fixed depth: the library
(`screens/library.zig`) at its root, a book (`screens/reader.zig`) over it, and over
either a card, a sheet, a list, the keyboard, the lock screen, the picture viewer or a
finger being followed. Each turn the loop waits once for something to happen and hands
it to exactly one screen: the one in front. A lock or a stop goes instead to the first
screen under it that takes it (`takes`: the library, a book, the lock screen), and every
screen in front of that one ends `interrupted` first. A tap whose finger touched while
another screen was in front is dropped, as it was meant for that one.

A screen is a struct that says only what makes it different:

```zig
const Bubble = struct {
    pub const Result = void; // What it gives back when done
    pub const touches = Input.Modes.sheet; // Optional: how it takes touches
    a: *app.App,

    pub fn draw(b: *Bubble, part: screen.Part) !void { ... } // .all, or .changing
    pub fn on_tap(b: *Bubble, t: screen.Tap) !screen.Step(void) {
        return .close; // Or .stay, .{ .redraw = .changing }, .{ .done = result }
    }
};
```

The screen under it keeps it in a field of its own, opens it by returning
`.{ .push = screen.open(&self.bubble, &self.bubble_ending) }`, and reads how it ended
(done with a result, closed, or interrupted) in its `on_resume`. A screen is drawn whole
as it opens and again as each step asks. A screen that changes on its own adds
`tick_us` and `on_tick`; holds, swipes and drags go to `on_action`; one whose touches or
tick change as it's used says so in `setting` (the library, a book). A screen that only
leads to others (a book's actions, setting a series, getting a dictionary) draws
nothing itself and opens its first in `on_open`. Typing on the keyboard is
`screens/typing.zig`, shared by every screen with a field: each keeps a `Typist` (the
keyboard's layer, shift, and a held letter's accents), takes touches as `typing.touches`
says, and hands it taps and holds; the keys and layers are `ui/keyboard.zig`'s. A list
shown a page at a
time is `goto.Pages` (`ui/goto.zig`); a card of rows is `card.over`
(`screens/card.zig`); following a finger is `Drag` (`screens/drag.zig`).

The build checks each screen: anything else made `pub` on it, a misspelled hook
(`onTik`), or `tick_us` without `on_tick` fails with a message saying what's wrong. The
`Example` at the end of `screens/screen.zig` is the screen to copy from.

So a new screen never writes a wait loop, redraw flags or touch settings: there is
only the one loop.

## How the speed comparison was measured

`docs/speed.gif`, and the video it's made from, `docs/speed.mp4`, were recorded on a
Kindle Paperwhite 12th gen with `tools/fbrec`, the screen's memory 30 frames a second,
each frame with its time. Both readers do the same steps in Project Gutenberg's edition
of *Pride and Prejudice*, with Hugh Thomson's 1894 illustrations, starting from its
cover: four page turns, the toolbar, the contents, Chapter V, and two more page turns.
`tools/xtap` tapped the stock reader, logging each finger down on the recorder's clock;
`tools/e2e` played the same steps on noface, its `drawn` check timing each from the
finger's lift, to which the tap's 80 ms down is added. A step's time runs from the
finger down until its screen is last drawn before the next tap: the stock reader draws
some steps in stages (its chapter jump first closes the contents, then shows the
chapter), and the time is to the last of them. The e‑ink panel's own refresh follows
and takes the same time in both, so it's left out.

## Tests

- `zig build test`: unit tests, on this computer (GitHub runs them on Linux).
- `zig build gates`: everything a change passes before it's committed, as one step.
- Scripts in `tools/e2e/` play touches on the Kindle itself, against noface's own test
  books, tapping controls by name (`screens/places.zig`) and what moves with the text
  where noface logged it (`screens/placed.zig`), so they follow layout.
- `zig build scenarios`: the scenario tests, which play scripted touches through the
  real app on a screen in memory, a clock it moves itself and a pretend Kindle that
  starts no programs. GitHub runs them on every push; on the Kindle they're part of
  `noface selftest`.
- The scenarios compare screens with reference images, and where the test book's pages
  break with recorded digests (`breaks.txt`), in `src/testdata/recorded/<model>/`, for
  every Kindle `zig build layouts` lays out, so a change that moves anything on any of
  them is seen. The screens are the `Snapshot` list in `src/scenarios/harness.zig`:
  among them a page, the toolbar, Aa's tabs, running, the library, a note's panel and
  a picture shown whole. The last two are of `src/testdata/notes.epub`, a book with a
  footnote and a picture, which a scenario opens with `.book = .notes`. A book sent to
  the Kindle, in Amazon's format with Amazon's positions, is written by
  `src/testing/kfx_book.zig` from words of its own (`.book = .sent`); with it the
  pretend Kindle answers the device's own places for it (`.outside_places`), so
  `src/scenarios/elsewhere.zig` plays the place kept in step with the Kindle and other
  devices, and the card offering another's. When a screen changes on purpose, write
  new ones for each Kindle (`-Dlayout=<model>`), look at them, and convert them. When
  the page breaks move on purpose, the scenario that compares them prints the new
  digests for `breaks.txt`. A Kindle added to `device.Model` starts from another's
  folder copied as its own, so it builds; its screens are then written over and its
  digests put in as printed. Write them on this computer, not on a Kindle: a large
  screen's images don't fit the Kindle's `/tmp`.

```sh
zig build -Dlayout=<model> scenarios host-tools   # zig-out/bin/noface-scenarios-host
mkdir -p snaps && NOFACE_WRITE_SNAPSHOTS=$PWD/snaps zig-out/bin/noface-scenarios-host
for f in snaps/*.pgm; do
  zig-out/bin/pgm2png "$f" src/testdata/recorded/<model>/$(basename "$f" .pgm).png
done
```

## Where common changes go

Most changes are one entry in one table; the code around it places, draws and saves
it. The build or a test fails if a second place is needed and missed.

| To add | Change | What follows by itself |
|---|---|---|
| A switch in Aa | a field in `Settings` (`model/settings.zig`), a line in `saved` there, a line in `switches` (`ui/aa.zig`) | its place on the tab, drawing, taps, saving; the page-break key counts it unless it's in `not_layout` |
| A tile in the quick panel | a `Hit`, a line in `tiles` (`ui/menu.zig`), its action in `panel_control` (`screens/panel.zig`) | its place, icon, on/off look and label; the compiler wants the action |
| A value from the Kindle in the status bar or panel | a field in `Quick` (`model/quick.zig`), a line in `readings` (`kindle/lipc.zig`) | reading it with the others, the redraw when it changes, the pretend Kindle's answer |
| A value kept per book | a field in `State` (`sys/state.zig`) | saving and reading it by name; older files read it as its default |
| A file noface keeps, or a place on the Kindle | `kindle/paths.zig` | the app and the launcher both use it |
| A tone, corner or the status strip's height | `ui/style.zig` | every screen using it |
| An item in the reader's ⋮ menu | `screens/reader/more.zig` | |
| A sheet, card or list | a struct opened with `screen.open` (see above) | its waiting, touches and redraws |
| An App-wide font size or page margin | `setup.zig` | the Kindle and the tests alike |

