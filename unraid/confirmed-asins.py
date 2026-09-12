#!/usr/bin/env python3
"""Write the list of ASINs that are genuinely, fully in Calibre.

The Kindle deletes its local copy of a book once it appears here, so this list
is the safety interlock and it is deliberately strict. A book qualifies only if:

  - Calibre has a book carrying that amazon identifier, and
  - that book has at least one format recorded, and
  - the format file actually exists on disk with a non-trivial size.

"The row exists" is not enough. A book row with a missing or zero-length file
would otherwise authorise deleting the only remaining copy.
"""
import os
import re
import sqlite3
import sys

LIBRARY = os.environ.get("CALIBRE_LIBRARY", "/calibre-library")
OUT = os.environ.get("CONFIRMED_OUT", "/tmp/confirmed-asins.txt")
MIN_BYTES = int(os.environ.get("MIN_BYTES", "20000"))

lib = sqlite3.connect("file:%s/metadata.db?mode=ro" % LIBRARY, uri=True)
paths = dict(lib.execute("select id, path from books"))
ok, rejected = [], []
# Both the amazon identifier and the pipeline's own sync key ("kindle"). The
# receiver treats this list as the authority on what is synced, so it has to
# contain the key the device and receiver actually use -- which for a sideloaded
# book with a UUID is not an ASIN at all. Checking only amazon identifiers is
# what let two books loop: Calibre held them, but under a key nobody asked for.
def norm(v):
    v = (v or "").strip()
    return v.upper() if re.match(r"^[Bb][A-Za-z0-9]{9}$", v) else v


for bid, asin in lib.execute(
        "select book, val from identifiers where lower(type) in ('amazon','kindle')"):
    rows = list(lib.execute(
        "select format, name from data where book=?", (bid,)))
    if not rows:
        rejected.append((asin, bid, "no format recorded"))
        continue
    good = False
    for fmt, name in rows:
        path = os.path.join(LIBRARY, paths.get(bid, ""),
                            "%s.%s" % (name, fmt.lower()))
        try:
            if os.path.getsize(path) >= MIN_BYTES:
                good = True
                break
        except OSError:
            continue
    if good:
        ok.append(norm(asin))
    else:
        rejected.append((asin, bid, "no readable format file"))

tmp = OUT + ".tmp"
with open(tmp, "w") as fh:
    for a in sorted(set(ok)):
        fh.write(a + "\n")
os.replace(tmp, OUT)
print("confirmed %d key(s) in Calibre with a real file; %d rejected"
      % (len(set(ok)), len(rejected)))
for asin, bid, why in rejected[:10]:
    print("  not confirmed: %s (book %s) -- %s" % (asin, bid, why))
