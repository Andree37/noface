# Sourced by the other scripts: where noface lives, and where what it keeps lives.
#
# The app sits in /mnt/us/noface, which an update replaces whole. Settings, reading
# positions, stats, notes, the battery log and the dictionaries sit apart, in
# /mnt/us/noface-data, which no update touches. Installs from before the split kept
# both in /mnt/us/noface: what isn't the app is moved across. The first time it goes
# through a temporary folder, renamed when done, so a run cut short finishes next
# time; if noface-data already exists (made by hand for a dictionary, say), anything
# old is moved in unless the same name is already there.
#
# These names match src/kindle/paths.zig; a unit test checks they agree.
APP=/mnt/us/noface
DATA=/mnt/us/noface-data
LOG=$DATA/noface.log
LAUNCH_LOG=$DATA/launch.log
HEARTBEAT=/tmp/noface-alive
WIFI_PAUSED=$DATA/wifi-paused

# Wi-Fi noface turned off for reading, put back. The note goes only once airplane
# mode is really off, so a later try can still act.
restore_wifi() {
    [ -e "$WIFI_PAUSED" ] || return 0
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
    [ "$(lipc-get-prop com.lab126.cmd wirelessEnable 2>/dev/null)" = 1 ] && rm -f "$WIFI_PAUSED"
}

# Whether a file in the app folder is part of the app, or the install log
is_app() {
    case "${1##*/}" in
        noface | noface.new | noface-* | jxr2pgm | selftest | *.sh | noface-autostart.conf | LICENSE.md | \
        THIRD_PARTY_NOTICES.md | VERSION | kpm | launch.log) return 0 ;;
    esac
    return 1
}

if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA.moving"
    for f in "$APP"/* "$APP"/.[!.]*; do
        [ -e "$f" ] || continue
        is_app "$f" || mv "$f" "$DATA.moving/"
    done
    mv "$DATA.moving" "$DATA"
else
    for f in "$APP"/* "$APP"/.[!.]*; do
        [ -e "$f" ] || continue
        is_app "$f" && continue
        [ -e "$DATA/${f##*/}" ] || mv "$f" "$DATA/"
    done
fi
