#!/usr/bin/env python3
"""
Minimal HTTP PUT receiver for decrypted books coming off the jailbroken Kindle.

    curl -sS -H "X-Token: <token>" -T book.kfx-zip http://<unraid>:8086/book.kfx-zip

Writes to a staging directory OUTSIDE the watched ingest folder, then does an
atomic rename into it. CWA polls the ingest folder, and a rename is the only way
to guarantee it never sees a partially uploaded file. (CWA does have a
"file is ready" check, but relying on it is a race we don't need to run.)
"""

import os
import time
import shutil
import zipfile
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INGEST = os.environ.get("INGEST_DIR", "/ingest")
STAGING = os.environ.get("STAGING_DIR", "/staging")
CONFIRMED = os.environ.get("CONFIRMED_FILE", "/books/.confirmed-asins")
# Authoritative record of what has been synced off the Kindle. The device keeps
# no equivalent: it asks this server what is already done and works on the rest.
# Delete a line here and the next pass re-downloads and re-decrypts that book.
SYNCSTATE = os.environ.get("SYNC_STATE", "/books/.sync-state.tsv")
LIBRARY_STATE = os.environ.get("LIBRARY_STATE", "/books/.kindle-library.tsv")
# Downloads the device could not complete. Recorded here rather than only on the
# Kindle's screen: a stuck book in an unattended pipeline is exactly the thing
# nobody is watching for, and the device may be asleep when you go looking.
STUCK_STATE = os.environ.get("STUCK_STATE", "/books/.stuck.tsv")
# Books that were uploaded but never appeared in Calibre. CWA can drop a file
# -- its ingest processor races itself when two arrive together and reports
# "did not become ready or vanished" -- and nothing else notices, because the
# device fetches on "not synced" and purges on "confirmed", so an
# uploaded-but-unconfirmed book falls between the two and sits forever.
RESEND_STATE = os.environ.get("RESEND_STATE", "/books/.resend.tsv")
# How long to let CWA finish before calling an upload lost.
RESEND_GRACE = int(os.environ.get("RESEND_GRACE", 900))
# How long to wait between attempts on the same book.
RESEND_COOLDOWN = int(os.environ.get("RESEND_COOLDOWN", 1800))
# After this many tries it is not a transient drop; stop retrying and say so.
RESEND_MAX = int(os.environ.get("RESEND_MAX", 3))
# Hand back one book at a time. Delivering several at once is what triggered
# the CWA race in the first place, so a retry path that batches would recreate
# the failure it exists to repair.
RESEND_BATCH = int(os.environ.get("RESEND_BATCH", 1))
# Books whose uploads keep failing to convert. Resending the same bytes cannot
# help if those bytes are the problem, so past RESEND_MAX we ask the device to
# throw its local copy away and fetch the book again from Amazon.
REBUILD_STATE = os.environ.get("REBUILD_STATE", "/books/.rebuild.tsv")
# How long an upload is allowed to count as "done" before Calibre has to show
# it. Uploading is a claim; being in Calibre is the fact. Past this, the book
# reverts to not-synced and the device fetches it again from scratch -- which
# is what makes a book Calibre silently refused heal itself.
UPLOAD_GRACE = int(os.environ.get("UPLOAD_GRACE", 1800))
# KFX resource containers the device found missing from a book's .kfx-zip.
# calibre's KFX Input plugin refuses a book whose containers are not all in the
# one archive ("Book is incomplete... Missing containers CR!..."), and the
# on-device packager does not always include them. They are plain CONT
# containers, copied verbatim -- nothing is decrypted here.
ATTACH_DIR = os.environ.get("ATTACH_DIR", "/books/.attachables")

ASIN_IN_NAME = re.compile(r"_(B[A-Z0-9]{9})(?:_sample)?(?:\.|$)")


def sync_key(name):
    """Identity for 'has this been synced?'.

    Normally the ASIN. A sideloaded file may carry a UUID and no ASIN at all --
    those had no identity here, so the device never saw them as done and
    re-uploaded them on every pass, duplicating them in Calibre. Falling back to
    the filename gives them one. Must match key_of() in menu.sh.
    """
    m = ASIN_IN_NAME.search(name)
    if m:
        return m.group(1).upper()
    base = name
    for ext in (".kfx-zip", ".kfx", ".epub", ".azw3", ".mobi"):
        if base.lower().endswith(ext):
            base = base[: -len(ext)]
            break
    return base.replace("\t", " ").strip()


