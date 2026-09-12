#!/usr/bin/env python3
"""
Replace greyscale library covers with Amazon colour art.

Books arriving from a Kindle carry greyscale, e-ink-optimised covers -- that is
what Amazon ships to the device, so nothing upstream can recover the colour.
Every Kindle book carries its ASIN in Calibre (amazon identifier, and the
kindle sync key), which addresses the cover exactly. Titles are never compared:
a book with no ASIN is skipped, not guessed at.

Run inside the CWA container:  python3 fix-covers.py [--dry-run]
"""
import os, re, sqlite3, struct, subprocess, sys
from datetime import datetime, timezone

LIB      = "/calibre-library"
APPDB    = "/config/app.db"
DRY      = "--dry-run" in sys.argv


# The reader renders covers full-screen at 480x720 and dithers to 4 grey levels.
# A cover that has to be UPSCALED into that has less than one source pixel per
# output pixel, so the dither has no real intermediate tone to work with and
# fine detail turns to mud. Anything that downscales looks fine. 800px on the
# long edge is the floor; Amazon's _SCRM_ gives 1600x2400.
MIN_LONG_EDGE = int(os.environ.get("MIN_COVER_EDGE", 800))

# _SCLZZZZZZZ_ caps out around 333x500 -- it is a thumbnail, and using it is
# what shrank 168 of 180 covers in this library. _SCRM_ serves the full art.
# Order matters: the ".01." form returns the full art, the bare form returns the
# same thumbnail as _SCLZZZZZZZ_. Measured on B0C4JMJBNX -- 1600x2400 vs 333x500.
COVER_URLS = [
    "https://m.media-amazon.com/images/P/%s.01._SCRM_.jpg",
    "https://m.media-amazon.com/images/P/%s._SCRM_.jpg",
    "https://m.media-amazon.com/images/P/%s.01._SCLZZZZZZZ_.jpg",
]


def dimensions(path):
    """(width, height) of a JPEG, or None."""
    try:
        d = open(path, "rb").read()
    except OSError:
        return None
    i = 2
    while i < len(d) - 1:
        if d[i] != 0xFF:
            i += 1; continue
        m = d[i+1]
        if m in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", d[i+5:i+9])
            return (w, h)
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2; continue
        i += 2 + struct.unpack(">H", d[i+2:i+4])[0]
    return None


JPEGTRAN = os.environ.get("JPEGTRAN", "/app/calibre/bin/jpegtran")


def is_progressive(path):
    try:
        d = open(path, "rb").read()
    except OSError:
        return False
    i = 2
    while i < len(d) - 1:
        if d[i] != 0xFF:
            i += 1; continue
        m = d[i+1]
        if m in (0xC0, 0xC1):
            return False
        if m == 0xC2:
            return True
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2; continue
        i += 2 + struct.unpack(">H", d[i+2:i+4])[0]
    return False


def make_baseline(path):
    """Rewrite a progressive JPEG as baseline, losslessly, in place.

    Amazon's full-size _SCRM_ art is progressive, and the X4 Pro decodes a
    progressive JPEG at 1/8 resolution -- so without this, fetching the bigger
    cover is what made it render blocky. jpegtran transcodes the existing DCT
    coefficients; the pixels do not change.
    """
    if not is_progressive(path):
        return True
    # This jpegtran keeps progressive mode unless handed a scan script; one
    # interleaved full-spectrum scan is exactly baseline structure (SOF0).
    d = open(path, "rb").read()
    n, i = 0, 2
    while i < len(d) - 1:
        if d[i] != 0xFF:
            i += 1; continue
        m = d[i+1]
        if m in (0xC0, 0xC1, 0xC2):
            n = d[i + 9]; break
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2; continue
        i += 2 + struct.unpack(">H", d[i+2:i+4])[0]
    if not 1 <= n <= 4:
        return False
    out, scans = path + ".bl", path + ".scans"
    with open(scans, "w") as fh:
        fh.write("%s: 0 63 0 0;\n" % " ".join(str(c) for c in range(n)))
    env = dict(os.environ, LD_LIBRARY_PATH="/app/calibre/lib:" + os.environ.get("LD_LIBRARY_PATH", ""))
    r = subprocess.run([JPEGTRAN, "-copy", "all", "-optimize", "-scans", scans,
                        "-outfile", out, path], capture_output=True, env=env)
    os.remove(scans)
    if r.returncode != 0 or not os.path.exists(out) or is_progressive(out):
        if os.path.exists(out):
            os.remove(out)
        return False
    os.replace(out, path)
    return True


def components(path):
    """JPEG colour components: 3 = colour, 1 = greyscale."""
    try:
        d = open(path, "rb").read()
    except OSError:
        return None
    i = 2
    while i < len(d) - 1:
        if d[i] != 0xFF:
            i += 1; continue
        m = d[i+1]
        if m in (0xC0, 0xC1, 0xC2):
            return d[i+9]
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2; continue
        i += 2 + struct.unpack(">H", d[i+2:i+4])[0]
    return None


