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
| `compose.telegram.yml` | tg-bot (connects to the shared MySQL under a separate database + user) |

Replica counts drop from 2 → 1 for api and gateway (no HA benefit on a single host). Traefik's retry middleware absorbs the brief restart window.

### MySQL tenant model

A single MySQL server hosts multiple databases, one user per application:

| Database | Application user | Vault key |
|---|---|---|
| `cashtrack` | `cashtrack_app` | `mysql_app_passwords.cashtrack_app` |
| `telegram_bots` | `tg_bot_app` | `mysql_app_passwords.tg_bot_app` |
| *(future)* `wordpress` | `wp_app` | `mysql_app_passwords.wp_app` |

Root credentials are used only by initial provisioning, `mysql-backup`, and `mysql-exporter`.

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
│   ├── replace-preflight.sh
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
  tg_bot:       "1.0.0"

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

| Component | Expected |
|---|---|
| MySQL data (+headroom) | 5 GB |
| Prometheus 7d retention | 4 GB |
| Loki 7d retention | 5 GB |
| Tempo 3d retention | 3 GB |
| Grafana + Alertmanager | 1 GB |
| Headroom (images, compose overhead) | ~2 GB |
| **Total** | **~20 GB** |

Redis data is not persisted (accepted data loss on reboot); CSRF tokens invalidate on restart and users reauth on next mutating request.

### Memory on the droplet (8 GB total, ~1.8 GB headroom)

| Service | MB |
|---|---|
| api | 700 |
| gateway | 100 |
| frontend | 100 |
| website (Nuxt SSR) | 500 |
| mysql | 800 |
| redis | 300 |
| traefik | 100 |
| prometheus | 500 |
| grafana | 200 |
| loki | 500 |
| tempo | 500 |
| alertmanager | 100 |
| promtail | 100 |
| node-exporter + mysql-exporter + ofelia | 150 |
| tg-bot | 500 |
| OS + Docker overhead | 600 |
| **Total used** | **~5 750** |
| **Headroom** | **~2 250** |

If sustained memory usage exceeds 6.5 GB or the `website` SSR spikes under traffic, resize to `s-4vcpu-16gb` ($96/mo) via `terraform apply`. Resize uses the droplet-replacement flow; Block Volume data is untouched.

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

  # Block Volume mount — idempotent for replacement case
  - |
    DEV=/dev/disk/by-id/scsi-0DO_Volume_${volume_name}
    if ! blkid $DEV; then mkfs.ext4 -L cashtrack-data $DEV; fi
    mkdir -p /mnt/data
    grep -q LABEL=cashtrack-data /etc/fstab || echo "LABEL=cashtrack-data /mnt/data ext4 defaults,nofail,discard 0 2" >> /etc/fstab
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
| Tailscale auth key expired before use | Re-run `terraform apply` (provider rotates the key) |
| Volume attached but wrong label | `mkfs` guard blocks reformat; manual intervention required (intentional) |
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
    - base                 # apt upgrade, unattended-upgrades, timezone, chrony
    - docker               # daemon.json with log rotation + json-file size caps
    - firewall-refresh     # CF IP list → DO Cloud Firewall via digitalocean API
    - volume               # verifies /mnt/data mount, creates directory skeleton
    - mysql-init           # minimal mysql container, creates DBs + users idempotently
    - compose-render       # renders .env, secrets/*.env, config/* ; uploads static compose/*.yml
    - compose-up           # `docker compose -f ... up -d --remove-orphans`
```

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
│   └── telegram.env
├── config/
│   ├── traefik/{traefik.yml,dynamic.yml,origin-cert.pem,origin-key.pem}
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

  redis:
    image: cashtrack/redis:${VERSION_REDIS}
    restart: unless-stopped
    networks: [app]
    # intentionally NO volume
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]

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

  mysql-exporter:
    image: prom/mysqld-exporter:v0.15.1
    restart: unless-stopped
    networks: [app]
    env_file: [secrets/mysql-exporter.env]
    command: ["--mysqld.address=mysql:3306"]
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
tls:
  certificates:
    - certFile: /etc/traefik/origin-cert.pem
      keyFile:  /etc/traefik/origin-key.pem
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

### Example — telegram bot jobs

```yaml
services:
  tg-bot:
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

