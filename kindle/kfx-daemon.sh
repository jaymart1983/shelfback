#!/bin/sh
# kfx-daemon -- the sync loop, detached from the UI, able to recover the device.
#
# WHY THIS EXISTS
# Sharing books wedges the Kindle's transfer queue: downloads receive their
# sidecar and no book bytes, cover art stops arriving, and the only thing that
# clears it is a UI framework restart. That restart kills kterm, so a sync
# script running there cannot both trigger the fix and survive it.
#
# Measured 10 Sep 2026 (KFX Probe25): a `setsid` process DOES survive
# `initctl restart lab126_gui` -- same pid throughout, reparented to init when
# kterm died. So the loop runs here, detached, and can restart the framework
# under itself.
#
# The sync logic is not duplicated: menu.sh is sourced with KFX_LIB=1, which
# gives its functions without the front end.
#
#   kfx-daemon.sh start | stop | status | ensure | loop
#
# `ensure` is the cron entry point: start it if it is not running. That covers
# both boot and the daemon dying, without a second supervisor.

BASE=${BASE:-/mnt/us/extensions/kfx-sync}
PIDFILE=${PIDFILE:-/var/local/kfx-daemon.pid}
DLOG=${DLOG:-/mnt/us/kfx-daemon.log}

# A short tick so a newly shared book is noticed quickly, the panel stays
# current, and a remote request from the receiver is picked up within seconds.
# The expensive steps do not run every tick -- see the divisors below.
TICK=${TICK:-30}
EVERY_CLOUD=${EVERY_CLOUD:-2}          # poke Amazon's cloud   ~60s
EVERY_RESEND=${EVERY_RESEND:-4}        # ask what to resend    ~2m
EVERY_SWEEP=${EVERY_SWEEP:-4}          # walk local files      ~2m
EVERY_PURGE=${EVERY_PURGE:-10}         # delete synced books   ~5m  (~14s each)
EVERY_LIBRARY=${EVERY_LIBRARY:-20}     # report the catalogue  ~10m
EVERY_STATS=${EVERY_STATS:-10}         # refresh the panel counts ~5m, even idle
PASS_EVERY=$TICK                       # what the menu shows

# The daemon is always up; whether it syncs on a timer is a separate flag the
# menu sets. That split exists because a stuck-download fix restarts the UI
# framework, which kills the menu -- so even a one-off Sync has to run here to
# survive its own recovery.
# Its own name, not REQFILE: this script sources menu.sh, which used REQFILE for
# the (since removed) network listener's scratch file. Sharing the name meant sourcing menu.sh
# silently re-pointed the daemon at the listener's file, so "Sync now" requests
# written to the real path were never seen.
DAEMON_REQ=${DAEMON_REQ:-/var/local/kfx-daemon.req}
monitor_on() { [ "$(cat /var/local/kfx-state/MONITOR 2>/dev/null)" = "on" ]; }

# Sleep in slices so a Sync requested from the menu starts within a couple of
# seconds instead of waiting out the tick.
nap() {
    _np=0
    while [ "$_np" -lt "$1" ]; do
        [ -f "$DAEMON_REQ" ] && return 0
        sleep 3
        _np=$((_np + 3))
    done
    return 0
}
# Every newly shared book jams the transfer queue -- a tap on the Kindle sits
# "Queued" just the same -- and only a UI framework restart clears it. So one
# stuck book is enough to act on, and the cooldown is short enough that the
# next share is not left waiting an hour (11 Sep 2026: was 2 books / 1 hour /
# 4 a day, which a single shared book could never trigger). This Kindle only
# runs the sync, so a restart costs nothing but a blank screen for a minute.
WEDGE_WINDOW=${WEDGE_WINDOW:-1800}     # how far back to count wedge evidence
WEDGE_TRIGGER=${WEDGE_TRIGGER:-1}      # books stuck with no data before acting
RECOVER_COOLDOWN=${RECOVER_COOLDOWN:-120}   # long enough for the UI to return (RECOVER_SETTLE) and a pass to run
RECOVER_MAX_DAY=${RECOVER_MAX_DAY:-12}
# Two restarts is the limit for any one book: if the queue is still not
# delivering it after that, the restart is not the answer and hammering the UI
# helps nobody. The book is left stuck (it shows as Stuck in the books list)
# and its count clears as soon as it downloads.
RECOVER_MAX_PER_BOOK=${RECOVER_MAX_PER_BOOK:-2}
RECOVER_SETTLE=${RECOVER_SETTLE:-90}   # let the framework come back up

