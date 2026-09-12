#!/usr/bin/env python3
"""
Fill in series and series index from Amazon, keyed by ASIN.

WHY THIS EXISTS
calibre ships an Amazon metadata source and it is enabled, but it reports
"Found 0 results" for our ASINs. That is not Amazon refusing us -- measured
10 Sep 2026, one request in four returns the real product page:

    try 1: 3781 bytes   bot-block
    try 2: 3781 bytes   bot-block
    try 3: 186410 bytes real page, series present
    try 4: 3781 bytes   bot-block

Amazon rate-limits rather than blocks. calibre's plugin makes a single attempt
per book and gives up, then falls back to scraping Google and Bing, which fail
too. Retrying with backoff is the whole difference.

The page states it plainly:  "Book 2 of 3: The Empyrean"

Nothing here guesses from titles: the ASIN identifies the book, and the series
is read off that book's own page.

Run inside the CWA container:
    python3 series-from-amazon.py [--dry-run] [--limit N] [--book ID]
"""
import os, re, sqlite3, subprocess, sys, time, random

LIB   = os.environ.get("CALIBRE_LIBRARY", "/calibre-library")
CFG   = os.environ.get("CALIBRE_CONFIG_DIRECTORY", "/config/.config/calibre")
DRY   = "--dry-run" in sys.argv
TRIES = int(os.environ.get("AMAZON_TRIES", 6))     # attempts per book
GAP   = float(os.environ.get("AMAZON_GAP", 4))     # seconds between attempts
REST  = float(os.environ.get("AMAZON_REST", 6))    # seconds between books

# A blocked response is a small, consistent page; a real one is ~200KB.
MIN_REAL_PAGE = 20000

AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0",
]

# "Book 2 of 3: The Empyrean"  /  "Book 1 of 8: Dungeon Crawler Carl"
SERIES_RE = re.compile(r"Book\s+(\d+)\s+of\s+\d+:\s*([^<\r\n]{2,80})")


def arg(flag, cast=int):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return cast(sys.argv[i + 1])
    return None


def fetch(asin):
    """The product page, or None if Amazon rate-limited every attempt."""
    for attempt in range(TRIES):
        ua = AGENTS[attempt % len(AGENTS)]
        r = subprocess.run(
            ["curl", "-sS", "--compressed", "-L", "--max-time", "40",
             "-A", ua, "https://www.amazon.com/dp/%s" % asin],
            capture_output=True, check=False)
        page = r.stdout.decode("utf-8", "replace")
        if len(page) >= MIN_REAL_PAGE:
            return page
        # Jitter: a fixed interval looks exactly like a bot.
        time.sleep(GAP + random.uniform(0, 2))
    return None


def series_of(page):
    m = SERIES_RE.search(page)
    if not m:
        return None
    idx, name = m.group(1), m.group(2).strip()
    name = re.sub(r"\s+", " ", name).strip(" :–-")
    if not name:
        return None
    return name, int(idx)


def main():
    limit = arg("--limit")
    only  = arg("--book")
    con = sqlite3.connect("file:%s/metadata.db?mode=ro" % LIB, uri=True)
    rows = con.execute("""
        select b.id, b.title, i.val
        from books b
        join identifiers i on i.book = b.id and i.type = 'amazon'
        where b.id not in (select book from books_series_link)
        order by b.id""").fetchall()
    con.close()

    if only:
        rows = [r for r in rows if r[0] == only]
    print("  %d book(s) with an ASIN and no series" % len(rows))

    done = blocked = noseries = 0
    for bid, title, asin in rows:
        if limit and done >= limit:
            break
        page = fetch(asin)
        if page is None:
            print("  RATE-LIMITED [%s] %s (%d tries)" % (bid, title[:34], TRIES))
            blocked += 1
            time.sleep(REST)
            continue
        got = series_of(page)
        if not got:
            print("  no series on page [%s] %s" % (bid, title[:34]))
            noseries += 1
            time.sleep(REST)
            continue
        name, idx = got
        if DRY:
            print("  WOULD SET [%s] %-34s -> %s #%d" % (bid, title[:34], name, idx))
        else:
            r = subprocess.run(
                ["calibredb", "set_metadata", str(bid),
                 "--field", "series:%s" % name,
                 "--field", "series_index:%d" % idx,
                 "--with-library", LIB],
                capture_output=True, text=True,
                env=dict(os.environ, CALIBRE_CONFIG_DIRECTORY=CFG))
            if r.returncode != 0:
                print("  FAILED [%s] %s: %s" % (bid, title[:30], r.stderr.strip()[:60]))
                time.sleep(REST)
                continue
            print("  set [%s] %-34s -> %s #%d" % (bid, title[:34], name, idx))
        done += 1
        time.sleep(REST)

    verb = "would set" if DRY else "set"
    print("  %s %d, rate-limited %d, no series on page %d" % (verb, done, blocked, noseries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
