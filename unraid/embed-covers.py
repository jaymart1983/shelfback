#!/usr/bin/env python3
"""
Push the library's cover into each epub, so the reader gets real resolution.

The X4 Pro draws covers full-screen at 480x720 and dithers to 4 grey levels. A
cover that has to be upscaled into that has under one source pixel per output
pixel, so the dither has no true intermediate tone to work with and detail
collapses. Anything that downscales looks right. Measured on the device:

    Trash Droid  778x1244 embedded -> downscale 1.62x -> fine
    Iron Flame   333x500  embedded -> UPSCALE   1.44x -> bad

calibre's own cover.jpg is often far better than what the epub carries, and
`ebook-polish --cover` swaps it in without a full reconversion (0.5s per book).

Run inside the CWA container:
    python3 embed-covers.py [--dry-run] [--limit N] [--book ID]
"""
import os, sqlite3, struct, subprocess, sys, tempfile, zipfile
from datetime import datetime, timezone

LIB   = os.environ.get("CALIBRE_LIBRARY", "/calibre-library")
MIN   = int(os.environ.get("MIN_COVER_EDGE", 800))
DRY   = "--dry-run" in sys.argv
CFG   = os.environ.get("CALIBRE_CONFIG_DIRECTORY", "/config/.config/calibre")


def arg(flag, cast=int):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return cast(sys.argv[i + 1])
    return None


def dims(data):
    """(w, h) of a JPEG held in memory, else None."""
    i = 2
    while i < len(data) - 1:
        if data[i] != 0xFF:
            i += 1; continue
        m = data[i+1]
        if m in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", data[i+5:i+9])
            return (w, h)
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2; continue
        i += 2 + struct.unpack(">H", data[i+2:i+4])[0]
    return None


def biggest_image(path):
    """Largest JPEG inside the epub, as ((w,h), bytes). PNGs are ignored: the
    reader handles either, and this is only used to decide 'is it worth
    replacing', where the JPEG cover is what matters."""
    best = None
    try:
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if not n.lower().endswith((".jpg", ".jpeg")):
                    continue
                d = z.read(n)
                wh = dims(d)
                if wh and (best is None or wh[0] * wh[1] > best[0][0] * best[0][1]):
                    best = (wh, len(d))
    except (OSError, zipfile.BadZipFile):
        return None
    return best


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
    limit = arg("--limit")
    only  = arg("--book")
    con = sqlite3.connect(f"{LIB}/metadata.db")
    rows = con.execute("""select b.id, b.title, b.path, d.name
                          from books b join data d on d.book = b.id
                          where d.format = 'EPUB' order by b.id""").fetchall()

    done = skipped = failed = 0
    for bid, title, path, name in rows:
        if only and bid != only:
            continue
        if limit and done >= limit:
            break
        book  = os.path.join(LIB, path, name + ".epub")
        cover = os.path.join(LIB, path, "cover.jpg")
        if not (os.path.exists(book) and os.path.exists(cover)):
            continue
        try:
            cwh = dims(open(cover, "rb").read())
        except OSError:
            continue
        if not cwh or max(cwh) < MIN:
            # Nothing better to offer. fix-covers.py is what raises this.
            skipped += 1
            continue
        cur = biggest_image(book)
        if cur and max(cur[0]) >= max(cwh):
            skipped += 1
            continue

        have = f"{cur[0][0]}x{cur[0][1]}" if cur else "none"
        want = f"{cwh[0]}x{cwh[1]}"
        if DRY:
            print(f"  WOULD EMBED [{bid}] {title[:34]:<34} {have} -> {want}")
            done += 1
            continue

        # Polish to a sibling temp file, then swap: an interrupted run must
        # never leave a half-written book in the library.
        tmp = book + ".polished"
        env = dict(os.environ, CALIBRE_CONFIG_DIRECTORY=CFG)
        r = subprocess.run(["ebook-polish", "--cover", cover, book, tmp],
                           capture_output=True, text=True, env=env)
        if r.returncode != 0 or not os.path.exists(tmp):
            print(f"  FAILED [{bid}] {title[:34]}: {r.stderr.strip()[:80]}")
            failed += 1
            if os.path.exists(tmp):
                os.remove(tmp)
            continue
        new = biggest_image(tmp)
        if not new or max(new[0]) < max(cwh):
            print(f"  NO GAIN [{bid}] {title[:34]} ({new})")
            os.remove(tmp)
            skipped += 1
            continue
        os.replace(tmp, book)
        # Keep calibre's recorded size honest, or its own tooling reports a
        # mismatch later.
        try:
            con.execute("update data set uncompressed_size = ? where book = ? and format = 'EPUB'",
                        (os.path.getsize(book), bid))
            touch_book(con, bid)
            con.commit()
        except sqlite3.Error as e:
            print(f"  (size not updated for {bid}: {e})")
        print(f"  embedded [{bid}] {title[:34]:<34} {have} -> {want}")
        done += 1

    verb = "would embed" if DRY else "embedded"
    print(f"  {verb} {done}, skipped {skipped}, failed {failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
