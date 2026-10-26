# nginx-ui HA — keepalived production set (VM1 = preferred primary, VM2 = standby)

## Release notes — 2026-09-11 (live-validated revision)

`ha-sync.sh` in this revision contains two bug fixes required for
synchronization to ever complete (both found by live testing against
nginx-ui 2.5.10; without them `ha-sync.sh pull`/`standby` exits rc=1 after
the restore even though the restore itself succeeded):

1. **Post-restore login race.** nginx-ui's in-place restore restart brings up
   a *new* process with a *fresh* RSA keypair, so a login ciphertext minted
   before the restart never decrypts afterwards (`"decryption failed"`,
   40001; during the restart window: 500/empty). `login()` now retries up to
   15× (2 s apart) **and re-mints the encrypted body (fresh public key) on
   every attempt**.
2. **`dlen` NameError.** `pyjson "len(d['data'])"` expanded to
   `print(dlen(d['data']))` (pyjson builds `print(d$1)`). Replaced with a
   direct `python3` call for the site count.

Runbook also corrected: service-failover recovery does NOT auto-preempt
(demotion closes the gate — see Step 11.4), and the new CRITICAL CAVEAT
explains why `systemctl stop nginx` is ineffective after any restore.
keepalived 2.2.8 (Ubuntu 24.04) is a supported line for this set — see
Step 1. A 12-scenario failure matrix was executed live and is recorded in
the appendix.

**2026-09-12 hardening revision (both live-tested on the pair):**

3. **G3 shipped — `ha-sync.sh` single-instance guard.** `flock -n` on
   `/run/ha-sync.lock` acquired before any work; a second concurrent
   trigger (cron during a source-down retry window, failover event while a
   sync runs) exits immediately with `another sync is already running —
   exiting` (rc=0) instead of restoring concurrently.
4. **G2 shipped — automated VIP preflight.** New `ha-preflight.sh`:
   * `ha-preflight.sh vip` — installed as keepalived's `ExecStartPre`
     (drop-in `ha-vip-gate.conf`): every keepalived start (boot, restart,
     failback) is refused if the configured VIP is already on the local
     interface.
   * `ha-preflight.sh <own-mgmt-ip>` — full pre-deployment audit on each
     node: interface/management IP, VIP absent locally, nothing on the LAN
     answers to the VIP, local nginx-ui, peer reachability, `keepalived -t`,
     script ownership (2.3.x script security), and prints the `[crypto]`
     Secret for cross-node comparison. Run on both nodes before first
     bring-up (both keepaliveds stopped); add `--live` for re-audits while
     the cluster runs.
   Live-verified: foreign VIP on a node → keepalived start refused
   (journal shows the exact remediation); audit fails (rc=1) on a real
   defect and passes (rc=0) on the healthy pair.