RECOVERLOG=${RECOVERLOG:-/mnt/us/kfx-recoveries.log}

# A document on the home screen is the only "is it running?" indicator the
# Kindle UI can give us, so the daemon publishes its log as one. It appears
# when the daemon starts and is deleted when it stops -- its presence on the
# shelf IS the status light.
BOOK=${BOOK:-/mnt/us/documents/KFX Monitor.txt}
BOOK_LINES=${BOOK_LINES:-120}

write_book() {
    {
        if monitor_on; then echo "KFX Monitor -- running"
        else echo "KFX Monitor -- idle (monitor off, daemon up)"; fi
        echo "updated $(date '+%a %d %b %H:%M:%S')"
        echo "syncs so far: $(state_get SYNC_COUNT)   last: $(ago "$(state_get LAST_SYNC)")"
        echo "next sync: $(countdown "$(state_get NEXT_SYNC)")"
        echo "framework recoveries in last 24h: $(recoveries_today)"
        echo
        echo "----- recent activity -----"
        tail -"$BOOK_LINES" "$LOG" 2>/dev/null
    } > "$BOOK" 2>/dev/null
}
remove_book() { rm -f "$BOOK" 2>/dev/null; }

dlog() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$DLOG"; }

# Every daemon loop actually running, not just the one the pidfile names.
#
# The pidfile is a single slot: start a second daemon and it overwrites the
# first, which then keeps running with no way to reach it. That is how two
# daemons -- one holding pre-rewrite code -- ended up syncing at the same time.
all_daemon_pids() {
    for _ad in /proc/[0-9]*; do
        _adp=${_ad#/proc/}
        [ "$_adp" = "$$" ] && continue
        grep -qa 'kfx-daemon' "$_ad/cmdline" 2>/dev/null || continue
        grep -qa 'loop'       "$_ad/cmdline" 2>/dev/null || continue
        echo "$_adp"
    done
}

running_pid() {
    [ -f "$PIDFILE" ] || return 1
    _rp=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_rp" ] || return 1
    [ -d "/proc/$_rp" ] || return 1
    # A reused pid after a reboot must not read as "already running".
    grep -qa kfx-daemon "/proc/$_rp/cmdline" 2>/dev/null || return 1
    echo "$_rp"
    return 0
}

# --- recovery --------------------------------------------------------------

recoveries_today() {
    [ -f "$RECOVERLOG" ] || { echo 0; return; }
    _rt_now=$(date +%s); _rt_c=0
    while read -r _rt_t _rt_rest; do
        case "$_rt_t" in ''|*[!0-9]*) continue ;; esac
        [ $((_rt_now - _rt_t)) -lt 86400 ] && _rt_c=$((_rt_c + 1))
    done < "$RECOVERLOG"
    echo "$_rt_c"
}

may_recover() {
    _mr_now=$(date +%s)
    _mr_last=$(tail -1 "$RECOVERLOG" 2>/dev/null | cut -d' ' -f1)
    case "$_mr_last" in ''|*[!0-9]*) _mr_last=0 ;; esac
    if [ $((_mr_now - _mr_last)) -lt "$RECOVER_COOLDOWN" ]; then
        dlog "wedge seen but last recovery was $((_mr_now - _mr_last))s ago -- holding"
        return 1
    fi
    if [ "$(recoveries_today)" -ge "$RECOVER_MAX_DAY" ]; then
        dlog "wedge seen but already recovered $(recoveries_today) times today -- holding"
        emit "RECOVERY HELD: $(recoveries_today) already today"
        flush_log
        return 1
    fi
    return 0
}

restart_framework() {
    if initctl status lab126_gui >/dev/null 2>&1; then
        initctl restart lab126_gui
    elif [ -x /etc/init.d/framework ]; then
        /etc/init.d/framework restart
    else
        pkill -TERM cvm
    fi
}

recover_device() {
    may_recover || return 1
    printf '%s framework-restart\n' "$(date +%s)" >> "$RECOVERLOG"
    # Say it before doing it: the restart tears down the UI, and if anything
    # goes wrong this line is the only record of why.
    emit "RECOVERY: restarting UI framework to clear the transfer queue"
    flush_log
    dlog "RECOVERY: restarting lab126_gui"
    : > "$WEDGEFILE"
    rm -f "$INFLIGHT" 2>/dev/null      # those requests died with the queue
    # And the books that got stuck in it deserve a fresh try on the next pass,
    # not the half-hour-and-doubling wait a genuinely bad book gets.
    : > "$STUCKLIST" 2>/dev/null
    : > "$NOTREADY" 2>/dev/null
    restart_framework
    sleep "$RECOVER_SETTLE"
    dlog "RECOVERY: framework back, resuming"
    emit "RECOVERY: framework restarted, resuming"
    flush_log
    return 0
}