1. **Add the database + user** — edit `ansible/roles/mysql-init/vars/databases.yml`:
   ```yaml
   databases:
     - { name: wordpress, user: wp_app, password_op_ref: "op://cash-track-prod/mysql-app-users/WORDPRESS_APP_PASSWORD" }
   ```
2. **Add the secret in 1Password** — open the `cash-track-prod` vault in the desktop app; under the `mysql-app-users` item add field `WORDPRESS_APP_PASSWORD`. Also create a new item `wordpress` with fields for any WP-specific secrets (e.g. `WORDPRESS_AUTH_KEY`).
3. **Add a per-service env template** — `ansible/roles/compose-render/templates/wordpress.env.tpl`:
   ```ini
   WORDPRESS_DB_HOST=mysql
   WORDPRESS_DB_NAME=wordpress
   WORDPRESS_DB_USER=wp_app
   WORDPRESS_DB_PASSWORD={{ op_prefix }}/mysql-app-users/WORDPRESS_APP_PASSWORD
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

Accepted trade-offs: runtime dependency on the 1Password API at deploy time (high uptime, and we are not deploying during SaaS outages anyway), and the Service Account token becomes the single most valuable credential (mitigated by scope + rotation).

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
├── api                      fields: JWT_SECRET, CAPTCHA_SECRET_KEY, FIREBASE_CREDENTIALS,
│                                     GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, ...
├── gateway                  fields: CAPTCHA_SECRET_KEY, ...
├── mysql                    fields: ROOT_PASSWORD, REPLICATION_PASSWORD
├── mysql-app-users          fields: CASHTRACK_APP_PASSWORD, TG_BOT_APP_PASSWORD, WP_APP_PASSWORD
├── mysql-backup             fields: SPACES_KEY, SPACES_SECRET, BUCKET_NAME
├── mysql-exporter           fields: DATA_SOURCE_NAME
├── alertmanager-telegram    fields: BOT_TOKEN, CHAT_ID
├── grafana                  fields: ADMIN_PASSWORD, SMTP_PASSWORD
├── telegram-bot             fields: BOT_TOKEN, WEBHOOK_SECRET
├── cloudflare-origin-cert   fields: CERT_PEM, KEY_PEM (attachments)
├── tailscale                fields: OAUTH_CLIENT_ID, OAUTH_CLIENT_SECRET
├── dockerhub                fields: USERNAME, TOKEN
└── do-api                   fields: TOKEN (for firewall-refresh playbook + doctl)
```

### Templates reference secrets by `op://` URI

Templates live in git — reviewable in PRs, no secret material embedded.

`ansible/roles/compose-render/templates/api.env.tpl`:

```ini
APP_ENV=prod
DEBUG=false
JWT_SECRET={{ op_prefix }}/api/JWT_SECRET
CAPTCHA_SECRET_KEY={{ op_prefix }}/api/CAPTCHA_SECRET_KEY
FIREBASE_CREDENTIALS={{ op_prefix }}/api/FIREBASE_CREDENTIALS
GOOGLE_CLIENT_ID={{ op_prefix }}/api/GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET={{ op_prefix }}/api/GOOGLE_CLIENT_SECRET
DB_HOST=mysql
DB_NAME=cashtrack
DB_USER=cashtrack_app
DB_PASSWORD={{ op_prefix }}/mysql-app-users/CASHTRACK_APP_PASSWORD
...
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
- `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` — CI tailnet join (could live in 1Password, but CI reads org secrets more cleanly than `op`-lookups during early job steps before `op` CLI is installed)
- `DOCKERHUB_TOKEN`, `DOCKERHUB_USERNAME` — Docker Hub push from service repos; mirroring the value in 1Password `dockerhub` item for operator reference

Operator laptop authenticates to 1Password via the normal desktop app + `op signin`; no long-lived token on disk.

---

## 12. CI/CD

### Target repo topology

```
GitHub org: cash-track
├── .github                          # NEW — reusable workflows
│   └── .github/workflows/
│       ├── ship-service.yml         # reusable: build → push → deploy
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
├── api, gateway, frontend, website, telegram-bot
│   └── .github/workflows/
│       ├── quality.yml              # calls org reusable quality-*.yml
│       └── release.yml              # calls org reusable ship-service.yml on tag
```

### Org secrets (scoped to selected repos)

| Secret | Used by | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | all service repos | Docker Hub push |
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` | all service repos + `infra` | Tailscale ephemeral node auth |
| `OP_SERVICE_ACCOUNT_TOKEN` | `infra` only | 1Password read access for `op inject` in CI |
| `SPACES_TFSTATE_ID`, `SPACES_TFSTATE_KEY` | `infra` only | Terraform state access |
| `OPS_SSH_PRIVATE_KEY` | — not needed — | Auth via Tailscale SSH instead |

### `ship-service.yml` (reusable, in `cash-track/.github`)

```yaml
name: Ship service
on:
  workflow_call:
    inputs:
      service:        { required: true, type: string }
      image:          { required: true, type: string }
      tag:            { required: true, type: string }
      context:        { required: false, type: string, default: "." }
      dockerfile:     { required: false, type: string, default: "Dockerfile" }
      run_migrations: { required: false, type: boolean, default: false }
    secrets:
      DOCKERHUB_USERNAME:     { required: true }
      DOCKERHUB_TOKEN:        { required: true }
      TS_OAUTH_CLIENT_ID:     { required: true }
      TS_OAUTH_SECRET:        { required: true }

concurrency:
  group: deploy-${{ inputs.service }}
  cancel-in-progress: false

jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          push: true
          tags: |
            ${{ inputs.image }}:${{ inputs.tag }}
            ${{ inputs.image }}:latest
          cache-from: type=gha
          cache-to:   type=gha,mode=max

  deploy:
    runs-on: ubuntu-latest
    needs: build-push
    steps:
      - name: Join tailnet (ephemeral)
        uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret:    ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci
      - name: Deploy service
        env:
          TAG: ${{ inputs.tag }}
          SERVICE: ${{ inputs.service }}
          RUN_MIGRATIONS: ${{ inputs.run_migrations }}
        run: |
          ssh -o StrictHostKeyChecking=accept-new ops@cashtrack-prod-0 \
            "/opt/cashtrack/bin/deploy-service $SERVICE $TAG $RUN_MIGRATIONS"
```

No infra checkout. No Ansible on the runner. No vault access. No PAT. SSH auth is Tailscale SSH, keyless — governed by the tailnet ACL granting `tag:ci` identity SSH to `tag:prod-server` as user `ops`.

### Caller in a service repo (`cash-track/api/.github/workflows/release.yml`)

```yaml
name: Release
on:
  push:
    tags: ['v*.*.*']

jobs:
  ship:
    uses: cash-track/.github/.github/workflows/ship-service.yml@main
    with:
      service: api
      image:   cashtrack/api
      tag:     ${{ github.ref_name }}       # used verbatim as Docker Hub tag
      run_migrations: true
    secrets: inherit
```

Every service repo's release workflow is 9 lines. Only `service`, `image`, and `run_migrations` vary.

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

Rollback is a re-run with an older tag:

```bash
gh workflow run release.yml --repo cash-track/api -f tag=v1.2.8
```

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
  backend "s3" {
    bucket = "cash-track-tfstate"
    key    = "prod/terraform.tfstate"
    region = "us-east-1"
  }
}
```

`terraform/backend.hcl` (not committed; `.gitignore`'d):

```hcl
endpoints = {
  s3 = "https://ams3.digitaloceanspaces.com"
}
access_key                  = "..."
secret_key                  = "..."
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
skip_region_validation      = true
skip_s3_checksum            = true
use_path_style              = true
```

Initialized with `terraform -chdir=terraform init -backend-config=backend.hcl`.

### State locking

DO Spaces does not expose a DynamoDB-equivalent. Approach:

1. **No locking, serialize via CI concurrency group.** `infra` repo workflows running `terraform apply` share `concurrency: group: terraform-prod` so two CI runs cannot collide. Operator discipline handles the single-human case. Spaces versioning is the rollback net.
2. Optional: try Terraform 1.10's `use_lockfile = true`. If DO Spaces supports conditional writes it works; otherwise Terraform errors immediately and falls back to option 1.

### Credentials flow

| Actor | Where |
|---|---|
| Operator | `backend.hcl` on laptop, chmod 600, `.gitignore`'d |
| CI (`infra` repo) | Org secrets `SPACES_TFSTATE_ID/KEY`, written to `backend.hcl` at job start, `shred -u` on cleanup |

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

### Dashboards

Grafana provisioning (`config/grafana/provisioning/`):
- Datasources: Prometheus, Loki, Tempo — auto-wired
- Dashboards: Traefik, api latency, MySQL, Redis, Node, Ofelia jobs — committed as JSON

Accessed via `https://grafana-cashtrack.<tailnet>.ts.net` (Tailscale Serve).

---

## 16. Initial Cutover Plan

### Pre-cutover (any time beforehand)

1. **Create the new Spaces bucket** `cash-track-tfstate` in AMS3 with "Block all public access". Existing `cash-track-storage` (public) and `cash-track-backups` (private) stay as-is. Create one dedicated access key for it.
2. **Set up the 1Password vault** `cash-track-prod`: create items (`api`, `gateway`, `mysql`, `mysql-app-users`, `mysql-backup`, `mysql-exporter`, `alertmanager-telegram`, `grafana`, `telegram-bot`, `cloudflare-origin-cert`, `tailscale`, `dockerhub`, `do-api`) and populate from existing K8s secrets. Create a read-only Service Account scoped to the vault; store its token as `OP_SERVICE_ACCOUNT_TOKEN` org secret.
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

### Minimal command

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

- `mkfs` only runs if `blkid` shows no filesystem label (cloud-init).
- `make replace` blocks if the latest object in `cash-track-backups` is >24h old (`replace-preflight.sh`).
- `prevent_destroy` on `digitalocean_volume.data` and `digitalocean_reserved_ip.main`.

### What to verify after a replace

1. `tailscale status` on the droplet
2. `docker compose ps` all healthy
3. Grafana: MySQL connection count, api p95, Traefik 5xx rate
4. Smoke test externally: `curl https://api.cash-track.app/healthcheck`

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
| Service returns 502 | `ssh ops@cashtrack-prod-0 'docker compose logs --tail=100 <service>'` |
| Droplet unreachable via Tailscale | `make ssh-open IP=$(curl ifconfig.me)` → SSH to public IP |
| MySQL OOM | Check Grafana for memory spikes; consider droplet resize or mysql cnf tuning |
| Full volume | `docker system df` on droplet; Prometheus/Loki retention may need trimming |
| Backups not running | Check Ofelia logs in Loki: `{container="ofelia"}` |

---

## 19. Critique and Residual Risks

### Accepted risks

1. **Single point of failure.** By design, for the cost reduction. RTO 5–8 min is the mitigation.
2. **Redis data loss on restart.** Accepted — CSRF tokens invalidate, users reauth on next mutating request.
3. **Self-observability gap.** Alertmanager co-resident with the services it observes. External Cloudflare/GH Actions health check closes this.
4. **Vertical resize is the only scaling lever.** No horizontal scale without a bigger re-architecture.

### Things to monitor / revisit

