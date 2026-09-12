#!/bin/sh
# kfx-update.sh -- pull new code from GitHub, stage it, verify it, install it,
# and restart the sync daemon on the new version.
#
# A SECOND daemon, separate from kfx-daemon.sh, for one reason: the thing that
# restarts the sync daemon must not be the sync daemon. This one can kill and
# start that one freely, and it replaces itself only by re-exec'ing at the end
# of a successful update.
#
# Nothing here trusts the download. Every shell file must parse (sh -n) and
# every file in the manifest must arrive non-empty before anything is moved
# into place; the previous version is kept, and if the sync daemon will not
# come up on the new code the old code goes back and the daemon is restarted on
# it. A failed update leaves a working Kindle, which matters when the only way
# to fix it by hand is a USB cable.
#
#   kfx-update.sh check     one cycle now, print what happened
#   kfx-update.sh loop      the daemon: poll for a request, check periodically
#   kfx-update.sh start     start the daemon if it is not running
#   kfx-update.sh stop      stop it
#   kfx-update.sh status    what version is installed, and is it running
#   kfx-update.sh request   ask a running daemon to check right now
BASE=${BASE:-/mnt/us/extensions/kfx-sync}
CONF=${CONF:-$BASE/config}
[ -r "$CONF" ] && . "$CONF"

# Where updates come from. A branch, not a tag: publishing an update is
# committing a new VERSION, and rolling one back is committing the old one.
UPDATE_URL=${UPDATE_URL:-https://raw.githubusercontent.com/jaymart1983/shelfback/main/kindle}
UPDATE_EVERY=${UPDATE_EVERY:-900}        # a check every fifteen minutes
UPDATE_POLL=${UPDATE_POLL:-10}           # how often to look for a request
UPDATE_REQ=${UPDATE_REQ:-/var/local/kfx-update.req}
UPDATE_PID=${UPDATE_PID:-/var/local/kfx-update.pid}
LOGDIR=${LOGDIR:-/mnt/us/kfx-logs}
ULOG=${ULOG:-$LOGDIR/update.log}
STAGE=${STAGE:-/mnt/us/dedrm/.update}    # not /tmp: that is 64MB and shared
BACKUP=${BACKUP:-$BASE/.previous}
DAEMON=${DAEMON:-$BASE/kfx-daemon.sh}
CURL_MAX=${CURL_MAX:-60}

ulog() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$ULOG" 2>/dev/null; }
say()  { printf '%s\n' "$*"; ulog "$*"; }

local_version()  { cat "$BASE/VERSION" 2>/dev/null; }
remote_version() {
    curl -sS --max-time "$CURL_MAX" "$UPDATE_URL/VERSION" 2>/dev/null </dev/null \
        | head -1 | tr -d '\r\n '
}

# ---------------- fetch ----------------
# The manifest says which files make up a release. Fetching a fixed list means
# a file added upstream arrives with the release that expects it, and a typo in
# a name fails the whole update rather than half-installing one.
fetch_all() {
    rm -rf "$STAGE"; mkdir -p "$STAGE" 2>/dev/null || { say "no staging space"; return 1; }
    if ! curl -sS --max-time "$CURL_MAX" -o "$STAGE/MANIFEST" \
           "$UPDATE_URL/MANIFEST" 2>/dev/null </dev/null; then
        say "could not fetch the manifest"; return 1
    fi
    [ -s "$STAGE/MANIFEST" ] || { say "the manifest is empty"; return 1; }
    _fa_n=0
    while read -r _fa_f; do
        case "$_fa_f" in ''|'#'*) continue ;; esac
        # A name from the network becomes a path here, so allow only plain
        # names: no slashes, no leading dot, nothing that could escape $STAGE.
        case "$_fa_f" in
            */*|.*|*' '*) say "refusing a suspicious name in the manifest: $_fa_f"; return 1 ;;
        esac
        if ! curl -sS --max-time "$CURL_MAX" -o "$STAGE/$_fa_f" \
               "$UPDATE_URL/$_fa_f" 2>/dev/null </dev/null; then
            say "download failed: $_fa_f"; return 1
        fi
        [ -s "$STAGE/$_fa_f" ] || { say "downloaded empty: $_fa_f"; return 1; }
        _fa_n=$((_fa_n + 1))
    done < "$STAGE/MANIFEST"
    [ "$_fa_n" -gt 0 ] || { say "the manifest listed nothing"; return 1; }
    ulog "fetched $_fa_n file(s)"
    return 0
}

# ---------------- verify ----------------
# Cheap checks, but they catch what actually goes wrong over a flaky link: a
# truncated file, an HTML error page saved as a script, a half-written commit.
verify_stage() {
    _vs_bad=0
    while read -r _vs_f; do
        case "$_vs_f" in ''|'#'*) continue ;; esac
        [ -s "$STAGE/$_vs_f" ] || { say "missing after fetch: $_vs_f"; _vs_bad=1; continue; }
        case "$_vs_f" in
            *.sh)
                if ! sh -n "$STAGE/$_vs_f" 2>/dev/null; then
                    say "will not parse: $_vs_f"; _vs_bad=1
                fi
                # GitHub serves a 404 as HTML with status 404; curl without -f
                # writes it to the file. A shell file starting with "<" is that.
                case "$(head -c 1 "$STAGE/$_vs_f" 2>/dev/null)" in
                    '<') say "got a web page, not a script: $_vs_f"; _vs_bad=1 ;;
                esac ;;
        esac
    done < "$STAGE/MANIFEST"
    # The front end must still know its own build, or the menu shows nothing.
    if [ -f "$STAGE/menu.sh" ] && ! grep -q '^KFX_BUILD=' "$STAGE/menu.sh"; then
        say "menu.sh has no KFX_BUILD line"; _vs_bad=1
    fi
    [ "$_vs_bad" = 0 ]
}

# The files and the version marker are separate objects on a CDN and refresh
# independently. Measured 12 Sep 2026: minutes after a push, menu.sh served the
# new build while VERSION still served the old one. The other order is the
# dangerous one -- new VERSION, stale files -- and an earlier version of this
# script made it invisible by stamping the incoming menu.sh with whatever
# VERSION said, which labels old code as new.
#
# So the code carries its own version, and it has to agree. A mismatch is a
# half-propagated release: leave it, say so once, and pick it up next time.
stage_matches() {   # $1 = the version we believe we are installing
    [ -f "$STAGE/menu.sh" ] || return 0
    _sm_b=$(sed -n 's/^KFX_BUILD=\([0-9.]*\).*/\1/p' "$STAGE/menu.sh" | head -1)
    [ "$_sm_b" = "$1" ] && return 0
    say "half-published: VERSION says $1 but menu.sh is $_sm_b -- waiting"
    return 1
}

