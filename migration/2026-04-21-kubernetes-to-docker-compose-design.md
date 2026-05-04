# Migration: Kubernetes → Single-Droplet Docker Compose

**Status:** Design, pending review
**Date:** 2026-04-21
**Target environment:** Production (`cash-track.app`)
**Scope:** Replace the DOKS cluster that hosts the `cash-track` app, the `monitoring` stack, and the `telegram-bots` namespace with a single DigitalOcean droplet running Docker Compose. Existing K8s infrastructure files remain in `./infra/` for rollback.

---

## 1. Motivation

The current DOKS cluster (3 nodes × 4GB/2vCPU + 1 LoadBalancer) costs ~$84/month, plus operational overhead: cert-manager, nginx-ingress, metrics-server, actions-runner-controller, Tailscale operator, cluster upgrades, etcd health. For a SaaS with ~1GB of MySQL data and modest traffic, the managed-Kubernetes complexity is not earning its cost.

The replacement is a single DigitalOcean droplet running Docker Compose, fronted by Traefik, with persistent state on an attached Block Volume and a Reserved IP that insulates Cloudflare DNS from droplet lifecycle events. Target cost: **~$50/month**, a ~40% reduction, with the larger win being the removal of six operator/controller systems.

### Explicit trade-off accepted

Single-droplet = single point of failure. RTO ≈ 5–8 minutes for an automated replacement (Block Volume + Reserved IP survive; droplet is recreated by Terraform). The user accepts this for the cost reduction. HA is future work (Section 18).

---

## 2. End-State Architecture

### Topology

```
                   Cloudflare (TLS termination, WAF, cache)
                           │
                           │   443 (CF IP ranges only, via DO Firewall)
                           ▼
               ┌───────────────────────┐
               │  Reserved IP (stable) │
               └───────────┬───────────┘
                           │
                 ┌─────────▼─────────┐
                 │   Droplet (ams3)  │   s-4vcpu-8gb
                 │                   │
                 │ ┌───────────────┐ │     ─── Block Volume 25 GB ───
                 │ │    Traefik    │ │  • /mnt/data/mysql
                 │ │   :80 :443    │ │  • /mnt/data/prometheus
                 │ └───────┬───────┘ │  • /mnt/data/loki
                 │         │         │  • /mnt/data/tempo
                 │   app + obs + tg  │  • /mnt/data/grafana
                 │   (Docker Compose)│  • /mnt/data/alertmanager
                 │                   │
                 │                   │    tailscale0  ── tailnet
                 └───────────────────┘ ◀────────────── admin SSH, CI/CD
                           │
                           ▼
                DigitalOcean Spaces (all AMS3)
                  • cash-track-storage  (public — user avatars, static assets, CDN)
                  • cash-track-backups  (private — existing; MySQL dumps)
                  • cash-track-tfstate  (private — Terraform state)       [NEW]

                1Password (cash-track-prod vault)
                  • all secrets (API, DB, TLS cert, Tailscale, Telegram, …)
```

### Services on the droplet

Four Docker Compose files, composed via `docker compose -f a.yml -f b.yml -f c.yml -f d.yml ...`:

| Compose file | Services |
|---|---|
| `compose.core.yml` | traefik, mysql, redis, ofelia |
| `compose.app.yml` | api, gateway, frontend, website, mysql-backup, mysql-exporter |
| `compose.obs.yml` | prometheus, node-exporter, grafana, loki, tempo, promtail, alertmanager |
| `compose.telegram.yml` | crashers-bot, home-exporter (each its own image; share MySQL via the `telegram_bots` database) |

Replica counts drop from 2 → 1 for api and gateway (no HA benefit on a single host). Traefik's retry middleware absorbs the brief restart window.

### MySQL tenant model

A single MySQL server hosts multiple databases. Each application service has its own dedicated MySQL user scoped only to its database(s). `mysql-init` creates each database and grants `ALL PRIVILEGES` on it to the corresponding dedicated user. A compromised service cannot read or write any other service's data.

| Database | Used by | App user | Vault item |
|---|---|---|---|
| `cashtrack` | api | `mysql.MYSQL_USER` | `mysql` |
| `telegram_bots` | crashers-bot | `crashers-bot-mysql.MYSQL_USER` | `crashers-bot-mysql` |
| *(future)* `wordpress` | wordpress | dedicated user | new vault item |

Root credentials are used only by initial provisioning, `mysql-backup`, and `mysql-init` itself; `mysql-exporter` uses its own dedicated `exporter` MySQL user (DSN in the `mysql-exporter` vault).

Adding a new application: add an entry to `mysql-init/vars/databases.yml` (name, vault op refs, list of databases), create the corresponding vault item in 1Password, and re-run `site.yml --tags mysql`. No shared user to rotate across services.

### Estimated monthly cost

| Item | Cost |
|---|---|
| Droplet `s-4vcpu-8gb` | $48 |
| Block Volume 25 GB | $2.50 |
| Reserved IP (attached) | $0 |
| DO Firewall | $0 |
| Spaces (existing + 2 new buckets) | ~unchanged |
| **Total** | **~$50/mo** |

### What is removed vs. today

| Removed | Reason |
|---|---|
| DOKS control plane + 3 nodes | Replaced by one droplet |
| DO Load Balancer | Traefik replaces it |
| nginx-ingress, cert-manager, metrics-server | Unneeded without Kubernetes |
| actions-runner-controller + self-hosted runners | GitHub-hosted runners |
| Tailscale operator (Helm) | Plain Tailscale daemon on the host |
| Kubernetes Secrets & ConfigMaps | 1Password (fetched via `op inject` at render time) + rendered `.env` |

---

## 3. Repository Layout

Existing `./infra/` K8s manifests are preserved verbatim as a rollback safety net. Existing GitHub Actions workflows are also preserved but **disabled** (see below). The current `README.md` is renamed to `README-kubernetes.md` and a brand-new `README.md` is written that describes only the new Docker Compose infrastructure — its operational usage, commands, and day-2 runbook. The new `README.md` makes no reference to "migration" as a concept; once the cutover is done, the migration is history.

**Existing workflows disabled — two-step approach:**

1. Rename each file so it no longer matches GitHub's `.github/workflows/*.yml` glob: `./github/workflows/deploy.yml` → `./.github/workflows.disabled/deploy.yml` (moved out of the workflows directory). Git history is preserved, the files remain reviewable, and GitHub will not schedule/trigger them.
2. Alternatively, keep the files in place and replace each trigger block with `on: workflow_dispatch:` (removes automatic triggers; still runnable manually as an emergency escape hatch).

Approach 1 is cleaner. Approach 2 is preferred if you want a one-click "run the old K8s deploy" option from the GitHub UI during the 48-hour post-cutover observation window. **Recommendation:** use approach 2 for the 48-hour observation window, then switch to approach 1 after decommission.

```
./infra/
├── README.md                      # NEW — describes Docker Compose infra only (operational, no "migration" narrative)
├── README-kubernetes.md           # RENAMED from README.md — preserved as the previous K8s documentation
├── LICENSE                        # kept
├── common/                        # kept (K8s manifests — dormant)
├── services/                      # kept (K8s manifests — dormant)
├── .github/workflows/             # existing workflows disabled (trigger → workflow_dispatch only, then moved to workflows.disabled/ after decommission)
│
├── Makefile                       # NEW — top-level convenience targets
├── terraform/                     # NEW
│   ├── backend.tf                 # DO Spaces S3-compatible backend (backend.hcl not committed)
│   ├── providers.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   └── modules/
│       ├── droplet/               # incl. cloud-init template
│       ├── block_volume/
│       ├── reserved_ip/
│       └── firewall/
│
├── ansible/                       # NEW
│   ├── ansible.cfg
│   ├── requirements.yml           # community.docker, community.digitalocean
│   ├── inventory/prod/
│   │   └── terraform.sh           # reads `terraform output -json`, emits Ansible JSON
│   ├── group_vars/all/
│   │   └── main.yml               # non-secret vars (secret refs live in env templates as op:// URIs)
│   ├── site.yml
│   ├── deploy.yml
│   ├── replace-droplet.yml
│   ├── ops/
│   │   ├── ssh-open.yml
│   │   ├── ssh-close.yml
│   │   ├── firewall-refresh-cf.yml
│   │   └── backup-restore.yml
│   └── roles/
│       ├── base/
│       ├── docker/
│       ├── tailscale/
│       ├── volume/
│       ├── mysql-init/
│       ├── compose-render/
│       └── compose-up/
│
├── compose/                       # NEW — static files, no Jinja in compose/*.yml
│   ├── compose.core.yml
│   ├── compose.app.yml
│   ├── compose.obs.yml
│   ├── compose.telegram.yml
│   └── config/                    # bind-mounted service configs; some Jinja-templated in ansible/roles/compose-render/templates/
│       ├── traefik/
│       ├── prometheus/
│       ├── loki/
│       ├── tempo/
│       ├── grafana/provisioning/{datasources,dashboards}/
│       ├── alertmanager/
│       └── promtail/
│
├── scripts/                       # NEW — helper scripts
│   ├── replace-preflight.sh       # enforces backup freshness; honours FORCE_REPLACE_REASON
│   ├── restore-to-new-volume.sh   # Block Volume corruption path (Section 17)
│   └── bootstrap-buckets.sh       # one-time Spaces bucket creation
│
└── .gitignore                     # extended: secrets/, *.tfstate*, .terraform/, backend.hcl, /tmp/cashtrack-render/
```

---

## 4. Configuration Surface

### Terraform (`terraform/terraform.tfvars`)

```hcl
region                = "ams3"
droplet_count         = 1                   # [0] holds the Reserved IP; multi-droplet is future work
droplet_size          = "s-4vcpu-8gb"
droplet_image         = "ubuntu-24-04-x64"
volume_size_gb        = 25
volume_tag            = "cashtrack-data"

domain                = "cash-track.app"
ssh_key_fingerprints  = ["aa:bb:cc:..."]    # fallback; primary path is Tailscale SSH
tailscale_tags        = ["tag:prod-server"]
cf_ipv4_url           = "https://www.cloudflare.com/ips-v4"
cf_ipv6_url           = "https://www.cloudflare.com/ips-v6"

enable_cloudflare_dns = false               # true = Terraform manages A records to Reserved IP
```

### Ansible (`ansible/group_vars/all/main.yml`)

Values below are Docker Hub image tags used verbatim. No parsing, no `v` stripping, no normalization anywhere — if a release is published as `v1.2.9`, that exact string is the tag set in `.env` and the exact string passed to `docker pull`.

```yaml
versions:
  api:          "1.2.9"
  gateway:      "1.2.9"
  frontend:     "1.1.4"
  website:      "0.1.14"
  mysql:        "1.0.8"
  mysql_backup: "0.0.5"
  redis:        "1.0.1"
  crashers_bot:  "1.0.0"
  home_exporter: "1.0.0"

retention:
  prometheus: "7d"
  loki:       "168h"
  tempo:      "72h"

backups:
  spaces_endpoint: "ams3.digitaloceanspaces.com"
  spaces_bucket:   "cash-track-backups"     # private bucket, already exists
  schedule_cron:   "0 0 3 * * *"            # Ofelia 6-field; 03:00 UTC daily
```

---

## 5. Sizing & Retention

### Disk on the Block Volume (target ~20 GB used of 25 GB provisioned)