# 1 when this tick is a multiple of $2, else 0. The first tick does everything
# so a freshly started monitor is immediately up to date rather than waiting
# five minutes for its first purge.
every() {
    [ "$1" -le 1 ] && { echo 1; return; }
    [ $(( $1 % $2 )) -eq 0 ] && echo 1 || echo 0
}

# The books behind recent jam signs (older signs carry no book: "?" then).
wedge_books() {
    [ -f "$WEDGEFILE" ] || return 0
    _wb_now=$(date +%s)
    while read -r _wb_t _wb_a; do
        case "$_wb_t" in ''|*[!0-9]*) continue ;; esac
        [ -n "$_wb_a" ] || _wb_a="?"
        [ $((_wb_now - _wb_t)) -lt "$WEDGE_WINDOW" ] && printf '%s\n' "$_wb_a"
    done < "$WEDGEFILE" | sort -u
}

# Restart the UI for a jam, unless every book behind it has already had its two.
maybe_recover_wedge() {
    _mw_n=$(wedge_signs)
    [ "${_mw_n:-0}" -ge "$WEDGE_TRIGGER" ] || return 1
    _mw_go=""; _mw_held=""
    for _mw_b in $(wedge_books); do
        if [ "$_mw_b" != "?" ] && [ "$(recover_count "$_mw_b")" -ge "$RECOVER_MAX_PER_BOOK" ]; then
            _mw_held="$_mw_held $_mw_b"
        else
            _mw_go="$_mw_go $_mw_b"
        fi
    done
    if [ -z "$_mw_go" ]; then
        dlog "wedge: already restarted ${RECOVER_MAX_PER_BOOK}x for$_mw_held -- leaving it stuck"
        emit "STUCK BOOK: the UI restart did not help it, leaving it"
        flush_log
        : > "$WEDGEFILE"        # do not re-decide this every tick
        return 1
    fi
    dlog "wedge: $_mw_n sign(s); restarting for$_mw_go"
    emit "WEDGE DETECTED: restarting the UI to clear the queue"
    flush_log
    recover_device || return 1
    for _mw_b in $_mw_go; do
        [ "$_mw_b" = "?" ] || note_recover "$_mw_b"
    done
    return 0
}

wedge_signs() {
    [ -f "$WEDGEFILE" ] || { echo 0; return; }
    _ws_now=$(date +%s); _ws_c=0
    # "<epoch> <asin>" now; older files have the epoch alone, so read two
    # fields and ignore the second. Reading one put the whole line in _ws_t,
    # which then failed the digits test and counted every sign as none.
    while read -r _ws_t _ws_a; do
        case "$_ws_t" in ''|*[!0-9]*) continue ;; esac
        [ $((_ws_now - _ws_t)) -lt "$WEDGE_WINDOW" ] && _ws_c=$((_ws_c + 1))
    done < "$WEDGEFILE"
    echo "$_ws_c"
}

# --- the loop --------------------------------------------------------------