def record_synced(asin, title):
    """Append or refresh one book's synced record. Last line for an ASIN wins."""
    try:
        with open(SYNCSTATE, "a") as fh:
            fh.write("%s\t%s\t%d\tuploaded\n" % (asin, title.replace("\t", " "), int(time.time())))
    except OSError as e:
        log("  SYNCSTATE write failed: %s" % e)


def merge_attachables(path, asin):
    """Add any staged resource containers missing from this book's archive.

    Returns the number added. A book whose archive is already complete is left
    untouched, so this is safe to call on every upload.
    """
    if not asin:
        return 0
    src = os.path.join(ATTACH_DIR, asin)
    if not os.path.isdir(src):
        return 0
    try:
        pending = sorted(os.listdir(src))
    except OSError:
        return 0
    if not pending:
        return 0
    try:
        with zipfile.ZipFile(path) as zf:
            have = set(os.path.basename(n) for n in zf.namelist())
        missing = [n for n in pending if n not in have]
        if missing:
            with zipfile.ZipFile(path, "a", zipfile.ZIP_DEFLATED) as zf:
                for n in missing:
                    zf.write(os.path.join(src, n), n)
            log("  MERGED %d container(s) into %s: %s"
                % (len(missing), asin, ", ".join(missing)))
        # Only drop the staging copies once they are safely inside the archive.
        shutil.rmtree(src, ignore_errors=True)
        return len(missing)
    except (OSError, zipfile.BadZipFile) as exc:
        log("  ERROR merging containers for %s: %s" % (asin, exc))
        return 0


def synced_view():
    """What the device should treat as done.

    Calibre is the authority. An upload only counts while it is inside the
    grace period, so a book that uploaded but never appeared in the library
    stops being "done" on its own and gets fetched again -- no queue, no
    bookkeeping to go stale.
    """
    confirmed = confirmed_set()
    if confirmed is None:
        return None                     # cannot tell; caller must not guess
    now = int(time.time())
    view = set(confirmed)
    for key, (_title, ts) in synced_rows().items():
        if key in view:
            continue
        if ts and now - ts < UPLOAD_GRACE:
            view.add(key)               # still ingesting, give it time
    return view


def rebuild_pending():
    """ASINs queued for rebuild and still not in Calibre."""
    confirmed = confirmed_set() or set()
    out = set()
    try:
        with open(REBUILD_STATE) as fh:
            for line in fh:
                a = line.split("\t")[0].strip()
                if re.match(r"^B[A-Z0-9]{9}$", a) and a not in confirmed:
                    out.add(a)
    except OSError:
        pass
    return out


def clear_rebuild(asin):
    """Drop a book from the rebuild queue once a fresh copy has arrived."""
    try:
        with open(REBUILD_STATE) as fh:
            rows = [l for l in fh if not l.startswith(asin + "\t")]
    except OSError:
        return
    tmp = REBUILD_STATE + ".tmp"
    try:
        with open(tmp, "w") as fh:
            fh.writelines(rows)
        os.replace(tmp, REBUILD_STATE)
    except OSError as e:
        log("  REBUILD prune failed: %s" % e)


def clear_stuck(asin):
    """Drop a book from the stuck list once it has actually arrived.

    Otherwise /stuck accumulates books that were stuck at some point and later
    succeeded, and a list that is mostly stale gets ignored -- which defeats
    the only alarm this pipeline has.
    """
    try:
        with open(STUCK_STATE) as fh:
            rows = [l for l in fh if not l.startswith(asin + "\t")]
    except OSError:
        return
    tmp = STUCK_STATE + ".tmp"
    try:
        with open(tmp, "w") as fh:
            fh.writelines(rows)
        os.replace(tmp, STUCK_STATE)
    except OSError as e:
        log("  STUCK prune failed: %s" % e)


