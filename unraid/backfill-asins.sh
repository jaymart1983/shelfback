#!/bin/bash
# Record ASINs as native Calibre identifiers for anything newly ingested.
# Runs inside the CWA container -- the library, cwa.db and python all live there.
CT=${CT:-calibre-web-automated}
SCRIPT=${SCRIPT:-/mnt/main/data/book-receiver/backfill-asins.py}
TAG=backfill-asins

docker ps --format '{{.Names}}' | grep -qx "$CT" || {
    logger -t "$TAG" -- "$CT not running"
    exit 1
}
# The Kindle's own ASIN list, so a filename CWA truncated can still be resolved.
BOOKS=${BOOKS:-/mnt/remotes/main-share/Books/calibre}
[ -s "$BOOKS/.asin-manifest" ] && docker cp "$BOOKS/.asin-manifest" "$CT:/tmp/asin-manifest.tsv" >/dev/null 2>&1
out=$(docker exec -i -e DRY_RUN="${DRY_RUN:-0}" "$CT" python3 - < "$SCRIPT" 2>&1)
docker exec "$CT" rm -f /tmp/asin-manifest.tsv >/dev/null 2>&1
rc=$?
# Log what changed; a clean no-op leaves only the summary line.
printf '%s\n' "$out" | while IFS= read -r line; do
    case "$line" in
        ""|"clock offset:"*) ;;
        "written=0 "*) ;;
        *) logger -t "$TAG" -- "$line" ;;
    esac
done
exit $rc
