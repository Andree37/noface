## Install

You need a jailbroken Kindle Paperwhite (12th gen) with KMC and KPM.

1. Download **noface-*.zip** below and unzip it.
2. Plug in the Kindle. Copy the **noface** folder to the Kindle's drive, then copy the
   folder **noface/kpm/noface** into **kmc/kpm/packages** on the Kindle.
3. Eject the Kindle and type `;kpm launch noface` in its search bar.

To open noface whenever the Kindle starts, turn on Aa > More > "Open noface when the
Kindle starts".

**Dictionaries:** the first time you hold a word, noface offers to download the
dictionary for the book's language over Wi‑Fi (English is 27 MB, Portuguese 6 MB).
Choose "Not now" and it stops asking; the definition sheet keeps a "Get dictionary"
button for later. Without Wi‑Fi, download `dict-en.zip` or `dict-pt.zip` from the
[Dictionaries release](../../releases/tag/dictionaries), unzip, and copy the `dict-en`
or `dict-pt` file into the **noface-data** folder on the Kindle.

## Updating

Copy the new **noface** folder over the old one; replacing it is fine. Everything noface
keeps (settings, reading positions, stats, dictionaries) lives in **noface-data**,
which updates never touch.

If you built noface yourself before this release, it kept those in the **noface**
folder itself: copy the new folder in by merging rather than replacing (on a Mac, hold
Option while dragging and choose Merge), and noface moves them into **noface-data**
the first time it starts.

## If something's wrong

Over SSH, `/mnt/us/noface/noface doctor` reports what noface finds on the Kindle and
whether it can run there, and `/mnt/us/noface/noface selftest` runs noface's own
checks in memory, without touching the screen, your library or the Kindle's
settings. Paste both into a
[device report](../../issues/new?template=device-report.md).
