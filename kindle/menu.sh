#!/bin/sh
# KFX Sync -- admin front end. Launched inside kterm by "KFX Sync.sh".
#
# The device has no timer of its own: Unraid is always on and has real cron, so
# it drives the schedule and pokes this device. This loop only wakes to notice
# commands and to refresh the status panel.

# Which code this is: the deploy time, mmddyyyy.hhmm. Shown at the top right
# of the menu and in the log. Set by deploy.sh -- do not edit by hand.
KFX_BUILD=09132026.0854   # stamped by deploy.sh: mmddyyyy.hhmm of the deploy

CONF=${CONF:-/mnt/us/extensions/kfx-sync/config}
[ -r "$CONF" ] && . "$CONF"

# Who this Kindle hands books to. "receiver" is the book-receiver service;
# "cwa" talks to Calibre-Web Automated directly (cwa.sh) and needs nothing else
# on the server. Set BACKEND=cwa in the config to switch; delete it to go back.
BACKEND=${BACKEND:-receiver}
# Test first: in this shell, sourcing a missing file exits the whole script.
if [ "$BACKEND" = cwa ] && [ -r "$(dirname "$CONF")/cwa.sh" ]; then
    . "$(dirname "$CONF")/cwa.sh"
else
    BACKEND=receiver
fi
DEST_L=receiver; DEST_UC=RECEIVER
[ "$BACKEND" = cwa ] && { DEST_L=calibre; DEST_UC=CALIBRE; }

# The decrypt tool, in its own extension folder. Deliberately NOT $BASE: the
# daemon sets BASE to its own folder (kfx-sync) so it can find this script, and
# menu.sh inherited that -- so every decryption started from the daemon looked
# for run_cmd.sh in the wrong place and failed in seconds with "not found"
# (11 Sep 2026; it is why books reached Calibre still encrypted).
DEDRM_BASE=${DEDRM_BASE:-/mnt/us/extensions/kfxdedrm-scriptlet}
RUNNER=${RUNNER:-$DEDRM_BASE/bin/run_cmd.sh}
DOCS=${DOCS:-/mnt/us/documents}
OUT=${OUT:-/mnt/us/dedrm}
ITEMS=${ITEMS:-/mnt/us/documents/Downloads/Items01}
RECEIVER=${RECEIVER:-http://192.168.1.211:8086}
TOKEN=${TOKEN:-}
MAX_RETRIES=${MAX_RETRIES:-3}
PURGE_AFTER_UPLOAD=${PURGE_AFTER_UPLOAD:-0}
REFRESH=${REFRESH:-60}          # status panel repaint interval, seconds
PAGE=${PAGE:-8}                 # clear the page every N progress lines
# Use the terminal's actual width rather than a guess, so a title only gets an
# ellipsis when it genuinely reaches the right edge. stty is available in kterm;
# clamp to something sane if it reports nonsense.
_cols=$(stty size 2>/dev/null | awk '{print $2}')
case "$_cols" in ''|*[!0-9]*) _cols=0 ;; esac
[ "$_cols" -ge 40 ] && [ "$_cols" -le 200 ] || _cols=56
W=${WIDTH:-$_cols}
TAGW=${TAGW:-16}                # widest tag is "sent to receiver"

