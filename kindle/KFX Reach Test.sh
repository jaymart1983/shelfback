#!/bin/sh
# Name: KFX Reach Test
# Can the Kindle reach this laptop, when the laptop cannot reach the Kindle?
#
# Measured so far: the ACCEPT rule for the port exists and matched 7 packets
# from a local connection, while connections from two different hosts on the
# LAN incremented nothing at all. So the packets are not being dropped by the
# Kindle -- they are not arriving. Between those two machines something is
# discarding them, and wireless client isolation does exactly that: stations
# can reach the internet and the gateway, and nothing can reach the stations.
#
# If this Kindle can open a connection TO the laptop while the laptop cannot
# open one to the Kindle, that is the answer, and it is a setting on the
# access point rather than anything this project can fix.
HOST=${1:-192.168.1.129}
PORT=${2:-9999}

echo
echo "  Kindle -> $HOST:$PORT"
echo

code=$(curl -sS -o /tmp/kfxreach.$$ -w '%{http_code}' --max-time 15 \
         "http://$HOST:$PORT/hello-from-kindle" 2>/tmp/kfxreacherr.$$)
rc=$?
echo "  curl exit: $rc   http: ${code:-none}"
[ "$rc" -ne 0 ] && sed 's/^/    /' /tmp/kfxreacherr.$$ 2>/dev/null
[ "$rc" -eq 0 ] && echo "  REACHED IT -- outbound works, inbound does not"
rm -f /tmp/kfxreach.$$ /tmp/kfxreacherr.$$

echo
echo "  this Kindle is $(ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1)"
echo "  gateway:      $(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')"
echo
echo "  can it reach the gateway?"
ping -c 2 -W 2 "$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')" 2>&1 | tail -2 | sed 's/^/    /'
echo
printf '  [enter] '
read x 2>/dev/null