2026-09-13 operational note (no code changes): after a live incident, the
CRITICAL CAVEAT and Step 11.4 gained two verified warnings — never
`pkill -f nginx` (matches the operator's SSH session via `-f` flag and drops your connection),
and `systemctl start nginx` fails with `EADDRINUSE` when a restore-spawned
nginx still holds :80 (recovery: identify the holder, `fuser -k 80/tcp`,
then start).

Tested end-to-end in a keepalived **2.3.3** sandbox (state machine verified
against a mock VRRP peer, incl. failover, recovery, failback and the
no-nopreempt contrast test). Backup/restore verified against real nginx-ui
2.5.10 nodes via its `/api/backup` + `/api/restore` API.
Additionally verified **live on two real Ubuntu 24.04 VMs (keepalived 2.2.8,
nginx-ui 2.5.10) on 2026-09-11**: full acceptance drill (failover / gated
recovery / sticky / manual failback / service failover) plus a 12-scenario
failure matrix around the sync mechanism (see the appendix at the end).

## Files

| file                  | install to                     | both VMs? |
|-----------------------|--------------------------------|-----------|
| keepalived-vm1.conf   | /etc/keepalived/keepalived.conf (VM1 only) | no |
| keepalived-vm2.conf   | /etc/keepalived/keepalived.conf (VM2 only) | no |
| chk_sync.sh           | /usr/local/bin/                | VM1 only  |
| chk_nginx.sh          | /usr/local/bin/                | yes       |
| chk_nginxui.sh        | /usr/local/bin/                | yes       |
| chk_conf.sh           | /usr/local/bin/                | yes       |
| ha-notify.sh          | /usr/local/bin/                | yes       |
| ha-sync.sh            | /usr/local/bin/                | yes       |
| ha-failback.sh        | /usr/local/bin/                | yes       |
| ha-preflight.sh       | /usr/local/bin/                | yes       |
| ha-vip-gate.conf      | /etc/systemd/system/keepalived.service.d/ | yes       |
| /etc/ha-sync.conf     | (create, chmod 600)            | yes (PEER_IP differs per node) |

All `/usr/local/bin` scripts: `root:root`, `755`. keepalived 2.3.3 enforces
script security (path must be root-owned, not group/world writable) when
`enable_script_security` is set — as shipped here.

`README.txt` in this folder is a plain-text rendering of this document for
viewers/editors without Markdown support (identical content).

## ⚠ CRITICAL CAVEAT — after any restore, nginx runs OUTSIDE systemd

nginx-ui's in-place restore (`restore_nginx=true`) restarts nginx itself.
After the **first** restore on a node, the running nginx master is no longer
the one systemd started:

* `systemctl stop nginx` → unit goes "inactive" but **the nginx processes
  keep running** (the PID the unit knows is stale). The service keeps
  serving; nothing actually stopped.
* `systemctl is-active nginx` then *lies* (reports `inactive` while nginx
  answers on :80).
* To actually stop the front-end: `sudo nginx -s quit` (graceful) or
  `sudo pkill -x nginx` (hard).
  ⚠ **NEVER `pkill -f nginx`.** `-f` matches the whole command line, and the
  operator's own SSH session can match the pattern, so it also kills *your own SSH session* mid-command (happened live; the connection dropped immediately).
* To start it: `sudo systemctl start nginx` works **only if :80 is free**.
  If a stale or restore-spawned nginx still holds the port, it fails with
  `bind() to 0.0.0.0:80 failed (98: Address already in use)`. Find and clear
  the holder, then start:
  ```bash
  sudo ss -tulpn | grep :80     # or: sudo fuser 80/tcp
  sudo fuser -k 80/tcp          # kills whatever holds the port (expect a
                                # failover if this node was the master)
  sudo systemctl start nginx
  ```
  nginx-ui will adopt/replace the systemd master on its next restore anyway.
* Restores run **automatically** (on demotion, and every 5 min by cron while
  the node is standby), so this drift appears on its own after any role
  change — not only when an operator runs a sync.

`chk_nginx.sh` monitors the **real** process (`pgrep -x nginx`) plus a real
HTTP probe, so health detection and failover are unaffected — only operator
expectations break. Verified live 2026-09-11 (see failure matrix FM2) and
again 2026-09-13, when an automatic post-reboot resync left the journal with
`nginx.service: Deactivated successfully` at restore time, `systemctl stop
nginx` became a no-op, and `systemctl start nginx` hit `EADDRINUSE` twice —
10:29 against the surviving boot master, 10:38 against the cron-restore's
out-of-band master (new PID, PPID 1).

## The model (what actually happens)

```
normal:        VM1 = MASTER (VIP) 110   VM2 = BACKUP 100
               VM2 keeps restoring full backups from VM1 (cron + on demotion)

VM1 dies:      ~4s later VM2 = MASTER (VIP).  VIP STAYS ON VM2.
VM1 reboots:   VM1 starts GATED (its /run/ha/i-am-master was wiped with the
               tmpfs) -> effective priority 110-50 = 60 < 100 -> VM1 cannot
               win the election -> VM1 = BACKUP, VM2 keeps the VIP.
               ha-notify fires "backup" on VM1 -> VM1 restores a full backup
               from VM2 (flipped direction) -> writes /var/lib/ha/synced.
manual:        operator runs `ha-failback.sh` on VM1 (checks the restore is
               fresh, <= SYNC_MAX_AGE) -> gate opens -> VM1 preempts the VIP
               -> VM1 = MASTER again, VM2 = BACKUP and resyncs from VM1.
```

Why a gate instead of `nopreempt`:
* keepalived 2.3.3 **silently clears `nopreempt` on any node whose initial
  state is MASTER** — so it cannot make the preferred primary sticky.
* With both nodes `state BACKUP` + `nopreempt`, a cold start deadlocks
  (both accept each other's adverts, nobody ever becomes master).
* `nopreempt` on the standby blocks the self-heal case: a solo, gated,
  stale master would never be replaced by the fresher standby (verified
  in test T4).
The `chk_sync` gate expresses the real intent — *a node may only hold the
VIP while its data is in sync* — and survives every recovery ordering.

## Implementation guide (step by step)

Complete build-out from two identical VMs to a verified HA pair. Follow in
order; every step says what to run and how to verify it.

References used below (substitute your own values everywhere they
appear): VM1 = preferred primary, VM2 = standby, `<VIP>` = the shared
virtual address (with its prefix, e.g. `<VIP>/24`), `<VM1-MGMT>` /
`<VM2-MGMT>` = each node's own management IP on the HA plane, NIC = the
HA-plane interface (`eth0` shown as the example), admin login = `admin`.

### Step 0 — Prerequisites

* Two VMs, same OS, on the **same L2 segment** (VRRPv2 is multicast and does
  not cross routers).
* Static management IPs on both.
* One **free VIP** on that subnet — it must not be used by anything else,
  because it will move between the VMs.
* nginx-ui already deployed on at least one node (VM1) with your sites,
  **or** you plan to create the sites after the initial sync.
* Root/sudo on both VMs.

### Step 1 — Install dependencies (both VMs)

Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y keepalived nginx curl openssl python3 cron
```

RHEL / AlmaLinux / Rocky:

```bash
sudo dnf install -y keepalived nginx curl openssl python3 cronie
```

| package      | used for                                              |
|--------------|-------------------------------------------------------|
| keepalived   | VRRP, VIP ownership, state-change hooks (2.3.x; 2.3.3 tested) |
| nginx        | the front-end; its config is managed by nginx-ui      |
| curl         | `ha-sync.sh` and the `chk_*` health checks            |
| openssl      | RSA-encrypts credentials for the sync API             |
| python3      | JSON parsing in `ha-sync.sh`                          |
| cron/cronie  | runs the periodic standby re-sync                     |

Verify:

```bash
keepalived -v            # want 2.3.x
nginx -v && curl --version | head -1 && openssl version && python3 --version
```

Notes:
* keepalived 2.3.x is the tested line (2.3.3). 2.2.8 also runs the design and
  was verified live on Ubuntu 24.04 (2026-09-11): Ubuntu's 2.2.8 **backports
  the script-security check**, so `keepalived -t` fails with "SECURITY
  VIOLATION" unless `enable_script_security` and `script_user root` are in
  `global_defs` — keep the shipped lines exactly as-is. (Plain upstream 2.2.x
  without the backport does not know these keywords; drop them there —
  scripts run as root by default in that case.)
* The Debian/Ubuntu keepalived package creates a `keepalived_script` user;
  the shipped configs set `script_user root`, which overrides that.
* Default config path: `/etc/keepalived/keepalived.conf` (Debian/Ubuntu and
  newer RHEL). On older RHEL it may be `/etc/keepalived.conf` — keep your
  distro's path and overwrite its contents.

### Step 2 — Identical application layer (both VMs)

1. Install the **same nginx-ui version** on both nodes (tested: 2.5.10) with
   the vendor's official installer — same command, same options, on both.
   nginx-ui must manage `/etc/nginx` (its default layout).
2. Set the **same `[crypto] Secret`** in nginx-ui's `app.ini` on both nodes.
   This is mandatory for cross-node restore: generate one value, paste it into
   both, restart nginx-ui on both.
3. Use the **same admin username/password** on both (after the first sync it
   is one shared database anyway — the value you put in `ha-sync.conf` must
   be valid on the node you sync *from*).

Verify on both:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/api/install   # want 200
nginx -t                                                                     # want "syntax is ok"
```

### Step 3 — Install the HA files

Copy this folder to both VMs, then:

```bash
# VM1 only:
sudo cp keepalived-vm1.conf /etc/keepalived/keepalived.conf
# VM2 only:
sudo cp keepalived-vm2.conf /etc/keepalived/keepalived.conf

# both:
sudo cp chk_sync.sh chk_nginx.sh chk_nginxui.sh chk_conf.sh \
        ha-notify.sh ha-sync.sh ha-failback.sh ha-preflight.sh /usr/local/bin/
sudo chown root:root /usr/local/bin/chk_*.sh /usr/local/bin/ha-*.sh
sudo chmod 755  /usr/local/bin/chk_*.sh /usr/local/bin/ha-*.sh

# both (G2): gate EVERY keepalived start on the VIP preflight check —
# a stale/foreign VIP on the local interface makes the unit fail with a
# clear journal message instead of silently running with a duplicated IP
sudo mkdir -p /etc/systemd/system/keepalived.service.d
sudo cp ha-vip-gate.conf /etc/systemd/system/keepalived.service.d/
sudo systemctl daemon-reload
```

`chk_sync.sh` is only *referenced* by the VM1 config; installing it on both is
harmless and keeps the machines identical. (keepalived 2.3.x script security
requires exactly these root-owned 755 paths.)

### Step 4 — Edit the keepalived configs (both VMs)

In each `/etc/keepalived/keepalived.conf`, replace the two marked
placeholders:

```bash
    interface eth0                # <-- your real NIC (ip link)
    virtual_ipaddress {
        <VIP>/24                 # <-- your VIP/prefix
    }
```

Validate as root **before** starting the service:

```bash
sudo keepalived -t -f /etc/keepalived/keepalived.conf
# must exit 0 with no output/warnings
```

### Step 5 — Create /etc/ha-sync.conf (one per VM)

```bash
sudo tee /etc/ha-sync.conf > /dev/null <<'EOF'
NGINXUI_USER=admin
NGINXUI_PASS=***
NGINXUI_PORT=9000
PEER_IP=<VM2-MGMT>   # peer's mgmt IP — on VM2 use <VM1-MGMT>
SYNC_INTERVAL=300
SYNC_MAX_AGE=1800
PROTECT_SECS=1800
EOF
sudo chmod 600 /etc/ha-sync.conf
```

**`PEER_IP` is the OTHER node's management IP on each VM** — the file on VM1
points at VM2 and vice versa. Never the VIP (a standby syncing from the VIP
would sync from itself while it holds the VIP).

### Step 6 — State directory and log (both VMs)

```bash
sudo mkdir -p /var/lib/ha
sudo touch /var/log/ha-role.log && sudo chown root:root /var/log/ha-role.log
```

(`/run/ha` is created automatically by `ha-notify.sh` on the first state
change; it is tmpfs by design — wiped on reboot, which is exactly what gates
a recovered node.)

### Step 7 — Initial full sync (keepalived still stopped on both)

On **VM2**, pull everything from VM1 so it is a true clone:

```bash
sudo /usr/local/bin/ha-sync.sh pull <VM1-MGMT>
sudo /usr/local/bin/ha-sync.sh status     # want: last restore -> just now
```

Verify the site/stream counts match on both nodes (nginx-ui UI on each). Do
not continue until they are identical.

### Step 8 — Cron (both VMs)

```bash
echo '* * * * * root /usr/local/bin/ha-sync.sh standby >> /var/log/ha-role.log 2>&1' \
    | sudo tee /etc/cron.d/ha-sync
sudo chmod 644 /etc/cron.d/ha-sync
```

Role-aware: the standby re-syncs at most every `SYNC_INTERVAL`; the master
exits immediately with a no-op line.

### Step 9 — Firewall (both VMs, between the two management IPs only)

Allow, from the peer's IP:
* **VRRP**: IP protocol **112** (keepalived heartbeat)
* **Sync**: TCP **9000** (nginx-ui backup/restore API)

ufw example — on VM1 (mirror on VM2 with `<VM1-MGMT>`):

```bash
sudo ufw allow in on eth0 from <VM2-MGMT> proto 112
sudo ufw allow in on eth0 from <VM2-MGMT> to any port 9000 proto tcp
```

Clients reach the VIP on 80/443 exactly as before — no new client-facing
openings.

### Step 10 — Start and verify

```bash
# VM1 first (preferred primary, priority 110), then VM2:
sudo systemctl enable --now keepalived
```

Verify (expected: VIP on VM1 **only**):

```bash
ip -4 addr show eth0 | grep <VIP>             # VM1: present / VM2: absent
cat /run/ha/role                              # VM1: master / VM2: backup
curl -sI http://<VIP>/                        # your site, via the VIP
tail -n 30 /var/log/ha-role.log               # role lines + sync lines
```

Within a minute, VM2's log shows either
`[ha-sync] OK — … Standby is current.` or
`[ha-sync] restored Ns ago (< 300s) — skipping` (both healthy — the second
means Step 7's pull still counts as fresh). Force one if you like:
`ha-sync.sh standby` on VM2.

### Step 11 — Acceptance drill (do this before going live)

1. **Failover.** On VM1:
   ```bash
   sudo systemctl stop keepalived
   sudo rm /run/ha/i-am-master        # simulates the tmpfs wipe of a real reboot
   ```
   * within ~4 s the VIP moves to VM2 (`ip addr` on both),
   * log: `vm2: now MASTER (serving VIP, gate open)`,
   * start VM1 again (`sudo systemctl start keepalived`) — it must come up as
     **gated standby** (effective 60 < 100) and restore from VM2:
     watch for `[ha-sync] OK` from vm1.
2. **Sticky check.** VIP stays on VM2 even though VM1 is healthy. ✓
3. **Failback.** Once VM1 shows `[ha-sync] OK`, on VM1:
   ```bash
   sudo /usr/local/bin/ha-failback.sh
   ```
   * VIP returns to VM1 within ~2 s, VM2 demotes and resyncs from VM1.
4. **Service failover (optional).** On the current master, stop the
   front-end with `sudo nginx -s quit` (NOT `systemctl stop nginx` — see the
   CRITICAL CAVEAT; after a restore systemd no longer controls nginx — and
   NOT `pkill -f nginx`, which also matches the operator's own SSH session and
   drops your connection):
   `chk_nginx` fails (fall 3 × 2 s) → priority drops 110→80 → the peer takes
   the VIP in ~6–10 s. Then restart the front-end (`sudo systemctl start
   nginx`); if it fails with `bind() ... Address already in use`, a
   restore-spawned nginx still holds :80 — clear it with `sudo fuser -k
   80/tcp` and start again. The node recovers, **but** the demotion already
   closed its gate
   (ha-notify removes `/run/ha/i-am-master` on demotion), so it returns as
   GATED standby (effective 60 < 100) and does **not** auto-preempt back —
   the VIP stays on the promoted node, and returning it is a manual
   `ha-failback.sh`, exactly like node-failure recovery. Verified live
   2026-09-11 and 2026-09-13 (the 2026-09-13 run reproduced both failure
   modes above, including the `pkill -f` SSH drop).

If all four pass, the pair is live.

## Deploy checklist (TL;DR)

1. Deps on both: `keepalived nginx curl openssl python3 cron` (Step 1).
2. Identical nginx-ui + same `[crypto] Secret` (Step 2).
3. Copy configs + scripts (Step 3), set interface + VIP (Step 4).
4. `/etc/ha-sync.conf` per node, `PEER_IP` = the other node (Step 5).
5. `mkdir -p /var/lib/ha` (Step 6).
6. First sync: on VM2 `ha-sync.sh pull <vm1_ip>` (Step 7).
7. Cron `/etc/cron.d/ha-sync` on both (Step 8).
8. Firewall: proto 112 + TCP 9000 peer-to-peer (Step 9).
9. `systemctl enable --now keepalived` — VM1 first, then VM2 (Step 10).
10. Run the acceptance drill (Step 11).

## Operations

| action | command (where) |
|---|---|
| see current roles | `cat /run/ha/role` on each VM; `grep "role ->" /var/log/ha-role.log` |
| force a standby resync now | `ha-sync.sh standby` (on the standby) |
| manual failback to VM1 | on VM1: `ha-failback.sh` (requires fresh restore) |
| maintenance of VM1 (keep VM2 master) | on VM1 before stopping keepalived: `rm /run/ha/i-am-master` — it then returns as gated standby |
| dual-failure guard | if both nodes failed at the same time and the pre-failure master may hold fresher data: on that node run `ha-sync.sh protect 3600` **before** it syncs, so its newer local data isn't overwritten by the peer's older copy |
| inspect last sync | `ha-sync.sh status` |

## Failure modes (verified / reasoned)

| scenario | outcome |
|---|---|
| VM1 down (crash/reboot) | VM2 master in ~4s; VIP stays on VM2 after VM1 recovers; VM1 syncs from VM2 |
| VM2 down | nothing moves (VM1 keeps serving); when VM2 returns it resyncs |
| nginx dies on the master | priority drops (110->80 / 100->70 etc.), peer takes over in ~6–10 s; demotion closes the gate, so after the service recovers the node stays GATED standby (60) — VIP stays on the promoted node; manual failback to return |
| nginx config broken on a node | `chk_conf` fails -> priority drops before broken config can serve |
| both nodes reboot simultaneously | VM2 (no gate) takes the VIP first; **VM1 then syncs FROM VM2 and may lose up to SYNC_INTERVAL of changes it made right before the outage** — the only real data-loss corner; see dual-failure guard above |
| network partition between nodes | both may hold the VIP (no quorum on 2 nodes); heals when the link returns; keep SYNC_INTERVAL short to bound divergence |

## keepalived 2.3.x gotchas baked into this set

* `global_defs { enable_script_security }` — without it 2.3.3 logs
  "SECURITY VIOLATION - scripts are being executed but script_security
  not enabled" and (with the flag) actually *disables* insecure scripts.
* `script_user root` — 2.3.3 runs notify/track scripts as the user
  `keepalived_script` when that user exists (Debian packages create it).
  Our scripts need root (`nginx -t` fails unprivileged: it can't open
  /run/nginx.pid). If you prefer unprivileged scripts: remove the line,
  chown `/run/ha` and `/var/lib/ha` to `keepalived_script`, and replace
  `nginx -t` in chk_conf.sh with a root-free check.
* `state MASTER` + `nopreempt` is a no-op in 2.3.3 (flag is cleared with a
  warning) — don't rely on it.
* Failover speed ≈ 3×`advert_int` + skew ≈ 4s with `advert_int 1`.
---

## Appendix — Failure matrix, executed live 2026-09-11 (keepalived 2.2.8 / nginx-ui 2.5.10)

All twelve scenarios from the pre-production test plan were run against the
live pair (VIP served on ens18). Network failures were simulated with
iptables on the HA plane only (protocol 112 / port 9000) so operator SSH
survived; reboots were real guest reboots. **Result: 12/12 behaved as
documented, or exposed a known, mitigable gap (marked below).**

| # | Scenario | Observed | Verdict |
|---|----------|----------|---------|
| 1 | VM1 loses network (HA plane) | Superseded by #5: with the HA plane partitioned, the standby self-promotes while the master keeps serving → documented split-brain until the link returns | PASS (known 2-node limit) |
| 2 | VM2 loses network | Nothing moves: master keeps the VIP and serving (VIP:80 = 200); on heal, cron confirms data freshness | PASS |
| 3 | nginx-ui crashes | systemd `Restart=on-failure` revives the UI in ~2 s — inside chk_nginxui's 6 s fall window, so a true crash rarely fails over (self-heals first) | PASS (finding) |
| 4 | nginx-ui unreachable but nginx up | Sustained outage (`systemctl stop nginx-ui`): prio 110→90 (−20), peer takes VIP in ~7 s; UI restart → gated 60, **no auto-preempt**; the demotion-triggered resync straddled the outage and completed once the UI returned (login-retry patch working as designed) | PASS |
| 5 | Restore fails halfway | Backup download OK (26 KB); restore failed at the nginx step: API code 4509 `Failed to restore Nginx configs … operation not permitted` (via `chattr +i /etc/nginx`); script reported `restore failed` rc=1; **node kept serving the old config** (`nginx -t` OK, :80/:9000 = 200); full restore after un-`chattr`. nginx-ui stages nginx restore with a rollback dir (`/etc/.nginx-ui-nginx-rollback-*`) — original config survives a failed restore | PASS |
| 6 | Both nodes lose keepalived simultaneously | VIP dark (both release it; VIP:80 unreachable). First node restarted becomes master, second demotes — no further operator action | PASS |
| 7 | Both nodes reboot simultaneously | Cold-start corner: VM2 (no gate) wins the VIP, no dark window; VM1 returns GATED (journal: prio 110→60, tmpfs marker wiped), resyncs from VM2; manual failback restores | PASS |
| 8 | VM1 reboots while VM2 owns VIP | Headline sticky behavior under a real reboot: VM1 returns at effective 60, does not steal the VIP, resyncs from VM2; failback restores | PASS |
| 9 | VM2 reboots while VM1 owns VIP | VIP never moves; VM2 back in ~90 s with keepalived + nginx-ui auto-started; cron resync on return | PASS |
| 10 | Sync fails, source unavailable | Login-retry loop (15 × 2 s ≈ 44 s) → `login to … failed`, rc=1; VIP/roles untouched throughout; after source recovery the next cron tick resyncs in ~7 s. Note: with a *silent* partition (DROP instead of REJECT) detection takes up to ~4 min (15 × 15 s curl timeout) — acceptable for background sync, cron retries meanwhile | PASS |
| 11 | Sync succeeds but nginx restore fails | Same test as #5 (backup phase succeeded, nginx phase failed) — graceful failure, node stays serving | PASS |
| 12 | VIP already occupied when keepalived starts | Starting MASTER adds the VIP while a foreign copy stays on the other host → **duplication persists even after roles stabilize** — keepalived only manages IPs it added itself; manual `ip addr del` required. Confirms the "VIP must be free on that subnet" precondition; see gap G2 | PASS (gap documented) |

### Findings & recommended hardening (none block deployment)

* **G1 — nginx-ui crash self-heals by systemd.** A `kill -9`'d UI process is
  restarted by its unit (`Restart=on-failure`) in ~2 s, i.e. faster than
  chk_nginxui's fall window (3 × 2 s) — failover only fires for *sustained*
  UI outages (stopped service, host problem, port bind failure). This is the
  desired behavior; document it so on-call isn't surprised that a crash alone
  does not move the VIP.
* **G2 — keepalived never reclaims a foreign VIP address. (SHIPPED, 2026-09-12)**
  The duplication hazard is now guarded in both directions: (a)
  `ha-preflight.sh vip` runs as keepalived's `ExecStartPre` and refuses to
  start when the VIP is already on the local host (live-verified: unit
  failed with a journal message including the exact `ip addr del` command;
  started cleanly after removal); (b) `ha-preflight.sh <mgmt-ip>` is the
  full pre-deployment audit for both nodes, including "nothing on the LAN
  answers to the VIP" — the cross-host half of the problem. Keep the VIP
  address unused by anything else on the subnet.
* **G3 — concurrent ha-sync instances. (SHIPPED, 2026-09-12)** `ha-sync.sh`
  now takes an exclusive `flock` on `/run/ha-sync.lock` immediately; a
  concurrent trigger exits rc=0 in ~6 ms with
  `another sync is already running — exiting` (live-verified against a
  running restore). The lock is per-node (tmpfs) and released on every exit
  path. All curl calls are timeout-bounded, so a hung instance cannot wedge
  future syncs.
* **G4 — silent-partition detection latency.** See #10: with DROP (not
  REJECT), the 15 × `curl -m 15` login loop takes ~4 min to give up. Fine for
  a background resync; if faster detection is ever wanted, shorten the curl
  timeout on retry attempts.
