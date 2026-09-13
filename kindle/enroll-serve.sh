#!/bin/sh
# enroll-serve.sh -- accept one SSH public key over HTTP, wait for the device
# owner to approve it, then answer. Run by tcpsvd, one copy per connection.
#
# It never writes authorized_keys itself. It only queues a request the menu can
# see, and waits for the menu to write a decision. Nothing is trusted without
# someone pressing approve on the Kindle.
#
#   client:  curl --max-time 130 --data-binary @~/.ssh/id_ed25519.pub \
#              http://<kindle>:<port>/enroll
#
# Shares a spool dir with the menu (default /tmp/kfx-enroll): pending/<id> holds
# the offered key, decision/<id> is written by the menu as "approve" or "deny".
ENROLL_DIR=${ENROLL_DIR:-/tmp/kfx-enroll}
ENROLL_WAIT=${ENROLL_WAIT:-120}
mkdir -p "$ENROLL_DIR/pending" "$ENROLL_DIR/decision" 2>/dev/null

respond() {   # $1 = status line, $2 = body
    printf '%s\r\n' "$1"
    printf 'Content-Type: text/plain\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n'
    printf '%s\n' "$2"
}

IFS= read -r _req || exit 0
_req=$(printf '%s' "$_req" | tr -d '\r')
_method=${_req%% *}; _rest=${_req#* }; _path=${_rest%% *}; _path=${_path%%\?*}

# headers: we need Content-Length to know how much body to read.
_clen=0
while IFS= read -r _h; do
    _h=$(printf '%s' "$_h" | tr -d '\r'); [ -z "$_h" ] && break
    case "$_h" in
        [Cc]ontent-[Ll]ength:*) _clen=$(printf '%s' "${_h#*:}" | tr -dc '0-9') ;;
    esac
done
case "$_clen" in ''|*[!0-9]*) _clen=0 ;; esac

if [ "$_method" != POST ] || [ "$_path" != /enroll ]; then
    respond "HTTP/1.0 404 Not Found" "POST your SSH public key to /enroll"
    exit 0
fi
[ "$_clen" -gt 0 ] && [ "$_clen" -le 20000 ] || { respond "HTTP/1.0 400 Bad Request" "no key in the request"; exit 0; }

# the body is the public key; keep only the first line, trimmed.
_key=$(head -c "$_clen" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -1)
case "$_key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) ;;
    *) respond "HTTP/1.0 400 Bad Request" "that is not an SSH public key"; exit 0 ;;
esac

_id=$(date +%s).$$
printf 'ip=%s\ntype=%s\nkey=%s\n' "${TCPREMOTEIP:-unknown}" "${_key%% *}" "$_key" \
    > "$ENROLL_DIR/pending/$_id" 2>/dev/null

# Wait for the owner to decide, on the device.
_n=0
while [ "$_n" -lt "$ENROLL_WAIT" ]; do
    if [ -f "$ENROLL_DIR/decision/$_id" ]; then
        _d=$(cat "$ENROLL_DIR/decision/$_id" 2>/dev/null)
        rm -f "$ENROLL_DIR/decision/$_id" "$ENROLL_DIR/pending/$_id" 2>/dev/null
        case "$_d" in
            approve*) respond "HTTP/1.0 200 OK" "approved -- your key is enrolled" ;;
            *)        respond "HTTP/1.0 403 Forbidden" "denied on the device" ;;
        esac
        exit 0
    fi
    sleep 2; _n=$((_n + 2))
done
rm -f "$ENROLL_DIR/pending/$_id" 2>/dev/null
respond "HTTP/1.0 408 Request Timeout" "no approval on the device in time"
exit 0
