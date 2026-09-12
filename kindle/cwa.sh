#!/bin/sh
# cwa.sh -- talk to Calibre-Web Automated directly, as a logged-in user.
#
# Sourced by menu.sh (and through it kfx-daemon.sh) when BACKEND=cwa. This is
# what replaces the receiver: the Kindle asks Calibre what it holds and hands it
# finished books, with nothing in between.
#
# WHAT CALIBRE HOLDS, BY ASIN
# CWA will not hand over a list keyed by ASIN. /ajax/listbooks returns every
# book in one request, but its identifiers field is always empty, and neither
# OPDS nor the web search matches an ASIN. The one place CWA shows it is each
# book's own page, as an amazon.com/dp/<ASIN> link. So the map is built
# incrementally: the list gives the current ids, a page is read once per id we
# have not seen, and ids that leave the list drop out of the map.
#
# Books without an ASIN (sideloaded files) show no identifier on their page at
# all -- CWA only renders types it has a URL for -- so they never appear here.
# The upload record below remembers them permanently instead: uploaded once,
# never purged, never re-sent, which is how they were already treated.
#
# THE ONE RULE
# A book missing from the list means "not in Calibre, fetch it again". So a list
# with holes in it is worse than no list: if the list itself or any page we
# needed could not be read, the previous list stays as it was and the caller is
# told it failed. Nothing here ever publishes a partial answer.

CWA_CONF=${CWA_CONF:-/mnt/us/extensions/kfx-sync/cwa.conf}
CWA_URL_DEFAULT=http://192.168.1.211:8083

# Address and login come from cwa.conf, which Settings can rewrite while the
# daemon is running -- so read it again before anything that talks to CWA,
# rather than once at start. It is three lines; sourcing it costs nothing.
cwa_load_conf() {
    CWA_URL=; CWA_USER=; CWA_PASS=
    [ -r "$CWA_CONF" ] && . "$CWA_CONF"
    CWA_URL=${CWA_URL:-$CWA_URL_DEFAULT}
    CWA_URL=${CWA_URL%/}
}
cwa_load_conf

# Write cwa.conf from CWA_URL, CWA_USER and CWA_PASS. Each value is single-
# quoted with any ' inside escaped, so a password with quotes, $ or spaces
# reads back exactly as typed. Written to a temp file and moved into place, so
# a daemon sourcing it mid-write never sees half a file.
cwa_save_conf() {
    _cs_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
    {   echo "# CWA login for this Kindle. Written by KFX Sync -> Settings -> Calibre login."
        echo "CWA_URL=$(_cs_q "$CWA_URL")"
        echo "CWA_USER=$(_cs_q "$CWA_USER")"
        echo "CWA_PASS=$(_cs_q "$CWA_PASS")"
    } > "$CWA_CONF.new.$$" && mv "$CWA_CONF.new.$$" "$CWA_CONF"
}

# A changed address or login must not reuse the old session.
cwa_forget_session() { rm -f "$CWA_JAR"; }
CWA_STATE=${CWA_STATE:-${STATEDIR:-/var/local/kfx-state}}
CWA_TMP=${CWA_TMP:-/tmp}
# Unpacking a book needs real space; /tmp is a 64MB tmpfs shared with /var.
CWA_WORK=${CWA_WORK:-/mnt/us/dedrm/.work}
CWA_JAR="$CWA_STATE/cwa.cookies"
CWA_MAP="$CWA_STATE/cwa.map"        # "<book id> <ASIN>", or "<book id> - <epoch checked>" for none yet
# A page read before backfill-asins has recorded the book's ASIN shows none --
# and that used to be cached for good, so a just-uploaded book was never seen
# as confirmed and was sent again after the grace period. An empty answer is
# therefore re-checked once it is this old (seconds). ~13 sideloaded books
# genuinely have none; re-reading those every 10 minutes costs a few requests.
CWA_RECHECK=${CWA_RECHECK:-600}
CWA_ASINS="$CWA_STATE/cwa.asins"    # ASINs Calibre holds, one per line, sorted
CWA_UPLOADS="$CWA_STATE/cwa.uploads" # "<key>\t<epoch>\t<file name>" -- tabs: keys can hold spaces
# How long an upload counts as done before Calibre has to confirm it. Covers
# CWA's import and conversion plus backfill-asins' 10-minute cycle, which is
# what records the ASIN the book page shows.
CWA_GRACE=${CWA_GRACE:-1800}
CWA_LAST=""                         # one-line summary of the last operation
# Why the last request failed, short enough for the status panel: an HTTP code
# (e.g. 503), "curl <n>" when the network failed (7 = no connection, 28 =
# timed out), or "login" when CWA refused the username or password.
CWA_ERR=""

