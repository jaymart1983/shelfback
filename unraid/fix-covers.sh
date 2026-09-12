#!/bin/bash
# Swap greyscale Kindle covers for Amazon colour art.
#
SRC=/mnt/main/data/book-receiver/fix-covers.py
# Shares baseline-jpegs.sh's lock: both rewrite cover.jpg, and a baseline pass
# that read a cover just before this replaced it would put the old art back.
exec 9>/var/run/kfx-baseline.lock || exit 0
flock -n 9 || exit 0
docker cp "$SRC" calibre-web-automated:/tmp/fix-covers.py     >/dev/null || exit 1
docker exec calibre-web-automated python3 /tmp/fix-covers.py "$@"
