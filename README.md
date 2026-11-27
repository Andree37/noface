<h1 align="center">noface</h1>

<p align="center">
  A home screen and reader for e-readers, written to turn pages fast.
</p>

<p align="center">
  <a href="https://github.com/Andree37/noface/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Andree37/noface?label=release"></a>
  <a href="https://github.com/Andree37/noface/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/Andree37/noface/total"></a>
  <a href="docs/DEVICES.md"><img alt="Supported devices" src="https://img.shields.io/badge/devices-supported%20list-informational"></a>
  <a href="LICENSE.md"><img alt="License: PolyForm Noncommercial" src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue"></a>
</p>

<p align="center">
  <a href="https://github.com/Andree37/noface/releases/latest"><b>Download</b></a> ·
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="docs/DEVICES.md">Devices</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="docs/DEVELOPING.md">Developing</a>
</p>

<p align="center"><a href="docs/speed.mp4"><img src="docs/speed.gif" width="720" alt="The stock reader and noface side by side doing the same things in the same book: four page turns, opening the toolbar, opening the contents, going to a chapter and two more page turns. Under each, the time each step took."></a></p>

<p align="center"><b>Same book, same steps, on the same e-reader.</b><br>
Page turn: about 90 ms with noface, about 300 ms with the stock reader.<br>
Going to a chapter: 84 ms with noface, 1.2 s with the stock reader.<br>
<sub>Measured on the device, from finger down until the new screen is complete. <a href="docs/DEVELOPING.md#how-the-speed-comparison-was-measured">How</a> · <a href="docs/speed.mp4">Video</a></sub></p>

## About

noface replaces the home screen and the reader on an e-reader. It was written because
the device's own reader takes about a third of a second to show the next page; noface
takes under a tenth of a second on the same device.

noface is opinionated. It is a place to read: your books, the page, and the few
controls reading needs. There is no store, no recommendations and nothing to scroll
past, and where the device's own software does something better, noface leaves it to
it rather than copying it.

It works with the books already on your device and with EPUBs you copy over USB, and
it keeps the parts of the device you'd miss working (see
[What keeps working](#what-keeps-working)). noface doesn't change the device's own
software: you can go back to it from noface's panel at any time.

## Features

- Pages turn in about 90 ms, against about 300 ms in the device's own reader. The
  toolbar and contents open in about 110 ms, against about 580 ms.
- The home screen shows your books only. The store, recommendations and ads aren't
  part of it.
- EPUBs copied over USB show up in the library and open in noface, with no conversion.
- Wi‑Fi is turned off while you read and turned back on when you leave the book.
  The battery shows an estimate of how long the charge will last at the rate you read.
- The book you're reading shows how much time it has left on the home screen, based on
  your reading speed.
- Books in a series are grouped and sorted using their file names, and when you finish
  one, noface offers the next.
- Running mode, for reading on a treadmill, shows the text a little at a time in large
  type and moves on at your pace.
- An optional bold-word-starts mode sets the first half of each word in bold.
- Your places, highlights and stats are kept in a separate folder that updates don't
  touch. A file noface can't read is left as it is rather than written over.
- Also: definitions (the dictionary downloads the first time you look up a word),
  highlights and bookmarks, footnotes, contents and Go To, a Back button after jumps,
  search, the device's typefaces and your own, size, spacing, margins, justification
  and hyphenation, a clock, full-screen pictures with zoom, reading stats, your own
  picture on the lock screen, and a pull-down panel for Wi‑Fi, Bluetooth, sync, light
  and warmth.

## What keeps working

noface sits on top of the device's own software instead of replacing all of it, so
what the device does well carries on. Each device keeps its own list; more join it as
more devices are supported.

### Kindle

| | With noface |
|---|---|
| Books from Amazon and Send to Kindle | In noface's library with the rest, and they open in noface when they have no DRM. |
| Books with DRM | Open in the Kindle's own reader, as before. noface never works around DRM. |
| Highlights and bookmarks | On books from Amazon they sync with the Kindle apps both ways. On EPUBs copied over USB they stay with noface, as Amazon doesn't know those books. |
| Where you stopped | On books from Amazon, the Kindle apps and your other devices go on from where you left off in noface. Read on your phone since, and noface asks whether to go to that place when you open the book, as the Kindle does. It can be turned off. |
| Wi‑Fi, Bluetooth, sync, light, warmth | In noface's pull-down panel. Wi‑Fi is off while a book is open, to save battery, and comes back when you leave the book, so syncing happens between books. |
| Typefaces | The Kindle's own, and any you add. |
| Dictionary | noface's own, built from Wiktionary, downloaded the first time you look up a word. The Kindle's dictionaries aren't used. |
| The store | Not part of noface. Buy in the Kindle's own screens or on Amazon, and the book shows up in noface's library. |
| The Kindle's own screens | A button in noface's panel takes you back to them, whenever you want. |

## Install

1. Find your device in [Supported devices](docs/DEVICES.md), which says what it needs
   first.
2. Download the zip for your device from the
   [latest release](https://github.com/Andree37/noface/releases/latest).
3. Follow your device's install steps in [Supported devices](docs/DEVICES.md).

noface can also be set to open when the device starts. If it keeps failing to start,
it turns that off by itself.

To update, install the new zip the same way. Your reading data is kept in a separate
`noface-data` folder, which updates don't touch.

## FAQ

**Will I lose my books, highlights or places?**
No. Your books stay where they are, highlights on books from the device's store still
sync, and noface keeps its places, notes and stats in `noface-data`.

**How do I go back to the device's own software?**
noface's panel has a button that switches back to the device's own screens. Removing
noface is described for each device in [Supported devices](docs/DEVICES.md).

**Does it work on my device?**
[Supported devices](docs/DEVICES.md) lists the devices noface runs on, and those being
worked on.

**Can it open books I bought?**
Only books without DRM. noface doesn't remove or work around DRM, so protected books
open in the device's own reader.

**How do I report a problem?**
Run `noface doctor` and `noface selftest`; the
[release notes](https://github.com/Andree37/noface/releases/latest) explain how. Open an
issue with their output and `noface-data/noface.log`, which records crashes.

## Good to know

- noface never removes or works around DRM. Protected books open in the device's own
  reader instead.
- Some devices need to be jailbroken first. That is your own choice, under your own
  agreement with the device's maker: it may go against their terms and void your
  warranty. noface doesn't jailbreak anything.
- noface comes as is, with no warranty. It is an independent project, not made,
  endorsed or supported by any device maker. Device names are trademarks of their
  owners, used here only to say which devices noface runs on.

## License

Free for personal, noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md): use it, change it and share it,
but don't sell it or build it into a commercial product. Contributions are welcome and
come under the same terms.

noface builds on [stb](https://github.com/nothings/stb) (its font and picture readers
are Zig ports of stb_truetype and stb_image), the TeX hyphenation patterns
and [Wiktionary](https://www.wiktionary.org) definitions (CC BY-SA 4.0), each under its
own license: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