# ---------------- install ----------------
install_stage() {   # $1 = the version being installed
    rm -rf "$BACKUP"; mkdir -p "$BACKUP" 2>/dev/null
    while read -r _is_f; do
        case "$_is_f" in ''|'#'*) continue ;; esac
        [ -f "$BASE/$_is_f" ] && cp "$BASE/$_is_f" "$BACKUP/$_is_f" 2>/dev/null
    done < "$STAGE/MANIFEST"
    cp "$BASE/VERSION" "$BACKUP/VERSION" 2>/dev/null
    cp "$STAGE/MANIFEST" "$BACKUP/MANIFEST" 2>/dev/null

    while read -r _is_f; do
        case "$_is_f" in ''|'#'*) continue ;; esac
        cp "$STAGE/$_is_f" "$BASE/$_is_f" 2>/dev/null || { say "could not install $_is_f"; return 1; }
    done < "$STAGE/MANIFEST"
    chmod +x "$BASE"/*.sh 2>/dev/null
    printf '%s\n' "$1" > "$BASE/VERSION"
    cp "$STAGE/MANIFEST" "$BASE/MANIFEST" 2>/dev/null
    return 0
}

roll_back() {
    [ -d "$BACKUP" ] || { say "nothing to roll back to"; return 1; }
    _rb_n=0
    for _rb_f in "$BACKUP"/*; do
        [ -f "$_rb_f" ] || continue
        cp "$_rb_f" "$BASE/$(basename "$_rb_f")" 2>/dev/null && _rb_n=$((_rb_n + 1))
    done
    chmod +x "$BASE"/*.sh 2>/dev/null
    say "rolled back $_rb_n file(s) to $(local_version)"
    return 0
}

# ---------------- the sync daemon ----------------
sync_running() { sh "$DAEMON" status 2>/dev/null | head -1 | grep -q '^running'; }

restart_sync() {
    sh "$DAEMON" stop >/dev/null 2>&1
    sleep 2
    sh "$DAEMON" start >/dev/null 2>&1
    sleep 3
    sync_running
}

# ---------------- finding, then installing ----------------
# Finding an update and installing it are separate, because an install restarts
# the sync daemon and replaces the front end under whoever is reading it. So a
# new version is ANNOUNCED first: the menu grows an "Install update" item, and
# if nobody chooses it the install happens on its own after UPDATE_DELAY. The
# device ends up current either way; the difference is whether it happens while
# someone is looking at it.
UPDATE_DELAY=${UPDATE_DELAY:-300}                 # five minutes to decide
UPDATE_AVAIL=${UPDATE_AVAIL:-${STATEDIR:-/var/local/kfx-state}/UPDATE_AVAIL}
UPDATE_DUE=${UPDATE_DUE:-${STATEDIR:-/var/local/kfx-state}/UPDATE_DUE}
UPDATE_GO=${UPDATE_GO:-${STATEDIR:-/var/local/kfx-state}/UPDATE_GO}
UPDATE_SEEN=${UPDATE_SEEN:-${STATEDIR:-/var/local/kfx-state}/UPDATE_SEEN}
UPDATE_STATE=${UPDATE_STATE:-${STATEDIR:-/var/local/kfx-state}/UPDATE_STATE}

# One line the menu can show without reading a log: what happened last.
set_state() { mkdir -p "$(dirname "$UPDATE_STATE")" 2>/dev/null
              printf '%s\n' "$1" > "$UPDATE_STATE" 2>/dev/null; }

announce() {   # $1 = the version found
    mkdir -p "$(dirname "$UPDATE_AVAIL")" 2>/dev/null
    printf '%s\n' "$1" > "$UPDATE_AVAIL"
    [ -f "$UPDATE_DUE" ] || printf '%s\n' "$(( $(date +%s) + UPDATE_DELAY ))" > "$UPDATE_DUE"
    set_state "update available ($1)"
}
forget_update() { rm -f "$UPDATE_AVAIL" "$UPDATE_DUE" "$UPDATE_GO" 2>/dev/null; }

# Look, and say what was found. Does not install.
#
# Logs only when the answer CHANGES. Checking every fifteen minutes and writing
# "up to date" each time buries the one line that matters under ninety-six that
# do not.
check_once() {
    _co_have=$(local_version); _co_want=$(remote_version)
    if [ -z "$_co_want" ]; then
        set_state "error connecting"
        [ "$(cat "$UPDATE_SEEN" 2>/dev/null)" = "unreachable" ] || ulog "could not reach $UPDATE_URL"
        printf 'unreachable\n' > "$UPDATE_SEEN" 2>/dev/null
        return 1
    fi
    # A version is a build stamp: digits and a dot. Anything else means the
    # file is not what we think it is.
    case "$_co_want" in
        *[!0-9.]*|'') say "refusing a version that is not a build stamp: $_co_want"
                      set_state "error: bad version published"; return 1 ;;
    esac
    if [ "$_co_want" = "$_co_have" ]; then
        forget_update
        set_state "up to date (connected)"
        [ "$(cat "$UPDATE_SEEN" 2>/dev/null)" = "$_co_want" ] || ulog "up to date ($_co_have)"
        printf '%s\n' "$_co_want" > "$UPDATE_SEEN" 2>/dev/null
        return 0
    fi
    [ "$(cat "$UPDATE_SEEN" 2>/dev/null)" = "$_co_want" ] || say "update available: $_co_have -> $_co_want"
    printf '%s\n' "$_co_want" > "$UPDATE_SEEN" 2>/dev/null
    announce "$_co_want"
    return 0
}

# Do it. Called when the deadline passes, or when someone chooses to now.
install_now() {
    _in_want=$(cat "$UPDATE_AVAIL" 2>/dev/null)
    [ -n "$_in_want" ] || return 1
    case "$_in_want" in *[!0-9.]*) forget_update; return 1 ;; esac
    say "installing $(local_version) -> $_in_want"
    set_state "installing ($_in_want)"
    fetch_all    || { set_state "error downloading"; say "download failed"; rm -rf "$STAGE"; rm -f "$UPDATE_GO"; return 1; }
    verify_stage || { set_state "error: download did not verify"; rm -rf "$STAGE"; rm -f "$UPDATE_GO"; return 1; }
    stage_matches "$_in_want" || {
        set_state "waiting, release still publishing"
        rm -rf "$STAGE"; rm -f "$UPDATE_GO"
        # Not a failure of ours, and not permanent: drop the announcement so
        # the next check re-reads both and announces again when they agree.
        forget_update
        return 1
    }
    install_stage "$_in_want" || {
        set_state "error: install failed, rolled back"; roll_back; rm -rf "$STAGE"; rm -f "$UPDATE_GO"; return 1
    }
    rm -rf "$STAGE"
    if restart_sync; then
        say "installed $_in_want and restarted the sync daemon"
        set_state "installed ($_in_want)"
        forget_update
        printf '%s\n' "$_in_want" > "$UPDATE_SEEN" 2>/dev/null
    else
        say "the sync daemon will not start on $_in_want -- rolling back"
        roll_back
        if restart_sync; then say "back on $(local_version)"
        else say "ROLLBACK DID NOT START EITHER -- needs a USB cable"; fi
        set_state "rolled back, $_in_want would not run"
        forget_update
        return 1
    fi
    # This process is still running the old updater, and the file on disk is
    # now the new one, so start again on it. Only when we ARE the daemon:
    # "kfx-update.sh check" by hand must return to the prompt, not quietly
    # become a background loop.
    if [ "${IN_LOOP:-0}" = 1 ] && [ -x "$BASE/kfx-update.sh" ] && [ "${UPDATE_REEXEC:-1}" = 1 ]; then
        ulog "re-exec on the new updater"
        UPDATE_REEXEC=0 exec sh "$BASE/kfx-update.sh" loop
    fi
    return 0
}

# check, then install if one is waiting and its time has come
check_and_maybe_install() {
    check_once || return 1
    [ -f "$UPDATE_AVAIL" ] || return 0
    if [ -f "$UPDATE_GO" ]; then rm -f "$UPDATE_GO"; install_now; return $?; fi
    _cm_due=$(cat "$UPDATE_DUE" 2>/dev/null)
    case "$_cm_due" in ''|*[!0-9]*) return 0 ;; esac
    [ "$(date +%s)" -ge "$_cm_due" ] && { install_now; return $?; }
    return 0
}

# ---------------- the daemon ----------------
update_pids() {
    for _up_d in /proc/[0-9]*; do
        _up_p=${_up_d#/proc/}
        [ "$_up_p" = "$$" ] && continue
        grep -qa 'kfx-update' "$_up_d/cmdline" 2>/dev/null || continue
        grep -qa 'loop'       "$_up_d/cmdline" 2>/dev/null || continue
        echo "$_up_p"
    done
}

loop() {
    IN_LOOP=1
    echo $$ > "$UPDATE_PID"
    trap 'rm -f "$UPDATE_PID"; exit 0' INT TERM HUP
    ulog "update daemon started on $(local_version)"
    # Check immediately. The device may have been off for a week, and waiting a
    # quarter of an hour to find that out helps nobody.
    check_and_maybe_install
    _lp_last=$(date +%s)
    while :; do
        sleep "$UPDATE_POLL"
        if [ -f "$UPDATE_REQ" ]; then
            # Asked for from the menu or over FTP. Not logged: the answer gets
            # logged if it changed, and "someone pressed a key" is not news.
            rm -f "$UPDATE_REQ"
            check_and_maybe_install
            _lp_last=$(date +%s)
            continue
        fi
        # Chosen from the menu: install the announced version now, without
        # waiting out the rest of the five minutes.
        if [ -f "$UPDATE_GO" ]; then
            rm -f "$UPDATE_GO"
            install_now
            _lp_last=$(date +%s)
            continue
        fi
        # The deadline on an announced update.
        if [ -f "$UPDATE_AVAIL" ]; then
            _lp_due=$(cat "$UPDATE_DUE" 2>/dev/null)
            case "$_lp_due" in
                ''|*[!0-9]*) : ;;
                *) [ "$(date +%s)" -ge "$_lp_due" ] && { install_now; _lp_last=$(date +%s); continue; } ;;
            esac
        fi
        [ $(( $(date +%s) - _lp_last )) -ge "$UPDATE_EVERY" ] && {
            check_and_maybe_install
            _lp_last=$(date +%s)
        }
    done
}

case "${1:-status}" in
    check)   check_and_maybe_install ;;
    install) : > "$UPDATE_GO"
             if [ -n "$(update_pids)" ]; then echo "installing"; else install_now; fi ;;
    request) mkdir -p "$(dirname "$UPDATE_REQ")" 2>/dev/null
             : > "$UPDATE_REQ"
             if [ -n "$(update_pids)" ]; then echo "asked the update daemon to check"
             else echo "the update daemon is not running"; fi ;;
    start)   if [ -n "$(update_pids)" ]; then echo "already running"; exit 0; fi
             setsid nohup sh "$0" loop >/dev/null 2>&1 &
             sleep 2
             if [ -n "$(update_pids)" ]; then echo "started"; else echo "FAILED to start"; exit 1; fi ;;
    stop)    _n=0
             for _p in $(update_pids); do kill "$_p" 2>/dev/null && _n=$((_n + 1)); done
             sleep 1
             for _p in $(update_pids); do kill -9 "$_p" 2>/dev/null; done
             rm -f "$UPDATE_PID"
             [ "$_n" -gt 0 ] && echo "stopped" || echo "not running" ;;
    status)  _v=$(local_version); printf 'installed: %s\n' "${_v:-unknown}"
             _a=$(cat "$UPDATE_AVAIL" 2>/dev/null); [ -n "$_a" ] && printf 'available: %s\n' "$_a"
             if [ -n "$(update_pids)" ]; then echo "update daemon: running"
             else echo "update daemon: not running"; fi
             [ -f "$ULOG" ] && tail -5 "$ULOG" ;;
    loop)    loop ;;
    *)       echo "usage: $0 {check|install|request|start|stop|status|loop}"; exit 1 ;;
esac
