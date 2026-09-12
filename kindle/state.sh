# state.sh -- one record per book, and the only place that says what happened.
#
# There used to be seven stores: .failed, cwa.uploads, cwa.held, cwa.parts,
# recover-books, .inflight and a pair of /tmp lists. Each knew part of a book's
# story and nothing kept them in step, so they disagreed. .failed was
# append-only: two books that failed six times, then decrypted, uploaded and
# were purged were still reported as "failed to decrypt", permanently, on the
# screen whose only job is to say what needs attention.
#
# One record per book cannot disagree with itself. Decrypting sets the stage to
# "decrypted" and the earlier failure is gone -- not cleaned up, gone.
#
# Format: tab-separated, one line per key, a version marker on the first line.
#   key       ASIN, ASIN_sample, or the GUID of a book with no ASIN
#   stage     queued downloading stuck decrypted waiting uploaded confirmed
#             failed notkfx
#   since     epoch of the last stage change; the grace windows measure from it
#   tries     uploads sent -- the retry cap for a book Calibre never
#             confirms counts these
#   restarts  UI framework restarts spent on this book (two, then leave it be)
#   need/have pieces the book declares, and pieces gathered
#   note      why, for the stages that need a why
#   title     for the screen; "-" when unknown
#
# Tabs because titles carry spaces, semicolons and commas. A field is never
# empty -- "-" stands in -- so a short line cannot be mistaken for a long one.
STATE_FILE=${STATE_FILE:-/mnt/us/dedrm/books.tsv}
STATE_VERSION=1
STATE_MARK="#shelfback-state"

st_init() {
    [ -s "$STATE_FILE" ] && return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
    printf '%s %s\n' "$STATE_MARK" "$STATE_VERSION" > "$STATE_FILE" 2>/dev/null
}

# Read-modify-write in one awk run, then rename. The menu and the daemon both
# write this file; a short window is not no window, but it is one process
# lifetime rather than the read-think-write of a shell pipeline.
st_set() {   # $1 = key, then name=value ...
    _ss_k=$1; shift
    [ -n "$_ss_k" ] && [ $# -gt 0 ] || return 0
    st_init
    # The pairs go through a file, not through awk -v: -v rejects an embedded
    # newline outright ("newline in string"), so every multi-field write failed
    # silently and left the record untouched. A file has no escaping rules.
    _ss_f="$STATE_FILE.kv.$$"
    for _ss_a in "$@"; do printf '%s\n' "$_ss_a"; done > "$_ss_f" 2>/dev/null
    awk -F'\t' -v OFS='\t' -v key="$_ss_k" -v now="$(date +%s)" '
    function idx(n) {
        if (n == "stage")    return 2
        if (n == "since")    return 3
        if (n == "tries")    return 4
        if (n == "restarts") return 5
        if (n == "need")     return 6
        if (n == "have")     return 7
        if (n == "note")     return 8
        if (n == "title")    return 9
        return 0
    }
    NR == FNR {                      # first file: the name=value pairs
        eq = index($0, "=")
        if (eq > 1) {
            n = substr($0, 1, eq - 1); v = substr($0, eq + 1)
            gsub(/\t/, " ", v)
            if (v == "") v = "-"
            want[n] = v
        }
        next
    }
    /^#/ { print; next }
    $1 == key {
        found = 1
        was = $2
        for (n in want) { j = idx(n); if (j) $j = want[n] }
        # A stage change restamps "since" -- the grace windows measure from it,
        # so re-recording the same stage must NOT slide the window forward.
        if (("stage" in want) && !("since" in want) && want["stage"] != was) $3 = now
        print
        next
    }
    { print }
    END {
        if (found) exit
        # A record that did not exist: defaults, then what the caller asked for.
        $1 = key; $2 = "queued"; $3 = now; $4 = 0; $5 = 0; $6 = 0; $7 = 0
        $8 = "-"; $9 = "-"
        for (n in want) { j = idx(n); if (j) $j = want[n] }
        print
    }' "$_ss_f" "$STATE_FILE" > "$STATE_FILE.new.$$" 2>/dev/null
    rm -f "$_ss_f"
    # An empty result would mean losing every record, so refuse it. Testing the
    # exit status instead of the file has bitten this script twice.
    if [ -s "$STATE_FILE.new.$$" ]; then
        mv "$STATE_FILE.new.$$" "$STATE_FILE" 2>/dev/null
    else
        rm -f "$STATE_FILE.new.$$"
        return 1
    fi
    return 0
}

st_line() {   # $1 = key -- the whole record, or nothing
    [ -s "$STATE_FILE" ] || return 1
    awk -F'\t' -v key="$1" '$1 == key { print; found = 1; exit } END { exit !found }' \
        "$STATE_FILE" 2>/dev/null
}

st_get() {   # $1 = key, $2 = field name -- prints "" when absent
    [ -s "$STATE_FILE" ] || return 1
    awk -F'\t' -v key="$1" -v want="$2" '
        function idx(n) {
            if (n == "stage") return 2; if (n == "since")    return 3
            if (n == "tries") return 4; if (n == "restarts") return 5
            if (n == "need")  return 6; if (n == "have")     return 7
            if (n == "note")  return 8; if (n == "title")    return 9
            return 0 }
        $1 == key { j = idx(want); if (j) print $j; found = 1; exit }
        END { exit !found }' "$STATE_FILE" 2>/dev/null
}

st_stage() { st_get "$1" stage; }

st_bump() {   # $1 = key, $2 = field name -- add one, atomically enough
    _sb_n=$(st_get "$1" "$2" 2>/dev/null)
    case "$_sb_n" in ''|*[!0-9]*) _sb_n=0 ;; esac
    st_set "$1" "$2=$(( _sb_n + 1 ))"
}

