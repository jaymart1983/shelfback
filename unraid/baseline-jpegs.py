#!/usr/bin/env python3
"""
Convert progressive JPEGs to baseline, losslessly -- in cover.jpg and in epubs.

WHY
The X4 Pro's decoder (JPEGDEC) cannot fully decode a progressive JPEG: it reads
the DC coefficients only, which is 1/8 resolution. A 1600x2400 progressive cover
arrives on the device as ~200x300 and is then upscaled into blocks. The same
pixels stored as baseline render cleanly.

Most of the progressive covers were put there by fix-covers.py: Amazon's
full-size "_SCRM_" art is progressive, and embed-covers.py copied it into the
epubs. The resolution fix and the progressive problem are the same images.

HOW
calibre ships libjpeg-turbo's jpegtran, which transcodes the existing DCT
coefficients rather than decoding and re-encoding -- the pixels do not change.
One catch, measured 10 Sep 2026: this build KEEPS progressive mode when the
input is progressive, even without -progressive. Handing it a scan script with
a single interleaved full-spectrum scan ("0 1 2: 0 63 0 0;") forces exactly the
baseline structure: SOF0, pixel-identical on a 1600x2400 cover. Every image is
still verified -- both versions decoded and compared -- and anything that does
not come out SOF0 with identical pixels is left alone.

EPUB rules kept: every entry is rewritten in its original order with its
original compression, so "mimetype" stays first and uncompressed. Each book is
written to a sibling temp file and only swapped in after it re-opens cleanly
with every entry present.

Run inside the CWA container:
    python3 baseline-jpegs.py [--dry-run] [--limit N] [--book ID] [--covers-only]
                              [--since HOURS]

--since limits the run to books added or modified in the last HOURS, which is
how the cron job keeps up with new arrivals without re-reading every JPEG in
the library every ten minutes. Converting a new book here, before it is ever
sent to the reader, also means it never has to be re-sent.
"""
import io, os, sqlite3, subprocess, sys, tempfile, zipfile
from datetime import datetime, timezone
from PIL import Image

LIB  = os.environ.get("CALIBRE_LIBRARY", "/calibre-library")
JT   = os.environ.get("JPEGTRAN", "/app/calibre/bin/jpegtran")
DRY  = "--dry-run" in sys.argv
COVERS_ONLY = "--covers-only" in sys.argv
ENV  = dict(os.environ,
            LD_LIBRARY_PATH="/app/calibre/lib:" + os.environ.get("LD_LIBRARY_PATH", ""))


def arg(flag, cast=int):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return cast(sys.argv[i + 1])
    return None


def kind(d):
    """'baseline', 'progressive', or '?' from the JPEG start-of-frame marker."""
    i = 2
    while i < len(d) - 1:
        if d[i] != 0xFF:
            i += 1
            continue
        m = d[i + 1]
        if m == 0xC0:
            return "baseline"
        if m == 0xC1:
            return "extended"          # sequential, but not what we want to emit
        if m == 0xC2:
            return "progressive"
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        i += 2 + int.from_bytes(d[i + 2:i + 4], "big")
    return "?"


def ncomp(d):
    """Component count from the start-of-frame segment (FF Cx Lh Ll P Yh Yl Xh Xl Nf)."""
    i = 2
    while i < len(d) - 1:
        if d[i] != 0xFF:
            i += 1
            continue
        m = d[i + 1]
        if m in (0xC0, 0xC1, 0xC2):
            return d[i + 9]
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        i += 2 + int.from_bytes(d[i + 2:i + 4], "big")
    return 0


def to_baseline(data):
    """Baseline (SOF0) bytes with identical pixels, or None if that cannot be proven."""
    n = ncomp(data)
    if not 1 <= n <= 4:                 # baseline interleaves at most 4 components
        return None
    with tempfile.TemporaryDirectory() as td:
        src, dst = os.path.join(td, "in.jpg"), os.path.join(td, "out.jpg")
        scans = os.path.join(td, "seq.scans")
        with open(src, "wb") as fh:
            fh.write(data)
        with open(scans, "w") as fh:
            fh.write("%s: 0 63 0 0;\n" % " ".join(str(c) for c in range(n)))
        r = subprocess.run([JT, "-copy", "all", "-optimize", "-scans", scans,
                            "-outfile", dst, src],
                           capture_output=True, env=ENV)
        if r.returncode != 0 or not os.path.exists(dst):
            return None
        out = open(dst, "rb").read()
    if kind(out) != "baseline":
        return None
    try:
        a = Image.open(io.BytesIO(data))
        b = Image.open(io.BytesIO(out))
        if a.size != b.size or a.mode != b.mode or a.tobytes() != b.tobytes():
            return None
    except Exception:
        return None
    return out


