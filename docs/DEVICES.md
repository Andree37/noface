# Supported devices

noface runs on jailbroken Kindles with KMC and KPM installed. Each supported Kindle has
its own zip in every release, named after it (`noface-<version>-<model>.zip`); download
the one for yours.

## Supported

A Kindle is listed here once noface's full test run has passed on a real one.

| Kindle | Zip | Tested on a real one |
|---|---|---|
| Kindle Paperwhite (12th generation, 2024) | `noface-<version>-paperwhite_12.zip` | Yes |

On a Kindle not listed here, noface checks the screen, says it can't run, and returns
to the Kindle's home screen.

## Being worked on

noface draws through MediaTek's `hwtcon` display driver, which Kindles have used since
about 2021, so those are next.

| Kindle | Status |
|---|---|
| Kindle Paperwhite (11th generation) and Signature Edition, 2021 | Its display driver to check, then a test run on one |
| Kindle (2022, 2024) | No warm light: its warmth controls are to be hidden |
| Kindle Colorsoft (2024) | Its colour layer is drawn in grays |
| Kindle Scribe | Its display driver to check first |

## Not planned

Kindles from before about 2021 (Paperwhite 4, Oasis 2 and 3, Kindle 10th generation and
older) use NXP's `mxcfb` display driver, which would need a second way of drawing.