cwa_token() { sed -n 's/.*name="csrf_token"[^>]*value="\([^"]*\)".*/\1/p' "$1" | head -1; }

# A fresh session. Flask-WTF wants the token from the login page and the cookie
# that came with it; success is a redirect away from /login, failure re-renders
# the form with 200.
#
# The menu, its background count refresher and the daemon all share CWA_JAR.
# Two of them logging in at once used to interleave: one posted its token with
# the other's session cookie, and CWA answered 400 (CSRF mismatch) -- shown as
# "Error 400" while the login itself was fine. So each login builds its session
# in a jar of its own and only swaps it in, whole, once the login has worked.
cwa_login() {
    cwa_load_conf
    CWA_ERR=""
    if [ -z "$CWA_USER" ] || [ -z "$CWA_PASS" ]; then CWA_ERR="no login set"; return 1; fi
    mkdir -p "$CWA_STATE" 2>/dev/null
    _cl_p="$CWA_TMP/cwa-login.$$"; _cl_j="$CWA_JAR.login.$$"
    rm -f "$_cl_j"
    _cl_c=$(curl -sS --max-time 20 -c "$_cl_j" -o "$_cl_p" -w '%{http_code}' \
              "$CWA_URL/login" </dev/null 2>/dev/null); _cl_rc=$?
    if [ "$_cl_rc" -ne 0 ]; then rm -f "$_cl_p" "$_cl_j"; CWA_ERR="curl $_cl_rc"; return 1; fi
    _cl_t=$(cwa_token "$_cl_p"); rm -f "$_cl_p"
    if [ -z "$_cl_t" ]; then rm -f "$_cl_j"; CWA_ERR="${_cl_c:-no page}"; [ "$CWA_ERR" = 200 ] && CWA_ERR="not CWA"; return 1; fi
    _cl_w=$(curl -sS --max-time 20 -b "$_cl_j" -c "$_cl_j" -o /dev/null \
        -w '%{http_code} %{redirect_url}' \
        --data-urlencode "csrf_token=$_cl_t" --data-urlencode "username=$CWA_USER" \
        --data-urlencode "password=$CWA_PASS" --data-urlencode "remember_me=on" \
        --data-urlencode "next=/" "$CWA_URL/login" </dev/null 2>/dev/null); _cl_rc=$?
    if [ "$_cl_rc" -ne 0 ]; then rm -f "$_cl_j"; CWA_ERR="curl $_cl_rc"; return 1; fi
    case "$_cl_w" in
        302*/login*) rm -f "$_cl_j"; CWA_ERR="login"; return 1 ;;
        302*)        mv "$_cl_j" "$CWA_JAR"; return 0 ;;
        200*)        rm -f "$_cl_j"; CWA_ERR="login"; return 1 ;;   # the form came back: refused
    esac
    rm -f "$_cl_j"
    CWA_ERR="${_cl_w%% *}"
    return 1
}

