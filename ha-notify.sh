#!/usr/bin/env bash
# ha-notify.sh <master|backup|fault> — keepalived state-change hook.
# Installed on BOTH VMs (runs as root via keepalived script_user root).
#
# Maintains the /run/ha state used by the chk_sync gate (preferred primary)
# and triggers the FLIPPED resync the moment a node is demoted:
#   demoted node = new standby -> restore full backup from the node that is
#   MASTER now, so the standby is always one sync cycle behind the active.
ROLE="$1"
HA=/run/ha
LOG=/var/log/ha-role.log
mkdir -p "$HA"
echo "$(date -Is) $(hostname): role -> $ROLE" >> "$LOG"
echo "$ROLE" > "$HA/role"

case "$ROLE" in
  master)
    # We are the source of truth now -> open the gate for this session.
    touch "$HA/i-am-master"
    rm -f "$HA/failback-allowed"
    echo "$(date -Is) $(hostname): now MASTER (serving VIP, gate open)" >> "$LOG"
    ;;
  backup|fault)
    # We no longer hold the VIP -> our data may be stale -> close the gate.
    rm -f "$HA/i-am-master" "$HA/failback-allowed"
    echo "$(date -Is) $(hostname): demoted ($ROLE), gate closed" >> "$LOG"
    if [ "$ROLE" = backup ]; then
      # Flipped sync: restore from the node that is MASTER now.
      # Run in background; give the new master a few seconds to stabilize.
      ( sleep 15
        /usr/local/bin/ha-sync.sh standby >> "$LOG" 2>&1 \
        || echo "$(date -Is) WARNING: resync failed - run 'ha-sync.sh standby' manually" >> "$LOG" ) &
    fi
    ;;
esac
exit 0