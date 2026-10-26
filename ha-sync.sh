#!/usr/bin/env bash
# =============================================================================
# ha-sync.sh — full data sync between two nginx-ui nodes (active/standby)
#
# Uses nginx-ui's built-in FULL BACKUP / RESTORE API (tested end-to-end):
#   * GET  /api/backup   on the SOURCE (master) node -> encrypted zip + token
#   * POST /api/restore  on the TARGET (standby) node -> replaces the UI
#     database + full nginx config dir, then restarts nginx and nginx-ui
#     in place on the standby only.
#
# What gets synced: sites, streams, upstreams (embedded in site configs),
# SSL certificate files, users, ACLs, namespaces, and every other record in
# the nginx-ui database. Nothing is left behind.
#
# DIRECTION IS ROLE-BASED (auto-flips): the STANDBY always pulls from the
# MASTER. The master's ha-notify fires "backup" the moment it is demoted,
# and the cron below keeps catching up while it is standby.
#
# Usage:
#   ha-sync.sh standby   run on EITHER node (safe): if I am standby -> pull
#                        from PEER_IP (the master); if I am master -> no-op.
#                        This is what cron + ha-notify.sh call.
#   ha-sync.sh pull <ip> manual: pull full backup from <ip> into this node
#   ha-sync.sh protect [secs]
#                        (re)activate the protection window: for PROTECT_SECS
#                        (default 1800) this node will NOT auto-restore from
#                        its peer even as standby. Use when BOTH nodes failed
#                        and may have been down simultaneously: after such an
#                        event the node that was master before the outage
#                        holds the freshest data and must not be overwritten
#                        by the peer's older copy.
#   ha-sync.sh status    local health summary
#
# /etc/ha-sync.conf (chmod 600, DIFFERS PER NODE only in PEER_IP):
#   NGINXUI_USER=admin
#   NGINXUI_PASS=********
#   NGINXUI_PORT=9000
#   PEER_IP=<VM2_MGMT>           # the OTHER node's management IP
#   SYNC_INTERVAL=300            # skip if a restore happened less than N s ago
#   SYNC_MAX_AGE=1800            # max restore age for ha-failback.sh
#   PROTECT_SECS=1800            # protect window length
#
# Requirements on each VM:
#   * identical nginx-ui deployment: same UI port (9000), same /etc/nginx
#     layout, and the SAME [crypto] Secret in app.ini on both nodes
#   * one shared admin account (same user/pass on both nodes — automatically
#     true after the first cross-sync)
#   * curl, openssl, python3 (stdlib only)
# =============================================================================

set -euo pipefail

