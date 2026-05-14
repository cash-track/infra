# Cash-Track Infrastructure — Docker Compose on DigitalOcean

---

## 1. Design Rationale

Cash-Track runs on a single DigitalOcean droplet (`s-4vcpu-8gb`, AMS3) running Docker Compose, fronted by Traefik. Persistent state lives on an attached Block Volume; a Reserved IP insulates Cloudflare DNS from droplet lifecycle events. Total cost is ~$50/month.

### Explicit trade-off accepted

Single-droplet = single point of failure. RTO ≈ 5–8 minutes for an automated replacement (Block Volume + Reserved IP survive; droplet is recreated by Terraform). HA is future work (Section 19).

---

## 2. Architecture

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
                  • cash-track-backups  (private — MySQL dumps)
                  • cash-track-tfstate  (private — Terraform state)

                1Password (cash-track-prod vault)
                  • all secrets (API, DB, TLS cert, Tailscale, Telegram, …)
```

### Services on the droplet

Four Docker Compose files composed together:

| Compose file | Services |
|---|---|
| `compose.core.yml` | traefik, mysql, redis, ofelia |
| `compose.app.yml` | api, gateway, frontend, website, mysql-backup, mysql-exporter |
| `compose.obs.yml` | prometheus, node-exporter, grafana, loki, tempo, promtail, alertmanager |
| `compose.telegram.yml` | crashers-bot, home-exporter |

Replica count is 1 for all services (no HA benefit on a single host). Traefik's retry middleware absorbs the brief restart window.

### MySQL tenant model

A single MySQL server hosts multiple databases. Each application service has its own dedicated MySQL user scoped only to its database(s). `mysql-init` creates each database and grants privileges idempotently. A compromised service cannot read or write any other service's data.

| Database       | Used by      | Vault item           |
|----------------|--------------|----------------------|
| `cashtrack`    | api          | `mysql`              |
| `crashers_bot` | crashers-bot | `crashers-bot-mysql` |
| `potwora`      | potwora      | `potwora-mysql`      |

Root credentials are used only by initial provisioning, `mysql-backup`, and `mysql-init` itself.

### Monthly cost

| Item | Cost |
|---|---|
| Droplet `s-4vcpu-8gb` | $48 |
| Block Volume 25 GB | $2.50 |
| Reserved IP (attached) | $0 |
| DO Firewall | $0 |
| Spaces (3 buckets) | ~unchanged |
| **Total** | **~$50/mo** |

---

## 3. Repository Layout

```
./infra/
├── README.md                      # operational runbook
├── Makefile
├── terraform/
│   ├── backend.tf
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
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventory/prod/
│   │   └── terraform.sh           # reads `terraform output -json`, emits Ansible JSON
│   ├── group_vars/all/main.yml    # non-secret vars; op:// refs in env templates
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
├── compose/
│   ├── compose.core.yml
│   ├── compose.app.yml
│   ├── compose.obs.yml
│   ├── compose.telegram.yml
│   └── config/
│       ├── traefik/
│       ├── prometheus/
│       ├── loki/
│       ├── tempo/
│       ├── grafana/provisioning/{datasources,dashboards}/
│       ├── alertmanager/
│       └── promtail/
│
├── scripts/
│   ├── replace-preflight.sh
│   ├── restore-to-new-volume.sh
│   └── bootstrap-buckets.sh
│
└── .gitignore
```

---

## 4. Configuration Surface

### Terraform (`terraform/terraform.tfvars`)

Key variables: `region=ams3`, `droplet_size=s-4vcpu-8gb`, `droplet_image=ubuntu-24-04-x64`, `volume_size_gb=25`. The `enable_cloudflare_dns` flag controls whether Terraform manages Cloudflare A records.

### Ansible (`ansible/group_vars/all/main.yml`)

Stores Docker Hub image tags for each service (used verbatim — no `v` stripping), observability retention periods (`prometheus: 7d`, `loki: 168h`, `tempo: 72h`), and the MySQL backup schedule (`03:00 UTC daily`).

---

## 5. Sizing & Retention

### Disk on the Block Volume (target ~20 GB used of 25 GB provisioned)

| Component | Expected | Cap enforced by |
|---|---|---|
| MySQL data (+headroom) | 5 GB | app schema + quarterly review |
| Prometheus 7d retention | 4 GB | `--storage.tsdb.retention.size=3GB` + `time=7d` |
| Loki 7d retention | 5 GB | `retention_period=168h` + ingestion rate caps |
| Tempo 3d retention | 3 GB | `compactor.compaction.block_retention=72h` |
| Grafana + Alertmanager | 1 GB | bounded by config size |
| Headroom | ~2 GB | — |
| **Total** | **~20 GB** | — |

Redis data is not persisted (accepted data loss on reboot); CSRF tokens invalidate on restart and users reauth on the next mutating request. Redis is capped at `maxmemory 250mb` with `allkeys-lru` eviction.

**Budgets are caps, not aspirations.** Every retention and rate limit above is wired into the service config. A cardinality spike on Prometheus or a log-verbose deploy on Loki drops data at the ingestion boundary rather than silently eating disk.

**Block Volume IOPS are flat, not per-GB.** DO caps per volume at 5,000 write / 7,500 read IOPS / ~300 MB/s regardless of size. "Resize the volume" only buys capacity. If sustained I/O saturation appears, the lever is tuning or splitting observability to a second storage tier (future work, Section 19).

### Filesystem mount flags

`/mnt/data` mounts with `defaults,nofail,noatime,nodiratime,discard`. `noatime` removes the metadata write on every read — a cheap win on a read-heavy workload.

### MySQL I/O tuning (baked into `cashtrack/mysql` image `my.cnf`)

Defaults tuned for network-attached SSD: `innodb_flush_log_at_trx_commit=2` (fsync per second, not per commit), `innodb_flush_method=O_DIRECT` (bypasses OS page cache double-buffering), `innodb_io_capacity=2000/4000` (tells InnoDB the disk is fast), `innodb_buffer_pool_size=512M`.

### Memory on the droplet (8 GB total, ~2.25 GB headroom)

All services have `mem_limit` / `mem_reservation` enforced in compose. A runaway service hits its cgroup limit, is OOM-killed at container scope, and restarted by Docker's `unless-stopped` policy. Host-level OOM is avoided by `oom_score_adj` bias: MySQL at `-500` (last to die), Loki/Tempo at `+500` (first).

| Service | `mem_limit` | `oom_score_adj` |
|---|---|---|
| api | 768m | -200 |
| gateway | 128m | -200 |
| frontend | 128m | -100 |
| website (Nuxt SSR) | 640m | -100 |
| mysql | 896m | **-500** |
| redis | 320m | -200 |
| traefik | 128m | -300 |
| prometheus | 640m | +300 |
| grafana | 256m | +300 |
| loki | 640m | +500 |
| tempo | 640m | +500 |
| alertmanager | 128m | +300 |
| promtail | 128m | +300 |
| node-exporter + mysql-exporter + ofelia | 192m | 0 |
| crashers-bot | 320m | -100 |
| home-exporter | 128m | 0 |
| OS + Docker overhead | ~600m | — |
| **Headroom** | **~2 250m** | — |

**Swap policy.** A 1 GB swapfile lives on the **droplet root disk** (local SSD), not on the Block Volume. Swap on network-attached storage turns memory pressure into thrashing — every anon-page swap-in competes with MySQL fsyncs on the same network device. `vm.swappiness=10` biases the kernel toward evicting page cache before anon pages.

**Memory pressure alerting.** PSI (`node_pressure_memory_waiting_seconds_total`) fires when sustained memory pressure exceeds 10% for 2 minutes — before OOM, not after.

### Resize trigger

If sustained memory usage exceeds 6.5 GB or PSI stays non-zero for hours, resize to `s-4vcpu-16gb` ($96/mo) via `terraform apply`. $48/mo for another 8 GB of RAM is cheaper than any memory-engineering alternative.

---

## 6. First-Boot Flow

Terraform creates droplet → cloud-init joins Tailscale + installs Docker → Ansible takes over. Zero public-SSH exposure at any point.

### Cloud-init responsibilities (minimal by design)

Only what must happen before Ansible can SSH via Tailscale:

- Install Tailscale, run `tailscale up --ssh` to join the tailnet.
- Install Docker CE + Compose plugin.
- Mount the Block Volume at `/mnt/data` — **re-entrant**: `mkfs.ext4` only runs if no filesystem label exists. On droplet replacement with the same volume, the existing filesystem is preserved. The guard uses a filesystem label check (`cashtrack-data`), not a device path, to survive device-path changes and refuse silent reformats of mis-attached volumes.
- Write `/var/lib/bootstrap-ready` sentinel for Ansible's `wait_for` task.

The Tailscale auth key is minted by Terraform at `apply` time (single-use, tagged). Tailscale SSH is the primary access path; the `ops` SSH key is a fallback.

### Failure modes and recovery

| Failure | Recovery |
|---|---|
| Cloud-init fails mid-way | `make ssh-open IP=$(curl ifconfig.me)` → SSH to public IP → inspect `/var/log/cloud-init-output.log` → `make ssh-close` |
| Block Volume not attached within 90s | Cloud-init aborts before touching `mkfs` — check DO console, fix, re-run cloud-init |
| Volume has filesystem but not label `cashtrack-data` | Guard aborts; manual intervention required (intentional) |
| Tailscale auth key expired before use | Re-run `terraform apply` (provider rotates the key) |

---

## 7. Ansible Bootstrap

### `site.yml` — idempotent full-droplet configuration

Runs on every `ansible-playbook site.yml` invocation. Roles in order:

```yaml
roles:
  - base          # unattended-upgrades + 04:00 UTC reboot window, swapfile, sysctls, PSI
  - docker        # daemon.json with log rotation + json-file size caps
  - firewall-refresh  # CF IP list → DO Cloud Firewall
  - volume        # verifies /mnt/data mount, creates directory skeleton
  - mysql-init    # creates DBs + users idempotently
  - compose-render    # renders .env files via `op inject`, uploads static compose files
  - compose-up    # `docker compose up -d --remove-orphans`
