#!/bin/sh
# Name: KFX User Test
# Can we add a non-root FTP account, and would it survive?
#
# busybox ftpd here authenticates against the system accounts: "anonymous" is
# rejected 530 because there is no such account. A dedicated low-privilege user
# is the right answer -- but /etc/passwd and /etc/shadow live on the read-only
# root filesystem, so the real questions are whether we can write there at all
# and whether a write persists.
#
# THIS PROBE ONLY READS AND REPORTS. It creates no account and leaves no change
# on the rootfs. The one write it attempts is a temp file during a remount
# test, which it removes and reverts. Password hashes are never printed -- only
# whether each account has one.
OUT_TXT=/mnt/us/kfxuser.txt

exec 3>&1
say() { printf '%s\n' "$*" >&3; }
say "  looking at the account setup (read-only)..."

{
    echo "kfx user test -- read-only"
    echo "date: $(date)"
    echo "running as: uid=$(id -u) $(id -un 2>/dev/null)"
    echo

    echo "=== 1. accounts that exist (/etc/passwd) ==="
    echo "  name : uid : shell : home"
    awk -F: '{ printf "  %-12s %-5s %-16s %s\n", $1, $3, $7, $6 }' /etc/passwd 2>/dev/null

    echo
    echo "=== 2. which accounts have a usable password (NO hashes shown) ==="
    if [ -r /etc/shadow ]; then
        awk -F: '{
            st="no password set"
            if ($2 != "" && $2 != "*" && $2 != "!" && $2 != "!!") st="HAS a password"
            printf "  %-12s %s\n", $1, st
        }' /etc/shadow 2>/dev/null
    else
        echo "  /etc/shadow is not readable as this user"
    fi

    echo
    echo "=== 3. is /etc a symlink, and what fs is it on ==="
    ls -ld /etc 2>/dev/null | sed 's/^/  /'
    echo "  mount line for the filesystem holding /etc:"
    mount 2>/dev/null | grep -E ' / |on / ' | sed 's/^/    /'
    echo "  df /etc:"
    df /etc 2>/dev/null | sed 's/^/    /'

    echo
    echo "=== 4. tools for managing accounts ==="
    for a in adduser addgroup useradd passwd chpasswd mkpasswd openssl; do
        _w=$(command -v "$a" 2>/dev/null)
        printf '  %-10s %s\n' "$a" "${_w:-MISSING}"
    done
    echo "  busybox applets among them:"
    busybox --list 2>/dev/null | grep -xE 'adduser|addgroup|passwd|chpasswd|mkpasswd' | sed 's/^/    /'

    echo
    echo "=== 5. can the root filesystem be made writable, reversibly? ==="
    _was_ro=$(mount 2>/dev/null | grep -E 'on / ' | grep -c '\bro\b')
    echo "  / is currently: $( [ "$_was_ro" -gt 0 ] && echo read-only || echo read-write )"
    if mount -o remount,rw / 2>/tmp/kfxremount.err; then
        echo "  remount rw: SUCCEEDED"
        if touch /etc/.kfxwritetest 2>/dev/null; then
            echo "  write to /etc: SUCCEEDED (and will be removed now)"
            rm -f /etc/.kfxwritetest 2>/dev/null
        else
            echo "  write to /etc: failed even after remount rw"
        fi
        # Put it back the way it was.
        [ "$_was_ro" -gt 0 ] && mount -o remount,ro / 2>/dev/null
        echo "  restored / to: $(mount 2>/dev/null | grep -E 'on / ' | grep -qc '\bro\b' >/dev/null && mount | grep 'on / ' | grep -o '\br[ow]\b' | head -1)"
    else
        echo "  remount rw: FAILED -- $(head -1 /tmp/kfxremount.err 2>/dev/null)"
        echo "  (a new account in /etc/passwd would not be possible this way)"
    fi
    rm -f /tmp/kfxremount.err

    echo
    echo "=== 6. does ftpd drop to the logged-in user? (usage/flags) ==="
    busybox ftpd --help 2>&1 | head -8 | sed 's/^/  /'
} > "$OUT_TXT" 2>&1

say ""
sed -n '/=== 1/,$p' "$OUT_TXT" >&3
say ""
say "  full output: $OUT_TXT  (no account created, no change left behind)"