# Matching is keyed on the ASIN, not the filename. The Kindle's FAT mount cannot
# represent characters like an en-dash and substitutes "?", so a title read off
# disk never byte-matches the name recorded at upload time and the book looks
# perpetually pending. The ASIN is ASCII and survives that intact.
# One directory holding every log, and nothing else. It is what the read-only
# FTP server serves, so what goes in here is what anyone on the network can
# read: logs and the book state, never cwa.conf, never the books themselves.
LOGDIR=${LOGDIR:-/mnt/us/kfx-logs}
mkdir -p "$LOGDIR" 2>/dev/null
# The logs used to be scattered across /mnt/us. Move them in once, keeping the
# history rather than starting fresh.
for _lm in "$OUT/sync.log:sync.log" /mnt/us/kfx-daemon.log:daemon.log \
           /mnt/us/kfx-update.log:update.log /mnt/us/kfx-recoveries.log:recoveries.log; do
    _lm_f=${_lm%%:*}; _lm_t=${_lm##*:}
    [ -f "$_lm_f" ] && [ ! -f "$LOGDIR/$_lm_t" ] && mv "$_lm_f" "$LOGDIR/$_lm_t" 2>/dev/null
done
LOG="$LOGDIR/sync.log"; SPOOL=/tmp/kfxsync.spool
mkdir -p "$OUT"; touch "$LOG"; rm -f "$SPOOL"

# The one record per book. It lives next to sync.log rather than in
# /var/local so it can be read by mounting the Kindle, which is how this thing
# gets debugged. Nothing syncs while the Kindle is mounted anyway, so losing
# write access to it for the duration costs nothing.
# Sourcing a missing file exits this shell outright, so test first.
# Anchored on $CONF, like cwa.sh above: $0 is the *calling* script when the
# daemon sources this file, so dirname $0 points at the wrong place there.
[ -r "$(dirname "$CONF")/state.sh" ] && . "$(dirname "$CONF")/state.sh"
command -v st_migrate >/dev/null 2>&1 && st_migrate "$OUT" "${STATEDIR:-/var/local/kfx-state}"

keyof() {
    n=$(basename "$1"); n=${n%.kfx-zip}; n=${n%.kfx}
    k=$(printf '%s' "$n" | sed -n 's/.*_\(B[A-Z0-9]\{9\}\)\(_sample\)\{0,1\}$/\1\2/p')
    [ -n "$k" ] && { printf '%s' "$k"; return; }
    k=$(printf '%s' "$n" | sed -n 's/.*_\([0-9A-Fa-f]\{32\}\)$/\1/p')
    [ -n "$k" ] && { printf '%s' "$k"; return; }
    printf '%s' "$n" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z' | cut -c1-40
}

# Rebuild the key indexes from the human-readable name lists. Cheap, idempotent,
# and it reconciles anything recorded before keying existed.

rule()  { printf '%*s\n' "$W" '' | tr ' ' '='; }
short() { s=$1; m=$2; if [ ${#s} -gt "$m" ]; then printf '%s...' "$(printf '%s' "$s" | cut -c1-$((m-3)))"; else printf '%s' "$s"; fi; }

# Every line is echoed to the screen, appended to the on-device log, and spooled
# for forwarding to the receiver so it can be read from the host.
emit() {
    line="$1"
    echo "$line"
    printf '%s\n' "$(date '+%H:%M:%S') $line" >> "$LOG"
    printf '%s\n' "$(date '+%H:%M:%S') $line" >> "$SPOOL"
}
flush_log() {
    [ "$BACKEND" = cwa ] && { : > "$SPOOL"; return 0; }   # the log stays on the Kindle
    [ -s "$SPOOL" ] || return 0
    curl -sS -X POST --max-time 15 --data-binary @"$SPOOL" "$RECEIVER/log" >/dev/null 2>&1
    : > "$SPOOL"
}

known()     { grep -Fxq "$2" "$1" 2>/dev/null; }
# Tell the server what this Kindle's catalogue holds, so the whole library is
# visible there rather than only the books that happened to reach it.
report_library() {
    [ "$BACKEND" = cwa ] && return 0
    [ -r "$CC_DB" ] || return 0
    tmp=/tmp/kfx-lib.$$
    sqlite3 "$CC_DB" "select distinct p_cdeKey||'\t'||replace(coalesce(p_titles_0_nominal,''),'\t',' ')
        from Entries where p_cdeType='EBOK' and p_type='Entry:Item' and p_cdeKey is not null;" \
        2>/dev/null | awk -F'\t' 'length($1)==10 {printf "%s\t%s\t%s\n", $1, $2, ""}' > "$tmp"
    if [ -s "$tmp" ]; then
        curl -sS -o /dev/null --max-time 60 -X POST --data-binary @"$tmp" \
            "$RECEIVER/library" 2>/dev/null </dev/null
    fi
    rm -f "$tmp"
}

# ---------------- server-held state ----------------
# The receiver owns the record of what has been synced; this device keeps none.
# Two consequences worth knowing:
#   - deleting a line from the server's .sync-state.tsv makes the next pass treat
#     that book as un-synced, so it is re-downloaded and re-decrypted.
#   - whether a book still needs DECRYPTING is answered by whether its .kfx-zip
#     exists on disk, not by a list. One less thing to keep in step.
SYNCED_CACHE=/tmp/kfx-synced.list

fetch_synced() {
    if [ "$BACKEND" = cwa ]; then
        # Calibre's list plus our own recent uploads. cwa_refresh never leaves
        # a partial list, and failing here stops the pass, as below.
        # Record how the attempt went, for the status panel: a wrong password
        # must show as an error, not as a server that merely answers.
        if ! cwa_refresh; then state_set CWA_LINK "${CWA_ERR:-list}"; return 1; fi
        state_set CWA_LINK ok
        cwa_synced_view "$SYNCED_CACHE"
        return 0
    fi
    code=$(curl -sS -o "$SYNCED_CACHE.new" -w '%{http_code}' --max-time 30 \
             "$RECEIVER/synced" 2>/dev/null </dev/null)
    if [ "$code" = "200" ]; then
        mv "$SYNCED_CACHE.new" "$SYNCED_CACHE"
        return 0
    fi
    rm -f "$SYNCED_CACHE.new"
    # No list means we cannot tell what is done. Doing the work anyway would
    # re-upload the entire library, so callers treat this as a hard stop.
    return 1
}

synced_known() {   # $1 = ASIN
    [ -s "$SYNCED_CACHE" ] || return 1
    grep -qxF "$1" "$SYNCED_CACHE" 2>/dev/null
}

asin_of() {        # $1 = any path or basename carrying _<ASIN>
    # The ASIN may be followed by "_sample" rather than the extension, e.g.
    # "..._B007UJPULS_sample.kfx-zip". Requiring a dot straight after missed
    # those, so they never counted as synced and were re-uploaded every pass.
    # Must give the same answer for a full filename and for one whose extension
    # has already been stripped: run_pass passes the bare basename, and a key
    # that changes shape between callers means "already done" is never true.
    printf '%s' "$(basename "$1")" \
      | sed -n 's/.*_\(B[A-Z0-9]\{9\}\)\(_sample\)\{0,1\}\(\..*\)\{0,1\}$/\1/p'
}

# The identity used to answer "has this already been synced?". Normally the
# ASIN, but a sideloaded file may carry a UUID and have no ASIN at all. Such a
# book had NO identity, so up_known was always false and it was decrypted and
# re-uploaded on every pass -- which put three copies of two books into Calibre
# before it was caught.
key_of() {
    _ko=$(asin_of "$1")
    if [ -n "$_ko" ]; then printf '%s' "$_ko"; return 0; fi
    _ko=$(basename "$1"); _ko=${_ko%.kfx-zip}; _ko=${_ko%.kfx}
    printf '%s' "$_ko" | tr -d '\t\n'
}

up_known()  { k=$(key_of "$1"); [ -n "$k" ] && synced_known "$k"; }
dec_known() { k=$(key_of "$1"); [ -n "$k" ] && synced_known "$k"; }
mark_up()   { :; }   # the receiver records this itself, on receipt
mark_dec()  { :; }

# Count ASINs, not lines: the server's reply ends with a blank line, and
# wc -l counts it as a book.
n_synced() { grep -cE '^B[A-Z0-9]{9}$' "$SYNCED_CACHE" 2>/dev/null || echo 0; }
n_dec() { [ -s "$SYNCED_CACHE" ] && n_synced || echo '-'; }
n_up()  { n_dec; }
n_bad() { st_count failed; }
# One number for "things went wrong", whatever the cause. The detail screen
# separates them, because the fixes differ.
n_problems() { echo $(( $(n_bad) + $(n_stalled) )); }

n_todo(){ ls -1 "$OUT"/*.kfx-zip 2>/dev/null > /tmp/kfxsync.zips
          c=0; while read -r f; do up_known "$f" || c=$((c + 1)); done < /tmp/kfxsync.zips
          rm -f /tmp/kfxsync.zips; echo "$c"; }

# Books in your Amazon library that are not on the device. cc.db is the full
# catalogue; p_isArchived=1 means cloud-only (verified: isArchived=0 matched the
# on-device count exactly). Dictionaries and Audible items are excluded -- Amazon
# ships a large free dictionary catalogue that would otherwise swamp the count.
CC_DB=/var/local/cc.db
title_of() {
    t=$(sqlite3 "$CC_DB" "select replace(coalesce(p_titles_0_nominal,''),'|','/')
        from Entries where p_cdeKey='$1' limit 1;" 2>/dev/null | head -1)
    [ -n "$t" ] && printf '%s' "$t" || printf '%s' "(title unknown)"
}
# p_isArchived is NOT a cloud indicator. Verified on 2026-09-09 by dumping the
# catalogue: 300 EBOK Entry:Item rows = 150 distinct books, and all 150 carry
# BOTH isArchived=1 and isArchived=0. The old "in cloud" figure was just the
# library counted twice. Worse, cc.db holds ONLY books already on the device
# (catalogue 150, on disk 150, difference zero both ways) -- it grows as the
# library UI encounters titles, it is not a mirror of the account.
#
# So the wanted-list is the honest source for books to fetch: ASINs you supply,
# one per line, optionally "ASIN,TYPE" (TYPE defaults to EBOK). Lines starting
# with # are ignored.
WANTED=${WANTED:-/mnt/us/extensions/kfx-sync/wanted-asins}

wanted_list() {
    [ -r "$WANTED" ] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$WANTED" 2>/dev/null \
      | grep -E '^B[A-Z0-9]{9}(,[A-Z]+)?$' \
      | sed 's/,.*//' | sort -u
}
n_wanted() { wanted_list | wc -l | tr -d ' '; }

# ---------------- download health ----------------
# A failed download leaves its .sdr sidecar with no book file beside it: the
# manifest and the tiny PHL sidecar arrive, the content never does. That is the
# signature of a jammed transfer queue (seen 2026-09-09); a reboot clears it.
#
# Key on the ASIN, never the title. Amazon revises titles, which renames the
# book file and orphans the old sidecar -- a title-stem match reported three
# long-since-downloaded books as failures.
stalled_list() {
    [ -d "$ITEMS" ] || return 0
    have=/tmp/kfx-have.$$
    # Two steps: \| alternation in a sed BRE is not portable, and getting it
    # wrong silently empties "have", which reports the whole library as stalled.
    ls -1 "$ITEMS" 2>/dev/null \
      | grep -E '\.(kfx|kfx-zip|azw3|azw|mobi|pdf)$' \
      | sed -n 's/.*_\(B[A-Z0-9]\{9\}\)\..*$/\1/p' \
      | sort -u > "$have"
    for d in "$ITEMS"/*.sdr; do
        [ -d "$d" ] || continue
        base=$(basename "$d" .sdr)
        asin=$(printf '%s' "$base" | sed -n 's/.*_\(B[A-Z0-9]\{9\}\)$/\1/p')
        [ -n "$asin" ] || continue
        grep -qxF "$asin" "$have" || printf '%s\n' "$base"
    done
    rm -f "$have"
}
n_stalled() { stalled_list | wc -l | tr -d ' '; }

# ---------------- bulk download ----------------
# Trigger recovered from EInkReadNowService.jar (library/action/
# DownloadActionHandler): kppDownloadAction takes kppItems, one "cdeKey,type"
# per item, ';' between items.
#   printf '{ kppItems = "B0FP31CMKR,EBOK" }' \
#     | lipc-hash-prop com.lab126.readnow kppDownloadAction   -> kppResponseCode = "OK"
DL_BATCH=${DL_BATCH:-5}
DL_PAUSE=${DL_PAUSE:-25}

missing_list() {
    have=/tmp/kfx-dlhave.$$
    ls -1 "$ITEMS" 2>/dev/null \
      | grep -E '\.(kfx|kfx-zip|azw3|azw|mobi|pdf)$' \
      | sed -n 's/.*_\(B[A-Z0-9]\{9\}\)\..*$/\1/p' \
      | sort -u > "$have"
    # Two sources: catalogue rows with no file here, plus anything on the
    # wanted-list. cc.db alone is not enough -- it only lists books already on
    # the device, so on its own it can never report anything missing.
    { sqlite3 "$CC_DB" "select distinct p_cdeKey from Entries
        where p_cdeType='EBOK' and p_type='Entry:Item' and p_cdeKey is not null;" 2>/dev/null
      wanted_list
    } | sort -u | while read -r a; do
            case "$a" in B*) ;; *) continue ;; esac
            grep -qxF "$a" "$have" || printf '%s\n' "$a"
        done
    rm -f "$have"
}
# Books we still owe: in the catalogue, not on disk, and not already synced.
# The last clause matters because purge deliberately deletes synced books --
# without it the purge and the fetcher chase each other forever.
pending_list() {
    missing_list | while read -r _pl; do
        case "$_pl" in B*) ;; *) continue ;; esac
        synced_known "$_pl" && continue
        printf '%s\n' "$_pl"
    done
}
n_missing() { pending_list | wc -l | tr -d ' '; }

send_batch() {   # $1 = "asin,EBOK;asin,EBOK;..."
    printf '{ kppItems = "%s" }' "$1" \
      | lipc-hash-prop com.lab126.readnow kppDownloadAction 2>&1 \
      | grep -o 'kppResponseCode = "[A-Z_]*"' | head -1
}

# Only the SINGLE-item payload is proven. Multi-item via ';' is inferred from the
# delimiter literals in DownloadActionHandler, so if a batch is rejected fall
# back to one at a time rather than failing every remaining book.
BATCH_OK=unknown
flush_batch() {   # echoes "<accepted> <rejected>"
    acc=0; rej=0
    if [ "$BATCH_OK" != "no" ]; then
        rc=$(send_batch "$1")
        case "$rc" in
            *OK*) BATCH_OK=yes
                  acc=$(printf '%s' "$1" | tr ';' '\n' | grep -c ',')
                  echo "$acc $rej"; return ;;
            *)    [ "$BATCH_OK" = unknown ] && { BATCH_OK=no; emit "batch form rejected ($rc); one at a time"; } ;;
        esac
    fi
    for item in $(printf '%s' "$1" | tr ';' ' '); do
        rc=$(send_batch "$item")
        case "$rc" in *OK*) acc=$((acc + 1)) ;; *) rej=$((rej + 1)) ;; esac
        sleep 2
    done
    echo "$acc $rej"
}

# ---------------- hands-off acquisition ----------------
# For this to need no human, the device has to LEARN about new books on its own.
# Amazon delivers library changes as ToDo items; com.lab126.todo publishes
# scheduleToDo (Int, write) which asks the daemon to poll now rather than wait
# for its own timer. com.lab126.archive then processes the archive.sync topic and
# writes new entries into cc.db -- which is how a shared book becomes a catalogue
# row with no file next to it, i.e. exactly what missing_list looks for.
AUTO_FETCH=${AUTO_FETCH:-1}
MAX_FETCH_PER_PASS=${MAX_FETCH_PER_PASS:-20}
CLOUD_WAIT=${CLOUD_WAIT:-25}

# $1 = seconds to wait for the sync to come back (default CLOUD_WAIT).
#
# These two ARE the library refresh: scheduleToDo makes the todo daemon poll
# Amazon now, and refreshCache makes the archive service re-sync the archived
# (cloud) item list into cc.db. Verified on 2026-09-09 -- the log showed
# "ProcessingToDo:status=starting,reason=Customer",
# "handleRefreshCacheCallback::syncing archived items" and
# "DownloadArchiveItems:status=success". So the not-downloaded list IS refreshed
# from Amazon each time, not read from a stale local cache.
refresh_cloud() {
    lipc-set-prop com.lab126.todo scheduleToDo 1 >/dev/null 2>&1 </dev/null
    rc=$?
    lipc-set-prop com.lab126.archive refreshCache "archive.sync" >/dev/null 2>&1 </dev/null
    sleep "${1:-$CLOUD_WAIT}"
    return $rc
}

# Request, but do NOT wait for the bytes. Downloads run in the background and
# the next scheduled pass collects whatever landed -- far more robust than
# blocking here while a 30-minute cron tick is already doing the waiting for us.
auto_fetch() {
    [ "$AUTO_FETCH" = 1 ] || return 0
    progress "checking" "for new books"
    refresh_cloud "$1"
    tmp=/tmp/kfx-auto.$$
    fetch_candidates | head -"$MAX_FETCH_PER_PASS" > "$tmp" 2>/dev/null
    n=$(wc -l < "$tmp" | tr -d ' ')
    if [ "${n:-0}" = 0 ]; then
        rm -f "$tmp"; emit "no new books in the cloud"; return 0
    fi
    emit "found $n new book(s); requesting"
    batch=""; c=0; req=0
    while read -r a; do
        [ -n "$a" ] || continue
        mark_inflight "$a"
        batch="${batch:+$batch;}$a,EBOK"; c=$((c + 1))
        if [ "$c" -ge "$DL_BATCH" ]; then
            set -- $(flush_batch "$batch"); req=$((req + ${1:-0}))
            progress "get" "requested $req/$n"
            batch=""; c=0; sleep "$DL_PAUSE"
        fi
    done < "$tmp"
    if [ -n "$batch" ]; then
        set -- $(flush_batch "$batch"); req=$((req + ${1:-0}))
        progress "get" "requested $req/$n"
    fi
    rm -f "$tmp"
    emit "requested $req book(s); next pass will collect them"
}

# ---------------- purge after confirmation ----------------
# This Kindle is not read from -- it exists to run KFX Sync -- so once a book is
# safely in Calibre there is no reason to keep either the original or the
# decrypted intermediate. 244MB of .kfx-zip alone at last count.
#
# The interlock is deliberately one-directional: the host publishes the ASINs
# Calibre actually holds WITH A REAL FILE ON DISK, and the Kindle only ever
# deletes against that list. A row existing in Calibre is not enough -- a book
# record with a missing file would otherwise authorise deleting the last copy.
# The endpoint returns 503 rather than an empty 200 if it cannot tell, so
# "cannot confirm" can never be mistaken for "nothing is confirmed".
PURGE_SYNCED=${PURGE_SYNCED:-1}
PURGE_KEEP_DAYS=${PURGE_KEEP_DAYS:-0}

purge_synced() {
    [ "$PURGE_SYNCED" = 1 ] || return 0
    list=/tmp/kfx-confirmed.$$
    if [ "$BACKEND" = cwa ]; then
        # Fresh: sync_once stops before purging unless cwa_refresh succeeded.
        if cp "$CWA_ASINS" "$list" 2>/dev/null; then code=200; else code=none; fi
    else
        code=$(curl -sS -o "$list" -w '%{http_code}' --max-time 30 \
                 "$RECEIVER/confirmed" 2>/dev/null </dev/null)
    fi
    if [ "$code" != "200" ]; then
        rm -f "$list"
        flog "PURGE SKIPPED: host could not confirm (http ${code:-none})"
        return 0
    fi
    # /confirmed now also carries non-ASIN sync keys (a sideloaded book's
    # filename). Count and act on exact ASINs only: a key that merely starts
    # with B must never be turned into a delete glob.
    n=$(grep -cE '^B[A-Z0-9]{9}$' "$list" 2>/dev/null | head -1)
    if [ "${n:-0}" -lt 1 ]; then
        rm -f "$list"; flog "PURGE SKIPPED: empty confirmation list"; return 0
    fi

    flog "PURGE: checking $n"
    freed=0; books=0
    while read -r _pg_asin; do
        case "$_pg_asin" in
            B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
            *) continue ;;
        esac
        # Only touch a book we can still see locally.
        found=0
        for f in "$ITEMS"/*"_$_pg_asin".kfx "$ITEMS"/*"_$_pg_asin".azw3 \
                 "$ITEMS"/*"_$_pg_asin".azw "$OUT"/*"_$_pg_asin".kfx-zip; do
            [ -f "$f" ] || continue
            kb=$(( $(wc -c < "$f" 2>/dev/null || echo 0) / 1024 ))
            rm -f "$f" 2>/dev/null && { freed=$((freed + kb)); found=1; }
        done
        # The sidecar directory goes with it.
        for d in "$ITEMS"/*"_$_pg_asin".sdr; do
            [ -d "$d" ] || continue
            kb=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
            rm -rf "$d" 2>/dev/null && freed=$((freed + ${kb:-0}))
        done
        [ "$found" = 1 ] && books=$((books + 1))
        # Calibre has it and the local copy is gone: that is the end of this
        # book's story, and the last chance to say so. Nothing else runs for a
        # book that no longer exists on the device -- which is exactly how the
        # old .failed list kept reporting books that had long since arrived.
        # Only for books this Kindle actually handled: the confirmation list is
        # the whole library, and recording all of it would turn our account of
        # what we did into a copy of Calibre's catalogue.
        if [ "$found" = 1 ] || st_line "$_pg_asin" >/dev/null 2>&1; then
            st_set "$_pg_asin" stage=confirmed note=-
        fi
    done < "$list"
    rm -f "$list"
    if [ "$books" -gt 0 ]; then
        flog "PURGED $books book(s), freed $((freed / 1024))MB"
    fi
}

# ---------------- in-flight tracking ----------------
# A request is not instant. Fast watch polled every 60s, saw the same books
# still missing, and re-requested them every cycle -- duplicate transfers
# collide (dup_uniq_id) and jam tmd, which is exactly what stalled three shared
# books on 2026-09-09 (three unconsumed .tmp_manifest files, no .kfx at all).
# Never ask twice for the same book inside the cooldown.
INFLIGHT="$OUT/.inflight"
REQ_COOLDOWN=${REQ_COOLDOWN:-1200}

mark_inflight() { printf '%s %s\n' "$1" "$(date +%s)" >> "$INFLIGHT"; }

prune_inflight() {
    [ -f "$INFLIGHT" ] || return 0
    _pi_now=$(date +%s); _pi_tmp="$INFLIGHT.new"
    : > "$_pi_tmp"
    while read -r _pi_asin _pi_ts; do
        [ -n "$_pi_asin" ] || continue
        [ $((_pi_now - ${_pi_ts:-0})) -lt "$REQ_COOLDOWN" ] && \
            printf '%s %s\n' "$_pi_asin" "$_pi_ts" >> "$_pi_tmp"
    done < "$INFLIGHT"
    mv "$_pi_tmp" "$INFLIGHT" 2>/dev/null
}

# NB: the loop variables here are deliberately NOT named `a`. This function is
# called from inside `missing_list | while read -r a`, and a plain `read -r a`
# in here overwrites the CALLER's variable -- so fetch_candidates printed the
# clobbered (empty) value instead of the ASIN. The result was a file of blank
# lines: wc -l reported "FOUND 1 NEW BOOK(S)" and the per-book loop then skipped
# every line as empty, so nothing was ever downloaded or decrypted.
is_inflight() {
    [ -f "$INFLIGHT" ] || return 1
    _if_now=$(date +%s)
    while read -r _if_asin _if_ts; do
        [ "$_if_asin" = "$1" ] || continue
        [ $((_if_now - ${_if_ts:-0})) -lt "$REQ_COOLDOWN" ] && return 0
    done < "$INFLIGHT"
    return 1
}

# Books worth asking for: missing, and not already asked for recently.
fetch_candidates() {
    prune_inflight
    pending_list | while read -r cand; do
        is_inflight "$cand" && continue
        backed_off "$cand" && continue
        # Asking too early does not just fail -- it leaves a dead partial
        # behind and burns the stall timeout. Skipping costs one pass.
        ready_or_waited "$cand" || continue
        printf '%s\n' "$cand"
    done
}

# ---------------- download progress ----------------
# Landed: the book file is here. Amazon still delivers some older titles as
# AZW3 rather than KFX; with the CWA backend those are sent as they are.
dl_done() {
    ls "$ITEMS"/*"_$1".kfx >/dev/null 2>&1 && return 0
    [ "$BACKEND" = cwa ] && ls "$ITEMS"/*"_$1".azw3 >/dev/null 2>&1
}

# Book bytes ONLY. The .sdr sidecar (manifest, PHL, EndActions, StartActions,
# LanguageLayer) lands almost immediately and is ~70KB, so counting it made a
# download that had not started look like steady progress at 7% -- the meter
# was measuring metadata and calling it the book.
dl_kb() {   # $1 = asin
    total=0
    for f in "$ITEMS"/*"$1"*; do
        [ -e "$f" ] || continue
        [ -d "$f" ] && continue
        case "$f" in *.tmp_manifest) continue ;; esac
        k=$(( $(wc -c < "$f" 2>/dev/null || echo 0) / 1024 ))
        total=$((total + ${k:-0}))
    done
    echo "$total"
}

# Sidecar bytes, tracked separately: they prove the request reached Amazon and
# came back, which is what distinguishes a jammed transfer queue (metadata
# arrives, content never does) from a request that never went anywhere.
dl_side_kb() {   # $1 = asin
    t=0
    for d in "$ITEMS"/*"$1"*.sdr; do
        [ -d "$d" ] || continue
        k=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
        t=$((t + ${k:-0}))
    done
    echo "${t:-0}"
}

# Remove half-finished artifacts so a retry starts from nothing. Without this
# the retry re-reads the same leftover bytes and reports the identical figure,
# which reads as "stalled at the same place" when nothing was ever transferred.
clear_partial() {   # $1 = asin
    dl_done "$1" && return 0          # never touch a finished download
    for f in "$ITEMS"/*"$1"*; do
        [ -e "$f" ] || continue
        case "$f" in
            # In-flight chunks. The book itself arrives as
            # "<n>_<ASIN>.sdr.tmpNN_EBOK" -- not a name any .kfx or .sdr glob
            # matches, which is why an earlier version of this left the stuck
            # bytes exactly where they were.
            *.sdr.tmp*)                    rm -f  "$f" ;;
            *.tmp_manifest)                rm -f  "$f" ;;
            *.kfx|*.azw3|*.azw|*.mobi)     rm -f  "$f" ;;
            *.sdr)                         rm -rf "$f" ;;
        esac
    done
    return 0
}

# A book Amazon has not finished provisioning cannot be downloaded: the request
# is accepted, the manifest comes back, the content transfer starts and dies
# around 56KB. Cover art is the tell -- verified against the whole library, all
# 158 synced books have a thumbnail while none of them are still on the device,
# so thumbnails come from catalogue sync and outlive the book file. Their
# absence means "not ready yet", never "not downloaded yet".
THUMBS=${THUMBS:-/mnt/us/system/thumbnails}
book_ready() {   # $1 = asin
    [ -f "$THUMBS/thumbnail_$1_EBOK_portrait.jpg" ]
}

# How many books we are holding back. Counted outside the candidate pipeline:
# fetch_candidates' stdout IS the book list, so a log line written inside it
# would be read back as an ASIN.
n_notready() {
    [ -f "$NOTREADY" ] || { echo 0; return; }
    _nr_c=0
    while read -r _nr_a _nr_t; do
        case "$_nr_a" in B*) ;; *) continue ;; esac
        book_ready "$_nr_a" && continue
        # Done is done. A book can sync and never get its cover, and it should
        # not be reported as waiting for one.
        synced_known "$_nr_a" && continue
        _nr_c=$((_nr_c + 1))
    done < "$NOTREADY"
    echo "$_nr_c"
}

# Never wait forever on a signal that might not arrive for every book type.
#
# Both waits below default to 0 since 11 Sep 2026. They were built on the idea
# that requesting a book before its cover existed was what jammed the transfer
# queue. Testing disproved that: the jam follows sharing books, covers are a
# symptom, and only a UI framework restart clears it -- which the daemon now
# does by itself when it sees books stuck sidecar-only (WEDGE_TRIGGER). Kept,
# the waits held EVERY new book back for up to 30 minutes, because a book that
# has not downloaded often never gets a cover. Put READY_GRACE / SETTLE_WINDOW
# (seconds) in the config to bring them back if jams return.
NOTREADY=${NOTREADY:-/tmp/kfx-notready.list}
READY_GRACE=${READY_GRACE:-0}
# While the device is still taking delivery of a batch of newly shared books it
# is fragile: cover art and book content share one transfer queue, and adding
# download requests during that window is what wedges it -- after which nothing
# downloads at all and only a UI framework restart clears it. Six books shared
# at once produced exactly that. So during the settling window we ask for
# nothing and simply let the device finish.
SETTLE_WINDOW=${SETTLE_WINDOW:-0}
settling() {
    [ -f "$NOTREADY" ] || return 1
    _st_now=$(date +%s)
    while read -r _st_a _st_t; do
        case "$_st_a" in B*) ;; *) continue ;; esac
        book_ready "$_st_a" && continue
        synced_known "$_st_a" && continue
        [ $((_st_now - ${_st_t:-0})) -lt "$SETTLE_WINDOW" ] && return 0
    done < "$NOTREADY"
    return 1
}
forget_notready() { sed -i "/^$1 /d" "$NOTREADY" 2>/dev/null; }

ready_or_waited() {   # $1 = asin -- true if ready, or if we have waited long enough
    book_ready "$1" && { forget_notready "$1"; return 0; }
    _rw_now=$(date +%s)
    _rw_since=$(awk -v a="$1" '$1==a {print $2; exit}' "$NOTREADY" 2>/dev/null)
    if [ -z "$_rw_since" ]; then
        printf '%s %s\n' "$1" "$_rw_now" >> "$NOTREADY"
        return 1
    fi
    [ $((_rw_now - _rw_since)) -ge "$READY_GRACE" ]
}

dl_target_kb() {   # expected size, from the manifest the device already fetched
    m="$ITEMS/$1.tmp_manifest"
    [ -f "$m" ] || { echo 0; return; }
    grep -o '"size":[0-9]*' "$m" 2>/dev/null | cut -d: -f2 \
      | awk '{s+=$1} END {print int(s/1024)}'
}

# Watch until every requested book has landed, or we run out of patience.
# Returns 0 all done, 1 timed out, 2 user pressed enter.
# ---------------- stuck-download recovery ----------------
# A jammed transfer queue used to mean rebooting the device, which defeats the
# point of an unattended pipeline. The symptom is specific and detectable: the
# manifest and the tiny PHL sidecar arrive within seconds, then the content
# never does and the byte count stops moving.
#
# The recovery uses the library UI's own cancel, kppDownloadCancelAction on
# com.lab126.readnow -- the same action and payload shape as the download itself,
# so it is a mechanism the device already performs rather than something novel.
# Cancel, settle, re-request. One retry, then report and move on rather than
# hammering a queue that is already unhappy.
# Two different failures, two different waits.
#
# A download that moved and then stopped may genuinely recover from a clean
# retry, so it gets one -- but 150s was far longer than needed to be sure.
STALL_AFTER=${STALL_AFTER:-60}
# No retry ladder before calling it a jam: a download frozen at the same byte
# count for a minute is the jam, and a retry against a jammed queue was
# measured doing nothing. The UI restart is what fixes it.
STALL_RETRIES=${STALL_RETRIES:-0}
# A download where NO book bytes ever arrive -- only the ~8KB sidecar -- is the
# wedged-queue signature, and a retry against a wedged queue was measured doing
# nothing at all. There is no point spending the full stall window on it, and
# no point retrying: declare it and let the monitor act.
NODATA_AFTER=${NODATA_AFTER:-60}

cancel_download() {   # $1 = asin
    printf '{ kppItems = "%s,EBOK" }' "$1" \
      | lipc-hash-prop com.lab126.readnow kppDownloadCancelAction 2>&1 \
      | grep -o 'kppResponseCode = "[A-Z_]*"' | head -1
}

# Ask tmd to dump its queues into the system log. Purely diagnostic -- it does
# not change anything -- but it puts the queue state next to the stall in the
# log, which is what we lacked when diagnosing this by hand.
dump_transfer_queues() {
    lipc-hash-prop -n com.lab126.transfer dump_queues >/dev/null 2>&1
}

recover_download() {   # $1 = asin -- returns 0 if a retry was issued
    dump_transfer_queues
    rc=$(cancel_download "$1")
    flog "STALLED: cancelling ${rc:+($rc)}"
    flush_log
    sleep 5
    # Start clean. Cancelling alone leaves the sidecar and any partial in place,
    # so the retry inherits the jam it was meant to escape.
    clear_partial "$1"
    flog "CLEARED partial download"
    # Nudge the cloud queue as well: a re-request against a queue that still
    # believes it is working on this book is ignored.
    refresh_cloud 5 >/dev/null 2>&1
    mark_inflight "$1"
    send_batch "$1,EBOK" >/dev/null
    flog "RETRY issued"
    flush_log
    return 0
}

# A book that has been declared stuck must not come straight back round. The
# not-ready list cannot do this job: ready_or_waited() short-circuits to true as
# soon as a cover exists, and a wedged queue stalls books that have covers -- so
# a stuck book with a cover would be retried every REQ_COOLDOWN (20 min) all
# night, burning ~5 minutes of stalling each time for a queue that cannot
# recover without a framework restart. Hence a separate list, and a doubling
# delay so repeated failure costs less and less.
STUCKLIST=${STUCKLIST:-/tmp/kfx-stuckwait.list}
STUCK_BACKOFF=${STUCK_BACKOFF:-1800}
STUCK_BACKOFF_MAX=${STUCK_BACKOFF_MAX:-21600}

# The precise signature of a wedged transfer queue: the sidecar lands, the book
# never does. One book like this could be a bad book; several in a row is the
# queue, and only a UI framework restart clears that.
WEDGEFILE=${WEDGEFILE:-/tmp/kfx-wedge.list}
# A jam sign carries the book it happened to, so the daemon can stop restarting
# the UI for a book that two restarts have not helped.
note_wedge_sign() { printf '%s %s\n' "$(date +%s)" "${1:-?}" >> "$WEDGEFILE"; }

# How many UI restarts this book has already caused. Kept on /var/local: the
# restart tears down the UI (and /tmp survives, but a reboot does not).
# How many UI restarts this book has already cost. Two, then it is left alone:
# a book that genuinely cannot be downloaded must not restart the UI forever.
# It is a field on the book's record, so it cannot outlive the book.
recover_count() { _rc_n=$(st_get "$1" restarts 2>/dev/null)
    case "$_rc_n" in ''|*[!0-9]*) echo 0 ;; *) echo "$_rc_n" ;; esac
}
note_recover() { st_bump "$1" restarts; }
clear_recover_count() { st_set "$1" restarts=0; }

back_off() {   # $1 = asin
    _bo_n=$(awk -v a="$1" '$1==a {print $3; exit}' "$STUCKLIST" 2>/dev/null)
    _bo_n=$(( ${_bo_n:-0} + 1 ))
    sed -i "/^$1 /d" "$STUCKLIST" 2>/dev/null
    printf '%s %s %s\n' "$1" "$(date +%s)" "$_bo_n" >> "$STUCKLIST"
    # keep the readiness clock honest too
    sed -i "/^$1 /d" "$NOTREADY" 2>/dev/null
    printf '%s %s\n' "$1" "$(date +%s)" >> "$NOTREADY"
}

backed_off() {   # $1 = asin -- true while this book is still serving its wait
    [ -f "$STUCKLIST" ] || return 1
    _bk_now=$(date +%s)
    while read -r _bk_a _bk_ts _bk_n; do
        [ "$_bk_a" = "$1" ] || continue
        _bk_wait=$STUCK_BACKOFF
        _bk_i=1
        while [ "$_bk_i" -lt "${_bk_n:-1}" ] && [ "$_bk_wait" -lt "$STUCK_BACKOFF_MAX" ]; do
            _bk_wait=$((_bk_wait * 2)); _bk_i=$((_bk_i + 1))
        done
        [ "$_bk_wait" -gt "$STUCK_BACKOFF_MAX" ] && _bk_wait=$STUCK_BACKOFF_MAX
        [ $((_bk_now - ${_bk_ts:-0})) -lt "$_bk_wait" ] && return 0
        return 1
    done < "$STUCKLIST"
    return 1
}

clear_backoff() { sed -i "/^$1 /d" "$STUCKLIST" 2>/dev/null; }

report_stuck() {   # $1 = asin, $2 = why
    [ "$BACKEND" = cwa ] && return 0   # stays in the local log
    curl -sS -o /dev/null --max-time 20 -X POST \
        -H 'Content-Type: text/plain' \
        --data-binary "$1	$(title_of "$1")	$2" \
        "$RECEIVER/stuck" 2>/dev/null </dev/null
}

# Watch ONE book to completion, printing a stamped progress line each poll.
# 0 = landed, 1 = gave up, 2 = user pressed enter.
# Interruptible sleep. Returns 0 if the user pressed [enter] during it.
# Every wait the user might sit through goes through this, never bare `sleep`.
# Interruptible only when someone is watching. The daemon has no terminal, so
# there it is simply a sleep -- which keeps the download cadence identical
# whether a pass is run by the daemon or from the menu.
stop_wait() {
    if [ "${INTERACTIVE:-0}" = 1 ]; then
        read -t "$1" _sw 2>/dev/null
    else
        sleep "$1"; return 1
    fi
}

wait_for_download() {   # $1 = asin
    a=$1
    deadline=$(( $(date +%s) + DL_TIMEOUT ))
    last_kb=-1; still=0; retries=0; polls=0; nodata=0
    while :; do
        dl_done "$a" && { flog "DOWNLOAD COMPLETE"; clear_recover_count "$a"; return 0; }
        kb=$(dl_kb "$a"); tgt=$(dl_target_kb "$a")
        if [ "${kb:-0}" -eq 0 ]; then
            # Distinguish the two silences. Sidecar present but no content is
            # the jammed-queue signature; nothing at all means the request has
            # not been answered yet.
            side=$(dl_side_kb "$a")
            if [ "${side:-0}" -gt 0 ]; then
                flog "WAITING: ${side}KB sidecar, no book yet"
            else
                flog "WAITING: nothing received yet"
            fi
        elif [ "${tgt:-0}" -gt 0 ]; then
            flog "$((kb * 100 / tgt))% ${kb}/${tgt}KB"
        else
            flog "${kb}KB"
        fi
        # Push to the receiver as we go. Buffering until the end of the pass
        # left the server blind for the whole download -- exactly the stretch
        # worth watching, and unreadable after the fact if the device reboots.
        polls=$((polls + 1))
        [ $((polls % 3)) -eq 0 ] && flush_log

        # No book data at all -- only the sidecar, or nothing whatsoever: the
        # queue is wedged, and the ladder cannot fix that. A healthy queue
        # starts delivering within seconds, so a full minute of zero book bytes
        # is the jam either way (it used to count only with a sidecar, so a
        # request that got nothing at all was never treated as one). Say so
        # early instead of burning the stall window and a pointless retry.
        if [ "${kb:-0}" -eq 0 ]; then
            nodata=$((nodata + DL_POLL))
            if [ "$nodata" -ge "$NODATA_AFTER" ]; then
                flog "STUCK: no book data in ${nodata}s -- queue wedged"
                report_stuck "$a" "sidecar-only-queue-wedged"
                note_wedge_sign "$a"
                clear_partial "$a"
                back_off "$a"
                flush_log
                return 3
            fi
        else
            nodata=0
        fi

        # Stall = the byte count has not moved. Distinct from "slow": a healthy
        # transfer moves within a poll or two even on a bad connection.
        if [ "$kb" = "$last_kb" ]; then
            still=$((still + DL_POLL))
        else
            still=0; last_kb=$kb
        fi
        if [ "$still" -ge "$STALL_AFTER" ]; then
            if [ "$retries" -lt "$STALL_RETRIES" ]; then
                retries=$((retries + 1))
                recover_download "$a"
                still=0; last_kb=-1
                deadline=$(( $(date +%s) + DL_TIMEOUT ))
            else
                # Distinguish "this book will not come" from "nothing will".
                # Frozen at the same byte count is the jam too, not just a
                # book that never started: both mean the queue, not the book.
                if [ "$(dl_kb "$a")" = "0" ]; then
                    flog "STUCK: no book data in ${still}s -- queue wedged"
                    report_stuck "$a" "sidecar-only-queue-wedged"
                else
                    flog "STUCK: frozen at ${last_kb}KB for ${still}s -- queue wedged"
                    report_stuck "$a" "frozen-queue-wedged"
                fi
                note_wedge_sign "$a"
                clear_partial "$a"      # a stranded partial is what blocks the queue
                back_off "$a"
                return 3
            fi
        fi

        [ "$(date +%s)" -ge "$deadline" ] && {
            flog "DOWNLOAD TIMED OUT"
            report_stuck "$a" "timeout"
            return 1
        }
        stop_wait "$DL_POLL" && return 2
    done
}

# Decrypt and upload a single book, reporting each step on its own line.
# Mobipocket encryption type of a MOBI/AZW3 file: record 0's offset is the
# big-endian word at byte 78, and the type is the 16-bit value 12 bytes into
# record 0. 0 = no DRM, 2 = DRM. Empty if the file cannot be read.
mobi_enc() {
    _me_f=$1      # set -- replaces $1, so keep the name
    set -- $(od -An -tu1 -j78 -N4 "$_me_f" 2>/dev/null)
    [ $# -eq 4 ] || return 0
    _me_o=$(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
    set -- $(od -An -tu1 -j$((_me_o + 12)) -N2 "$_me_f" 2>/dev/null)
    [ $# -eq 2 ] && echo $(( ($1 << 8) + $2 ))
}

# Amazon still delivers some older titles as AZW3 (Mobipocket DRM) instead of
# KFX. The Kindle's own kfxdedrm tool carries a MobiDeDrm port and unlocks them
# with this Kindle's key -- proven on "The Adversary", 11 Sep 2026: flag 2 -> 0,
# and calibre with NO plugins converted the result to a readable 90,000-word
# EPUB. So the book is decrypted here and Calibre receives a plain file.
#
# If the tool ever fails on a book, the original is sent instead: CWA's DeDRM
# plugin holds this Kindle's serial and unlocks it on import. The log says which.
#
# Capped: if Calibre never confirms it, the sweep would otherwise send it again
# every few minutes once the grace period ran out. After MAX_RETRIES sends it
# is left alone and says why.
send_azw3() {   # $1 = asin, $2 = .azw3 path
    _az_k=$(key_of "$2")
    _az_n=$(st_get "$_az_k" tries 2>/dev/null)
    case "$_az_n" in ''|*[!0-9]*) _az_n=0 ;; esac
    if [ "${_az_n:-0}" -ge "$MAX_RETRIES" ]; then
        flog "NOT SENT: sent ${_az_n} times, Calibre never confirmed it"
        return 1
    fi
    _az_w="$CWA_WORK/azw.$$"; rm -rf "$_az_w"; mkdir -p "$_az_w"
    _az_send=$2
    "$RUNNER" dedrm "$2" "$_az_w" >/dev/null 2>&1 </dev/null
    _az_d="$_az_w/$(basename "$2")"
    if [ -f "$_az_d" ] && [ "$(mobi_enc "$_az_d")" = 0 ]; then
        _az_send=$_az_d
        flog "AZW3: decrypted on this Kindle"
    else
        flog "AZW3: could not decrypt here -- sending as it is (Calibre unlocks it)"
    fi
    QUIET_UP=1
    if upload_one "$_az_send"; then
        P_UP=$((P_UP + 1)); flog "SENT TO $DEST_UC: Success"
    else
        P_FAIL=$((P_FAIL + 1)); flog "SENT TO $DEST_UC: FAILED"
    fi
    QUIET_UP=0
    rm -rf "$_az_w"
    return 0
}

handle_one_book() {   # $1 = asin
    a=$1
    # Once per book per pass. Three paths reach here -- the candidate loop,
    # collect_inflight and the sweep -- and each used to run the whole thing
    # again: two books that would not decrypt logged 191 failures that way.
    case " $PASS_DONE " in *" $a "*) return 0 ;; esac
    PASS_DONE="$PASS_DONE $a"
    # Already on the server -> nothing to do. Checked before the file lookup
    # because purge removes the .kfx-zip too, so the later dec_known test
    # (which requires that zip) misses and we would decrypt the whole book
    # only to discard it at the upload step.
    if synced_known "$a"; then
        forget_notready "$a"
        clear_backoff "$a"
        flog "ALREADY SYNCED: skipping"
        return 0
    fi
    book=$(ls "$ITEMS"/*"_$a".kfx 2>/dev/null | head -1)
    if [ -z "$book" ] && [ "$BACKEND" = cwa ]; then
        _hb_azw=$(ls "$ITEMS"/*"_$a".azw3 2>/dev/null | head -1)
        [ -n "$_hb_azw" ] && { send_azw3 "$a" "$_hb_azw"; return $?; }
    fi
    if [ -z "$book" ]; then
        flog "DECRYPTION: no file on device"
        return 1
    fi
    base=$(basename "$book" .kfx); zip="$OUT/$base.kfx-zip"
    if dec_known "$base" && [ -f "$zip" ]; then
        st_set "$a" stage=decrypted note=-
        flog "DECRYPTION: already done"
    else
        # Keep what the tool said: a bare "FAILED" explains nothing, and this
        # log can only be read by mounting the Kindle over USB.
        [ -f "$RUNNER" ] || flog "DECRYPT TOOL MISSING: $RUNNER"
        "$RUNNER" dedrm "$book" "$OUT" > "$OUT/.dedrm-last.log" 2>&1 </dev/null
        if [ -f "$zip" ]; then
            mark_dec "$base"
            # The record is the only account of this book, so the failure that
            # may precede this is replaced, not annotated.
            st_set "$a" stage=decrypted note=- "title=$(title_of "$a")"
            P_DEC=$((P_DEC + 1)); flog "DECRYPTION: Success"
        else
            P_FAIL=$((P_FAIL + 1))
            flog "DECRYPTION: FAILED"
            _hb_why=$(grep -a -i -E "error|fail|cannot|unable|no key|voucher|unsupported|not.*mobi|topaz" \
                        "$OUT/.dedrm-last.log" 2>/dev/null | tail -1 | cut -c1-64)
            [ -n "$_hb_why" ] && flog "REASON: $_hb_why"
            st_set "$a" stage=failed "note=${_hb_why:-no reason given}" \
                   "title=$(title_of "$a")"
            cp "$OUT/.dedrm-last.log" "$OUT/.dedrm-failed-$base.log" 2>/dev/null
            return 1
        fi
    fi
    if [ "$BACKEND" = cwa ]; then
        # Hold the book until every piece is in the archive: CWA rejects an
        # incomplete one, and a book sent twice becomes two library entries.
        if ! cwa_complete "$zip" "$a"; then
            flog "WAITING FOR PART: $CWA_LAST"
            cwa_hold "$a"
            return 1
        fi
        case "$CWA_LAST" in added*) flog "PARTS: $CWA_LAST" ;; esac
        cwa_unhold "$a"
    else
        ensure_containers "$a" "$zip"
    fi
    if up_known "$zip"; then
        flog "SENT TO $DEST_UC: already sent"
    else
        QUIET_UP=1
        if upload_one "$zip"; then
            st_set "$a" stage=uploaded note=-
            P_UP=$((P_UP + 1)); flog "SENT TO $DEST_UC: Success"
        else
            st_set "$a" stage=failed "note=upload: ${CWA_LAST:-failed}"
            P_FAIL=$((P_FAIL + 1)); flog "SENT TO $DEST_UC: FAILED"
        fi
        QUIET_UP=0
    fi
    return 0
}

# ---------------- fast watch ----------------
# Attended mode: poll every minute instead of waiting for the half-hourly cron.
# Exits on any [enter] -- the same read -t trick the main loop uses, so the key
# is read while we would otherwise be sleeping, and stopping is instant.
FAST_INTERVAL=${FAST_INTERVAL:-60}
FAST_WAIT=${FAST_WAIT:-10}
# A book takes minutes, not seconds. The old 30s settle made every pass
# report decrypted=0 and then re-request the same books.
# Nothing legitimate takes this long at the sizes we see (a 2.5MB book lands
# in ~10s); past this it is stuck in a way the ladder has not caught.
DL_TIMEOUT=${DL_TIMEOUT:-300}
DL_POLL=${DL_POLL:-10}

# Books requested by a cron-driven pass (auto_fetch) download in the background
# and were then stranded: fast watch only decrypted what IT had requested, so a
# book fetched by the */10 pass sat on disk untouched while every cycle reported
# "NOTHING NEW (n still in flight)". Collect anything in flight that has landed.
# Books the receiver uploaded but never saw arrive in Calibre. They fall
# between the device's two rules -- it fetches what is "not synced" and purges
# what is "confirmed" -- so without this they sit unnoticed forever. The server
# decides what to resend and how often; the device just does as it is asked.
fetch_resend() {
    code=$(curl -sS -o /tmp/kfx-resend.$$ -w '%{http_code}' --max-time 30 \
             "$RECEIVER/resend" 2>/dev/null </dev/null)
    if [ "$code" = "200" ]; then
        cat /tmp/kfx-resend.$$ 2>/dev/null
    fi
    rm -f /tmp/kfx-resend.$$
}

# Send one book again, from whatever stage of it still exists here.
resend_one() {   # $1 = asin
    _rs=$1
    _rs_zip=$(ls "$OUT"/*"_$_rs".kfx-zip 2>/dev/null | head -1)
    if [ -z "$_rs_zip" ]; then
        _rs_kfx=$(ls "$ITEMS"/*"_$_rs".kfx 2>/dev/null | head -1)
        if [ -n "$_rs_kfx" ]; then
            "$RUNNER" dedrm "$_rs_kfx" "$OUT" >/dev/null 2>&1 </dev/null
            _rs_zip=$(ls "$OUT"/*"_$_rs".kfx-zip 2>/dev/null | head -1)
        fi
    fi
    flog "RESEND $_rs"
    finfo "NAME: $(short "$(title_of "$_rs")" "${NW:-44}")"
    if [ -z "$_rs_zip" ]; then
        # Nothing left locally: ask for it again and let the normal path run.
        flog "RESEND: no local copy, re-requesting"
        mark_inflight "$_rs"
        send_batch "$_rs,EBOK" >/dev/null
        return 0
    fi
    # The archive we already hold may be why the book never made it, so
    # complete it before sending the same bytes a second time.
    ensure_containers "$_rs" "$_rs_zip"
    FORCE_UP=1; QUIET_UP=1
    if upload_one "$_rs_zip"; then
        flog "SENT TO RECEIVER: Success"
    else
        flog "SENT TO RECEIVER: FAILED"
    fi
    FORCE_UP=0; QUIET_UP=0
    return 0
}

# Reconcile what is on this Kindle against what Calibre actually has.
#
# The receiver's /synced is now derived from Calibre, not from our own record
# of uploads: a book that uploaded but never appeared in the library falls out
# of it on its own. So anything still sitting here that is NOT in that list has
# to be fetched again -- its local copy is what Calibre already refused.
#
# This replaces the resend/rebuild queues for that case. No queue to go stale,
# and it self-corrects however the book got into that state.
reconcile_local() {
    [ -s "$SYNCED_CACHE" ] || return 0      # no trustworthy view; do nothing
    for _rc_f in "$ITEMS"/*.kfx; do
        [ -e "$_rc_f" ] || continue
        _rc_a=$(asin_of "$_rc_f")
        [ -n "$_rc_a" ] || continue
        synced_known "$_rc_a" && continue
        # Held for a missing piece: give it the same window an upload gets
        # before starting over with a fresh download.
        [ "$BACKEND" = cwa ] && cwa_held_recent "$_rc_a" && continue
        # Present locally, absent from Calibre: the copy we made is no good.
        flog "RECONCILE $_rc_a"
        finfo "NAME: $(short "$(title_of "$_rc_a")" "${NW:-44}")"
        finfo "not in Calibre -- discarding and fetching again"
        rm -f "$OUT"/*"_$_rc_a".kfx-zip 2>/dev/null
        clear_partial_force "$_rc_a"
        sed -i "/^$_rc_a /d" "$INFLIGHT" 2>/dev/null
        clear_backoff "$_rc_a"
        forget_notready "$_rc_a"
    done
    return 0
}

# clear_partial refuses to touch a completed download, which is exactly the
# case here -- the download completed, it is the artifact Calibre rejected.
clear_partial_force() {   # $1 = asin
    for f in "$ITEMS"/*"$1"*; do
        [ -e "$f" ] || continue
        case "$f" in
            *.sdr.tmp*|*.tmp_manifest)     rm -f  "$f" ;;
            *.kfx|*.azw3|*.azw|*.mobi)     rm -f  "$f" ;;
            *.sdr)                         rm -rf "$f" ;;
        esac
    done
    return 0
}

do_resends() {
    [ "$BACKEND" = cwa ] && return 0   # reconcile_local fetches again instead
    fetch_resend > /tmp/kfx-rs.$$ 2>/dev/null
    while read -r _dr; do
        case "$_dr" in B*) ;; *) continue ;; esac
        resend_one "$_dr"
    done < /tmp/kfx-rs.$$
    rm -f /tmp/kfx-rs.$$
}

collect_inflight() {
    [ -s "$INFLIGHT" ] || return 0
    while read -r _ci_asin _ci_ts; do
        case "$_ci_asin" in B*) ;; *) continue ;; esac
        dl_done "$_ci_asin" || continue
        # Already on the server: just drop it from the in-flight list. Saying
        # COLLECTING and then ALREADY SYNCED in the next breath is noise.
        if synced_known "$_ci_asin"; then
            sed -i "/^$_ci_asin /d" "$INFLIGHT" 2>/dev/null
            forget_notready "$_ci_asin"
            continue
        fi
        flog "COLLECTING $_ci_asin"
        finfo "NAME: $(short "$(title_of "$_ci_asin")" "${NW:-44}")"
        handle_one_book "$_ci_asin"
        sed -i "/^$_ci_asin /d" "$INFLIGHT" 2>/dev/null
    done < "$INFLIGHT"
    return 0
}

# One synchronisation cycle -- the only place the work is defined. The daemon
# runs this on a timer and the menu's Sync runs it once, so the log reads the
# same either way rather than two formats drifting apart.
# Not every step is worth doing every tick. The loop runs often so a newly
# shared book is noticed quickly and the panel stays fresh, but purging 166
# confirmed books takes ~14s and poking Amazon's cloud every 30s is both slow
# and rude. The daemon sets these; a manual Sync leaves them at 1 and does
# everything.
sync_once() {
    DO_CLOUD=${DO_CLOUD:-1}
    DO_RESEND=${DO_RESEND:-1}
    DO_PURGE=${DO_PURGE:-1}
    DO_SWEEP=${DO_SWEEP:-1}
    P_DEC=0; P_UP=0; P_FAIL=0
    PASS_DONE=
    NW=$((W - 11))                 # width left after the "     NAME: " label
    stopped=0

    if ! fetch_synced; then
        flog "$DEST_UC UNREACHABLE -- skipping"
        flush_log
        return 1
    fi

    collect_inflight
    [ "$DO_RESEND" = 1 ] && { reconcile_local; do_resends; }
    flush_log
    if [ "$DO_PURGE" = 1 ]; then
        purge_synced
        flush_log
    fi

    [ "$DO_CLOUD" = 1 ] && refresh_cloud "$FAST_WAIT"
    tmp=/tmp/kfx-sync.$$
    if settling; then
        # Deliberately request nothing: the device is still pulling covers and
        # item records for a batch that just landed, and adding load there is
        # what wedges the transfer queue.
        : > "$tmp"
    else
        fetch_candidates | head -"$MAX_FETCH_PER_PASS" > "$tmp" 2>/dev/null
    fi
    n=$(wc -l < "$tmp" | tr -d ' ')

    if [ "${n:-0}" -gt 0 ]; then
        flog "FOUND $n NEW BOOK(S)"
        b=0
        # fd 3, not stdin: wait_for_download reads the terminal for the stop
        # key, and with stdin bound here it would eat the remaining book lines.
        while read -r a <&3; do
            [ -n "$a" ] || continue
            b=$((b + 1))
            flog "GETTING BOOK $b OF $n"
            finfo "NAME: $(short "$(title_of "$a")" "$NW")"
            finfo "ASIN: $a"

            mark_inflight "$a"
            send_batch "$a,EBOK" >/dev/null

            # The manifest arrives first and carries the size; wait briefly so
            # SIZE is real rather than a guess.
            t=0; tgt=0
            while [ "$t" -lt 20 ]; do
                tgt=$(dl_target_kb "$a")
                [ "${tgt:-0}" -gt 0 ] && break
                dl_done "$a" && break          # already here; stop waiting
                stop_wait 2 && { stopped=1; break; }
                t=$((t + 2))
            done
            [ "$stopped" = 1 ] && break
            # No size means the book arrived before the manifest could be read
            # -- a fast download, not a missing one.
            [ "${tgt:-0}" -gt 0 ] && finfo "SIZE: ${tgt}KB"

            wait_for_download "$a"; wd=$?
            if [ "$wd" = 2 ]; then stopped=1; break; fi
            [ "$wd" = 0 ] && handle_one_book "$a"
        done 3< "$tmp"
        rm -f "$tmp"
    else
        rm -f "$tmp"
        pend=$(n_missing)
        nr=$(n_notready)
        if settling; then
            flog "SETTLING: $nr book(s) arriving"
        elif [ "${nr:-0}" -gt 0 ]; then
            flog "WAITING: $nr book(s) have no cover yet"
        elif [ "${pend:-0}" -gt 0 ]; then
            flog "NOTHING NEW ($pend still in flight)"
        else
            flog "NOTHING NEW"
        fi
    fi

    # Anything on disk that was downloaded but never decrypted or uploaded --
    # a pass interrupted mid-book, say. A filesystem walk, so not every tick.
    if [ "$DO_SWEEP" = 1 ]; then
        if [ "$BACKEND" = cwa ]; then
            find "$DOCS" \( -name '*.kfx' -o -name '*.azw3' \) 2>/dev/null
        else
            find "$DOCS" -name '*.kfx' 2>/dev/null
        fi | grep -v '\.sdr/' | sort > /tmp/kfx-local.$$
        while read -r _sw_book; do
            _sw_base=$(basename "$_sw_book"); _sw_base=${_sw_base%.kfx}; _sw_base=${_sw_base%.azw3}
            dec_known "$_sw_base" && continue
            _sw_a=$(asin_of "$_sw_base")
            [ -n "$_sw_a" ] || continue
            [ "$(fails "$_sw_base")" -ge "$MAX_RETRIES" ] && continue
            flog "COLLECTING $_sw_a"
            finfo "NAME: $(short "$(title_of "$_sw_a")" "$NW")"
            handle_one_book "$_sw_a"
        done < /tmp/kfx-local.$$
        rm -f /tmp/kfx-local.$$
    fi

    flog "SYNC COMPLETE"
    finfo "decrypted=$P_DEC uploaded=$P_UP failed=$P_FAIL"
    flush_log
    note_sync_done
    [ "$stopped" = 1 ] && return 2
    return 0
}

list_wanted() {
    clear 2>/dev/null
    rule; printf ' books you have asked for\n'; rule; echo
    if [ ! -r "$WANTED" ]; then
        echo "  No wanted-list yet. Create:"
        echo "    $WANTED"
        echo
        echo "  One ASIN per line, e.g. B0BGDM197Q"
        echo "  Get them from Amazon's Manage Your Content page."
        echo
        echo "  This device's catalogue only lists books already"
        echo "  here, so it cannot enumerate your cloud library."
    else
        w=$(n_wanted); pend=$(n_missing)
        printf '  %s listed, %s still not on this device.\n\n' "$w" "$pend"
        pending_list | head -25 | sed 's/^/  /'
    fi
    echo; rule
    printf ' [enter] back > '
    read _x 2>/dev/null
}

# Only one thing may drive downloads at a time. The daemon runs unattended and
# the menu is still usable, so without this a manual fast watch and a daemon
# pass would request the same books at once -- which is exactly the pile-up
# that wedges the device.
RUNLOCK=${RUNLOCK:-/tmp/kfx-run.lock}
take_lock() {   # $1 = who
    if [ -f "$RUNLOCK" ]; then
        _tl_pid=$(cut -d' ' -f1 "$RUNLOCK" 2>/dev/null)
        # A dead holder leaves a stale lock; do not let it block forever.
        if [ -n "$_tl_pid" ] && [ -d "/proc/$_tl_pid" ]; then
            return 1
        fi
    fi
    printf '%s %s\n' "$$" "${1:-?}" > "$RUNLOCK"
    return 0
}
drop_lock() {
    [ -f "$RUNLOCK" ] || return 0
    [ "$(cut -d' ' -f1 "$RUNLOCK" 2>/dev/null)" = "$$" ] && rm -f "$RUNLOCK"
    return 0
}
lock_holder() { cut -d' ' -f2 "$RUNLOCK" 2>/dev/null; }

# Frontlight, dimmed while nothing is happening. The screen itself is e-ink and
# costs nothing to leave showing; the light is the part that drains the battery
# on a device sitting on a desk syncing all day.
#
# The brightness is read at the moment we dim, not once at startup, so changing
# it while the script runs is picked up rather than overwritten.
FL_SAVED=""
# Seconds of no keypress before the light goes off. 0 = never.
LIGHT_CHOICES="30 60 120 300 0"
light_idle() {
    _lv=$(state_get LIGHT_IDLE)
    case "$_lv" in ''|*[!0-9]*) echo 60 ;; *) echo "$_lv" ;; esac
}
light_idle_text() {
    case "$(light_idle)" in
        0)   echo "never" ;;
        30)  echo "30s" ;;  60) echo "60s" ;;
        120) echo "2 min" ;; 300) echo "5 min" ;;
        *)   echo "$(light_idle)s" ;;
    esac
}
# Step to the next value -- one keypress per change suits an e-ink keyboard
# better than typing a number.
light_idle_next() {
    _cur=$(light_idle); _first=""; _take=0
    for _v in $LIGHT_CHOICES; do
        [ -n "$_first" ] || _first=$_v
        if [ "$_take" = 1 ]; then state_set LIGHT_IDLE "$_v"; return; fi
        [ "$_v" = "$_cur" ] && _take=1
    done
    state_set LIGHT_IDLE "$_first"
}
light_off() {
    _fl=$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null)
    case "$_fl" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_fl" -gt 0 ] || return 0          # already off; leave it alone
    FL_SAVED=$_fl
    lipc-set-prop com.lab126.powerd flIntensity 0 >/dev/null 2>&1
}
light_restore() {
    case "$FL_SAVED" in ''|*[!0-9]*) return 0 ;; esac
    [ "$FL_SAVED" -gt 0 ] || return 0
    lipc-set-prop com.lab126.powerd flIntensity "$FL_SAVED" >/dev/null 2>&1
    FL_SAVED=""
}

awake_on()  { lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1; }
awake_off() { lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1; }
# Leave the background helper alone: if the monitor is on it keeps syncing.
close_only() {
    clear 2>/dev/null
    light_restore
    flush_log; rm -f "$SPOOL"; awake_off
    if monitor_on; then
        echo "Closed. Daemon still running, monitor still syncing."
    else
        echo "Closed. Daemon still running, monitor off."
    fi
    exit 0
}

# Stop everything, including the helper that would otherwise keep syncing.
quit_all() {
    clear 2>/dev/null
    # The daemon is the gate: stopping it stops the monitor, so the flag goes
    # off with it. Leaving the flag on meant the next launch started the daemon
    # and silently resumed syncing, which is not what "Quit" means.
    state_set MONITOR off
    note_monitor
    sh "$DAEMON" stop >/dev/null 2>&1
    light_restore
    flush_log; rm -f "$SPOOL"; awake_off
    echo "Daemon and monitor stopped."
    exit 0
}

cleanup() { light_restore; flush_log; rm -f "$SPOOL"; awake_off
            clear 2>/dev/null; echo "KFX Sync stopped."; exit 0; }
trap cleanup INT TERM HUP

# Remote run/stop, which only the receiver ever offered (/control). Nothing
# pokes this Kindle directly any more: the port-8087 listener went with
# poke-kindle, the server job that was its only caller.
# A command channel that works over FTP. The file sits under /mnt/us, which is
# the only thing this device can serve, so writing one word into it from a
# laptop is enough to ask the Kindle for a sync with no cable and no server in
# between.
#
# Read once and deleted, so a command cannot repeat forever if the daemon
# restarts. The vocabulary is deliberately small -- sync, stop syncing, clear a
# jam, close the way in -- and anything else is dropped rather than guessed at.
# Nothing here reboots or reformats: whoever can write this file is whoever can
# reach the FTP port, and that is not a reason to trust them with more.
CMDFILE=${CMDFILE:-/mnt/us/extensions/kfx-sync/command}
poll_cmd() {
    if [ "$BACKEND" = cwa ]; then
        [ -s "$CMDFILE" ] || return 0
        _pc_c=$(head -1 "$CMDFILE" 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z')
        rm -f "$CMDFILE" 2>/dev/null
        case "$_pc_c" in
            run|stop|restart-ui|update|remote-on|remote-off) echo "$_pc_c" ;;
        esac
        return 0
    fi
    case "$(curl -sS --max-time 8 "$RECEIVER/control" 2>/dev/null)" in run) echo run ;; stop) echo stop ;; esac
}

# ---------------- work ----------------
STEP=0
# Fast watch writes a structured, timestamped log: a stamped event line, and
# indented detail lines under it. Screen, on-device log and the spool forwarded
# to the receiver all get the same text, so what you read on the Kindle is what
# the host sees.
# The screen wraps silently at $W, which turns one long line into two and
# desyncs the whole display. Clip here, once, so no caller has to count
# characters and no future message can reintroduce the wrap. The receiver's
# copy keeps the full text -- only the on-device view is clipped.
#
# busybox printf is not the printf tested on the desktop, so ask it rather than
# assume: %.*s if it honours it, otherwise cut (a process per line, but only on
# a device that needs it).
if [ "$(printf '%.*s' 3 abcdef 2>/dev/null)" = "abc" ]; then
    clip() { printf '%.*s\n' "$W" "$1"; }
else
    clip() { printf '%s\n' "$1" | cut -c"1-$W"; }
fi

flog() {
    stamp="[$(date '+%m%d%Y %H:%M:%S')] "
    line="$stamp$1"
    clip "$line"
    printf '%s\n' "$line" >> "$LOG"
    printf '%s\n' "$line" >> "$SPOOL"
}
finfo() {
    line="     $1"
    clip "$line"
    printf '%s\n' "$line" >> "$LOG"
    printf '%s\n' "$line" >> "$SPOOL"
}

progress() {   # progress TAG name  -- paginates instead of scrolling
    STEP=$((STEP + 1))
    # Inline mode never clears: the log is the point.
    if [ "${PASS_INLINE:-0}" != 1 ] && [ $((STEP % PAGE)) -eq 1 ] && [ "$STEP" -gt 1 ]; then
        flush_log; sleep 1; clear 2>/dev/null
        rule; printf ' working... (%s done this pass)\n' "$((STEP - 1))"; rule; echo
    fi
    emit "$(printf '%-*s %s' "$TAGW" "$1" "$(short "$2" $((W - TAGW - 2)))")"
}

upload_container() {   # $1 = container file, $2 = asin
    _uc_n=$(basename "$1")
    _uc_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 300 \
                 -H "X-Token: $TOKEN" -H "X-Filename: $_uc_n" -H "X-Asin: $2" \
                 -T "$1" "$RECEIVER/attach" 2>/dev/null </dev/null)
    case "$_uc_code" in
        201|200) return 0 ;;
        *) flog "MISSING PART: failed ($_uc_code)"; return 1 ;;
    esac
}

# A KFX book can span several containers, with the extra ones sitting in
# .sdr/assets/attachables. calibre rejects the book outright unless every
# container is in the one archive ("Book is incomplete... Missing containers"),
# and the on-device packager does not always include them. Send whatever the
# archive is missing so the receiver can complete it before CWA sees the file.
#
# ZIP keeps entry names uncompressed, so a plain grep answers "is it already in
# there?" -- no unzip needed, which matters on a device that has none.
# grep skips binary files on some builds and reports "no match" rather than an
# error, so ask this grep what it does instead of trusting it. A false "not in
# the archive" only costs a needless upload -- the receiver's merge is a no-op
# when the container is already there -- but it would cost it on every book.
if printf 'x\000CR!TESTNAME\n' > /tmp/kfx-gt.$$ 2>/dev/null &&
   grep -qaF -- 'CR!TESTNAME' /tmp/kfx-gt.$$ 2>/dev/null; then
    zip_has() { grep -qaF -- "$2" "$1" 2>/dev/null; }
else
    zip_has() { strings "$1" 2>/dev/null | grep -qF -- "$2"; }
fi
rm -f /tmp/kfx-gt.$$

ensure_containers() {   # $1 = asin, $2 = kfx-zip path
    [ -f "$2" ] || return 0
    _ec_sdr=$(ls -d "$ITEMS"/*"_$1".sdr 2>/dev/null | head -1)
    [ -n "$_ec_sdr" ] || return 0
    for _ec_f in "$_ec_sdr"/assets/attachables/*.kfx; do
        [ -e "$_ec_f" ] || continue
        _ec_n=$(basename "$_ec_f")
        zip_has "$2" "$_ec_n" && continue
        # "Container" is Amazon's word for one chunk of a KFX book -- the
        # pictures often live in their own. The screen says what it means to
        # the reader: a piece of the book is missing from what we packed.
        _ec_kb=$(( $(wc -c < "$_ec_f" 2>/dev/null || echo 0) / 1024 ))
        finfo "MISSING PART: ${_ec_kb}KB -- sending"
        upload_container "$_ec_f" "$1"
    done
    return 0
}

upload_one() {
    f=$1; name=$(basename "$f")
    if [ "${FORCE_UP:-0}" != 1 ] && up_known "$f"; then
        return 0
    fi
    if [ "$BACKEND" = cwa ]; then
        if cwa_upload "$f"; then
            _uo_k=$(key_of "$f")
            cwa_record_upload "$_uo_k" "$name"
            printf '%s\n' "$_uo_k" >> "$SYNCED_CACHE"   # done for the rest of this pass too
            [ "${QUIET_UP:-0}" = 1 ] || progress "sent to Calibre" "$name"
            [ "$PURGE_AFTER_UPLOAD" = "1" ] && rm -f "$f"
            return 0
        fi
        [ "${QUIET_UP:-0}" = 1 ] || progress "$CWA_LAST" "$name"
        return 1
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 600 \
             -H "X-Token: $TOKEN" -H "X-Filename: $name" -T "$f" "$RECEIVER/upload" 2>/dev/null </dev/null)
    case "$code" in
        201|200) mark_up "$f"; [ "${QUIET_UP:-0}" = 1 ] || progress "sent to receiver" "$name"
                 [ "$PURGE_AFTER_UPLOAD" = "1" ] && rm -f "$f"
                 return 0 ;;
        000)     [ "${QUIET_UP:-0}" = 1 ] || progress "upload failed" "$name"; return 1 ;;
        *)       [ "${QUIET_UP:-0}" = 1 ] || progress "http $code" "$name"; return 1 ;;
    esac
}

list_pending() {
    ls -1 "$OUT"/*.kfx-zip 2>/dev/null | while read -r f; do
        up_known "$f" || basename "$f"
    done
}

DAEMON=${DAEMON:-/mnt/us/extensions/kfx-sync/kfx-daemon.sh}

# Shared between the daemon and the front end: the menu shows what the daemon
# is doing even though it is a separate process. /var/local survives a reboot.
# One file per key, not one file with all the keys in it.
#
# The single-file version did a read-modify-write through a shared temp name,
# and there are three writers here -- the front end, its background count
# refresher, and the daemon. Two overlapping writes meant one silently threw
# away the other's key: pressing Start Monitor set MONITOR=on and a concurrent
# NEXT_SYNC write from the daemon put it straight back to off. A key per file
# removes the interaction entirely.
STATEDIR=${STATEDIR:-/var/local/kfx-state}
state_get() { cat "$STATEDIR/$1" 2>/dev/null; }
state_set() {
    [ -d "$STATEDIR" ] || mkdir -p "$STATEDIR" 2>/dev/null
    # $$ in the temp name: two processes writing the same key at once must not
    # share a scratch file either.
    if printf '%s' "$2" > "$STATEDIR/.$1.$$" 2>/dev/null; then
        mv "$STATEDIR/.$1.$$" "$STATEDIR/$1" 2>/dev/null
    fi
}
# The panel reads these from the state file so a repaint costs nothing. They
# have to be refreshed by something, though -- and a sync is not that something
# when the monitor is off and no sync ever runs. Hence a standalone refresher,
# called at startup and periodically by the daemon whether or not it is syncing.
refresh_counts() {
    fetch_synced >/dev/null 2>&1
    state_set N_SYNCED   "$(n_dec)"
    state_set N_WANTED   "$(n_wanted)"
    state_set N_MISSING  "$(n_missing)"
    state_set N_PROBLEMS "$(n_problems)"
}

note_sync_done() {
    _nd_c=$(state_get SYNC_COUNT)
    state_set LAST_SYNC "$(date +%s)"
    state_set SYNC_COUNT "$(( ${_nd_c:-0} + 1 ))"
    # Publish the counts the panel wants. Computing them costs a cc.db query
    # and a directory walk, which is why the front end must not do it on every
    # repaint -- and why it used to show "?" until you pressed Refresh.
    refresh_counts
}

# Map any epoch to a local wall clock without `date -d @epoch`, which busybox
# may not support: take the current time of day and shift it by the difference.
fmt_clock() {
    case "$1" in ''|*[!0-9]*) echo "--:--:--"; return ;; esac
    [ "$1" -gt 0 ] || { echo "--:--:--"; return; }
    _fc_now=$(date +%s)
    # Strip leading zeros first: "09" is octal to shell arithmetic, and an
    # hour of 08 or 09 would abort with "value too great for base".
    _fc_hh=$(date +%H); _fc_hh=${_fc_hh#0}; [ -n "$_fc_hh" ] || _fc_hh=0
    _fc_mm=$(date +%M); _fc_mm=${_fc_mm#0}; [ -n "$_fc_mm" ] || _fc_mm=0
    _fc_ss=$(date +%S); _fc_ss=${_fc_ss#0}; [ -n "$_fc_ss" ] || _fc_ss=0
    _fc_sod=$(( _fc_hh * 3600 + _fc_mm * 60 + _fc_ss ))
    _fc_t=$(( (_fc_sod + ($1 - _fc_now)) % 86400 ))
    [ "$_fc_t" -lt 0 ] && _fc_t=$(( _fc_t + 86400 ))
    _fc_h=$(( _fc_t / 3600 )); _fc_m=$(( _fc_t % 3600 / 60 )); _fc_s=$(( _fc_t % 60 ))
    if [ "$_fc_h" -ge 12 ]; then _fc_ap=PM; else _fc_ap=AM; fi
    _fc_h12=$(( _fc_h % 12 )); [ "$_fc_h12" -eq 0 ] && _fc_h12=12
    printf '%02d:%02d:%02d %s' "$_fc_h12" "$_fc_m" "$_fc_s" "$_fc_ap"
}

# date -d @epoch is not reliable on busybox, so work in relative terms.
ago() {
    case "$1" in ''|*[!0-9]*) echo "never"; return ;; esac
    [ "$1" -gt 0 ] || { echo "never"; return; }
    _ag=$(( $(date +%s) - $1 ))
    if   [ "$_ag" -lt 60 ];   then echo "${_ag}s ago"
    elif [ "$_ag" -lt 3600 ]; then echo "$((_ag / 60))m ago"
    else echo "$((_ag / 3600))h ago"; fi
}
countdown() {
    case "$1" in ''|*[!0-9]*) echo "-"; return ;; esac
    _cd=$(( $1 - $(date +%s) ))
    [ "$_cd" -le 0 ] && { echo "due now"; return; }
    if [ "$_cd" -lt 60 ]; then echo "in ${_cd}s"; else echo "in $((_cd / 60))m"; fi
}
daemon_state() {
    [ -x "$DAEMON" ] || { echo "not installed"; return; }
    case "$(sh "$DAEMON" status 2>/dev/null | head -1)" in
        running*) echo "running" ;;
        *)        echo "stopped" ;;
    esac
}

manual_sync() {
    clear 2>/dev/null
    rule; printf ' sync\n'; rule; echo
    if [ "$(daemon_state)" != "running" ]; then
        sh "$DAEMON" ensure >/dev/null 2>&1
        sleep 2
    fi
    if [ "$(daemon_state)" != "running" ]; then
        printf '   The daemon will not start, so a sync cannot run.\n'
        printf '   Sync runs inside it so a stuck-download fix can\n'
        printf '   restart the UI without killing the sync.\n'
        printf '   See Settings for the daemon log.\n'
        echo; printf ' [enter] back > '; read _x 2>/dev/null
        return 1
    fi

    # The daemon does the work, not this screen: a stuck-download fix restarts
    # the UI framework, which would kill this process mid-sync.
    _ms_from=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    : > "$REQFILE_D" 2>/dev/null || { printf '   could not reach the helper\n'; sleep 2; return 1; }

    _ms_wait=0
    while [ "$_ms_wait" -lt 300 ]; do
        _ms_now=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
        if [ "${_ms_now:-0}" -gt "${_ms_from:-0}" ]; then
            _ms_new=$(sed -n "$((_ms_from + 1)),${_ms_now}p" "$LOG" 2>/dev/null)
            printf '%s\n' "$_ms_new"
            _ms_from=$_ms_now
            case "$_ms_new" in *"SYNC COMPLETE"*) break ;; esac
        fi
        sleep 2
        _ms_wait=$((_ms_wait + 2))
    done
    [ "$_ms_wait" -ge 300 ] && printf '\n   (still going -- see Log)\n'
    echo; printf ' [enter] back > '; read _x 2>/dev/null
}

monitor_since() { state_get MONITOR_SINCE; }
REQFILE_D=${REQFILE_D:-/var/local/kfx-daemon.req}
monitor_on() { [ "$(state_get MONITOR)" = "on" ]; }
# What the panel shows: the flag, qualified by whether the daemon that would
# act on it is actually alive.
monitor_text() {
    if monitor_on; then
        if [ "$(daemon_state)" = "running" ]; then
            printf 'Running (%s)' "$(state_get SYNC_COUNT)"
        else
            printf 'on (daemon stopped)'
        fi
    else
        printf 'Stopped'
    fi
}
note_monitor() { state_set MONITOR_SINCE "$(date '+%m%d%Y %H:%M:%S')"; }

# Silent on purpose: the caller redraws, and the panel already says whether the
# monitor is running. A confirmation screen for a toggle is friction with no
# information in it.
# One decision point. The menu label and this both ask monitor_on, so they
# cannot disagree -- which they did: the label read the flag while the action
# read whether the daemon was up, and since the daemon is always up, pressing
# "Start Monitor" ran monitor_stop.
monitor_toggle() {
    if monitor_on; then monitor_stop; else monitor_start; fi
}

monitor_start() {
    sh "$DAEMON" ensure >/dev/null 2>&1
    # The count beside "Running" means syncs since this start, so a freshly
    # started monitor showing (44) would be claiming work it has not done.
    state_set SYNC_COUNT 0
    state_set MONITOR on
    note_monitor
    # Start means start: sync now rather than after the daemon's current idle
    # nap, and show that time immediately. Without this the panel read
    # "next sync --:--:--" until a sync had already finished.
    state_set NEXT_SYNC "$(date +%s)"
    : > "$REQFILE_D" 2>/dev/null
}

monitor_stop() {
    state_set MONITOR off
    note_monitor
}

# The hook is a file we own under /mnt/us; its presence is the whole state.
boot_hook_state() {
    if [ -f /mnt/us/emergency.sh ] && grep -qF 'kfx-sync boot hook' /mnt/us/emergency.sh 2>/dev/null; then
        echo "on"
    elif [ -f /mnt/us/emergency.sh ]; then
        echo "other script present"
    else
        echo "off"
    fi
}

# ---------------- remote access ----------------
# Two FTP servers, because they answer two different needs and carry two very
# different risks.
#
#   logs  READ-ONLY, always on, serving $LOGDIR and nothing else. Enough to
#         see what the device has been doing from a laptop. busybox ftpd is
#         read-only unless given -w, so this is not a policy we enforce -- it
#         is a capability the server does not have.
#
#   dev   READ-WRITE, off by default, serving all of /mnt/us. This is how a
#         test script gets onto the device without a cable, and it is also
#         root access to everything on it: books, cwa.conf with the Calibre
#         password, the lot. Its own port, its own toggle, and it says so.
#
# Neither reaches the network on its own. Measured 12 Sep 2026: this Kindle's
# INPUT chain is policy DROP, accepting only port 40317 (Amazon's own service)
# and RELATED/ESTABLISHED traffic. tcpsvd was listening and answering on
# 127.0.0.1 for a morning while every packet from the LAN was dropped. So a
# port is opened in the firewall when its server starts and closed when it
# stops -- never left open without something behind it.
REMOTE_LOG_PORT=${REMOTE_LOG_PORT:-2121}
REMOTE_DEV_PORT=${REMOTE_DEV_PORT:-2122}
REMOTE_PIDS=${REMOTE_PIDS:-/tmp/kfx-remote.pids}       # the dev server
REMOTE_LOG_PIDS=${REMOTE_LOG_PIDS:-/tmp/kfx-remotelog.pids}
REMOTE_FLAG=${REMOTE_FLAG:-${STATEDIR:-/var/local/kfx-state}/REMOTE_ON}
REMOTE_LOG_OFF=${REMOTE_LOG_OFF:-${STATEDIR:-/var/local/kfx-state}/REMOTE_LOG_OFF}

IPTABLES=${IPTABLES:-iptables}
NETSTAT=${NETSTAT:-netstat}

# "A process is alive" is not "a port is bound" -- a super-server that starts
# and fails to bind stays alive just long enough to look like success. Ask the
# kernel instead.
port_listening() {   # $1 = port
    command -v "$NETSTAT" >/dev/null 2>&1 || return 2   # cannot tell
    "$NETSTAT" -ln 2>/dev/null | grep -q "[:.]$1[^0-9]" && return 0
    return 1
}
pids_alive() {   # $1 = pid file
    [ -s "$1" ] || return 1
    while read -r _pa_p; do kill -0 "$_pa_p" 2>/dev/null && return 0; done < "$1"
    return 1
}
server_up() {   # $1 = port, $2 = pid file
    port_listening "$1"
    case "$?" in 0) return 0 ;; 1) return 1 ;; esac
    pids_alive "$2"
}

fw_open() {   # $1 = port
    command -v "$IPTABLES" >/dev/null 2>&1 || return 1
    fw_close "$1"                                   # never stack duplicates
    "$IPTABLES" -I INPUT 1 -p tcp --dport "$1" -j ACCEPT 2>/dev/null
}
fw_close() {   # $1 = port -- -D removes one rule and fails when none are left
    command -v "$IPTABLES" >/dev/null 2>&1 || return 0
    _fc_n=0
    while [ "$_fc_n" -lt 8 ]; do
        "$IPTABLES" -D INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || break
        _fc_n=$((_fc_n + 1))
    done
    return 0
}
fw_is_open() {   # $1 = port
    command -v "$IPTABLES" >/dev/null 2>&1 || return 2
    "$IPTABLES" -L INPUT -n 2>/dev/null | grep -q "dpt:$1" && return 0
    return 1
}

# busybox ftpd needs a super-server in front of it. tcpsvd is what this device
# has; nc can do it too on builds with -e. Verified by the port, not the pid.
ftp_serve() {   # $1 = port, $2 = pid file, $3.. = ftpd arguments
    _fs_port=$1; _fs_pids=$2; shift 2
    command -v ftpd >/dev/null 2>&1 || { REMOTE_HOW="no ftpd on this device"; return 1; }
    REMOTE_HOW=""
    for _fs_m in tcpsvd nc; do
        command -v "$_fs_m" >/dev/null 2>&1 || continue
        : > "$_fs_pids"
        case "$_fs_m" in
            tcpsvd) setsid tcpsvd -vE 0.0.0.0 "$_fs_port" ftpd "$@" >/dev/null 2>&1 & ;;
            nc)     setsid nc -ll -p "$_fs_port" -e ftpd "$@" >/dev/null 2>&1 & ;;
        esac
        echo $! >> "$_fs_pids"
        sleep 2
        if server_up "$_fs_port" "$_fs_pids"; then
            REMOTE_HOW="$_fs_m"
            fw_open "$_fs_port" || REMOTE_HOW="$_fs_m (could not open the firewall)"
            return 0
        fi
        while read -r _fs_p; do kill "$_fs_p" 2>/dev/null; done < "$_fs_pids" 2>/dev/null
        rm -f "$_fs_pids"
    done
    REMOTE_HOW="nothing could listen on $_fs_port"
    return 1
}

ftp_unserve() {   # $1 = port, $2 = pid file
    [ -s "$2" ] && while read -r _fu_p; do kill "$_fu_p" 2>/dev/null; done < "$2"
    rm -f "$2"
    # Close the hole even if the server was already gone: a crash between
    # starting and stopping must not leave a port open with nothing behind it.
    fw_close "$1"
}

# --- the read-only log server (anonymous HTTP) --------------------------
# ftpd needs a login, so it cannot be anonymous. This serves the logs over HTTP
# through tcpsvd instead: no account, read-only by construction (serve-logs.sh
# only ever reads files from LOGDIR). Open a browser at http://<ip>:<port>/.
LOGSERVER=${LOGSERVER:-$(dirname "$CONF")/serve-logs.sh}
log_ftp_running() { server_up "$REMOTE_LOG_PORT" "$REMOTE_LOG_PIDS"; }
log_ftp_ours()    { pids_alive "$REMOTE_LOG_PIDS"; }
log_ftp_wanted()  { [ ! -f "$REMOTE_LOG_OFF" ]; }
log_ftp_stop() {
    [ -s "$REMOTE_LOG_PIDS" ] && while read -r _lp; do kill "$_lp" 2>/dev/null; done < "$REMOTE_LOG_PIDS"
    rm -f "$REMOTE_LOG_PIDS"
    fw_close "$REMOTE_LOG_PORT"
}
log_ftp_ensure() {
    log_ftp_wanted || { log_ftp_running && log_ftp_stop; return 0; }
    if log_ftp_running; then
        # Already listening: open the firewall if it is not, but only for a
        # server we started. Anything else on this port could be serving
        # something we would not want exposed.
        if log_ftp_ours; then
            fw_is_open "$REMOTE_LOG_PORT"; [ "$?" = 1 ] && fw_open "$REMOTE_LOG_PORT"
        fi
        return 0
    fi
    [ -x "$LOGSERVER" ] || { command -v tcpsvd >/dev/null 2>&1 || return 1; }
    mkdir -p "$LOGDIR" 2>/dev/null
    command -v tcpsvd >/dev/null 2>&1 || return 1
    : > "$REMOTE_LOG_PIDS"
    LOGDIR="$LOGDIR" setsid tcpsvd -vE 0.0.0.0 "$REMOTE_LOG_PORT" sh "$LOGSERVER" >/dev/null 2>&1 &
    echo $! >> "$REMOTE_LOG_PIDS"
    sleep 2
    if server_up "$REMOTE_LOG_PORT" "$REMOTE_LOG_PIDS"; then
        fw_open "$REMOTE_LOG_PORT"
        emit "logs readable at http://$(device_ip):$REMOTE_LOG_PORT/ (anonymous, read-only)"
        return 0
    fi
    while read -r _lp; do kill "$_lp" 2>/dev/null; done < "$REMOTE_LOG_PIDS" 2>/dev/null
    rm -f "$REMOTE_LOG_PIDS"
    return 1
}

# --- the read-write dev server ------------------------------------------
remote_running()  { server_up "$REMOTE_DEV_PORT" "$REMOTE_PIDS"; }
remote_wanted()   { [ -f "$REMOTE_FLAG" ]; }
remote_want_on()  { mkdir -p "$(dirname "$REMOTE_FLAG")" 2>/dev/null; : > "$REMOTE_FLAG"; }
remote_want_off() { rm -f "$REMOTE_FLAG" 2>/dev/null; }
remote_stop()     { ftp_unserve "$REMOTE_DEV_PORT" "$REMOTE_PIDS"; }
remote_start()    { ftp_serve "$REMOTE_DEV_PORT" "$REMOTE_PIDS" -w /mnt/us; }
remote_ours() { pids_alive "$REMOTE_PIDS"; }
remote_ensure() {
    remote_wanted || return 0
    if remote_running; then
        if remote_ours; then
            fw_is_open "$REMOTE_DEV_PORT"; [ "$?" = 1 ] && fw_open "$REMOTE_DEV_PORT"
        fi
        return 0
    fi
    if remote_start; then
        emit "dev access: ftp://$(device_ip):$REMOTE_DEV_PORT/ read-write, via $REMOTE_HOW"
    fi
    return 0
}

# Who is connected, by address, from the kernel's own connection table.
#
# This used to count ftpd processes on the theory that tcpsvd runs one per
# client. It does -- but a stray ftpd left behind by a crashed or killed client
# counts just the same, and the panel then reports a connection that is not
# there. An ESTABLISHED entry is a connection; a process is only evidence of
# one. It also gives us the address, which is the useful part: "someone is
# reading the logs" matters less than which machine it is.
ftp_peers() {   # $1 = port -- one address per line, deduplicated
    command -v "$NETSTAT" >/dev/null 2>&1 || return 0
    "$NETSTAT" -tn 2>/dev/null | awk -v p="[:.]$1\$" '
        $NF == "ESTABLISHED" && $4 ~ p {
            addr = $5
            sub(/[:.][0-9]+$/, "", addr)      # drop the peer port
            if (addr != "") print addr
        }' | sort -u
}
ftp_peer_count() { ftp_peers "$1" | grep -c . ; }

# Both servers together, for the one-line "is anyone on this device" question.
remote_clients() {
    _rc_n=$(( $(ftp_peer_count "$REMOTE_LOG_PORT") + $(ftp_peer_count "$REMOTE_DEV_PORT") ))
    printf '%s' "$_rc_n"
}

# The line the panel prints only when someone is actually connected.
remote_peers_text() {
    _rp_l=$(ftp_peers "$REMOTE_LOG_PORT" | tr '\n' ' ')
    _rp_d=$(ftp_peers "$REMOTE_DEV_PORT" | tr '\n' ' ')
    _rp_o=""
    [ -n "$_rp_l" ] && _rp_o="Logs ${_rp_l%% }"
    [ -n "$_rp_d" ] && _rp_o="${_rp_o:+$_rp_o  }Dev ${_rp_d%% }"
    printf '%s' "$_rp_o"
}

# Both servers on one line, each saying where it is or that it is not there:
#   Logs (2121), Dev (Off)      the usual state
#   Logs (2121), Dev (2122)     dev access on
#   Logs (Off),  Dev (Off)      the log server turned off in config
# A server that is listening but firewalled says so instead of giving a port
# nothing can connect to -- that state cost a morning once.
remote_text() {
    # fw_is_open returns 2 for "no iptables here, cannot tell", which is not
    # the same as "blocked" -- only a definite 1 means the port is shut.
    if log_ftp_running; then
        if ! log_ftp_ours; then _rt_l="busy"        # someone else holds the port
        else
            fw_is_open "$REMOTE_LOG_PORT"; _rt_f=$?
            if [ "$_rt_f" = 1 ]; then _rt_l="blocked"; else _rt_l=$REMOTE_LOG_PORT; fi
        fi
    elif log_ftp_wanted; then _rt_l="starting"
    else _rt_l="Off"; fi

    if remote_running; then
        if ! remote_ours; then _rt_d="busy"
        else
            fw_is_open "$REMOTE_DEV_PORT"; _rt_f=$?
            if [ "$_rt_f" = 1 ]; then _rt_d="blocked"; else _rt_d=$REMOTE_DEV_PORT; fi
        fi
    elif remote_wanted; then _rt_d="starting"
    else _rt_d="Off"; fi

    printf 'Logs (%s), Dev (%s)' "$_rt_l" "$_rt_d"
}

# --- creating the dev FTP account ------------------------------------------
# ftpd authenticates against the system accounts, so the read-write dev server
# needs a real one. This makes a locked-down user (no login shell, home in
# /mnt/us) by writing /etc/passwd and /etc/shadow -- which live on the
# read-only rootfs, so it is the one thing here that can break the device's own
# login if it goes wrong. Hence: back up both files first, only ever APPEND or
# replace our own line (never touch root), validate the result parses and still
# has root, and restore the backups if anything looks wrong. The rootfs is put
# back read-only at the end whatever happens.
FTP_USER=${FTP_USER:-kfx}
PASSWD_FILE=${PASSWD_FILE:-/etc/passwd}
SHADOW_FILE=${SHADOW_FILE:-/etc/shadow}
ACCT_BACKUP=${ACCT_BACKUP:-$LOGDIR/etc-backup}
# Hooks so the logic can be tested off-device: in a test these become ":".
REMOUNT_RW=${REMOUNT_RW:-mount -o remount,rw /}
REMOUNT_RO=${REMOUNT_RO:-mount -o remount,ro /}

# Hash a password with whatever this build has. Prints the hash, or nothing.
hash_password() {   # $1 = plaintext
    if command -v cryptpw >/dev/null 2>&1; then
        printf '%s' "$1" | cryptpw -m sha512 2>/dev/null && return 0
    fi
    if command -v mkpasswd >/dev/null 2>&1; then
        mkpasswd -m sha512 "$1" 2>/dev/null && return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl passwd -6 "$1" 2>/dev/null && return 0   # -6 = sha512
    fi
    return 1
}

acct_exists() { cut -d: -f1 "$PASSWD_FILE" 2>/dev/null | grep -qx "$FTP_USER"; }

# Returns: 0 made/updated, 1 could not hash, 2 rootfs not writable, 3 validation
# failed (and was rolled back).
create_ftp_user() {   # $1 = plaintext password
    _cu_hash=$(hash_password "$1")
    [ -n "$_cu_hash" ] || return 1

    $REMOUNT_RW 2>/dev/null || return 2
    # Prove it really is writable, not just remounted.
    if ! { : > "$PASSWD_FILE.kfxtest" ; } 2>/dev/null; then
        $REMOUNT_RO 2>/dev/null; return 2
    fi
    rm -f "$PASSWD_FILE.kfxtest" 2>/dev/null

    mkdir -p "$ACCT_BACKUP" 2>/dev/null
    _cu_ts=$(date +%s)
    cp "$PASSWD_FILE" "$ACCT_BACKUP/passwd.$_cu_ts" 2>/dev/null
    cp "$SHADOW_FILE" "$ACCT_BACKUP/shadow.$_cu_ts" 2>/dev/null

    # An unused uid/gid at the top of the range.
    _cu_uid=$(awk -F: 'BEGIN{m=9000} $3+0>m && $3+0<20000 {m=$3} END{print m+1}' "$PASSWD_FILE" 2>/dev/null)
    case "$_cu_uid" in ''|*[!0-9]*) _cu_uid=9001 ;; esac

    # Build both files without our old line, then append the new one. Editing
    # in a temp and moving means a half-written file is never the live one.
    grep -v "^$FTP_USER:" "$PASSWD_FILE" > "$PASSWD_FILE.new.$$" 2>/dev/null
    # /bin/sh, not /bin/false: this account is used for SSH dev access too,
    # which needs a shell. FTP does not care either way.
    printf '%s:x:%s:%s:kfx dev:/mnt/us:/bin/sh\n' "$FTP_USER" "$_cu_uid" "$_cu_uid" >> "$PASSWD_FILE.new.$$"
    grep -v "^$FTP_USER:" "$SHADOW_FILE" > "$SHADOW_FILE.new.$$" 2>/dev/null
    printf '%s:%s:19000:0:99999:7:::\n' "$FTP_USER" "$_cu_hash" >> "$SHADOW_FILE.new.$$"

    # Validate before committing: every passwd line has 7 fields, root is still
    # there, and our user is present exactly once.
    if ! awk -F: 'NF!=7{bad=1} END{exit bad}' "$PASSWD_FILE.new.$$" 2>/dev/null \
       || ! grep -q '^root:' "$PASSWD_FILE.new.$$" \
       || [ "$(grep -c "^$FTP_USER:" "$PASSWD_FILE.new.$$")" != 1 ] \
       || ! grep -q '^root:' "$SHADOW_FILE.new.$$"; then
        rm -f "$PASSWD_FILE.new.$$" "$SHADOW_FILE.new.$$"
        $REMOUNT_RO 2>/dev/null
        return 3
    fi

    mv "$PASSWD_FILE.new.$$" "$PASSWD_FILE" 2>/dev/null
    mv "$SHADOW_FILE.new.$$" "$SHADOW_FILE" 2>/dev/null

    # Final guard: if root vanished from either file, put the backups back.
    if ! grep -q '^root:' "$PASSWD_FILE" || ! grep -q '^root:' "$SHADOW_FILE"; then
        cp "$ACCT_BACKUP/passwd.$_cu_ts" "$PASSWD_FILE" 2>/dev/null
        cp "$ACCT_BACKUP/shadow.$_cu_ts" "$SHADOW_FILE" 2>/dev/null
        $REMOUNT_RO 2>/dev/null
        return 3
    fi
    $REMOUNT_RO 2>/dev/null
    return 0
}

# --- SSH (dropbear) --------------------------------------------------------
# The static dropbear we built runs as its own standalone server (unlike ftpd,
# it does its own listen/accept -- no tcpsvd in front). Key-only auth, no root
# login: you log in as the kfx account, whose home is /mnt/us, so its
# authorized_keys lives at /mnt/us/.ssh/authorized_keys -- writable, unlike
# root's on the read-only rootfs.
SSH_PORT=${SSH_PORT:-2222}
SSH_FLAG=${SSH_FLAG:-${STATEDIR:-/var/local/kfx-state}/SSH_ON}
SSH_PID=${SSH_PID:-/tmp/kfx-dropbear.pid}
SSH_DIR=${SSH_DIR:-/mnt/us/.ssh}
SSH_AUTHKEYS=${SSH_AUTHKEYS:-$SSH_DIR/authorized_keys}
SSH_HOSTKEY=${SSH_HOSTKEY:-${STATEDIR:-/var/local/kfx-state}/dropbear_ed25519_host_key}

# armhf now; armel would join for old soft-float Kindles. Pick by the loader the
# firmware ships -- a static hardfloat binary needs a hardfloat CPU, and the
# armhf loader's presence is the reliable sign of one.
ssh_bin() {
    _sb_base=${BASE:-$(dirname "$CONF")}
    if [ -e /lib/ld-linux-armhf.so.3 ] && [ -f "$_sb_base/dropbearmulti-armhf" ]; then
        printf '%s' "$_sb_base/dropbearmulti-armhf"
    elif [ -f "$_sb_base/dropbearmulti-armel" ]; then
        printf '%s' "$_sb_base/dropbearmulti-armel"
    else
        printf '%s' "$_sb_base/dropbearmulti-armhf"   # best guess; may not exist
    fi
}
ssh_have_bin() { _hb=$(ssh_bin); [ -f "$_hb" ]; }

ssh_running() { server_up "$SSH_PORT" "$SSH_PID"; }
ssh_wanted()  { [ -f "$SSH_FLAG" ]; }
ssh_want_on() { mkdir -p "$(dirname "$SSH_FLAG")" 2>/dev/null; : > "$SSH_FLAG"; }
ssh_want_off(){ rm -f "$SSH_FLAG" 2>/dev/null; }
ssh_ours()    { pids_alive "$SSH_PID"; }
ssh_keys()    { grep -cE '^(ssh-|ecdsa-|sk-)' "$SSH_AUTHKEYS" 2>/dev/null || echo 0; }

# Make the host key once, with our own dropbearkey (the multi-binary). It lives
# in STATEDIR so it is stable across restarts -- a changing host key would make
# every client warn about a changed fingerprint.
ssh_ensure_hostkey() {
    [ -s "$SSH_HOSTKEY" ] && return 0
    _hb=$(ssh_bin); [ -f "$_hb" ] || return 1
    mkdir -p "$(dirname "$SSH_HOSTKEY")" 2>/dev/null
    "$_hb" dropbearkey -t ed25519 -f "$SSH_HOSTKEY" >/dev/null 2>&1
    [ -s "$SSH_HOSTKEY" ]
}

ssh_fingerprint() {
    _hb=$(ssh_bin); [ -f "$_hb" ] && [ -s "$SSH_HOSTKEY" ] || return 1
    "$_hb" dropbearkey -y -f "$SSH_HOSTKEY" 2>/dev/null | grep -i fingerprint | head -1
}

ssh_stop() {
    [ -s "$SSH_PID" ] && kill "$(cat "$SSH_PID" 2>/dev/null)" 2>/dev/null
    # dropbear may have re-forked; sweep any of ours by name on our port too.
    for _p in $(all_ssh_pids); do kill "$_p" 2>/dev/null; done
    rm -f "$SSH_PID"
    fw_close "$SSH_PORT"
}

all_ssh_pids() {
    for _d in "${PROCDIR:-/proc}"/[0-9]*; do
        grep -qa 'dropbearmulti' "$_d/cmdline" 2>/dev/null || continue
        grep -qa 'dropbear'      "$_d/cmdline" 2>/dev/null || continue
        echo "${_d##*/}"
    done
}

# Start dropbear: key-only (-s), no root login (-w), its own host key (-r),
# our port (-p), pidfile (-P). It daemonizes itself; setsid so a framework
# restart cannot take it down with the menu.
ssh_start() {
    _hb=$(ssh_bin)
    [ -f "$_hb" ] || { SSH_HOW="no dropbear binary (need $(basename "$_hb"))"; return 1; }
    chmod +x "$_hb" 2>/dev/null
    acct_exists || { SSH_HOW="no login account -- create it in Settings first"; return 1; }
    ssh_ensure_hostkey || { SSH_HOW="could not generate a host key"; return 1; }
    mkdir -p "$SSH_DIR" 2>/dev/null
    [ -f "$SSH_AUTHKEYS" ] || : > "$SSH_AUTHKEYS"
    chmod 700 "$SSH_DIR" 2>/dev/null; chmod 600 "$SSH_AUTHKEYS" 2>/dev/null
    rm -f "$SSH_PID"
    setsid "$_hb" dropbear -s -w -r "$SSH_HOSTKEY" -p "$SSH_PORT" -P "$SSH_PID" >/dev/null 2>&1 &
    sleep 2
    if ssh_running; then
        fw_open "$SSH_PORT" || SSH_HOW="running but firewall not opened"
        [ -z "$SSH_HOW" ] && SSH_HOW="dropbear"
        return 0
    fi
    SSH_HOW="dropbear did not stay up"; rm -f "$SSH_PID"; return 1
}

ssh_ensure() {
    ssh_wanted || return 0
    if ssh_running; then
        if ssh_ours; then fw_is_open "$SSH_PORT"; [ "$?" = 1 ] && fw_open "$SSH_PORT"; fi
        return 0
    fi
    if ssh_start; then emit "ssh: dropbear on $(device_ip):$SSH_PORT (key-only, as $FTP_USER)"; fi
    return 0
}

# Add one public key to authorized_keys, validated. Accepts a file or a string.
# Rejects anything that is not a single well-formed key line -- no newlines,
# no forced-command options that could turn an authorized key into a backdoor.
ssh_add_key() {   # $1 = a public key line (type base64 [comment])
    _ak_line=$(printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$_ak_line" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) ;;
        *) SSH_KEY_ERR="not a recognised public key line"; return 1 ;;
    esac
    # exactly one line, and no option prefix (must start with the key type)
    case "$_ak_line" in
        *"
"*) SSH_KEY_ERR="more than one line"; return 1 ;;
    esac
    mkdir -p "$SSH_DIR" 2>/dev/null
    # de-dupe on the base64 body (field 2), so re-adding a key does nothing.
    _ak_body=$(printf '%s' "$_ak_line" | awk '{print $2}')
    if [ -f "$SSH_AUTHKEYS" ] && [ -n "$_ak_body" ] && grep -qF "$_ak_body" "$SSH_AUTHKEYS" 2>/dev/null; then
        SSH_KEY_ERR=""; return 0
    fi
    printf '%s\n' "$_ak_line" >> "$SSH_AUTHKEYS"
    chmod 700 "$SSH_DIR" 2>/dev/null; chmod 600 "$SSH_AUTHKEYS" 2>/dev/null
    SSH_KEY_ERR=""; return 0
}

# --- enrolling a key over the network ------------------------------------
# A short attended window: the device serves an HTTP endpoint, a host POSTs its
# public key, and the owner approves it here on the Kindle. The endpoint only
# queues the request; this loop is the only thing that writes authorized_keys,
# and only after a YES. It listens only while this window is open.
ENROLL_PORT=${ENROLL_PORT:-2223}
ENROLL_DIR=${ENROLL_DIR:-/tmp/kfx-enroll}
ENROLL_PIDS=${ENROLL_PIDS:-/tmp/kfx-enroll.pids}
ENROLL_SERVE=${ENROLL_SERVE:-$(dirname "$CONF")/enroll-serve.sh}

# The SHA256 fingerprint of an offered public key, in ssh's own format when
# openssl is here, else a plain hash so there is still something to eyeball.
pubkey_fp() {   # $1 = full key line
    _pf_blob=$(printf '%s' "$1" | awk '{print $2}')
    [ -n "$_pf_blob" ] || { printf '(no key body)'; return; }
    if command -v openssl >/dev/null 2>&1; then
        _pf=$(printf '%s' "$_pf_blob" | openssl base64 -d -A 2>/dev/null \
              | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null)
        [ -n "$_pf" ] && { printf 'SHA256:%s' "$(printf '%s' "$_pf" | sed 's/=*$//')"; return; }
    fi
    printf 'sha256 %s' "$( (printf '%s' "$_pf_blob" | sha256sum 2>/dev/null) | cut -c1-32)"
}

enroll_running() { server_up "$ENROLL_PORT" "$ENROLL_PIDS"; }
enroll_stop() {
    [ -s "$ENROLL_PIDS" ] && while read -r _ep; do kill "$_ep" 2>/dev/null; done < "$ENROLL_PIDS"
    rm -f "$ENROLL_PIDS"
    fw_close "$ENROLL_PORT"
}
enroll_start() {
    command -v tcpsvd >/dev/null 2>&1 || { ENROLL_HOW="no tcpsvd"; return 1; }
    [ -x "$ENROLL_SERVE" ] || [ -f "$ENROLL_SERVE" ] || { ENROLL_HOW="enroll-serve.sh missing"; return 1; }
    rm -rf "$ENROLL_DIR"; mkdir -p "$ENROLL_DIR/pending" "$ENROLL_DIR/decision" 2>/dev/null
    : > "$ENROLL_PIDS"
    # No -E: we WANT tcpsvd to set TCPREMOTEIP so the prompt can name the host.
    ENROLL_DIR="$ENROLL_DIR" setsid tcpsvd -v 0.0.0.0 "$ENROLL_PORT" sh "$ENROLL_SERVE" >/dev/null 2>&1 &
    echo $! >> "$ENROLL_PIDS"
    sleep 2
    if enroll_running; then fw_open "$ENROLL_PORT"; return 0; fi
    while read -r _ep; do kill "$_ep" 2>/dev/null; done < "$ENROLL_PIDS" 2>/dev/null
    rm -f "$ENROLL_PIDS"; ENROLL_HOW="did not start on $ENROLL_PORT"; return 1
}

# Handle any requests waiting in the spool: show each, ask, act. Returns the
# number handled. Kept separate so it can be tested without the read loop.
enroll_process_pending() {
    _epp_n=0
    for _epp_f in "$ENROLL_DIR"/pending/*; do
        [ -f "$_epp_f" ] || continue
        _epp_id=$(basename "$_epp_f")
        _epp_ip=$(sed -n 's/^ip=//p' "$_epp_f" | head -1)
        _epp_key=$(sed -n 's/^key=//p' "$_epp_f" | head -1)
        echo
        printf '   a host wants to enrol an SSH key:\n'
        printf '     from: %s\n' "${_epp_ip:-unknown}"
        printf '     type: %s\n' "$(printf '%s' "$_epp_key" | awk '{print $1}')"
        printf '     note: %s\n' "$(printf '%s' "$_epp_key" | awk '{print $3}')"
        printf '     %s\n' "$(pubkey_fp "$_epp_key")"
        printf '   approve this key? type YES > '
        read _epp_ans 2>/dev/null
        if [ "$_epp_ans" = YES ] && ssh_add_key "$_epp_key"; then
            echo approve > "$ENROLL_DIR/decision/$_epp_id"
            printf '   enrolled. %s key(s) now.\n' "$(ssh_keys)"
        else
            echo deny > "$ENROLL_DIR/decision/$_epp_id"
            printf '   denied%s\n' "$([ -n "$SSH_KEY_ERR" ] && printf ' (%s)' "$SSH_KEY_ERR")"
        fi
        # Remove the request now so a refresh cannot re-prompt it before the
        # handler (which is reading the decision) clears it.
        rm -f "$_epp_f"
        _epp_n=$((_epp_n + 1))
    done
    return 0
}

enroll_window() {
    clear 2>/dev/null
    rule; printf ' enrol an SSH key\n'; rule; echo
    if ! enroll_start; then
        printf '   could not open the endpoint: %s\n' "$ENROLL_HOW"
        echo; printf ' [enter] > '; read _x 2>/dev/null; return 0
    fi
    acct_exists || printf '   NOTE: no dev account yet -- create it (option 8) or\n   the enrolled key cannot be used until you do.\n\n'
    printf '   On the host you want to let in, run:\n'
    printf '     curl --max-time 130 --data-binary @~/.ssh/id_ed25519.pub \\\n'
    printf '       http://%s:%s/enroll\n\n' "$(device_ip)" "$ENROLL_PORT"
    printf '   Then approve it here. This endpoint is open only while this\n'
    printf '   screen is. Press q to close it.\n'
    while :; do
        enroll_process_pending
        printf '   waiting for a key...  [enter] refresh, q to stop > '
        read -t 5 _ew 2>/dev/null
        case "$_ew" in q|Q) break ;; esac
    done
    enroll_stop
    rm -rf "$ENROLL_DIR"
    printf '\n   enrolment closed.\n'
    echo; printf ' [enter] > '; read _x 2>/dev/null
}

ssh_text() {
    if ssh_running; then
        if ! ssh_ours; then printf 'busy'
        else fw_is_open "$SSH_PORT"; [ "$?" = 1 ] && printf 'on, blocked' || printf 'on :%s' "$SSH_PORT"; fi
    elif ssh_wanted; then printf 'on, not answering'
    else printf 'off'
    fi
}

device_ip() { ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1; }

# ---------------- updates ----------------
# The update daemon (kfx-update.sh) does the work: it checks on its own every
# quarter of an hour and announces what it finds. The front end only reads its
# state files and writes requests, so a slow or failing download can never hang
# the menu.
UPDATER=${UPDATER:-${BASE:-/mnt/us/extensions/kfx-sync}/kfx-update.sh}
# The same default as kfx-update.sh, and overridden by the same config, so the
# screen can say where it is looking. "Could not reach it" is a much more
# useful sentence with the address attached.
UPDATE_URL=${UPDATE_URL:-https://raw.githubusercontent.com/jaymart1983/shelfback/main/kindle}
UPDATE_REQ=${UPDATE_REQ:-/var/local/kfx-update.req}
UPDATE_AVAIL=${UPDATE_AVAIL:-${STATEDIR:-/var/local/kfx-state}/UPDATE_AVAIL}
UPDATE_DUE=${UPDATE_DUE:-${STATEDIR:-/var/local/kfx-state}/UPDATE_DUE}
UPDATE_GO=${UPDATE_GO:-${STATEDIR:-/var/local/kfx-state}/UPDATE_GO}
UPDATE_STATE=${UPDATE_STATE:-${STATEDIR:-/var/local/kfx-state}/UPDATE_STATE}
ULOG=${ULOG:-/mnt/us/kfx-update.log}

installed_version() { cat "${BASE:-/mnt/us/extensions/kfx-sync}/VERSION" 2>/dev/null; }

# One line for the panel. The updater writes its own state in words meant to be
# read here, so this mostly passes it through -- an announced update is the one
# case worth adding to, because when it installs matters as much as that it can.
update_panel_text() {
    [ -f "$UPDATER" ] || { printf 'not installed'; return; }
    _up_a=$(update_available)
    if [ -n "$_up_a" ]; then printf 'update available (%s) %s' "$_up_a" "$(update_due_text)"; return; fi
    _up_s=$(update_status)
    case "$_up_s" in
        '') printf 'checking' ;;        # started, nothing reported yet
        *)  printf '%s' "$_up_s" ;;
    esac
}
update_available()  { cat "$UPDATE_AVAIL" 2>/dev/null; }
update_status()     { cat "$UPDATE_STATE" 2>/dev/null; }

# "in 4m", or "now" once the deadline has passed.
update_due_text() {
    _ud_t=$(cat "$UPDATE_DUE" 2>/dev/null)
    case "$_ud_t" in ''|*[!0-9]*) printf 'soon'; return ;; esac
    _ud_s=$(( _ud_t - $(date +%s) ))
    if   [ "$_ud_s" -le 0 ];  then printf 'now'
    elif [ "$_ud_s" -lt 60 ]; then printf 'in %ss' "$_ud_s"
    else printf 'in %sm' "$(( (_ud_s + 59) / 60 ))"
    fi
}

request_update() {
    [ -f "$UPDATER" ] || return 1
    mkdir -p "$(dirname "$UPDATE_REQ")" 2>/dev/null
    : > "$UPDATE_REQ" 2>/dev/null || return 1
    return 0
}
# The front end runs from memory. An update replaces menu.sh on disk and this
# process keeps the old code until something starts it again -- which is why an
# over-the-air update appeared to do nothing until the script was relaunched by
# hand. So when the installed version stops matching the build we are running,
# restart into it.
#
# KFX_RELOADED survives the exec and stops this becoming a loop if the two can
# never agree: a hand-edited VERSION, or a menu.sh the updater could not stamp.
# One restart per version, then leave it alone and say so on the menu.
menu_self() {
    case "$0" in
        *menu.sh) [ -r "$0" ] && { printf '%s' "$0"; return 0; } ;;
    esac
    printf '%s' "$(dirname "$CONF")/menu.sh"
}

reload_if_stale() {
    [ -n "${KFX_BUILD:-}" ] || return 0
    _ri_v=$(installed_version)
    [ -n "$_ri_v" ] || return 0
    [ "$_ri_v" = "$KFX_BUILD" ] && return 0
    [ "${KFX_RELOADED:-}" = "$_ri_v" ] && return 1     # tried once already
    _ri_self=$(menu_self)
    [ -r "$_ri_self" ] || return 1
    emit "front end restarting: $KFX_BUILD -> $_ri_v"
    flush_log
    clear 2>/dev/null
    printf '\n'
    uline "Updated to $_ri_v."
    uline "Restarting..."
    sleep 2
    if [ "${KFX_RELOAD_DRYRUN:-0}" = 1 ]; then printf 'would exec %s\n' "$_ri_self"; return 0; fi
    KFX_RELOADED=$_ri_v
    export KFX_RELOADED
    exec sh "$_ri_self"
}

request_install() {
    [ -f "$UPDATER" ] || return 1
    mkdir -p "$(dirname "$UPDATE_GO")" 2>/dev/null
    : > "$UPDATE_GO" 2>/dev/null || return 1
    return 0
}

# Every line clipped to the screen. The updater writes sentences, and one line
# wrapping pushes the rest of the page down and makes the whole screen look
# broken.
uline() { printf '   %s\n' "$(short "$1" $((W - 4)))"; }

updates_screen() {
    clear 2>/dev/null
    rule; printf ' updates\n'; rule; echo
    if [ ! -f "$UPDATER" ]; then
        uline "The updater is not installed."
        uline "$UPDATER"
        echo; printf ' [enter] > '; read _x 2>/dev/null; return 0
    fi
    uline "Installed: $(stat_or "$(installed_version)")"
    _us_a=$(update_available)
    [ -n "$_us_a" ] && uline "Available: $_us_a"
    uline "Source:    $UPDATE_URL/VERSION"
    echo
    uline "Checking for Updates"
    echo
    if ! request_update; then
        uline "The updater is not running."
        echo; printf ' [enter] > '; read _x 2>/dev/null; return 0
    fi
    # The daemon deletes the request when it picks it up, and writes one line
    # of state when it has an answer. Wait for that, not for a log to grow.
    _us_was=$(update_status)
    _us_n=0
    while [ "$_us_n" -lt 45 ]; do
        sleep 2; _us_n=$((_us_n + 2))
        [ -f "$UPDATE_REQ" ] && continue
        [ "$(update_status)" != "$_us_was" ] && break
        [ "$_us_n" -ge 12 ] && break        # answered the same as before
    done
    uline "$(stat_or "$(update_status)")"
    _us_a=$(update_available)
    if [ -n "$_us_a" ]; then
        echo
        uline "Version $_us_a will install $(update_due_text)."
        uline "Choose Install Update on the main menu to do it now."
    fi
    echo; printf ' [enter] > '; read _x 2>/dev/null
}

install_update_screen() {
    clear 2>/dev/null
    rule; printf ' updates\n'; rule; echo
    _iu_a=$(update_available)
    if [ -z "$_iu_a" ]; then
        uline "Nothing to install."
        echo; printf ' [enter] > '; read _x 2>/dev/null; return 0
    fi
    uline "Installing $_iu_a"
    uline "This restarts the background sync. It takes about a minute."
    echo
    if ! request_install; then
        uline "The updater is not running."
        echo; printf ' [enter] > '; read _x 2>/dev/null; return 0
    fi
    _iu_n=0
    while [ "$_iu_n" -lt 120 ]; do
        sleep 3; _iu_n=$((_iu_n + 3))
        [ -n "$(update_available)" ] || break     # cleared: done, either way
    done
    uline "$(stat_or "$(update_status)")"
    uline "Installed: $(stat_or "$(installed_version)")"
    if [ "$(installed_version)" != "$KFX_BUILD" ]; then
        echo
        uline "Restarting on the new version."
    fi
    echo; printf ' [enter] > '; read _x 2>/dev/null
    # Back to the menu loop, which restarts into the new code.
}

# ---------------- calibre login ----------------
# Address, username and password live in cwa.conf beside the config. The daemon
# re-reads that file before every login, refresh and upload, so a change here
# takes effect on its next tick -- no restart. Every change drops the old
# session and tries the new login straight away, so a typo shows up here, not
# as a silently stalled sync.
cwa_test_text() {
    cwa_forget_session
    if cwa_login; then state_set CWA_LINK ok; echo "login OK"
    else
        state_set CWA_LINK "${CWA_ERR:-?}"
        case "$CWA_ERR" in
            login) echo "login FAILED -- check the username and password" ;;
            curl*) echo "cannot reach $CWA_URL (Error $CWA_ERR)" ;;
            *)     echo "login FAILED (Error ${CWA_ERR:-?})" ;;
        esac
    fi
}

calibre_login_menu() {
    # Loaded on demand, so the login can be set up before switching over.
    if ! command -v cwa_load_conf >/dev/null 2>&1; then
        [ -r "$(dirname "$CONF")/cwa.sh" ] || { echo "  cwa.sh is missing"; sleep 2; return 0; }
        . "$(dirname "$CONF")/cwa.sh"
    fi
    _cl_msg=""
    while :; do
        cwa_load_conf
        clear 2>/dev/null
        rule; printf ' calibre login\n'; rule; echo
        printf '   address:  %s\n' "$(short "$CWA_URL" $((W - 14)))"
        printf '   username: %s\n' "$(short "${CWA_USER:-(not set)}" $((W - 14)))"
        if [ -n "$CWA_PASS" ]; then printf '   password: set\n'; else printf '   password: (not set)\n'; fi
        [ "$BACKEND" = cwa ] || printf '   (not in use yet: this Kindle syncs through the receiver)\n'
        [ -n "$_cl_msg" ] && { echo; printf '   %s\n' "$_cl_msg"; }
        echo
        rule
        printf '   1) Change address\n'
        printf '   2) Change username\n'
        printf '   3) Change password\n'
        printf '   4) Test login\n'
        printf '   [enter] back\n'
        rule
        printf ' > '
        read _cm 2>/dev/null || return 0
        case "$_cm" in
            1) printf '\n  new address, e.g. http://192.168.1.211:8083\n  [enter] keeps the current one\n  > '
               read -r _cv 2>/dev/null
               _cv=$(printf '%s' "$_cv" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
               case "$_cv" in
                   '')                 _cl_msg="address unchanged" ;;
                   http://*|https://*) CWA_URL=${_cv%/}; cwa_save_conf
                                       _cl_msg="address saved -- $(cwa_test_text)" ;;
                   *)                  _cl_msg="not saved: it must start with http:// or https://" ;;
               esac ;;
            2) printf '\n  new username\n  [enter] keeps the current one\n  > '
               read -r _cv 2>/dev/null
               _cv=$(printf '%s' "$_cv" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
               if [ -z "$_cv" ]; then _cl_msg="username unchanged"
               else CWA_USER=$_cv; cwa_save_conf; _cl_msg="username saved -- $(cwa_test_text)"; fi ;;
            3) # Typed blind, twice: a typo in a hidden field is otherwise
               # invisible until the sync stops.
               printf '\n  new password (not shown as you type)\n  [enter] keeps the current one\n  > '
               stty -echo 2>/dev/null; read -r _cp1 2>/dev/null; stty echo 2>/dev/null; echo
               if [ -z "$_cp1" ]; then
                   _cl_msg="password unchanged"
               else
                   printf '  again, to confirm\n  > '
                   stty -echo 2>/dev/null; read -r _cp2 2>/dev/null; stty echo 2>/dev/null; echo
                   if [ "$_cp1" = "$_cp2" ]; then
                       CWA_PASS=$_cp1; cwa_save_conf; _cl_msg="password saved -- $(cwa_test_text)"
                   else
                       _cl_msg="not saved: the two entries did not match"
                   fi
               fi
               _cp1=; _cp2= ;;
            4) _cl_msg="$(cwa_test_text)" ;;
            *) return 0 ;;
        esac
    done
}

settings_menu() {
    while :; do
        clear 2>/dev/null
        rule; printf ' settings\n'; rule; echo
        sh "$DAEMON" status 2>&1 | sed 's/^/   /'
        echo
        rule
        case "$(boot_hook_state)" in
            on)    printf '   1) Disable Auto-Start Monitor on Boot\n' ;;
            off)   printf '   1) Enable Auto-Start Monitor on Boot\n' ;;
            *)     printf '   1) Auto-start: another script owns the hook\n' ;;
        esac
        printf '   2) Backlight off after: %s\n' "$(light_idle_text)"
        printf '   3) Monitor log\n'
        printf '   4) Recovery history\n'
        printf '   5) Restart UI now (clears stuck downloads)\n'
        printf '   6) Calibre login\n'
        printf '   7) Dev FTP (read-write, port %s): %s\n' \
        "$REMOTE_DEV_PORT" "$(remote_wanted && echo ON || echo off)"
        printf '   8) FTP login: %s\n' "$(acct_exists && echo "set ($FTP_USER)" || echo "not created")"
        printf '   9) SSH (dev, port %s): %s\n' "$SSH_PORT" "$(ssh_wanted && echo ON || echo off)"
        printf '  10) Enrol an SSH key over the network\n'
        printf '   [enter] back\n'
        rule
        printf ' > '
        read _sm 2>/dev/null || return 0
        case "$_sm" in
            1) clear 2>/dev/null; echo
               if [ "$(boot_hook_state)" = "on" ]; then
                   sh /mnt/us/extensions/kfx-sync/install-boot-hook.sh remove 2>&1 | sed 's/^/   /'
               else
                   sh /mnt/us/extensions/kfx-sync/install-boot-hook.sh 2>&1 | sed 's/^/   /'
               fi
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            2) light_idle_next ;;
            6) calibre_login_menu ;;
            7) clear 2>/dev/null; echo
               if remote_wanted; then
                   remote_want_off; remote_stop
                   emit "dev access: turned off"
                   printf '   Dev access is off.\n'
                   printf '   Logs stay readable on port %s.\n' "$REMOTE_LOG_PORT"
               elif ! acct_exists; then
                   printf '   No FTP login yet. Create one first with\n'
                   printf '   option 8, then turn this on.\n'
               else
                   printf '   Opens a SECOND FTP server on port %s, serving\n' "$REMOTE_DEV_PORT"
                   printf '   all of /mnt/us READ AND WRITE -- every book, and\n'
                   printf '   cwa.conf with your Calibre password. Log in as the\n'
                   printf '   "%s" account you created.\n\n' "$FTP_USER"
                   printf '   The anonymous log server on %s is unaffected.\n' "$REMOTE_LOG_PORT"
                   printf '   This stays on until you turn it off here.\n\n'
                   printf '   type YES to turn it on > '
                   read _ra 2>/dev/null
                   if [ "$_ra" = "YES" ]; then
                       remote_want_on
                       if remote_start; then
                           emit "dev access: ftp://$(device_ip):$REMOTE_DEV_PORT/ read-write, via $REMOTE_HOW"
                           printf '\n   on: ftp://%s@%s:%s/\n' "$FTP_USER" "$(device_ip)" "$REMOTE_DEV_PORT"
                           printf '   stays on, through a UI restart, until turned off\n'
                       else
                           printf '\n   could not start: %s\n' "$REMOTE_HOW"
                           printf '   left ON, so the daemon will keep trying\n'
                       fi
                   else
                       printf '\n   cancelled\n'
                   fi
               fi
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            8) clear 2>/dev/null; echo
               printf '   Creates the "%s" FTP login used by the dev server.\n' "$FTP_USER"
               printf '   This writes /etc/passwd and /etc/shadow on the\n'
               printf '   device. Both are backed up first, root is never\n'
               printf '   touched, and the change is undone if anything looks\n'
               printf '   wrong -- but it is the one setting that edits the\n'
               printf '   system, so it asks before doing it.\n\n'
               printf '   a dev account, home /mnt/us, for FTP and SSH.\n\n'
               printf '   type a password for it (blank to cancel) > '
               read _pw 2>/dev/null
               if [ -z "$_pw" ]; then
                   printf '\n   cancelled\n'
               else
                   create_ftp_user "$_pw"
                   case "$?" in
                       0) printf '\n   login "%s" is ready.\n' "$FTP_USER"
                          printf '   turn on Dev FTP (option 7) to use it.\n' ;;
                       1) printf '\n   no password-hashing tool on this device\n'
                          printf '   (need cryptpw, mkpasswd or openssl)\n' ;;
                       2) printf '\n   the system files are not writable here.\n'
                          printf '   the root filesystem would not remount.\n' ;;
                       3) printf '\n   the change did not validate and was undone.\n'
                          printf '   nothing was altered.\n' ;;
                   esac
               fi
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            9) clear 2>/dev/null; echo
               if ssh_wanted; then
                   ssh_want_off; ssh_stop
                   emit "ssh: turned off"
                   printf '   SSH is off.\n'
               elif ! ssh_have_bin; then
                   printf '   The dropbear binary is not installed:\n'
                   printf '   %s\n' "$(ssh_bin)"
               elif ! acct_exists; then
                   printf '   No dev account yet. Create one with option 8,\n'
                   printf '   then turn on SSH.\n'
               else
                   # A key is required -- this is key-only auth. Import one from
                   # the drop file if the user left it there over FTP/USB.
                   if [ "$(ssh_keys)" -eq 0 ] && [ -s /mnt/us/import_key.pub ]; then
                       if ssh_add_key "$(cat /mnt/us/import_key.pub)"; then
                           printf '   imported the key from /mnt/us/import_key.pub\n'
                           rm -f /mnt/us/import_key.pub
                       else
                           printf '   /mnt/us/import_key.pub is not a valid key: %s\n' "$SSH_KEY_ERR"
                       fi
                   fi
                   if [ "$(ssh_keys)" -eq 0 ]; then
                       printf '   No authorized keys yet, and SSH here is key-only.\n'
                       printf '   Add your PUBLIC key one of these ways, then retry:\n'
                       printf '    - drop it at /mnt/us/import_key.pub (via dev FTP\n'
                       printf '      or USB); I will import it, or\n'
                       printf '    - append it to %s\n' "$SSH_AUTHKEYS"
                   else
                       printf '   Starts dropbear on port %s, key-only, no root.\n' "$SSH_PORT"
                       printf '   Log in: ssh -p %s %s@%s\n\n' "$SSH_PORT" "$FTP_USER" "$(device_ip)"
                       printf '   %s authorized key(s).\n' "$(ssh_keys)"
                       printf '   type YES to turn it on > '
                       read _ss 2>/dev/null
                       if [ "$_ss" = "YES" ]; then
                           ssh_want_on
                           if ssh_start; then
                               emit "ssh: dropbear on $(device_ip):$SSH_PORT (key-only, as $FTP_USER)"
                               printf '\n   on: ssh -p %s %s@%s\n' "$SSH_PORT" "$FTP_USER" "$(device_ip)"
                               printf '   host %s\n' "$(ssh_fingerprint)"
                               printf '   stays on, through a UI restart, until turned off\n'
                           else
                               printf '\n   could not start: %s\n' "$SSH_HOW"
                               printf '   left ON, so the daemon will keep trying\n'
                           fi
                       else
                           printf '\n   cancelled\n'
                       fi
                   fi
               fi
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            10) enroll_window ;;
            3) clear 2>/dev/null
               tail -30 /mnt/us/kfx-daemon.log 2>/dev/null | sed 's/^/  /' || echo "  no log yet"
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            4) clear 2>/dev/null
               echo "  UI restarts used to clear a wedged download queue:"; echo
               tail -12 /mnt/us/kfx-recoveries.log 2>/dev/null | sed 's/^/    /' || echo "    none"
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            5) clear 2>/dev/null
               echo "  This restarts the Kindle UI -- the screen will blank and"
               echo "  return to the home screen. The device does NOT reboot,"
               echo "  and the monitor keeps running through it."
               echo
               echo "  It is the only thing that clears a wedged download"
               echo "  queue. The monitor does this by itself when it detects"
               echo "  one; use this if you want it now."
               echo
               printf '  type YES to restart the UI > '
               read _ru 2>/dev/null
               if [ "$_ru" = "YES" ]; then
                   printf '%s manual-ui-restart\n' "$(date +%s)" >> /mnt/us/kfx-recoveries.log
                   emit "RECOVERY: UI restart requested from the menu"
                   flush_log
                   sleep 2
                   if initctl status lab126_gui >/dev/null 2>&1; then initctl restart lab126_gui
                   elif [ -x /etc/init.d/framework ]; then /etc/init.d/framework restart
                   else pkill -TERM cvm; fi
               else
                   echo; echo "  cancelled"; sleep 1
               fi ;;
            *) return 0 ;;
        esac
    done
}

draw() {
    clear 2>/dev/null
    HALF=$((W / 2))                 # both stat columns start on this boundary
    rule
    # The build number sits where the clock used to, one space in from the
    # right. Padding is spelled into the format rather than %*s, which not
    # every busybox printf supports.
    _hb_pad=$((W - 10 - ${#KFX_BUILD})); [ "$_hb_pad" -lt 1 ] && _hb_pad=1
    printf " KFX Sync%${_hb_pad}s%s \n" '' "$KFX_BUILD"
    rule
    _dst=$(daemon_state)            # asked once: it shells out
    # System.
    if [ "$BACKEND" = cwa ]; then
        two ' calibre:' "$(cwa_link_text "$(state_get CWA_LINK)")"
    else
        two ' receiver:' "$RCV_STATE"
    fi
    two ' daemon:'   "$_dst"       'monitor:'  "$(monitor_text)"
    if monitor_on; then _nxt=$(fmt_clock "$(state_get NEXT_SYNC)"); else _nxt="--:--:--"; fi
    two ' last sync:' "$(fmt_clock "$(state_get LAST_SYNC)")" 'next sync:' "$_nxt"
    # Updates gets the full width: "update available (09122026.1100) in 5m" is
    # longer than half a screen. The address shares a row with the FTP ports,
    # because neither is useful without the other.
    two ' updates:'  "$(update_panel_text)" '' ''
    two ' ip:'       "$(stat_or "$(device_ip)")" 'ssh:' "$(ssh_text)"
    two ' ftp:'      "$(remote_text)" '' ''
    # Someone reading or writing this Kindle's storage is worth more than a
    # column: it is a server with no password, and the owner should be able to
    # see it is in use without going looking.
    # Only when someone is actually on it: a line that is always there stops
    # being read, and this one is worth reading.
    _dr_p=$(remote_peers_text)
    [ -n "$_dr_p" ] && printf '%s\n' "$(short " connected: $_dr_p" "$W")"
    rule
    # Books.
    two ' decrypted:' "$(stat_or "$(state_get N_SYNCED)")" \
        'uploaded:'   "$(stat_or "$(state_get N_SYNCED)")"
    two ' wanted:'    "$(stat_or "$(state_get N_WANTED)")" \
        'missing:'    "$(stat_or "$(state_get N_MISSING)")"
    two ' problems:'  "$(stat_or "$(state_get N_PROBLEMS)")" '' ''
    rule
    printf ' 1) Sync now\n'
    if monitor_on; then
        printf ' 2) Stop Monitor%s\n'  "$(m_since started)"
    else
        printf ' 2) Start Monitor%s\n' "$(m_since stopped)"
    fi
    printf ' 3) Books\n'
    [ "$(state_get N_PROBLEMS)" -gt 0 ] 2>/dev/null && printf ' 4) View problems\n'
    _mm_up=$(update_available)
    [ -n "$_mm_up" ] && printf '%s\n' \
        "$(short " 5) Install update $_mm_up (otherwise $(update_due_text))" "$W")"
    echo
    if [ "$(installed_version)" != "$KFX_BUILD" ] && [ -n "$(installed_version)" ]; then
        printf '%s\n' \
            "$(short " ! running $KFX_BUILD, $(installed_version) installed -- reopen" "$W")"
    fi
    printf ' U) Updates\n'
    printf ' S) Settings\n'
    printf ' R) Refresh\n'
    printf ' L) Log\n'
    printf ' C) Close (leave the daemon running)\n'
    printf ' Q) Quit (stop the daemon)\n'
    echo
    printf ' > '
}

# Two label/value pairs, the second starting exactly at mid-screen so the
# columns line up whatever the values are.
two() {
    _t_left=$(printf '%s %s' "$1" "$2")
    if [ -z "$3" ]; then
        printf '%s\n' "$(short "$_t_left" "$W")"
    else
        # Clip the left column, or a long value runs into the right one and the
        # two columns stop lining up -- which is what a wrapped line looks like
        # before it wraps.
        _t_left=$(short "$_t_left" $((HALF - 1)))
        printf '%-*s%s %s\n' "$HALF" "$_t_left" "$3" "$(short "$4" $((W - HALF - ${#3} - 2)))"
    fi
}

# A count we have never computed shows as "-", not a bare empty column.
stat_or() { [ -n "$1" ] && printf '%s' "$1" || printf -- '-'; }

# " (started 09102026 09:36:25)" -- empty until the monitor has been touched.
m_since() {
    _ms=$(monitor_since)
    [ -n "$_ms" ] || return 0
    printf ' (%s %s)' "$1" "$_ms"
}

# ---------------- every book this Kindle knows ----------------
# One row per book: title, pieces, status. Built in one awk pass over files the
# sync already keeps -- one sqlite3 query for every title, not one per book --
# because a per-book lookup is several seconds on this CPU.
#
#   pieces   "3/4" (present/needed) while the book is on this Kindle, from the
#            book's record, which cwa_complete updates each time it opens one.
#            Nothing decides anything from these numbers -- completeness is
#            recomputed from the archive itself -- but this screen cannot unzip
#            every book just to draw a column;
#            "?" until it has; "Cleared" once the book is sent and gone from
#            here -- it needs no tracking after that; "-" before it arrives.
#   status   in the order the list is sorted, work still to do first:
#            Queued        known to this Kindle, download not started
#            Downloading   requested, not landed yet
#            Stuck         download failed; waiting before trying again
#            Waiting Part  here, but a piece has not downloaded yet
#            Not Sent      here and complete, not uploaded yet
#            Not KFX       here, but in a format that is never sent (AZW,
#                          MOBI, PDF -- and AZW3 unless the backend is CWA,
#                          whose DeDRM plugin takes AZW3 as it is)
#            Sent          uploaded; Calibre has not confirmed it yet (or
#                          never can: a book with no ASIN)
#            Sent Success  Calibre has it
# A copy with each book's key lands in $OUT/.books-list.tsv every time the list
# is built, so it can be read off the USB mount when something looks wrong.
all_books_table() {   # $1 = output file: "title<TAB>pieces<TAB>status<TAB>key"
    _ab_st=${CWA_STATE:-$STATEDIR}; _ab_t=/tmp/kfx-ab.$$
    sqlite3 -separator '	' "$CC_DB" "select distinct p_cdeKey, replace(coalesce(p_titles_0_nominal,''),'	',' ')
        from Entries where p_cdeType='EBOK' and p_type='Entry:Item' and p_cdeKey is not null;" \
        2>/dev/null > "$_ab_t.cat"
    # On this Kindle: a downloaded book (any format the sync counts as "have"),
    # or its decrypted archive. Only KFX can be decrypted and sent.
    for _ab_f in "$ITEMS"/*.kfx "$OUT"/*.kfx-zip "$ITEMS"/*.azw3 "$ITEMS"/*.azw \
                 "$ITEMS"/*.mobi "$ITEMS"/*.pdf; do
        [ -e "$_ab_f" ] || continue
        case "$_ab_f" in
            *.kfx|*.kfx-zip) _ab_k=kfx ;;
            *.azw3)          if [ "$BACKEND" = cwa ]; then _ab_k=azw3; else _ab_k=other; fi ;;
            *)               _ab_k=other ;;
        esac
        printf '%s\t%s\t%s\n' "$(key_of "$_ab_f")" "$(basename "$_ab_f")" "$_ab_k"
    done > "$_ab_t.local"
    { [ -s "$SYNCED_CACHE" ] && [ "$BACKEND" != cwa ] && cat "$SYNCED_CACHE"; } > "$_ab_t.done"
    LC_ALL=C awk -F'\t' -v now="$(date +%s)" -v grace="${CWA_GRACE:-1800}" -v cwa="$BACKEND" \
        -v asins="$_ab_st/cwa.asins" -v state="$STATE_FILE" \
        -v seed="${CWA_SEED:-/nonexistent}" -v done="$_ab_t.done" \
        -v infl="$INFLIGHT" -v stuck="$STUCKLIST" -v local_="$_ab_t.local" '
        function rd(f, arr,   l, a) { while ((getline l < f) > 0) { split(l, a, " "); arr[a[1]] = l } }
        # A title taken from a file name: no extension, no trailing _<ASIN> or _<UUID>.
        function nice(n) { sub(/\.(kfx(-zip)?|azw3?|mobi|pdf)$/, "", n); sub(/_B[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9](_sample)?$/, "", n)
                           sub(/_[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]+$/, "", n); return n }
        BEGIN {
            rd(asins, A); rd(infl, I); rd(stuck, S)
            while ((getline l < done) > 0) D[l] = 1          # whole line: keys can hold spaces
            while ((getline l < seed) > 0) if (l !~ /^#/ && l != "") SD[l] = 1
            # One pass over the book records: stage, when it entered it, and
            # the pieces. Everything this screen used to read from four files.
            while ((getline l < state) > 0) {
                if (l ~ /^#/) continue
                if (split(l, u, "\t") < 9) continue
                SG[u[1]] = u[2]; SN[u[1]] = u[3]; NE[u[1]] = u[6]; HA[u[1]] = u[7]
                if (!(u[1] in T) && u[9] != "-" && u[9] != "") T[u[1]] = nice(u[9])
            }
            while ((getline l < local_) > 0) { split(l, u, "\t"); L[u[1]] = 1; if (u[3] == "kfx" || u[3] == "azw3") LK[u[1]] = 1; if (u[3] == "azw3") AZ[u[1]] = 1
                                               if (!(u[1] in T)) T[u[1]] = nice(u[2]) }
        }
        { if ($1 != "") { if ($2 != "") T[$1] = $2; K[$1] = 1 } }
        END {
            for (k in L) K[k] = 1
            for (k in SG) K[k] = 1        # books we have a record of, wherever they are now
            for (k in K) {
                a = k; sub(/_sample$/, "", a)
                here = (k in L)
                # Calibre confirms ASINs only. The seed keys were confirmed by the
                # old receiver; any other ASIN-less upload can only ever be "Sent".
                if (cwa == "cwa") ok = (a in A) || (k in SD)
                else ok = (k in D) || (a in D)
                if (ok || SG[k] == "confirmed")           { st = "Sent Success"; r = 7 }
                else if (SG[a] == "waiting")              { st = "Waiting Part"; r = 4 }
                else if (SG[k] == "uploaded" && (now - SN[k] < grace || k !~ /^B[A-Z0-9]/)) { st = "Sent"; r = 6 }
                else if (SG[k] == "failed")               { st = "Failed"; r = 4 }
                else if (a in I)                          { st = "Downloading"; r = 2 }
                else if (a in S)                          { st = "Stuck"; r = 3 }
                else if (here && (k in LK))               { st = "Not Sent"; r = 5 }
                else if (here)                            { st = "Not KFX"; r = 5 }
                else                                      { st = "Queued"; r = 1 }
                if (!here)       pc = (r >= 6 ? "Cleared" : "-")
                else if (!(k in LK)) pc = "-"
                else if (k in AZ)    pc = "1/1"      # one file, nothing to gather
                else if (a in NE && NE[a] + 0 > 0) pc = HA[a] "/" NE[a]
                else             pc = "?"
                t = (k in T && T[k] != "" ? T[k] : k)
                printf "%d\t%s\t%s\t%s\t%s\n", r, t, pc, st, k
            }
        }' "$_ab_t.cat" | sort -t '	' -k1,1n -k2,2f | cut -f2- > "$1"
    cp "$1" "$OUT/.books-list.tsv" 2>/dev/null
    rm -f "$_ab_t.cat" "$_ab_t.local" "$_ab_t.done"
}

list_all_books() {
    clear 2>/dev/null
    printf '\n   gathering...\n'
    _lb_f=/tmp/kfx-allbooks.$$
    all_books_table "$_lb_f"
    _lb_n=$(wc -l < "$_lb_f" | tr -d ' ')
    # Title takes what the screen leaves after " pieces  status".
    _lb_tw=$((W - 24)); [ "$_lb_tw" -lt 12 ] && _lb_tw=12
    _lb_rows=$(stty size 2>/dev/null | awk '{print $1}')
    case "$_lb_rows" in ''|*[!0-9]*) _lb_rows=24 ;; esac
    _lb_per=$((_lb_rows - 9)); [ "$_lb_per" -lt 5 ] && _lb_per=5
    _lb_pages=$(( (_lb_n + _lb_per - 1) / _lb_per )); [ "$_lb_pages" -lt 1 ] && _lb_pages=1
    # Counts in list order, wrapped to the screen rather than cut off.
    _lb_sum=$(awk -F'\t' -v w="$((W - 2))" '{c[$3]++}
        END { n = split("Queued,Downloading,Stuck,Waiting Part,Not Sent,Not KFX,Sent,Sent Success", o, ",")
              line = ""
              for (i = 1; i <= n; i++) if (c[o[i]]) {
                  item = o[i] " " c[o[i]]
                  if (line != "" && length(line) + 2 + length(item) > w) { print line ","; line = item }
                  else line = (line == "" ? item : line ", " item)
              }
              if (line != "") print line }' "$_lb_f")
    _lb_p=1
    while :; do
        clear 2>/dev/null
        rule; printf ' all Kindle books (%s)\n' "$_lb_n"; rule
        printf '%s\n' "$_lb_sum" | sed 's/^/ /'
        printf " %-${_lb_tw}s %7s  %s\n" 'title' 'pieces' 'status'
        _lb_a=$(( (_lb_p - 1) * _lb_per + 1 )); _lb_b=$((_lb_a + _lb_per - 1))
        # Padded and cut by CHARACTER, not byte: an "ae" ligature or an accent
        # is two bytes in UTF-8 but one column on screen, and byte-counting
        # left such rows a space short.
        sed -n "${_lb_a},${_lb_b}p" "$_lb_f" | LC_ALL=C awk -F'\t' -v tw="$_lb_tw" '
            function chars(t,   i, c, n) { n = 0
                for (i = 1; i <= length(t); i++) { c = substr(t, i, 1); if (!(c >= "\200" && c < "\300")) n++ }
                return n }
            function head(t, m,   i, c, n, out) { n = 0; out = ""
                for (i = 1; i <= length(t); i++) { c = substr(t, i, 1)
                    if (!(c >= "\200" && c < "\300")) { if (n == m) break; n++ }
                    out = out c }
                return out }
            function fit(t, w,   n) { n = chars(t)
                if (n > w) { t = head(t, w - 3) "..."; n = w }
                while (n < w) { t = t " "; n++ }
                return t }
            { printf " %s %7s  %s\n", fit($1, tw), $2, $3 }'
        rule
        printf ' page %s/%s   [enter] next  p) prev  q) back > ' "$_lb_p" "$_lb_pages"
        read _lb_k 2>/dev/null || break
        case "$_lb_k" in
            '') [ "$_lb_p" -lt "$_lb_pages" ] && _lb_p=$((_lb_p + 1)) || break ;;
            p|P) [ "$_lb_p" -gt 1 ] && _lb_p=$((_lb_p - 1)) ;;
            *) break ;;
        esac
    done
    rm -f "$_lb_f"
}

books_menu() {
    while :; do
        clear 2>/dev/null
        rule; printf ' books\n'; rule; echo
        printf '   on the server: %-6s   waiting: %s\n' \
            "$(stat_or "$(state_get N_SYNCED)")" "$(stat_or "$(state_get N_MISSING)")"
        printf '   on your wanted list: %s\n' "$(stat_or "$(state_get N_WANTED)")"
        echo
        rule
        printf '   1) Recently added\n'
        printf '   2) Still to fetch\n'
        printf '   3) Your wanted list\n'
        printf '   4) List All Kindle Books\n'
        printf '   [enter] back\n'
        rule
        printf ' > '
        read _bm 2>/dev/null || return 0
        case "$_bm" in
            1) recent_books ;;
            2) clear 2>/dev/null
               rule; printf ' still to fetch\n'; rule; echo
               if [ "$(n_missing)" -gt 0 ]; then
                   pending_list | head -20 | while read -r _b; do
                       printf '   %s  %s\n' "$_b" "$(short "$(title_of "$_b")" $((W - 18)))"
                   done
               else
                   printf '   Nothing outstanding.\n'
               fi
               echo; printf ' [enter] > '; read _x 2>/dev/null ;;
            3) list_wanted ;;
            4) list_all_books ;;
            *) return 0 ;;
        esac
    done
}

# Without the receiver, the Kindle's own record of what it sent, each marked by
# whether Calibre has it yet.
recent_uploads_cwa() {
    clear 2>/dev/null
    rule; printf ' recently sent to Calibre\n'; rule; echo
    # Straight from the book records: everything we sent, most recent first.
    _ru_any=0
    for _ru_st in uploaded confirmed; do
        st_keys "$_ru_st" >> /tmp/kfxsync.sent.$$ 2>/dev/null
    done
    if [ -s /tmp/kfxsync.sent.$$ ]; then
        _ru_any=1
        while read -r _ru_k; do
            printf '%s\t%s\n' "$(st_get "$_ru_k" since)" "$_ru_k"
        done < /tmp/kfxsync.sent.$$ | sort -rn | head -20 | while IFS='	' read -r _ru_t _ru_k; do
            _ru_a=${_ru_k%_sample}
            case "$(st_stage "$_ru_k")" in
                confirmed) _ru_s="in Calibre" ;;
                *)         case "$_ru_k" in
                               B*) if cwa_has "$_ru_a"; then _ru_s="in Calibre"; else _ru_s="waiting"; fi ;;
                               *)  _ru_s="sent" ;;
                           esac ;;
            esac
            _ru_title=$(title_of "$_ru_a")
            [ -n "$_ru_title" ] || _ru_title=$(st_get "$_ru_k" title)
            printf '   %s  %-10s %s\n' "$(fmt_day "$_ru_t")" "$_ru_s" "$(short "$_ru_title" $((W - 30)))"
        done
    else
        printf '   nothing sent yet\n'
    fi
    rm -f /tmp/kfxsync.sent.$$
    echo; printf ' [enter] > '; read _x 2>/dev/null
}

# When a book actually reached Calibre is only known to the receiver, so ask it.
recent_books() {
    [ "$BACKEND" = cwa ] && { recent_uploads_cwa; return; }
    clear 2>/dev/null
    rule; printf ' recently added\n'; rule; echo
    _rb=/tmp/kfx-recent.$$
    if ! curl -sS -o "$_rb" --max-time 20 "$RECEIVER/recent?n=20" 2>/dev/null; then
        printf '   receiver unreachable\n'
        rm -f "$_rb"
        echo; printf ' [enter] > '; read _x 2>/dev/null
        return
    fi
    if [ -s "$_rb" ]; then
        while IFS='	' read -r _ts _key _title; do
            printf '   %s  %s\n' "$(fmt_day "$_ts")" "$(short "$_title" $((W - 20)))"
        done < "$_rb"
    else
        printf '   nothing recorded yet\n'
    fi
    rm -f "$_rb"
    echo; printf ' [enter] > '; read _x 2>/dev/null
}

# "today 09:44" for recent arrivals, "Sep 08" for older ones -- a bare clock on
# a three-day-old book would read as if it had just landed.
fmt_day() {
    case "$1" in ''|*[!0-9]*) printf '%-12s' "?"; return ;; esac
    _fd_age=$(( $(date +%s) - $1 ))
    if [ "$_fd_age" -lt 86400 ]; then
        printf 'today %s' "$(fmt_clock "$1" | cut -c1-5)"
    elif [ "$_fd_age" -lt 172800 ]; then
        printf 'yest. %s' "$(fmt_clock "$1" | cut -c1-5)"
    else
        printf '%3sd ago    ' "$(( _fd_age / 86400 ))"
    fi
}

list_problems() {
    clear 2>/dev/null
    rule; printf ' problems\n'; rule; echo
    printf '  Failed to decrypt (%s):\n' "$(n_bad)"
    if [ "$(n_bad)" -gt 0 ]; then
        st_keys failed | head -12 | while read -r _pb; do
            printf '    %s\n' "$(short "$(title_of "$_pb")" $((W - 6)))"
            printf '      %s\n' "$(short "$(st_get "$_pb" note)" $((W - 8)))"
        done
    else
        printf '    none\n'
    fi
    echo
    printf '  Download left a sidecar but no book (%s):\n' "$(n_stalled)"
    if [ "$(n_stalled)" -gt 0 ]; then
        stalled_list | head -12 | while read -r _pb; do
            printf '    %s  %s\n' "$_pb" "$(short "$(title_of "$_pb")" $((W - 20)))"
        done
    else
        printf '    none\n'
    fi
    echo
    rule
    printf ' These retry on their own. Persistent ones are on the\n'
    printf ' receiver at /stuck.\n'
    rule
    printf ' [enter] back > '
    read _x 2>/dev/null
}

view_log() {
    clear 2>/dev/null
    rule; printf ' recent activity\n'; rule; echo
    tail -30 "$LOG" 2>/dev/null | cut -c1-"$W"
    echo; rule
    printf ' [enter] back > '
    read _x 2>/dev/null
}

# Startup has to be quick. n_stalled globs ~300 sidecar directories and
# n_missing additionally queries cc.db and globs again -- and a stray duplicate
# meant BOTH ran twice per call, which was most of the wait before the menu
# appeared. They are only needed when asked for, so they are computed on demand
# (option 3, or the screens that display them) rather than at startup.
refresh_state() {
    if [ "$BACKEND" = cwa ]; then
        # A real login, not just "the port answers".
        if cwa_login; then state_set CWA_LINK ok; RCV_STATE=ok
        else state_set CWA_LINK "${CWA_ERR:-?}"; RCV_STATE="error ${CWA_ERR:-?}"; fi
    elif curl -sS --max-time 6 "$RECEIVER/healthz" >/dev/null 2>&1 </dev/null; then RCV_STATE=ok; else RCV_STATE=DOWN; fi
    WANTED_N=$(n_wanted)
    if [ "${1:-}" = full ]; then
        printf ' counting...\r'
        STALLED_N=$(n_stalled)
        MISSING_N=$(n_missing)
        PROBLEMS_N=$(n_problems)
        state_set N_MISSING "$MISSING_N"
        state_set N_PROBLEMS "$PROBLEMS_N"
    fi
}

# --- entry point -----------------------------------------------------------
# Everything above is definitions. The daemon sources this file with KFX_LIB=1
# to get the sync logic without the front end, so there is one implementation
# rather than two that drift.
if [ "${KFX_LIB:-0}" = 1 ]; then
    trap - INT TERM HUP          # the daemon installs its own
    return 0
fi

clear 2>/dev/null
echo "KFX Sync starting..."
awake_on
# The background helper is always wanted: it is what lets a sync survive the UI
# restart used to clear a stuck download. Whether it syncs on a timer is the
# Monitor flag, which this does not touch.
#
# A daemon started by an earlier build keeps running that build's code until it
# is stopped -- relaunching the menu alone does not reach it. Seen 11 Sep 2026:
# menu on 09112026.1450, daemon still on 0831, so the new AZW3 sending never
# ran. So restart it whenever its recorded build is not ours (a daemon from
# before builds were recorded has none, and is restarted too).
if [ "$(daemon_state)" = running ] && [ "$(state_get DAEMON_BUILD)" != "$KFX_BUILD" ]; then
    _db=$(state_get DAEMON_BUILD)
    emit "helper was build ${_db:-unknown}, restarting on $KFX_BUILD"
    sh "$DAEMON" stop >/dev/null 2>&1
fi
sh "$DAEMON" ensure >/dev/null 2>&1
# The update daemon too, or "Check for updates" reports it unreachable until
# the next reboot -- the boot hook was the only thing starting it. Backgrounded
# and ignored: it is not needed to sync books, so it must not delay the menu or
# fail it.
[ -f "$UPDATER" ] && ( sh "$UPDATER" start >/dev/null 2>&1 & ) 2>/dev/null
# In the background: these need a cc.db query and a directory walk, and blocking
# the first paint on them is what the panel's "-" was avoiding. They fill in a
# few seconds later, on the next repaint.
( refresh_counts ) >/dev/null 2>&1 &
refresh_state
emit "front end build $KFX_BUILD"
emit "front end started ($DEST_L $RCV_STATE)"
flush_log

# Wake on a short step and keep two clocks: one for the backlight, one for the
# periodic refresh. They used to be the same 60s key wait, so a shorter light
# setting could never take effect. A 15s wake costs nothing -- it only
# repaints when something actually changed.
UI_STEP=15
_redraw=1; _idle=0; _since=0
while :; do
    # Before drawing, not after: if the code on disk is newer than this
    # process, the screen we are about to paint is the old one.
    reload_if_stale
    [ "$_redraw" = 1 ] && draw
    _redraw=0
    if read -t "$UI_STEP" choice 2>/dev/null; then
        # Any key wakes the light; Enter on its own is a safe way to do that.
        _idle=0
        light_restore
        _redraw=1
        case "$choice" in
            1) manual_sync ;;
            2) monitor_toggle ;;
            3) books_menu ;;
            4) refresh_state full; list_problems ;;
            5) [ -n "$(update_available)" ] && install_update_screen ;;
            u|U) updates_screen ;;
            s|S) settings_menu ;;
            r|R) refresh_state full ;;
            l|L) view_log ;;
            c|C) close_only ;;
            q|Q) quit_all ;;
            *) : ;;
        esac
    else
        _idle=$((_idle + UI_STEP))
        _since=$((_since + UI_STEP))
        _li=$(light_idle)
        [ "$_li" -gt 0 ] && [ "$_idle" -ge "$_li" ] && light_off
        if [ "$_since" -ge "$REFRESH" ]; then
            _since=0
            # A remote "run" is the daemon's job, not the front end's. Acting
            # on it here started a sync while the user sat on the menu.
            case "$(poll_cmd)" in
                stop) emit "remote: stop"; cleanup ;;
            esac
            refresh_state
            flush_log
            # Nothing syncing, nothing changes: leave the screen alone.
            monitor_on && _redraw=1
        fi
    fi
done
