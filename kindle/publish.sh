#!/bin/sh
# publish.sh -- stamp a release so the device can install it over the air.
#
# VERSION and menu.sh's KFX_BUILD must carry the SAME number. The updater
# refuses a release where they disagree, because a CDN serves the files and the
# version marker as separate objects that refresh independently: minutes after
# a push, menu.sh can be the new build while VERSION is still the old one, or
# the reverse. The reverse is the dangerous one -- the device would install
# stale files under a new number -- so the code carries its own version and the
# two are checked against each other.
#
# deploy.sh does the same stamping for a USB install. This is for publishing
# without a cable:
#
#   kindle/publish.sh            stamp, check, and show what to commit
#   kindle/publish.sh --commit   stamp, check, commit and push
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$(date +%m%d%Y.%H%M)

# Checked before anything is stamped: a refusal must leave the tree as it was,
# not sitting on a version number that was never published.
if [ "${1:-}" = "--commit" ]; then
    _dirty=$(cd "$HERE/.." && git status --porcelain -- . \
             | grep -v 'kindle/VERSION\|kindle/menu.sh\|kindle/SHA256SUMS' || true)
    if [ -n "$_dirty" ]; then
        echo "refusing: commit these first, or they are not in the release"
        printf '%s\n' "$_dirty" | sed 's/^/  /'
        exit 1
    fi
fi

for f in menu.sh cwa.sh state.sh kfx-daemon.sh kfx-update.sh launch.sh kual-status.sh; do
    sh -n "$HERE/$f" || { echo "syntax error in $f -- not publishing"; exit 1; }
done

grep -q '^KFX_BUILD=' "$HERE/menu.sh" || { echo "menu.sh has no KFX_BUILD line"; exit 1; }
sed -i '' "s/^KFX_BUILD=.*/KFX_BUILD=$BUILD   # published by publish.sh/" "$HERE/menu.sh"
sh -n "$HERE/menu.sh" || { echo "stamping broke menu.sh"; exit 1; }
printf '%s\n' "$BUILD" > "$HERE/VERSION"

# Regenerate checksums over the MANIFEST files, after stamping.
: > "$HERE/SHA256SUMS"
while read -r _mf; do case "$_mf" in ""|\#*) continue ;; esac
    ( cd "$HERE" && shasum -a 256 "$_mf" ) >> "$HERE/SHA256SUMS"
done < "$HERE/MANIFEST"

# The check the device will make, made here first.
_b=$(sed -n 's/^KFX_BUILD=\([0-9.]*\).*/\1/p' "$HERE/menu.sh" | head -1)
[ "$_b" = "$BUILD" ] || { echo "stamp did not take: menu.sh says $_b"; exit 1; }

echo "release $BUILD"
if [ "${1:-}" = "--commit" ]; then
    cd "$HERE/.."
    git add kindle/VERSION kindle/menu.sh kindle/SHA256SUMS
    git commit -q -m "Release $BUILD"
    git push -q origin main
    echo "pushed. The CDN may serve the old files for a few minutes;"
    echo "the device will wait rather than install a half-published release."
else
    echo "commit kindle/VERSION and kindle/menu.sh to publish it."
fi