def touch_book(con, bid):
    """Mark a book changed, the way calibre does when its cover is set.

    OPDS <updated> is books.last_modified, and readers decide what to
    re-download from it (plus length). A cover-only change never moved it, so
    readers kept serving their old copy. Call this only when a file was
    actually replaced -- every bump costs each reader a full re-download.

    calibre's books_update_trg calls title_sort(), which exists only inside
    calibre. It fires only when the title changes, so a pass-through stand-in
    satisfies the trigger and is never actually called.
    """
    con.create_function("title_sort", 1, lambda t: t)
    now = datetime.now(timezone.utc).isoformat(sep=" ", timespec="microseconds")
    con.execute("update books set last_modified=? where id=?", (now, bid))


def main():
    con = sqlite3.connect(f"{LIB}/metadata.db")
    # Calibre already stores the ASIN as an identifier for anything that came
    # off the Kindle. That is the book -- exactly, not probably -- so use it and
    # never guess from the title. Title similarity cannot tell one volume of a
    # series from another, which is why books with a perfectly good ASIN on
    # record were being skipped at "best 0.40".
    ident = {}
    for bid, kind, val in con.execute(
            "select book, lower(type), upper(trim(val)) from identifiers "
            "where lower(type) in ('amazon', 'kindle')"):
        if re.match(r"^B[A-Z0-9]{9}$", val) and (kind == "amazon" or bid not in ident):
            ident[bid] = val

    todo = []
    for bid, title, path in con.execute("select id,title,path from books"):
        cover = os.path.join(LIB, path, "cover.jpg")
        if not os.path.exists(cover):
            continue
        d = dimensions(cover)
        too_small = (not d) or max(d) < MIN_LONG_EDGE
        if components(cover) == 3 and not too_small:
            continue
        asin = ident.get(bid)
        if not asin:
            # No ASIN, no cover. Titles are never compared: similarity cannot
            # tell one volume of a series from the next, and a wrong match
            # puts the wrong art on a book with nothing to show it happened.
            print(f"  skip [{bid}] {title[:44]} -- no ASIN in Calibre")
            continue
        todo.append((bid, title, asin, cover))

    print(f"  {len(todo)} greyscale cover(s) with a known ASIN")
    fixed = []
    for bid, title, asin, cover in todo:
        # Stage in the destination directory: /tmp is a different filesystem to
        # the library, and os.replace cannot cross one (EXDEV). Same-dir staging
        # also keeps the swap atomic, so a half-downloaded cover never lands.
        tmp = cover + ".new"
        have = dimensions(cover) or (0, 0)
        was_grey = components(cover) != 3
        size = 0
        for pattern in COVER_URLS:
            url = pattern % asin
            subprocess.run(["curl", "-sS", "-o", tmp, "--max-time", "40", url], check=False)
            size = os.path.getsize(tmp) if os.path.exists(tmp) else 0
            got = dimensions(tmp)
            # Amazon serves a tiny placeholder rather than a 404 when it has
            # no art, so judge by the image, not the HTTP status.
            if size > 8000 and components(tmp) == 3 and got and max(got) >= MIN_LONG_EDGE:
                break
        if os.path.exists(tmp) and size > 8000:
            make_baseline(tmp)
        got = dimensions(tmp) if os.path.exists(tmp) else None
        # Replace only on a real improvement: grey -> colour, or strictly
        # larger. Accepting an equal-size image (>=) meant books with no
        # full-size Amazon art re-downloaded the same thumbnail and rewrote
        # cover.jpg on every cron run.
        improves = was_grey or (got and max(got) > max(have))
        if size > 8000 and components(tmp) == 3 and got and improves:
            if DRY:
                print(f"  WOULD FIX [{bid}] {title[:34]} <- {asin} {got[0]}x{got[1]}")
            else:
                os.replace(tmp, cover)
                fixed.append(bid)
                touch_book(con, bid)    # served epubs embed cover.jpg
                print(f"  fixed [{bid}] {title[:34]} <- {asin} {got[0]}x{got[1]}")
        else:
            print(f"  no better image [{bid}] {title[:34]} ({asin}, {size}B, {got})")
        if os.path.exists(tmp):
            os.remove(tmp)

    # Calibre-Web's grid serves cached thumbnails, so a new cover.jpg is
    # invisible until the cached entry is dropped.
    if fixed and not DRY:
        con.commit()
    if fixed and not DRY:
        try:
            a = sqlite3.connect(APPDB)
            a.execute("delete from thumbnail where entity_id in (%s)"
                      % ",".join("?" * len(fixed)), fixed)
            a.commit(); a.close()
            print(f"  cleared {len(fixed)} cached thumbnail(s)")
        except Exception as exc:
            print(f"  thumbnail cache clear failed: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
