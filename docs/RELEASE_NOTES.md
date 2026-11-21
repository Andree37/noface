## Install

You need a jailbroken Kindle from the table above, with KMC and KPM. **Each zip runs
on its own Kindle only:** noface drives the display directly and is laid out for one
screen, so on any other model it checks the screen, says it can't run, and goes back
to the Kindle's own home screen.

1. Download the zip for your Kindle below and unzip it.
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

**Checking the download:** `SHA256SUMS` beside it holds every zip's checksum, and GitHub
signed where it was built: `gh attestation verify noface-*.zip -R Andree37/noface`
says whether it came from this repository's release workflow, unchanged.

## Updating

Copy the new **noface** folder over the old one; replacing it is fine. Everything noface
keeps (settings, reading positions, stats, dictionaries) lives in **noface-data**,
which updates never touch.

## If something's wrong

Over SSH, `/mnt/us/noface/noface doctor` reports what noface finds on the Kindle and
whether it can run there, and `/mnt/us/noface/noface selftest` runs noface's own
checks in memory, without touching the screen, your library or the Kindle's
settings. It names your books only by kind and number, never by title. Paste both
into a [device report](../../issues/new?template=device-report.md).
