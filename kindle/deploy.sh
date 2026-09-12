#!/bin/sh
# deploy.sh -- stamp a build number and copy KFX Sync to the mounted Kindle.
#
# The build number is the deploy time, mmddyyyy.hhmm, written into menu.sh's
# KFX_BUILD line and shown at the top right of the menu. It is stamped only
# when the Kindle is actually mounted, so a number on screen always means
# "this exact code is on the device" -- the repo copy carries the same stamp.
#
# Usage: kindle/deploy.sh            (from anywhere)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
KINDLE=${KINDLE:-/Volumes/Kindle}
EXT="$KINDLE/extensions/kfx-sync"
DOCS="$KINDLE/documents"
FILES="menu.sh cwa.sh kfx-daemon.sh launch.sh kual-status.sh"
# menu.json is what KUAL reads, if KUAL is installed; it is inert otherwise.
DATA="menu.json"
# The way in without KUAL: a scriptlet in documents/, whose "# Name:" header
# makes it appear in the library as a book you open. It only runs launch.sh.
LAUNCHER="KFX Sync.sh"
LAUNCHER_AS="00 KFX Sync.sh"

[ -d "$EXT" ] || { echo "Kindle not mounted at $KINDLE -- nothing stamped or copied."; exit 1; }

for f in $FILES "$LAUNCHER"; do
    sh -n "$HERE/$f" || { echo "syntax error in $f -- not deploying"; exit 1; }
done

BUILD=$(date +%m%d%Y.%H%M)
grep -q '^KFX_BUILD=' "$HERE/menu.sh" || { echo "menu.sh has no KFX_BUILD line"; exit 1; }
sed -i '' "s/^KFX_BUILD=.*/KFX_BUILD=$BUILD   # stamped by deploy.sh: mmddyyyy.hhmm of the deploy/" "$HERE/menu.sh"
sh -n "$HERE/menu.sh"

for f in $FILES $DATA; do
    cp "$HERE/$f" "$EXT/$f"
    cmp -s "$HERE/$f" "$EXT/$f" || { echo "copy of $f did not verify"; exit 1; }
    echo "  $f"
done
chmod +x "$EXT/launch.sh" "$EXT/kual-status.sh" 2>/dev/null || :
# The launcher carries no build number and changes almost never, so only copy
# it when it differs -- a needless write shows up as a "new book" on the device.
if [ -d "$DOCS" ] && ! cmp -s "$HERE/$LAUNCHER" "$DOCS/$LAUNCHER_AS"; then
    cp "$HERE/$LAUNCHER" "$DOCS/$LAUNCHER_AS"
    cmp -s "$HERE/$LAUNCHER" "$DOCS/$LAUNCHER_AS" || { echo "copy of $LAUNCHER_AS did not verify"; exit 1; }
    echo "  $LAUNCHER_AS (launcher, in documents/)"
fi

echo "build $BUILD deployed to $EXT"
echo "eject the Kindle, then press Q in KFX Sync and relaunch it to load this build."
