#!/bin/sh
# serve-logs.sh -- answer one HTTP request with one log file. No login.
#
# Run under tcpsvd, which hands each connection's socket to a fresh copy on
# stdin/stdout. That is how the logs are readable anonymously despite ftpd
# requiring an account: this speaks just enough HTTP to hand over a file, and
# it can ONLY read, and ONLY from the log directory -- there is nothing here
# that writes, and nothing that opens a path outside LOGDIR.
#
#   tcpsvd -vE 0.0.0.0 2121 serve-logs.sh
#
# Point a browser at http://<kindle>:2121/ for the index, or fetch one file
# directly: curl http://<kindle>:2121/sync.log
LOGDIR=${LOGDIR:-/mnt/us/kfx-logs}

# Read the request line, strip the trailing CR busybox read leaves on.
IFS= read -r _req || exit 0
_req=$(printf '%s' "$_req" | tr -d '\r')
# Drain the headers; we need none of them, but the client sends them.
while IFS= read -r _h; do
    _h=$(printf '%s' "$_h" | tr -d '\r')
    [ -z "$_h" ] && break
done

# "GET /name HTTP/1.1" -> path is the second field.
set -- $_req
_method=$1; _path=$2
_path=${_path%%\?*}              # drop any query string

send_head() {   # $1 = status line, $2 = content type
    printf '%s\r\n' "$1"
    printf 'Content-Type: %s\r\n' "$2"
    printf 'Connection: close\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf '\r\n'
}

# Only GET. Anything else is not something a log viewer does.
case "$_method" in
    GET|HEAD) ;;
    *) send_head "HTTP/1.0 405 Method Not Allowed" "text/plain"
       printf 'only GET\n'; exit 0 ;;
esac

# The index: the files that are actually there, as links.
if [ "$_path" = "/" ] || [ -z "$_path" ]; then
    send_head "HTTP/1.0 200 OK" "text/html"
    [ "$_method" = HEAD ] && exit 0
    printf '<!doctype html><meta charset=utf-8><title>kfx logs</title>\n'
    printf '<h3>kfx logs</h3><ul>\n'
    for _f in "$LOGDIR"/*; do
        [ -f "$_f" ] || continue
        _b=$(basename "$_f")
        _sz=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
        printf '<li><a href="/%s">%s</a> (%s bytes)</li>\n' "$_b" "$_b" "$_sz"
    done
    printf '</ul>\n'
    exit 0
fi

# A single file. The name is everything after the leading slash, and it must be
# a plain file name: no slash, no "..", nothing but the safe characters a log
# file is named with. This is the whole security boundary -- a request for
# /../cwa.conf or an absolute path must never resolve.
_name=${_path#/}
case "$_name" in
    *[!A-Za-z0-9._-]* | *..* | */* | "")
        send_head "HTTP/1.0 403 Forbidden" "text/plain"
        printf 'no\n'; exit 0 ;;
esac

_file="$LOGDIR/$_name"
if [ -f "$_file" ]; then
    send_head "HTTP/1.0 200 OK" "text/plain; charset=utf-8"
    [ "$_method" = HEAD ] && exit 0
    cat "$_file"
else
    send_head "HTTP/1.0 404 Not Found" "text/plain"
    printf 'no such log: %s\n' "$_name"
fi
exit 0
