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
UPDATE_EVERY=${UPDATE_EVERY:-21600}      # a check every six hours
UPDATE_POLL=${UPDATE_POLL:-30}           # how often to look for a request
UPDATE_REQ=${UPDATE_REQ:-/var/local/kfx-update.req}
UPDATE_PID=${UPDATE_PID:-/var/local/kfx-update.pid}
ULOG=${ULOG:-/mnt/us/kfx-update.log}
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

# ---------------- install ----------------
install_stage() {   # $1 = the version being installed
    rm -rf "$BACKUP"; mkdir -p "$BACKUP" 2>/dev/null
    while read -r _is_f; do
        case "$_is_f" in ''|'#'*) continue ;; esac
        [ -f "$BASE/$_is_f" ] && cp "$BASE/$_is_f" "$BACKUP/$_is_f" 2>/dev/null
    done < "$STAGE/MANIFEST"
    cp "$BASE/VERSION" "$BACKUP/VERSION" 2>/dev/null
    cp "$STAGE/MANIFEST" "$BACKUP/MANIFEST" 2>/dev/null

    # The build number on screen must mean "the code that is running", so the
    # incoming menu.sh is stamped with the version being installed. Without
    # this it would keep whatever the last USB deploy stamped, and every
    # over-the-air update would look like the build before it.
    if [ -f "$STAGE/menu.sh" ]; then
        sed "s/^KFX_BUILD=.*/KFX_BUILD=$1   # installed over the air/" \
            "$STAGE/menu.sh" > "$STAGE/menu.sh.stamped" 2>/dev/null
        if sh -n "$STAGE/menu.sh.stamped" 2>/dev/null; then
            mv "$STAGE/menu.sh.stamped" "$STAGE/menu.sh"
        else
            rm -f "$STAGE/menu.sh.stamped"; say "stamping menu.sh broke it"; return 1
        fi
    fi

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

# ---------------- one cycle ----------------
check_once() {
    _co_have=$(local_version); _co_want=$(remote_version)
    if [ -z "$_co_want" ]; then
        say "could not reach $UPDATE_URL"; return 1
    fi
    # A version is a build stamp: digits and a dot. Anything else means the
    # file is not what we think it is.
    case "$_co_want" in
        *[!0-9.]*|'') say "refusing a version that is not a build stamp: $_co_want"; return 1 ;;
    esac
    if [ "$_co_want" = "$_co_have" ]; then
        ulog "up to date ($_co_have)"
        UPDATE_LAST="up to date"
        return 0
    fi
    say "update: $_co_have -> $_co_want"
    fetch_all    || { UPDATE_LAST="download failed"; rm -rf "$STAGE"; return 1; }
    verify_stage || { UPDATE_LAST="the download did not verify"; rm -rf "$STAGE"; return 1; }
    install_stage "$_co_want" || {
        UPDATE_LAST="install failed"; roll_back; rm -rf "$STAGE"; return 1
    }
    rm -rf "$STAGE"
    if restart_sync; then
        say "installed $_co_want and restarted the sync daemon"
        UPDATE_LAST="installed $_co_want"
    else
        say "the sync daemon will not start on $_co_want -- rolling back"
        roll_back
        if restart_sync; then say "back on $(local_version)"
        else say "ROLLBACK DID NOT START EITHER -- needs a USB cable"; fi
        UPDATE_LAST="rolled back"
        return 1
    fi
    # Replace ourselves last, and only by starting again: this process is
    # running the old code until it does.
    if [ -x "$BASE/kfx-update.sh" ] && [ "${UPDATE_REEXEC:-1}" = 1 ]; then
        ulog "re-exec on the new updater"
        UPDATE_REEXEC=0 exec sh "$BASE/kfx-update.sh" loop
    fi
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
    echo $$ > "$UPDATE_PID"
    trap 'rm -f "$UPDATE_PID"; exit 0' INT TERM HUP
    ulog "update daemon started, installed version $(local_version)"
    _lp_last=0
    while :; do
        # Asked for, by the menu or over FTP: check straight away.
        if [ -f "$UPDATE_REQ" ]; then
            rm -f "$UPDATE_REQ"
            ulog "check requested"
            check_once
            _lp_last=$(date +%s)
        elif [ $(( $(date +%s) - _lp_last )) -ge "$UPDATE_EVERY" ]; then
            check_once
            _lp_last=$(date +%s)
        fi
        sleep "$UPDATE_POLL"
    done
}

case "${1:-status}" in
    check)   check_once ;;
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
             if [ -n "$(update_pids)" ]; then echo "update daemon: running"
             else echo "update daemon: not running"; fi
             [ -f "$ULOG" ] && tail -5 "$ULOG" ;;
    loop)    loop ;;
    *)       echo "usage: $0 {check|request|start|stop|status|loop}"; exit 1 ;;
esac