# GET a page into $2, logging in when there is no session or it has expired.
cwa_get() {   # $1 = path, $2 = output file
    for _cg_try in 1 2; do
        [ -s "$CWA_JAR" ] || cwa_login || return 1
        _cg_c=$(curl -sS --max-time 30 -b "$CWA_JAR" -c "$CWA_JAR" -o "$2" \
                  -w '%{http_code} %{redirect_url}' "$CWA_URL$1" </dev/null 2>/dev/null)
        _cg_rc=$?
        if [ "$_cg_rc" -ne 0 ]; then CWA_ERR="curl $_cg_rc"; return 1; fi
        case "$_cg_c" in
            200*)             CWA_ERR=""; return 0 ;;
            302*/login*|401*) rm -f "$CWA_JAR"; CWA_ERR="login" ;;    # session gone: once more
            *)                CWA_ERR="${_cg_c%% *}"; return 1 ;;
        esac
    done
    return 1
}

# "192.168.1.211:8083 (Connected)" or "... (Error 503)" for the status panel.
# $1 = "ok" or an error from CWA_ERR.
cwa_link_text() {
    _lt_u=${CWA_URL#http://}; _lt_u=${_lt_u#https://}
    if [ "$1" = ok ]; then printf '%s (Connected)' "$_lt_u"
    else printf '%s (Error %s)' "$_lt_u" "${1:-?}"; fi
}

cwa_up() { cwa_load_conf; curl -sS -o /dev/null --max-time 6 "$CWA_URL/login" </dev/null 2>/dev/null; }

# Rebuild the map and, only if every book is accounted for, the ASIN list.
# Temp names carry the PID: the daemon and the front end's count refresher can
# both run this at once.
cwa_refresh() {
    cwa_load_conf
    mkdir -p "$CWA_STATE" 2>/dev/null
    # Book ids belong to one CWA. If the address changed since the map was
    # built, the old ids mean nothing here: start the map again.
    if [ "$(cat "$CWA_MAP.url" 2>/dev/null)" != "$CWA_URL" ]; then
        rm -f "$CWA_MAP" "$CWA_ASINS"
        printf '%s' "$CWA_URL" > "$CWA_MAP.url"
    fi
    _cr_l="$CWA_TMP/cwa-list.$$"
    if ! cwa_get "/ajax/listbooks?offset=0&limit=100000&sort=id&order=asc" "$_cr_l"; then
        rm -f "$_cr_l"; CWA_LAST="book list unavailable (${CWA_ERR:-?})"; return 1
    fi
    _cr_total=$(grep -o '"total": [0-9]*' "$_cr_l" | head -1 | sed 's/.*: //')
    grep -o '"id": [0-9]*' "$_cr_l" | sed 's/.*: //' | sort -n > "$_cr_l.ids"
    rm -f "$_cr_l"
    _cr_n=$(wc -l < "$_cr_l.ids" | tr -d ' ')
    # A list that disagrees with its own count is not a list to act on.
    if [ -z "$_cr_total" ] || [ "$_cr_n" != "$_cr_total" ] || [ "$_cr_n" -lt 1 ]; then
        rm -f "$_cr_l.ids"; CWA_ERR="bad list"; CWA_LAST="book list inconsistent (${_cr_n:-0} ids, total ${_cr_total:-?})"
        return 1
    fi

    touch "$CWA_MAP"
    : > "$CWA_MAP.new.$$"
    _cr_new=0; _cr_fail=0; _cr_now=$(date +%s)
    while read -r _cr_id; do
        _cr_have=$(sed -n "s/^$_cr_id //p" "$CWA_MAP" | head -1)
        case "$_cr_have" in
            B*) printf '%s %s\n' "$_cr_id" "$_cr_have" >> "$CWA_MAP.new.$$"; continue ;;
            "- "*) _cr_t=${_cr_have#- }
                   if [ $((_cr_now - ${_cr_t:-0})) -lt "$CWA_RECHECK" ] 2>/dev/null; then
                       printf '%s %s\n' "$_cr_id" "$_cr_have" >> "$CWA_MAP.new.$$"; continue
                   fi ;;
        esac
        if cwa_get "/book/$_cr_id" "$CWA_TMP/cwa-book.$$"; then
            _cr_a=$(grep -o 'amazon\.com/dp/B[A-Z0-9]\{9\}' "$CWA_TMP/cwa-book.$$" | head -1 | sed 's|.*/||')
            if [ -n "$_cr_a" ]; then printf '%s %s\n' "$_cr_id" "$_cr_a" >> "$CWA_MAP.new.$$"
            else printf '%s - %s\n' "$_cr_id" "$_cr_now" >> "$CWA_MAP.new.$$"; fi
            _cr_new=$((_cr_new + 1))
        else
            _cr_fail=$((_cr_fail + 1))    # not recorded: tried again next time
        fi
        rm -f "$CWA_TMP/cwa-book.$$"
    done < "$_cr_l.ids"
    rm -f "$_cr_l.ids"

    # The map may be saved partial -- it is only a cache of pages already read.
    mv "$CWA_MAP.new.$$" "$CWA_MAP"
    if [ "$_cr_fail" -gt 0 ]; then
        CWA_ERR="${CWA_ERR:-pages}"; CWA_LAST="books=$_cr_n looked-up=$_cr_new FAILED=$_cr_fail (list not updated)"
        return 1
    fi
    awk '$2 ~ /^B[A-Z0-9]+$/ && length($2) == 10 {print $2}' "$CWA_MAP" | sort -u > "$CWA_ASINS.new.$$" \
        && mv "$CWA_ASINS.new.$$" "$CWA_ASINS"
    CWA_LAST="books=$_cr_n looked-up=$_cr_new asins=$(wc -l < "$CWA_ASINS" | tr -d ' ')"
    return 0
}

