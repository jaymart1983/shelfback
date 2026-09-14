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
- **The logs** are all in `/mnt/us/kfx-logs/`: `sync.log`, `daemon.log`,
  `update.log`, `recoveries.log`. Read them by mounting the Kindle, or over SSH.
- **Build numbers** are the deploy time (`mmddyyyy.hhmm`), shown at the top
  right and in the log. The menu restarts the background sync when it finds it
  running an older build, so relaunching is enough after a deploy.
- **Settings -> Calibre login** changes the address, username or password on the
  device, and tests the login straight away.
- **U) Check for updates** asks the update daemon to look now; it also checks
  every couple of hours by itself. See [updating](#updating).
- **Settings -> SSH** runs a static **dropbear** we build from source (see
  [SSH](#ssh)), key-only, as the dev account, on port 2222. Off by default;
  once on it survives a UI restart and reboot, and the firewall opens with it.
  The device generates its own host key on first start.

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

- `kindle/VERSION` is the release, and `menu.sh`'s `KFX_BUILD` must match it.
  `kindle/publish.sh` stamps both and can commit them; **publishing an update
  is committing a new VERSION**, and rolling one back is committing the old one.
- `kindle/MANIFEST` lists the files a release is made of.
- `kfx-update.sh` is a second daemon, separate from the sync daemon because the
  thing that restarts the sync daemon cannot be the sync daemon. It compares
  the two VERSIONs, fetches every file the manifest names, and installs only if
  all of them arrive.

It does not trust the download. Every `.sh` must parse; a file starting with
`<` is a web page, not a script; a version that is not a build stamp is
refused; a manifest name containing a slash or a leading dot is refused before
it becomes a path; and the downloaded `menu.sh` must already carry the version
being installed, because a CDN refreshes the files and the version marker
independently and a half-published release would otherwise install stale code
under a new number. The previous release is kept, and **if the sync
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
`update`. Write it (over SSH or USB) and the daemon acts on it within a tick.
Nothing in that vocabulary reboots the device or deletes anything: whoever can
write the file is whoever can already reach the device, which is not a reason to
trust them with more.

## SSH

Real key-based SSH, from a static `dropbear` we build for this device rather
than trust a prebuilt -- none of the community binaries matched (soft-float, or
wanting a newer glibc than this firmware has). `kindle/build-dropbear.sh`
reproduces it: official DROPBEAR source, a musl cross-toolchain, fully
**static** so one binary spans Kindle firmwares. It ships in the repo and
installs through the updater with a checksum like everything else.

- The binary is `dropbearmulti-armhf` (a soft-float `-armel` can join it for
  very old Kindles; the device picks by its float ABI).
- **Key-only, no root login.** You log in as the `kfx` account (created
  automatically with a random password nothing reads), whose home is
  `/var/local/kfx` on ext3 -- a real filesystem, so `dropbear` trusts the
  ownership and permissions of `~/.ssh/authorized_keys`. It refuses that file on
  FAT (`/mnt/us`) or when it is owned by root, silently, so the home lives here
  and the account owns the tree.
- **Enroll a key over the network** (Settings -> Enroll an SSH key): the device
  opens a short HTTP window. The **requester generates its own keypair** and
  sends only the **public** half plus a name; you approve it on the Kindle by
  pressing `y` after checking the fingerprint matches. Nothing secret ever
  crosses the wire -- the private key stays with the requester -- so the plain
  HTTP and the device's pbkdf2-less openssl never matter. The `y` is the
  authorisation; the fingerprint compare guards against a key swapped in transit.
  The enroll page can make the key **in the browser** (a download button hands
  over the private half; only the public half is submitted) using a vendored
  `nacl.min.js` (WebCrypto is unavailable over plain HTTP), or take one you
  paste. Or do it from a terminal:
  ```sh
  ssh-keygen -t ed25519 -f kfx_key -N "" -C laptop
  curl -s --data-urlencode 'name=laptop' \
       --data-urlencode "key=$(cat kfx_key.pub)" http://<kindle>:2223/enroll
  ssh -i kfx_key -p 2222 kfx@<kindle-ip>
  ```
  Enrollments are recorded (name / when / fingerprint) in `kfx-state/enrolled`.
- The host key is generated on the device on first start and kept in state, so
  a client's fingerprint check stays stable.

```sh
ssh -i kfx_key -p 2222 kfx@<kindle-ip>
```

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
  publish.sh         stamp a release so devices can install it over the air
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