CONF=/etc/ha-sync.conf
[ -f "$CONF" ] || { echo "missing $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"
: "${NGINXUI_USER:?}"; : "${NGINXUI_PASS:?}"; : "${NGINXUI_PORT:=9000}"
: "${SYNC_INTERVAL:=300}"; : "${SYNC_MAX_AGE:=1800}"; : "${PROTECT_SECS:=1800}"

STATEDIR=/var/lib/ha
SYNCED="$STATEDIR/synced"
PROTECT="$STATEDIR/sync-protect"
LOG=/var/log/ha-role.log
log() { echo "$(date -Is) $*"; }

# --- G3 (2026-09-12, failure-matrix hardening): single-instance guard.
# cron (every minute) and ha-notify (role changes) can fire while a previous
# instance is still running (e.g. a source-down retry window). Without this,
# two instances could download/restore concurrently on the same node. The
# lock lives on per-node tmpfs (/run) and is released on every exit path.
exec 9>/run/ha-sync.lock
flock -n 9 || { log "another sync is already running — exiting"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pyjson() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }

enc_params() {  # $1=json object -> base64(RSA-PKCS1v15(json)) using fresh server pubkey
  local base=$1 json=$2 pub b64
  pub=$(curl -s -m 10 -X POST "$base/api/crypto/public_key" \
        -H 'Content-Type: application/json' \
        -d "{\"timestamp\":$(date +%s%3N),\"fingerprint\":\"$RANDOM$RANDOM\"}" \
        | pyjson "['public_key']")
  printf '%s' "$pub" > "$WORK/pub.pem"
  b64=$(printf '%s' "$json" | openssl pkeyutl -encrypt -pubin -inkey "$WORK/pub.pem" \
        -pkeyopt rsa_padding_mode:pkcs1 | base64 -w0)
  printf '{"encrypted_params":"%s"}' "$b64"
}

login() {  # $1=base url -> prints token
  # NOTE: patched during 2026-09-11 HA validation. After nginx-ui's in-place
  # restore restart the process is (re)started with a FRESH RSA keypair, so a
  # ciphertext minted before the restart never decrypts on the new instance
  # ("decryption failed"). Also /api/install=200 briefly precedes login
  # readiness. Hence: retry up to 15x (2s apart), and re-mint the encrypted
  # body (fresh public key) on EVERY attempt.
  local body tok i
  for i in $(seq 1 15); do
    body=$(enc_params "$1" "{\"name\":\"$NGINXUI_USER\",\"password\":\"$NGINXUI_PASS\"}") || body=
    [ -n "$body" ] || { [ "$i" -eq 15 ] && { echo "login to $1 failed (no public key)" >&2; exit 1; }; sleep 2; continue; }
    tok=$(curl -s -m 15 -X POST "$1/api/login" \
          -H 'Content-Type: application/json' -d "$body" | pyjson "['token']" 2>/dev/null) || tok=
    [ -n "$tok" ] && break
    [ "$i" -eq 15 ] && { echo "login to $1 failed" >&2; exit 1; }
    sleep 2
  done
  printf '%s' "$tok"
}

wait_ui() {  # $1=base url
  local i
  for i in $(seq 1 30); do
    if curl -s -m 2 -o /dev/null -w '%{http_code}' "$1/api/install" | grep -q '^200$'; then
      return 0
    fi
    sleep 2
  done
  echo "UI at $1 did not come back in 60s" >&2
  return 1
}

sync_to() {  # $1 = base url of SOURCE (active) node; runs on TARGET (standby)
  local src=$1
  local src_base="http://$src:$NGINXUI_PORT" local_base="http://127.0.0.1:$NGINXUI_PORT"
  local tok src_token local_token sec hdr

  echo "[ha-sync] logging in to source $src_base ..."
  src_token=$(login "$src_base")
  echo "[ha-sync] downloading full backup from source ..."
  curl -s -m 300 -f -H "Authorization: $src_token" \
       -D "$WORK/hdrs" -o "$WORK/backup.zip" "$src_base/api/backup"
  sec=$(grep -i '^x-backup-security:' "$WORK/hdrs" | tr -d '\r' | awk '{print $2}')
  [ -n "$sec" ] || { echo "no X-Backup-Security header" >&2; exit 1; }
  echo "[ha-sync] backup size: $(stat -c%s "$WORK/backup.zip") bytes"

  echo "[ha-sync] restoring into local node (UI + nginx) — local UI/nginx will restart ..."
  local_token=$(login "$local_base")
  local resp
  resp=$(curl -s -m 600 -X POST "$local_base/api/restore" \
        -H "Authorization: $local_token" \
        -F "backup_file=@$WORK/backup.zip;type=application/zip" \
        -F "security_token=$sec" \
        -F "restore_nginx=true" \
        -F "restore_nginx_ui=true" \
        -F "verify_hash=true")
  echo "[ha-sync] restore response: $resp"
  echo "$resp" | grep -q '"nginx_ui_restored":true' || { echo "restore failed" >&2; exit 1; }

  echo "[ha-sync] waiting for local UI to come back (in-place restart) ..."
  wait_ui "$local_base"
  local after n
  after=$(login "$local_base")
  # (bugfix: pyjson "len(d['data'])" expanded to "dlen(...)" -> NameError)
  n=$(curl -s -m 10 -H "Authorization: $after" "$local_base/api/sites?page=1&limit=500" \
      | python3 -c "import sys,json;print(len(json.load(sys.stdin)['data']))")
  echo "[ha-sync] OK — local node now serves $n synced site(s). Standby is current."
}

my_role() { cat /run/ha/role 2>/dev/null || echo unknown; }

protected() {  # echo remaining seconds of the protection window (0 = none)
  [ -f "$PROTECT" ] || { echo 0; return; }
  local start now rem
  start=$(cat "$PROTECT" 2>/dev/null || echo 0)
  now=$(date +%s)
  rem=$(( start + PROTECT_SECS - now ))
  [ "$rem" -lt 0 ] && rem=0
  echo "$rem"
}

case "${1:-}" in
  standby)
    # Role-based: only the standby syncs; the master is the source of truth.
    role=$(my_role)
    if [ "$role" != backup ]; then
      log "[ha-sync] role=$role — not standby, nothing to do"
      exit 0
    fi
    [ -n "${PEER_IP:-}" ] || { log "[ha-sync] PEER_IP not set in $CONF"; exit 2; }

    rem=$(protected)
    if [ "$rem" -gt 0 ]; then
      log "[ha-sync] PROTECTED (${rem}s left, dual-failure guard) — skipping restore from ${PEER_IP}"
      exit 0
    fi

    if [ -f "$SYNCED" ]; then
      age=$(( $(date +%s) - $(cat "$SYNCED") ))
      if [ "$age" -lt "$SYNC_INTERVAL" ]; then
        log "[ha-sync] restored ${age}s ago (< ${SYNC_INTERVAL}s) — skipping"
        exit 0
      fi
    fi

    sync_to "$PEER_IP"
    mkdir -p "$STATEDIR"
    date +%s > "$SYNCED"
    log "[ha-sync] sync marker updated ($SYNCED)"
    ;;

  protect)
    secs=${2:-$PROTECT_SECS}
    mkdir -p "$STATEDIR"
    echo $(( $(date +%s) - secs )) > "$PROTECT"
    log "[ha-sync] protection window active for ${secs}s (dual-failure guard)"
    ;;

  pull)  [ -n "${2:-}" ] || { echo "usage: $0 pull <peer_ui_ip>" >&2; exit 2; }
         sync_to "$2"
         mkdir -p "$STATEDIR"; date +%s > "$SYNCED"
         ;;

  push)  echo "push is not a separate mode: the STANDBY pulls from the MASTER."
         echo "If you meant manual restore into this node from $2: $0 pull ${2:-<ip>}"
         exit 1 ;;

  status)
    role=$(my_role)
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NGINXUI_PORT/api/install" 2>/dev/null || true)
    echo "role              -> $role"
    echo "nginx-ui :$NGINXUI_PORT -> ${code:-unreachable}"
    pgrep -x nginx >/dev/null && echo "nginx process   -> running" || echo "nginx process   -> NOT running"
    nginx -t >/dev/null 2>&1 && echo "nginx config    -> valid" || echo "nginx config    -> INVALID"
    if [ -f "$SYNCED" ]; then
      echo "last restore      -> $(( $(date +%s) - $(cat "$SYNCED") ))s ago"
    else
      echo "last restore      -> never"
    fi
    rem=$(protected)
    echo "protect window    -> $([ "$rem" -gt 0 ] && echo "${rem}s left" || echo none)"
    ;;

  *) echo "usage: $0 {standby|pull <peer_ui_ip>|protect [secs]|status}" >&2; exit 2 ;;
esac