1. **MySQL in Docker with host bind-mount** — lower performance than bare-metal or managed. Monitor p95 query latency; revisit if >100ms on simple queries.
2. **Traefik reads the Docker socket.** RCE on Traefik pivots to root. Mitigations: pin version, read-only socket mount, consider `docker-socket-proxy` later.
3. **Tailscale daemon health** is a hard dependency for operator access. If Tailscale on the droplet dies, emergency SSH toggle is the fallback.
4. **DO Spaces state locking** is absent. Concurrency group + operator discipline are the compensation; revisit if collisions ever happen.
5. **GH Actions image pulls from Docker Hub** — subject to Docker Hub rate limits on replacement. Mitigation (future work): authenticated pulls or DO Container Registry.

### Rejected alternatives

- **Managed MySQL / Managed Redis** — overkill for 1GB data; doubles the managed-services cost.
- **SOPS + age or Ansible Vault** instead of 1Password — added tool complexity and no existing subscription leverage; 1Password gives audit log, granular access, and desktop-app ergonomics for free.
- **Push-on-bump with a droplet-side Watchtower** — harder to audit; splits deploy state between GH and droplet.
- **Jinja-templated compose files** — user preference for static compose + `.env`; sacrificing a small amount of DRY for cleaner diffs.
- **Checking out the `infra` repo in service-deploy workflows** — needlessly requires PAT/App; direct SSH to on-droplet deploy script is simpler and matches today's `kubectl set image` shape.

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
2. **Long-term observability archival.** Ship Loki chunks to Spaces with retention beyond 7d, accessed on-demand via a separate Loki instance pointed at Spaces.
3. **GitHub App** replacing any remaining PATs for GitHub API calls (Docker Hub is an org secret, not a PAT, so not relevant; only applies if someday the infra repo needs to be checked out cross-repo).
4. **Docker Socket Proxy** to harden Traefik's access.
5. **Automated monthly Docker Hub rate-limit check** as a GH Actions cron — warn if approaching limits.
6. **HA.** A genuinely HA architecture is a different design: managed MySQL, managed Redis, ≥2 droplets behind a DO LB, shared Spaces-backed file storage for per-request state, and a re-architected observability stack. Not attempted here.

---

## 22. Implementation Sequencing

When this design is approved and work begins, implementation proceeds in these stages, each independently verifiable before moving on:

1. **Stage 0 — Spaces bucket + 1Password vault + baseline.** Create `cash-track-tfstate` (new) and its access key via `scripts/bootstrap-buckets.sh`. Set up the `cash-track-prod` 1Password vault — create all items and migrate values from existing K8s secrets. Create a read-only Service Account scoped to the vault; store the token as `OP_SERVICE_ACCOUNT_TOKEN` GitHub org secret.
2. **Stage 1 — Terraform.** Write modules + `terraform.tfvars`. `terraform plan` produces an actionable plan.
3. **Stage 2 — First provision.** `make apply && make bootstrap` brings up a droplet with core compose stack (traefik, mysql empty, redis, ofelia). Verify via Tailscale.
4. **Stage 3 — App services.** Bring up api, gateway, frontend, website, mysql-backup, mysql-exporter. Restore from a K8s MySQL backup. Internal smoke test with `curl --resolve`.
5. **Stage 4 — Observability.** Bring up prometheus, node-exporter, grafana, loki, tempo, promtail, alertmanager. Import dashboards. Verify alerts flow to Telegram (intentionally fire a test alert via `amtool alert add`).
6. **Stage 5 — Telegram bot.** Bring up tg-bot with its Ofelia schedules.
7. **Stage 6 — CI/CD.** Create `cash-track/.github` repo with reusable workflows; update service repos' `release.yml`. Test a deploy to the droplet from a tag push in a scratch branch.
8. **Stage 7 — Cutover.** Run the Section 16 runbook.
9. **Stage 8 — Decommission.** After 48h observation, tear down DOKS.

Each stage produces a reviewable `git push` to the `infra` repo and a verifiable outcome in the droplet's state.
