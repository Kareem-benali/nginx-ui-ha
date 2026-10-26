#!/usr/bin/env bash
# chk_nginx.sh — exits 0 when the local nginx is alive AND answering on :80
# Used by keepalived vrrp_script (weight -30).
nginx -t >/dev/null 2>&1 || exit 1
pgrep -x nginx >/dev/null 2>&1 || exit 1
code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:80/ 2>/dev/null)
case "$code" in
    2*|3*|404|503) exit 0 ;;   # any HTTP response = nginx is serving
    *) exit 1 ;;
esac