| Component | Expected | Cap enforced by |
|---|---|---|
| MySQL data (+headroom) | 5 GB | app schema + quarterly review |
| Prometheus 7d retention | 4 GB | `--storage.tsdb.retention.size=3GB` + `--storage.tsdb.retention.time=7d` |
| Loki 7d retention | 5 GB | `retention_period=168h` + `ingestion_rate_mb=2` / `ingestion_burst_size_mb=4` |
| Tempo 3d retention | 3 GB | `compactor.compaction.block_retention=72h` + `ingester.max_bytes_per_trace` |
| Grafana + Alertmanager | 1 GB | bounded by config size |
| Headroom (images, compose overhead) | ~2 GB | — |
| **Total** | **~20 GB** | — |

Redis data is not persisted (accepted data loss on reboot); CSRF tokens invalidate on restart and users reauth on next mutating request. `redis.conf` sets `maxmemory 250mb` + `maxmemory-policy allkeys-lru` so Redis cannot grow beyond its budget slot regardless of traffic.

**Budgets are caps, not aspirations.** Every retention and rate limit above is wired into the service config, not the comment column in this table. A cardinality spike on Prometheus or a log-verbose deploy on Loki drops data at the ingestion boundary rather than silently eating disk.

**Block Volume IOPS are flat, not per-GB.** Unlike AWS gp3, DO Block Volumes cap at 5,000 write IOPS / 7,500 read IOPS / ~300 MB/s per volume regardless of size. "Resize the volume" is not a lever for I/O — it only buys capacity. If sustained I/O saturation appears, the lever is tuning (Section below) or splitting observability to a second storage tier (future work, Section 21).

### Filesystem mount flags

`/mnt/data` mounts with `defaults,nofail,noatime,nodiratime,discard` (fstab, set by cloud-init). `noatime` removes the metadata write on every read — a cheap win on a read-heavy workload and worth more than most tuning knobs on network-attached storage.

### MySQL I/O tuning (baked into `cashtrack/mysql` image my.cnf)

Defaults are tuned for network-attached SSD latency, not the 2005-era assumption of spinning disks:

- `innodb_flush_log_at_trx_commit = 2` — fsync the log once per second instead of per commit. Trades ≤1s of commit durability for 5–50× write throughput on this class of storage. Appropriate at this workload scale; revisit if the app ever handles money movement that must be bit-precise at the exact instant of commit.
- `innodb_flush_method = O_DIRECT` — bypass OS page cache for InnoDB data files. Removes double-caching (InnoDB buffer pool + kernel page cache).
- `innodb_io_capacity = 2000`, `innodb_io_capacity_max = 4000` — tell InnoDB the disk is actually fast. Default (200) is 15+ years out of date and starves flush scheduling.
- `innodb_buffer_pool_size = 512M` — matches the memory budget slot below. Explicit, not tuned-by-default.

### Memory on the droplet (8 GB total, ~2.25 GB headroom)

Budget values in the table below are also enforced as Docker `mem_limit` / `mem_reservation` per service in compose. A runaway service hits its cgroup limit, gets OOM-killed by the kernel at container scope (not host scope), and is restarted by Docker's `unless-stopped` policy within seconds. Neighbors are untouched. Without these limits, host-level OOM can kill MySQL (highest RSS) and take everything with it.

| Service | Budget (MB) | `mem_limit` | `oom_score_adj` |
|---|---|---|---|
| api | 700 | 768m | -200 |
| gateway | 100 | 128m | -200 |
| frontend | 100 | 128m | -100 |
| website (Nuxt SSR) | 500 | 640m | -100 |
| mysql | 800 | 896m | **-500** (protected) |
| redis | 300 | 320m | -200 |
| traefik | 100 | 128m | -300 |
| prometheus | 500 | 640m | +300 |
| grafana | 200 | 256m | +300 |
| loki | 500 | 640m | +500 |
| tempo | 500 | 640m | +500 |
| alertmanager | 100 | 128m | +300 |
| promtail | 100 | 128m | +300 |
| node-exporter + mysql-exporter + ofelia | 150 | 192m | 0 |
| crashers-bot | 250 | 320m | -100 |
| home-exporter | 100 | 128m | 0 |
| OS + Docker overhead | 600 | — | — |
| **Total used** | **~5 750** | — | — |
| **Headroom** | **~2 250** | — | — |

**OOM bias rationale.** If host-level OOM ever fires despite per-container limits, the kernel picks by `oom_score_adj`. MySQL at `-500` is the last thing to die; Loki/Tempo at `+500` die first. Observability loss → user-invisible, self-recovering. MySQL loss → data-loss risk. Bias accordingly.

**Swap policy.** A small (1 GB) swapfile lives on the **droplet root disk** (local SSD), not on the Block Volume. Rationale: swap on network-attached storage turns memory pressure into thrashing — the box becomes unreachable for minutes under load as every anon-page swap-in competes with MySQL fsyncs on the same network device. 1 GB is enough to absorb transient malloc spikes from idle daemons; too small to enable deep thrashing. `vm.swappiness = 10` biases the kernel toward evicting page cache before anon pages. Configured in the `base` Ansible role.

**Memory pressure alerting.** Host-level alert on Linux Pressure Stall Information via node-exporter's `node_pressure_memory_waiting_seconds_total` — fires when sustained memory pressure exceeds 10% for 2 minutes. PSI catches the *approach* to OOM, not the aftermath. Gives the operator a window to resize before the kernel decides for them.

### Resize trigger

If sustained memory usage exceeds 6.5 GB, PSI stays non-zero for hours, or the `website` SSR spikes under traffic, resize to `s-4vcpu-16gb` ($96/mo) via `terraform apply`. Resize uses the droplet-replacement flow; Block Volume data is untouched.

"Resize" is a cheap lever. $48/mo for another 8 GB of RAM is cheaper than the operational complexity of any memory-engineering alternative — don't let swap, tuning, or per-service whittling delay the decision once measurements justify it.

---

## 6. First-Boot Flow

Terraform creates droplet → cloud-init joins Tailscale → Ansible takes over. Zero public-SSH exposure at any point.

### Cloud-init (minimal, `terraform/modules/droplet/templates/cloud-init.yaml`)

```yaml
#cloud-config
hostname: ${hostname}
users:
  - name: ops
    groups: [sudo, docker]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ops_ssh_public_key}

package_update: true
packages: [curl, gnupg, python3, python3-apt]

runcmd:
  # Tailscale
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
  - apt-get update && apt-get install -y tailscale
  - tailscale up --authkey=${tailscale_authkey} --hostname=${hostname} --advertise-tags=tag:prod-server --ssh --accept-routes

  # Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - usermod -aG docker ops

  # Block Volume mount — idempotent for replacement case, robust against volume-attach race
  - |
    set -e
    DEV=/dev/disk/by-id/scsi-0DO_Volume_${volume_name}

    # Wait for the udev queue to drain, then poll for the specific device node.
    # On replacement boots, the Block Volume attach can complete after cloud-init
    # starts; without a bounded wait, `blkid` races and `mkfs` runs on a missing path.
    udevadm settle --timeout=30 || true
    for _ in $(seq 1 60); do [ -b "$DEV" ] && break; sleep 1; done
    if [ ! -b "$DEV" ]; then
      logger -s "cloud-init: Block Volume $DEV did not appear within 90s; aborting mount"
      exit 1
    fi

    # Key the re-entrance check off the filesystem label, not the by-id path.
    # `blkid $DEV` alone returns exit-code 2 for both "device missing" and
    # "device empty" — ambiguous. Label lookup is unambiguous and also survives
    # device-path changes across replacement.
    if ! blkid -L cashtrack-data >/dev/null 2>&1; then
      if blkid "$DEV" >/dev/null 2>&1; then
        logger -s "cloud-init: $DEV has a filesystem but not label=cashtrack-data; refusing to reformat"
        exit 1
      fi
      mkfs.ext4 -L cashtrack-data "$DEV"
    fi

    mkdir -p /mnt/data
    grep -q LABEL=cashtrack-data /etc/fstab || \
      echo "LABEL=cashtrack-data /mnt/data ext4 defaults,nofail,noatime,nodiratime,discard 0 2" >> /etc/fstab
    mount -a

  - touch /var/lib/bootstrap-ready
```

### Design properties

- **Minimal by design.** Only what must happen before Ansible can SSH via Tailscale. Everything else is Ansible's job.
- **Volume mount is re-entrant.** `mkfs.ext4` runs only if no filesystem label exists. On droplet replacement with the same volume, the existing filesystem is preserved — this is the core guarantee behind "no data loss on replacement".
- **Tailscale SSH (`--ssh`)** means SSH auth flows through the tailnet identity; the `ops` SSH key is a fallback.
- **The Tailscale auth key** is minted by Terraform at `apply` time (single-use, tagged, non-ephemeral), lives in Terraform state in the private `cash-track-tfstate` Spaces bucket.

### Failure modes and recovery

| Failure | Recovery |
|---|---|
| Cloud-init fails mid-way | Get the droplet's public IP (`doctl compute droplet list`); `make ssh-open IP=$(curl ifconfig.me)` → SSH to that public IP → inspect `/var/log/cloud-init-output.log` → fix → `cloud-init clean && cloud-init init`; then `make ssh-close` |
| Block Volume not attached within 90s | Cloud-init `logger`s and aborts before touching `mkfs` — check DO console for volume-attach errors, fix, re-run cloud-init |
| Volume has existing filesystem but not label `cashtrack-data` | Guard aborts; manual intervention required (intentional — avoids accidental reformat of a mis-attached volume) |
| Tailscale auth key expired before use | Re-run `terraform apply` (provider rotates the key) |
| Ops SSH key lost | Emergency `tailscale ssh` still works; otherwise `terraform apply` with new fingerprint issues cloud-init for fresh droplets |

---

## 7. Ansible Bootstrap

### `site.yml` — idempotent full-droplet configuration

```yaml
- hosts: prod
  become: true
  serial: 1
  pre_tasks:
    - name: Wait for cloud-init sentinel
      ansible.builtin.wait_for:
        path: /var/lib/bootstrap-ready
        timeout: 300
  roles:
    - base                 # unattended-upgrades + 04:00 UTC maint-window reboot, needrestart, swapfile, sysctls, timezone, chrony, PSI
    - docker               # daemon.json with log rotation + json-file size caps
    - firewall-refresh     # CF IP list → DO Cloud Firewall via digitalocean API
    - volume               # verifies /mnt/data mount, creates directory skeleton
    - mysql-init           # minimal mysql container, creates DBs + users idempotently
    - compose-render       # renders .env, secrets/*.env, config/* ; uploads static compose/*.yml
    - compose-up           # `docker compose -f ... up -d --remove-orphans`
```

### `base` role — OS-level hardening and maintenance policy

Responsible for:

- **Timezone** pinned to `UTC` (chrony for NTP). The maintenance-window reboot below is evaluated in UTC so behavior doesn't drift with DST.
- **Swapfile** — 1 GB at `/swapfile` on the root disk (local SSD), permission `0600`, `vm.swappiness=10`, `vm.vfs_cache_pressure=50`. Root disk, not Block Volume (rationale: Section 5, Memory). Enough to absorb idle-daemon anon pages; too small to enable deep thrashing.
- **`vm.overcommit_memory=1`** — classic overcommit. Matches Redis's recommended host config; avoids the heuristic overcommit's occasional OOM surprises.
- **PSI exposure** — `psi=1` kernel cmdline (default on Ubuntu 22.04+), node-exporter picks up `/proc/pressure/{cpu,memory,io}` for pressure-based alerting (Section 15).
- **Unattended-upgrades** installed and enabled for the security pocket, with an **explicit maintenance-window reboot policy**. Stock Ubuntu ships `Automatic-Reboot "false"`, which means kernel patches install but the box keeps running the vulnerable kernel indefinitely — the real default failure mode is stale-kernel, not surprise reboot. We flip that to a predictable, scheduled window:

  ```
  # /etc/apt/apt.conf.d/52unattended-upgrades-reboot (Ansible-managed)
  Unattended-Upgrade::Automatic-Reboot "true";
  Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
  Unattended-Upgrade::Automatic-Reboot-Time "04:00";
  ```

  04:00 UTC = low-traffic window for the EU-focused user base (AMS3 region). The reboot fires only when `/var/run/reboot-required` is set (i.e., when a kernel or core-library update actually needs it), not nightly. Expected cadence is a handful per year, each ≈60–180s of downtime. Documented as an accepted nightly-window trade in Section 19.