def note_received(name):
    """Record the ASIN and title of a book that has arrived.

    Kindle covers are greyscale (e-ink), so a later job swaps in Amazon colour
    art -- but only the original filename carries the ASIN, and it is gone once
    CWA ingests. Each step is guarded separately and logged as an ERROR: a
    broken manifest write must not cost us the synced record, which is the only
    thing that stops the device sending this book again.
    """
    key = sync_key(name)
    if not key:
        return
    m = re.search(r"_(B[A-Z0-9]{9})(_sample)?\.", name)
    asin = m.group(1).upper() if m else ""
    title = name[:m.start()] if m else key
    try:
        record_synced(key, title)
        clear_stuck(key)
        clear_rebuild(key)
    except Exception as exc:
        log("  ERROR record_synced %s: %s" % (asin, exc))
    try:
        if asin:      # the manifest is ASIN-keyed by design; skip keyless books
            with open(os.path.join(os.path.dirname(INGEST), ".asin-manifest"), "a") as mf:
                mf.write("%s\t%s\n" % (asin, title))
    except Exception as exc:
        log("  ERROR asin-manifest %s: %s" % (asin, exc))


def synced_rows():
    """{asin: (title, uploaded_ts)} from the sync state. Last row for an ASIN wins."""
    rows = {}
    try:
        with open(SYNCSTATE) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 4 and parts[0]:
                    try:
                        ts = int(parts[2])
                    except ValueError:
                        ts = 0
                    rows[parts[0]] = (parts[1], ts)
    except OSError:
        return {}
    return rows


def confirmed_set():
    """ASINs Calibre genuinely holds, or None if we cannot tell.

    None and empty are different answers and must stay different: treating
    "could not read the list" as "nothing is confirmed" would mark the entire
    library as lost and resend all of it.
    """
    try:
        with open(CONFIRMED) as fh:
            body = fh.read()
    except OSError:
        return None
    # One key per LINE. Splitting on whitespace, as this used to, shredded any
    # key containing a space -- a sideloaded book's filename key -- into words
    # and then discarded them for not being ten characters long.
    keys = set()
    for line in body.splitlines():
        v = line.strip()
        if not v:
            continue
        keys.add(v.upper() if re.match(r"^[Bb][A-Za-z0-9]{9}$", v) else v)
    return keys or None


def resend_rows():
    """{asin: (attempts, last_ts)}"""
    rows = {}
    try:
        with open(RESEND_STATE) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 3 and len(parts[0]) == 10:
                    try:
                        rows[parts[0].upper()] = (int(parts[1]), int(parts[2]))
                    except ValueError:
                        continue
    except OSError:
        pass
    return rows


def write_resend_rows(rows):
    """Persist attempt counts. Raises on failure -- the caller must not hand
    out a book it could not account for."""
    tmp = RESEND_STATE + ".tmp"
    with open(tmp, "w") as fh:
        for asin, (attempts, ts) in sorted(rows.items()):
            fh.write("%s\t%d\t%d\n" % (asin, attempts, ts))
    os.replace(tmp, RESEND_STATE)


def pick_resends(peek=False):
    """ASINs the device should upload again.

    Returns None when the confirmation list is unreadable -- the caller must
    serve 503 rather than guess. Records the attempt itself before returning:
    handing out a book whose attempt count did not get written would serve it
    again on the very next poll, forever.

    peek=True answers the same question without spending an attempt, so
    looking at the queue does not take the device's turn.
    """
    confirmed = confirmed_set()
    if confirmed is None:
        return None
    now = int(time.time())
    rows = resend_rows()
    # A book that made it into Calibre needs no further attention, and keeping
    # its row would leave a stale attempt count to trip over on a later drop.
    for asin in list(rows):
        if asin in confirmed:
            del rows[asin]
    # Anything already waiting in the ingest folder is CWA's turn, not ours.
    try:
        queued = set(m.group(1).upper()
                     for m in (ASIN_IN_NAME.search(n) for n in os.listdir(INGEST))
                     if m)
    except OSError:
        queued = set()
    due = []
    for asin, (title, uploaded) in synced_rows().items():
        if asin in confirmed or asin in queued:
            continue
        # Confirmation is ASIN-keyed. A filename-keyed book can never appear
        # there, so resending it would repeat forever rather than repair.
        if not re.match(r"^B[A-Z0-9]{9}$", asin):
            continue
        if uploaded and now - uploaded < RESEND_GRACE:
            continue                      # still within CWA's normal window
        attempts, last = rows.get(asin, (0, 0))
        if attempts >= RESEND_MAX:
            continue                      # already given up on; see /stuck
        if last and now - last < RESEND_COOLDOWN:
            continue
        due.append((uploaded, asin, title, attempts))
    due.sort()                            # oldest loss first
    chosen = due[:RESEND_BATCH]
    if peek:
        return [asin for _u, asin, _t, _a in chosen]
    for uploaded, asin, title, attempts in chosen:
        rows[asin] = (attempts + 1, now)
    try:
        write_resend_rows(rows)
    except OSError as e:
        log("  RESEND state write failed, serving nothing: %s" % e)
        return []
    picked = []
    for uploaded, asin, title, attempts in chosen:
        picked.append(asin)
        if attempts + 1 >= RESEND_MAX:
            # Re-sending achieved nothing, so the artifact itself is suspect.
            # Hand it to the rebuild path rather than giving up on the book.
            try:
                with open(REBUILD_STATE, "a") as fh:
                    fh.write("%s\t%s\t%d\n" % (asin, title.replace("\t", " "), now))
                log("  REBUILD queued for %s (resends exhausted)" % asin)
            except OSError as e:
                log("  REBUILD write failed: %s" % e)
            try:
                with open(STUCK_STATE, "a") as fh:
                    fh.write("%s\t%s\t%s\t%d\n" % (
                        asin, title.replace("\t", " "),
                        "not-confirmed-after-%d-resends" % RESEND_MAX, now))
            except OSError as e:
                log("  STUCK write failed: %s" % e)
            log("  RESEND %s reached attempt %d -- recorded as stuck"
                % (asin, RESEND_MAX))
    return picked


