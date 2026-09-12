#!/usr/bin/env python3
"""Record the ASIN of every ingested book as a native Calibre identifier.

The ASIN comes off the Kindle, so we always know exactly which book we uploaded
-- but CWA renames format files to "Title - Author", so the ASIN is gone by the
time the book exists in Calibre. Reconstructing it from titles was the source of
a wrong match (B012UINHWM, the same book under two series brandings), so this
does not use titles at all.

CWA keeps its own ingest log, and that log preserves the original filename:

    cwa_import(id, timestamp, filename, original_backed_up)
    192 | 2026-09-09 15:53:35 | Surface Tension_ ..._B07SWR82MV | True

Calibre records the same instant as books.timestamp. The two clocks differ by a
constant offset (cwa_import is written in local time, books.timestamp in UTC),
so the pairing is exact to the second once that offset is known. The offset is
DERIVED here rather than hardcoded -- a hardcoded 6h would silently break at the
next DST change, which is exactly how the Kindle sidecar timestamps went wrong.

Run repeatedly; it only writes identifiers that are missing.
"""
import collections
import datetime
import os
import re
import sqlite3
import sys

LIBRARY = os.environ.get("CALIBRE_LIBRARY", "/calibre-library")
CWA_DB = os.environ.get("CWA_DB", "/config/cwa.db")
# The ASIN may be followed by "_sample" before the end, as in
# "..._B007UJPULS_sample". Requiring the end straight after the ASIN missed
# those, which left such a book with no identifier at all -- and a book Calibre
# cannot be matched against is a book the pipeline re-fetches forever.
ASIN_RE = re.compile(r"_(B[A-Z0-9]{9})(?:_sample)?(?:\.[A-Za-z0-9-]+)?$")
EXTS = (".kfx-zip", ".kfx", ".epub", ".azw3", ".mobi")


def sync_key(filename, asin):
    """The key the device and receiver use for this book.

    MUST match sync_key() in receiver.py and key_of() in menu.sh: the ASIN when
    there is one, otherwise the filename minus its extension. A sideloaded book
    carrying a UUID instead of an ASIN only has the second.
    """
    if asin:
        return asin
    base = filename or ""
    for ext in EXTS:
        if base.lower().endswith(ext):
            base = base[:-len(ext)]
            break
    return base.replace("\t", " ").strip()
# CWA's ingest log truncates long filenames at 142 characters, which cuts the
# ASIN in half on books with long titles -- "_B0GG9LSG" instead of "B0GG9LSGVV",
# and once as short as "_B0FQ". The books themselves are fine; only the log is
# clipped. A fragment is still a unique prefix of a real ASIN, so match it
# against the ASINs the Kindle actually reported and require exactly one hit.
PARTIAL_RE = re.compile(r"_(B[A-Z0-9]{1,9})$")
MANIFEST = os.environ.get("ASIN_MANIFEST", "/tmp/asin-manifest.tsv")


def known_asins():
    out = set()
    try:
        with open(MANIFEST) as fh:
            for line in fh:
                a = line.split("\t", 1)[0].strip().upper()
                if len(a) == 10 and a.startswith("B"):
                    out.add(a)
    except OSError:
        pass
    return out


def asin_from(filename, known):
    """Full ASIN if present, else a uniquely-resolvable truncated one."""
    m = ASIN_RE.search(filename or "")
    if m:
        return m.group(1)
    m = PARTIAL_RE.search(filename or "")
    if not m or not known:
        return None
    frag = m.group(1)
    if len(frag) < 4:          # too short to be distinctive
        return None
    hits = [a for a in known if a.startswith(frag)]
    return hits[0] if len(hits) == 1 else None
DRY = os.environ.get("DRY_RUN", "0") == "1"
TOLERANCE = 2.0          # seconds; the pairing is normally exact


def parse_ts(value):
    if not value:
        return None
    text = str(value).strip().replace("T", " ")
    text = re.sub(r"([+-]\d\d):(\d\d)$", "", text)      # drop any offset
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.datetime.strptime(text, fmt)
        except ValueError:
            pass
    return None


