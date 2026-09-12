#!/bin/sh
# Name: KFX Firewall Test
# The port is listening, the rule is added, and nothing gets in. Why?
#
# Known so far, measured: INPUT policy is DROP; tcpsvd binds the port; a
# connection from the device to 127.0.0.1 gets an FTP greeting; no host on the
# LAN can connect, to 2121 or 2122, with or without our ACCEPT rule.
#
# Filtering can happen in more than one place. A DROP in raw/PREROUTING or
# mangle runs BEFORE filter/INPUT, so a rule at the top of INPUT would never be
# consulted. This prints every table, adds the rule, prints INPUT again with
# interfaces and packet counts (-v, which the last probe omitted), and then
# LEAVES a read-only server running on 2121 so it can be tested from a laptop.
#
# It does not stop the server. Run "KFX Firewall Test stop" to clean up, or
# just reboot: nothing here survives one.
OUT_TXT=/mnt/us/kfxfirewall.txt
PORT=${PORT:-2121}
LOGDIR=${LOGDIR:-/mnt/us/kfx-logs}

exec 3>&1
say() { printf '%s\n' "$*" >&3; }

cleanup() {
    for _p in $(ps 2>/dev/null | grep -E 'tcpsvd|ftpd' | grep -v grep | awk '{print $1}'); do
        kill "$_p" 2>/dev/null
    done
    _n=0
    while [ "$_n" -lt 8 ]; do
        iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || break
        _n=$((_n + 1))
    done
    say "  stopped, and removed $_n rule(s)"
}

if [ "${1:-}" = stop ]; then cleanup; exit 0; fi

say "  probing the firewall..."

{
    echo "kfx firewall test"
    echo "date: $(date)"
    echo "port: $PORT"
    echo

    echo "=== 1. where iptables is, and what it is ==="
    printf '  which: %s\n' "$(command -v iptables 2>/dev/null || echo MISSING)"
    printf '  PATH:  %s\n' "$PATH"
    iptables --version 2>&1 | sed 's/^/  /'

    echo
    echo "=== 2. every table that can drop an inbound packet ==="
    for t in raw mangle security filter; do
        echo "  --- table $t ---"
        iptables -t "$t" -L -n -v 2>/dev/null | head -30 | sed 's/^/    /' \
            || echo "    (cannot read $t)"
    done

    echo
    echo "=== 3. INPUT before, with interfaces and counters ==="
    iptables -L INPUT -n -v --line-numbers 2>/dev/null | sed 's/^/  /'

    echo
    echo "=== 4. clear the decks ==="
    cleanup 2>/dev/null
    sleep 1
    echo "  listeners now:"
    netstat -ln 2>/dev/null | grep -E "[:.]$PORT[^0-9]" | sed 's/^/    /' || echo "    none"

    echo
    echo "=== 5. add the rule ==="
    mkdir -p "$LOGDIR" 2>/dev/null
    iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT
    echo "  insert exit: $?"
    echo "  INPUT now:"
    iptables -L INPUT -n -v --line-numbers 2>/dev/null | head -6 | sed 's/^/    /'

    echo
    echo "=== 6. start a READ-ONLY server on $PORT (no -w) ==="
    setsid tcpsvd -vE 0.0.0.0 "$PORT" ftpd "$LOGDIR" >/tmp/kfxfw.log 2>&1 &
    sleep 2
    echo "  listening:"
    netstat -ln 2>/dev/null | grep -E "[:.]$PORT[^0-9]" | sed 's/^/    /' || echo "    NOT LISTENING"
    echo "  tcpsvd says:"
    head -3 /tmp/kfxfw.log 2>/dev/null | sed 's/^/    /'
    echo "  local connect:"
    echo QUIT | nc -w 4 127.0.0.1 "$PORT" 2>/dev/null | head -1 | sed 's/^/    /'

    echo
    echo "=== 7. address to try from a laptop ==="
    ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' \
        | head -1 | sed "s|^|    ftp://|;s|$|:$PORT/|"

    echo
    echo "=== 8. counters after (run again later to see if packets arrived) ==="
    iptables -L INPUT -n -v 2>/dev/null | head -4 | sed 's/^/  /'
} > "$OUT_TXT" 2>&1

say ""
sed -n '/=== 5/,$p' "$OUT_TXT" >&3
say ""
say "  LEFT RUNNING on $PORT, read-only, serving $LOGDIR"
say "  full output: $OUT_TXT"