def synced_asins():
    seen = {}
    try:
        with open(SYNCSTATE) as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 4 and parts[0]:
                    seen[parts[0]] = parts[3]
    except OSError:
        return {}
    return seen
TOKEN = os.environ.get("UPLOAD_TOKEN", "")
MAX_BYTES = int(os.environ.get("MAX_BYTES", 512 * 1024 * 1024))
# Reject only what is actually dangerous rather than whitelisting characters.
# Real book titles contain accented letters (Atmosphaera), colons, question
# marks, dashes and quotes, and a whitelist silently 400s all of them.
UNSAFE = re.compile(r"[/\\\x00-\x1f\x7f]")

# Remote-trigger flag. The Kindle polls /control; POST /control/run raises the
# flag, and the Kindle clears it when it starts a pass. This is the fallback for
# when the Kindle's own nc listener is unavailable or its IP has moved.
_RUN_REQUESTED = False
_STOP_REQUESTED = False
_LOG_LINES = []          # ring buffer of status lines forwarded from the Kindle
_LOG_MAX = 500
_LAST_SEEN = ""
_LAST_IP = ""


def note_client(ip):
    """Record where the Kindle is talking from. Its address is DHCP-assigned, so
    when it moves we want that change to be loud in the log rather than something
    you discover when a direct trigger stops working."""
    global _LAST_IP, _LAST_SEEN
    import datetime
    _LAST_SEEN = datetime.datetime.now().isoformat(timespec="seconds")
    if ip != _LAST_IP:
        if _LAST_IP:
            log("  *** CLIENT IP CHANGED: %s -> %s ***" % (_LAST_IP, ip))
        else:
            log("  client IP: %s" % ip)
        _LAST_IP = ip


