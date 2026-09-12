#!/bin/bash
# Convert progressive JPEGs to baseline, losslessly -- see baseline-jpegs.py.
#
# One lock for every caller. The cron job (recent books) and a full-library run
# must never rewrite the same epub at the same time, so both go through here;
# whichever gets the lock second simply exits.
LOCK=/var/run/kfx-baseline.lock
SRC=/mnt/main/data/book-receiver/baseline-jpegs.py
exec 9>"$LOCK" || exit 0
flock -n 9 || exit 0
docker cp "$SRC" calibre-web-automated:/config/baseline-jpegs.py >/dev/null || exit 1
docker exec -u abc calibre-web-automated python3 /config/baseline-jpegs.py "$@"
