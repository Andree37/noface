# Developing noface

## Building

Needs [Zig](https://ziglang.org) 0.17.

- `zig build`: the app (`zig-out/bin/noface`) and the picture helper (`jxr2pgm`), for
  the Kindle (32-bit ARM, static).
- `zig build test`: unit tests.
- `zig build check`: the ownership boundaries below, and that every file with tests
  is listed in `src/tests.zig` (a file left out would have its tests never run).
- `zig build scenarios`: scripted runs of the real app (see Tests).
- `zig build sim`: the real app in a browser on this computer (see below).
- `zig build tools`: development tools, also for the Kindle.

Before pushing, run them all; CI does the same (`.github/workflows/ci.yml`).

## Trying a build on your Kindle

With SSH to the Kindle (a jailbroken one, over Wi-Fi or USB networking), replace the
app and start it again. noface is stopped first, and `noface.sh` puts the Kindle's
own screens back as it goes, so nothing is left half-switched:

```sh
zig build
cat zig-out/bin/noface | ssh root@kindle 'cat > /mnt/us/noface/noface.new && chmod +x /mnt/us/noface/noface.new;
  killall noface; sleep 3; mv /mnt/us/noface/noface.new /mnt/us/noface/noface;
  setsid sh /mnt/us/noface/start.sh now >> /mnt/us/noface-data/launch.log 2>&1 < /dev/null &'
```

`/mnt/us/noface-data/noface.log` is what it printed. `zig build tools` makes the
development tools for the Kindle too: copy one over and run it there (for instance
`fbcap` to capture the screen, `touchsim` to tap it). Keep their output out of `/tmp`
when it's large: it's a small RAM disk the Kindle needs for itself.

## Packaging and releases

`tools/package.sh 1.2.3` builds `zig-out/noface-1.2.3.zip`, the same zip a release
carries. Pushing a tag like `v1.2.3` has GitHub build and publish it
(`.github/workflows/release.yml`), with `docs/RELEASE_NOTES.md` as its install steps.
The dictionaries are built and published by hand from the Actions tab
(`dictionaries.yml`).

On the Kindle, the app lives in `/mnt/us/noface/` and opens with `;kpm launch noface`
(the launcher entry is `kmc/kpm/packages/noface/launch.sh`). What noface keeps lives
in `/mnt/us/noface-data/`, so replacing the app folder never loses anything;
`device/data.sh` moves an older install's data there on its first run.

"Open noface when the Kindle starts" (Aa > More) installs
`/etc/upstart/noface-autostart.conf` itself, after asking. Three failed starts in a row
turn it off again by themselves, and the Kindle button in the drag-down panel always
returns to the stock home screen.

## Dictionaries

The Kindle's own dictionaries are DRM protected, so noface uses Wiktionary instead.
Build the files from the extracts at [kaikki.org](https://kaikki.org):

```
curl -LO https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz
curl -LO https://kaikki.org/dictionary/Portuguese/kaikki.org-dictionary-Portuguese.jsonl.gz
python3 tools/build_dictionary.py kaikki.org-dictionary-English.jsonl.gz dict-en
python3 tools/build_dictionary.py kaikki.org-dictionary-Portuguese.jsonl.gz dict-pt
```

Then put `dict-en` (about 95 MB) and `dict-pt` (about 38 MB) in `/mnt/us/noface-data/`.
A book's language is worked out from its text.

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
- `src/base/`: building blocks every folder may use: memory budgets, checks.
- `src/screens/`: the flow of each screen. Of the folders, the only one that calls
  into `kindle/`.
- `src/testing/`: the pretend Kindle the scenario tests and the simulator run against.
  No other folder may import it.
- Files at the top of `src/` may import anything: `app.zig` (what screens share),
  `setup.zig` (putting an App together, the same way for the Kindle, the simulator and
  the tests), `main.zig` (startup), `sim.zig` (the simulator), `scenarios.zig` (the
  scenario tests, also run on the Kindle as `noface selftest`), `core.zig` (the parts
  the tools share) and `tests.zig` (every unit test). The simulator and the scenarios
  stay at the top because a Zig program's main file can only import files below it.
- Every place on the Kindle noface reads or writes is named in `src/kindle/paths.zig`,
  and the shell scripts' copy in `device/data.sh`; a test checks they agree.

The exact rules are at the top of `tools/check/boundaries.zig`.
- `device/`: scripts installed on the Kindle, and `jxr2pgm`, the picture helper that
  decodes JPEG XR with the Kindle's own library.
- `tools/`: development tools, not part of the app. `tools/check/` holds the boundary
  check, `tools/build_dictionary.py` builds the dictionaries, and `fbrec`, `touchsim`
  and `xtap` record the screen and fake taps, for timing and demos.
- `third_party/`: stb libraries.

## How a screen works

Two screens run for as long as noface does: the library (`screens/library.zig`) and a
book (`screens/reader.zig`). Each is a struct with one loop that takes the next action
and hands it to a handler, and each says how it takes touches (`Input.Modes`) in one
place: the library's `touches`, the reader's `touchesFor(view)`.

Everything opened over them (a card, a sheet, a list, the keyboard, the quick panel,
the picture viewer) runs on `screens/screen.zig`. Such a screen is a struct that says
only what makes it different:

```zig
const Bubble = struct {
    pub const Result = void; // What it gives back when done
    pub const touches = Input.Modes.sheet; // Optional: how it takes touches
    a: *app.App,

    pub fn draw(b: *Bubble, part: screen.Part) !void { ... } // .all, or .changing
    pub fn onTap(b: *Bubble, t: screen.Tap) !screen.Step(void) {
        return .close; // Or .stay, .{ .redraw = .changing }, .{ .done = result }
    }
};

var bubble = Bubble{ .a = a };
_ = try screen.run(a, &bubble); // null: closed, or the Kindle locked
```

`screen.run` draws it whole first, waits, and draws again as each step asks. It sets
the touch modes and puts them back after, and when the Kindle locks or noface is told
to leave, it closes the screen and keeps that action for the one underneath. A screen
that changes on its own adds `tick_us` and `onTick`; holds and swipes go to `onAction`.
Typing on the keyboard is `screens/typing.zig`, shared by every screen with a field, and
a list shown a page at a time is `goto.Pages` (`ui/goto.zig`), which turns the page
itself, so the screen only says what a tapped row does.

A caller that must tell a screen closed by the reader from one cut short by the Kindle
locking uses `screen.runToEnd`, which says which. A loop of its own (the lock screen,
the picture's double tap) sets touches and its tick with `Input.enter`, and puts them
back with `leave`.

The build checks each screen: anything else made `pub` on it, a misspelled hook
(`onTik`), or `tick_us` without `onTick` fails with a message saying what's wrong. The
`Example` at the end of `screens/screen.zig` is the screen to copy from.

So a new screen never writes its own wait loop, redraw flags or touch settings. The
loops left are the two above, the lock screen (which waits for the unlock, not a tap),
and following one gesture to its end (`app.followDrag`, the picture's double tap).

## How the speed comparison was measured

`docs/speed.gif` was recorded on a Kindle Paperwhite 12th gen with `tools/fbrec`
(the screen's memory, 30 frames a second, each with its time) while `tools/xtap`
(stock reader) and `tools/touchsim` (noface) tapped to turn eight pages of the same
public-domain book. The time is from the tap until the new page is in the screen's
memory; the e‑ink panel's own refresh follows and takes the same time in both. The
book is Project Gutenberg's edition of *Pride and Prejudice*, with Hugh Thomson's 1894
illustrations.


## Measuring the battery

noface notes the battery level each time it changes (`noface-data/battery`) and how
long you read each day (`noface-data/journal`). After a few whole days off the charger,
run this on the Kindle:

```sh
/mnt/us/noface/noface battery-report
```

It fits the drain of each unplugged day against that day's reading, and prints the
drain per hour of reading, the drain per day on standby, and how long a full charge
lasts at your pace. Days with any charging in them are left out.

## The simulator

noface runs on a computer too, without a Kindle:

```sh
zig build sim                     # with a small test book
zig build sim -Dbooks=$HOME/Books # with the EPUBs in a folder (a full path)
```

Then open http://localhost:8080. It's the real app (library, reader, Aa, the
dictionary, everything) on a screen in memory, against the pretend Kindle the tests
use, so it starts no programs and changes nothing outside `./noface-sim-data`, where
it keeps positions and settings. Click to tap, press and hold to hold, drag sideways
to turn a page, drag down from the top for the light panel; the arrow keys turn
pages. It sets text in the Go fonts, as the Kindle's own aren't on a computer, and
reads only EPUBs. `NOFACE_SIM_PORT` picks another port.

## Tests

- `zig build test`: unit tests, on this computer (GitHub runs them on Linux).
- `zig build scenarios`: the scenario tests, which play scripted touches through the
  real app on a screen in memory, a clock it moves itself and a pretend Kindle that
  starts no programs. GitHub runs them on every push; on the Kindle they're part of
  `noface selftest`.
- One scenario compares five screens (a page, the toolbar, Aa, a definition and the
  library) with reference images in `src/testdata/snapshots`. When a screen changes on
  purpose, write new ones and convert them:

```sh
zig build scenarios                                  # builds zig-out/bin/noface-scenarios for the Kindle
NOFACE_WRITE_SNAPSHOTS=/tmp/snaps <noface-scenarios> # on the Kindle or a computer: writes <name>.pgm
for f in /tmp/snaps/*.pgm; do
  tools/pgm2png.py "$f" src/testdata/snapshots/$(basename "$f" .pgm).png
done
```

## Where common changes go

Most changes are one entry in one table; the code around it places, draws and saves
it. The build or a test fails if a second place is needed and missed.

| To add | Change | What follows by itself |
|---|---|---|
| A switch in Aa | a field in `Settings` (`model/settings.zig`), a line in `saved` there, a line in `switches` (`ui/aa.zig`) | its place on the tab, drawing, taps, saving; the page-break key counts it unless it's in `not_layout` |
| A tile in the quick panel | a `Hit`, a line in `tiles` (`ui/menu.zig`), its action in `panelControl` (`screens/panel.zig`) | its place, icon, on/off look and label; the compiler wants the action |
| A value from the Kindle in the status bar or panel | a field in `Quick` (`model/quick.zig`), a line in `readings` (`kindle/lipc.zig`) | reading it with the others, the redraw when it changes, the pretend Kindle's answer |
| A value kept per book | a field in `State` (`sys/state.zig`) | saving and reading it by name; older files read it as its default |
| A file noface keeps, or a place on the Kindle | `kindle/paths.zig`, and `device/data.sh` if a script needs it | the test that the two agree |
| A tone, corner or the status strip's height | `ui/style.zig` | every screen using it |
| An item in the reader's ⋮ menu | `screens/reader/more.zig` | |
| A sheet, card or list | a struct run by `screen.run` (see above) | its loop, touches and redraws |
| An App-wide font size or page margin | `setup.zig` | the Kindle, the simulator and the tests alike |