loop() {
    KFX_LIB=1
    export KFX_LIB
    . "$BASE/menu.sh" || { dlog "FATAL: cannot source $BASE/menu.sh"; exit 1; }
    PASS_INLINE=1
    trap 'dlog "stopping on signal"; drop_lock; remove_book; rm -f "$PIDFILE"; exit 0' INT TERM HUP

    dlog "daemon started (pid $$)"
    refresh_counts
    emit "daemon started, build ${KFX_BUILD:-?}"
    # The menu compares this with its own build at startup and restarts a
    # daemon still running older code.
    state_set DAEMON_BUILD "${KFX_BUILD:-?}"
    flush_log

    write_book
    tick=0
    while :; do
        tick=$((tick + 1))
        want_full=0

        # An explicit request from the menu always runs a FULL sync.
        if [ -f "$DAEMON_REQ" ]; then
            rm -f "$DAEMON_REQ"
            dlog "sync requested from the menu"
            want_full=1
        fi

        # Remote control, checked every tick so the receiver gets a response in
        # seconds rather than minutes.
        case "$(poll_cmd 2>/dev/null)" in
            stop) dlog "remote stop"; emit "monitor stopped remotely"; flush_log
                  drop_lock; remove_book; rm -f "$PIDFILE"; exit 0 ;;
            run)  dlog "remote run: full sync"; want_full=1 ;;
        esac

        # Idle unless the monitor is on or something asked for a sync. Still
        # keep the panel's counts current -- they are what the front end shows,
        # and with the monitor off nothing else would ever update them.
        if [ "$want_full" != 1 ] && ! monitor_on; then
            [ "$(every "$tick" "$EVERY_STATS")" = 1 ] && refresh_counts
            state_set NEXT_SYNC ""
            write_book
            nap "$TICK"
            continue
        fi

        if [ "$want_full" = 1 ]; then
            tick=0
            DO_CLOUD=1; DO_RESEND=1; DO_PURGE=1; DO_SWEEP=1
        fi

        if take_lock daemon; then
            [ "${DO_CLOUD:-}"  = 1 ] || DO_CLOUD=$(every "$tick" "$EVERY_CLOUD")
            [ "${DO_RESEND:-}" = 1 ] || DO_RESEND=$(every "$tick" "$EVERY_RESEND")
            [ "${DO_PURGE:-}"  = 1 ] || DO_PURGE=$(every "$tick" "$EVERY_PURGE")
            [ "${DO_SWEEP:-}"  = 1 ] || DO_SWEEP=$(every "$tick" "$EVERY_SWEEP")
            [ "$(every "$tick" "$EVERY_LIBRARY")" = 1 ] && report_library
            export DO_CLOUD DO_RESEND DO_PURGE DO_SWEEP
            sync_once
            DO_CLOUD=; DO_RESEND=; DO_PURGE=; DO_SWEEP=
            drop_lock
            maybe_recover_wedge
        remote_expire        # stop dev FTP when its time is up, menu open or not
        else
            # The menu is driving. Stay out of its way rather than racing it.
            dlog "skipped: $(lock_holder) holds the run lock"
        fi
        if monitor_on; then
            state_set NEXT_SYNC "$(( $(date +%s) + TICK ))"
        else
            state_set NEXT_SYNC ""
        fi
        write_book
        nap "$TICK"
    done
}

# --- control ---------------------------------------------------------------

case "${1:-status}" in
    start)
        _live=$(all_daemon_pids | tr '\n' ' ')
        if [ -n "$_live" ]; then echo "already running (pid $_live)"; exit 0; fi
        # setsid so the framework restart cannot take it down with kterm.
        setsid nohup "$0" loop >/dev/null 2>&1 &
        sleep 2
        if pid=$(running_pid); then echo "started (pid $pid)"; else echo "FAILED to start"; exit 1; fi
        ;;
    stop)
        _n=0
        for _p in $(all_daemon_pids); do
            kill "$_p" 2>/dev/null && _n=$((_n + 1))
        done
        sleep 1
        # anything that ignored TERM
        for _p in $(all_daemon_pids); do kill -9 "$_p" 2>/dev/null; done
        rm -f "$PIDFILE"
        # belt and braces: if it died without running its trap the book would
        # linger on the shelf claiming it is still running.
        rm -f "$BOOK" 2>/dev/null
        if [ "$_n" -gt 0 ]; then echo "stopped $_n daemon(s)"; else echo "not running"; fi
        ;;
    status)
        _live=$(all_daemon_pids | tr '\n' ' ')
        case "$(echo "$_live" | wc -w)" in
            0) echo "not running" ;;
            1) echo "running (pid $_live)" ;;
            *) echo "running BUT $(echo "$_live" | wc -w) daemons: $_live" ;;
        esac
        echo "recoveries in last 24h: $(recoveries_today)"
        echo "syncs: $(cat /var/local/kfx-state/SYNC_COUNT 2>/dev/null)"
        [ -f "$DLOG" ] && tail -5 "$DLOG"
        ;;
    ensure)
        # Start if absent, say nothing if already up. Checks every live daemon,
        # not the pidfile, so a stale one cannot be joined by a second.
        [ -n "$(all_daemon_pids)" ] || {
            dlog "ensure: not running, starting"
            setsid nohup "$0" loop >/dev/null 2>&1 &
        }
        ;;
    loop)
        echo $$ > "$PIDFILE"
        loop
        ;;
    *)
        echo "usage: $0 start|stop|status|ensure"
        exit 2
        ;;
esac
