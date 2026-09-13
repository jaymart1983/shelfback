#!/bin/sh
# Name: KFX Dropbear Test
# Does the community dropbear actually RUN on this device?
#
# The KindleModding/KPM dropbear is hard-float with the right loader, but it
# wants glibc 2.33, and this device may be older (fbink was built against 2.20).
# Inference can't settle it -- an old binary runs on new glibc -- so this just
# downloads the binary and runs it. If the glibc is too old the loader says so
# in plain words; if it runs, that is the one to use.
#
# Downloads to /tmp (tiny), runs the binary with a bad flag so it only prints
# usage and exits -- no server started, no port opened. Cleans up after.
OUT=/mnt/us/kfxdropbear.txt
KPKG_URL="https://github.com/ttrssreal/dropbear-kindle/releases/download/v0.1.0/dropbear_kindle-0.1.0.kpkg"

exec 3>&1
say() { printf '%s\n' "$*" >&3; }
say "  testing whether a community dropbear runs here..."

W=/tmp/kfxdb.$$
rm -rf "$W"; mkdir -p "$W"

{
    echo "kfx dropbear test"
    echo "date: $(date)"
    echo

    echo "=== 1. this device's glibc ==="
    if [ -e /lib/libc.so.6 ]; then
        /lib/libc.so.6 2>/dev/null | head -1
        echo "  highest GLIBC symbol version present:"
        strings /lib/libc.so.6 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -t_ -k2 -V | tail -1 | sed 's/^/    /'
    else
        echo "  /lib/libc.so.6 not found; trying ldd --version"
        ldd --version 2>&1 | head -1 | sed 's/^/    /'
    fi

    echo
    echo "=== 2. download the KPM dropbear (kindlehf) ==="
    if curl -sSL --max-time 90 -o "$W/pkg.kpkg" "$KPKG_URL" 2>/dev/null; then
        echo "  downloaded: $(wc -c < "$W/pkg.kpkg" | tr -d ' ') bytes"
        echo "  sha256: $( (sha256sum "$W/pkg.kpkg" 2>/dev/null || openssl dgst -sha256 "$W/pkg.kpkg" 2>/dev/null) | grep -oE '[0-9a-f]{64}' | head -1)"
        echo "  expected: a76ab5576c8ecdbd347a66173c977b953abf3a96cf2054c05e0495bd58d71111"
        ( cd "$W" && tar xzf pkg.kpkg 2>/dev/null ) && echo "  unpacked"
    else
        echo "  download FAILED -- can this device reach github releases?"
    fi

    echo
    echo "=== 3. try to run it (bad flag -> usage only, no server) ==="
    if [ -f "$W/dropbear" ]; then
        chmod +x "$W/dropbear" 2>/dev/null
        echo "  \$ dropbear -TESTBADFLAG"
        "$W/dropbear" -TESTBADFLAG 2>&1 | head -4 | sed 's/^/    /'
        echo "  exit: $?"
        echo
        echo "  reading: 'Dropbear v...' or a usage line = IT RUNS."
        echo "           'GLIBC_2.xx not found' or 'No such file' = glibc too old."
    else
        echo "  no dropbear binary to test"
    fi

    rm -rf "$W"
} > "$OUT" 2>&1

say ""
sed -n '/=== 1/,$p' "$OUT" >&3
say ""
say "  full output: $OUT"
