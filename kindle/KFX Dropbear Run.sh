#!/bin/sh
# Name: KFX Dropbear Run
# Does OUR freshly built static dropbear actually run on this Kindle?
#
# It is hard-float (matches this device) and fully static (no libc needed), but
# it is static-PIE, and a 2018 kernel can refuse that form. The real proof is
# generating a key with it. If dropbearkey produces an ed25519 key, the binary
# works end to end; if the kernel rejects it we see the exec error here.
OUT=/mnt/us/kfxdbrun.txt
BIN=/mnt/us/dropbearmulti-armhf

exec 3>&1
say() { printf '%s\n' "$*" >&3; }

{
    echo "kfx dropbear run test"
    echo "date: $(date)"
    echo "kernel: $(uname -a)"
    echo
    if [ ! -f "$BIN" ]; then echo "  MISSING: $BIN (copy it to /mnt/us first)"; exit 0; fi
    chmod +x "$BIN" 2>/dev/null
    echo "  sha256: $( (sha256sum "$BIN" 2>/dev/null || md5sum "$BIN") | cut -d' ' -f1)"
    echo
    echo "=== 1. bare exec (does the kernel load static-PIE?) ==="
    "$BIN" 2>&1 | head -3 | sed 's/^/    /'
    echo "    (a usage/version line = it execs; 'not found'/'Exec format' = kernel refused)"
    echo
    echo "=== 2. generate an ed25519 host key with it ==="
    rm -f /tmp/kfxhk.$$
    if "$BIN" dropbearkey -t ed25519 -f /tmp/kfxhk.$$ >/tmp/kfxkg.$$ 2>&1; then
        echo "    dropbearkey: OK"
        grep -iE 'fingerprint|public' /tmp/kfxkg.$$ | head -2 | sed 's/^/    /'
        echo "    key file bytes: $(wc -c < /tmp/kfxhk.$$ 2>/dev/null)"
    else
        echo "    dropbearkey FAILED:"
        head -4 /tmp/kfxkg.$$ | sed 's/^/    /'
    fi
    rm -f /tmp/kfxhk.$$ /tmp/kfxkg.$$
} > "$OUT" 2>&1

say ""
cat "$OUT" >&3
say ""
say "  full output: $OUT"
