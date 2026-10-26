#!/usr/bin/env bash
# ha-failback.sh — MANUAL failback (run on the node that is currently STANDBY).
#
# Authorizes this node to reclaim the VIP from the current master. Requires:
#   * local keepalived role == backup
#   * a restore from the master that happened within SYNC_MAX_AGE seconds
#     (recorded by ha-sync.sh standby in /var/lib/ha/synced)
#
# Once authorized, chk_sync passes within ~2s and this node preempts the
# VIP (it has the higher base priority); the former master demotes to backup
# and automatically resyncs from us.
set -euo pipefail

CONF=/etc/ha-sync.conf
[ -f "$CONF" ] || { echo "missing $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
SYNC_MAX_AGE=${SYNC_MAX_AGE:-1800}

ROLE=$(cat /run/ha/role 2>/dev/null || echo unknown)
[ "$ROLE" = backup ] || {
  echo "I am '$ROLE', not backup - nothing to fail back." >&2
  exit 1
}

SYNCED=/var/lib/ha/synced
[ -f "$SYNCED" ] || {
  echo "no restore record ($SYNCED) - run: ha-sync.sh standby" >&2
  exit 1
}
AGE=$(( $(date +%s) - $(cat "$SYNCED") ))
[ "$AGE" -le "$SYNC_MAX_AGE" ] || {
  echo "last restore is ${AGE}s old (max ${SYNC_MAX_AGE}s) - re-sync first: ha-sync.sh standby" >&2
  exit 1
}

mkdir -p /run/ha
touch /run/ha/failback-allowed
echo "failback authorized: VIP will move to $(hostname) within ~2s."
echo "watch:  tail -f /var/log/ha-role.log"