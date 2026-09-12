#!/bin/sh
# One short line for KUAL to show beside the menu entry. KUAL runs this while
# drawing the menu, so it must be cheap and must always print something: no
# network, no library scan, nothing that can block.
#
# It reports the background sync, which is the part that matters -- the menu
# is only a window onto it.
PIDFILE=${PIDFILE:-/var/local/kfx-daemon.pid}
MENU=${MENU:-/mnt/us/extensions/kfx-sync/menu.sh}

build=$(sed -n 's/^KFX_BUILD=\([0-9.]*\).*/\1/p' "$MENU" 2>/dev/null | head -1)
[ -n "$build" ] || build='?'

pid=$(cat "$PIDFILE" 2>/dev/null)
# A pid that has been reused since a reboot must not read as "running", so
# check the process is really ours before believing the file.
if [ -n "$pid" ] && [ -d "/proc/$pid" ] && grep -qa kfx-daemon "/proc/$pid/cmdline" 2>/dev/null; then
    printf 'sync running - build %s\n' "$build"
else
    printf 'sync stopped - build %s\n' "$build"
fi
