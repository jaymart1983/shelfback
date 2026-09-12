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
FILES="menu.sh cwa.sh kfx-daemon.sh"

[ -d "$EXT" ] || { echo "Kindle not mounted at $KINDLE -- nothing stamped or copied."; exit 1; }

for f in $FILES; do sh -n "$HERE/$f" || { echo "syntax error in $f -- not deploying"; exit 1; }; done

BUILD=$(date +%m%d%Y.%H%M)
grep -q '^KFX_BUILD=' "$HERE/menu.sh" || { echo "menu.sh has no KFX_BUILD line"; exit 1; }
sed -i '' "s/^KFX_BUILD=.*/KFX_BUILD=$BUILD   # stamped by deploy.sh: mmddyyyy.hhmm of the deploy/" "$HERE/menu.sh"
sh -n "$HERE/menu.sh"

for f in $FILES; do
    cp "$HERE/$f" "$EXT/$f"
    cmp -s "$HERE/$f" "$EXT/$f" || { echo "copy of $f did not verify"; exit 1; }
    echo "  $f"
done
echo "build $BUILD deployed to $EXT"
echo "eject the Kindle, then press Q in KFX Sync and relaunch it to load this build."
