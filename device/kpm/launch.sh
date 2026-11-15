#!/bin/sh
# KPM (";kpm launch noface") runs this file, and only a shell file: the one script noface
# keeps. noface-launch does the rest (src/launch.zig). Older installs also find this file
# as noface/start.sh, noface/data.sh and noface/autostart.sh (tools/package.zig), so "$0"
# says which way it was started.
exec /mnt/us/noface/noface-launch "$0"