- **`needrestart`** configured with `$nrconf{restart} = 'a'` in `/etc/needrestart/needrestart.conf`. Without this, a library update (libc/openssl/etc.) can hang unattended-upgrades waiting for an interactive prompt. `'a'` restarts services automatically post-upgrade — handles the majority of userland patches *without* a reboot.
- **Reboot-required alerting.** Prometheus rule on `node_reboot_required == 1 for 7d` → Alertmanager → Telegram. Fires if for any reason the scheduled reboot didn't happen (e.g., Docker service stuck, fsck delay) and the box is running stale.
- **Post-reboot smoke check.** A `@reboot` systemd oneshot runs `docker compose ps` and curls the local health endpoints; failures `logger -s` into `journalctl` and bump a node-exporter textfile metric `cashtrack_postreboot_check_ok` scraped into an Alertmanager rule. Catches "box rebooted at 04:00, MySQL didn't come back" before the operator wakes up.

**Rejected alternatives.**

- *Ubuntu Pro + Livepatch* — avoids reboot-for-kernel-CVE entirely (free tier covers up to 5 machines), but introduces a Canonical-account dependency and per-token expiry management for one droplet. The scheduled 04:00 window plus `needrestart` + reboot alerting covers the same security posture without the extra account plumbing.
- *Stock `Automatic-Reboot "false"`* — silently ships you a vulnerable kernel until someone notices the reboot-required file. Not acceptable.

All roles are tagged. Partial reruns:

```bash
ansible-playbook site.yml --tags mysql
ansible-playbook site.yml --tags compose
ansible-playbook site.yml --tags firewall
```

### `deploy.yml` — single-service deploy from CI (see also Section 12)

The runner does not run Ansible in the common case — it SSHes to the droplet and triggers the on-droplet `deploy-service` script. `deploy.yml` exists as an alternative entry point for infra-originated deploys (e.g., a compose-file change) and for admins doing targeted bumps from their laptop.

### Droplet-side file layout after `site.yml`

```
/opt/cashtrack/
├── compose.core.yml
├── compose.app.yml
├── compose.obs.yml
├── compose.telegram.yml
├── .env
├── secrets/
│   ├── api.env
│   ├── gateway.env
│   ├── mysql.env
│   ├── mysql-backup.env
│   ├── mysql-exporter.env
│   ├── alertmanager.env
│   ├── grafana.env
│   ├── crashers-bot.env
│   └── home-exporter.env
├── config/
│   ├── traefik/{traefik.yml,dynamic.yml,
│   │           cash-track-app-cert.pem,cash-track-app-key.pem,
│   │           potwora-com-ua-cert.pem,potwora-com-ua-key.pem}
│   ├── prometheus/prometheus.yml
│   ├── loki/loki.yml
│   ├── tempo/tempo.yml
│   ├── grafana/provisioning/
│   ├── alertmanager/alertmanager.yml
│   └── promtail/promtail.yml
├── bin/
│   └── deploy-service
└── /mnt/data/                    # ── Block Volume ──
    ├── mysql/
    ├── prometheus/
    ├── loki/
    ├── tempo/
    ├── grafana/
    └── alertmanager/
```

---

## 8. Docker Compose — Concrete Files

Static files, variables via `${VAR}` substitution or `env_file`. No Jinja in compose files; Jinja is only in per-service config templates (e.g., `prometheus.yml.j2`).

### `compose/compose.core.yml`

```yaml
name: cashtrack

networks:
  app:
    driver: bridge
    name: cashtrack-app

services:
  traefik:
    image: traefik:v3.1
    restart: unless-stopped
    networks: [app]
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./config/traefik:/etc/traefik:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command:
      - --configFile=/etc/traefik/traefik.yml
    mem_limit: 128m
    mem_reservation: 96m
    oom_score_adj: -300

  mysql:
    image: cashtrack/mysql:${VERSION_MYSQL}
    restart: unless-stopped
    networks: [app]
    env_file: [secrets/mysql.env]
    volumes:
      - /mnt/data/mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1"]
      interval: 10s
      timeout: 5s
      retries: 10
    mem_limit: 896m
    mem_reservation: 768m
    oom_score_adj: -500           # last thing the kernel kills under host OOM

  redis:
    image: cashtrack/redis:${VERSION_REDIS}
    restart: unless-stopped
    networks: [app]
    # intentionally NO volume
    command: ["redis-server", "--maxmemory", "250mb", "--maxmemory-policy", "allkeys-lru"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
    mem_limit: 320m
    mem_reservation: 256m
    oom_score_adj: -200

  ofelia:
    image: mcuadros/ofelia:v0.3.14
    restart: unless-stopped
    networks: [app]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    command: daemon --docker
    labels:
      - ofelia.save-folder=/var/log/ofelia
      # No direct webhook — failures flow through Prometheus → Alertmanager → Telegram.
      # Ofelia exposes `ofelia_job_failures_total` on its metrics port, scraped by Prometheus.
      - ofelia.on-error=true
      - ofelia.no-overlap=true
```

### `compose/compose.app.yml` (abbreviated; gateway / frontend / website follow the same pattern)

```yaml
services:
  api:
    image: cashtrack/api:${VERSION_API}
    restart: unless-stopped
    networks: [app]
    env_file: [.env, secrets/api.env]
    depends_on:
      mysql: { condition: service_healthy }
      redis: { condition: service_started }
    labels:
      - traefik.enable=true
      - traefik.http.routers.api.rule=Host(`api.${DOMAIN}`)
      - traefik.http.routers.api.entrypoints=websecure
      - traefik.http.routers.api.tls=true
      - traefik.http.services.api.loadbalancer.server.port=8080
      - traefik.http.routers.api.middlewares=retry@file
    mem_limit: 768m
    mem_reservation: 640m
    oom_score_adj: -200

  mysql-backup:
    image: cashtrack/mysql-backup:${VERSION_MYSQL_BACKUP}
    restart: unless-stopped
    networks: [app]
    env_file: [secrets/mysql-backup.env]
    depends_on: [mysql]
    command: ["tail", "-f", "/dev/null"]          # idle; Ofelia triggers jobs
    labels:
      - ofelia.enabled=true
      - ofelia.job-exec.backup.schedule=0 0 3 * * *
      - ofelia.job-exec.backup.command=php app.php backup
      - ofelia.job-exec.purge-old.schedule=0 0 4 * * 0
      - ofelia.job-exec.purge-old.command=php app.php clear --days=7
    mem_limit: 192m
    mem_reservation: 128m

  mysql-exporter:
    image: prom/mysqld-exporter:v0.15.1
    restart: unless-stopped
    networks: [app]
    env_file: [secrets/mysql-exporter.env]
    command: ["--mysqld.address=mysql:3306"]
```

### `compose/compose.obs.yml` — observability services (abbreviated)

All observability services carry explicit retention and rate caps at the process level. Budget table (Section 5) values become enforced, not suggested.

```yaml
services:
  prometheus:
    image: prom/prometheus:v2.54.1
    restart: unless-stopped
    networks: [app]
    volumes:
      - /mnt/data/prometheus:/prometheus
      - ./config/prometheus:/etc/prometheus:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=7d
      - --storage.tsdb.retention.size=3GB      # hard cap; drops oldest blocks past limit
      - --web.enable-lifecycle
    mem_limit: 640m
    mem_reservation: 512m
    oom_score_adj: 300

  loki:
    image: grafana/loki:3.2.0
    restart: unless-stopped
    networks: [app]
    volumes:
      - /mnt/data/loki:/loki
      - ./config/loki/loki.yml:/etc/loki/local-config.yaml:ro
    command: ["-config.file=/etc/loki/local-config.yaml"]
    # loki.yml sets: ingestion_rate_mb=2, ingestion_burst_size_mb=4,
    # retention_period=168h, compactor.retention_enabled=true
    mem_limit: 640m
    mem_reservation: 512m
    oom_score_adj: 500

  tempo:
    image: grafana/tempo:2.6.0
    restart: unless-stopped
    networks: [app]
    volumes:
      - /mnt/data/tempo:/var/tempo
      - ./config/tempo/tempo.yml:/etc/tempo.yaml:ro
    command: ["-config.file=/etc/tempo.yaml"]
    # tempo.yml sets: compactor.compaction.block_retention=72h,
    # ingester.max_bytes_per_trace=5000000
    mem_limit: 640m
    mem_reservation: 512m
    oom_score_adj: 500
```

### Traefik config

`config/traefik/traefik.yml`:

```yaml
entryPoints:
  web:
    address: :80
    http:
      redirections:
        entrypoint: { to: websecure, scheme: https, permanent: true }
  websecure:
    address: :443
metrics:
  prometheus:
    entryPoint: websecure
providers:
  docker:
    exposedByDefault: false
    network: cashtrack-app
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true
```

`config/traefik/dynamic.yml`:

```yaml
# One TLS cert pair per Cloudflare zone. Traefik's file provider selects the
# right cert per request by SNI matching against the cert's CN/SAN — no router
# config needed. Cert PEMs are rendered onto the droplet by the compose-render
# Ansible role from per-zone 1Password items (`cloudflare-origin-cert` for
# cash-track.app, `cloudflare-origin-cert-potwora` for potwora.com.ua).
tls:
  certificates:
    - certFile: /etc/traefik/cash-track-app-cert.pem
      keyFile:  /etc/traefik/cash-track-app-key.pem
    - certFile: /etc/traefik/potwora-com-ua-cert.pem
      keyFile:  /etc/traefik/potwora-com-ua-key.pem
http:
  middlewares:
    retry:
      retry: { attempts: 3, initialInterval: 100ms }
    cloudflare-only:
      ipAllowList:
        sourceRangeIPs: []   # rendered by Ansible from CF IP feeds
        ipStrategy:
          depth: 1
```

---

## 9. Scheduled Jobs (Ofelia)

Docker-native cron with label-driven discovery. Schedules are visible in compose files, reviewable in PRs, logged to Loki via Promtail.

### Adding a scheduled job — three steps

1. Identify whether the job runs inside an existing long-running container (→ `job-exec`) or is one-shot (→ `job-run`).
2. Add Ofelia labels to the service in the relevant `compose.*.yml`. Schedule syntax: 6-field cron (seconds precision) or `@every 1h`.
3. Redeploy: `make deploy SERVICE=ofelia`.

### Example — crashers-bot jobs

Schedule list is a placeholder; populate from the existing K8s `crashers-bot` CronJobs / scheduled tasks during Stage 10.

```yaml
services:
  crashers-bot:
    labels:
      - ofelia.enabled=true
      - ofelia.job-exec.daily-digest.schedule=0 0 8 * * *    # 08:00 UTC daily
      - ofelia.job-exec.daily-digest.command=php app.php bot:digest
      - ofelia.job-exec.cleanup.schedule=0 30 3 * * *
      - ofelia.job-exec.cleanup.command=php app.php bot:cleanup
      - ofelia.job-exec.reminders.schedule=@every 15m
      - ofelia.job-exec.reminders.command=php app.php bot:reminders
```

### Alerting