def fix_cover(path):
    """Returns 'converted', 'skip', or 'failed'."""
    try:
        d = open(path, "rb").read()
    except OSError:
        return "skip"
    if kind(d) != "progressive":
        return "skip"
    if DRY:
        return "converted"
    out = to_baseline(d)
    if out is None:
        return "failed"
    tmp = path + ".baseline"
    with open(tmp, "wb") as fh:
        fh.write(out)
    os.replace(tmp, path)
    return "converted"


def fix_epub(path):
    """(converted, failed) image counts; the file is replaced only if converted > 0."""
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile):
        return 0, 0
    entries = z.infolist()
    new, converted, failed = {}, 0, 0
    for info in entries:
        if not info.filename.lower().endswith((".jpg", ".jpeg")):
            continue
        d = z.read(info.filename)
        if kind(d) != "progressive":
            continue
        if DRY:
            converted += 1
            continue
        out = to_baseline(d)
        if out is None:
            failed += 1
        else:
            new[info.filename] = out
            converted += 1
    if DRY or not new:
        z.close()
        return converted, failed

    tmp = path + ".baseline"
    try:
        with zipfile.ZipFile(tmp, "w") as zo:
            # Original order and compression, so "mimetype" stays first and stored.
            for info in entries:
                data = new.get(info.filename)
                if data is None:
                    data = z.read(info.filename)
                zo.writestr(info, data, compress_type=info.compress_type)
        z.close()
        with zipfile.ZipFile(tmp) as chk:
            if chk.testzip() is not None:
                raise ValueError("corrupt after rewrite")
            if [i.filename for i in chk.infolist()] != [i.filename for i in entries]:
                raise ValueError("entry list changed")
        os.replace(tmp, path)
    except Exception as exc:
        print("    FAILED rewriting %s: %s" % (os.path.basename(path), exc))
        if os.path.exists(tmp):
            os.remove(tmp)
        return 0, converted + failed
    return converted, failed


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
    limit, only, since = arg("--limit"), arg("--book"), arg("--since", float)
    # The series and ASIN jobs write metadata.db on their own schedules; wait
    # for their locks rather than failing the size update.
    con = sqlite3.connect(LIB + "/metadata.db", timeout=30)
    sql = """select b.id, b.title, b.path,
                    (select name from data where book=b.id and format='EPUB')
             from books b"""
    params = ()
    if since:
        sql += (" where julianday(b.timestamp) >= julianday('now') - ?"
                " or julianday(coalesce(b.last_modified, b.timestamp)) >= julianday('now') - ?")
        params = (since / 24.0, since / 24.0)
    rows = con.execute(sql + " order by b.id", params).fetchall()
    if since:
        print("  %d book(s) added or changed in the last %gh" % (len(rows), since))
    books = covers = imgs = failed = 0
    for bid, title, path, name in rows:
        if only and bid != only:
            continue
        if limit and books >= limit:
            break
        c = fix_cover(os.path.join(LIB, path, "cover.jpg"))
        n, f = (0, 0)
        if not COVERS_ONLY and name:
            epub = os.path.join(LIB, path, name + ".epub")
            n, f = fix_epub(epub)
            if n and not DRY:
                con.execute("update data set uncompressed_size=? where book=? and format='EPUB'",
                            (os.path.getsize(epub), bid))
        if not DRY and (c == "converted" or n):
            touch_book(con, bid)        # cover.jpg is stamped into every served epub
        if c == "converted" or n or f:
            books += 1
            print("  %s [%d] %-34s cover=%-9s epub-images=%d%s"
                  % ("WOULD" if DRY else "done ", bid, title[:34], c, n,
                     " FAILED=%d" % f if f else ""))
        covers += (c == "converted")
        imgs += n
        failed += f + (c == "failed")
    if not DRY:
        con.commit()
    print("  %s: %d book(s), %d cover.jpg, %d epub image(s), %d failed (left as-is)"
          % ("would convert" if DRY else "converted", books, covers, imgs, failed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