cwa_has() {   # $1 = ASIN
    [ -s "$CWA_ASINS" ] && grep -qxF "$1" "$CWA_ASINS" 2>/dev/null
}

# ---------------- what each book is made of ----------------
# Written by cwa_complete each time it looks inside a book, read by the Books
# list. Books sent before this existed have no line: their pieces are unknown.
CWA_PARTS="$CWA_STATE/cwa.parts"    # "<ASIN> <pieces needed> <pieces present>"
cwa_record_parts() {   # $1 = ASIN, $2 = needed, $3 = present
    mkdir -p "$CWA_STATE" 2>/dev/null
    sed -i "/^$1 /d" "$CWA_PARTS" 2>/dev/null
    printf '%s %s %s\n' "$1" "$2" "$3" >> "$CWA_PARTS"
}

# ---------------- the upload record ----------------
cwa_record_upload() {   # $1 = key, $2 = file name
    mkdir -p "$CWA_STATE" 2>/dev/null
    printf '%s\t%s\t%s\n' "$1" "$(date +%s)" "$2" >> "$CWA_UPLOADS"
}

# Keys to treat as done without Calibre's say-so: an ASIN for CWA_GRACE after
# its upload, a key with no ASIN for good (Calibre can never confirm those).
#
# cwa.seed (next to cwa.conf) lists ASIN-less books that reached Calibre before
# this Kindle talked to it directly -- through the old receiver -- so there is
# no upload record for them here. One key per line, done for good.
CWA_SEED="$(dirname "$CWA_CONF")/cwa.seed"
cwa_uploaded_keys() {
    [ -s "$CWA_SEED" ] && grep -v '^#' "$CWA_SEED" | grep -v '^$'
    [ -s "$CWA_UPLOADS" ] || return 0
    awk -F'\t' -v now="$(date +%s)" -v grace="$CWA_GRACE" '
        $1 ~ /^B[A-Z0-9]+(_sample)?$/ { if (now - $2 < grace) print $1; next }
        { print $1 }' "$CWA_UPLOADS" | sort -u
}

