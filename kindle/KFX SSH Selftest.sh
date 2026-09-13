#!/bin/sh
# Name: KFX SSH Selftest
# Does the SSH server accept a key AT ALL, tested from the device itself?
# Mints a throwaway key with dropbearkey, authorizes it for kfx, then uses
# dbclient (same multi-binary) to log in to localhost as kfx. This separates
# "server/authorized_keys is broken" from "the remote client/key is the issue"
# with no laptop involved. Cleans up the throwaway key afterwards.
OUT=/mnt/us/kfx-logs/sshselftest.txt
BIN=/mnt/us/extensions/kfx-sync/dropbearmulti-armhf
AK=/var/local/kfx/.ssh/authorized_keys
{
    echo "kfx ssh selftest -- $(date)"
    [ -x "$BIN" ] || { echo "no dropbear binary"; exit 0; }
    echo "=== mint a throwaway client key ==="
    rm -f /tmp/stkey /tmp/stkey.pub
    "$BIN" dropbearkey -t ed25519 -f /tmp/stkey 2>/dev/null | sed 's/^/  /'
    "$BIN" dropbearkey -y -f /tmp/stkey 2>/dev/null | grep '^ssh-' > /tmp/stkey.pub
    echo "  pub: $(awk '{print $1" ..."}' /tmp/stkey.pub)"
    echo "=== authorize it for kfx (temporarily) ==="
    cp "$AK" /tmp/ak.bak 2>/dev/null
    cat /tmp/stkey.pub >> "$AK"
    chown kfx "$AK" 2>/dev/null; chmod 600 "$AK" 2>/dev/null
    echo "  authorized_keys now $(grep -c . "$AK") line(s)"
    echo "=== dbclient -> kfx@127.0.0.1:2222 with that key ==="
    "$BIN" dbclient -y -i /tmp/stkey -p 2222 kfx@127.0.0.1 'echo SELFTEST_OK; id' 2>&1 | sed 's/^/  /'
    echo "  (SELFTEST_OK above = server+authorized_keys work; the issue is the remote key/client)"
    echo "  (a failure above = server-side problem; the message says what)"
    echo "=== restore authorized_keys ==="
    [ -f /tmp/ak.bak ] && cp /tmp/ak.bak "$AK" && chown kfx "$AK" 2>/dev/null && chmod 600 "$AK" 2>/dev/null
    rm -f /tmp/stkey /tmp/stkey.pub /tmp/ak.bak
    echo "  restored ($(grep -c . "$AK") line(s))"
} > "$OUT" 2>&1
echo; cat "$OUT"; echo; echo "  saved: $OUT"
