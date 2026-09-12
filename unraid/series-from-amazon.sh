#!/bin/bash
# Fill in series/series_index from Amazon, keyed by ASIN.
#
# Idle cost is one SQL query: it only looks at books that have an ASIN and no
# series, so a run with nothing new exits immediately. That is why it can run
# every few minutes.
#
# A backfill over the whole library takes ~20 minutes though, because Amazon
# rate-limits and the script retries with backoff. Without a lock, cron would
# stack a second copy on top of a first and several processes would hammer
# Amazon at once -- making the rate-limiting worse and the retries pointless.
LOCK=/var/run/kfx-series.lock
SRC=/mnt/main/data/book-receiver/series-from-amazon.py

exec 9>"$LOCK" || exit 0
flock -n 9 || exit 0          # a run is already going; nothing to do

docker cp "$SRC" calibre-web-automated:/config/series-from-amazon.py >/dev/null || exit 1
docker exec -u abc -e CALIBRE_CONFIG_DIRECTORY=/config/.config/calibre \
    calibre-web-automated python3 /config/series-from-amazon.py "$@"
