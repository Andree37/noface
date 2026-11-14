#!/bin/sh
# Started by ";kpm launch noface". Library tap launching is broken,
# so this is the working way in. Detached so KPM can return straight away.
. /mnt/us/noface/data.sh
setsid sh "$APP/start.sh" >> "$LAUNCH_LOG" 2>&1 < /dev/null &
