# shelfback

Get the books off your Kindle and into your own Calibre library, by themselves.

A book you buy or borrow arrives on the Kindle and nowhere else. shelfback runs
on the Kindle itself: it notices a new book, downloads it, removes the DRM with
the Kindle's own key, hands the file to [Calibre-Web Automated][cwa], waits
until Calibre confirms it really has it, and only then deletes the local copy.
A handful of jobs on the server side then tidy the library: real cover art,
series information, and covers the reader can actually display.

Nothing sits in between. The Kindle talks to Calibre directly.

> **This removes DRM from books.** Do that only with books you have bought, and
> only where doing so is lawful where you live. Everything here uses the
> Kindle's own key, on your own device, for your own library.

## What it does

1. **Notices** a book the Kindle knows about but does not have on disk.
2. **Asks for it** and watches the download. A download that receives nothing
   for a minute means the transfer queue has jammed -- see [the jam](#the-jam).
3. **Decrypts** it with `kfxdedrm` on the Kindle. Nothing leaves the device
   encrypted.
4. **Completes it.** A KFX book can be several files; the book names the pieces
   it needs and shelfback will not upload a book that is missing any.
5. **Uploads** it to Calibre-Web Automated as a logged-in user.
6. **Confirms** Calibre holds it, keyed on the Amazon ID, then **deletes** the
   local copy. A book that never arrives is fetched again rather than lost.

Books that arrive as AZW3 rather than KFX go the same way; they are a single
file, so there is nothing to piece together.

## What you need

| Where | What |
|---|---|
| Kindle | A jailbroken Kindle with `kterm` and the `kfxdedrm` scriptlet at `/mnt/us/extensions/kfxdedrm-scriptlet`. [KUAL][kual] is optional -- see [two ways in](#two-ways-in). |
| Server | [Calibre-Web Automated][cwa] in Docker, with the **KFX Input** plugin (and **DeDRM** if you want the fallback). |
| Server | Anything that runs cron and can `docker exec` into that container. Written on Unraid; nothing depends on Unraid itself. |
| Calibre-Web | A user account for the Kindle with **upload**, **download** and **view** permissions. It does not need to be an admin. |

The Kindle needs `curl` (any recent firmware has it) and about 1 GB free for
books in flight.

## Install

### On the Kindle

```sh
# from a checkout, with the Kindle mounted over USB
kindle/deploy.sh    # copies the scripts, installs the launcher, stamps a build number
```

That installs both ways in, whether or not you have KUAL.

Then create two files in `/mnt/us/extensions/kfx-sync/`:

`config` -- see [kindle/config.example](kindle/config.example):

```sh
BACKEND=cwa
```

`cwa.conf` -- your Calibre-Web address and login, see
[kindle/cwa.conf.example](kindle/cwa.conf.example):

```sh
CWA_URL='http://192.168.1.10:8083'
CWA_USER='kindle@example.net'
CWA_PASS='...'
```

`cwa.conf` is plain text on the Kindle's USB storage: anyone who mounts the
Kindle can read it. Use an account that can upload books and nothing else.

Then the boot hook, which is what lets you forget about all of this: it starts
the background sync at every framework start, so a reboot brings it back and
you never have to open the menu to make a book arrive.

```sh
sh /mnt/us/extensions/kfx-sync/install-boot-hook.sh
```

Then open **KFX Sync**. The top right shows the build number; the first line
shows whether Calibre is reachable.

#### Two ways in

Most of the time you never open it at all -- the background sync does the work
while you read. When you do want the menu, there are two routes, and neither
depends on the other:

- **Without KUAL:** `documents/00 KFX Sync.sh` is a [scriptlet][scriptlet] -- a
  `.sh` file with a `# Name:` header, which the library shows as a book. Open
  the book and it runs.
- **With KUAL:** `menu.json` sits in the extension directory, so **KFX Sync**
  appears in the KUAL menu with a line saying whether the sync is running and
  which build it is.

Both start the same `launch.sh`. A Kindle with no KUAL loses nothing, and
`menu.json` is just an unread file there.

### On the server

Copy `unraid/*` somewhere the host can run them (they `docker exec` into the
CWA container) and add them to cron:

```cron
2-59/10 * * * * /path/to/backfill-asins.sh      >/dev/null 2>&1
5-59/10 * * * * /path/to/fix-covers.sh          >/dev/null 2>&1
8-59/10 * * * * /path/to/baseline-jpegs.sh --since 24 >/dev/null 2>&1
3-59/5  * * * * /path/to/series-from-amazon.sh  >/dev/null 2>&1
```

**`backfill-asins` is not optional.** Calibre-Web shows a book's Amazon ID only
when it is stored as an `amazon` identifier, and that identifier is what the
Kindle checks to know a book arrived. Without it, books are uploaded again and
again.

## The server-side jobs

| Job | What it does |
|---|---|
| `backfill-asins` | Records each imported book's Amazon ID from the filename CWA logs at import. Never guesses from titles. |
| `fix-covers` | Replaces the greyscale, e-ink covers Amazon ships with full-size colour art, found by Amazon ID. |
| `baseline-jpegs` | Converts progressive JPEGs to baseline, losslessly. Some e-readers decode a progressive JPEG at 1/8 resolution and show a blurred mess. |
| `series-from-amazon` | Fills in series name and number from the book's Amazon page. Calibre's own Amazon source gives up after one rate-limited request; this one retries. |
| `embed-covers` | Puts the library cover inside the EPUB. Run by hand. |
| `confirmed-asins` | Publishes the list of books Calibre genuinely holds. Only needed by the retired receiver. |

## Living with it

- **The menu** shows Calibre's state, the background sync, counts, and a book
  list with each book's status: Queued, Downloading, Stuck, Waiting Part, Not
  Sent, Not KFX, Sent, Sent Success.
- **The log** is on the Kindle at `/mnt/us/dedrm/sync.log`. Read it by mounting
  the Kindle over USB.
- **Build numbers** are the deploy time (`mmddyyyy.hhmm`), shown at the top
  right and in the log. The menu restarts the background sync when it finds it
  running an older build, so relaunching is enough after a deploy.
- **Settings -> Calibre login** changes the address, username or password on the
  device, and tests the login straight away.
- **U) Check for updates** asks the update daemon to look now; it also checks
  every couple of hours by itself. See [updating](#updating).
- **Settings -> Remote access (dev)** puts an FTP server on `/mnt/us` for
  pulling the log and pushing a test script without a USB cable. It serves as
  root with **no password**, so it is off by default and has to be confirmed --
  but once on it stays on until you turn it off, because waiting for the next
  jam can take hours. The daemon puts it back after the framework restart that
  clears a jam.

### When something is wrong

| Symptom | What it means |
|---|---|
| `calibre: ... (Error login)` | The username or password is refused. |
| `calibre: ... (Error curl 7)` | Nothing answered at that address. |
| `STUCK: no book data in 60s` | The transfer queue jammed; a UI restart follows. |
| `DECRYPTION: FAILED` + `REASON:` | What `kfxdedrm` said. Its full output is in `/mnt/us/dedrm/.dedrm-last.log`. |
| `WAITING FOR PART` | A piece of a multi-file book has not downloaded yet. |
| A book stays **Sent** | Calibre has it but `backfill-asins` has not recorded its Amazon ID yet. |

## Updating

The device can update itself from this repository, so a fix does not need a
cable:

- `kindle/VERSION` is the release. **Committing a new VERSION publishes an
  update**; committing the old one rolls it back.
- `kindle/MANIFEST` lists the files a release is made of.
- `kfx-update.sh` is a second daemon, separate from the sync daemon because the
  thing that restarts the sync daemon cannot be the sync daemon. It compares
  the two VERSIONs, fetches every file the manifest names, and installs only if
  all of them arrive.

It does not trust the download. Every `.sh` must parse; a file starting with
`<` is a web page, not a script; a version that is not a build stamp is
refused; and a manifest name containing a slash or a leading dot is refused
before it becomes a path. The previous release is kept, and **if the sync
daemon will not start on the new code, the old code goes back** and the daemon
is restarted on it. A failed update has to leave a working Kindle, because the
alternative is finding a USB cable.

The build number shown on screen always means "the code that is running": the
incoming `menu.sh` is stamped with the version being installed.

```sh
kfx-update.sh check      # one cycle now, printing what happened
kfx-update.sh status     # what is installed, and is the daemon up
kfx-update.sh request    # ask a running daemon to check
```

### Driving it without a cable

`/mnt/us/extensions/kfx-sync/command` holds **one word**, is read once and
deleted, and accepts only: `run`, `stop`, `restart-ui`, `update`, `remote-on`,
`remote-off`. Write it over FTP and the daemon acts on it within a tick.
Nothing in that vocabulary reboots the device or deletes anything: whoever can
write the file is whoever can reach the FTP port, which is not a reason to
trust them with more.

## The jam

Sharing a book to this Kindle jams its transfer queue: downloads stop, only the
small sidecar files arrive, and nothing recovers on its own. Restarting the
Kindle's UI framework clears it, and nothing else does -- not the download
manager, not the to-do queue, not a cover refresh.

So shelfback treats a jam as normal. A download that receives no book data for
a minute is a jam; the background process restarts the UI framework, which
tears down the menu but not itself, and asks again. Any one book gets two
restarts; after that it is left alone and shown as Stuck, so a book that cannot
be downloaded never turns into a restart loop.

Cover art is a **symptom** of the jam, not a cause. An earlier version waited
for cover art before requesting a book, and only delayed every book by half an
hour. See [docs/design-notes.md](docs/design-notes.md).

## Layout

```
kindle/      what runs on the Kindle
  KFX Sync.sh        the scriptlet, copied into documents/ as "00 KFX Sync"
  menu.json          the KUAL entry, if KUAL is installed
  launch.sh          what both of those start: opens the front end in kterm
  kual-status.sh     the one-line status KUAL shows beside the entry
  menu.sh            the front end, and every sync step
  kfx-daemon.sh      the background process: timed syncs, jam recovery
  kfx-update.sh      the update daemon: pull, verify, install, roll back
  MANIFEST           the files a release is made of
  VERSION            the release; committing a new one publishes an update
  cwa.sh             talking to Calibre-Web: login, book list, upload
  deploy.sh          copy to a mounted Kindle, stamping a build number
  install-boot-hook.sh   start the background process after a reboot
unraid/      the cron jobs that tidy the library
legacy/      receiver.py, the service that used to sit in the middle
docs/        design notes: what was measured, and what was wrong
```

## Status

A personal project, running on one Kindle against one Calibre-Web Automated
instance. It is not packaged, versioned or tested anywhere else. Read the
scripts before running them.

[cwa]: https://github.com/crocodilestick/Calibre-Web-Automated
[kual]: https://www.mobileread.com/forums/showthread.php?t=203326
[scriptlet]: https://www.mobileread.com/forums/showthread.php?t=323568
