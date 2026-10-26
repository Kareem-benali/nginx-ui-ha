# nginx-ui HA — High Availability for nginx-ui

A production-tested, battle-tested high-availability set for **[nginx-ui](https://github.com/nginxui/nginx-ui)** — a two-VM active/standby cluster that keeps your nginx reverse-proxy and its web UI running through single-point-of-failure events.

## What it is

This project provides a complete HA solution for nginx-ui using keepalived VRRP for VIP failover and custom synchronization scripts that ensure data consistency across two nodes. It was designed for a real production deployment that needed zero-downtime failover.

## How it works

```
                    ┌─────────────────────┐
                    │   Public IP / DNS   │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │   Floating VIP      │ ◄─── moves between nodes
                    └──────────┬──────────┘
                        │           │
                  ┌─────┘           └─────┐
                  │                       │
         ┌────────▼────────┐   ┌─────────▼─────────┐
         │    VM1           │   │    VM2             │
         │  (MASTER) 110    │   │  (BACKUP) 100     │
         │                  │   │                    │
         │  keepalived + nginx-ui + nginx│
         │  (serves VIP)       │   │  (standby, resyncs)│
         └───────────────────┘   └──────────────────┘
```

**Key behaviors:**

- **Normal operation:** VM1 holds the VIP, VM2 syncs from VM1
- **VM1 fails:** VM2 takes the VIP in ~4 seconds
- **VM1 recovers:** It cannot steal the VIP back — it re-syncs and becomes standby
- **Failback:** Operator runs `ha-failback.sh` to return VIP to VM1

## What it provides

### Sticky Failover
When VM1 fails, VM2 becomes master. When VM1 comes back, it stays as standby until manually commanded to take over. This prevents "VIP thrashing" where the VIP bounces between nodes.

### Gated Recovery
A recovered node is "gated" — it cannot serve traffic until it has restored a full backup from the current master. This ensures data consistency and prevents stale data from being served.

### Full Data Sync
Every site, stream, upstream, SSL certificate, user, ACL, and namespace (everything in the nginx-ui database) is automatically synchronized between nodes using nginx-ui's built-in backup/restore API.

### Manual Failback
The operator controls when the preferred primary regains the VIP. The `ha-failback.sh` script verifies the local data is fresh before allowing the node to preempt the VIP.

### Automated Resync
Cron and keepalived hooks ensure the standby node is always one sync cycle behind the master. No manual intervention needed for routine operation.

### Deployment Safety
A 9-point pre-flight check validates everything before the cluster is brought up — NIC existence, management IP, VIP absence, nginx-ui reachability, keepalived config validation, and more.

## Quick Start

```bash
# 1. Copy the release files to both VMs
#    (you'll get these files from this repo)

# 2. Install on both nodes
#    See the step-by-step guide in README-runbook.md

# 3. Follow the deployment checklist
#    13 steps to go from bare VMs to verified HA pair
```

## Files

| File | Purpose | Install To |
|------|---------|------------|
| `keepalived-vm1.conf` | VRRP config for preferred primary (priority 110, with chk_sync gate) | `/etc/keepalived/keepalived.conf` on VM1 only |
| `keepalived-vm2.conf` | VRRP config for standby (priority 100) | `/etc/keepalived/keepalived.conf` on VM2 only |
| `chk_sync.sh` | VIP eligibility gate — only runs on VM1 | `/usr/local/bin/` |
| `chk_nginx.sh` | Health check: nginx process alive + HTTP probe | `/usr/local/bin/` |
| `chk_nginxui.sh` | Health check: nginx-ui API responds on :9000 | `/usr/local/bin/` |
| `chk_conf.sh` | Health check: nginx configuration is valid | `/usr/local/bin/` |
| `ha-notify.sh` | keepalived role-change hook — writes gate markers, triggers resync | `/usr/local/bin/` |
| `ha-sync.sh` | Full backup/restore sync — runs on cron and role changes | `/usr/local/bin/` |
| `ha-failback.sh` | Manual failback — operator action after verified restore | `/usr/local/bin/` |
| `ha-preflight.sh` | 9-point deployment safety check | `/usr/local/bin/` |
| `ha-vip-gate.conf` | systemd drop-in — runs VIP preflight on keepalived start | `/etc/systemd/system/keepalived.service.d/` |
| `README-runbook.md` | Full step-by-step deployment guide | — |

All scripts: `root:root`, `755` permissions.

## Requirements

- **Two VMs** on the same L2 segment (VRRPv2 is multicast, doesn't cross routers)
- **Same OS** on both nodes (tested: Ubuntu 24.04 LTS)
- **nginx-ui** installed identically on both (same version, same `[crypto] Secret` in `app.ini`)
- **One free VIP** on that subnet — must not be used by anything else
- **Root/sudo** access on both nodes
- **Dependencies:** `keepalived`, `nginx`, `curl`, `openssl`, `python3`, `cron`

## Key Operations

| Task | Command |
|------|---------|
| See current roles | `cat /run/ha/role` on each VM |
| Force a standby resync | `ha-sync.sh standby` (on the standby) |
| Manual failback to VM1 | `ha-failback.sh` on VM1 |
| Inspect last sync | `ha-sync.sh status` |
| Pre-deployment audit | `ha-preflight.sh <mgmt-ip>` on each node |

## Failure Scenarios

| Scenario | Outcome |
|----------|---------|
| VM1 crashes/reboots | VM2 becomes master in ~4s; VIP stays on VM2 after VM1 recovers |
| VM2 crashes/reboots | Nothing moves; VM1 keeps serving; VM2 resyncs on return |
| nginx dies on master | Priority drops → peer takes VIP in ~6–10s |
| Both nodes reboot | VM2 (no gate) wins VIP first; VM1 returns gated, resyncs from VM2 |
| Network partition | Both may hold VIP (known 2-node limit); heals when link returns |

## Security

- All HA scripts run as **root** (keepalived `script_user root` for `nginx -t` access)
- `enable_script_security` is set in keepalived configs (required for 2.3.x)
- Scripts are `root:root 755` (enforced by `ha-preflight.sh`)
- Sync uses nginx-ui's built-in RSA-encrypted API (backup/restore endpoints)
- VRRP authentication is configured (set your own `CHANGE_ME_AUTH_PASS`)
- `/etc/ha-sync.conf` must be `chmod 600` (contains admin credentials)
- **Never commit** `/etc/ha-sync.conf` or any file with real credentials

## Compatibility

- **keepalived** 2.3.x (tested 2.3.3) — also works with 2.2.8 (Ubuntu backport)
- **nginx-ui** 2.5.10+ (tested) — the sync mechanism uses the `/api/backup` + `/api/restore` endpoints
- **Linux** — tested on Ubuntu 24.04 LTS

## Architecture Diagram

See `ha-topology.html` in this repository for a visual representation of the HA architecture.

## Getting Help

For the complete step-by-step deployment guide, see `README-runbook.md`. It contains:
- Full 13-step implementation guide
- Firewall configuration examples
- Acceptance drill instructions
- Failure mode analysis
- Troubleshooting tips

## License

This project is provided as-is for operational use. Users are responsible for ensuring their deployment meets their organization's security and compliance requirements.

## Credits

This HA set was developed and tested in production to provide zero-downtime failover for nginx-ui deployments. The design was refined through 12 failure-matrix scenarios executed live against a real two-node cluster.
