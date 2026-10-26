#!/usr/bin/env bash
# chk_nginxui.sh — exits 0 when the nginx-ui API answers on :9000
# The UI process owns the SQLite DB; if it is down, the node cannot apply
# config changes and must be treated as unhealthy for role purposes.
code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:9000/api/install 2>/dev/null)
[ "$code" = "200" ] || exit 1
exit 0