All alerts — including scheduled-job failures — flow through **Alertmanager → Telegram**. A dedicated Telegram bot (managed in the `cash-track-prod` vault/1Password item `alertmanager-telegram`) posts to a private Telegram chat/channel that the team subscribes to. Alertmanager 0.26+ has a first-class `telegram_configs` receiver — no custom webhook bridge is needed.

Ofelia exposes Prometheus metrics (`ofelia_job_failures_total`, `ofelia_last_duration_seconds`, etc.). Prometheus scrapes Ofelia, and an alert rule fires when `increase(ofelia_job_failures_total[15m]) > 0`. Alertmanager routes the firing alert to Telegram. This avoids the Ofelia-specific direct-webhook path and keeps a single notification channel for all alert sources.

---

## 10. Adding a New Service

Example: a WordPress site sharing MySQL, served at `blog.cash-track.app`.

1. **Add the database and dedicated user** — edit `ansible/roles/mysql-init/vars/databases.yml`, append an entry:
   ```yaml
   app_users:
     # ...existing entries...
     - name: wordpress
       user_op_ref:     "op://cash-track-prod/wordpress-mysql/MYSQL_USER"
       password_op_ref: "op://cash-track-prod/wordpress-mysql/MYSQL_PASSWORD"
       databases:
         - wordpress
   ```
   `mysql-init` creates the new user and grants `ALL PRIVILEGES` on its database only.
2. **Add WP-specific secrets in 1Password** — create vault items `wordpress` (WP-only keys: `WORDPRESS_AUTH_KEY`, `WORDPRESS_NONCE_KEY`, etc.) and `wordpress-mysql` (`MYSQL_USER`, `MYSQL_PASSWORD` for the dedicated DB user).
3. **Add a per-service env template** — `ansible/roles/compose-render/templates/wordpress.env.tpl`:
   ```ini
   WORDPRESS_DB_HOST=mysql
   WORDPRESS_DB_NAME=wordpress
   WORDPRESS_DB_USER={{ op_prefix }}/wordpress-mysql/MYSQL_USER
   WORDPRESS_DB_PASSWORD={{ op_prefix }}/wordpress-mysql/MYSQL_PASSWORD
   WORDPRESS_AUTH_KEY={{ op_prefix }}/wordpress/WORDPRESS_AUTH_KEY
   ```
4. **Register the template** in `ansible/roles/compose-render/defaults/main.yml` under `secret_files` (renders through `op inject`).
5. **Add the service** — create `compose/compose.wordpress.yml`:
   ```yaml
   services:
     wordpress:
       image: wordpress:6.5-apache
       restart: unless-stopped
       networks: [app]
       env_file: [secrets/wordpress.env]
       labels:
         - traefik.enable=true
         - traefik.http.routers.wordpress.rule=Host(`blog.${DOMAIN}`)
         - traefik.http.routers.wordpress.tls=true
         - traefik.http.services.wordpress.loadbalancer.server.port=80
   ```
6. **Register the compose file** in `ansible/group_vars/all/main.yml` (`compose_files` list).
7. **Commit and push** — `ansible-apply.yml` triggers, runs `site.yml --tags mysql,compose`. The `mysql-init` role creates DB+user idempotently; `compose-up` picks up the new stack.
8. **Point DNS** — add `blog.cash-track.app` as a proxied A record in Cloudflare pointing to the Reserved IP.

No image rebuilds, no downtime for existing services.

---

## 11. Secrets Management

Secrets live in **1Password**, fetched at render time via the `op` CLI on the control node (operator laptop or CI runner). Plaintext never lands in git, Spaces, or the droplet filesystem outside the target `.env` file. There is no ciphertext-at-rest for us to manage, no vault password, no bucket for secrets.

### Rationale for choosing 1Password over Ansible Vault + Spaces

- **Existing paid subscription** — no new tool cost.
- **Built-in audit log** per item (who read/edited/viewed, when) without any work on our side.
- **Per-item granular access** via 1Password groups — useful if a contractor needs a single secret for a short time.
- **No custom wrapper scripts** to maintain (`vault-edit.sh`, `vault-view.sh`, `vault-diff.sh` all go away).
- **Operator ergonomics** — edit in the 1Password desktop app, not in a terminal editor.
- **Onboarding** — invite a teammate to the vault; no key distribution.

Accepted trade-offs:

- **CI-driven deploys are hard-linked to 1Password API uptime.** `ansible-apply.yml`, `replace-droplet.yml`, and `bootstrap.yml` all require `op inject` on the runner, which authenticates against `1password.com`. During a 1P API outage, CI cannot render secrets → cannot deploy, cannot replace the droplet from CI.
- **Operator-laptop deploys survive most 1P outages.** The 1Password desktop app maintains a local encrypted cache of the vault; an operator who was recently signed in can run `op read` / `op inject` against the cache via the CLI even when `1password.com` is unreachable. That converts "unbounded downtime during joint DR + 1P outage" into "operator runs `ansible-playbook site.yml` locally, same as a normal manual apply." Not as clean as a CI path, but an available break-glass.
- **Service Account token is the single most valuable credential.** Mitigated by scope (vault read-only) + rotation (quarterly or on personnel change).

Residual risk: joint outage (droplet gone + 1P API down + operator laptop either unavailable or never signed into the cache) → unbounded RTO until 1P comes back. Combined probability is small — 1P's published SLA is ~99.9% — but non-zero. Flagged in Section 19. If this ever becomes intolerable, add a break-glass encrypted snapshot of rendered `.env` files to the private `cash-track-tfstate` bucket, re-rendered after any vault edit; DR flow decrypts with an age key held by the operator.

### Storage

| Where | What | Access |
|---|---|---|
| 1Password vault `cash-track-prod` | All secret items: per-service env values, MySQL credentials, Tailscale OAuth, Docker Hub token, Telegram bot token, DO API token, Cloudflare origin cert PEM + key | Operator (via desktop app / `op` CLI) + CI (via Service Account token) |
| Operator laptop | 1Password desktop app signed in + `op` CLI signed in | Operator |
| GitHub org secret `OP_SERVICE_ACCOUNT_TOKEN` | Long-lived Service Account token scoped to `cash-track-prod` vault, read-only on secret items | CI only |
| Git | No secrets. `.env.tpl` templates are committed with `op://` references (metadata, not secrets); `.env` rendered output is `.gitignore`'d. | Anyone with repo access |

### Vault layout (items inside `cash-track-prod` 1Password vault)

Each item is a "Secure Note" or "API Credential" in 1Password, with fields referenced individually:

```
cash-track-prod/
├── api                      fields: JWT_SECRET, JWT_PUBLIC_KEY, JWT_PRIVATE_KEY,
│                                     ENCRYPTER_KEY, DB_ENCRYPTER_KEY
├── common                   fields: CAPTCHA_CLIENT_KEY, CAPTCHA_SECRET_KEY,
│                                     GOOGLE_API_*, MAIL_*, S3_*
├── mysql                    fields: MYSQL_DATABASE, MYSQL_USER,
│                                     MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD
├── mysql-exporter           fields: DATA_SOURCE_NAME
├── alertmanager-telegram    fields: BOT_TOKEN, CHAT_ID
├── grafana                  fields: ADMIN_PASSWORD, SMTP_PASSWORD
├── crashers-bot             fields: per crashers-bot-secret (BOT_TOKEN, ...)
├── home-exporter            fields: per home-exporter-secret
├── cloudflare-origin-cert            attachments: origin-cert.pem, origin-key.pem
│                                     (cash-track.app zone — two files; CF only
│                                      shows the private key once at creation,
│                                      so save both textboxes from the dashboard)
├── cloudflare-origin-cert-potwora    attachments: origin-cert.pem, origin-key.pem
│                                     (potwora.com.ua zone — same shape, separate
│                                      CF zone → separate Origin Cert)
├── tailscale                fields: API_KEY (personal API key)
├── dockerhub                fields: USERNAME, TOKEN
├── do-api                   fields: TOKEN (for firewall-refresh playbook + doctl)
└── cash-track-tfstate       fields: ACCESS_KEY_ID, SECRET_ACCESS_KEY
                                     (Spaces keypair for tfstate bucket;
                                      operator renders backend.hcl from these)
```

Dedup rules:

- `common` holds every secret consumed by 2+ services (CAPTCHA, Google OAuth, mail, S3) — one rotation point.
- `gateway` has no vault item: only secret it needs is `CAPTCHA_SECRET_KEY`, served from `common`.
- `mysql-backup` has no vault item: pulls `MYSQL_ROOT_PASSWORD` + `MYSQL_DATABASE` from `mysql`, `S3_KEY` + `S3_SECRET` from `common`. Bucket name is a non-secret literal.
- Each service gets a dedicated MySQL user scoped to its own database(s). `mysql` vault holds the api user; `crashers-bot-mysql` vault holds the crashers-bot user. Adding a new service = new `<name>-mysql` vault item + new entry in `mysql-init/vars/databases.yml`.
- Two telegram-namespace apps (`crashers-bot`, `home-exporter`) → two separate vault items, mirroring their separate K8s secrets.

### Templates reference secrets by `op://` URI

Templates live in git — reviewable in PRs, no secret material embedded.

`ansible/roles/compose-render/templates/api.env.tpl`:

```ini
APP_ENV=prod
DEBUG=false

# api vault — api-only keys
JWT_SECRET={{ op_prefix }}/api/JWT_SECRET
JWT_PUBLIC_KEY={{ op_prefix }}/api/JWT_PUBLIC_KEY
JWT_PRIVATE_KEY={{ op_prefix }}/api/JWT_PRIVATE_KEY
ENCRYPTER_KEY={{ op_prefix }}/api/ENCRYPTER_KEY
DB_ENCRYPTER_KEY={{ op_prefix }}/api/DB_ENCRYPTER_KEY

# common vault — shared with gateway, website, mysql-backup
CAPTCHA_CLIENT_KEY={{ op_prefix }}/common/CAPTCHA_CLIENT_KEY
CAPTCHA_SECRET_KEY={{ op_prefix }}/common/CAPTCHA_SECRET_KEY
GOOGLE_API_CLIENT_ID={{ op_prefix }}/common/GOOGLE_API_CLIENT_ID
GOOGLE_API_CLIENT_SECRET={{ op_prefix }}/common/GOOGLE_API_CLIENT_SECRET
MAIL_HOST={{ op_prefix }}/common/MAIL_HOST
MAIL_PASSWORD={{ op_prefix }}/common/MAIL_PASSWORD
S3_KEY={{ op_prefix }}/common/S3_KEY
S3_SECRET={{ op_prefix }}/common/S3_SECRET
# ... remaining GOOGLE_API_*, MAIL_*, S3_* keys

# mysql vault — api's dedicated MySQL user, scoped to cashtrack DB only
DB_HOST=mysql:3306
DB_NAME={{ op_prefix }}/mysql/MYSQL_DATABASE
DB_USER={{ op_prefix }}/mysql/MYSQL_USER
DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD
```

`op_prefix` resolves to `op://cash-track-prod` at render time. The two-step approach is used so that the same template works with a staging vault name in the future (just change the var).

### Render flow

Ansible runs entirely on the control node (laptop or CI runner). The `op` CLI is installed there, signed in via the Service Account token.

`ansible/roles/compose-render/tasks/main.yml`:

```yaml
- name: Render env template (Jinja → .env.tpl with op:// refs)
  ansible.builtin.template:
    src: "{{ item }}.env.tpl"
    dest: "/tmp/cashtrack-render/{{ item }}.env.tpl"
  delegate_to: localhost
  loop: "{{ secret_files }}"

- name: Inject secrets via `op inject` (local)
  ansible.builtin.command:
    cmd: op inject -i "/tmp/cashtrack-render/{{ item }}.env.tpl" -o "/tmp/cashtrack-render/{{ item }}.env"
  delegate_to: localhost
  environment:
    OP_SERVICE_ACCOUNT_TOKEN: "{{ lookup('env', 'OP_SERVICE_ACCOUNT_TOKEN') }}"
  loop: "{{ secret_files }}"
  no_log: true

- name: Ship rendered .env to droplet
  ansible.builtin.copy:
    src: "/tmp/cashtrack-render/{{ item }}.env"
    dest: "/opt/cashtrack/secrets/{{ item }}.env"
    mode: "0600"
    owner: ops
  loop: "{{ secret_files }}"
  no_log: true
  notify: "restart {{ item }}"

- name: Wipe local renders
  ansible.builtin.file:
    path: /tmp/cashtrack-render
    state: absent
  delegate_to: localhost
```

Plaintext exists only in `/tmp/cashtrack-render/` on the control node for the duration of the task, then deleted. On the droplet, plaintext lives in `/opt/cashtrack/secrets/<service>.env` (mode 0600, owner `ops`). The droplet never holds an `op` CLI and never sees the Service Account token.

### Handler pattern — restart only services whose env file changed

The `copy` task already reports `changed: true` only when content actually differs (Ansible compares file hashes). That triggers the per-service handler:

```yaml
# roles/compose-render/handlers/main.yml
- name: "restart api"
  community.docker.docker_compose_v2:
    project_src: /opt/cashtrack
    files: [compose.core.yml, compose.app.yml]
    services: [api]
    restarted: true
# ...one handler per service...
```

Editing `api/JWT_SECRET` in 1Password alone causes `api.env` to re-render to a different hash, triggering only the `restart api` handler. Other services remain running.

### CI workflow

The `ansible-apply.yml` reusable workflow installs `op` CLI, exports the Service Account token, runs `site.yml`. Service-deploy workflows (Section 12) do not touch 1Password — they only trigger a script on the droplet.

```yaml
- name: Install 1Password CLI
  uses: 1password/install-cli-action@v1

- name: Run Ansible
  env:
    OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
  run: |
    ansible-playbook site.yml -i ansible/inventory/prod/terraform.sh
```

No file-based secrets on disk. No shred step.

### Operator workflow

Rotate an existing secret:

1. Open 1Password desktop app → `cash-track-prod` vault → `api` item → change `JWT_SECRET` field → save.
2. Trigger the apply: `gh workflow run ansible-apply.yml --repo cash-track/infra -f tags=compose`.
3. CI renders, ships, and handler restarts `api`. ~30 seconds end-to-end.

The 1Password audit log records the edit. No git commit needed.

Add a secret to an existing service:

1. Add the field to the 1Password item for that service.
2. Add the reference line to the service's `.env.tpl` (git commit + push → triggers `ansible-apply.yml` automatically via path watcher).

Add secrets for a new service: see Section 10, steps 2–4 — create a new 1Password item in `cash-track-prod`, and add a new `<service>.env.tpl` file with `op://` references.

### Rotate the 1Password Service Account token

Quarterly, or on personnel change:

1. 1Password admin console → `cash-track-prod` vault → Service Accounts → rotate.
2. Update the `OP_SERVICE_ACCOUNT_TOKEN` GitHub org secret.
3. No playbook run needed; next CI invocation picks up the new token.

### Secrets NOT in 1Password

A handful of secrets live directly as GitHub org secrets because they are consumed only by CI, never by the droplet:

- `OP_SERVICE_ACCOUNT_TOKEN` — bootstrap root-of-trust for everything else
- `SPACES_TFSTATE_ID`, `SPACES_TFSTATE_KEY` — Terraform backend access
- `TS_AUTH_KEY` — CI tailnet join via reusable ephemeral auth key tagged `tag:ci`; generate in Tailscale admin → Keys; rotate every 90 days
- `DOCKERHUB_TOKEN`, `DOCKERHUB_USERNAME` — Docker Hub push from service repos; mirroring the value in 1Password `dockerhub` item for operator reference

Operator laptop authenticates to 1Password via the normal desktop app + `op signin`; no long-lived token on disk.

---

## 12. CI/CD

### Target repo topology

```
GitHub org: cash-track
├── .github                          # NEW — reusable workflows
│   └── .github/workflows/
│       ├── build.yml                # reusable: build + push image
│       ├── deploy.yml               # reusable: tailnet + ssh deploy-service
│       ├── ansible-apply.yml        # reusable: run a playbook
│       ├── quality-go.yml
│       ├── quality-php.yml
│       └── quality-node.yml
│
├── infra
│   └── .github/workflows/
│       ├── quality.yml              # existing — keep
│       ├── deploy.yml               # existing K8s — keep (rollback)
│       ├── deploy-*.yml             # existing K8s — keep (rollback)
│       ├── ansible-apply.yml        # NEW — trigger on ansible/**, compose/** push
│       ├── replace-droplet.yml      # NEW — workflow_dispatch
│       └── bootstrap.yml            # NEW — workflow_dispatch
│
├── api, gateway, frontend, website, mysql, redis, mysql-backup
│   └── .github/workflows/
│       ├── quality.yml              # calls org reusable quality-*.yml (app repos only)
│       ├── build.yml                # workflow_dispatch — calls org reusable build.yml
│       ├── deploy.yml               # workflow_dispatch — calls org reusable deploy.yml (rollback)
│       └── release.yml              # tag push — chains build.yml → deploy.yml
│
# crashers-bot and home-exporter live in repos outside the cash-track org
# (images at `vovanms/crashers_bot_api`, `vovanms/home_exporter` on Docker Hub).
# They are NOT consumers of the org reusable workflows — their images get pulled
# anonymously by the droplet, and `versions.crashers_bot` / `versions.home_exporter`
# in `infra/ansible/group_vars/all/main.yml` is bumped by hand to redeploy.
```

### Org secrets (scoped to selected repos)

| Secret | Used by | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | all service repos | Docker Hub push |
| `TS_AUTH_KEY` | all service repos + `infra` | Tailscale ephemeral node auth (reusable key tagged `tag:ci`; rotate every 90 days) |
| `OP_SERVICE_ACCOUNT_TOKEN` | `infra` only | 1Password read access for `op inject` in CI |
| `SPACES_TFSTATE_ID`, `SPACES_TFSTATE_KEY` | `infra` only | Terraform state access |
| `OPS_SSH_PRIVATE_KEY` | — not needed — | Auth via Tailscale SSH instead |

### `build.yml` and `deploy.yml` (reusable, in `cash-track/.github`)

The release pipeline is split into two reusables — `build.yml` (build + push) and `deploy.yml`
(tailnet + ssh `deploy-service`) — to mirror the existing per-repo structure (`build.yml`,
`deploy.yml`, `release.yml`). Splitting matters because:

- Tag push auto-builds → pushes → deploys via a chained `release.yml` in the service repo.
- Rebuild without redeploy (cache invalidation, base-image refresh) calls `build.yml` directly.
- Redeploy without rebuild (rollback) calls `deploy.yml` directly with the older tag, pulling
  the existing image off Docker Hub. A combined "ship" workflow would force a rebuild for every
  rollback, breaking the deterministic-image guarantee.

`build.yml` (build + push only) — uses `docker/metadata-action@v5` to derive tags from the git
ref (the existing org convention: `type=sha` for the commit SHA tag, `type=semver,pattern={{version}}`
to strip the `v` from `v1.2.9` git tags so the image is pushed as `1.2.9`). The `:latest` push
is controlled by metadata-action's `flavor: latest=auto` rule (only the highest semver). Outputs
the resolved `version` so the chained deploy job can pass the same tag the build pushed:

```yaml
name: Build
on:
  workflow_call:
    inputs:
      image:      { required: true,  type: string }
      context:    { required: false, type: string,  default: "." }
      dockerfile: { required: false, type: string,  default: "Dockerfile" }
      tag_rules:  { required: false, type: string,  default: "type=sha\ntype=semver,pattern={{version}}" }
      flavor:     { required: false, type: string,  default: "latest=auto" }
      build_args: { required: false, type: string,  default: "GIT_COMMIT=${{ github.sha }}\nGIT_TAG=${{ github.ref_name }}" }
      attest:     { required: false, type: boolean, default: true }
    secrets:
      DOCKERHUB_USERNAME: { required: true }
      DOCKERHUB_TOKEN:    { required: true }
    outputs:
      digest:  { value: ${{ jobs.build.outputs.digest }} }
      version: { value: ${{ jobs.build.outputs.version }} }
      tags:    { value: ${{ jobs.build.outputs.tags }} }

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      attestations: write
    outputs:
      digest:  ${{ steps.push.outputs.digest }}
      version: ${{ steps.meta.outputs.version }}
      tags:    ${{ steps.meta.outputs.tags }}
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ inputs.image }}
          tags:   ${{ inputs.tag_rules }}
          flavor: ${{ inputs.flavor }}
      - id: push
        uses: docker/build-push-action@v6
        with:
          context:    ${{ inputs.context }}
          file:       ${{ inputs.dockerfile }}
          push:       true
          tags:       ${{ steps.meta.outputs.tags }}
          labels:     ${{ steps.meta.outputs.labels }}
          build-args: ${{ inputs.build_args }}
          cache-from: type=gha
          cache-to:   type=gha,mode=max
      - if: ${{ inputs.attest }}
        uses: actions/attest-build-provenance@v1
        with:
          subject-name:    docker.io/${{ inputs.image }}
          subject-digest:  ${{ steps.push.outputs.digest }}
          push-to-registry: true
```

`deploy.yml` (tailnet + ssh deploy only):

```yaml
name: Deploy
on:
  workflow_call:
    inputs:
      service:        { required: true,  type: string }
      tag:            { required: true,  type: string }
      run_migrations: { required: false, type: boolean, default: false }
      droplet_host:   { required: false, type: string,  default: "cashtrack-prod-0" }
      droplet_user:   { required: false, type: string,  default: "ops" }
    secrets:
      TS_AUTH_KEY: { required: true }

concurrency:
  group: deploy-${{ inputs.service }}
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: prod
    steps:
      - uses: tailscale/github-action@v3
        with:
          authkey: ${{ secrets.TS_AUTH_KEY }}
      - env:
          SERVICE:        ${{ inputs.service }}
          TAG:            ${{ inputs.tag }}
          RUN_MIGRATIONS: ${{ inputs.run_migrations }}
          DROPLET_HOST:   ${{ inputs.droplet_host }}
          DROPLET_USER:   ${{ inputs.droplet_user }}
        run: |
          ssh -o StrictHostKeyChecking=accept-new "${DROPLET_USER}@${DROPLET_HOST}" \
            "/opt/cashtrack/bin/deploy-service ${SERVICE} ${TAG} ${RUN_MIGRATIONS}"
```

No infra checkout. No Ansible on the runner. No vault access. No PAT. SSH auth is Tailscale SSH, keyless — governed by the tailnet ACL granting `tag:ci` identity SSH to `tag:prod-server` as user `ops`.

### Caller in a service repo (`cash-track/api/.github/workflows/release.yml`)

```yaml
name: release
on:
  push:
    tags: ['v*.*.*']

jobs:
  build:
    uses: cash-track/.github/.github/workflows/build.yml@main
    with:
      image: cashtrack/api
    secrets: inherit

  deploy:
    needs: build
    uses: cash-track/.github/.github/workflows/deploy.yml@main
    with:
      service: api
      tag:     ${{ needs.build.outputs.version }}     # stripped semver — matches what was pushed
      run_migrations: true
    secrets: inherit
```

`build.yml` injects `GIT_COMMIT=${{ github.sha }}` and `GIT_TAG=${{ github.ref_name }}` as
default build args so Dockerfiles can stamp the image with provenance metadata. Repos that
don't `ARG` them in their Dockerfile silently ignore them; repos that need additional build
args override `build_args:` and re-specify these defaults if they still want them.

