<h1 align="center">noface</h1>

<p align="center">
  A home screen and reader for Kindle e-readers, written to turn pages fast.
</p>

<p align="center">
  <a href="https://github.com/Andree37/noface/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Andree37/noface?label=release"></a>
  <a href="https://github.com/Andree37/noface/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/Andree37/noface/total"></a>
  <a href="docs/DEVICES.md"><img alt="Supported devices" src="https://img.shields.io/badge/devices-supported%20Kindles-informational"></a>
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

noface replaces the home screen and the reader on a jailbroken Kindle. It
was written because the stock reader takes about a third of a second to show the next
page; noface takes about 60 ms on the same Kindle.

It works with the books already on your Kindle and with EPUBs you copy over USB.
Highlights on Amazon books still sync with the Kindle apps, and Wi‑Fi, sync and the
dictionary keep working. noface doesn't change the Kindle's own software: you can go
back to it from noface's panel at any time.

## Features

- Pages turn in about 60 ms, against about 330 ms in the stock reader on the same
  Kindle.
- The home screen shows your books only. The store, recommendations and ads aren't
  part of it.
- EPUBs copied to the Kindle over USB show up in the library and open in noface, with
  no conversion or Send to Kindle.
- Wi‑Fi is turned off while you read and turned back on when you leave the book.
  The battery shows an estimate of how long the charge will last at the rate you read.
- The book you're reading shows how much time it has left on the home screen, based on
  your reading speed.
- Books in a series are grouped and sorted using their file names, and when you finish
  one, noface offers the next.
- Running mode, for reading on a treadmill, shows the text a little at a time in large type
  and moves on at your pace.
- An optional bold-word-starts mode sets the first half of each word in bold.
- Your places, highlights and stats are kept in a separate folder that updates don't
  touch. A file noface can't read is left as it is rather than written over.
- Also: definitions (the dictionary downloads the first time you look up a word),
  highlights and bookmarks, footnotes, contents and Go To, a Back button after jumps,
  search, the Kindle's typefaces and your own, size, spacing, margins, justification and
  hyphenation, a clock, full-screen pictures with zoom, reading stats, your own picture
  on the lock screen, and a pull-down panel for Wi‑Fi, Bluetooth, sync, light and
  warmth.

## Install

You need a jailbroken Kindle with KMC and KPM installed (most jailbreak guides install
both). Check that yours is in [Supported devices](docs/DEVICES.md) first.

1. Download the zip for your Kindle from the
   [latest release](https://github.com/Andree37/noface/releases/latest) and unzip it.
2. Connect the Kindle over USB. Copy the `noface` folder to its drive, and copy
   `noface/kpm/noface` into `kmc/kpm/packages`.
3. Eject the Kindle and type `;kpm launch noface` in its search bar.

noface can also be set to open when the Kindle starts. If it keeps failing to start,
it turns that off by itself.

To update, copy the new `noface` folder over the old one. Reading data is kept in a
separate `noface-data` folder, which updates don't touch.

## FAQ

**Will I lose my books, highlights or places?**
No. Your books stay where they are, highlights on Amazon books still sync with the
Kindle apps, and noface keeps its places, notes and stats in `noface-data`.

**How do I go back to the normal Kindle?**
noface's panel has a button that switches back to the Kindle's own screens. To remove
noface, turn off opening it when the Kindle starts, then delete the `noface` folder and
`kmc/kpm/packages/noface`. If you had turned that on, noface also added a startup file
in `/etc/upstart` (`noface-autostart.conf`), which you can delete.

**Does it work on my Kindle?**
[Supported devices](docs/DEVICES.md) lists the Kindles noface runs on, and those being
worked on.

**Can it open books I bought from Amazon?**
Only books without DRM. noface doesn't remove or work around DRM, so protected books
(most books bought from Amazon) open in the Kindle's own reader.

**How do I report a problem?**
Run `noface doctor` and `noface selftest`; the
[release notes](https://github.com/Andree37/noface/releases/latest) explain how. Open an
issue with their output and `noface-data/noface.log`, which records crashes.

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