st_keys() {   # no argument: every key. With one: every key at that stage.
    [ -s "$STATE_FILE" ] || return 0
    awk -F'\t' -v want="${1:-}" '!/^#/ && NF > 1 && (want == "" || $2 == want) { print $1 }' \
        "$STATE_FILE" 2>/dev/null
}

st_count() { st_keys "${1:-}" | wc -l | tr -d ' '; }

st_drop() {   # $1 = key -- forget a book entirely (purged, or never ours)
    [ -s "$STATE_FILE" ] || return 0
    awk -F'\t' -v key="$1" '$1 != key' "$STATE_FILE" > "$STATE_FILE.new.$$" 2>/dev/null
    if [ -s "$STATE_FILE.new.$$" ]; then
        mv "$STATE_FILE.new.$$" "$STATE_FILE" 2>/dev/null
    else
        rm -f "$STATE_FILE.new.$$"
    fi
    return 0
}

# Has this book been at its current stage longer than $2 seconds?
st_older_than() {   # $1 = key, $2 = seconds
    _so_t=$(st_get "$1" since 2>/dev/null)
    case "$_so_t" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $(date +%s) - _so_t )) -ge "$2" ]
}

# ---------------- migration ----------------
# Fold the seven old stores into the record, once, then rename them .imported
# so a later run does not undo an edit the new code has since made. Runs on
# first use; costs nothing afterwards.
#
# .failed is deliberately NOT imported. It was append-only and, by the time
# this shipped, every entry in it was for a book that had long since decrypted,
# uploaded and been purged -- importing it would carry the exact wrong answer
# into the file meant to fix it. A book that still cannot be decrypted will
# fail again on the next pass and say so then.
st_migrate() {
    _sm_o=${1:-/mnt/us/dedrm}
    _sm_s=${2:-/var/local/kfx-state}
    [ -f "$STATE_FILE.imported" ] && return 0
    st_init

    # what we sent, and when            "<key>\t<epoch>\t<name>"
    if [ -s "$_sm_s/cwa.uploads" ]; then
        while IFS="$(printf '\t')" read -r _sm_k _sm_t _sm_n; do
            [ -n "$_sm_k" ] || continue
            st_set "$_sm_k" stage=uploaded "since=$_sm_t" "title=${_sm_n:--}"
        done < "$_sm_s/cwa.uploads"
    fi
    # books waiting on a piece          "<ASIN> <epoch first held>"
    if [ -s "$_sm_s/cwa.held" ]; then
        while read -r _sm_k _sm_t; do
            [ -n "$_sm_k" ] || continue
            st_set "$_sm_k" stage=waiting "since=$_sm_t"
        done < "$_sm_s/cwa.held"
    fi
    # pieces                            "<ASIN> <needed> <present>"
    if [ -s "$_sm_s/cwa.parts" ]; then
        while read -r _sm_k _sm_need _sm_have; do
            [ -n "$_sm_k" ] || continue
            st_set "$_sm_k" "need=${_sm_need:-0}" "have=${_sm_have:-0}"
        done < "$_sm_s/cwa.parts"
    fi
    # UI restarts spent per book        "<ASIN> <count> <epoch>"
    if [ -s "$_sm_s/recover-books" ]; then
        while read -r _sm_k _sm_n _sm_t; do
            [ -n "$_sm_k" ] || continue
            st_set "$_sm_k" "restarts=${_sm_n:-0}"
        done < "$_sm_s/recover-books"
    fi

    for _sm_f in "$_sm_s/cwa.uploads" "$_sm_s/cwa.held" "$_sm_s/cwa.parts" \
                 "$_sm_s/recover-books" "$_sm_o/.failed"; do
        [ -f "$_sm_f" ] && mv "$_sm_f" "$_sm_f.imported" 2>/dev/null
    done
    : > "$STATE_FILE.imported" 2>/dev/null
    return 0
}
