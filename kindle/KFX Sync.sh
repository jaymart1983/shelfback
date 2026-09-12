#!/bin/sh
# Name: 00 KFX Sync
# Author: built for jason
#
# A scriptlet: the "# Name:" line above makes this appear in the library as a
# book, and opening it runs the file. That is how a Kindle without KUAL gets a
# way in. With KUAL installed, menu.json in the extension directory offers the
# same thing and this file is simply another way to reach it.
#
# It holds no logic: documents/ is where the user's books live, so anything
# real belongs under extensions/ where it can be replaced by a deploy.
LAUNCH=/mnt/us/extensions/kfx-sync/launch.sh

if [ ! -f "$LAUNCH" ]; then
    printf '\nKFX Sync is not installed:\n%s\n\n' "$LAUNCH"
    printf 'Run kindle/deploy.sh with this Kindle mounted over USB.\n'
    sleep 8
    exit 1
fi
exec sh "$LAUNCH"
