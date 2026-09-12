#!/bin/sh
# Name: KFX Remote Test
# Why is nothing listening on 2121?
#
# The menu reported that the FTP server had started, and no host on the LAN can
# reach the port. remote_start only checked that the process it backgrounded
# was still alive -- not that anything had bound the port -- so a super-server
# that started and failed can look like success.
#
# This finds out which of them this Kindle actually has, tries each one, and
# asks the kernel whether the port is listening. It stops everything it starts.
#
# Output: /mnt/us/kfxremote.txt, and on screen.
OUT_TXT=/mnt/us/kfxremote.txt
PORT=${PORT:-2121}

exec 3>&1
say() { printf '%s\n' "$*" >&3; }
say "  testing what can host an FTP server..."

listening() {
    command -v netstat >/dev/null 2>&1 || { echo "no netstat"; return 2; }
    if netstat -ln 2>/dev/null | grep -q "[:.]$PORT[^0-9]"; then echo yes; return 0; fi
    echo no; return 1
}

kill_all() {
    for _p in $(ps 2>/dev/null | grep -E 'tcpsvd|inetd|ftpd|nc ' | grep -v grep | awk '{print $1}'); do
        kill "$_p" 2>/dev/null
    done
    sleep 1
}

{
    echo "kfx remote test -- what can host ftpd on this Kindle?"
    echo "date: $(date)"
    echo

    echo "=== 1. addresses this device has ==="
    ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/  &/p' | sed 's/^ *//'
    echo "  what the menu would report:"
    ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1 | sed 's/^/    /'

    echo
    echo "=== 2. which programs exist ==="
    for a in ftpd tcpsvd inetd nc netstat telnetd httpd; do
        _w=$(command -v "$a" 2>/dev/null)
        if [ -n "$_w" ]; then printf '  %-9s %s\n' "$a" "$_w"
        else printf '  %-9s MISSING\n' "$a"; fi
    done
    echo "  busybox applets among them:"
    busybox --list 2>/dev/null | grep -xE 'ftpd|tcpsvd|inetd|nc|netstat' | sed 's/^/    /'

    echo
    echo "=== 3. is anything listening on $PORT right now? ==="
    echo "  $(listening)"
    netstat -ln 2>/dev/null | grep "[:.]$PORT[^0-9]" | sed 's/^/    /'

    echo
    echo "=== 4. try each way of hosting it ==="
    kill_all

    if command -v tcpsvd >/dev/null 2>&1; then
        echo "  -- tcpsvd --"
        setsid tcpsvd -vE 0.0.0.0 "$PORT" ftpd -w /mnt/us >/tmp/kfxrt.tcpsvd 2>&1 &
        sleep 2
        echo "    listening: $(listening)"
        head -3 /tmp/kfxrt.tcpsvd 2>/dev/null | sed 's/^/    says: /'
        kill_all
    else
        echo "  -- tcpsvd -- not present"
    fi

    if command -v inetd >/dev/null 2>&1; then
        echo "  -- inetd --"
        printf '%s stream tcp nowait root ftpd ftpd -w /mnt/us\n' "$PORT" > /tmp/kfxrt.inetd.conf
        setsid inetd -f /tmp/kfxrt.inetd.conf >/tmp/kfxrt.inetd 2>&1 &
        sleep 2
        echo "    listening: $(listening)"
        head -3 /tmp/kfxrt.inetd 2>/dev/null | sed 's/^/    says: /'
        kill_all
    else
        echo "  -- inetd -- not present"
    fi

    if command -v nc >/dev/null 2>&1; then
        echo "  -- nc as its own super-server --"
        echo "    does this nc take -e and -ll?"
        nc --help 2>&1 | head -6 | sed 's/^/      /'
        setsid nc -ll -p "$PORT" -e ftpd -w /mnt/us >/tmp/kfxrt.nc 2>&1 &
        sleep 2
        echo "    listening: $(listening)"
        head -3 /tmp/kfxrt.nc 2>/dev/null | sed 's/^/    says: /'
        kill_all
    else
        echo "  -- nc -- not present"
    fi

    echo
    echo "=== 5. anything left running? ==="
    ps 2>/dev/null | grep -E 'tcpsvd|inetd|ftpd' | grep -v grep | sed 's/^/  /' || echo "  nothing"
    echo "  port $PORT: $(listening)"

    rm -f /tmp/kfxrt.* 2>/dev/null
} > "$OUT_TXT" 2>&1

say ""
sed -n '/=== 2/,$p' "$OUT_TXT" >&3
say ""
say "  full output: $OUT_TXT"
