#!/bin/sh
# The launcher. It finds kterm and opens the front end inside it so the
# on-screen keyboard is available.
#
# Two things start this, and neither needs the other:
#   KUAL         -- menu.json next to this file, action "launch.sh"
#   a scriptlet  -- documents/"00 KFX Sync.sh", which just runs this
# KUAL is not installed on every jailbroken Kindle, and the scriptlet works
# without it, so the real launcher lives here and both entry points are thin.
#
# kterm's -e takes ONE argument that it splits itself, and it cannot cope with a
# path containing spaces -- which is why everything it runs lives at a
# space-free path under extensions/, and only the scriptlet is named for
# reading.
# kterm must also stay under /mnt/us/extensions or the keyboard silently fails
# to appear (documented by the KFX DeDRM project, learned the hard way).

MENU=/mnt/us/extensions/kfx-sync/menu.sh
DIAG=/mnt/us/kfxsync-launch.log

# Record what happens here: if kterm fails or the front end dies immediately the
# screen just goes blank, with nothing to go on.
: > "$DIAG"
d() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$DIAG"; }
d "launcher start (shell=$0)"

find_kterm() {
    configured=${KTERM_PATH:-}
    if [ -n "$configured" ] && [ -x "$configured" ]; then printf '%s\n' "$configured"; return 0; fi
    for c in /mnt/us/extensions/kterm/bin/kterm \
             /mnt/us/kterm/bin/kterm \
             /mnt/us/extensions/*/bin/kterm \
             /mnt/us/*/bin/kterm; do
        [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

KTERM=$(find_kterm)
d "kterm=${KTERM:-<none>}"
d "menu exists: $([ -f "$MENU" ] && echo yes || echo NO)"
d "menu readable: $([ -r "$MENU" ] && echo yes || echo NO)"
d "sh=$(command -v sh)"
if [ -z "$KTERM" ] || [ ! -x "$KTERM" ]; then
    d "FATAL: no kterm"
    printf '\nKFX Sync: no kterm found.\n'
    printf 'Install kterm under /mnt/us/extensions/kterm/.\n'
    sleep 8
    exit 1
fi
if [ ! -f "$MENU" ]; then
    d "FATAL: menu missing"
    printf '\nKFX Sync: front end missing:\n%s\n' "$MENU"
    sleep 8
    exit 1
fi

# -k 1 keyboard on, -o U upright, -s 7 small font (more columns), UTF-8 titles
d "launching: $KTERM -e \"sh $MENU\" -k 1 -o U -s 7 -t UTF-8"
started=$(date +%s)
"$KTERM" -e "sh $MENU" -k 1 -o U -s 7 -t UTF-8 >>"$DIAG" 2>&1
rc=$?
elapsed=$(( $(date +%s) - started ))
d "kterm exited rc=$rc after ${elapsed}s"

# Only fall back to an inline run if kterm died *immediately* -- i.e. it never
# really started. Falling back unconditionally re-launches the menu every time
# the user quits normally, which looks exactly like being stuck in a loop.
if [ "$elapsed" -lt 5 ]; then
    d "kterm failed to start; running front end inline (no keyboard)"
    sh "$MENU" 2>>"$DIAG"
    d "inline run exited rc=$?"
else
    d "normal exit; not falling back"
fi
exit 0
