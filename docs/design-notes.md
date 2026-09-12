# Design notes

Things that were measured rather than assumed, including the ones that were
wrong first. Kept because each cost hours to find, and because the obvious
explanation was often the wrong one.

## The transfer queue jams when a book is shared

Sharing a book jams the Kindle's transfer queue. Afterwards every download
stalls with only the ~8KB sidecar arriving, and cover art stops arriving too:
covers and book content share one queue.

**Only a UI framework restart clears it** (`initctl restart lab126_gui`). Ruled
out with evidence, each leaving covers at 0/6: the download manager (`tmd`),
the to-do queue, `whisperstore`, toggling to-do processing, and
`archive refreshCache`. A reboot also works, but a framework restart is enough.

**Cover art is a symptom, not a cause.** Two freshly shared books that already
had covers still stalled. An earlier version waited for a cover before
requesting a book, on the theory that requesting too early caused the jam. It
delayed every new book by up to 30 minutes and prevented nothing -- a book that
has not downloaded often never gets a cover, so the wait always ran out.

**What works:** request immediately; treat 60 seconds with no book data as a
jam; restart the framework; ask again. Cap the restarts per book (two) so a
book that genuinely cannot be downloaded does not restart the UI forever.

The background process must survive the restart it triggers. `setsid` is enough:
it is reparented to init and outlives the framework. The menu, which runs inside
`kterm`, does not -- it dies with the restart, by design.

## A KFX book declares its own pieces

A KFX book can span several containers. Calibre's KFX Input plugin refuses the
book unless every container listed in its *container entity map* is present in
one `.kfx-zip` ("Book is incomplete ... Missing containers").

Measured on a real book:

- every piece is a plain `CONT` container once decrypted, and its own id
  (`CR!` + 28 characters) is the **first** such string in the file;
- `metadata.kfx` carries the map: its own id first, then every id the book needs;
- a single-file book has no map and mentions only its own id.

So completeness is decidable on the device with `grep`: the ids any file
mentions, minus the first id of each file present. Anything left over is
missing, and is looked for in the book's `.sdr/assets/attachables`.

The device's own packager does not always include the extra pieces, which is why
this check exists at all.

## Calibre-Web has no ASIN-keyed list

`/ajax/listbooks` returns every book in one request, but its `identifiers` field
is always empty, and neither OPDS nor the web search matches an Amazon ID. The
only place Calibre-Web shows it is each book's own page, as an
`amazon.com/dp/<ASIN>` link -- and only for identifiers stored as type `amazon`.
A `kindle` or `mobi-asin` identifier is invisible.

So the Kindle builds its own map: one list request for the current book ids, one
page read per id it has not seen, and ids that leave the list drop out. An
answer of "no ASIN" is re-checked after ten minutes, because a book uploaded
seconds ago has not been given its identifier yet -- caching that permanently
meant a book was never seen as confirmed and was uploaded again.

**A partial list is worse than no list.** A missing book means "fetch it again",
so if the list or any page cannot be read, the previous list stands and the pass
fails loudly.

## Calibre-Web serves a different file than it stores

With `embed_metadata` on, Calibre-Web rewrites the EPUB at download time,
stamping in the library's `cover.jpg` and metadata. Two consequences:

- changing only a cover changes what readers receive, so a cover fix should also
  touch the book's `last_modified`, or no reader will notice;
- the KOReader checksums Calibre-Web stores are of the **served** file, so
  hashing the stored EPUB and finding no match is normal, not damage.

## Progressive JPEGs render at 1/8 size

The reader's JPEG decoder reads only the DC coefficients of a progressive JPEG,
so a 1600x2400 cover arrives as roughly 200x300 and is upscaled into blocks.
Amazon's full-size cover art is progressive.

`jpegtran` transcodes the existing coefficients, so the pixels do not change --
but this build **keeps** progressive mode unless it is given a scan script with
a single interleaved scan (`0 1 2: 0 63 0 0;`). Every image is verified by
decoding both versions and comparing; anything that does not come out identical
is left alone.

## Amazon rate-limits, it does not block

Calibre's Amazon metadata source reports "Found 0 results" for ASINs that
clearly exist. Measured: roughly one request in four returns the real page
(~200KB); the rest are a 3.7KB bot-block page. The plugin tries once and gives
up. Retrying with jitter is the whole difference.

## Small things that cost time

- **Identify books by ASIN, never by title.** Title matching silently attached
  one book's cover and identifiers to another; two different series brandings of
  the same work defeat any similarity test.
- **Kindle shell:** busybox `grep` skips binary files unless given `-a`;
  `[ -w ]` returns true for root even on a read-only mount (test by writing);
  `date +%H` yields values like `09`, which arithmetic reads as octal.
- **`/tmp` is a 64MB tmpfs** shared with `/var`. Anything book-sized belongs
  under `/mnt/us`.
- **The Kindle cannot mount network shares.** No CIFS or NFS in the kernel, no
  SMB client, no SSH server. HTTP (`curl`) or FTP are the only ways in or out.
- **KUAL is optional, and being optional costs nothing.** KUAL reads
  `menu.json` from each directory under `/mnt/us/extensions/`, which is already
  where the code lives, so the extension entry is one inert file on a device
  without KUAL. The way in that needs nothing is a *scriptlet*: a `.sh` file in
  `documents/` whose `# Name:` header makes the library list it as a book.
  Both run the same `launch.sh`, and neither is a fallback for the other.
