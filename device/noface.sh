#!/bin/sh
# Pauses the stock UI, runs noface, and always puts the stock UI back.
. /mnt/us/noface/data.sh
DIR=$DATA
FONTS=/usr/java/lib/fonts
restore() {
    killall -CONT awesome 2>/dev/null
    lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
    lipc-set-prop com.lab126.blanket load screensaver 2>/dev/null
    # Only noface's own power watcher, in case noface died before ending it. Stock
    # has listeners of its own that must keep running. lipc-wait-event splits its
    # event list in place, so the comma shows up as a separate word here.
    for p in $(pidof lipc-wait-event); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -E -- "-m com.lab126.powerd goingToScreenSaver outOfScreenSaver|-m com.lab126.volumd usbConfigured" && kill "$p"
    done
    [ -n "$watchdog" ] && kill "$watchdog" 2>/dev/null
    restore_wifi # In case noface couldn't turn it back on itself
}
trap restore EXIT

# noface draws its own lock screen, so the stock one has to stay out of the way.
lipc-set-prop com.lab126.powerd preventScreenSaver 0
lipc-set-prop com.lab126.blanket unload screensaver 2>/dev/null
lipc-set-prop com.lab126.pillow disableEnablePillow disable
killall -STOP awesome

# Keep the log small: start over once it passes 512 KB, keeping one old copy.
if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv "$LOG" "$DIR/noface.log.old"
fi

# Background plus wait, so a signal reaches noface instead of waiting on it.
"$APP/noface" "$DIR/library.tsv" "$FONTS/Bookerly-Regular.ttf" "$FONTS/Bookerly-Bold.ttf" "$FONTS/Amazon-Ember-Regular.ttf" "$FONTS/Amazon-Ember-Bold.ttf" "$DIR" >> "$LOG" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null' INT TERM HUP

# Watchdog. noface refreshes a heartbeat in RAM every 30 seconds while its loop runs.
# If that stops for 2 minutes while the Kindle is awake, noface is stuck: end it,
# and the stock UI comes back. A locked Kindle lets noface sleep, so it's left alone.
# After a minute of running well, the boot crash guard in autostart.sh is reset too.
(
    sleep 60
    kill -0 "$pid" 2>/dev/null && rm -f "$DIR/boot-attempts"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 30
        [ "$(lipc-get-prop -s com.lab126.powerd state 2>/dev/null)" = active ] || continue
        beat=$(cat "$HEARTBEAT" 2>/dev/null || echo 0)
        if [ $(( $(date +%s) - beat )) -gt 120 ]; then
            echo "watchdog: no heartbeat for 2 minutes, stopping noface" >> "$LOG"
            kill -9 "$pid" 2>/dev/null
        fi
    done
) &
watchdog=$!
# A signal ends the first wait early, while noface is still shutting down.
wait "$pid"
code=$?
if kill -0 "$pid" 2>/dev/null; then
    wait "$pid"
    code=$?
fi
echo "exit code $code" >> "$LOG"
# Leaving on purpose is a good start too, even within the first minute.
[ "$code" -eq 0 ] && rm -f "$DIR/boot-attempts"
