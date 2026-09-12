#!/bin/sh
# Start the monitor automatically, without touching the read-only rootfs.
#
# /etc/upstart/kmc.conf runs "start on framework_ready" and does this:
#     BRIDGE_EMERGENCY="/mnt/us/emergency.sh"
#     if [ -f "${BRIDGE_EMERGENCY}" ] ; then
#         [ -x "${BRIDGE_EMERGENCY}" ] || chmod +x "${BRIDGE_EMERGENCY}"
#         /bin/sh "${BRIDGE_EMERGENCY}"
#         return 0
#     fi
# So a file we create under /mnt/us -- which IS writable -- gets executed as
# root every time the framework starts. That covers a reboot AND every UI
# framework restart, including the ones the monitor fires to clear a wedged
# download queue: if the daemon ever fails to survive one, this puts it back.
#
# Nothing is displaced: with no emergency.sh, that job only writes two lines to
# the log and returns.
#
# cron was the original plan and is not possible here -- / is ext3 mounted ro
# with errors=remount-ro, and no cron spool directory exists.
HOOK=/mnt/us/emergency.sh
DAEMON=/mnt/us/extensions/kfx-sync/kfx-daemon.sh
MARK='kfx-sync boot hook'

case "${1:-install}" in
  remove)
        if [ -f "$HOOK" ] && grep -qF "$MARK" "$HOOK" 2>/dev/null; then
            rm -f "$HOOK"; echo "boot hook removed"
        elif [ -f "$HOOK" ]; then
            echo "$HOOK exists but is NOT ours -- leaving it alone"
        else
            echo "no boot hook installed"
        fi
        exit 0 ;;
esac

if [ -f "$HOOK" ] && ! grep -qF "$MARK" "$HOOK" 2>/dev/null; then
    echo "$HOOK already exists and was not written by us."
    echo "Refusing to overwrite it. Inspect it first."
    exit 1
fi

cat > "$HOOK" <<'HOOKEOF'
#!/bin/sh
# kfx-sync boot hook -- run by /etc/upstart/kmc.conf on framework_ready.
# Must return immediately: kmc runs this synchronously before continuing.
# setsid so the monitor is not killed when this job stops with the framework.
echo "$(date '+%m-%d %H:%M:%S') boot hook fired" >> /mnt/us/kfx-daemon.log 2>/dev/null
setsid sh -c 'sleep 30; /mnt/us/extensions/kfx-sync/kfx-daemon.sh ensure' >/dev/null 2>&1 &
exit 0
HOOKEOF

chmod +x "$HOOK" 2>/dev/null
echo "installed $HOOK"
echo
echo "It runs at every framework start (boot, and after a UI restart)."
echo "It waits 30s for wifi, then starts the monitor only if it is not"
echo "already running, so it is safe to fire repeatedly."
echo
echo "To undo:  sh $0 remove"
