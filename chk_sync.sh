#!/usr/bin/env bash
# chk_sync.sh — VIP eligibility gate (installed on the PREFERRED PRIMARY only).
# keepalived vrrp_script; weight -50. exit 0 = allowed to hold the VIP.
#
# The node is allowed to hold the VIP only while it is "in sync":
#   /run/ha/i-am-master        — written by ha-notify.sh when this keepalived
#                                session becomes MASTER (data = truth).
#                                Lives on tmpfs: a real VM reboot wipes it,
#                                so a recovering node starts GATED.
#   /run/ha/failback-allowed   — written by ha-failback.sh after the operator
#                                verified a fresh restore (manual failback).
[ -f /run/ha/i-am-master ] && exit 0
[ -f /run/ha/failback-allowed ] && exit 0
exit 1