Every service repo's `release.yml` is the same shape — only `service`, `image`, and `run_migrations` vary. The repo also keeps a `build.yml` (`workflow_dispatch` → `build.yml@main`) for manual rebuild (operator passes `--ref` to dispatch a specific tag/branch/SHA) and a `deploy.yml` (`workflow_dispatch` → `deploy.yml@main`) for rollback to a known-good tag (passed as the bare version, e.g. `1.2.8`).

### The on-droplet deploy script (`/opt/cashtrack/bin/deploy-service`, installed by Ansible)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /opt/cashtrack

SERVICE="$1"
TAG="$2"                 # used verbatim; whatever GitHub passed
MIGRATE="${3:-false}"

VAR_NAME="VERSION_${SERVICE^^}"
VAR_NAME="${VAR_NAME//-/_}"

tmp=$(mktemp)
awk -v k="$VAR_NAME" -v v="$TAG" 'BEGIN{FS=OFS="="} $1==k{$2=v} 1' .env > "$tmp" && mv "$tmp" .env

COMPOSE="docker compose -f compose.core.yml -f compose.app.yml -f compose.obs.yml -f compose.telegram.yml"

$COMPOSE pull "$SERVICE"

if [[ "$MIGRATE" == "true" && "$SERVICE" == "api" ]]; then
  $COMPOSE run --rm api php app.php migrate -s -n
fi