def main():
    lib = sqlite3.connect(LIBRARY + "/metadata.db", timeout=30)
    cwa = sqlite3.connect("file:%s?mode=ro" % CWA_DB, uri=True)

    books = []
    for bid, title, ts in lib.execute("select id, title, timestamp from books"):
        t = parse_ts(ts)
        if t:
            books.append((bid, title, t))
    have = {b: v.upper() for b, v in
            lib.execute("select book, val from identifiers where lower(type)='amazon'")}
    # The pipeline's own key, stored on the book. Calibre is the authority for
    # what is synced, and it can only answer for keys it actually holds.
    have_k = {b: v for b, v in
              lib.execute("select book, val from identifiers where lower(type)='kindle'")}

    known = known_asins()
    imports, recovered = [], 0
    for ts, filename in cwa.execute("select timestamp, filename from cwa_import"):
        t = parse_ts(ts)
        if not t:
            continue
        full = ASIN_RE.search(filename or "")
        asin = asin_from(filename, known)
        if asin and not full:
            recovered += 1
        key = sync_key(filename, asin)
        if key:
            imports.append((t, asin, key))
    if recovered:
        print("recovered %d ASIN(s) truncated by CWA's ingest log" % recovered)
    if not imports or not books:
        print("nothing to correlate (imports=%d books=%d)" % (len(imports), len(books)))
        return

    # Derive the clock offset: for the true pairing every delta is identical, so
    # the correct offset is overwhelmingly the most common one.
    deltas = collections.Counter()
    for t, _a, _k in imports:
        for _, _, bt in books:
            d = round((bt - t).total_seconds())
            if abs(d) <= 86400:
                deltas[d] += 1
    if not deltas:
        print("no plausible clock offset found -- not guessing")
        return
    offset, votes = deltas.most_common(1)[0]
    print("clock offset: %+d s (%.1f h), %d supporting pairs" % (offset, offset / 3600.0, votes))

    written = already = ambiguous = unmatched = written_k = 0
    for t, asin, key in sorted(imports, key=lambda r: r[0]):
        target = t + datetime.timedelta(seconds=offset)
        near = [(abs((bt - target).total_seconds()), bid, title)
                for bid, title, bt in books
                if abs((bt - target).total_seconds()) <= TOLERANCE]
        if not near:
            unmatched += 1
            continue
        near.sort()
        if len(near) > 1 and abs(near[0][0] - near[1][0]) < 0.001:
            ambiguous += 1
            print("  ? %s matches %d books at the same instant -- skipped" % (key[:40], len(near)))
            continue
        _, bid, title = near[0]

        # amazon identifier: only for a real ASIN, never overwritten.
        if asin:
            if have.get(bid) == asin:
                already += 1
            elif have.get(bid):
                print("  ! book %s already has %s, refusing to overwrite with %s (%s)"
                      % (bid, have[bid], asin, title[:32]))
            else:
                print("  %s %-12s -> id=%-4s %s" % ("DRY" if DRY else "set", asin, bid, title[:40]))
                if not DRY:
                    lib.execute("insert into identifiers (book, type, val) values (?, 'amazon', ?) "
                                "on conflict(book, type) do update set val=excluded.val", (bid, asin))
                    have[bid] = asin
                written += 1

        # kindle identifier: the sync key, for every book including ones with
        # no ASIN, so confirmation never depends on a key Calibre lacks.
        if have_k.get(bid) != key:
            if have_k.get(bid):
                print("  ! book %s already keyed %s, refusing %s"
                      % (bid, have_k[bid][:30], key[:30]))
            else:
                print("  %s kindle=%-24s -> id=%-4s %s"
                      % ("DRY" if DRY else "set", key[:24], bid, title[:32]))
                if not DRY:
                    lib.execute("insert into identifiers (book, type, val) values (?, 'kindle', ?) "
                                "on conflict(book, type) do update set val=excluded.val", (bid, key))
                    have_k[bid] = key
                written_k += 1
    if not DRY:
        lib.commit()
    total = lib.execute("select count(*) from identifiers where lower(type)='amazon'").fetchone()[0]
    total_k = lib.execute("select count(*) from identifiers where lower(type)='kindle'").fetchone()[0]
    print("written=%d kindle=%d already=%d ambiguous=%d no-book-at-that-time=%d  "
          "totals amazon=%d kindle=%d"
          % (written, written_k, already, ambiguous, unmatched, total, total_k))


if __name__ == "__main__":
    main()
