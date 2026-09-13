#!/bin/sh
# Name: KFX SSH Probe
# What can this device do for SSH, measured rather than assumed?
#
# The plan is: the Kindle mints a client keypair, keeps the public half in its
# own authorized_keys, and hands the private half to a client -- encrypted with
# a passphrase so it is safe over plain HTTP. Two things have to be true for
# that, and both depend on tools that may or may not be here:
#   1. the device can GENERATE a usable SSH keypair
#   2. the device can ENCRYPT the private half with a passphrase
# This checks both, and does a real encrypt->decrypt round trip to prove it.
#
# Read-only. Writes only to /tmp, and cleans up.
OUT=/mnt/us/kfxssh.txt
exec 3>&1
say() { printf '%s\n' "$*" >&3; }
say "  measuring SSH tooling..."

have() { command -v "$1" >/dev/null 2>&1 && echo "$(command -v "$1")" || echo MISSING; }

{
    echo "kfx ssh probe"
    echo "date: $(date)"
    echo

    echo "=== 1. key-generation tools ==="
    printf '  ssh-keygen      %s\n' "$(have ssh-keygen)"
    printf '  dropbearkey     %s\n' "$(have dropbearkey)"
    printf '  dropbearconvert %s\n' "$(have dropbearconvert)"
    printf '  dropbear        %s\n' "$(have dropbear)"
    printf '  ssh (client)    %s\n' "$(have ssh)"
    echo "  searching the filesystem for dropbear/ssh binaries not on PATH:"
    find / -name 'dropbear*' -o -name 'ssh-keygen' 2>/dev/null | head -10 | sed 's/^/    /'
    [ -d /mnt/us/extensions ] && { echo "  under extensions/:"; find /mnt/us/extensions -iname '*dropbear*' -o -iname '*ssh*' 2>/dev/null | head -10 | sed 's/^/    /'; }

    echo
    echo "=== 2. crypto tools ==="
    printf '  openssl         %s\n' "$(have openssl)"
    openssl version 2>/dev/null | sed 's/^/    /'
    printf '  gpg             %s\n' "$(have gpg)"

    echo
    echo "=== 3. what openssl can generate ==="
    if command -v openssl >/dev/null 2>&1; then
        echo "  genrsa:   $(openssl genrsa 2048 >/tmp/kfxk.$$ 2>/dev/null && echo OK || echo no)"
        echo "  ed25519:  $(openssl genpkey -algorithm ED25519 -out /tmp/kfxe.$$ 2>/dev/null && echo OK || echo 'no (too old)')"
        rm -f /tmp/kfxk.$$ /tmp/kfxe.$$
    else
        echo "  (no openssl)"
    fi

    echo
    echo "=== 4. LIVE passphrase encrypt -> decrypt round trip ==="
    if command -v openssl >/dev/null 2>&1; then
        printf 'secret-key-material-test' > /tmp/kfxpt.$$
        if openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:testpass123 \
               -in /tmp/kfxpt.$$ -out /tmp/kfxct.$$ 2>/dev/null; then
            echo "  encrypt: OK ($(wc -c < /tmp/kfxct.$$ | tr -d ' ') bytes of ciphertext)"
            _dec=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:testpass123 -in /tmp/kfxct.$$ 2>/dev/null)
            if [ "$_dec" = "secret-key-material-test" ]; then
                echo "  decrypt with right pass: OK (round trip works)"
            else
                echo "  decrypt: FAILED (got [$_dec])"
            fi
            _wrong=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:wrongpass -in /tmp/kfxct.$$ 2>/dev/null)
            echo "  decrypt with wrong pass: $( [ "$_wrong" = "secret-key-material-test" ] && echo 'LEAKED (bad)' || echo 'correctly refused' )"
        else
            echo "  encrypt: FAILED -- this openssl cannot do -pbkdf2"
            echo "  retry without -pbkdf2:"
            openssl enc -aes-256-cbc -salt -pass pass:testpass123 -in /tmp/kfxpt.$$ -out /tmp/kfxct.$$ 2>/dev/null \
                && echo "    plain -aes-256-cbc: OK" || echo "    also failed"
        fi
        rm -f /tmp/kfxpt.$$ /tmp/kfxct.$$
    else
        echo "  (no openssl -- would need another way to encrypt)"
    fi

    echo
    echo "=== 5. where keys would live ==="
    echo "  /mnt/us writable: $( touch /mnt/us/.kfxw 2>/dev/null && { echo yes; rm -f /mnt/us/.kfxw; } || echo no )"
} > "$OUT" 2>&1

say ""
sed -n '/=== 1/,$p' "$OUT" >&3
say ""
say "  full output: $OUT"
