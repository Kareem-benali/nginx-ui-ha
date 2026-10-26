#!/usr/bin/env bash
# =============================================================================
# ha-preflight.sh — deployment-safety checks for the nginx-ui HA set
#
# G2 (2026-09-12 failure-matrix hardening): the matrix proved that if the
# configured VIP is already assigned to a host, keepalived can stabilize the
# ROLES (master/backup) while the IP stays duplicated — and keepalived never
# removes a foreign address. These checks make the "VIP must be free"
# precondition a hard, automated gate instead of a runbook wish.
#
# Modes:
#   ha-preflight.sh vip
#       LIGHTWEIGHT, runs as keepalived's ExecStartPre (unit drop-in):
#       this host must not already hold the configured VIP before keepalived
#       starts. A stale/foreign local assignment makes the unit FAIL with a
#       clear journal message instead of silently coexisting with the peer.
#       (Checked on every keepalived start: boot, restart, failback.)
#
#   ha-preflight.sh [expected_mgmt_ip] [--live]
#       FULL AUDIT — run on BOTH nodes before the first HA bring-up
#       (both keepaliveds stopped, VIP free):
#        1. interface named in keepalived.conf exists
#        2. it carries the expected management IP (if given)
#        3. the VIP is absent from every local interface
#        4. nothing on the LAN already answers to the VIP
#           (skipped with --live, where a healthy peer legitimately does)
#        5. local nginx-ui answers on its port
#        6. peer management IP (unicast_peer) is reachable
#        7. keepalived -t validates the shipped config
#        8. all HA scripts are root:root 755 (keepalived 2.3.x script
#           security; Ubuntu 2.2.8 backport checks the same)
#        9. prints the local [crypto] Secret so the operator can confirm it
#           matches the peer (cross-restore requirement)
#
# Exit: 0 = all passed, 1 = at least one failure.
# =============================================================================
set -uo pipefail

KVCONF=/etc/keepalived/keepalived.conf
[ -f "$KVCONF" ] || { echo "[ha-preflight] missing $KVCONF" >&2; exit 1; }

fail=0
ok()   { echo "  [ OK ] $*"; }
bad()  { echo "  [FAIL] $*"; fail=1; }
info() { echo "  [i   ] $*"; }

get_vip()   { awk '/virtual_ipaddress[[:space:]]*\{/,/\}/' "$KVCONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1; }
get_iface() { grep -E '^[[:space:]]*interface[[:space:]]' "$KVCONF" | awk '{print $2}' | head -1; }
# peer's management IP: authoritative source is /etc/ha-sync.conf (PEER_IP);
# keepalived.conf may use multicast (no peer line at all)
get_peer()  { sed -n 's/^PEER_IP=//p' /etc/ha-sync.conf 2>/dev/null | head -1; }

VIP=$(get_vip); IFC=$(get_iface); PEER=$(get_peer)
NGINXUI_PORT=9000
[ -f /etc/ha-sync.conf ] && NGINXUI_PORT=$(sed -n 's/^NGINXUI_PORT=//p' /etc/ha-sync.conf | head -1)
: "${NGINXUI_PORT:=9000}"

# ---------------------------------------------------------------- vip mode --
if [ "${1:-}" = "vip" ]; then
  echo "[ha-preflight] keepalived start-gate on $(hostname): VIP=$VIP"
  if [ -z "$VIP" ]; then
    bad "could not parse virtual_ipaddress from $KVCONF"
    exit 1
  fi
  if ip -4 addr show | grep -qw "$VIP"; then
    bad "VIP $VIP is ALREADY on this host before keepalived starts — stale/foreign assignment. Refusing to start. Remove it first:  ip addr del $VIP/24 dev $IFC"
    ip -4 addr show | grep -w "$VIP" | sed 's/^/         /'
    exit 1
  fi
  ok "VIP $VIP not present on this host — safe to start"
  exit 0
fi

# ------------------------------------------------------------ full audit ---
EXPECTED_IP=${1:-}
LIVE=0; [ "${2:-}" = "--live" ] && LIVE=1

echo "[ha-preflight] full audit on $(hostname) — VIP=$VIP iface=$IFC peer=$PEER mode=$([ $LIVE -eq 1 ] && echo live || echo fresh-deploy)"

# 1. interface
if ip link show "$IFC" >/dev/null 2>&1; then
  ok "interface $IFC exists"
else
  bad "interface $IFC does not exist"
fi

# 2. expected management IP
if [ -n "$EXPECTED_IP" ]; then
  if ip -4 addr show "$IFC" 2>/dev/null | grep -qw "$EXPECTED_IP"; then
    ok "$IFC carries expected management IP $EXPECTED_IP"
  else
    bad "$IFC does NOT carry expected management IP $EXPECTED_IP"
  fi
else
  info "no expected management IP given — check 2 skipped"
fi

# 3. VIP absent from this host
if ip -4 addr show | grep -qw "$VIP"; then
  bad "VIP $VIP is present on this host — it must be free before HA start"
else
  ok "VIP $VIP absent from this host"
fi

# 4. nothing answers to the VIP (fresh-deploy only)
if [ $LIVE -eq 1 ]; then
  info "--live: skipped VIP-response check (a healthy peer legitimately answers)"
else
  if ping -c1 -W2 "$VIP" >/dev/null 2>&1; then
    bad "something on the LAN already answers to $VIP — the VIP is NOT free"
  else
    ok "nothing answers to $VIP — VIP is free on the subnet"
  fi
fi

# 5. local nginx-ui
code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${NGINXUI_PORT}/api/install" 2>/dev/null || echo 000)
if [ "$code" = "200" ]; then
  ok "local nginx-ui answers on :${NGINXUI_PORT}"
else
  bad "local nginx-ui not answering on :${NGINXUI_PORT} (http $code)"
fi

# 6. peer reachable
if [ -n "$PEER" ]; then
  if ping -c1 -W2 "$PEER" >/dev/null 2>&1; then
    ok "peer $PEER reachable"
  else
    bad "peer $PEER unreachable"
  fi
else
  bad "could not determine peer IP (PEER_IP in /etc/ha-sync.conf / unicast_peer in $KVCONF)"
fi

# 7. keepalived config validation
if keepalived -t >/dev/null 2>&1; then
  ok "keepalived -t validates the config"
else
  bad "keepalived -t FAILED (run it manually to see why)"
fi

# 8. script ownership/permissions (keepalived script-security requirement)
sbad=0
for f in /usr/local/bin/ha-*.sh /usr/local/bin/chk_*.sh; do
  [ -f "$f" ] || continue
  own=$(stat -c '%U:%G %a' "$f")
  [ "$own" = "root:root 755" ] || { bad "$f is '$own' (need root:root 755)"; sbad=1; }
done
[ $sbad -eq 0 ] && ok "HA scripts are root:root 755"

# 9. crypto secret (operator must confirm both nodes match)
secret=$(grep -A1 '^\[crypto\]' /usr/local/etc/nginx-ui/app.ini 2>/dev/null | awk -F= '/Secret/ {print $2}' | tr -d '[:space:]')
if [ -n "$secret" ]; then
  info "local [crypto] Secret: $secret  (must be IDENTICAL on the peer — cross-restore requirement)"
else
  bad "could not read [crypto] Secret from /usr/local/etc/nginx-ui/app.ini"
fi

if [ $fail -eq 0 ]; then
  echo "[ha-preflight] ALL CHECKS PASSED on $(hostname)"
else
  echo "[ha-preflight] CHECKS FAILED on $(hostname) — do NOT bring up HA"
fi
exit $fail