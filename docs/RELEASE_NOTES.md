## Install

Find your device in the table above and download its zip. **Each zip runs on its own
device only:** noface draws on the screen directly and is laid out for one screen, so
on any other model it checks the screen, says it can't run, and goes back to the
device's own home screen. What each device needs, and its install steps, are in
[Supported devices](https://github.com/Andree37/noface/blob/main/docs/DEVICES.md),
with the devices being worked on.

noface can also be set to open when the device starts.

**Dictionaries:** the first time you hold a word, noface offers to download the
dictionary for the book's language over Wi‑Fi. Choose "Not now" and it stops asking;
the definition sheet keeps a "Get dictionary" button for later. Without Wi‑Fi, download
`dict-en.zip` or `dict-pt.zip` from the [Dictionaries release](../../releases/tag/dictionaries),
unzip, and copy the `dict-en` or `dict-pt` file into the **noface-data** folder on the
device.

**Checking the download:** `SHA256SUMS` beside it holds every zip's checksum, and GitHub
signed where it was built: `gh attestation verify noface-*.zip -R Andree37/noface`
says whether it came from this repository's release workflow, unchanged.

## Updating

Install the new zip the same way; replacing the old **noface** folder is fine.
Everything noface keeps (settings, reading positions, stats, dictionaries) lives in
**noface-data**, which updates never touch.

## If something's wrong

`noface doctor` reports what noface finds on the device and whether it can run there,
and `noface selftest` runs noface's own checks in memory, without touching the screen,
your library or the device's settings. It names your books only by kind and number,
never by title. [Supported devices](https://github.com/Andree37/noface/blob/main/docs/DEVICES.md)
says how to run them on each device. Paste both into a
[device report](../../issues/new?template=device-report.md).