# The "done" list the rest of the Kindle works from, in the receiver's format:
# what Calibre holds (each ASIN also in its _sample form -- a sample's key is
# ASIN_sample, Calibre records the bare ASIN), plus recent and ASIN-less uploads.
cwa_synced_view() {   # $1 = output file
    { [ -s "$CWA_ASINS" ] && sed 'p; s/$/_sample/' "$CWA_ASINS"
      cwa_uploaded_keys; } | sort -u > "$1.$$" && mv "$1.$$" "$1"
}

# ---------------- books held for a missing piece ----------------
# A book waiting on a piece that has not downloaded yet is not a bad copy, so
# reconcile_local leaves it alone for CWA_GRACE -- the same window an upload
# gets -- before giving up on it and starting over with a fresh download.
CWA_HELD="$CWA_STATE/cwa.held"      # "<ASIN> <epoch first held>"
cwa_hold() {   # $1 = ASIN; keeps the FIRST time, so the window cannot slide
    mkdir -p "$CWA_STATE" 2>/dev/null
    grep -q "^$1 " "$CWA_HELD" 2>/dev/null || printf '%s %s\n' "$1" "$(date +%s)" >> "$CWA_HELD"
}
cwa_unhold() { sed -i "/^$1 /d" "$CWA_HELD" 2>/dev/null; }
cwa_held_recent() {   # $1 = ASIN
    _ch_t=$(sed -n "s/^$1 //p" "$CWA_HELD" 2>/dev/null | head -1)
    [ -n "$_ch_t" ] || return 1
    if [ $(( $(date +%s) - _ch_t )) -lt "$CWA_GRACE" ]; then return 0; fi
    cwa_unhold "$1"    # window over: let the fresh download happen, once
    return 1
}

# ---------------- upload ----------------
# POST /upload as the logged-in user. CWA writes the file into its ingest folder
# as new_<user>_<time>_<name>, so the ASIN at the end of the name survives for
# backfill-asins. The CSRF token comes from any logged-in page; success is a
# JSON redirect to /tasks, a rejected file redirects to / instead.
cwa_upload() {   # $1 = file
    cwa_load_conf
    _cu_f=$1; _cu_n=$(basename "$1")
    for _cu_try in 1 2; do
        cwa_get "/" "$CWA_TMP/cwa-home.$$" || { rm -f "$CWA_TMP/cwa-home.$$"; CWA_LAST="not logged in"; return 1; }
        _cu_t=$(cwa_token "$CWA_TMP/cwa-home.$$"); rm -f "$CWA_TMP/cwa-home.$$"
        [ -n "$_cu_t" ] || { rm -f "$CWA_JAR"; continue; }
        # The token belongs to the session that fetched it: post with that
        # exact session, even if another process logs in meanwhile.
        _cu_j="$CWA_JAR.up.$$"; cp "$CWA_JAR" "$_cu_j" 2>/dev/null
        # Names on the Kindle's FAT storage cannot contain " or \, so quoting
        # them is safe -- and needed, since titles carry ; and , which -F
        # would otherwise read as its own separators.
        _cu_c=$(curl -sS --max-time 600 -b "$_cu_j" -c "$_cu_j" -o "$CWA_TMP/cwa-up.$$" \
                  -w '%{http_code}' -H "X-CSRFToken: $_cu_t" \
                  -F "btn-upload=@\"$_cu_f\";filename=\"$_cu_n\"" \
                  "$CWA_URL/upload" </dev/null 2>/dev/null)
        _cu_b=$(head -c 200 "$CWA_TMP/cwa-up.$$" 2>/dev/null); rm -f "$CWA_TMP/cwa-up.$$" "$_cu_j"
        case "$_cu_c:$_cu_b" in
            200:*/tasks*) CWA_LAST="accepted"; return 0 ;;
            200:*)        CWA_LAST="refused by Calibre"; return 1 ;;
            400:*)        rm -f "$CWA_JAR" ;;          # stale token/session: once more
            *)            CWA_LAST="http ${_cu_c:-none}"; return 1 ;;
        esac
    done
    CWA_LAST="upload failed"
    return 1
}

