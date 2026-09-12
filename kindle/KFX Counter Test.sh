#!/bin/sh
# Name: KFX Counter Test
# Do packets from the laptop reach this device at all?
#
# The last probe printed the firewall counters BEFORE the laptop tried to
# connect, and I read "0 packets" as proof that nothing arrived. That was not
# measured -- the attempts came afterwards. This measures it: counters now, a
# window while the laptop hammers the port, counters again.
#
# It also prints the MAC address, because a laptop with a stale or wrong ARP
# entry sends its packets to a machine that is not here, which looks exactly
# like a firewall drop from the other end.
PORT=${PORT:-2121}
WINDOW=${WINDOW:-90}

echo
echo "  this device:"
ifconfig 2>/dev/null | grep -E 'wlan0|HWaddr|inet addr' | sed 's/^/    /'
echo
echo "  listeners on $PORT:"
netstat -ln 2>/dev/null | grep -E "[:.]$PORT[^0-9]" | sed 's/^/    /' || echo "    NONE"
echo
echo "  rule and counters BEFORE:"
iptables -L INPUT -n -v 2>/dev/null | grep -E "dpt:$PORT|policy DROP" | sed 's/^/    /'
echo
echo "  arp table (who has this device been talking to):"
arp -a 2>/dev/null | head -5 | sed 's/^/    /'
echo
echo "  ---- now waiting ${WINDOW}s. Tell the laptop to connect. ----"
_i=0
while [ "$_i" -lt "$WINDOW" ]; do
    sleep 10; _i=$((_i + 10))
    printf '    %ss ' "$_i"
done
echo
echo
echo "  rule and counters AFTER:"
iptables -L INPUT -n -v 2>/dev/null | grep -E "dpt:$PORT|policy DROP" | sed 's/^/    /'
echo
echo "  any connection recorded:"
netstat -tn 2>/dev/null | grep -E "[:.]$PORT" | sed 's/^/    /' || echo "    none"
echo
echo "  If the ACCEPT counter moved, packets arrive and the server is at fault."
echo "  If only the DROP policy moved, they arrive and something else drops them."
echo "  If neither moved, they never got here."
echo
printf '  [enter] '
read x 2>/dev/null
