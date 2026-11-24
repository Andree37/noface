<h1 align="center">noface</h1>

<p align="center">
  <b>Your Kindle, without the wait.</b><br>
  A fast, quiet home screen and reader for the Kindle Paperwhite.
</p>

<p align="center">
  <a href="https://github.com/Andree37/noface/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Andree37/noface?label=release"></a>
  <a href="https://github.com/Andree37/noface/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/Andree37/noface/total"></a>
  <img alt="Kindle Paperwhite 12" src="https://img.shields.io/badge/Kindle-Paperwhite%2012-informational">
  <a href="LICENSE.md"><img alt="License: PolyForm Noncommercial" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue"></a>
</p>

<p align="center">
  <a href="https://github.com/Andree37/noface/releases/latest"><b>Download</b></a> ·
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="docs/DEVELOPING.md">Developing</a>
</p>

<p align="center"><img src="docs/speed.gif" width="600" alt="The stock Kindle reader and noface side by side, turning pages of the same book: the stock reader's new page appears about 300 ms after the tap, noface's about 60 ms after"></p>

<p align="center"><b>New page in ~60 ms with noface, ~330 ms with the stock reader.</b><br>
<sub>Same Kindle, same book, measured on the device. <a href="docs/DEVELOPING.md#how-the-speed-comparison-was-measured">How</a>.</sub></p>

## About

The Kindle Paperwhite has a wonderful screen held back by slow software: a store where
your library should be, and a beat of lag on every page. noface replaces its home
screen and reader with one built for reading, and built to be fast. Tap, and the page
is already there.

Everything you rely on keeps working: your Amazon library, sync, highlights, the
dictionary and Wi‑Fi. And the Kindle's own software is never touched, so going back is
one tap.

## Features

- **Fast.** Pages turn in about 60 ms, five times faster than the stock reader on the
  same Kindle. You stop noticing the device and just read.
- **Quiet.** Your home screen is your books and nothing else: no store, no deals, no
  banners asking you to subscribe.
- **EPUBs that just open.** Copy them over USB and they're in your library. No Send to
  Kindle, no email, no account.
- **Kind to your battery.** Wi‑Fi switches itself off a couple of minutes into a book
  and back on when you're done, and a tap on the battery says how many days it has left
  at the way you read.
- **Knows your pace.** The book you're reading says how long it has left, right on the
  home screen, from how fast you actually read.
- **Series, sorted.** Books in a series are grouped and kept in order from your own
  files, and finishing one offers the next.
- **Running mode.** Read on a treadmill: a sentence or so at a time, large and still at
  one spot, moving on at your running pace, with big taps to go back, skip or pause.
  Aa > Themes > Running.
- **Bold word starts.** An option that sets the first half of each word in bold, to
  lead the eye along the line.
- **Safe with your reading.** Your places, highlights and stats live apart from the
  app, so updates never touch them, and noface never writes over one it couldn't read.
- **And everything you'd expect:** definitions (the dictionary downloads itself the
  first time you hold a word), highlights and bookmarks synced with the Kindle apps for
  Amazon books, footnotes over the page, contents and Go To, a Back button after every
  jump, search as you type, four typefaces plus your own, size, spacing, margins,
  justification and hyphenation, a clock, pictures full screen with zoom, reading stats
  with your daily minutes and streak, the book's cover or your own picture on the lock
  screen, and Wi‑Fi, Bluetooth, sync, light and warmth in a panel you pull down from the
  top.

## Install

**You'll need** a **Kindle Paperwhite, 12th generation (2024)**, jailbroken, with
**KMC** and **KPM** installed (the usual jailbreak guides set both up). That's the only
Kindle noface runs on: on any other model it checks the screen, says it can't run, and
hands straight back to the Kindle's own home screen.

1. **Download** the latest `noface-<version>-paperwhite_12.zip` from
   [Releases](https://github.com/Andree37/noface/releases/latest) and unzip it.
2. **Copy** the `noface` folder to the Kindle's drive over USB, and the folder
   `noface/kpm/noface` into `kmc/kpm/packages` on the same drive.
3. **Launch**: eject, and type `;kpm launch noface` into the Kindle's search bar.

Your library appears, and your books open at the page you were on.

**Start with your Kindle:** turn on Aa > More > "Open noface when the Kindle starts".
If noface ever fails to start on three boots in a row, it turns this off itself.

**Update** by copying the new `noface` folder over the old one. Your reading lives in a
separate `noface-data` folder that updates never touch.

## FAQ

**Will I lose my books, highlights or places?**
No. Your books stay where they are, your highlights on Amazon books keep syncing with
the Kindle apps, and noface keeps its own places, notes and stats in `noface-data`,
apart from the app.

**How do I go back to the normal Kindle?**
Pull the panel down from the top and tap **Kindle**: the Kindle's own screens return.
To remove noface, turn off starting with the Kindle, then delete the `noface` folder and
`kmc/kpm/packages/noface`. If you had turned on starting with the Kindle, its one small
startup file stays behind, idle, in `/etc/upstart`: delete `noface-autostart.conf` there
to leave no trace.

**Does it work on my Kindle?**
Only on the Paperwhite 12th generation (2024) today. Other Kindles are added once noface
has passed its full test run on a real one; the release notes list which.

**Can it open books I bought from Amazon?**
Books without DRM, yes. Most bought from Amazon are protected, and noface never removes
or works around DRM: those open in the Kindle's own reader instead.

**Something's not right. What do I do?**
`noface doctor` and `noface selftest` check the Kindle and noface itself; the
[release notes](https://github.com/Andree37/noface/releases/latest) say how to run them
and where to send what they print. A crash is written to `noface.log`, and attaching it
to a report is enough.

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
