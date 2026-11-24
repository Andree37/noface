# noface

**Your Kindle, without the wait.**

The Kindle Paperwhite is a wonderful screen held back by slow software: a store where
your library should be, and a beat of lag on every page. noface replaces its home
screen and reader with one built for one thing, reading, and built to be fast. Tap,
and the page is already there.

<p align="center"><img src="docs/speed.gif" width="600" alt="The stock Kindle reader and noface side by side, turning pages of the same book: the stock reader's new page appears about 300 ms after the tap, noface's about 60 ms after"></p>

<p align="center"><b>New page in ~60 ms with noface, ~330 ms with the stock reader.</b><br>
<sub>Same Kindle, same book, measured on the device. <a href="docs/DEVELOPING.md#how-the-speed-comparison-was-measured">How</a>.</sub></p>

## Why you'll love it

- **It feels like paper.** Pages turn about five times faster than the stock reader.
  You stop noticing the device and just read.
- **It's quiet.** Your home screen is your books and nothing else. No store, no deals,
  no banners asking you to subscribe.
- **Your battery lasts longer.** Wi‑Fi switches itself off while you read and comes
  back when you're done, and the battery tells you how many days you have left.
- **Your books, your way.** Drop EPUBs onto the Kindle over USB and they're in your
  library, no Send to Kindle, no email, no account.
- **Nothing you rely on breaks.** Your Amazon library, sync, highlights and Wi‑Fi all
  keep working, and your highlights on Amazon books still reach the Kindle apps.
- **Nothing to lose.** Your Kindle's own software stays exactly where it was: leave
  noface from its panel and the Kindle's screens come straight back.

## Unique features

Things the stock Kindle doesn't do:

- **Pages in ~60 ms.** About five times faster than the stock reader, measured on
  the same Kindle.
- **Just your books.** A home screen with your library and nothing else: no store
  shelves, deals or subscription banners.
- **EPUBs that just open.** Copy them over USB and read them; no Send to Kindle.
- **Wi‑Fi off while you read.** It switches itself off a couple of minutes into a
  book and back on when you're done, so the battery lasts longer.
- **Time left on the home screen.** The book you're reading says how long it has left
  right on the home screen, worked out from how fast you actually read.
- **How long your charge will last.** Tap the battery for an estimate in days, from
  how you actually read.
- **Series from your own files.** Books in a series are grouped and kept in order,
  and finishing one offers the next.
- **Bold word starts.** An option that sets the first half of each word in bold, to
  lead the eye along the line.
- **Running mode.** Read on a treadmill. The book shows a sentence or so at a time,
  large and still at one spot, so a bouncing head never loses its place, moving on at
  your running pace. A small map of the page in the corner shows where you are, and
  big taps go back, skip ahead or pause mid-stride. Turn it on in Aa > Themes > Running.

## And everything you'd expect

Definitions (the dictionary downloads itself the first time you hold a word),
highlights and bookmarks (synced with the Kindle apps for Amazon books), footnotes that
open over the page, contents and Go To, a Back button after every jump, search as you
type, four typefaces plus your own from the Kindle's `fonts` folder, size, spacing,
margins, justification and hyphenation, a clock, pictures full screen with zoom, reading
stats with your daily minutes and streak, series you can fix by hand, the book's cover
or your own picture on the lock screen, and Wi‑Fi, Bluetooth, sync, light and warmth in
a panel you pull down from the top.

## Install it in five minutes

**What you need:** a **Kindle Paperwhite, 12th generation (2024)**, jailbroken, with
**KMC** and **KPM** installed (the usual jailbreak guides set both up). That's the
only Kindle noface runs on: it drives the display directly, so on any other model it
checks the screen, says it can't run, and hands straight back to the Kindle's own home
screen.

1. **Download** the latest **noface-&lt;version&gt;-paperwhite_12.zip** from
   [Releases](../../releases/latest) and unzip it on your computer.
2. **Copy** it over: plug the Kindle in by USB, copy the **noface** folder to the
   Kindle's drive, then copy the folder **noface/kpm/noface** into
   **kmc/kpm/packages** on the same drive.
3. **Launch** it: eject the Kindle, and type `;kpm launch noface` into its search bar.

That's it: your library appears, and your books open at the page you were on.

**Start with your Kindle.** To have noface open whenever the Kindle starts, turn on
Aa > More > "Open noface when the Kindle starts". If noface ever fails to start on three
boots in a row, it turns this off itself and the Kindle starts as usual.

**Update** by copying the new **noface** folder over the old one. Your settings,
reading positions, highlights and stats live in a separate **noface-data** folder that
updates never touch.

**Go back** any time: pull the panel down from the top and tap **Kindle**, and the
Kindle's own screens return. To remove noface, turn off starting with the Kindle, then
delete the **noface** folder and **kmc/kpm/packages/noface**. If you had turned on
starting with the Kindle, its one small startup file stays behind in /etc/upstart, idle;
delete **noface-autostart.conf** there too to leave no trace.

**Something not right?** `noface doctor` and `noface selftest` check the Kindle and
noface itself; the [release notes](../../releases/latest) say how to run them and where
to send what they print.

## Good to know

- noface never removes or works around DRM. Books that are protected, as most bought
  from Amazon are, open in the Kindle's own reader instead.
- Jailbreaking is your own choice, under your own agreement with Amazon: it may go
  against Amazon's terms and void your warranty. noface doesn't jailbreak anything.
- noface comes as is, with no warranty. It is an independent project, not made,
  endorsed or supported by Amazon. "Kindle" is a trademark of Amazon.com, Inc. or its
  affiliates, used here only to say which device noface runs on.

## License

Free for personal, noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md): use it, change it and share it,
but don't sell it or build it into a commercial product. Contributions are welcome and
come under the same terms.

noface builds on [stb](https://github.com/nothings/stb) (its font and picture readers
are Zig ports of stb_truetype and stb_image), the TeX hyphenation patterns
and [Wiktionary](https://www.wiktionary.org) definitions (CC BY-SA 4.0), each under its
own license: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
