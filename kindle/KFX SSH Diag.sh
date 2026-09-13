#!/bin/sh
# Name: KFX SSH Diag
# Where does dropbear look for the key, and is it there?
# dropbear says "0 fails, exit before auth" = the offered key is not in the
# authorized_keys it reads. That file is the LOGIN USER'S ~/.ssh/authorized_keys
# -- on /var/local, which USB cannot see. This dumps the ground truth.
OUT=/mnt/us/kfx-logs/sshdiag.txt
mkdir -p /mnt/us/kfx-logs 2>/dev/null
{
    echo "kfx ssh diag -- $(date)"
    echo
    echo "=== the account (from /etc/passwd) ==="
    grep '^kfx:' /etc/passwd 2>/dev/null || echo "  no kfx account!"
    H=$(awk -F: '$1=="kfx"{print $6; exit}' /etc/passwd 2>/dev/null)
    echo "  home = ${H:-<none>}"
    echo
    echo "=== that home's .ssh (perms + owner as dropbear sees them) ==="
    ls -ld "$H" "$H/.ssh" 2>/dev/null | sed 's/^/  /'
    ls -l "$H/.ssh/authorized_keys" 2>/dev/null | sed 's/^/  /' || echo "  no authorized_keys at $H/.ssh/"
    echo
    echo "=== authorized_keys content (type + comment only) ==="
    if [ -f "$H/.ssh/authorized_keys" ]; then
        awk '{print "  "$1" ... "$NF}' "$H/.ssh/authorized_keys" 2>/dev/null
        echo "  ($(grep -c . "$H/.ssh/authorized_keys" 2>/dev/null) line(s))"
    fi
    echo
    echo "=== the two candidate locations, explicitly ==="
    for f in /var/local/kfx/.ssh/authorized_keys /mnt/us/.ssh/authorized_keys; do
        echo "  $f:"
        [ -f "$f" ] && { ls -l "$f" | sed 's/^/    /'; awk '{print "    key: "$1" "$NF}' "$f"; } || echo "    (missing)"
    done
    echo
    echo "=== does the home key match /mnt/us/import_key.pub? ==="
    if [ -f "$H/.ssh/authorized_keys" ] && [ -f /mnt/us/import_key.pub ]; then
        b=$(awk '{print $2}' /mnt/us/import_key.pub)
        grep -qF "$b" "$H/.ssh/authorized_keys" && echo "  YES -- the enrolled key IS in the file dropbear reads" || echo "  NO -- the enrolled key is NOT there"
    fi
    echo
    echo "=== dropbear process + how it was started ==="
    ps 2>/dev/null | grep -E 'dropbear' | grep -v grep | sed 's/^/  /'
} > "$OUT" 2>&1
echo; cat "$OUT"; echo; echo "  saved: $OUT"