- **A shell can write a valid zip.** Stored entries, a CRC-32 taken from gzip's
  trailer, and `printf` octal escapes for the headers; the Kindle's own `unzip`
  reads the result back byte-for-byte. Used to rebuild a book's archive when a
  piece arrives late.

## Updating a device whose only other way in is a cable

The update daemon is separate from the sync daemon for one reason: it restarts
the sync daemon, and a process cannot reliably restart itself. Keeping them
apart also means a release that breaks the sync daemon outright still leaves a
process running that can fetch the next one.

What the checks are actually for, in the order they have mattered:

- **`sh -n` on every shell file.** A truncated download is the common failure
  on a device that loses wifi mid-transfer, and half a shell script is valid
  text but not a valid program.
- **A leading `<` is a web page.** `curl` without `-f` writes a 404 body to the
  output file, so a renamed file upstream arrives as HTML with a 200-shaped
  filename.
- **The version must be digits and dots.** It is read from the network and then
  compared, logged and stamped into `menu.sh`.
- **Manifest names must be plain.** They come from the network and become paths
  under the staging directory; a slash or a leading dot is refused rather than
  sanitised.

Rollback is the part worth having: install, restart the sync daemon, and if it
does not come up, put the previous files back and restart it on those. The
fallback if that fails too is a USB cable, which is exactly what this exists to
avoid.

One bug found in testing that is easy to write: the updater re-execs itself
after installing, because the file on disk is new while the running process is
old. Done unconditionally, `kfx-update.sh check` typed at a prompt turns into a
background daemon and never returns. It re-execs only when it is the daemon.

## A CDN publishes the files and the version marker separately

Measured 12 Sep 2026, minutes after a push: `menu.sh` on
raw.githubusercontent.com was already the new build while `VERSION` still
served the old one. A cache-busting query string did not help; they are
separate objects with separate lifetimes.

Either order is possible, and one of them is dangerous: a fresh `VERSION` with
stale files means installing old code under a new number. The first version of
the updater made that invisible, because it stamped the incoming `menu.sh` with
whatever `VERSION` said -- so the mislabelling was automatic.

So the code carries its own version, and the two must agree: `menu.sh`'s
`KFX_BUILD` must already equal the `VERSION` being installed, or the release is
half-published and the device waits for the next check. `publish.sh` stamps both
together so they cannot drift apart in the repository.

## The firewall drops everything inbound

Measured 12 Sep 2026. `tcpsvd` was listening on 2121, `netstat` showed it
bound, and connecting from the device itself to `127.0.0.1:2121` got an FTP
greeting -- while no host on the LAN could reach it, and the Kindle did not
answer ping either.

```
Chain INPUT (policy DROP)
ACCEPT tcp dpt:40317                        <- Amazon's own service
ACCEPT tcp state RELATED,ESTABLISHED
ACCEPT icmp state RELATED,ESTABLISHED
```

Outbound and established traffic are fine, which is why fetching updates from
GitHub always worked. Nothing else gets in. So any inbound server needs a rule
of its own, opened when it starts and removed when it stops -- and a port is
never left open with nothing behind it.

This cost a morning because the failure was silent in both directions: the
server said it had started (it had), and the client saw a timeout
indistinguishable from a sleeping device. Two wrong diagnoses came before the
measurement -- "the Kindle is asleep", then "tcpsvd must be missing" -- and the
probe that answered it took ten minutes to write. It should have been written
before the feature, not after the third guess.

What the device actually has, since that is what the guesses got wrong:
`ftpd`, `tcpsvd`, `nc` (with `-e` and `-l`), `telnetd`, `netstat`, `setsid`,
`iptables`, busybox 1.34.1. No `httpd`, no `inetd`, no `sshd`, no `dropbear`.

## Two servers, because read-only is a capability not a promise

busybox `ftpd` cannot write unless given `-w`. So the always-on log server is
not read-only by policy -- it is read-only because the program it runs has no
way to write. It serves `/mnt/us/kfx-logs` and nothing else, which is why the
logs were gathered into one directory: the alternative was serving `/mnt/us`,
where `cwa.conf` holds the Calibre password.

The read-write server is a separate process on a separate port with a separate
toggle, so "let me read the log" and "let me replace the code" are never the
same decision.

## What the Kindle can reach, and what it can host

Measured 11 Sep 2026 on this device (curl 7.86.0, OpenSSL 1.0.2q, 2018):

- **HTTPS to GitHub works, with certificate checking.** raw.githubusercontent.com,
  github.com and api.github.com all return 200 with verify result 0, over TLS 1.2,
  against a CA bundle of 145 certificates at `/etc/ssl/certs/ca-certificates.crt`.
  So the device can pull its own updates; no server is needed for that direction.
- **There is no SSH.** No `sshd`, no `dropbear`. Real SSH means installing
  `usbnet`, which is not present.
- **busybox does have `ftpd`,** plus `telnetd` and `nc`. `ftpd` expects a
  super-server in front of it (`tcpsvd` or `inetd`), and serves as root with no
  password -- which is why Settings offers it only for a fixed period.
