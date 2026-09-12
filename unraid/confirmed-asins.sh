#!/bin/bash
# Publish the list of ASINs Calibre genuinely holds, so the Kindle can safely
# delete its local copies. Written to the books share where the receiver can
# serve it. Strict by design -- see confirmed-asins.py.
CT=${CT:-calibre-web-automated}
BOOKS=${BOOKS:-/mnt/remotes/main-share/Books/calibre}
SCRIPT=${SCRIPT:-/mnt/main/data/book-receiver/confirmed-asins.py}
TAG=confirmed-asins

docker ps --format '{{.Names}}' | grep -qx "$CT" || { logger -t "$TAG" -- "$CT not running"; exit 1; }
out=$(docker exec -i -e CONFIRMED_OUT=/tmp/confirmed.txt "$CT" python3 - < "$SCRIPT" 2>&1) || {
    logger -t "$TAG" -- "generation failed: $out"; exit 1; }
docker cp "$CT:/tmp/confirmed.txt" /tmp/confirmed.$$ >/dev/null 2>&1 || { logger -t "$TAG" -- "copy out failed"; exit 1; }
docker exec "$CT" rm -f /tmp/confirmed.txt >/dev/null 2>&1

# Never publish an empty or implausibly short list: the Kindle deletes against
# it, so a truncated list would simply fail to authorise deletions (safe), but an
# EMPTY one after a DB hiccup would look like "nothing is confirmed" forever.
n=$(wc -l < /tmp/confirmed.$$ | tr -d ' ')
if [ "${n:-0}" -lt 1 ]; then
    logger -t "$TAG" -- "refusing to publish an empty confirmation list"
    rm -f /tmp/confirmed.$$; exit 1
fi
mv /tmp/confirmed.$$ "$BOOKS/.confirmed-asins"
chmod 644 "$BOOKS/.confirmed-asins" 2>/dev/null
logger -t "$TAG" -- "$out ($n published)"