def log(msg):
    print(msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "book-receiver/1.0"

    def _reply(self, code, msg):
        body = (msg + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log("  %s - %s" % (self.client_address[0], fmt % args))

    def do_GET(self):
        global _RUN_REQUESTED, _STOP_REQUESTED, _LAST_SEEN
        # health check, so the Kindle script can verify before uploading
        if self.path == "/healthz":
            return self._reply(200, "ok")
        if self.path == "/control":
            note_client(self.client_address[0])
            # polled by the Kindle; reading a flag consumes it.
            # stop wins over run - if both are set, we want it to exit.
            if _STOP_REQUESTED:
                _STOP_REQUESTED = False
                log("  CONTROL stop consumed by Kindle")
                return self._reply(200, "stop")
            if _RUN_REQUESTED:
                _RUN_REQUESTED = False
                log("  CONTROL run consumed by Kindle")
                return self._reply(200, "run")
            return self._reply(200, "idle")
        if self.path.startswith("/log"):
            n = 60
            if "=" in self.path:
                try: n = max(1, min(_LOG_MAX, int(self.path.split("=")[-1])))
                except ValueError: pass
            if not _LOG_LINES:
                return self._reply(200, "(no log lines received yet)")
            return self._reply(200, "\n".join(_LOG_LINES[-n:]))
        if self.path == "/synced":
            # Reconciled against Calibre, not against our own upload log.
            view = synced_view()
            if view is None:
                # Cannot read the confirmation list. Saying "nothing is synced"
                # would make the device re-fetch the entire library.
                return self._reply(503, "confirmation list unavailable")
            note_client(self.client_address[0])
            return self._reply(200, "".join(a + "\n" for a in sorted(view)))
        if self.path == "/confirmed":
            # ASINs Calibre genuinely holds, with a real file on disk. The
            # Kindle deletes its local copies against this list, so serving a
            # stale or empty body would be worse than serving none: 503 rather
            # than an empty 200, so the device can tell "nothing confirmed" from
            # "could not tell".
            try:
                with open(CONFIRMED) as fh:
                    body = fh.read()
            except OSError as e:
                log("  CONFIRMED unavailable: %s" % e)
                return self._reply(503, "confirmation list unavailable")
            if not body.strip():
                return self._reply(503, "confirmation list empty")
            note_client(self.client_address[0])
            return self._reply(200, body)
        if self.path in ("/resend", "/resend?peek=1"):
            peek = self.path.endswith("peek=1")
            # Uploaded, but never turned up in Calibre. Serving one at a time,
            # and only after a grace period, so a slow ingest is not mistaken
            # for a lost one.
            picked = pick_resends(peek=peek)
            if picked is None:
                return self._reply(503, "confirmation list unavailable")
            if picked and not peek:
                log("  RESEND -> %s" % ", ".join(picked))
            if not peek:
                note_client(self.client_address[0])
            return self._reply(200, "".join(a + "\n" for a in picked))
        if self.path == "/rebuild":
            # ASINs the device should discard locally and download again. Only
            # ones Calibre still does not have -- if it arrived in the meantime
            # there is nothing to rebuild.
            confirmed = confirmed_set()
            if confirmed is None:
                return self._reply(503, "confirmation list unavailable")
            out = []
            try:
                with open(REBUILD_STATE) as fh:
                    for line in fh:
                        a = line.split("\t")[0].strip()
                        if re.match(r"^B[A-Z0-9]{9}$", a) and a not in confirmed:
                            out.append(a)
            except OSError:
                pass
            note_client(self.client_address[0])
            return self._reply(200, "".join(a + "\n" for a in dict.fromkeys(out)))
        if self.path.startswith("/recent"):
            # Newest arrivals, for the device's Books screen. The Kindle cannot
            # know when a book reached Calibre -- only this side has that.
            try:
                n = int(self.path.split("n=")[1].split("&")[0])
            except (IndexError, ValueError):
                n = 20
            n = max(1, min(n, 100))
            rows = []
            for key, (title, ts) in synced_rows().items():
                rows.append((ts, key, title))
            rows.sort(reverse=True)
            body = "".join("%d\t%s\t%s\n" % r for r in rows[:n])
            note_client(self.client_address[0])
            return self._reply(200, body)
        if self.path == "/stuck":
            try:
                with open(STUCK_STATE) as fh:
                    return self._reply(200, fh.read())
            except OSError:
                return self._reply(200, "")
        if self.path == "/status":
            return self._reply(200, "client-ip: %s\nlast-seen: %s\ntrigger-url: %s\npending: %s" % (
                _LAST_IP or "unknown",
                _LAST_SEEN or "never",
                ("http://%s:8087/" % _LAST_IP) if _LAST_IP else "unknown",
                "stop" if _STOP_REQUESTED else ("run" if _RUN_REQUESTED else "none")))
        self._reply(404, "not found")

    def do_POST(self):
        global _RUN_REQUESTED, _STOP_REQUESTED, _LAST_SEEN
        if self.path == "/control/run":
            _RUN_REQUESTED = True
            log("  CONTROL run requested")
            return self._reply(202, "queued")
        if self.path == "/control/stop":
            _STOP_REQUESTED = True
            log("  CONTROL stop requested")
            return self._reply(202, "queued")
        if self.path == "/log":
            # Kindle forwards its status lines here so they can be read from the
            # host instead of squinting at e-ink.
            note_client(self.client_address[0])
            try:
                n = int(self.headers.get("Content-Length", 0))
            except ValueError:
                n = 0
            body = self.rfile.read(n).decode("utf-8", "replace") if n > 0 else ""
            for line in body.splitlines():
                line = line.rstrip()
                if line:
                    _LOG_LINES.append(line)
            del _LOG_LINES[:-_LOG_MAX]
            return self._reply(200, "ok")
        if self.path == "/stuck":
            note_client(self.client_address[0])
            try:
                n = int(self.headers.get("Content-Length", 0))
            except ValueError:
                n = 0
            body = self.rfile.read(n).decode("utf-8", "replace") if n > 0 else ""
            parts = body.rstrip("\n").split("\t")
            if not parts or len(parts[0]) != 10 or not parts[0].startswith("B"):
                return self._reply(400, "expected ASIN<TAB>title<TAB>reason")
            asin = parts[0]
            title = parts[1] if len(parts) > 1 else ""
            reason = parts[2] if len(parts) > 2 else "unknown"
            # One row per book, not one per attempt. A device retrying every
            # 20 minutes overnight otherwise writes the same line dozens of
            # times, and a list that repeats itself is one nobody reads.
            try:
                try:
                    with open(STUCK_STATE) as fh:
                        rows = [l for l in fh if not l.startswith(asin + "\t")]
                except OSError:
                    rows = []
                rows.append("%s\t%s\t%s\t%d\n" % (asin, title.replace("\t", " "),
                                                   reason, int(time.time())))
                tmp = STUCK_STATE + ".tmp"
                with open(tmp, "w") as fh:
                    fh.writelines(rows)
                os.replace(tmp, STUCK_STATE)
            except OSError as e:
                log("  STUCK write failed: %s" % e)
                return self._reply(500, "write failed")
            log("  STUCK %s (%s) %s" % (asin, reason, title[:40]))
            return self._reply(200, "ok")
        if self.path == "/library":
            # The Kindle reports what its catalogue holds, so the server has a
            # picture of the whole library rather than only what reached it.
            note_client(self.client_address[0])
            try:
                n = int(self.headers.get("Content-Length", 0))
            except ValueError:
                n = 0
            body = self.rfile.read(n).decode("utf-8", "replace") if n > 0 else ""
            kept = 0
            tmp = LIBRARY_STATE + ".tmp"
            try:
                with open(tmp, "w") as fh:
                    for line in body.splitlines():
                        parts = line.rstrip().split("\t")
                        if not parts or len(parts[0]) != 10 or not parts[0].startswith("B"):
                            continue
                        fh.write("\t".join(parts[:3]) + "\n")
                        kept += 1
                os.replace(tmp, LIBRARY_STATE)
            except OSError as e:
                log("  LIBRARY write failed: %s" % e)
                return self._reply(500, "write failed")
            log("  LIBRARY %d book(s) reported" % kept)
            return self._reply(200, "ok %d" % kept)
        if self.path == "/checkin":
            note_client(self.client_address[0])
            return self._reply(200, "ok")
        self._reply(404, "not found")

    def _recv_attachable(self):
        """Stash one KFX resource container until its book's archive arrives.

        Kept out of the ingest folder entirely: on its own a container is not a
        book, and CWA would only try and fail to convert it.
        """
        asin = (self.headers.get("X-Asin", "") or "").strip().upper()
        name = os.path.basename((self.headers.get("X-Filename", "") or "").strip())
        if not re.match(r"^B[A-Z0-9]{9}$", asin):
            return self._reply(400, "bad or missing X-Asin")
        if not name or UNSAFE.search(name) or not name.lower().endswith(".kfx"):
            return self._reply(400, "bad container name")
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return self._reply(411, "length required")
        if length <= 0:
            return self._reply(411, "length required")
        if length > MAX_BYTES:
            return self._reply(413, "too large")

        dest_dir = os.path.join(ATTACH_DIR, asin)
        try:
            os.makedirs(dest_dir, exist_ok=True)
        except OSError as e:
            log("  ERROR attach dir %s: %s" % (asin, e))
            return self._reply(500, "write failed")
        tmp = os.path.join(dest_dir, name + ".part")
        got = 0
        try:
            with open(tmp, "wb") as fh:
                while got < length:
                    chunk = self.rfile.read(min(1 << 16, length - got))
                    if not chunk:
                        break
                    fh.write(chunk)
                    got += len(chunk)
                fh.flush()
                os.fsync(fh.fileno())
            if got != length:
                os.unlink(tmp)
                return self._reply(400, "incomplete upload")
            os.rename(tmp, os.path.join(dest_dir, name))
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            log("  ERROR attach %s/%s: %s" % (asin, name, e))
            return self._reply(500, "write failed")
        note_client(self.client_address[0])
        log("  CONTAINER %s/%s (%d bytes)" % (asin, name, got))
        return self._reply(201, "stored")

    def do_PUT(self):
        if TOKEN and self.headers.get("X-Token", "") != TOKEN:
            log("  REJECT auth from %s" % self.client_address[0])
            return self._reply(403, "forbidden")

        if self.path.rstrip("/") == "/attach":
            return self._recv_attachable()

        # Prefer the filename from a header. Book titles contain spaces and
        # punctuation, and curl refuses to build a URL from an unencoded name
        # ("URL using bad/illegal format", which surfaces as HTTP 000). Keeping
        # the name out of the URL sidesteps encoding entirely.
        name = self.headers.get("X-Filename", "").strip()
        if name:
            # http.server decodes headers as latin-1, so a UTF-8 title like
            # "Atmosphaera" arrives mojibaked. Round-trip it back to UTF-8.
            try:
                name = name.encode("latin-1").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
        if not name:
            name = os.path.basename(self.path.lstrip("/"))
            try:
                from urllib.parse import unquote
                name = unquote(name)
            except Exception:
                pass
        name = os.path.basename(name)

        # reject anything that isn't a plain, expected filename
        if not name or name in (".", "..") or UNSAFE.search(name) or len(name) > 255:
            log("  REJECT bad filename: %r" % name[:120])
            return self._reply(400, "bad filename")
        if not name.lower().endswith((".kfx-zip", ".epub", ".azw3", ".mobi", ".kfx")):
            log("  REJECT unsupported extension: %r" % name[:120])
            return self._reply(400, "unsupported extension")

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return self._reply(411, "length required")
        if length <= 0:
            return self._reply(411, "length required")
        if length > MAX_BYTES:
            return self._reply(413, "too large")

        final = os.path.join(INGEST, name)
        if os.path.exists(final):
            # Record it anyway. The file already being here does not mean the
            # bookkeeping ever happened -- and skipping that is what turns one
            # failed record into an endless re-upload: the device asks what is
            # synced, does not see this book, sends it again, and we skip again.
            note_received(name)
            log("  SKIP already present: %s" % name)
            return self._reply(200, "already present")

        os.makedirs(STAGING, exist_ok=True)
        tmp = os.path.join(STAGING, name + ".part")
        got = 0
        try:
            with open(tmp, "wb") as fh:
                while got < length:
                    chunk = self.rfile.read(min(1 << 16, length - got))
                    if not chunk:
                        break
                    fh.write(chunk)
                    got += len(chunk)
                fh.flush()
                os.fsync(fh.fileno())
            if got != length:
                os.unlink(tmp)
                log("  TRUNCATED %s (%d of %d)" % (name, got, length))
                return self._reply(400, "incomplete upload")
            # Complete the archive BEFORE it becomes visible to CWA. Once the
            # file appears in the watched folder the ingest processor may pick
            # it up at any moment, so merging after the rename would race it.
            m = ASIN_IN_NAME.search(name)
            if m and name.lower().endswith(".kfx-zip"):
                merge_attachables(tmp, m.group(1).upper())
            # atomic publish into the watched folder
            os.rename(tmp, final)
        except Exception as exc:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            log("  ERROR %s: %s" % (name, exc))
            return self._reply(500, "write failed")

        note_client(self.client_address[0])
        note_received(name)
        log("  RECEIVED %s (%d bytes)" % (name, got))
        self._reply(201, "created")


def main():
    port = int(os.environ.get("PORT", 8086))
    for d in (INGEST, STAGING):
        if not os.path.isdir(d):
            log("FATAL: %s is not a directory" % d)
            sys.exit(1)
    if not TOKEN:
        log("WARNING: UPLOAD_TOKEN unset - accepting unauthenticated uploads")
    # Staging and ingest must share a filesystem or the atomic rename fails with
    # EXDEV. Bind-mounting them as two separate docker volumes is the easy way to
    # get this wrong, so check at startup instead of discovering it mid-upload.
    if os.stat(INGEST).st_dev != os.stat(STAGING).st_dev:
        log("FATAL: %s and %s are on different filesystems - atomic rename "
            "impossible. Mount their common parent as ONE volume." % (STAGING, INGEST))
        sys.exit(1)
    log("book-receiver listening on :%d  ingest=%s staging=%s" % (port, INGEST, STAGING))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