# ---------------- a complete book ----------------
# A multi-part KFX book names every piece it needs, and KFX Input refuses the
# book unless all of them are in the one archive. Each piece's own id is the
# first CR! string in it; the book's map (metadata.kfx) lists the rest. So:
#   required = every CR! id any piece mentions
#   present  = each entry's own id (a CR!<id>.kfx entry is named by its id)
# Anything missing is looked for in the book's .sdr/assets/attachables, which
# is where the Kindle stores extra pieces, and added.
# 0 = complete (possibly after adding pieces), 1 = still missing a piece.

# Little-endian writers and a STORED zip, proven on this device by Probe29:
# built in shell, read back byte-for-byte by the Kindle's own unzip.
_cwa_byte() { printf "\\$(printf '%03o' "$(( $1 & 255 ))")"; }
_cwa_le16() { _cwa_byte "$1"; _cwa_byte "$(( $1 >> 8 ))"; }
_cwa_le32() { _cwa_byte "$1"; _cwa_byte "$(( $1 >> 8 ))"; _cwa_byte "$(( $1 >> 16 ))"; _cwa_byte "$(( $1 >> 24 ))"; }
_cwa_crc32() {   # gzip's trailer carries the same CRC-32 zip uses
    set -- $(gzip -c < "$1" | tail -c 8 | od -An -tu1)
    echo $(( $1 + ($2 << 8) + ($3 << 16) + ($4 << 24) ))
}
cwa_mkzip() {   # $1 = output, rest = files (stored under their base names)
    _mz_out=$1; shift
    : > "$_mz_out"; : > "$_mz_out.cd"
    _mz_n=0; _mz_off=0
    for _mz_f in "$@"; do
        _mz_name=$(basename "$_mz_f"); _mz_len=${#_mz_name}
        _mz_size=$(wc -c < "$_mz_f" | tr -d ' '); _mz_crc=$(_cwa_crc32 "$_mz_f")
        {   _cwa_le32 67324752; _cwa_le16 10; _cwa_le16 0; _cwa_le16 0
            _cwa_le16 0; _cwa_le16 33
            _cwa_le32 "$_mz_crc"; _cwa_le32 "$_mz_size"; _cwa_le32 "$_mz_size"
            _cwa_le16 "$_mz_len"; _cwa_le16 0
            printf '%s' "$_mz_name"; cat "$_mz_f"
        } >> "$_mz_out"
        {   _cwa_le32 33639248; _cwa_le16 20; _cwa_le16 10; _cwa_le16 0; _cwa_le16 0
            _cwa_le16 0; _cwa_le16 33
            _cwa_le32 "$_mz_crc"; _cwa_le32 "$_mz_size"; _cwa_le32 "$_mz_size"
            _cwa_le16 "$_mz_len"; _cwa_le16 0; _cwa_le16 0
            _cwa_le16 0; _cwa_le16 0; _cwa_le32 0
            _cwa_le32 "$_mz_off"
            printf '%s' "$_mz_name"
        } >> "$_mz_out.cd"
        _mz_off=$(( _mz_off + 30 + _mz_len + _mz_size )); _mz_n=$(( _mz_n + 1 ))
    done
    _mz_cds=$(wc -c < "$_mz_out.cd" | tr -d ' ')
    cat "$_mz_out.cd" >> "$_mz_out"; rm -f "$_mz_out.cd"
    {   _cwa_le32 101010256; _cwa_le16 0; _cwa_le16 0; _cwa_le16 "$_mz_n"; _cwa_le16 "$_mz_n"
        _cwa_le32 "$_mz_cds"; _cwa_le32 "$_mz_off"; _cwa_le16 0
    } >> "$_mz_out"
}

cwa_complete() {   # $1 = kfx-zip, $2 = asin (to find the .sdr); sets CWA_LAST
    _cc_zip=$1; _cc_w="$CWA_WORK/$2.$$"
    rm -rf "$_cc_w"; mkdir -p "$_cc_w" || { CWA_LAST="no work space"; return 1; }
    if ! ( cd "$_cc_w" && unzip -o -q "$_cc_zip" ) >/dev/null 2>&1; then
        rm -rf "$_cc_w"; CWA_LAST="cannot open the archive"; return 1
    fi
    : > "$_cc_w/.req"; : > "$_cc_w/.have"
    for _cc_f in "$_cc_w"/*; do
        [ -f "$_cc_f" ] || continue
        grep -ao 'CR![A-Z0-9]\{28\}' "$_cc_f" >> "$_cc_w/.req"
        case "$(basename "$_cc_f")" in
            CR!*.kfx) basename "$_cc_f" .kfx >> "$_cc_w/.have" ;;
            *)        grep -ao 'CR![A-Z0-9]\{28\}' "$_cc_f" | head -1 >> "$_cc_w/.have" ;;
        esac
    done
    sort -u "$_cc_w/.req" -o "$_cc_w/.req"; sort -u "$_cc_w/.have" -o "$_cc_w/.have"
    _cc_miss=$(grep -vxF -f "$_cc_w/.have" "$_cc_w/.req")
    # Remember what this book is made of, for the Books list: it cannot
    # afford to unzip every archive each time the screen is drawn.
    _cc_rn=$(wc -l < "$_cc_w/.req" | tr -d ' ')
    _cc_mn=$(printf '%s\n' "$_cc_miss" | grep -c 'CR!')
    cwa_record_parts "$2" "$_cc_rn" "$((_cc_rn - _cc_mn))"
    if [ -z "$_cc_miss" ]; then
        CWA_LAST="complete ($(wc -l < "$_cc_w/.have" | tr -d ' ') part(s))"
        rm -rf "$_cc_w"; return 0
    fi

    # A sample's sidecar is named ..._<ASIN>_sample.sdr, not ..._<ASIN>.sdr.
    _cc_sdr=$(ls -d "$ITEMS"/*"_$2".sdr "$ITEMS"/*"_$2"_sample.sdr 2>/dev/null | head -1)
    _cc_added=0; _cc_still=""
    for _cc_id in $_cc_miss; do
        if [ -n "$_cc_sdr" ] && [ -f "$_cc_sdr/assets/attachables/$_cc_id.kfx" ]; then
            cp "$_cc_sdr/assets/attachables/$_cc_id.kfx" "$_cc_w/" && _cc_added=$((_cc_added + 1))
        else
            _cc_still="$_cc_still $_cc_id"
        fi
    done
    if [ -n "$_cc_still" ]; then
        rm -rf "$_cc_w"
        CWA_LAST="missing $(echo $_cc_still | wc -w | tr -d ' ') part(s), not on this Kindle yet"
        return 1
    fi

    # Rebuild with the added pieces. The dot-files are bookkeeping, not entries.
    rm -f "$_cc_w/.req" "$_cc_w/.have"
    cwa_mkzip "$_cc_zip.new" "$_cc_w"/*
    _cc_in=$(ls "$_cc_w" | wc -l | tr -d ' ')
    _cc_out=$(unzip -l "$_cc_zip.new" 2>/dev/null | awk 'END {print $2}')
    rm -rf "$_cc_w"
    if [ "$_cc_in" = "$_cc_out" ]; then
        mv "$_cc_zip.new" "$_cc_zip"
        CWA_LAST="added $_cc_added missing part(s)"
        return 0
    fi
    rm -f "$_cc_zip.new"
    CWA_LAST="rebuilt archive did not check out ($_cc_out of $_cc_in files)"
    return 1
}
