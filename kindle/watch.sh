#!/bin/sh
# On-device bus capture. Read-only observation: it starts listeners, it never
# sets a property or calls a method.
#
# Purpose: find out what the library UI actually invokes when you tap download
# on a cloud book, so a download can be triggered from a script instead of by
# hand. LIPC is a thin layer over D-Bus, so watching the system bus sees the
# real call -- much better than guessing lipc property names against live
# services on a device with no rollback.
#
# Toggle: first tap starts capture and returns you to the library, second tap
# stops it and writes the report. A watchdog stops it regardless after
# MAX_MINUTES so a forgotten capture cannot sit there eating battery.

SELF=/mnt/us/extensions/kfx-sync/watch.sh
W=/mnt/us/extensions/kfx-sync/watch
REPORT=/mnt/us/kfx-watch-report.txt
MAX_MINUTES=${MAX_MINUTES:-20}
CC=/var/local/cc.db
DCM=/var/local/dcm.db
RAW_CAP=4000000        # bytes of raw log copied out to /mnt/us for inspection

mkdir -p "$W" 2>/dev/null

running() {
    [ -f "$W/pids" ] || return 1
    while read -r p _; do
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    done < "$W/pids"
    return 1
}

snapshot() {   # $1 = tag
    sqlite3 "$CC" "select p_cdeKey||'|'||coalesce(p_isArchived,'')||'|'||coalesce(p_contentState,'')||'|'||substr(replace(coalesce(p_titles_0_nominal,''),'|','/'),1,44) from Entries where p_cdeType='EBOK' order by p_cdeKey;" \
        2>/dev/null | sort > "$W/cc.$1" 
    sqlite3 "$DCM" "select p_cdeKey from DeviceContentEntry where p_cdeType='EBOK' order by p_cdeKey;" \
        2>/dev/null | sort > "$W/dcm.$1"
    ls /mnt/us/documents 2>/dev/null | sort > "$W/docs.$1"
}

