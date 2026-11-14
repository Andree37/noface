#!/bin/sh
# Starts noface when the Kindle boots. Run by /etc/upstart/noface-autostart.conf once
# the user drive is mounted; noface installs that file when "Open noface when the
# Kindle starts" is switched on. Older installs ran this as /mnt/us/emergency.sh.
#
# It never holds up boot: it returns at once and starts noface in the background.
# Safety:
#   - Off unless the settings say "autostart on" (Aa > More in noface).
#   - Crash guard: three boots in a row where noface didn't run for a minute turn
#     autostart off by themselves (noface.sh clears the count after a good minute).
. /mnt/us/noface/data.sh
DIR=$DATA
# Once per boot: the drive comes back after every USB unplug, and an older install's
# emergency.sh may call this too. /tmp is in RAM, so the mark is gone on the next boot.
[ -e /tmp/noface-autostart-ran ] && exit 0
touch /tmp/noface-autostart-ran
# Airplane mode noface turned on for reading, left on by a hard restart mid-book:
# undo it now, at boot, before the reader can make airplane mode their own choice.
# In the background, as the connection manager may not be up yet.
if [ -e "$WIFI_PAUSED" ]; then
    nohup sh -c ". $APP/data.sh; sleep 30; restore_wifi" > /dev/null 2>&1 &
fi
grep -q '^autostart on' "$DIR/settings" 2>/dev/null || exit 0
count=$(cat "$DIR/boot-attempts" 2>/dev/null || echo 0)
if [ "$count" -ge 3 ]; then
    sed -i 's/^autostart on/autostart off/' "$DIR/settings"
    rm -f "$DIR/boot-attempts"
    echo "autostart: noface failed to start 3 boots in a row, autostart turned off" >> "$LOG"
    exit 0
fi
echo $((count + 1)) > "$DIR/boot-attempts"
# Give the Kindle's home a moment to finish drawing, then open noface over it. Straight
# to start.sh rather than through KPM: KPM's waits are for the search keyboard,
# which isn't there at boot.
nohup sh -c "sleep 20; setsid sh $APP/start.sh now >> $LAUNCH_LOG 2>&1 < /dev/null" > /dev/null 2>&1 &
exit 0