```

All roles are tagged for partial reruns: `ansible-playbook site.yml --tags mysql,compose`.

### `base` role — OS-level hardening and maintenance policy

- **Timezone** pinned to `UTC` (chrony for NTP).
- **Swapfile** — 1 GB at `/swapfile` on root disk, `vm.swappiness=10`.
- **`vm.overcommit_memory=1`** — matches Redis's recommended host config.
- **PSI exposure** — `psi=1` kernel cmdline; node-exporter picks up `/proc/pressure/*`.
- **Unattended-upgrades** with `Automatic-Reboot "true"` at `04:00 UTC`. Deliberate: stock Ubuntu ships `Automatic-Reboot "false"`, meaning a kernel patch installs but the vulnerable kernel keeps running indefinitely. The 04:00 window fires only when `/var/run/reboot-required` is set — expected cadence is a handful per year, each ≈60–180s of downtime.
- **`needrestart`** restarts services automatically after library updates without waiting for an interactive prompt.
- **Post-reboot smoke check** — a `@reboot` systemd oneshot runs `docker compose ps` and curls local health endpoints; failures bump a node-exporter textfile metric `cashtrack_postreboot_check_ok` monitored by Alertmanager.

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
│   ├── traefik/{traefik.yml, dynamic.yml, *.pem}
│   ├── prometheus/prometheus.yml
│   ├── loki/loki.yml
│   ├── tempo/tempo.yml
│   ├── grafana/provisioning/
│   ├── alertmanager/alertmanager.yml
│   └── promtail/promtail.yml
├── bin/
│   └── deploy-service
└── /mnt/data/        # ── Block Volume ──
    ├── mysql/
    ├── prometheus/
    ├── loki/
    ├── tempo/
    ├── grafana/
    └── alertmanager/
```

---

## 8. Docker Compose — Design

Compose files are **static** — no Jinja templating inside them. Variables flow via `${VAR}` substitution from `.env` or per-service `env_file`. Jinja is only used in Ansible templates for per-service configs (e.g., `prometheus.yml.j2`).

Key design decisions applied uniformly across all services:

- Every service has `restart: unless-stopped`, `mem_limit`, `mem_reservation`, and `oom_score_adj`.
- All services share a single Docker bridge network (`cashtrack-app`).
- Services needing MySQL declare `depends_on: mysql: { condition: service_healthy }` via a `mysqladmin ping` healthcheck.
- Traefik routing is declared as labels on each service — no separate router config files for app routes.
- Observability services carry hard retention and rate caps at the process level, not just as documentation.

### Traefik

Listens on `:80` (redirects to HTTPS) and `:443`. Uses the Docker provider (labels) for app routes and the file provider for TLS certificates and shared middlewares. Two middlewares:

- `retry` — 3 attempts with 100ms initial interval; applied to all app routers.
- `cloudflare-only` — IP allowlist of CF ranges; applied to all external routers as defense-in-depth behind the DO Firewall.

TLS certificates are Cloudflare Origin Certificates — one per zone (`cash-track.app`, `potwora.com.ua`), rendered onto the droplet from 1Password attachments by the `compose-render` role. Traefik selects the correct cert per request by SNI matching.

### Scheduled jobs (Ofelia)

`ofelia` runs as a sidecar with Docker socket access. Schedules are declared as labels on the target service container — visible in compose files, diffable in PRs, logged to Loki via Promtail. Ofelia exposes `ofelia_job_failures_total` scraped by Prometheus; failures flow through Alertmanager → Telegram.

---

## 9. Adding a New Service

Example: a WordPress site sharing MySQL, served at `blog.cash-track.app`.

1. Add an entry to `ansible/roles/mysql-init/vars/databases.yml` with the new database name and 1Password `op://` refs for its dedicated MySQL user credentials.
2. Create vault items in 1Password — one for app secrets, one for the dedicated MySQL user.
3. Add a per-service env template `ansible/roles/compose-render/templates/<service>.env.tpl` with `op://` references.
4. Register the template in `ansible/roles/compose-render/defaults/main.yml` under `secret_files`.
5. Create `compose/compose.<service>.yml` with Traefik labels pointing to the Reserved IP domain.
6. Register the compose file in `ansible/group_vars/all/main.yml` (`compose_files` list).
7. Commit and push — `ansible-apply.yml` triggers, runs `site.yml --tags mysql,compose`. `mysql-init` creates DB+user idempotently; `compose-up` picks up the new stack.
8. Add the DNS record in Cloudflare pointing to the Reserved IP.

No image rebuilds, no downtime for existing services.

---

## 10. Secrets Management

Secrets live in **1Password**, fetched at render time via the `op` CLI on the control node (operator laptop or CI runner). Plaintext never lands in git, Spaces, or the droplet filesystem outside the target `.env` file.

### Why 1Password over Ansible Vault + Spaces

Existing paid subscription, built-in per-item audit log, granular access via 1Password groups, no custom wrapper scripts, desktop-app ergonomics, simpler onboarding.

Accepted trade-offs:

- **CI deploys are hard-linked to 1Password API uptime.** During a 1P API outage, CI cannot render secrets. The 1Password desktop app's local cache means an operator who was recently signed in can still run `ansible-playbook site.yml` locally — converting "unbounded CI RTO" into "operator runs a manual apply."
- **Service Account token is the single most valuable credential.** Mitigated by vault-read-only scope + quarterly rotation.

Residual risk: joint outage (droplet gone + 1P API down + operator cache cold) → unbounded RTO. Flagged in Section 17. Break-glass: encrypted `.env` snapshot in the tfstate bucket (future work, Section 19).

### Vault layout (`cash-track-prod` 1Password vault)

```
cash-track-prod/
├── api                 JWT_SECRET, JWT_PUBLIC_KEY, JWT_PRIVATE_KEY, ENCRYPTER_KEY, DB_ENCRYPTER_KEY
├── common              CAPTCHA_*, GOOGLE_API_*, MAIL_*, S3_*  (consumed by 2+ services)
├── mysql               MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD, MYSQL_ROOT_PASSWORD
├── mysql-exporter      DATA_SOURCE_NAME
├── alertmanager-telegram   BOT_TOKEN, CHAT_ID
├── grafana             ADMIN_PASSWORD, SMTP_PASSWORD
├── crashers-bot        BOT_TOKEN, ...
├── home-exporter       ...
├── cloudflare-origin-cert          origin-cert.pem, origin-key.pem  (cash-track.app zone)
├── cloudflare-origin-cert-potwora  origin-cert.pem, origin-key.pem  (potwora.com.ua zone)
├── tailscale           API_KEY
├── dockerhub           USERNAME, TOKEN
├── do-api              TOKEN
└── cash-track-tfstate  ACCESS_KEY_ID, SECRET_ACCESS_KEY
```

Dedup rules: `common` holds every secret consumed by 2+ services — one rotation point. `gateway` has no vault item (only needs `CAPTCHA_SECRET_KEY` from `common`). `mysql-backup` pulls from `mysql` and `common`. Each service has a dedicated MySQL user.

### Render flow

1. Ansible (on the control node) renders Jinja templates into `.env.tpl` files with `op://` URI references.
2. `op inject` replaces `op://` references with plaintext values.
3. Ansible copies rendered `.env` to `/opt/cashtrack/secrets/<service>.env` (mode 0600).
4. Local renders are wiped immediately after upload.
5. The `copy` task reports `changed: true` only when content differs — triggering a per-service restart handler for only the affected service. Editing one secret in 1Password restarts only that service.

The droplet never holds an `op` CLI and never sees the Service Account token.

### Secret rotation

Edit the field in 1Password → trigger `gh workflow run ansible-apply.yml --repo cash-track/infra -f tags=compose`. CI renders, ships, and restarts only the affected service. ~30 seconds end-to-end.

The `OP_SERVICE_ACCOUNT_TOKEN` is rotated quarterly via the 1Password admin console + update the GitHub org secret.

---

## 11. CI/CD

### Repo topology

| Repo | Workflows |
|---|---|
| `cash-track/.github` | Reusable: `build.yml` (image build+push), `deploy.yml` (tailnet SSH deploy), `ansible-apply.yml`, quality checks |
| `infra` | `ansible-apply.yml` (triggers on `ansible/**`, `compose/**`, `terraform/**`), `replace-droplet.yml`, `bootstrap.yml` |
| Each service repo | `quality.yml`, `build.yml` (workflow_dispatch), `deploy.yml` (workflow_dispatch rollback), `release.yml` (tag push → build → deploy) |
| `crashers-bot`, `home-exporter` | Outside the org; images bumped by hand in `group_vars/all/main.yml` |

### Release pipeline

Tag push (`v*.*.*`) on a service repo chains `build.yml` → `deploy.yml`:

- `build.yml` builds and pushes the image, strips the `v` prefix from the git tag (image pushed as `1.2.9` not `v1.2.9`), outputs the resolved version.
- `deploy.yml` joins the tailnet via `tailscale/github-action`, SSHes to `cashtrack-prod-0` as `ops`, and calls `/opt/cashtrack/bin/deploy-service <service> <tag> <run_migrations>`.

The pipeline is split into two reusables so rollback (`deploy.yml` with an older tag) doesn't force a rebuild.

### On-droplet deploy script

`/opt/cashtrack/bin/deploy-service` (installed by Ansible) updates the `VERSION_<SERVICE>` variable in `.env`, runs `docker compose pull <service>`, optionally runs API migrations, then `docker compose up -d --no-deps <service>`. No Ansible, no vault access on the runner side.

### Rollback

```bash
gh workflow run deploy.yml --repo cash-track/api -f tag=1.2.8
```

For infra rollbacks, `git revert` + push triggers `ansible-apply.yml` automatically.

### Key org secrets

| Secret | Used by | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | all service repos | Docker Hub push |
| `TS_AUTH_KEY` | all service repos + infra | Tailscale ephemeral node auth (rotate every 90 days) |
| `OP_SERVICE_ACCOUNT_TOKEN` | infra only | 1Password read access for `op inject` |
| `SPACES_TFSTATE_ID`, `SPACES_TFSTATE_KEY` | infra only | Terraform state access |

---

## 12. Terraform State

### Spaces buckets

All three buckets in **AMS3**, co-located with the droplet to eliminate cross-region egress.

| Bucket | Visibility | Contents | Versioning |
|---|---|---|---|
| `cash-track-storage` | public | User avatars, static assets | as today |
| `cash-track-backups` | private | MySQL dumps | as today |
| `cash-track-tfstate` | private, block all public access | `prod/terraform.tfstate` | on, 90-day noncurrent retention |

Three separate access keypairs for blast-radius isolation.

### Backend and state locking

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

`backend.hcl` (not committed) holds the Spaces endpoint and access credentials, rendered by the operator from 1Password. Two locking layers: native `use_lockfile` conditional-write locking (primary), and a CI `concurrency: group: terraform-prod` guard (belt-and-braces).

Local `terraform apply` is break-glass only — day-to-day changes go through CI.

### Critical resource protection

```hcl
resource "digitalocean_volume" "data" {
  lifecycle { prevent_destroy = true }
}

resource "digitalocean_reserved_ip" "main" {
  lifecycle { prevent_destroy = true }
}
```

The droplet has no `prevent_destroy` — it's disposable by design.

---

## 13. Network Security

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
make ssh-open IP=$(curl -s ifconfig.me)   # adds TCP 22 rule for specific IP
make ssh-close                            # removes it
```

Tailscale SSH is the normal access path; public SSH is only toggled during incidents where Tailscale is unavailable.

### Tailscale ACLs

- `tag:cashtrack-prod` — the droplet
- `tag:ci` — ephemeral GitHub Actions runners; can SSH to `tag:cashtrack-prod` as `deploy`
- `tag:cashtrack-devops` - priveledged ephemeral GitHub Actions runners; can SSH to `tag:cashtrack-prod` as `ops`
- `tag:ct-dev` — operators; full SSH + Grafana/Prometheus/Alertmanager/MySql/Redis access

Grafana and internal dashboards are exposed via `tailscale serve`, reachable only on the tailnet.

### Defense in depth

Traefik's `cloudflare-only` IP allowlist middleware is applied to all external routers. If the DO Firewall's CF IP list ever lags behind a CF range update, Traefik still rejects non-CF source IPs.

---

## 14. Observability

### Retention — 7-day operational window

| Component | Retention | Disk target |
|---|---|---|
| Prometheus | 7d | 4 GB |
| Loki | 168h (7d) | 5 GB |
| Tempo | 72h (3d) | 3 GB |

All caps are enforced at the process level so a log-verbose deploy or cardinality spike drops data at ingestion rather than silently filling the volume.

### Scrape and log targets

- **Prometheus** scrapes services over the `cashtrack-app` network via Docker SD labels.
- **Node Exporter** on the host, scraped by Prometheus.
- **Promtail** uses Docker SD — reads container stdout via the Docker socket, tags with container name.
- **Tempo** ingests OTLP traces via gRPC (`:4317`) from api, gateway, and website.

### Alerting — two layers

1. **Internal (Alertmanager → Telegram):** "something on the droplet is unhealthy". Co-resident with observed services; dies with the droplet.
2. **External (DigitalOcean Uptime → Email):** "API is down". Polls `https://api.cash-track.app/healthcheck` every 1 minute, alerts on 3 consecutive failures.

### Key alert rules

- **HostMemoryPressure** — PSI `rate > 0.10` for 2 min; early OOM warning.
- **HostRebootRequired** — `node_reboot_required == 1` for 7d; fires if the 04:00 window didn't run.
- **MySQLBackupStale** — backup age > 6h; fires before the `make replace` preflight would block an incident.
- **BlockVolumeIOPSSaturated** — disk IO utilization > 80% for 15 min; monitor for Block Volume contention (see Section 17).

The `mysql_backup_last_success_timestamp_seconds` metric is emitted by the backup container via a Prometheus textfile collector entry picked up by node-exporter. Same source feeds `replace-preflight.sh`.

### Dashboards

Grafana provisioning auto-wires Prometheus, Loki, and Tempo as datasources. Dashboards for Traefik, api latency, MySQL, Redis, Node, and Ofelia jobs are committed as JSON. Accessed via Tailscale Serve at `https://grafana-cashtrack.<tailnet>.ts.net`.

---

## 15. Droplet Replacement (DR) Runbook

### Triage — escalate to replace, don't start there

1. **Service-level** (most common) — `docker compose logs` + `docker compose restart <service>`. Recovery: 10–30s.
2. **Docker daemon-level** — `sudo systemctl restart docker && docker compose up -d`. Recovery: 30–60s.
3. **OS-level, droplet reachable** — `doctl compute droplet-action power-cycle <id>`. Recovery: 60–120s.
4. **Droplet gone or unrecoverable** — only now: `make replace`.

### Block Volume corruption — a different runbook

**`make replace` does not help if the Block Volume itself is corrupt.** It destroys the droplet and reattaches the same volume. Symptoms: mount fails in cloud-init, fsck errors, MySQL refuses to start.

Separate procedure: provision a new Block Volume + snapshot the old one (forensics), restore the latest MySQL backup from Spaces into the new volume, swap the Terraform volume resource reference, then `terraform apply`. RPO for this path = age of the last successful backup.

### Droplet replacement

```bash
make replace
```

Runs: backup freshness check (`replace-preflight.sh`) → `terraform apply -replace=digitalocean_droplet.host[0]` → `ansible-playbook site.yml`.

### Replacement sequence

| # | Step | Duration |
|---|---|---|
| 1 | TF destroys old droplet | ~30s |
| 2 | TF detaches Reserved IP and Block Volume | ~10s |
| 3 | TF creates new droplet with identical cloud-init | ~30s |
| 4 | TF reattaches Block Volume + Reserved IP | ~20s |
| 5 | Cloud-init: Tailscale up, Docker install, `mkfs` guard preserves FS, mount | ~60–90s |
| 6 | Ansible `site.yml` over tailnet: render configs, `docker compose up -d` | ~2–4 min |
| 7 | Traefik routes to restarted containers with existing MySQL data | — |

**Total RTO: 5–8 minutes.** Cloudflare DNS never changes. RPO: MySQL zero (same volume), Redis lost (accepted), Observability zero (same volume).

### Guards

- `mkfs` only runs if filesystem label `cashtrack-data` is absent — existing data survives replacement.
- `make replace` blocks if the latest object in `cash-track-backups` is >24h old. Override via `FORCE_REPLACE_REASON="inc-<id>: <reason>"` — preflight logs the override to S3 and posts to Telegram before proceeding. Empty reason is not accepted.
- `prevent_destroy` on the Block Volume and Reserved IP.

### Post-replace verification

1. `tailscale status` on the droplet
2. `docker compose ps` all healthy
3. `cashtrack_postreboot_check_ok == 1`
4. Grafana: MySQL connections, api p95, Traefik 5xx rate
5. `curl https://api.cash-track.app/healthcheck`

---

## 16. Day-2 Operations

### Daily (passive)

- Ofelia runs `mysql-backup` at 03:00 UTC, uploads to `cash-track-backups`.
- Alertmanager delivers firing alerts to Telegram.
- Prometheus drops >7d data automatically.

### Weekly (recommended)

`make backup-verify` — pulls the latest dump from Spaces, restores into a throwaway container, runs row-count SELECTs, discards.

### Monthly

- Review droplet RAM/CPU in Grafana. Resize if sustained >80%.
- Prune old Docker images: `docker system prune -af --filter until=168h`.

### OS or droplet size upgrade

Edit `terraform/terraform.tfvars` (`droplet_size`, `droplet_image`) then `make apply`. Same replacement mechanics as `make replace`. RTO ~5–8 min.

### Common failure responses

| Symptom | First action |
|---|---|
| Service returns 502 | `docker compose logs --tail=200 <service>`; restart if isolated |
| Droplet unreachable via Tailscale | `make ssh-open IP=$(curl ifconfig.me)` → SSH to public IP |
| Container cgroup-OOM | Expected — Docker restarts it. Repeated: raise `mem_limit` or investigate allocation pattern. |
| Host-level OOM / PSI alert sustained | MySQL protected by `oom_score_adj`; expect Loki/Tempo to die first. Review Grafana memory panel; resize if PSI >5% for hours. |
| Full volume | `docker system df`; verify retention caps are in effect; `docker system prune -af --filter until=168h` |
| Backups not running | `MySQLBackupStale` should have fired; check Ofelia logs in Loki: `{container="ofelia"}` |
| Reboot-required alert | Patch installed, 04:00 window pending. Wait, or `sudo reboot` manually — post-reboot smoke check validates recovery. |

---

## 17. Critique and Residual Risks

### Accepted risks

1. **Single point of failure.** By design. RTO 5–8 min.
2. **Redis data loss on restart.** CSRF tokens invalidate; users reauth on next mutating request.
3. **Self-observability gap.** Alertmanager co-resident with observed services. External health check closes this.
4. **Vertical resize is the only scaling lever.** No horizontal scale without re-architecture.
5. **Scheduled maintenance-window reboots.** ~60–180s outages a handful of times per year for kernel/library patches. Accepted over running a vulnerable kernel.
6. **Joint 1Password + droplet outage → unbounded CI-path RTO.** Operator-laptop path survives via the 1P desktop cache. Break-glass: `ansible-playbook site.yml` locally.

### Things to monitor / revisit

1. **MySQL in Docker with host bind-mount** — monitor p95 query latency; revisit if >100ms on simple queries.
2. **Traefik reads the Docker socket** — RCE on Traefik pivots to root. Consider `docker-socket-proxy`.
3. **Tailscale daemon health** — hard dependency for operator access; emergency SSH toggle is the fallback.
4. **Terraform state locking** — native `use_lockfile` via DO Spaces S3 conditional writes. Monitor for lockfile errors; fall back to concurrency-group-only if provider misbehaves.
5. **Block Volume I/O contention** — MySQL, Prometheus, Loki, Tempo share one volume. DO's IOPS cap is flat. Monitor via `BlockVolumeIOPSSaturated`; escalate to storage split (Section 19) only after sustained saturation post-tuning.
6. **Docker Hub rate limits on replacement** — future work: authenticated pulls or DO Container Registry.

### Rejected alternatives

- **Managed MySQL / Managed Redis** — overkill for 1 GB data; doubles managed-service cost.
- **SOPS + age or Ansible Vault** — added tool complexity; 1Password gives audit log and granular access for free.
- **Watchtower** — harder to audit; splits deploy state between GH and droplet.
- **Jinja-templated compose files** — prefer static compose + `.env` for cleaner diffs.
- **GitLab HTTP backend for Terraform state** — external dependency on an unrelated platform; native `use_lockfile` closes the gap.
- **Ubuntu Pro + Livepatch** — Canonical-account dependency for one droplet; scheduled reboot window covers the same posture.
- **Swap on Block Volume** — network-attached storage turns memory pressure into thrashing.
- **Larger Block Volume for IOPS** — DO's cap is flat regardless of size.

---

## 18. Out of Scope

- Local development environment (`dev-cash-track.app`) — unchanged; stays on developer laptops.
- Rewriting application code. All services run their published Docker Hub images.
- A second production environment (staging). If introduced later, a second Terraform workspace is the pattern.
- Redis persistence. Accepted data loss.

---

## 19. Future Work

1. **Multi-droplet scaling.** Stateful services (MySQL, Loki, etc.) must stay on droplet[0] (Block Volume + Reserved IP). Scaling stateless services requires rethinking Traefik placement, session affinity, and shared storage (Spaces).
2. **Split storage tier for observability.** Trigger: `BlockVolumeIOPSSaturated` sustained after MySQL tuning and retention caps are already in place. Move observability bind-mounts to local SSD; pair with `remote_write` to Grafana Cloud's free tier so DR events don't lose observability history.
3. **Long-term observability archival.** Ship Loki chunks to Spaces with retention beyond 7d.
4. **Encrypted `.env` snapshot in tfstate bucket.** Mitigates joint 1P-outage + droplet-outage tail (Section 17 accepted risk 6). Re-rendered after any vault edit; decrypted with an age key held by the operator.
5. **Docker Socket Proxy** to harden Traefik's access to the Docker API.
6. **Automated Docker Hub rate-limit check** as a monthly GH Actions cron.
7. **HA.** Genuinely HA architecture requires managed MySQL, managed Redis, ≥2 droplets behind a DO LB, and shared Spaces-backed state. Not attempted here.