# ---------------------------------------------------------------- stop --------
if [ "$1" = stop ] || running; then
    echo "Stopping capture..."
    while read -r p what; do
        [ -n "$p" ] && kill "$p" 2>/dev/null && echo "  stopped $what"
    done < "$W/pids"
    sleep 1
    while read -r p _; do
        [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    done < "$W/pids"
    rm -f "$W/pids"

    snapshot after

    {
        echo "KFX bus capture report"
        echo "started: $(cat "$W/started" 2>/dev/null)"
        echo "stopped: $(date)"
        echo

        echo "=== catalogue rows that CHANGED (cdeKey|isArchived|contentState|title) ==="
        if [ -f "$W/cc.before" ] && [ -f "$W/cc.after" ]; then
            grep -vxF -f "$W/cc.before" "$W/cc.after" 2>/dev/null | sed 's/^/  now: /'
            grep -vxF -f "$W/cc.after" "$W/cc.before" 2>/dev/null | sed 's/^/  was: /'
            [ -s "$W/cc.before" ] || echo "  (before-snapshot empty -- could not read $CC)"
        fi
        echo
        echo "=== files that APPEARED on device (dcm.db) ==="
        grep -vxF -f "$W/dcm.before" "$W/dcm.after" 2>/dev/null | sed 's/^/  + /'
        echo "=== new files in documents/ ==="
        grep -vxF -f "$W/docs.before" "$W/docs.after" 2>/dev/null | sed 's/^/  + /'
        echo

        echo "=== D-Bus capture sizes ==="
        for f in dbus dbus-plain; do
            echo "  $f.log: $(wc -l < "$W/$f.log" 2>/dev/null || echo 0) lines, method calls: $(grep -c '^method call' "$W/$f.log" 2>/dev/null | head -1)"
            [ -s "$W/$f.err" ] && sed 's/^/    err: /' "$W/$f.err" | head -3
        done
        echo
        # Analyse whichever log actually caught method calls.
        [ -s "$W/dbus.log" ] || cp "$W/dbus-plain.log" "$W/dbus.log" 2>/dev/null
        if [ -s "$W/dbus.log" ]; then
            echo "=== D-Bus: method calls seen (deduped, most frequent last) ==="
            # A method_call line looks like:
            #   method call ... dest=com.lab126.foo ... interface=X; member=Y
            grep -h '^method call' "$W/dbus.log" 2>/dev/null \
              | sed -n 's/.*dest=\([^ ]*\).*interface=\([^ ;]*\).*member=\([^ ;]*\).*/\1 \2.\3/p' \
              | sort | uniq -c | sort -n | sed 's/^/  /'
            echo
            echo "=== D-Bus: signals seen ==="
            grep -h '^signal' "$W/dbus.log" 2>/dev/null \
              | sed -n 's/.*interface=\([^ ;]*\).*member=\([^ ;]*\).*/\1.\2/p' \
              | sort | uniq -c | sort -n | sed 's/^/  /'
            echo
            echo "=== D-Bus: method calls WITH ARGUMENTS (the property name lives here) ==="
            awk '/^method call/{p=1} p{print} /^$/{p=0}' "$W/dbus.log" 2>/dev/null \
              | grep -iE -B2 -A12 'download|kpp|archive|deliver' | head -300 | sed 's/^/  /'
            echo
            echo "=== D-Bus: lines mentioning download/archive/content (with context) ==="
            grep -n -i -E 'download|archive|fetch|deliver|contentState|cdeKey|B0[0-9A-Z]{8}' \
                "$W/dbus.log" 2>/dev/null | head -400 | sed 's/^/  /'
            echo
            echo "  raw dbus lines: $(wc -l < "$W/dbus.log")"
        else
            echo "=== D-Bus monitor produced nothing ==="
            echo "  (see $W/dbus.err)"
            sed 's/^/  /' "$W/dbus.err" 2>/dev/null | head -20
        fi
        echo

        if [ -s "$W/lipc.log" ]; then
            echo "=== LIPC events ==="
            sort "$W/lipc.log" | uniq -c | sort -n | tail -200 | sed 's/^/  /'
            echo
        fi

        if [ -s "$W/messages.log" ]; then
            echo "=== /var/log/messages: download-ish lines ==="
            grep -i -E 'download|archive|deliver|todo|dwnld|content' "$W/messages.log" 2>/dev/null \
              | tail -200 | sed 's/^/  /'
            echo "  total new log lines: $(wc -l < "$W/messages.log")"
        fi
    } > "$REPORT" 2>&1

    # Copy raw logs out to /mnt/us so they are readable over USB.
    for f in dbus dbus-plain messages; do
        [ -s "$W/$f.log" ] && head -c "$RAW_CAP" "$W/$f.log" > "/mnt/us/kfx-watch-$f.log"
    done

    echo
    echo "Report: $REPORT"
    echo "  $(wc -l < "$REPORT" 2>/dev/null) lines"
    echo "Raw logs copied to /mnt/us/kfx-watch-*.log"
    echo
    echo "Connect USB and tell Claude it is mounted."
    sleep 8
    exit 0
fi

# --------------------------------------------------------------- start --------
echo "Starting bus capture (read-only)."
if [ -s "$W/dbus.log" ] || [ -s "$W/lipc.log" ] || [ -s "$W/messages.log" ]; then
    A="$W/prev"
    rm -rf "$A" 2>/dev/null; mkdir -p "$A" 2>/dev/null
    for f in "$W"/*.log "$W"/*.err "$W"/cc.* "$W"/dcm.* "$W"/docs.*; do
        [ -f "$f" ] && mv "$f" "$A/" 2>/dev/null
    done
    echo "  (previous capture archived to $A -- not deleted)"
fi
rm -f "$W"/*.log "$W"/*.err "$W"/pids 2>/dev/null
date > "$W/started"
snapshot before
: > "$W/pids"

note() { printf '%s %s\n' "$1" "$2" >> "$W/pids"; }

# 1. dbus-monitor on the system bus -- the whole point of the exercise.
DBM=$(command -v dbus-monitor 2>/dev/null)
if [ -n "$DBM" ]; then
    # A bare "dbus-monitor --system" only ever delivered SIGNALS here, which is
    # useless for this job: a LIPC property set is a METHOD CALL, and that is
    # exactly where the download trigger lives. Modern dbus requires explicit
    # eavesdrop match rules to receive other peers' method calls.
    #
    # Run both variants rather than probing which one works -- an idle bus makes
    # "did it produce output" an unreliable test, and a second monitor is cheap.
    nohup "$DBM" --system \
        "eavesdrop=true,type='method_call'" \
        "eavesdrop=true,type='method_return'" \
        "eavesdrop=true,type='error'" \
        > "$W/dbus.log" 2> "$W/dbus.err" &
    note $! dbus-monitor-eavesdrop
    nohup "$DBM" --system > "$W/dbus-plain.log" 2> "$W/dbus-plain.err" &
    note $! dbus-monitor-plain
    echo "  dbus-monitor: running (eavesdrop + plain)"
else
    echo "  dbus-monitor: NOT INSTALLED"
    echo "dbus-monitor binary not present on this device" > "$W/dbus.err"
fi

# 2. (removed) lipc-wait-event fan-out.
#    It spawned up to 40 `sh -c "lipc-wait-event ... | sed ..."` wrappers and
#    recorded the WRAPPER's pid, so stopping the capture killed the wrapper and
#    orphaned both children -- 44 lipc-wait-event and ~26 sed processes were
#    still alive hours later, holding LIPC connections ("Having high DBUS
#    connections. count : 90"). It also produced an empty log every time, since
#    dbus-monitor already sees the same events. Not worth fixing; dropped.

# 3. New lines in the system log.
for L in /var/log/messages /var/log/system.log; do
    if [ -f "$L" ]; then
        nohup tail -f -n 0 "$L" > "$W/messages.log" 2>/dev/null &
        note $! "tail:$L"
        echo "  tailing $L"
        break
    fi
done

# 4. Watchdog: stop everything after MAX_MINUTES no matter what, so a capture
#    left running cannot quietly drain the battery.
nohup sh -c "sleep $((MAX_MINUTES * 60)); sh '$SELF' stop" >/dev/null 2>&1 &
echo "$! watchdog" >> "$W/pids"

echo
echo "CAPTURING. Now:"
echo "  1. Go to your library / cloud view"
echo "  2. Tap download on ONE shared book"
echo "  3. Wait for it to finish downloading"
echo "  4. Come back here and tap 'KFX Watch' again to stop"
echo
echo "Auto-stops after ${MAX_MINUTES} min."
sleep 8
exit 0
