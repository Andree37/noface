# Supported devices

Each supported device has its own zip in every release, named after it
(`noface-<version>-<model>.zip`); download the one for yours. A device is listed as
supported once noface's full test run has passed on a real one.

| Device | Zip | Tested on a real one |
|---|---|---|
| Kindle Paperwhite (12th generation, 2024) | `noface-<version>-paperwhite_12.zip` | Yes |

On a device that isn't listed, noface checks the screen, says it can't run, and returns
to the device's own home screen.

## Being worked on

| Device | Status |
|---|---|
| Kindle Paperwhite (11th generation) and Signature Edition, 2021 | Its display driver to check, then a test run on one |
| Kindle (2022, 2024) | No warm light: its warmth controls are to be hidden |
| Kindle Colorsoft (2024) | Its colour layer is drawn in grays |
| Kindle Scribe | Its display driver to check first |

Kindles from before about 2021 (Paperwhite 4, Oasis 2 and 3, Kindle 10th generation and
older) use a different display driver, NXP's `mxcfb`, and aren't planned for now.

## Kindle

**What it needs:** the Kindle jailbroken, with KMC and KPM installed (most jailbreak
guides install both).

**Install:**

1. Unzip the zip for your Kindle.
2. Connect the Kindle over USB. Copy the `noface` folder to its drive, and copy
   `noface/kpm/noface` into `kmc/kpm/packages`.
3. Eject the Kindle and type `;kpm launch noface` in its search bar.

To update, copy the new `noface` folder over the old one.

**Remove:** turn off opening noface when the Kindle starts, then delete the `noface`
folder and `kmc/kpm/packages/noface`. If you had turned that on, noface also added a
startup file in `/etc/upstart` (`noface-autostart.conf`), which you can delete.

**Checks:** over SSH, `/mnt/us/noface/noface doctor` and `/mnt/us/noface/noface
selftest`.

Highlights and bookmarks on books from Amazon sync with the Kindle apps as before.
Books protected by DRM, as most bought from Amazon are, open in the Kindle's own
reader.

"Kindle" is a trademark of Amazon.com, Inc. or its affiliates, used here only to say
which devices noface runs on.