$COMPOSE up -d --no-deps "$SERVICE"
```

### Infra-repo workflows

- `ansible-apply.yml` — triggered on push to `ansible/**`, `compose/**`, `terraform/**`. Installs `op` CLI (`1password/install-cli-action@v1`), exports `OP_SERVICE_ACCOUNT_TOKEN`, renders env templates via `op inject`, ships them to the droplet, runs `site.yml` with optional tag filter.
- `replace-droplet.yml` — workflow_dispatch. Installs `op` CLI, runs `replace-preflight.sh` (enforces fresh backup), then `terraform apply -replace=droplet[0]` + `site.yml`.
- `bootstrap.yml` — workflow_dispatch, first-ever provision. Runs `terraform apply` for everything + `site.yml` (also installs `op` CLI for initial secret rendering).

### Rollback

Rollback dispatches the per-repo `deploy.yml` workflow with the older tag — no rebuild, the
existing image is pulled from Docker Hub:

```bash
gh workflow run deploy.yml --repo cash-track/api -f tag=v1.2.8
```

This is why the release pipeline is split: a combined "ship" workflow would force a rebuild
on every rollback, defeating the deterministic-image guarantee.

For infra rollbacks, `git revert` + push triggers `ansible-apply.yml` automatically. The retained K8s workflows in `infra` remain available as an emergency escape hatch in the immediate post-cutover period.

---

## 13. Terraform State

Stored in a dedicated private Spaces bucket — separate from secrets, separate from assets, for blast-radius isolation.

### Buckets

All three buckets live in **AMS3**, co-located with the droplet. Rationale: the droplet and the backup job both talk to Spaces; putting them in the same region eliminates cross-region egress and keeps read latency in the low-millisecond range. There is no reason to split across regions — cross-region replication for DR is a future-work item and, if ever needed, would be configured via DO Spaces replication rather than by separating buckets at provision time.

| Bucket | Status | Visibility | Contents | Versioning | Access key |
|---|---|---|---|---|---|
| `cash-track-storage` | existing | **public** | User avatars, static assets (served via CDN) | as today | Wide (in app containers) |
| `cash-track-backups` | existing | private | MySQL dumps from `mysql-backup` container | as today | `mysql-backup` container + operator |
| `cash-track-tfstate` | **NEW** | private, "Block all public access" | `prod/terraform.tfstate` | on, 90-day noncurrent retention | Operator + CI |

Three separate access keypairs. A compromised app container can reach `cash-track-storage` (public anyway) and nothing else. A compromised backup key reaches only `cash-track-backups`. Only CI and the operator hold the `cash-track-tfstate` key. Secrets live in 1Password (not Spaces) — see Section 11.

### Backend configuration

`terraform/backend.tf`:

```hcl
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "cash-track-tfstate"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true     # native S3 conditional-write locking; DO Spaces supports this
  }
}
```

`terraform/backend.hcl` (not committed; `.gitignore`'d; `chmod 600`). Operator renders it locally from the `cash-track-tfstate` vault item:

```bash
eval "$(op signin)"
cat > terraform/backend.hcl <<EOF
endpoints = {
  s3 = "https://ams3.digitaloceanspaces.com"
}
access_key                  = "$(op read op://cash-track-prod/cash-track-tfstate/ACCESS_KEY_ID)"
secret_key                  = "$(op read op://cash-track-prod/cash-track-tfstate/SECRET_ACCESS_KEY)"
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
skip_region_validation      = true
skip_s3_checksum            = true
use_path_style              = true
EOF
chmod 600 terraform/backend.hcl
```

Initialized with `terraform -chdir=terraform init -backend-config=backend.hcl`.

### State locking

Two layers:

1. **Native S3 conditional-write locking via `use_lockfile = true`** (Terraform 1.10+). Writes a `prod/terraform.tfstate.tflock` object under a conditional `If-None-Match: *` precondition; DO Spaces supports S3 conditional writes, so two concurrent `terraform apply` invocations — whether from CI, operator laptop, or both — race on the lockfile and exactly one wins. This is the primary control.
2. **CI concurrency group as belt-and-braces.** `infra` repo workflows running `terraform apply` additionally share `concurrency: group: terraform-prod` with `cancel-in-progress: false`, so CI can't stack multiple runs in the first place. Spaces versioning (90-day noncurrent retention on the bucket) remains the rollback net if either layer fails.

**Local apply policy.** Because `use_lockfile` is now active, local `terraform apply` is technically safe — a CI-held lock will block a laptop run cleanly. But the operator laptop having a `backend.hcl` on disk is still an incident-risk surface. Treat local applies as break-glass, not routine:

- Day-to-day changes: commit → push → CI runs `terraform apply` via `ansible-apply.yml`.
- Operator-laptop apply: only when CI is unavailable (1Password outage on the runner, GitHub Actions incident, DR triage). Document the reason in the commit or incident log.

To push harder on this, the `SPACES_TFSTATE_ID/KEY` can be CI-only (removed from the operator laptop entirely) and rotated on a short cadence — the laptop then cannot apply routinely, forcing CI use. Decision left to the operator team; the native lockfile makes either policy safe.

**Rejected:** migrating state to a third-party HTTP backend (e.g., GitLab's free Terraform state). Adds an external dependency on a platform unrelated to our stack (DO + GitHub) for the single most critical file; the S3 backend is the portable default and `use_lockfile` closes the one gap that was motivating the workaround.

### Credentials flow

| Actor | Where |
|---|---|
| Operator | Renders `backend.hcl` from `op://cash-track-prod/cash-track-tfstate/{ACCESS_KEY_ID,SECRET_ACCESS_KEY}` to laptop disk, chmod 600, `.gitignore`'d |
| CI (`infra` repo) | Org secrets `SPACES_TFSTATE_ID/KEY` (mirror of the same vault item), written to `backend.hcl` at job start, `shred -u` on cleanup |

### Protect critical resources

```hcl
resource "digitalocean_volume" "data" {
  name   = "cashtrack-data"
  size   = var.volume_size_gb
  region = var.region
  lifecycle { prevent_destroy = true }
}

resource "digitalocean_reserved_ip" "main" {
  region = var.region
  lifecycle { prevent_destroy = true }
}
```

Droplet has no `prevent_destroy` — it's disposable by design.

### Bootstrap (one-time)

Create the three buckets and their keys manually via the DO console (or `doctl`), then run `terraform init`. The `scripts/bootstrap-buckets.sh` helper automates the `doctl` path.

---

## 14. Network Security

### DO Cloud Firewall (public NIC)

| Direction | Rule | Purpose |
|---|---|---|
| Inbound | TCP 80/443 from Cloudflare IPv4 + IPv6 ranges | Web traffic |
| Inbound | UDP 41641 from `0.0.0.0/0` | Tailscale direct peer-to-peer |
| Inbound | ICMP from `0.0.0.0/0` | Diagnostics |
| Inbound | TCP 22 | **Denied** (emergency toggle only) |
| Outbound | all | Tailscale, Docker pulls, Spaces, CF, GH |

Cloudflare IP ranges refreshed by `ops/firewall-refresh-cf.yml` (weekly cron + on-demand).

### Emergency SSH toggle

```bash
make ssh-open IP=$(curl -s ifconfig.me)     # adds TCP 22 rule for specific IP
make ssh-close                              # removes it
```

Implemented as two Ansible playbooks using the `community.digitalocean` collection. Not intended for routine use — Tailscale SSH is the normal path.

### Tailscale ACLs (conceptual; configured in Tailscale admin)

- `tag:prod-server` — the droplet
- `tag:ci` — ephemeral GitHub Actions runners; can SSH to `tag:prod-server` as `ops`
- `group:admin` — operators; can SSH + access Grafana / Prometheus / Alertmanager

Grafana and other internal dashboards are exposed through `tailscale serve` on the droplet, reachable only on the tailnet.

### Defense in depth

Traefik's `cloudflare-only` middleware (IP allowlist of CF ranges) is applied to all external routers. If the DO Firewall's CF IP list ever lags behind a CF range update, Traefik still rejects non-CF source IPs.

---

## 15. Observability

### Slimmed retention — 7-day operational window

| Component | Retention | Disk target |
|---|---|---|
| Prometheus | 7d | 4 GB |
| Loki | 168h (7d) | 5 GB |
| Tempo | 72h (3d) | 3 GB |

Beyond 7 days, if deeper history is needed, ship to Spaces via the ruler / Loki's filesystem client with periodic sync — future work, not day-one.

### Scrape and log targets

- **Prometheus** scrapes services over the `cashtrack-app` Docker network via service discovery labels.
- **Node Exporter** runs on the droplet host, port 9100, scraped by Prometheus.
- **Promtail** uses Docker SD — reads container stdout via the Docker socket, tags with container name.
- **Tempo** ingests OTLP traces via gRPC (`:4317`), connected by the api, gateway, and website.

### Alerting — two layers

1. **Internal (Alertmanager on the droplet → Telegram):** "something on the droplet is unhealthy". Dies with the droplet.
2. **External (Cloudflare Health Check OR a scheduled GitHub Action posting directly to the Telegram bot on failure):** "the droplet is gone". Covers the self-observability gap. The GH Action route is cheaper and under our control; the Telegram bot token lives as a repo-level secret in the `.github` org workflows repo.

The external check runs every 1 minute against `https://api.cash-track.app/healthcheck`, alerts on 3 consecutive failures.

### Host-level alert rules (internal Prometheus → Alertmanager → Telegram)

These rules catch host-class failures earlier than service health checks do. Authored day-one alongside the existing service alerts copied from `./infra/services/prometheus/configs/`.

```yaml
groups:
  - name: host.rules
    rules:
      # Memory pressure — early warning before OOM.
      # PSI "some" > 10% sustained for 2 min = tasks stalling on memory reclaim.
      - alert: HostMemoryPressure
        expr: rate(node_pressure_memory_waiting_seconds_total[2m]) > 0.10
        for: 2m
        labels: { severity: warning }
        annotations:
          summary: Memory pressure on {{ $labels.instance }} (PSI {{ $value | humanizePercentage }})

      # Kernel/library patch installed, reboot pending. Scheduled 04:00 UTC
      # window should clear this within 24h; fires if the reboot didn't happen
      # (e.g., long-running process blocked shutdown, or Automatic-Reboot misfired).
      - alert: HostRebootRequired
        expr: node_reboot_required == 1
        for: 7d
        labels: { severity: warning }
        annotations:
          summary: Droplet has had a pending reboot for >7 days — scheduled window missed

      # Backup freshness — primary defense against the `make replace` preflight
      # ever firing during an incident. Catch stale backups before you need them.
      - alert: MySQLBackupStale
        expr: time() - mysql_backup_last_success_timestamp_seconds > 6 * 3600
        for: 15m
        labels: { severity: critical }
        annotations:
          summary: Last successful MySQL backup is {{ $value | humanizeDuration }} old (expected cadence 3h)

      # Disk I/O saturation — proxy for the Block Volume contention risk flagged
      # in Section 19. Investigate if it stays saturated (MySQL tuning, Loki/Prom
      # retention caps, or escalate to storage split per Section 21).
      - alert: BlockVolumeIOPSSaturated
        expr: rate(node_disk_io_time_seconds_total{device=~"sda|vda|sd.|vd."}[5m]) > 0.80
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: Block Volume IO utilization >80% sustained on {{ $labels.instance }}
```

The `mysql_backup_last_success_timestamp_seconds` metric is emitted by the backup container on successful upload (small PHP tweak to write a Prometheus textfile collector entry; node-exporter picks it up via the textfile collector). Same source feeds `scripts/replace-preflight.sh`.

### Dashboards

Grafana provisioning (`config/grafana/provisioning/`):
- Datasources: Prometheus, Loki, Tempo — auto-wired
- Dashboards: Traefik, api latency, MySQL, Redis, Node, Ofelia jobs — committed as JSON

Accessed via `https://grafana-cashtrack.<tailnet>.ts.net` (Tailscale Serve).

---

## 16. Initial Cutover Plan

### Pre-cutover (any time beforehand)

1. **Create the new Spaces bucket** `cash-track-tfstate` in AMS3 with "Block all public access". Existing `cash-track-storage` (public) and `cash-track-backups` (private) stay as-is. Create one dedicated access key for it.
2. **Set up the 1Password vault** `cash-track-prod`: create the 12 items per Section 11 (`api`, `common`, `mysql`, `mysql-exporter`, `alertmanager-telegram`, `grafana`, `crashers-bot`, `home-exporter`, `cloudflare-origin-cert`, `cloudflare-origin-cert-potwora`, `tailscale`, `dockerhub`, `do-api`) and populate from existing K8s secrets. Create a read-only Service Account scoped to the vault; store its token as `OP_SERVICE_ACCOUNT_TOKEN` org secret.
3. **Provision infra:** `make apply && make bootstrap`. Wait for all containers green.
4. **Restore from latest K8s MySQL backup:** `ansible-playbook ops/backup-restore.yml -e backup_id=latest`.
5. **Internal smoke test** via Tailscale with `curl --resolve`:
   ```bash
   RIP=$(terraform -chdir=terraform output -raw reserved_ip)
   for host in cash-track.app my.cash-track.app api.cash-track.app gateway.cash-track.app; do
     curl -sS -o /dev/null -w "%{http_code}\n" \
          --resolve "$host:443:$RIP" "https://$host/healthcheck" || true
   done
   ```
6. **Push CF Origin cert** to Traefik: `ansible-playbook site.yml --tags compose`.

### Cutover window (~15–20 min planned, ~5–10 min expected)

```
T+0min   Announce downtime.
         Scale K8s writers to 0:
           kubectl scale deployment/api --replicas=0 -n cash-track
           kubectl scale deployment/gateway --replicas=0 -n cash-track
           kubectl scale deployment/website --replicas=0 -n cash-track
           kubectl scale deployment/frontend --replicas=0 -n cash-track

T+1min   Trigger final MySQL backup on K8s:
           kubectl exec deployment/mysql-backup -- php app.php backup

T+3min   Restore that backup onto the droplet:
           ansible-playbook ops/backup-restore.yml -e backup_id=<just-created-id>
         Verify row counts against pre-cutover snapshot of key tables.

T+5min   Flip Cloudflare A records: 206.189.242.130 → <reserved_ip>
         For: cash-track.app, my.cash-track.app, api.cash-track.app, gateway.cash-track.app.
         CF edge propagation is immediate; eyeball-visible in seconds.

T+6min   Smoke test through real URLs (login + load wallet + create charge).

T+8min   Monitor Grafana for 15 min:
         - Traefik 5xx rate
         - api p95 latency
         - MySQL connection count
         - Loki for fresh error spikes
```

### Rollback

If smoke test fails within the window: flip Cloudflare A records back to `206.189.242.130` (single action). K8s writers are still at 0 replicas but MySQL in K8s has the pre-cutover data intact. Scale them back up:

```bash
kubectl scale deployment/api --replicas=2 -n cash-track
kubectl scale deployment/gateway --replicas=2 -n cash-track
kubectl scale deployment/website --replicas=1 -n cash-track
kubectl scale deployment/frontend --replicas=1 -n cash-track
```

**Data integrity note:** between T+1min (final K8s backup) and T+5min (DNS flip), no writes occur. Rollback restores the exact pre-cutover state. The write freeze is non-negotiable; without it, K8s and the droplet would have diverged data and rollback is impossible.

### Post-cutover

- Keep K8s running, writers at 0 replicas, for 48 hours as a rollback safety net.
- After 48 hours incident-free: `kubectl delete namespace cash-track`; tear down the DOKS cluster + LB.
- Existing K8s workflows remain preserved but disabled (trigger stripped to `workflow_dispatch` during observation; folder renamed to `workflows.disabled/` after decommission). K8s manifests in `common/` and `services/` stay in git for reference.

---

## 17. Droplet Replacement (DR) Runbook

### Triage — escalate to replace, don't start there

Replacement is a 5–8 min outage. Many "droplet down" incidents are faster to recover in place. Escalate in order:

1. **Service-level** (most common). Single container unhealthy:
   ```bash
   tailscale ssh ops@cashtrack-prod-0 "docker compose logs --tail=200 <service>"
   tailscale ssh ops@cashtrack-prod-0 "docker compose restart <service>"
   ```
   Typical recovery: 10–30s. No user visibility if Traefik healthcheck drains cleanly.

2. **Docker daemon-level.** Compose works but containers won't start / won't pull:
   ```bash
   tailscale ssh ops@cashtrack-prod-0 "sudo systemctl restart docker && docker compose up -d"
   ```
   Typical recovery: 30–60s. All containers bounce; Traefik re-routes on health.

3. **OS-level, droplet reachable.** System-wide wedged state (kernel panic avoided, but filesystem read-only, memory exhausted with no swap, etc.):
   ```bash
   doctl compute droplet-action power-cycle <droplet-id>
   ```
   Typical recovery: 60–120s. Block Volume reattaches on boot; Docker starts containers; post-reboot smoke check (base role) validates.

4. **Droplet gone or unrecoverable.** Only now: `make replace`.

Step 4 is what the rest of this section documents. Steps 1–3 cover the majority of real incidents and don't need the backup-freshness guard.

### Block Volume corruption — a different runbook

**`make replace` does not help you if the Block Volume itself is corrupt.** It destroys the droplet and reattaches the same volume; if the volume is the problem, the new droplet inherits it. Symptoms: mount fails in cloud-init, fsck errors on boot, MySQL refuses to start with `Operating system error number 22`, files missing after a DO storage incident.

Separate procedure (`make restore-to-new-volume`):

```bash
# 1. Stop scheduled jobs + backup cron to avoid writes to a volume about to be discarded.
# 2. Provision a new Block Volume + snapshot the old one (for forensics).
terraform -chdir=terraform apply -var='new_volume=true'

# 3. Run cloud-init-equivalent mount path on the new volume (formatted blank).
# 4. Restore the latest good backup from cash-track-backups into MySQL on the new volume.
ansible-playbook ops/backup-restore.yml -e backup_id=<id>

# 5. Swap `digitalocean_volume.data` reference to the new volume.
# 6. terraform apply (droplet replace, with the new volume in play).
```

RPO for this path = "last successful backup age." This is the one scenario where backup freshness actually determines data loss. Everything else (droplet gone, OS wedged, Docker broken) preserves the volume and RPO stays zero.

### Droplet replacement — minimal command

```bash
make replace
```

Equivalent to:

```bash
./scripts/replace-preflight.sh              # fails if last backup in cash-track-backups is >24h old
terraform -chdir=terraform apply -replace='digitalocean_droplet.host[0]' -auto-approve
ansible-playbook -i ansible/inventory/prod/terraform.sh ansible/site.yml
```

### Sequence

| # | Step | Duration |
|---|---|---|
| 1 | `terraform apply -replace` destroys the old droplet | ~30s |
| 2 | TF detaches Reserved IP and Block Volume (separate resources) | ~10s |
| 3 | TF creates a new droplet with identical `user_data` | ~30s |
| 4 | TF reattaches Block Volume + Reserved IP | ~20s |
| 5 | Cloud-init: Tailscale up, Docker install, `mkfs` guard preserves existing FS, mount `/mnt/data` | ~60–90s |
| 6 | Ansible `site.yml` over tailnet: renders configs, `docker compose up -d` | ~2–4 min |
| 7 | Traefik routes to restarted containers with existing MySQL data intact | — |

**Total RTO: 5–8 minutes.** Cloudflare DNS never changed. External observers saw a 5–8 min 502.

### RPO

- MySQL: zero (same volume, same filesystem).
- Redis: in-memory state lost (accepted).
- Observability: zero (same volume).

### Guards

- `mkfs` only runs if the filesystem label `cashtrack-data` is not present (cloud-init; bounded wait + label check, see Section 6).
- `make replace` blocks if the latest object in `cash-track-backups` is >24h old (`replace-preflight.sh`). The guard exists because the replacement flow can theoretically corrupt the volume (cloud-init bug, operator fat-finger on `-replace` target); the backup is the parachute, not the restore source. See "Backup-freshness override" below.
- `prevent_destroy` on `digitalocean_volume.data` and `digitalocean_reserved_ip.main`.

### Backup-freshness override (break-glass)

`replace-preflight.sh` refuses to run when the last backup is >24h old. The upstream fix is the `MySQLBackupStale` alert (Section 15) firing at 6h so the stale-backup state is never silently reached. But if you're here and the guard is blocking an active incident, override like this:

```bash
FORCE_REPLACE_REASON="inc-<id>: <why backup is stale AND why replacing now is lower risk than waiting>" make replace
```

Rules:

- Empty or unset `FORCE_REPLACE_REASON` → preflight still refuses. No bare `FORCE_REPLACE=1` flag.
- Preflight writes the reason + operator identity + last backup age to `s3://cash-track-tfstate/audit/replace-overrides/<timestamp>.json` and posts an Alertmanager-style message to the ops Telegram channel: *"replace-preflight bypassed by $USER: $FORCE_REPLACE_REASON (last backup: 26h)"*. Non-optional — if either the audit write or the Telegram post fails, preflight aborts.
- Expected cadence: approximately never. Every override is a postmortem input.

### What to verify after a replace

1. `tailscale status` on the droplet
2. `docker compose ps` all healthy
3. Post-reboot smoke check metric: `cashtrack_postreboot_check_ok == 1`
4. Grafana: MySQL connection count, api p95, Traefik 5xx rate
5. Smoke test externally: `curl https://api.cash-track.app/healthcheck`
6. Row-count spot-check on the largest mutable tables vs a pre-incident snapshot (if available), to catch any silent filesystem damage the mount guard didn't detect.

---

## 18. Day-2 Operations

### Daily (passive)

- Ofelia runs `mysql-backup` at 03:00 UTC, uploads to `cash-track-backups` (private).
- Alertmanager delivers firing alerts to Telegram.
- Prometheus drops >7d data automatically.

### Weekly (recommended)

```bash
make backup-verify          # pulls latest dump from cash-track-backups, restores into a
                            # throwaway container, runs row-count SELECTs, discards.
```

### Monthly

- Review droplet RAM/CPU in Grafana. Resize if sustained >80%.
- Prune old Docker images: `ssh ops@cashtrack-prod-0 'docker system prune -af --filter until=168h'`.

### Droplet OS/size upgrade

```bash
# edit terraform/terraform.tfvars:
# droplet_size  = "s-4vcpu-16gb"
# droplet_image = "ubuntu-26-04-x64"
make apply       # TF detects change, prompts for approval; replacement flow runs
```

Same replacement mechanics as `make replace`. RTO ~5–8 min.

### Common failure responses

| Symptom | First action |
|---|---|
| Service returns 502 | `tailscale ssh ops@cashtrack-prod-0 'docker compose logs --tail=200 <service>'`; `docker compose restart <service>` if isolated |
| Droplet unreachable via Tailscale | `make ssh-open IP=$(curl ifconfig.me)` → SSH to public IP |
| Container cgroup-OOM (single service) | Expected behavior — `docker inspect <ctr> --format '{{.State.OOMKilled}}'` confirms; Docker restarts it. If repeated, raise that service's `mem_limit` or investigate the allocation pattern. |
| Host-level OOM or PSI alert sustained | `oom_score_adj` bias protects MySQL; expect Loki/Tempo to die first. Review Grafana memory panel + PSI; resize droplet if sustained >6.5 GB used or PSI >5% for hours. |
| Full volume | `docker system df` on droplet; check retention caps are actually in effect (`promtool` / `tempo-cli`); `docker system prune -af --filter until=168h` |
| Backups not running | `MySQLBackupStale` alert should have fired already; check Ofelia logs in Loki: `{container="ofelia"}` |
| Reboot-required alert fires | Patch a kernel or library installed but the 04:00 window hasn't come around yet. Wait, or `sudo reboot` manually if urgent — the post-reboot smoke check validates recovery. |

---

## 19. Critique and Residual Risks

### Accepted risks

1. **Single point of failure.** By design, for the cost reduction. RTO 5–8 min is the mitigation.
2. **Redis data loss on restart.** Accepted — CSRF tokens invalidate, users reauth on next mutating request.
3. **Self-observability gap.** Alertmanager co-resident with the services it observes. External Cloudflare/GH Actions health check closes this.
4. **Vertical resize is the only scaling lever.** No horizontal scale without a bigger re-architecture.
5. **Scheduled maintenance-window reboots.** `Automatic-Reboot-Time "04:00"` UTC means a handful of ≈60–180s outages per year when a kernel or core-library patch requires reboot. Accepted in exchange for not running a vulnerable kernel. Alternative (rejected) was Ubuntu Pro + Livepatch.
6. **Joint 1Password + droplet outage → unbounded CI-path RTO.** `ansible-apply.yml` / `replace-droplet.yml` / `bootstrap.yml` all require `op inject` on the CI runner. If 1P API is down at the same moment the droplet fails, CI cannot render secrets. Operator-laptop path survives via the 1P desktop cache (see Section 11). 1P's published SLA is ~99.9%; joint outage with a DO droplet failure is small but non-zero probability. Break-glass: operator runs `ansible-playbook site.yml` locally against the cached vault. Further mitigation (rejected day-one, reconsider if it bites): encrypted `.env` snapshot in the tfstate bucket, decrypted with an age key held by the operator.

### Things to monitor / revisit

1. **MySQL in Docker with host bind-mount** — lower performance than bare-metal or managed. Monitor p95 query latency; revisit if >100ms on simple queries.
2. **Traefik reads the Docker socket.** RCE on Traefik pivots to root. Mitigations: pin version, read-only socket mount, consider `docker-socket-proxy` later.
3. **Tailscale daemon health** is a hard dependency for operator access. If Tailscale on the droplet dies, emergency SSH toggle is the fallback.
4. **Terraform state locking.** Now native via `use_lockfile = true` (DO Spaces supports S3 conditional writes, Terraform 1.10+). Belt-and-braces: CI concurrency group + Spaces versioning. Monitor for lockfile-related errors in practice; fall back to concurrency-group-only if conditional writes ever misbehave on the provider.
5. **Block Volume I/O contention.** MySQL, Prometheus, Loki, Tempo share one 25 GB network-attached volume. DO caps per volume at 5,000 write IOPS / 7,500 read IOPS / ~300 MB/s — flat, not per-GB. Steady-state demand is well under ceiling; realistic risk is burst contention during Prometheus TSDB compaction collapsing MySQL commit p99. Mitigations in place: `noatime`, MySQL tuned for network SSD, hard retention + ingest caps on all three (Section 5). Monitor via `BlockVolumeIOPSSaturated` alert (Section 15); escalate to the storage-split option in Section 21 only if measurements show sustained saturation after tuning.
6. **GH Actions image pulls from Docker Hub** — subject to Docker Hub rate limits on replacement. Mitigation (future work): authenticated pulls or DO Container Registry.
7. **Swap on root disk, not Block Volume.** 1 GB root-disk swap buffers transient memory spikes without the network-device thrashing pathology of swap on Block Volume. If memory pressure becomes chronic (PSI alert firing regularly), don't grow swap — resize the droplet. Swap is insurance for spikes, not a capacity lever.

### Rejected alternatives

- **Managed MySQL / Managed Redis** — overkill for 1GB data; doubles the managed-services cost.
- **SOPS + age or Ansible Vault** instead of 1Password — added tool complexity and no existing subscription leverage; 1Password gives audit log, granular access, and desktop-app ergonomics for free.
- **Push-on-bump with a droplet-side Watchtower** — harder to audit; splits deploy state between GH and droplet.
- **Jinja-templated compose files** — user preference for static compose + `.env`; sacrificing a small amount of DRY for cleaner diffs.
- **Checking out the `infra` repo in service-deploy workflows** — needlessly requires PAT/App; direct SSH to on-droplet deploy script is simpler and matches today's `kubectl set image` shape.
- **GitLab HTTP backend for Terraform state locking.** Adds a third-party free-tier dependency on a platform unrelated to our stack (DO + GitHub) for the single most critical file. Native S3 conditional-write locking (`use_lockfile = true`) closes the gap without the extra provider.
- **Ubuntu Pro + Livepatch for kernel CVE patching.** Free tier covers the one droplet, but introduces a Canonical-account dependency and per-token expiry management. The scheduled 04:00 UTC maintenance window + `needrestart` + reboot-required alerting covers the same security posture with less account plumbing.
- **Swap on the Block Volume.** Network-attached storage turns memory pressure into thrashing — minutes of unresponsiveness instead of a clean OOM kill. Root-disk swap only.
- **Larger Block Volume to "buy" IOPS.** DO's per-volume IOPS cap is flat regardless of size (unlike AWS gp3). Resizing only buys capacity.

---

## 20. Out of Scope

Explicitly not in this design:

- Migration of the `dev-cash-track.app` local development environment (unchanged; stays on developer laptops with Traefik + local MySQL/Redis).
- Rewriting any application code. All images used are the existing published versions.
- Observability alert rule authorship — copied verbatim from the existing `./infra/services/prometheus/configs/` and `./infra/services/alertmanager/configs/`.
- A second production environment (staging). If introduced later, a second Terraform workspace is the pattern.
- Redis persistence. Accepted data loss, per requirements.

---

## 21. Future Work

Items explicitly deferred:

1. **Multi-droplet scaling.** `droplet_count > 1` is accepted by the Terraform code but stateful services (MySQL, Loki, etc.) must stay on droplet[0] (which holds the Block Volume and Reserved IP). Scaling stateless services (api, gateway, frontend, website) to additional droplets requires: (a) Traefik's mode rethought (e.g., one Traefik per droplet behind a DO LB, or move Traefik to droplet[0] only and add an internal LB), (b) session affinity decisions, (c) shared filesystem decisions (spec'd to use Spaces, not shared volumes).
2. **Split storage tier for observability if I/O contention materializes.** Trigger: `BlockVolumeIOPSSaturated` fires sustained after MySQL tuning and retention caps are already in place. Landing spot: move `prometheus/`, `loki/`, `tempo/` bind-mounts from `/mnt/data` to `/var/lib/docker/volumes` on the droplet's local SSD (or a Premium Intel/AMD SKU for guaranteed local NVMe). Pair with `remote_write` to Grafana Cloud's free tier so pre-incident observability data survives droplet replacement — otherwise DR events lose the history needed for postmortem. Trade: zero RPO on observability → 7d RPO + ~free-tier-lag-seconds to Grafana Cloud. Accepted when measurement justifies.
3. **Long-term observability archival.** Ship Loki chunks to Spaces with retention beyond 7d, accessed on-demand via a separate Loki instance pointed at Spaces.
4. **Encrypted `.env` snapshot in tfstate bucket.** Mitigates the joint 1P-outage + droplet-outage tail (Section 19 accepted risk 6). Re-rendered after any vault edit; DR path decrypts with an age key held by the operator. Defer until the joint-outage probability proves non-academic.
5. **GitHub App** replacing any remaining PATs for GitHub API calls (Docker Hub is an org secret, not a PAT, so not relevant; only applies if someday the infra repo needs to be checked out cross-repo).
6. **Docker Socket Proxy** to harden Traefik's access.
7. **Automated monthly Docker Hub rate-limit check** as a GH Actions cron — warn if approaching limits.
8. **HA.** A genuinely HA architecture is a different design: managed MySQL, managed Redis, ≥2 droplets behind a DO LB, shared Spaces-backed file storage for per-request state, and a re-architected observability stack. Not attempted here.

---

## 22. Implementation Sequencing

When this design is approved and work begins, implementation proceeds in these stages, each independently verifiable before moving on:

1. **Stage 0 — Spaces bucket + 1Password vault + baseline.** Create `cash-track-tfstate` (new) and its access key via `scripts/bootstrap-buckets.sh`. Set up the `cash-track-prod` 1Password vault — create all items and migrate values from existing K8s secrets. Create a read-only Service Account scoped to the vault; store the token as `OP_SERVICE_ACCOUNT_TOKEN` GitHub org secret.
2. **Stage 1 — Terraform.** Write modules + `terraform.tfvars`. `terraform plan` produces an actionable plan.
3. **Stage 2 — First provision.** `make apply && make bootstrap` brings up a droplet with core compose stack (traefik, mysql empty, redis, ofelia). Verify via Tailscale.
4. **Stage 3 — App services.** Bring up api, gateway, frontend, website, mysql-backup, mysql-exporter. Restore from a K8s MySQL backup. Internal smoke test with `curl --resolve`.
5. **Stage 4 — Observability.** Bring up prometheus, node-exporter, grafana, loki, tempo, promtail, alertmanager. Import dashboards. Verify alerts flow to Telegram (intentionally fire a test alert via `amtool alert add`).
6. **Stage 5 — Telegram-namespace apps.** Bring up crashers-bot and home-exporter (each with its own image and env file); register Ofelia schedules for any cron-style jobs.
7. **Stage 6 — CI/CD.** Create `cash-track/.github` repo with reusable workflows; update service repos' `release.yml`. Test a deploy to the droplet from a tag push in a scratch branch.
8. **Stage 7 — Cutover.** Run the Section 16 runbook.
9. **Stage 8 — Decommission.** After 48h observation, tear down DOKS.

Each stage produces a reviewable `git push` to the `infra` repo and a verifiable outcome in the droplet's state.
