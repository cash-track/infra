# Kubernetes → Docker Compose Migration: Implementation Plan

> **For agentic workers:** Execute one stage per Claude Code session. Each stage is sized to fit a single context window and produces a reviewable commit. Stages marked **[OPERATOR-ONLY]** must be executed by a human; Claude Code is forbidden from touching secret material or running `op`, `doctl`, `terraform apply`, `ansible-playbook`, or DO/1Password/GitHub admin consoles for secret tasks.

**Goal:** Replace the DOKS cluster with a single-droplet Docker Compose stack per the 2026-04-21 design doc.

**Source of truth:** `./infra/migration/2026-04-21-kubernetes-to-docker-compose-design.md`. Every file's concrete content lives in the numbered sections there. This plan sequences the work; the spec supplies the bodies.

**Tech stack:** Terraform (DO provider), Ansible (community.docker, community.digitalocean), Docker Compose v2, Traefik v3, cashtrack/mysql + cashtrack/redis images, Prometheus + Loki + Tempo + Grafana + Alertmanager, Ofelia, Tailscale, 1Password Service Accounts.

**Secret-handling rule (non-negotiable):**
- Claude Code **writes** templates (`*.env.tpl` with `op://` references), workflows, scripts.
- Claude Code **never** runs `op`, reads a secret value, or receives a token/key/password in any form — not in environment variables, not in files, not in command arguments.
- Every secret value (MySQL root password, JWT secret, DO API token, Service Account token, Cloudflare origin cert PEM, etc.) is entered into 1Password / GitHub org secrets / `backend.hcl` **by the operator, via copy-paste from trusted sources**.
- Any stage that involves "set this secret" or "run `op`/`doctl`/`terraform apply`" is flagged **[OPERATOR-ONLY]**. Claude Code hands off, waits for a "done" signal, then resumes.

---

## Stage Summary

| # | Stage | Who | Context-window fit | Produces |
|---|---|---|---|---|
| 0 | Prerequisites: Spaces bucket, 1Password vault, org secrets | **[OPERATOR-ONLY]** | N/A | tfstate Spaces bucket, 11 vault items, 7 org secrets |
| 1 | Repo scaffold + Terraform code | [CLAUDE CODE] | 1 session | `terraform/**`, Makefile, `.gitignore`, README rename |
| 2 | Terraform init + plan review | **[OPERATOR-ONLY]** | N/A | `terraform plan` output, committed plan-review notes |
| 3 | Ansible scaffold + base/docker/tailscale/volume roles | [CLAUDE CODE] | 1 session | `ansible/` with 4 roles |
| 4 | Compose files + per-service configs + env templates | [CLAUDE CODE] | 1 session | `compose/*.yml`, `compose/config/**`, `*.env.tpl` files |
| 5 | Ansible mysql-init + compose-render + compose-up + ops playbooks | [CLAUDE CODE] | 1 session | 3 more roles, 4 ops playbooks, handlers |
| 6 | Helper scripts + top-level Makefile targets | [CLAUDE CODE] | 1 session | `scripts/**`, Makefile targets |
| 7 | First provision: `make apply && make bootstrap` | **[OPERATOR-ONLY]** | N/A | Running droplet with core stack (traefik/mysql/redis/ofelia) |
| 8 | Restore MySQL backup + app-service smoke test | **[OPERATOR-ONLY]** | N/A | api/gateway/frontend/website/mysql-backup/mysql-exporter up, healthchecks green |
| 9 | Observability stack: dashboards, rules, Alertmanager config | [CLAUDE CODE] | 1 session | Grafana provisioning, Prometheus rules copied from `./infra/services/`, Alertmanager routes |
| 10 | Telegram-namespace apps (crashers-bot, home-exporter) + Ofelia schedules | [CLAUDE CODE] | 1 session | `compose.telegram.yml`, two env templates, Ofelia labels |
| 11 | `cash-track/.github` reusable workflows | [CLAUDE CODE] + **[OPERATOR-ONLY]** repo creation + Tailscale ACL edit | 1 session | `ship-service.yml`, `ansible-apply.yml`, quality workflows |
| 12 | Service-repo `release.yml` updates (api, gateway, frontend, website) | [CLAUDE CODE] | 1 session | 4 release workflows calling org reusable. crashers-bot / home-exporter live outside the cash-track org and are out of scope. |
| 13 | Disable old K8s workflows (step 1: `workflow_dispatch`) | [CLAUDE CODE] | 1 session | Modified `deploy*.yml` triggers |
| 14 | Cutover window (Section 16) | **[OPERATOR-ONLY]** | N/A | DNS flipped, K8s writers at 0 replicas |
| 15 | 48h observation + decommission: tear down DOKS, move workflows to `workflows.disabled/`, rewrite README | **[OPERATOR-ONLY]** + [CLAUDE CODE] for README | 1 session | K8s deleted, new `README.md`, `README-kubernetes.md` |

---

## Stage 0 — Prerequisites (OPERATOR-ONLY)

**Goal:** Stand up the external systems Claude Code cannot touch: Spaces bucket for Terraform state, 1Password vault, GitHub org secrets.

**This stage blocks everything else.** No code can be written against a vault that doesn't exist, and `terraform init` cannot run against a missing bucket.

### Action items

1. **Create `cash-track-tfstate` Spaces bucket.**
   - Region: `ams3`.
   - Visibility: private, "Block all public access".
   - Versioning: enabled, 90-day noncurrent retention.
   - Generate a dedicated access key pair (do NOT reuse `cash-track-backups` or `cash-track-storage` keys).
2. **Create the `cash-track-prod` 1Password vault.** Under your existing 1Password account, create a new vault named exactly `cash-track-prod`.
3. **Create vault items and populate values from existing K8s secrets.** For each item below, create the item in 1Password and copy values out of K8s using `kubectl -n <ns> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d` (run locally, paste into 1Password desktop app, never via any Claude-accessible channel).

   Reference one-liners (run against the existing DOKS cluster):

   ```shell
   # tfstate bucket setup
   aws s3api put-bucket-versioning \
     --bucket cash-track-tfstate \
     --endpoint=https://ams3.digitaloceanspaces.com \
     --versioning-configuration Status=Enabled

   aws s3api put-bucket-lifecycle-configuration \
     --bucket cash-track-tfstate \
     --endpoint=https://ams3.digitaloceanspaces.com \
     --lifecycle-configuration file://infra/migration/tfstate.json

   # K8s secrets to dump
   for s in api-secret common-secret mysql-secret mysql-exporter-secret; do
     echo "=== $s ==="
     kubectl -n cash-track get secret "$s" -o json \
       | jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"'
   done
   for s in crashers-bot-secret home-exporter-secret; do
     echo "=== $s ==="
     kubectl -n telegram-bots get secret "$s" -o json \
       | jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"'
   done
   ```

   **Vault catalog — 12 items.** Per-vault dedup decisions:
   - **One `common` vault** holds every secret consumed by 2+ services (CAPTCHA, Google OAuth, mail, S3) so a key rotation touches one place. Values match the existing `common-secret` 1:1.
   - **No `gateway` vault** — gateway only needs `CAPTCHA_SECRET_KEY`, which comes from `common`.
   - **No `mysql-backup` vault** — mysql-backup pulls `MYSQL_ROOT_PASSWORD`+`MYSQL_DATABASE` from `mysql` and `S3_KEY`+`S3_SECRET` from `common`. Bucket name (`cash-track-backups`) is non-secret and lives in the `.env` template literal.
   - **No `mysql-app-users` vault** — the cluster runs a single shared app user (`cashtrack`) granted on every app DB; that user's credentials live in `mysql.MYSQL_USER` / `mysql.MYSQL_PASSWORD` and are reused by api, crashers-bot, home-exporter. `mysql-init` grants the user on each database listed in `databases.yml`. (Per-app users is a future hardening step; deferred to keep the cutover small.)
   - **Two telegram vaults** — `crashers-bot` and `home-exporter` are separate K8s deployments with separate secrets; mirroring that 1:1 in 1Password keeps audit logs and rotations app-scoped.
   - `alertmanager-telegram` stays its own vault — different bot, different chat, monitoring-scoped.

   | Vault item                 | Fields | Source K8s secret(s) | Consumed by |
   |----------------------------|---|---|---|
   | + `api`                    | `JWT_SECRET`, `JWT_PUBLIC_KEY`, `JWT_PRIVATE_KEY`, `ENCRYPTER_KEY`, `DB_ENCRYPTER_KEY` | `cash-track/api-secret` | api |
   | + `common`                 | `CAPTCHA_CLIENT_KEY`, `CAPTCHA_SECRET_KEY`, `GOOGLE_API_AUTH_PROVIDER_X509_CERT_URL`, `GOOGLE_API_AUTH_URI`, `GOOGLE_API_CLIENT_ID`, `GOOGLE_API_CLIENT_SECRET`, `GOOGLE_API_PROJECT_ID`, `GOOGLE_API_REDIRECT_URI`, `GOOGLE_API_TOKEN_URI`, `MAIL_HOST`, `MAIL_PASSWORD`, `MAIL_PORT`, `MAIL_USERNAME`, `S3_ENDPOINT`, `S3_KEY`, `S3_REGION`, `S3_SECRET` | `cash-track/common-secret` | api, gateway, website, mysql-backup |
   | + `mysql`                  | `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD` | `cash-track/mysql-secret` | mysql, mysql-backup, mysql-init, api, crashers-bot, home-exporter |
   | + `mysql-exporter`         | `DATA_SOURCE_NAME` (`exporter:<pw>@tcp(mysql:3306)/`) | `cash-track/mysql-exporter-secret` | mysql-exporter |
   | + `alertmanager-telegram`  | `BOT_TOKEN`, `CHAT_ID` | New (BotFather + private channel) | alertmanager |
   | `grafana`                  | `ADMIN_PASSWORD`, `SMTP_PASSWORD` | Existing Grafana if migrating; else generate | grafana |
   | + `crashers-bot`           | TBD — populate by inspecting `kubectl -n telegram-bots get secret crashers-bot-secret`; expected: `BOT_TOKEN`, plus any app-specific keys | `telegram-bots/crashers-bot-secret` | crashers-bot |
   | + `home-exporter`          | `TELEGRAM_BOT_TOKEN` (mirrors `home-exporter-secret`) **plus** `HOME_TELEGRAM_CHAT_ID`, `HOME_PROBE_HOST` (extracted from the K8s `home-exporter-config` ConfigMap so the YAML config can be rendered via op inject — see `home-exporter.config.yml.tpl`) | `telegram-bots/home-exporter-secret` + `home-exporter-config` ConfigMap | home-exporter |
   | + `cloudflare-origin-cert` | Two file attachments: `origin-cert.pem`, `origin-key.pem` | Cloudflare dashboard → SSL/TLS → Origin Server (save both the certificate textbox and the private-key textbox at creation time — Cloudflare does not retain the key) | traefik |
   | + `tailscale`              | `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` (tags `tag:prod-server,tag:ci`) | Tailscale admin → OAuth clients | terraform (cloud-init authkey mint) |
   | + `dockerhub`              | `USERNAME`, `TOKEN` | Docker Hub PAT, scope `read+write` on `cashtrack/*` | CI |
   | + `do-api`                 | `TOKEN` | DO dashboard PAT (scope `droplet:*, reserved_ip:*, volume:*, firewall:*, load_balancer:*, ssh_key:*, spaces:*, domain:*`) | terraform, firewall-refresh |
   | + `cash-track-tfstate`     | `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY` | Spaces access keypair generated in step 1 (dedicated; not shared with `cash-track-backups` or `cash-track-storage`) | terraform `backend.hcl` (operator local), CI org secrets `SPACES_TFSTATE_ID/KEY` |

   When dumping `crashers-bot-secret` and `home-exporter-secret`, fill in the `TBD` rows above with the actual key list before moving past Stage 0. The Stage 10 env templates (`crashers-bot.env.tpl`, `home-exporter.env.tpl`) reference these field names directly.


4. **Create a read-only 1Password Service Account.**
   - 1Password admin console → Integrations → Service Accounts → new.
   - Scope: **`cash-track-prod` vault, read-only on items** (can read items, cannot edit).
   - Token expiry: longest available (rotate quarterly — track in a calendar reminder).
   - Copy the token value **once** — it is shown exactly once.

5. **Add GitHub org secrets.** `github.com/cash-track` → Settings → Secrets and variables → Actions → Organization secrets. Scope each to the listed repos.

   | Secret | Scope | Value |
   |---|---|---|
   | `OP_SERVICE_ACCOUNT_TOKEN` | `infra` only | Token from step 4 |
   | `SPACES_TFSTATE_ID` | `infra` only | Access key ID from step 1 |
   | `SPACES_TFSTATE_KEY` | `infra` only | Secret access key from step 1 |
   | `TS_OAUTH_CLIENT_ID` | All service repos + `infra` + `.github` | `tailscale` item from vault |
   | `TS_OAUTH_SECRET` | All service repos + `infra` + `.github` | `tailscale` item from vault |
   | `DOCKERHUB_USERNAME` | All service repos | `dockerhub.USERNAME` |
   | `DOCKERHUB_TOKEN` | All service repos | `dockerhub.TOKEN` |

6. **Verify `op` CLI locally on operator laptop.**
   ```bash
   op signin                       # interactive, to your 1Password account
   op vault list                   # must show cash-track-prod
   op item list --vault cash-track-prod
   op item get api --vault cash-track-prod --field JWT_SECRET   # redact; verify value present
   ```

### Verification checklist

- [x] `doctl spaces ls` shows `cash-track-tfstate` in `ams3`, private.
- [x] `op vault get cash-track-prod` succeeds and lists 12 items.
- [x] All 12 items have populated fields (open each in desktop app, eyeball). `crashers-bot` and `home-exporter` field lists are filled in from their K8s secrets.
- [x] `gh secret list --org cash-track` (or org Settings UI) shows the 7 org secrets above.
- [x] Service Account token is saved in the operator's personal 1Password (offline break-glass copy) and as `OP_SERVICE_ACCOUNT_TOKEN` GitHub org secret.
- [x] `op item get cash-track-tfstate --vault cash-track-prod --field ACCESS_KEY_ID` returns the Spaces access key from step 1 (used to render `backend.hcl` in Stage 2).

### Signal "done"

Post a message to Claude Code: *"Stage 0 complete. Vault populated, Service Account token installed as GitHub org secret, Spaces tfstate bucket live."* Claude then proceeds with Stage 1.

---

## Stage 1 — Repo Scaffold + Terraform Code [CLAUDE CODE]

**Goal:** Create the directory skeleton and all Terraform files. No secrets touched.

**Prerequisites:** Stage 0 complete (at minimum the Spaces bucket exists, so Terraform has somewhere to store state).

**Files created/modified:**
- Modify: `./infra/.gitignore` — extend per design §3
- Create: `./infra/README.md` (new Docker Compose-focused — stub for now, filled in Stage 15)
- Rename: `./infra/README.md` → `./infra/README-kubernetes.md` (git mv; preserve history)
- Create: `./infra/Makefile` (minimal: `apply`, `plan`, `bootstrap` stubs — filled in Stage 6)
- Create: `./infra/terraform/backend.tf` (per design §13)
- Create: `./infra/terraform/providers.tf`
- Create: `./infra/terraform/main.tf`
- Create: `./infra/terraform/variables.tf`
- Create: `./infra/terraform/outputs.tf`
- Create: `./infra/terraform/terraform.tfvars` (per design §4, no secrets — `ssh_key_fingerprints` is a public fingerprint)
- Create: `./infra/terraform/modules/droplet/{main.tf,variables.tf,outputs.tf}`
- Create: `./infra/terraform/modules/droplet/templates/cloud-init.yaml` (per design §6)
- Create: `./infra/terraform/modules/block_volume/{main.tf,variables.tf,outputs.tf}` (with `lifecycle.prevent_destroy = true` per design §13)
- Create: `./infra/terraform/modules/reserved_ip/{main.tf,variables.tf,outputs.tf}` (with `lifecycle.prevent_destroy = true`)
- Create: `./infra/terraform/modules/firewall/{main.tf,variables.tf,outputs.tf}` (rules per design §14)

### Action items

1. **Rename existing README:** `git mv ./infra/README.md ./infra/README-kubernetes.md`. Do NOT modify its content yet — it's archival.
2. **Write new `./infra/README.md` stub:** one-liner pointing at the new layout; full day-2 content in Stage 15.
3. **Extend `./infra/.gitignore`:** add lines `secrets/`, `*.tfstate*`, `.terraform/`, `backend.hcl`, `/tmp/cashtrack-render/`. Do not delete existing entries.
4. **Write `./infra/terraform/backend.tf`** — copy verbatim from design §13. Note `use_lockfile = true`, region `us-east-1` (Terraform S3 backend quirk for DO Spaces).
5. **Write `./infra/terraform/providers.tf`** — declare `digitalocean` provider (pinned `~> 2.40`), `tls` provider (for generating the ops SSH key if operator wants — but default is external key).
6. **Write `./infra/terraform/variables.tf`** — one var per entry in design §4 tfvars.
7. **Write `./infra/terraform/main.tf`** — wire modules: `block_volume` + `reserved_ip` first (stable resources), then `droplet` (refers to them), then `firewall` (refers to droplet IDs). Fetch Cloudflare IP ranges via `data "http" "cf_ipv4"` / `"cf_ipv6"` from `var.cf_ipv4_url` / `var.cf_ipv6_url`.
8. **Write `./infra/terraform/outputs.tf`:**
   - `reserved_ip` (string)
   - `droplet_id` (list(string), index-addressable for `count` future)
   - `tailscale_hostname` (string)
   - `volume_id` (string)
9. **Write `./infra/terraform/terraform.tfvars`** — exact values from design §4. `ssh_key_fingerprints` is the public MD5 fingerprint of the ops key, NOT the private key. This is a non-secret.
10. **Write `terraform/modules/droplet/main.tf`** — `digitalocean_droplet.host` with `count = var.droplet_count`, `user_data = templatefile("${path.module}/templates/cloud-init.yaml", { ... })`. The cloud-init template receives `hostname`, `ops_ssh_public_key`, `tailscale_authkey`, `volume_name` via `templatefile`. The authkey is minted by a `data "tailscale_auth_key"` or a `digitalocean_ssh_key` pattern — design §6 says "TF provider mints single-use tagged non-ephemeral authkey"; use the `tailscale` Terraform provider with vars `tailscale_oauth_client_id` / `tailscale_oauth_client_secret` read from `var.*`. These OAuth values are provided via `TF_VAR_tailscale_oauth_*` environment variables by the operator at apply time; they are NOT stored in `terraform.tfvars` (kept out of git).
11. **Write `terraform/modules/droplet/templates/cloud-init.yaml`** — copy verbatim from design §6.
12. **Write `terraform/modules/block_volume/main.tf`** — `digitalocean_volume.data` + `digitalocean_volume_attachment.data`. `lifecycle { prevent_destroy = true }` on the volume.
13. **Write `terraform/modules/reserved_ip/main.tf`** — `digitalocean_reserved_ip.main` + `digitalocean_reserved_ip_assignment.main`. `prevent_destroy = true` on the IP.
14. **Write `terraform/modules/firewall/main.tf`** — `digitalocean_firewall.cashtrack` with inbound rules per design §14 table (80/443 from CF v4+v6, 41641 UDP, ICMP). `digitalocean_firewall` is droplet-attached via `droplet_ids`.
15. **Write `./infra/Makefile` stubs:**
   ```makefile
   .PHONY: plan apply bootstrap ssh-open ssh-close replace deploy backup-verify
   plan:
   	terraform -chdir=terraform plan
   apply:
   	terraform -chdir=terraform apply
   # other targets: documented in later stages
   ```

### Verification checklist

- [x] `cd infra && terraform -chdir=terraform fmt -check` passes (Claude runs `terraform fmt` on all `.tf` files).
- [x] `terraform -chdir=terraform validate` passes (after operator supplies `backend.hcl` — Claude can run `terraform init -backend=false && terraform validate` to skip backend init).
- [x] `grep -r 'TODO\|FIXME\|PLACEHOLDER' terraform/` returns nothing.
- [x] `grep -rE '(access|secret)_key|password|token' terraform/ | grep -v variable.tf` returns nothing except variable declarations.
- [x] `git status` clean after commit.
- [x] The new `README.md` does not reference "migration" anywhere (per design §3).

### Commits

1. `chore(infra): rename README.md to README-kubernetes.md`
2. `feat(infra): add terraform modules for droplet, volume, reserved_ip, firewall`

### Handoff

Tell operator: *"Stage 1 committed. Ready for Stage 2: please run `terraform init -backend-config=backend.hcl` and `terraform plan`, and paste the plan summary back."*

---

## Stage 2 — Terraform Init + Plan Review (OPERATOR-ONLY)

**Goal:** Validate that the Terraform code actually plans against DO, and that the plan matches expectations.

**Why operator-only:** `terraform init` requires `backend.hcl` with real Spaces credentials; `terraform plan` requires `DIGITALOCEAN_TOKEN` and `TF_VAR_tailscale_oauth_*` environment variables sourced from the vault.

### Action items

1. **Render `./infra/terraform/backend.hcl`** (NOT COMMITTED — already in `.gitignore` from Stage 1; `chmod 600` after writing):
   ```bash
   eval "$(op signin)"
   cat > infra/terraform/backend.hcl <<EOF
   endpoints = { s3 = "https://ams3.digitaloceanspaces.com" }
   access_key                  = "$(op read op://cash-track-prod/cash-track-tfstate/ACCESS_KEY_ID)"
   secret_key                  = "$(op read op://cash-track-prod/cash-track-tfstate/SECRET_ACCESS_KEY)"
   skip_credentials_validation = true
   skip_metadata_api_check     = true
   skip_requesting_account_id  = true
   skip_region_validation      = true
   skip_s3_checksum             = true
   use_path_style              = true
   EOF
   chmod 600 infra/terraform/backend.hcl
   ```
2. **Source DO + Tailscale credentials into shell:**
   ```bash
   eval "$(op signin)"
   export DIGITALOCEAN_TOKEN="$(op read op://cash-track-prod/do-api/TOKEN)"
   export TF_VAR_tailscale_oauth_client_id="$(op read op://cash-track-prod/tailscale/OAUTH_CLIENT_ID)"
   export TF_VAR_tailscale_oauth_client_secret="$(op read op://cash-track-prod/tailscale/OAUTH_CLIENT_SECRET)"
   ```
3. **Initialize backend:**
   ```bash
   cd infra/terraform && terraform init -backend-config=backend.hcl
   ```
4. **Run plan:**
   ```bash
   terraform plan -out=tfplan.out
   ```
5. **Review plan:** expect to create:
   - 1 × `digitalocean_droplet.host[0]`
   - 1 × `digitalocean_volume.data`
   - 1 × `digitalocean_volume_attachment.data`
   - 1 × `digitalocean_reserved_ip.main`
   - 1 × `digitalocean_reserved_ip_assignment.main`
   - 1 × `digitalocean_firewall.cashtrack`
   - 1 × `tailscale_tailnet_key.bootstrap`
   - 0 destroys, 0 updates on anything existing.
6. **If plan looks wrong:** do not apply. Share plan output with Claude Code (redacted where needed); Claude iterates on Terraform code. Loop back to step 4.
7. **If plan looks correct:** do NOT apply yet — apply is in Stage 7. Save `tfplan.out` locally; it will be stale by Stage 7 but confirms plan generation works.

### Verification checklist

- [x] `terraform init` completes without error; remote state file exists in `cash-track-tfstate/prod/terraform.tfstate`.
- [x] `terraform plan` shows only *Plan: 7 to add, 0 to change, 0 to destroy.* (exact count depends on module structure).
- [x] Nothing in the plan references a secret by value (`terraform plan` output in DO provider should show `(sensitive)` for the Tailscale authkey).
- [x] `backend.hcl` is `.gitignore`'d: `git status --ignored | grep backend.hcl` shows it as ignored.

### Signal "done"

Operator confirms: *"Stage 2 done. Plan output looks right, 7 additions, no destroys."*

---

## Stage 3 — Ansible Scaffold + base/docker/tailscale/volume Roles [CLAUDE CODE]

**Goal:** Ansible inventory, config, entrypoint playbook, and the first four OS-level roles. No secrets, no 1Password invocations yet.

**Files:**
- Create: `./infra/ansible/ansible.cfg`
- Create: `./infra/ansible/requirements.yml` — `community.docker`, `community.digitalocean`
- Create: `./infra/ansible/inventory/prod/terraform.sh` — dynamic inventory reading `terraform output -json`
- Create: `./infra/ansible/group_vars/all/main.yml` — versions map, retention, backups schedule (per design §4)
- Create: `./infra/ansible/site.yml` — roles list per design §7
- Create: `./infra/ansible/roles/base/` — tasks/main.yml, handlers/main.yml, templates/52unattended-upgrades-reboot.j2, files/needrestart.conf, files/sysctl-psi.conf
- Create: `./infra/ansible/roles/docker/` — tasks/main.yml (install already done in cloud-init; this role configures daemon.json with log rotation `max-size: 10m`, `max-file: 3`)
- Create: `./infra/ansible/roles/tailscale/` — tasks/main.yml (verifies tailscale status, sets up `tailscale serve` for grafana)
- Create: `./infra/ansible/roles/volume/` — tasks/main.yml (verifies `/mnt/data` mounted with expected label + flags; creates `{mysql,prometheus,loki,tempo,grafana,alertmanager}/` subdirs with correct ownership)

### Action items

1. **Write `ansible/ansible.cfg`:**
   ```ini
   [defaults]
   inventory = ./inventory/prod/terraform.sh
   host_key_checking = False
   stdout_callback = yaml
   gathering = smart
   retry_files_enabled = False

   [ssh_connection]
   ssh_args = -o ControlMaster=auto -o ControlPersist=60s
   pipelining = True
   ```
2. **Write `requirements.yml`:**
   ```yaml
   collections:
     - name: community.docker
       version: ">=3.12.0"
     - name: community.digitalocean
       version: ">=1.25.0"
     - name: community.general
   ```
3. **Write `inventory/prod/terraform.sh`** (executable, `chmod +x`):
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   TF_OUTPUT=$(terraform -chdir=../../terraform output -json)
   RIP=$(jq -r '.reserved_ip.value' <<<"$TF_OUTPUT")
   HOSTNAME=$(jq -r '.tailscale_hostname.value' <<<"$TF_OUTPUT")
   cat <<JSON
   {
     "prod": { "hosts": ["$HOSTNAME"], "vars": { "reserved_ip": "$RIP" } },
     "_meta": { "hostvars": { "$HOSTNAME": { "ansible_host": "$HOSTNAME", "ansible_user": "ops" } } }
   }
   JSON
   ```
   Ansible connects via Tailscale MagicDNS hostname; no SSH key plumbing needed beyond `tailscale up --ssh` on the droplet.
4. **Write `group_vars/all/main.yml`** — copy the `versions:` / `retention:` / `backups:` block from design §4 verbatim. Add `compose_files:` list (paths the compose-up role will use). Add `secret_files:` list (names used by compose-render).
5. **Write `site.yml`** — exactly as design §7, `pre_tasks` with the `wait_for /var/lib/bootstrap-ready` sentinel, then roles in order.
6. **Write role `base/tasks/main.yml`** — items per design §7 "base role" bullet list:
   - Set timezone UTC
   - Create `/swapfile` 1GB, chmod 0600, `mkswap`, `swapon`, add to `/etc/fstab`
   - Set `vm.swappiness=10`, `vm.vfs_cache_pressure=50`, `vm.overcommit_memory=1` via `/etc/sysctl.d/99-cashtrack.conf`
   - Install `unattended-upgrades` + `needrestart`
   - Drop `52unattended-upgrades-reboot.j2` → `/etc/apt/apt.conf.d/52unattended-upgrades-reboot`
   - Drop `needrestart.conf` → `/etc/needrestart/needrestart.conf`
   - Install `chrony`, enable
   - Install `node_exporter` (prep for observability scrape) — OR skip if compose node-exporter handles it; prefer compose (simpler). Confirm with operator if unsure; default is compose.
   - Create `@reboot` systemd oneshot service for post-reboot smoke check (§7 last bullet)
7. **Write `base/templates/52unattended-upgrades-reboot.j2`** — exact string literal from design §7. No Jinja needed; template just for idempotent placement.
8. **Write `docker/tasks/main.yml`** — drop `/etc/docker/daemon.json` with:
   ```json
   { "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
   ```
   `notify: restart docker`. Docker itself is installed by cloud-init; this role configures it.
9. **Write `tailscale/tasks/main.yml`** — verify `tailscale status --json | jq -r .BackendState` is `Running`; if not, fail with message. Set up `tailscale serve --https=443 http://localhost:3000` for grafana access (after grafana is up — guarded by `when: 'grafana' in compose_services`, default false in Stage 3).
10. **Write `volume/tasks/main.yml`** — assert `/mnt/data` mounted with label `cashtrack-data` (via `ansible.builtin.assert`); create subdirectories:
    ```yaml
    - name: Create data subdirs
      ansible.builtin.file:
        path: "/mnt/data/{{ item }}"
        state: directory
        owner: "{{ item_owner_uid }}"
        mode: "0755"
      loop: [ mysql, prometheus, loki, tempo, grafana, alertmanager ]
    ```
    UIDs per upstream images: mysql=999, prometheus=65534 (nobody), loki=10001, tempo=10001, grafana=472, alertmanager=65534. Use a dict lookup.

### Verification checklist

- [x] `ansible-playbook site.yml --syntax-check` passes (Claude runs this locally after `ansible-galaxy install -r requirements.yml`).
- [x] `ansible-lint ansible/` produces no errors (warnings ok).
- [x] `inventory/prod/terraform.sh` is executable and returns valid JSON when Terraform outputs are mocked (test with `TF_OUTPUT=$(cat fixtures/tf-output.json) ./terraform.sh`).
- [x] No role references `op://` yet (secrets come in Stage 5).

### Commit

`feat(infra/ansible): add scaffold + base/docker/tailscale/volume roles`

### Handoff

No operator action. Proceed to Stage 4.

---

## Stage 4 — Compose Files + Per-Service Configs + Env Templates [CLAUDE CODE]

**Goal:** All four `compose/*.yml` files, all service configs (Traefik, Prometheus, Loki, Tempo, Alertmanager, Promtail, Grafana provisioning), and all `.env.tpl` templates with `op://` references.

**Files:**
- Create: `./infra/compose/compose.core.yml` (per design §8)
- Create: `./infra/compose/compose.app.yml` (per design §8; full — not abbreviated — covers api, gateway, frontend, website, mysql-backup, mysql-exporter)
- Create: `./infra/compose/compose.obs.yml` (per design §8; full — covers prometheus, node-exporter, grafana, loki, tempo, promtail, alertmanager)
- Create: `./infra/compose/compose.telegram.yml` (deferred service bodies to Stage 10; structure here)
- Create: `./infra/compose/config/traefik/{traefik.yml,dynamic.yml}` (per design §8)
- Create: `./infra/compose/config/prometheus/prometheus.yml` (scrape configs for all services)
- Create: `./infra/compose/config/loki/loki.yml` (retention_period=168h, ingestion_rate_mb=2, ingestion_burst_size_mb=4, compactor.retention_enabled=true)
- Create: `./infra/compose/config/tempo/tempo.yml` (compactor.compaction.block_retention=72h, ingester.max_bytes_per_trace=5000000, OTLP gRPC :4317)
- Create: `./infra/compose/config/grafana/provisioning/datasources/datasources.yml`
- Create: `./infra/compose/config/grafana/provisioning/dashboards/dashboards.yml` (dashboard JSONs come in Stage 9)
- Create: `./infra/compose/config/alertmanager/alertmanager.yml` (telegram_configs receiver per design §9)
- Create: `./infra/compose/config/promtail/promtail.yml` (docker SD)
- Create: `./infra/ansible/roles/compose-render/templates/api.env.tpl` (per design §11)
- Create: `./infra/ansible/roles/compose-render/templates/gateway.env.tpl` (only `CAPTCHA_SECRET` + non-secret config; still rendered through `op inject` for uniformity)
- Create: `./infra/ansible/roles/compose-render/templates/website.env.tpl` (`CAPTCHA_CLIENT_KEY`, `GOOGLE_API_CLIENT_ID` from `common`)
- Create: `./infra/ansible/roles/compose-render/templates/mysql.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/mysql-backup.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/mysql-exporter.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/alertmanager.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/grafana.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/crashers-bot.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/home-exporter.env.tpl`
- Create: `./infra/ansible/roles/compose-render/templates/env.tpl` (top-level `.env` with `VERSION_*` vars and `DOMAIN=...`)

Frontend has no secrets in K8s (only `common-config` env vars), so no `frontend.env.tpl` is rendered through `op inject` — its config goes into the top-level `.env` or directly in the compose service `environment:` block.

### Action items

1. **Write `compose.core.yml`** exactly per design §8 (traefik, mysql, redis, ofelia) with full `mem_limit`/`oom_score_adj` values from design §5 memory table.
2. **Write `compose.app.yml`** — expand the abbreviated §8 snippet to include:
   - `api` (full)
   - `gateway` — `image: cashtrack/gateway:${VERSION_GATEWAY}`, port 8081 internal, Traefik labels `Host(gateway.${DOMAIN})`, middleware `retry@file + cloudflare-only@file`
   - `frontend` — `image: cashtrack/frontend:${VERSION_FRONTEND}`, static (nginx-alpine inside), Traefik `Host(my.${DOMAIN})`
   - `website` — `image: cashtrack/website:${VERSION_WEBSITE}`, port 3000 (Nuxt SSR), Traefik `Host(${DOMAIN}) || Host(www.${DOMAIN})`, `mem_limit: 640m`
   - `mysql-backup` (full, with Ofelia labels)
   - `mysql-exporter` (full)
   All services in `networks: [app]`. All with `restart: unless-stopped`.
3. **Write `compose.obs.yml`** — expand §8 snippet to include:
   - `prometheus` (full)
   - `node-exporter` — `image: prom/node-exporter:v1.8.2`, `pid: host`, `network_mode: host`, volumes `/proc:/host/proc:ro, /sys:/host/sys:ro, /:/rootfs:ro`, command `--path.procfs=/host/proc --path.sysfs=/host/sys --path.rootfs=/rootfs --collector.textfile.directory=/var/lib/node_exporter/textfile_collector`
   - `grafana` — `image: grafana/grafana:11.3.0`, `env_file: [secrets/grafana.env]`, volume `/mnt/data/grafana:/var/lib/grafana`, `./config/grafana/provisioning:/etc/grafana/provisioning:ro`
   - `loki` (full)
   - `tempo` (full)
   - `promtail` — `image: grafana/promtail:3.2.0`, volume `/var/run/docker.sock`, `/var/lib/docker/containers:/var/lib/docker/containers:ro`, `./config/promtail:/etc/promtail:ro`
   - `alertmanager` — `image: prom/alertmanager:v0.27.0`, `env_file: [secrets/alertmanager.env]`, volume `/mnt/data/alertmanager:/alertmanager`, `./config/alertmanager:/etc/alertmanager:ro`
4. **Write `compose.telegram.yml`** — structure only for now; `crashers-bot` and `home-exporter` service bodies filled in Stage 10. Include the shared `networks` reference.
5. **Write `config/traefik/traefik.yml`** exactly per design §8.
6. **Write `config/traefik/dynamic.yml`** per design §8 + §14 `cloudflare-only` middleware. The cert file paths point to `/etc/traefik/origin-cert.pem` and `/etc/traefik/origin-key.pem` — these are rendered by Ansible compose-render role (Stage 5) from the 1Password `cloudflare-origin-cert` attachments.
7. **Write `config/prometheus/prometheus.yml`** — scrape jobs for:
   - `prometheus` itself (localhost:9090)
   - `node-exporter` (host:9100)
   - `traefik` (traefik:8080 or internal metrics endpoint)
   - `mysql-exporter` (mysql-exporter:9104)
   - `ofelia` (ofelia:8081, `/metrics`)
   - `api` (api:8080, `/metrics` — spiral-prometheus or equivalent; confirm path against existing K8s ServiceMonitor in `./infra/services/api/`)
   - `gateway` (gateway:8081, `/metrics`)
   - `tempo`, `loki` (self-metrics endpoints)
   Include `rule_files: ['/etc/prometheus/rules/*.yml']` — rules themselves come in Stage 9.
8. **Write `config/loki/loki.yml`** — explicit retention:
   ```yaml
   limits_config:
     retention_period: 168h
     ingestion_rate_mb: 2
     ingestion_burst_size_mb: 4
   compactor:
     working_directory: /loki/compactor
     retention_enabled: true
     retention_delete_delay: 2h
   ```
   Plus standard filesystem storage config pointed at `/loki`.
9. **Write `config/tempo/tempo.yml`** — with the retention + trace-size caps; OTLP receiver on gRPC :4317.
10. **Write `config/grafana/provisioning/datasources/datasources.yml`** — Prometheus, Loki, Tempo as datasources, URLs `http://prometheus:9090`, etc.
11. **Write `config/grafana/provisioning/dashboards/dashboards.yml`** — dashboard provider config pointing at `/etc/grafana/provisioning/dashboards/json/` (JSON files added in Stage 9).
12. **Write `config/alertmanager/alertmanager.yml`** — telegram_configs receiver; values `bot_token` and `chat_id` come from `$ALERTMANAGER_TELEGRAM_BOT_TOKEN` / `$ALERTMANAGER_TELEGRAM_CHAT_ID`, sourced from `alertmanager.env` via `env_file`. Use `{{ env "..." }}` Go-template syntax for alertmanager 0.26+.
13. **Write `config/promtail/promtail.yml`** — Docker SD config targeting the Docker socket; scrape containers on the `cashtrack-app` network; parse JSON logs.
14. **Write the `.env.tpl` files** per design §11. Every secret value is an `op://cash-track-prod/<item>/<field>` reference. No plaintext secrets. Cross-service keys (CAPTCHA, Google, MAIL, S3) live in `common`; per-service items (`api`, `mysql`, `mysql-exporter`, `crashers-bot`, `home-exporter`) hold only that service's keys. Example `api.env.tpl` (mirrors the `envFrom: common-secret + api-secret + mysql-secret` composition in `infra/services/api/deployment.yml`):

    ```ini
    APP_ENV=prod
    DEBUG=false

    # api-secret
    JWT_SECRET={{ op_prefix }}/api/JWT_SECRET
    JWT_PUBLIC_KEY={{ op_prefix }}/api/JWT_PUBLIC_KEY
    JWT_PRIVATE_KEY={{ op_prefix }}/api/JWT_PRIVATE_KEY
    ENCRYPTER_KEY={{ op_prefix }}/api/ENCRYPTER_KEY
    DB_ENCRYPTER_KEY={{ op_prefix }}/api/DB_ENCRYPTER_KEY

    # common-secret (shared with gateway / website / mysql-backup)
    CAPTCHA_CLIENT_KEY={{ op_prefix }}/common/CAPTCHA_CLIENT_KEY
    CAPTCHA_SECRET_KEY={{ op_prefix }}/common/CAPTCHA_SECRET_KEY
    GOOGLE_API_CLIENT_ID={{ op_prefix }}/common/GOOGLE_API_CLIENT_ID
    GOOGLE_API_CLIENT_SECRET={{ op_prefix }}/common/GOOGLE_API_CLIENT_SECRET
    GOOGLE_API_PROJECT_ID={{ op_prefix }}/common/GOOGLE_API_PROJECT_ID
    GOOGLE_API_AUTH_URI={{ op_prefix }}/common/GOOGLE_API_AUTH_URI
    GOOGLE_API_TOKEN_URI={{ op_prefix }}/common/GOOGLE_API_TOKEN_URI
    GOOGLE_API_REDIRECT_URI={{ op_prefix }}/common/GOOGLE_API_REDIRECT_URI
    GOOGLE_API_AUTH_PROVIDER_X509_CERT_URL={{ op_prefix }}/common/GOOGLE_API_AUTH_PROVIDER_X509_CERT_URL
    MAIL_HOST={{ op_prefix }}/common/MAIL_HOST
    MAIL_PORT={{ op_prefix }}/common/MAIL_PORT
    MAIL_USERNAME={{ op_prefix }}/common/MAIL_USERNAME
    MAIL_PASSWORD={{ op_prefix }}/common/MAIL_PASSWORD
    S3_ENDPOINT={{ op_prefix }}/common/S3_ENDPOINT
    S3_REGION={{ op_prefix }}/common/S3_REGION
    S3_KEY={{ op_prefix }}/common/S3_KEY
    S3_SECRET={{ op_prefix }}/common/S3_SECRET

    # mysql-secret — single shared app user
    DB_HOST=mysql:3306
    DB_NAME={{ op_prefix }}/mysql/MYSQL_DATABASE
    DB_USER={{ op_prefix }}/mysql/MYSQL_USER
    DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD

    REDIS_CONNECTION=redis:6379
    ```

    `{{ op_prefix }}` is a Jinja variable set to `op://cash-track-prod` in `group_vars/all/main.yml`. Compare against `infra/services/api/deployment.yml` to confirm the env var **names** (the API binds K8s `MYSQL_USER` to the app env var `DB_USER`; the same remap happens here in the template).
15. **Write `env.tpl`** — the top-level `.env`:
    ```ini
    DOMAIN=cash-track.app
    VERSION_API={{ versions.api }}
    VERSION_GATEWAY={{ versions.gateway }}
    VERSION_FRONTEND={{ versions.frontend }}
    VERSION_WEBSITE={{ versions.website }}
    VERSION_MYSQL={{ versions.mysql }}
    VERSION_MYSQL_BACKUP={{ versions.mysql_backup }}
    VERSION_REDIS={{ versions.redis }}
    VERSION_CRASHERS_BOT={{ versions.crashers_bot }}
    VERSION_HOME_EXPORTER={{ versions.home_exporter }}
    ```
    This file has no secrets — it's git-committed as a template but rendered on disk by Ansible.

### Verification checklist

- [x] `docker compose -f compose/compose.core.yml -f compose/compose.app.yml -f compose/compose.obs.yml -f compose/compose.telegram.yml config > /dev/null` passes syntactically (requires `VERSION_*` and `DOMAIN` vars exported for the smoke; set dummies). Verified both with and without `--profile stage10`.
- [x] `grep -rE '(password|secret|token)=[^{]' compose/ ansible/roles/compose-render/templates/` returns zero matches (no plaintext secrets). Match only `{{ op_prefix }}` references.
- [x] `yamllint compose/ config/` clean (run via `cytopia/yamllint` docker image).
- [x] Every `env_file:` referenced in a compose file has a corresponding `.env.tpl` in `ansible/roles/compose-render/templates/`. 11:11:11 parity between compose env_file refs, templates, and `secret_files` in `group_vars/all/main.yml`.
- [x] Every service appears in Prometheus scrape config OR is explicitly exempted (document which in `prometheus.yml` comments). Exemptions: frontend (static SPA), website (no /metrics), redis (no exporter), mysql (via mysql-exporter), mysql-backup (via node-exporter textfile), crashers-bot + home-exporter (Stage 10).

### Notes on deviations from the design snippets

- **Network model.** Each compose file declares the same `networks.app` block (`driver: bridge`, `name: cashtrack-app`) instead of marking it `external: true` in app/obs/telegram. Identical declarations let compose merge cleanly and reuse the named network across stacks; `external: true` would have required pre-creating it out-of-band.
- **Gateway port.** `GATEWAY_ADDRESS=:8081` (per this plan), Traefik routes to 8081. K8s deployment used `:80` — deliberate divergence the plan called out.
- **node-exporter scrape.** Host-networked, so Prometheus reaches it via `host.docker.internal:9100`; the prometheus service carries an `extra_hosts: ["host.docker.internal:host-gateway"]` entry. Documented in both `compose.obs.yml` and `prometheus.yml`.
- **Frontend env template.** Added `frontend.env.tpl` (URLs only, no secrets) — the frontend image consumes `VUE_APP_*` at runtime via its entrypoint, matching the K8s `common-config` envFrom on `infra/services/frontend/deployment.yml`. The original plan said the frontend had no env file; that was incorrect against the K8s reality.
- **`group_vars/all/main.yml` patch.** `secret_files` updated to include `frontend.env` and `website.env` (the latter was missing from Stage 3's seed list).
- **Telegram stack.** Service stubs gated behind `profiles: [stage10]` so default `compose up` skips them until Stage 10 fills the bodies.
- **`.gitignore`.** Added `compose/.env`, `compose/config/traefik/origin-cert.pem`, `compose/config/traefik/origin-key.pem` so rendered/secret artefacts can't slip into git.

### Commit

`feat(infra/compose): add docker compose files, service configs, and env templates`

### Handoff

No operator action. Proceed to Stage 5.

---

## Stage 5 — Ansible mysql-init + compose-render + compose-up + Ops Playbooks [CLAUDE CODE]

**Goal:** The three remaining roles (secret-rendering and deployment) plus ops playbooks for emergency and routine operations.

**Files:**
- Create: `./infra/ansible/roles/mysql-init/{tasks,vars,templates}/main.yml` + `vars/databases.yml`
- Create: `./infra/ansible/roles/compose-render/{tasks,handlers,defaults,templates}/main.yml`
- Create: `./infra/ansible/roles/compose-up/tasks/main.yml`
- Create: `./infra/ansible/deploy.yml`
- Create: `./infra/ansible/replace-droplet.yml`
- Create: `./infra/ansible/ops/ssh-open.yml`
- Create: `./infra/ansible/ops/ssh-close.yml`
- Create: `./infra/ansible/ops/firewall-refresh-cf.yml`
- Create: `./infra/ansible/ops/backup-restore.yml`
- Create: `./infra/ansible/bin/deploy-service` — the droplet-side script (per design §12), shipped by compose-up role

### Action items

1. **Write `mysql-init/vars/databases.yml`** — single shared app user, multiple databases (matches K8s reality; per-app users deferred):
   ```yaml
   app_user:
     user_op_ref:     "op://cash-track-prod/mysql/MYSQL_USER"
     password_op_ref: "op://cash-track-prod/mysql/MYSQL_PASSWORD"
   databases:
     - cashtrack
     - telegram_bots
   ```
2. **Write `mysql-init/tasks/main.yml`:** uses `community.mysql.mysql_db` and `community.mysql.mysql_user`, running against the mysql container via `delegate_to: "{{ inventory_hostname }}"` + `ansible_python_interpreter` switch. Requires `MYSQL_ROOT_PASSWORD` in the environment (rendered into a temp file in `compose-render`). Resolve `app_user` user/password via `op read` in a `delegate_to: localhost` pre-task with `no_log: true`. For each `databases[*]`: create the database idempotently and grant the resolved app user `ALL PRIVILEGES` on `<db>.*`. Adding a new application = add its DB name to the list and re-run; no new vault item, no new user.
3. **Write `compose-render/defaults/main.yml`:**
   ```yaml
   secret_files:
     - api
     - gateway
     - website
     - mysql
     - mysql-backup
     - mysql-exporter
     - alertmanager
     - grafana
     - crashers-bot
     - home-exporter
   op_prefix: "op://cash-track-prod"
   render_dir: /tmp/cashtrack-render
   droplet_project_dir: /opt/cashtrack
   ```
4. **Write `compose-render/tasks/main.yml`** per design §11 — the four-task flow:
   - Render template locally via `ansible.builtin.template` (`.env.tpl` → `/tmp/cashtrack-render/<name>.env.tpl`)
   - Run `op inject -i ... -o ...` via `ansible.builtin.command`, `delegate_to: localhost`, `environment: OP_SERVICE_ACCOUNT_TOKEN: "{{ lookup('env', 'OP_SERVICE_ACCOUNT_TOKEN') }}"`, `no_log: true`
   - `ansible.builtin.copy` the rendered `.env` to `/opt/cashtrack/secrets/<name>.env`, `mode: 0600`, `owner: ops`, `notify: "restart {{ item }}"`, `no_log: true`
   - Wipe `/tmp/cashtrack-render/` at the end
   Also render `env.tpl` → `.env` on the droplet (no `op inject` — no secrets in it). Also fetch the Traefik cert pair: `op read "op://cash-track-prod/cloudflare-origin-cert/origin-cert.pem"` and `op read "op://cash-track-prod/cloudflare-origin-cert/origin-key.pem"` (two separate file attachments on the same item), copy each to `/opt/cashtrack/config/traefik/origin-{cert,key}.pem` with `mode: 0600`, owner root. Also render `alertmanager.yml` and any other per-service config files that reference rendered environment values.

   **Critical:** `no_log: true` on every task that handles a rendered file. Ansible verbose output should never leak a secret.

5. **Write `compose-render/handlers/main.yml`** — one handler per `secret_files` item plus a shared `restart traefik` handler for the CF cert. Each handler uses `community.docker.docker_compose_v2` with `restarted: true` and `services: [<name>]`.
6. **Write `compose-up/tasks/main.yml`:**
   ```yaml
   - name: Upload compose files
     ansible.builtin.copy:
       src: "../../compose/{{ item }}"
       dest: "/opt/cashtrack/{{ item }}"
       mode: "0644"
     loop:
       - compose.core.yml
       - compose.app.yml
       - compose.obs.yml
       - compose.telegram.yml

   - name: Upload config files
     ansible.builtin.copy:
       src: "../../compose/config/"
       dest: "/opt/cashtrack/config/"
       mode: "0644"

   - name: Install deploy-service script
     ansible.builtin.copy:
       src: "bin/deploy-service"
       dest: "/opt/cashtrack/bin/deploy-service"
       mode: "0755"
       owner: ops

   - name: Compose up
     community.docker.docker_compose_v2:
       project_src: /opt/cashtrack
       files: "{{ compose_files }}"
       state: present
       remove_orphans: true
       pull: missing
   ```
7. **Write `bin/deploy-service`** per design §12 — literal contents verbatim. Shipped by compose-up role to `/opt/cashtrack/bin/deploy-service`.
8. **Write `deploy.yml`** — calling `site.yml --tags compose` with override for a single service (entry point for laptop/infra-originated single-service deploys).
9. **Write `replace-droplet.yml`** — orchestrates:
   - `scripts/replace-preflight.sh` (external; fails if backup stale)
   - `terraform apply -replace='digitalocean_droplet.host[0]' -auto-approve`
   - `site.yml` full run
10. **Write `ops/ssh-open.yml`:** uses `community.digitalocean.digital_ocean_firewall` to ADD a TCP 22 rule for `{{ ip }}/32` to firewall `cashtrack-prod`. Requires `DIGITALOCEAN_TOKEN` in env.
11. **Write `ops/ssh-close.yml`:** removes the TCP 22 rule.
12. **Write `ops/firewall-refresh-cf.yml`:** fetches CF IPv4 + IPv6 lists from `https://www.cloudflare.com/ips-v4` and `ips-v6`, updates firewall inbound rules. Can be invoked as a weekly cron on the operator laptop or as a GH Actions cron (future).
13. **Write `ops/backup-restore.yml`:** parameterized with `backup_id` (or `latest`), runs on the droplet:
    - `docker compose exec mysql-backup aws s3 cp s3://cash-track-backups/<id>.sql.gz /tmp/restore.sql.gz`
    - `docker compose exec -T mysql mysql -u root -p$ROOT < /tmp/restore.sql` (with `gunzip` piped in)
    - row-count verification SELECTs on `users`, `wallets`, `charges`, `tags` tables, store in a fact for later reporting
    Guarded by `--check` when possible; no destructive default.

### Verification checklist

- [x] `ansible-playbook site.yml --syntax-check` passes (also for `deploy.yml`, `replace-droplet.yml`, all four `ops/*.yml`).
- [x] `ansible-lint ansible/` clean at the **production** profile (0 failures, 0 warnings across 23 files).
- [x] Every `op://` reference in `.env.tpl` files resolves syntactically — templates are pure Jinja-formed `op://cash-track-prod/<item>/<field>` URIs, no missing pieces.
- [x] `no_log: true` appears on every task that processes a secret. Audited via grep + per-task scan of `roles/mysql-init/tasks/main.yml`, `roles/compose-render/tasks/main.yml`, `ops/backup-restore.yml` — every task that touches an `op read`, `op inject`, MYSQL root password, or rendered `.env` body carries `no_log: true`.
- [x] `deploy-service` script clean. `shellcheck` not installed locally; fell back to `bash -n` (parse-clean). Run `shellcheck ansible/roles/compose-up/files/deploy-service` in CI when available.
- [x] No role writes a secret to git or to any non-ephemeral location outside `/opt/cashtrack/secrets/`. Local plaintext lives only in `/tmp/cashtrack-render/` for the duration of `compose-render` and is wiped by the final task; CF cert/key go to `/opt/cashtrack/config/traefik/origin-{cert,key}.pem` (mode 0644/0600 root); rendered env files go to `/opt/cashtrack/secrets/<name>.env` (mode 0600 ops).

**Notes carried out of stage 5:**

- `secret_files` in `group_vars/all/main.yml` switched from `<name>.env` to bare names (`api`, `gateway`, …) so the role's `loop` matches the design §11 pattern (`{{ item }}.env.tpl` / `{{ item }}.env`). Mirrored in `roles/compose-render/defaults/main.yml`.
- `deploy-service` ships from `roles/compose-up/files/deploy-service` (not `ansible/bin/deploy-service` as in the plan's "Files" sketch) — keeps it co-located with the role that installs it.
- `mysql-init` talks to mysql via `docker exec` rather than `community.mysql.mysql_db` (mysql container does not publish 3306 on the host; `docker exec` avoids adding a network surface or pymysql installation requirement).
- Site role order is `compose-render → compose-up → mysql-init` (compose-up must run first so the mysql container exists for mysql-init to exec into; compose-render must run before compose-up so `secrets/mysql.env` exists for the container).
- `group_vars/all/main.yml` aligned-colon dict literals (`api:           "1.2.9"`, etc.) tripped `yaml[colons]` at the production profile after stage 4 added a few more files — collapsed every `versions:`/`retention:`/`backups:` entry to a single space after the colon to satisfy `ansible-lint`.

### Commit

`feat(infra/ansible): add mysql-init, compose-render, compose-up roles, ops playbooks`

### Handoff

No operator action. Proceed to Stage 6.

---

## Stage 6 — Helper Scripts + Top-Level Makefile [CLAUDE CODE]

**Goal:** Operator-facing commands. `scripts/*` and `Makefile` targets.

**Files:**
- Create: `./infra/scripts/bootstrap-buckets.sh` — one-time, already-run helper; kept for posterity
- Create: `./infra/scripts/replace-preflight.sh` — per design §17 (backup freshness + override)
- Create: `./infra/scripts/restore-to-new-volume.sh` — per design §17 (block volume corruption path)
- Modify: `./infra/Makefile` — fill in stubs from Stage 1

### Action items

1. **Write `scripts/bootstrap-buckets.sh`** — `doctl spaces create cash-track-tfstate --acl private ...` + `doctl spaces keys create ...`. Idempotent (check-then-create). Called once per-environment; operator already ran the equivalent manually in Stage 0, but the script exists as the canonical record.
2. **Write `scripts/replace-preflight.sh`:**
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail

   # Query cash-track-backups for the most recent backup object
   # Requires: SPACES_ID, SPACES_KEY (for mysql-backup key, read-only) OR rely on s3cmd with operator creds
   latest_ts=$(aws --endpoint-url https://ams3.digitaloceanspaces.com s3 ls s3://cash-track-backups/ \
     --recursive | sort | tail -1 | awk '{print $1, $2}')
   # convert latest_ts to epoch, diff vs now
   age_seconds=$(( $(date +%s) - $(date -d "$latest_ts" +%s) ))
   age_hours=$(( age_seconds / 3600 ))

   if [ "$age_hours" -gt 24 ]; then
     if [ -z "${FORCE_REPLACE_REASON:-}" ]; then
       echo "ERROR: last backup is ${age_hours}h old (>24h). Set FORCE_REPLACE_REASON='<incident-id>: <rationale>' to override." >&2
       exit 1
     fi
     # Write audit record to s3://cash-track-tfstate/audit/replace-overrides/<ts>.json
     # Post alertmanager-style Telegram message
     # If either fails, abort per design §17
     ...
   fi
   echo "Preflight OK. Last backup: ${age_hours}h ago."
   ```
   Full script with audit + Telegram post per design §17.
3. **Write `scripts/restore-to-new-volume.sh`** — per design §17; operator-invoked during block-volume-corruption DR.
4. **Update `./infra/Makefile`:**
   ```makefile
   TF = terraform -chdir=terraform
   AP = ansible-playbook -i ansible/inventory/prod/terraform.sh

   .PHONY: plan apply bootstrap replace deploy ssh-open ssh-close backup-verify firewall-refresh

   plan:
   	$(TF) plan
   apply:
   	$(TF) apply
   bootstrap:
   	$(AP) ansible/site.yml
   replace:
   	./scripts/replace-preflight.sh
   	$(TF) apply -replace='digitalocean_droplet.host[0]' -auto-approve
   	$(AP) ansible/site.yml
   deploy:
   	$(AP) ansible/site.yml --tags compose
   ssh-open:
   	$(AP) ansible/ops/ssh-open.yml -e ip=$(IP)
   ssh-close:
   	$(AP) ansible/ops/ssh-close.yml
   backup-verify:
   	$(AP) ansible/ops/backup-restore.yml -e backup_id=latest -e verify_only=true
   firewall-refresh:
   	$(AP) ansible/ops/firewall-refresh-cf.yml
   ```

### Verification checklist

- [x] `shellcheck scripts/*.sh` clean. *(shellcheck not installed locally per CLAUDE.md; substituted `bash -n scripts/*.sh` parse check — all three scripts parse OK.)*
- [x] `make -n plan` (dry-run) prints the expected terraform invocation. → `terraform -chdir=terraform plan`.
- [x] `make -n replace` shows preflight + replace + bootstrap in order. → `./scripts/replace-preflight.sh` → `terraform -chdir=terraform apply -replace='digitalocean_droplet.host[0]' -auto-approve` → `cd ansible && ansible-playbook site.yml`.
- [x] `scripts/replace-preflight.sh` refuses to run without `FORCE_REPLACE_REASON` when backup stale. Verified with three mocked-`aws` runs: stale + no override → exit 1; stale + `FORCE_REPLACE_REASON` + telegram mock → exit 0; fresh backup → exit 0. `AWS_BIN` / `CURL_BIN` env hooks in the script make this reproducible without real Spaces creds.
- [x] `ansible-lint` clean across all playbooks (`production` profile, 21 files including `ops/backup-restore.yml` after adding `verify_only` mode).

### Commit

`feat(infra): add bootstrap/replace-preflight/restore scripts and Makefile targets`

### Handoff

Tell operator: *"Stages 1–6 done. All code written. Ready for Stage 7: first provision via `make apply && make bootstrap`."*

---

## Stage 7 — First Provision (OPERATOR-ONLY)

**Goal:** Terraform creates droplet/volume/IP/firewall, cloud-init runs, Ansible runs site.yml. Core Docker Compose stack (traefik/mysql/redis/ofelia) comes up. No app services yet — those come in Stage 8 via full compose-up with `state: present`.

**Why operator-only:** requires DO API token, 1Password Service Account token, and terraform state bucket access keys. Claude Code is explicitly forbidden from these per your constraints.

### Pre-flight

- [ ] Stage 0 confirmed done (vault populated, bucket exists, org secrets set).
- [ ] Stage 2 terraform plan was reviewed and looked correct.
- [ ] Operator has `backend.hcl` populated and chmod 600.
- [ ] `op` CLI signed in to `cash-track-prod` vault.

### Action items

1. **Export credentials locally** (same as Stage 2 step 2):
   ```bash
   eval "$(op signin)"
   export DIGITALOCEAN_TOKEN="$(op read op://cash-track-prod/do-api/TOKEN)"
   export TF_VAR_tailscale_oauth_client_id="$(op read op://cash-track-prod/tailscale/OAUTH_CLIENT_ID)"
   export TF_VAR_tailscale_oauth_client_secret="$(op read op://cash-track-prod/tailscale/OAUTH_CLIENT_SECRET)"
   export OP_SERVICE_ACCOUNT_TOKEN="$(op read op://cash-track-prod/_service-account/TOKEN)"   # OR your personal cache
   ```
2. **Apply Terraform:**
   ```bash
   cd infra && make apply
   ```
   - Expect ~3 min for droplet creation + Tailscale join.
   - Output includes `reserved_ip`, `tailscale_hostname`, `volume_id`.
3. **Wait for cloud-init sentinel:** `tailscale ssh ops@cashtrack-prod-0 'sudo test -f /var/lib/bootstrap-ready && echo OK'` — retry every 10s for up to 5 min.
4. **Run bootstrap:**
   ```bash
   make bootstrap
   ```
   - Installs collections (`ansible-galaxy install -r ansible/requirements.yml` should run as a pre-step or be pre-installed).
   - Runs `site.yml` which applies all roles.
   - Secrets are injected via `op` locally and shipped to `/opt/cashtrack/secrets/` on the droplet.
   - First compose-up starts: traefik, mysql (empty schema — mysql-init role created databases and users), redis, ofelia.
   - Observability and app services DO come up here too, BUT:
     - api/gateway/frontend/website will 502 until MySQL has data (Stage 8).
     - Prometheus will scrape but show many "DOWN" targets until restore.
     - Alertmanager may fire — silence pre-cutover alerts via `amtool silence add ...` before running, or temporarily point `alertmanager.env` Telegram chat_id at a sandbox channel.

### Verification checklist

- [ ] `tailscale ssh ops@cashtrack-prod-0 'docker compose -f compose.core.yml ps'` — all core services `healthy` or `running`.
- [ ] `tailscale ssh ops@cashtrack-prod-0 'docker compose exec mysql mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SHOW DATABASES"'` shows `cashtrack`, `telegram_bots`.
- [ ] `tailscale ssh ops@cashtrack-prod-0 'ls /mnt/data/'` shows `mysql/`, `prometheus/`, `loki/`, `tempo/`, `grafana/`, `alertmanager/`.
- [ ] `/opt/cashtrack/secrets/*.env` exist with mode 0600.
- [ ] Traefik dashboard reachable via `tailscale serve` if configured; else `docker compose exec traefik wget -qO- http://localhost:8080/api/rawdata` shows router configs.
- [ ] No plaintext secret in `/tmp/cashtrack-render/` on operator laptop (should have been wiped by the render task's "absent" file action).

### If anything fails

1. Check `/var/log/cloud-init-output.log` on the droplet via `tailscale ssh`.
2. Re-run `make bootstrap` — idempotent; will fast-forward.
3. If Terraform state got wedged, `terraform state list`, `terraform taint <resource>`, retry.
4. If cloud-init hung on Tailscale, check the authkey TTL — single-use, short-lived; `terraform apply` re-mints on replacement.

### Signal "done"

Operator confirms: *"Stage 7 done. Core stack healthy on the droplet."*

---

## Stage 8 — Restore MySQL + App-Service Smoke Test (OPERATOR-ONLY)

**Goal:** Pull latest K8s MySQL backup into the new droplet's MySQL; confirm api/gateway/frontend/website all respond to internal `curl --resolve` probes.

### Action items

1. **Trigger a fresh K8s backup** (to minimize restore-point age):
   ```bash
   kubectl -n cash-track exec deployment/mysql-backup -- php app.php backup
   # note the returned backup ID
   ```
2. **Restore on the droplet:**
   ```bash
   cd infra && ansible-playbook ansible/ops/backup-restore.yml -e backup_id=<id>
   ```
   - The playbook pulls the dump from `cash-track-backups`, loads into the `cashtrack` database.
   - The shared app user (`mysql.MYSQL_USER`) is granted post-restore (if restore drops and recreates grants, re-run mysql-init role: `make bootstrap -e ansible_tags=mysql`).
3. **Restart dependent services** to pick up restored data:
   ```bash
   tailscale ssh ops@cashtrack-prod-0 'cd /opt/cashtrack && docker compose restart api gateway'
   ```
4. **Internal smoke test:**
   ```bash
   RIP=$(cd infra && terraform -chdir=terraform output -raw reserved_ip)
   for host in cash-track.app my.cash-track.app api.cash-track.app gateway.cash-track.app; do
     curl -sS -o /dev/null -w "$host -> %{http_code}\n" \
       --resolve "$host:443:$RIP" "https://$host/healthcheck" || true
   done
   ```
   Expect `200` on all four.
5. **Row-count sanity:** on the droplet, `docker compose exec mysql mysql -u root -p$ROOT cashtrack -e "SELECT count(*) FROM users, charges, wallets"` — compare against a snapshot taken before the K8s backup.

### Verification checklist

- [ ] All four internal smoke tests return 200.
- [ ] Row counts match (or are within expected delta from new post-backup writes on K8s during restore).
- [ ] `docker compose ps` — api / gateway / frontend / website / mysql-backup / mysql-exporter all `healthy`.
- [ ] `docker compose logs api --tail=100` shows no `PDOException` / `Connection refused`.
- [ ] `docker compose logs mysql-backup --tail=100` shows no recurring errors (the container is idle; only logs on Ofelia trigger).

### If any fails

- api 500 → `docker compose logs api` → check DB password, CAPTCHA secret, etc. A common failure: the restore dump re-created the shared app user with the old password; force the vault password by running `make bootstrap --tags mysql` after restore.
- gateway 502 upstream → `docker compose logs gateway` → API container health; check `compose.app.yml` Traefik labels spelled the service name right (`api.cashtrack-app` network name).
- frontend 404 on `/healthcheck` → frontend image serves static assets, not a healthcheck; adjust smoke test to `GET /` and assert HTTP 200 + known body substring.

### Signal "done"

Operator confirms: *"Stage 8 done. App services live internally with restored data."*

---

## Stage 9 — Observability Dashboards + Alert Rules [CLAUDE CODE]

**Goal:** Copy existing Prometheus rules + Grafana dashboards from `./infra/services/prometheus/configs/` and `./infra/services/alertmanager/configs/` (per design §20 "Out of Scope" — these are copied verbatim, not re-authored). Add the host-level rules from design §15. Commit and redeploy.

**Files:**
- Create: `./infra/compose/config/prometheus/rules/host.yml` (design §15 rule set)
- Create: `./infra/compose/config/prometheus/rules/service.yml` (copied from existing K8s manifests)
- Create: `./infra/compose/config/grafana/provisioning/dashboards/json/*.json` (copied from existing)
- Modify: `./infra/compose/config/alertmanager/alertmanager.yml` — ensure `route.receiver: telegram`; verify no routing gaps.

### Action items

1. **Find existing K8s Prometheus rules:** `ls ./infra/services/prometheus/configs/` and `./infra/services/alertmanager/configs/`. Claude Code identifies the files and copies them into `compose/config/prometheus/rules/` with path adjustments (no K8s service-discovery selectors).
2. **Write `rules/host.yml`** — verbatim from design §15 (HostMemoryPressure, HostRebootRequired, MySQLBackupStale, BlockVolumeIOPSSaturated).
3. **Copy Grafana dashboards** — from existing K8s ConfigMaps or wherever they live; place JSON at `compose/config/grafana/provisioning/dashboards/json/<dashboard>.json`. Dashboards to port: Traefik overview, API latency (p50/p95/p99), MySQL, Redis, Node metrics, Ofelia job status. Search `./infra/` for existing `.json` dashboard files.
4. **Verify `alertmanager.yml`** — single route to `telegram` receiver, subroutes for severity levels, `inhibit_rules` for noisy pairs (e.g. suppress service-up alerts when host is down).
5. **Operator asks Claude to test-fire an alert** post-deploy (see Stage 9 verification below).

### Verification checklist

- [x] `promtool check rules compose/config/prometheus/rules/*.yml` passes — `host.yml` (6 rules), `service.yml` (10 rules), `tempo.yml` (26 rules); `promtool check config compose/config/prometheus/prometheus.yml` also passes (rule-files glob picks up all three).
- [~] `amtool check-config compose/config/alertmanager/alertmanager.yml` — fails on the literal file because Stage 4 wired `bot_token` / `chat_id` as `'{{ env "..." }}'` strings, but Alertmanager does **not** expand env vars in YAML config keys (templating is only valid inside `message` rendering). Routing/inhibit structure is verified by re-running amtool against the file with placeholder secrets substituted — `SUCCESS: 1 route, 3 inhibit rules, 1 receiver, 1 template`. **Operator/Stage 4 follow-up:** switch `bot_token` to `bot_token_file` (file rendered by `compose-render`) and inline `chat_id` as a plain integer rendered into the YAML by Ansible (or wrap with an `envsubst` entrypoint) before Stage 14 cutover.
- [x] `jq . compose/config/grafana/provisioning/dashboards/json/*.json` — all 22 JSONs parse.
- [ ] After redeploy (`make deploy` — operator), Grafana (via `tailscale serve` or port-forward) shows dashboards in the "Cashtrack" folder.
- [ ] Operator fires a test alert: `docker compose exec alertmanager amtool alert add alertname=TestAlert severity=warning` — Telegram receives the message within 30s.

### Commit

`feat(infra/observability): add prometheus rules, grafana dashboards, alertmanager config`

### Handoff

Tell operator: *"Stage 9 committed. Heads-up: Stage 4 wired `bot_token` / `chat_id` in `alertmanager.yml` as `{{ env "..." }}` template literals — Alertmanager doesn't expand env vars in YAML keys, so `amtool check-config` fails on the literal file (routing/inhibit structure verified independently with placeholders). Fix that before `make deploy`, then run `make deploy` to pick up the new Prometheus rules and dashboards, then fire the test alert per the checklist."*

---

## Stage 10 — Telegram Bots + Ofelia Schedules [CLAUDE CODE]

**Goal:** Fill in `compose.telegram.yml` with the two telegram-namespace apps — `crashers-bot` and `home-exporter` — plus any Ofelia schedules they need.

**Why two services, not one:** the existing DOKS cluster runs them as separate deployments under the `telegram-bots` namespace with separate K8s secrets. Mirroring that 1:1 in compose keeps audit logs and image releases per-app. (`home-exporter`'s exact role — Telegram bot vs Prometheus-style exporter — needs to be confirmed against the deployment YAML at task start.)

**Files:**
- Modify: `./infra/compose/compose.telegram.yml`
- Modify: `./infra/ansible/roles/compose-render/templates/crashers-bot.env.tpl` (stubbed in Stage 4 — fill with the actual env surface)
- Modify: `./infra/ansible/roles/compose-render/templates/home-exporter.env.tpl` (same)
- Create: `./infra/ansible/roles/compose-render/templates/home-exporter.config.yml.tpl` (the binary's `homes:` config; rendered via op inject because `telegramChatId` and `host` are sensitive)
- Modify: `./infra/ansible/roles/compose-render/{defaults,tasks}/main.yml` and `./infra/ansible/group_vars/all/main.yml` to add `secret_config_files` (renders non-env secret artefacts the same way `secret_files` renders env files)
- Add: Prometheus scrape entry for `home-exporter:2112` in `./infra/compose/config/prometheus/prometheus.yml`

### Action items

1. **Inspect the existing K8s deployments** to enumerate images, env vars, and any volume / port surface:
   ```bash
   kubectl -n telegram-bots get deploy crashers-bot   -o yaml > /tmp/crashers-bot.k8s.yaml
   kubectl -n telegram-bots get deploy home-exporter  -o yaml > /tmp/home-exporter.k8s.yaml
   kubectl -n telegram-bots get secret crashers-bot-secret  -o jsonpath='{.data}' | jq 'keys'
   kubectl -n telegram-bots get secret home-exporter-secret -o jsonpath='{.data}' | jq 'keys'
   ```
   Operator pastes the output into the session if the manifests don't live under `./infra/services/`.
2. **Write `compose.telegram.yml`** — both services on the shared `app` network:
   ```yaml
   services:
     crashers-bot:
       # Source repo is outside the cash-track GitHub org — image lives in the
       # personal `vovanms/*` Docker Hub namespace, pulled anonymously.
       image: vovanms/crashers_bot_api:${VERSION_CRASHERS_BOT}
       restart: unless-stopped
       networks: [app]
       env_file: [secrets/crashers-bot.env]
       depends_on:
         mysql: { condition: service_healthy }
       labels:
         - ofelia.enabled=true
         # Add ofelia.job-exec.<name>.schedule / .command labels per the
         # CronJob / scheduled task list from the K8s deployment.
       mem_limit: 256m
       mem_reservation: 128m

     home-exporter:
       # Same as above — external repo, public Docker Hub image.
       image: vovanms/home_exporter:${VERSION_HOME_EXPORTER}
       restart: unless-stopped
       networks: [app]
       env_file: [secrets/home-exporter.env]
       depends_on:
         mysql: { condition: service_healthy }
       # If home-exporter exposes /metrics, add Prometheus scrape labels and
       # a corresponding scrape job in compose/config/prometheus/prometheus.yml.
       mem_limit: 128m
       mem_reservation: 64m
   ```
   Set `mem_limit` per the K8s `resources.limits.memory` of each deployment; the values above are placeholders.

3. **Fill `crashers-bot.env.tpl`** — every K8s env var, secrets sourced from the right vault:
   ```ini
   # crashers-bot vault — fields confirmed at Stage 0 from crashers-bot-secret
   BOT_TOKEN={{ op_prefix }}/crashers-bot/BOT_TOKEN
   # ...other crashers-bot-specific keys, one line per K8s secret data key

   # mysql vault — shared cashtrack app user
   DB_HOST=mysql:3306
   DB_NAME=telegram_bots
   DB_USER={{ op_prefix }}/mysql/MYSQL_USER
   DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD
   ```
4. **Fill `home-exporter.env.tpl`** — same shape, sourcing secrets from the `home-exporter` vault. If home-exporter doesn't touch MySQL, drop the `DB_*` block.
5. **Render `home-exporter.config.yml` through op inject.** The K8s `home-exporter-config` ConfigMap embeds two sensitive values directly in YAML (`telegramChatId` and the ICMP probe `host`). Move them to 1Password (vault item `home-exporter`, fields `HOME_TELEGRAM_CHAT_ID` and `HOME_PROBE_HOST`) and add a `home-exporter.config.yml.tpl` template alongside the env templates. Register the file under `secret_config_files` in `group_vars/all/main.yml` and `compose-render/defaults/main.yml`; the role renders, op-injects, and ships it to `/opt/cashtrack/secrets/home-exporter/config.yml` (mode 0600). Mount that file in `compose.telegram.yml` at `/app/config/config.yml`.
6. **Update `group_vars/all/main.yml`** — add `versions.crashers_bot` and `versions.home_exporter` to the versions map (and reflect them as `VERSION_CRASHERS_BOT` / `VERSION_HOME_EXPORTER` in `env.tpl`). Drop any prior `versions.tg_bot` / `VERSION_TG_BOT` reference.

### Verification checklist

- [x] `docker compose -f compose.core.yml -f compose.telegram.yml config` validates with `VERSION_CRASHERS_BOT` and `VERSION_HOME_EXPORTER` set.
- [ ] After deploy, `docker compose logs crashers-bot` shows the bot connecting to Telegram (or the equivalent app-level success line). *(deferred — runtime check)*
- [ ] If home-exporter exposes metrics, `curl http://home-exporter:<port>/metrics` from another container returns Prometheus-format output and the new scrape job in Prometheus shows it `UP`. *(deferred — runtime check; scrape job added to `compose/config/prometheus/prometheus.yml` targeting `home-exporter:2112`)*
- [ ] Any Ofelia jobs registered for crashers-bot appear in `docker compose logs ofelia`. *(deferred — runtime check; one job `scheduler` wired with `0 * * * * *` running `php artisan schedule:run`, replacing the K8s `crashers-bot-scheduler` CronJob)*
- [x] No reference to `tg-bot`, `telegram-bot`, `mysql-app-users`, `TG_BOT_APP_PASSWORD`, or `VERSION_TG_BOT` remains anywhere in `./infra/`.
- [x] `compose/config/home-exporter/` no longer exists in git; the `homes:` config is rendered from `home-exporter.config.yml.tpl` via op inject and shipped to `/opt/cashtrack/secrets/home-exporter/config.yml` with mode 0600.
- [ ] On first `compose-render` run, the operator's 1Password `home-exporter` item must carry `HOME_TELEGRAM_CHAT_ID` and `HOME_PROBE_HOST` fields populated from the K8s `home-exporter-config` ConfigMap; otherwise `op inject` exits non-zero. *(deferred — operator action at first apply)*

### Commit

`feat(infra/telegram): add crashers-bot and home-exporter services`

### Handoff

Tell operator: *"Stage 10 committed. Before `make deploy`: confirm the `home-exporter` 1Password item has `HOME_TELEGRAM_CHAT_ID` and `HOME_PROBE_HOST` fields populated (they come from the K8s `home-exporter-config` ConfigMap and now drive `home-exporter.config.yml` via op inject — without them the render step fails). Then bring up crashers-bot + home-exporter and verify per checklist."*

---

## Stage 11 — `cash-track/.github` Reusable Workflows [CLAUDE CODE] + [OPERATOR-ONLY] repo creation + ACL edit

**Goal:** Create the reusable workflows repo, populate `ship-service.yml` / `ansible-apply.yml` / quality workflows. Operator creates the repo and edits the Tailscale ACL.

### Action items

1. **[OPERATOR-ONLY] Create the `cash-track/.github` repo** on GitHub. Public or internal — either works. Branch `main`.
2. **[OPERATOR-ONLY] Edit Tailscale ACLs** — add:
   ```json
   {
     "tagOwners": { "tag:ci": ["autogroup:admin"], "tag:prod-server": ["autogroup:admin"] },
     "acls": [
       { "action": "accept", "src": ["tag:ci"], "dst": ["tag:prod-server:22"] }
     ],
     "ssh": [
       { "action": "accept", "src": ["tag:ci"], "dst": ["tag:prod-server"], "users": ["ops"] }
     ]
   }
   ```
   Apply in Tailscale admin → Access Controls.
3. **[CLAUDE CODE] Write workflows in a local clone of `cash-track/.github`:**
   - `.github/workflows/build.yml` — reusable build + push (Buildx, Docker Hub login, verbatim tag, optional `:latest`, optional build-args, SLSA provenance attestation).
   - `.github/workflows/deploy.yml` — reusable tailnet-join + SSH `deploy-service` runner. Callable independently for rollback (`workflow_dispatch -f tag=v1.2.8`).
   - `.github/workflows/ansible-apply.yml` — reusable workflow; installs `op` CLI via `1password/install-cli-action@v1`, clones `infra`, runs `ansible-playbook site.yml` with `OP_SERVICE_ACCOUNT_TOKEN`.
   - `.github/workflows/quality-go.yml` — reusable for the gateway repo (go vet, go test -race, golangci-lint).
   - `.github/workflows/quality-php.yml` — reusable for the api repo (composer checks).
   - `.github/workflows/quality-node.yml` — reusable for frontend/website (npm lint, npm test).
   - `README.md` — brief usage doc for each reusable workflow.
4. **[OPERATOR-ONLY] Push** the `cash-track/.github` repo (operator commits; Claude Code can prepare the PR locally in a cloned workdir).

### Verification checklist

- [x] `cash-track/.github` repo exists with 6 workflow files (`build.yml`, `deploy.yml`, `ansible-apply.yml`, `quality-go.yml`, `quality-php.yml`, `quality-node.yml`).
- [x] Tailscale admin → ACLs → validate JSON, save.
- [x] `build.yml` and `deploy.yml` pass `actionlint`.
- [ ] Claude Code reviews (but does not submit) the PR before operator merges.

### Commit (in `cash-track/.github` repo)

`feat: add reusable build, deploy, ansible-apply, and quality workflows`

### Handoff

Tell operator: *"Stage 11 committed. Please create the GitHub repo if not already, push the branch, review, and merge. Ready for Stage 12 (service repo updates) once merged."*

---

## Stage 12 — Service-Repo `release.yml` Updates [CLAUDE CODE]

**Goal:** Point each service repo's release workflow at the new org reusable `ship-service.yml`. Retire per-repo K8s deploy plumbing.

**Repos to update:** `cash-track/api`, `cash-track/gateway`, `cash-track/frontend`, `cash-track/website`, `cash-track/mysql`, `cash-track/redis`, `cash-track/mysql-backup`.

The infra images (`mysql`, `redis`, `mysql-backup`) ship through the same `ship-service.yml`. Their compose entries reference `${VERSION_MYSQL}`, `${VERSION_REDIS}`, `${VERSION_MYSQL_BACKUP}` — keys already present in the rendered `/opt/cashtrack/.env`. The deploy-service script's `${SERVICE^^}` + `-`→`_` mapping resolves the service name to the right env var. None take `run_migrations`. Tag a release in each repo (e.g. `v1.0.9` on `cash-track/mysql`) and `release.yml` triggers the same way as the app repos.

**Deferred (not impossible):** `crashers-bot` and `home-exporter` live in repos outside the `cash-track` GitHub org (`vokomarov/*` on GitHub, `vovanms/*` on Docker Hub). For cutover they stay on the manual path — the operator bumps `versions.crashers_bot` / `versions.home_exporter` in `infra/ansible/group_vars/all/main.yml` and pushes to `cash-track/infra` to redeploy. Folding them onto the org reusable workflow is post-cutover work tracked in **Future work: Bot repo workflow consolidation** at the bottom of this document — the migration there is intentionally deferred to keep cutover scope narrow, not abandoned.

### Action items

The release pipeline is split — `release.yml` chains two reusables instead of calling one combined workflow. This preserves the existing `build.yml` / `deploy.yml` / `release.yml` per-repo shape and lets rollback skip the rebuild step.

For each repo, in a local clone:

1. **Replace `.github/workflows/release.yml`** with the chained shape:
   ```yaml
   name: release
   on:
     push:
       tags: ['v*.*.*']
   jobs:
     build:
       uses: cash-track/.github/.github/workflows/build.yml@main
       with:
         image: cashtrack/<name>
         tag:   ${{ github.ref_name }}
         build_args: |
           GIT_COMMIT=${{ github.sha }}
           GIT_TAG=${{ github.ref_name }}
       secrets: inherit
     deploy:
       needs: build
       uses: cash-track/.github/.github/workflows/deploy.yml@main
       with:
         service: <name>
         tag:     ${{ github.ref_name }}
         run_migrations: <true for api only, false otherwise>
       secrets: inherit
   ```
2. **Replace `.github/workflows/build.yml`** with a thin caller for manual rebuild (no deploy):
   ```yaml
   name: build
   on:
     workflow_dispatch:
       inputs:
         tag: { type: string, required: true }
   jobs:
     build:
       uses: cash-track/.github/.github/workflows/build.yml@main
       with:
         image: cashtrack/<name>
         tag:   ${{ inputs.tag }}
       secrets: inherit
   ```
3. **Replace `.github/workflows/deploy.yml`** (the K8s deploy) with a thin caller for rollback / redeploy:
   ```yaml
   name: deploy
   on:
     workflow_dispatch:
       inputs:
         tag:            { type: string,  required: true }
         run_migrations: { type: boolean, default: false }
   jobs:
     deploy:
       uses: cash-track/.github/.github/workflows/deploy.yml@main
       with:
         service: <name>
         tag:     ${{ inputs.tag }}
         run_migrations: ${{ inputs.run_migrations }}
       secrets: inherit
   ```
   The old K8s `deploy.yml` is renamed to `deploy-k8s.yml` and kept disabled (workflow_dispatch only) for the 48h rollback window — see Stage 13.
4. **Commit on a feature branch in each repo**: `chore(ci): migrate release.yml to cash-track/.github reusable workflows`.
5. **[OPERATOR-ONLY]** opens PRs, reviews (test builds pass), merges when Stage 11 is merged and the cutover window nears.

### Verification checklist

- [ ] Each of the 7 service repos (api, gateway, frontend, website, mysql, redis, mysql-backup) has new `release.yml`, `build.yml`, and `deploy.yml` thin-caller workflows (each ≤ 25 lines).
- [ ] The old K8s `deploy.yml` is renamed to `deploy-k8s.yml` (or removed) — never auto-fires after the cutover.
- [ ] `actionlint` clean in each repo.
- [ ] A dry-run on a scratch tag (e.g. `v0.0.0-test`) builds and pushes an image (no deploy chained), then a manual `gh workflow run deploy.yml -f tag=v0.0.0-test` SSHes to the droplet via Tailscale. Do not run migrations on scratch. This is the CI smoke test before cutover.

### Commit (per repo)

`chore(ci): migrate release.yml to cash-track/.github reusable build + deploy`

### Handoff

Tell operator: *"Stage 12 committed. PRs on each service repo. Merge after Stage 11 merges. Test deploy via a scratch tag before cutover."*

---

## Stage 13 — Disable Existing K8s Workflows (Step 1: `workflow_dispatch`) [CLAUDE CODE]

**Goal:** Remove automatic triggers from the old K8s deploy workflows in `./infra/.github/workflows/`, leaving them runnable manually via `workflow_dispatch` during the 48h observation window (per design §3 approach 2).

### Action items

1. **For each `deploy*.yml` in `./infra/.github/workflows/`**:
   - Replace the `on:` block with:
     ```yaml
     on:
       workflow_dispatch:
         inputs:
           reason:
             description: 'Why are you running this K8s deploy?'
             required: true
     ```
2. **Do NOT delete** `./infra/.github/workflows/deploy.yml` or siblings. They remain as the 48h rollback path.
3. **Do NOT modify** the new `ansible-apply.yml` / `replace-droplet.yml` / `bootstrap.yml` — those use `push` / `workflow_dispatch` as designed.

### Verification checklist

- [ ] `actionlint` clean on all workflows in `./infra/.github/workflows/`.
- [ ] In GitHub UI → Actions tab, the old workflows show a "Run workflow" button (dispatch-only).
- [ ] No push to `main` re-triggers them (verified by pushing an unrelated doc change; watch the Actions tab stays empty).

### Commit

`chore(ci): disable auto-triggers on K8s deploy workflows (workflow_dispatch only)`

### Handoff

Operator: *"Stage 13 committed. Old workflows now dispatch-only — safe to push infra changes without triggering a K8s deploy. Ready for Stage 14 (cutover) when you are."*

---

## Stage 14 — Cutover Window (OPERATOR-ONLY)

**Goal:** Execute the cutover per design §16.

**This is a live production event.** Schedule it, announce it. Do not attempt outside maintenance window.

### Pre-cutover (T-24h)

1. [ ] Stages 0-13 all green.
2. [ ] Schedule announced: ≥15 min window, low-traffic time (suggest 04:00-04:30 UTC on a weekday to align with the maintenance window pattern).
3. [ ] Backup freshness: verify K8s mysql-backup ran successfully in last 3h (`kubectl logs cronjob/mysql-backup` or check `cash-track-backups` bucket latest object).
4. [ ] 1Password desktop app signed in on operator laptop (warm cache, protects against 1P API flake mid-cutover).
5. [ ] Cloudflare: verify manual access to the DNS zone; find the existing A record for `cash-track.app`, `my.cash-track.app`, `api.cash-track.app`, `gateway.cash-track.app`. Current value: `206.189.242.130` (old LB IP).
6. [ ] Reserved IP value from terraform output noted: `RIP=$(terraform output -raw reserved_ip)`.

### Cutover execution

Follow design §16 timeline exactly:

| T | Action |
|---|---|
| T+0 | Announce downtime (#ops channel / status page if any). Scale K8s writers to 0: `kubectl scale deployment/api --replicas=0 -n cash-track` (and gateway, website, frontend). |
| T+1 | Final K8s backup: `kubectl -n cash-track exec deployment/mysql-backup -- php app.php backup`. Note the returned ID. |
| T+3 | Restore on droplet: `cd infra && ansible-playbook ansible/ops/backup-restore.yml -e backup_id=<id>`. Row-count sanity check. |
| T+5 | Flip Cloudflare A records: in CF dashboard, update `cash-track.app`, `my.cash-track.app`, `api.cash-track.app`, `gateway.cash-track.app` A records to `$RIP`. |
| T+6 | External smoke test: login flow (real browser — vovikems@gmail.com or equivalent), load wallet, create a charge, delete it. |
| T+8 | Monitor Grafana for 15 min: Traefik 5xx rate, api p95, MySQL connection count, Loki error spikes. |

### Rollback (if any smoke fails)

- Flip Cloudflare A records back to `206.189.242.130`.
- Scale K8s writers back up: `kubectl scale deployment/api --replicas=2 -n cash-track` (and gateway 2, website 1, frontend 1).
- K8s MySQL still has pre-cutover data intact (the final backup was write-frozen).
- Post-mortem: what failed on the droplet, fix before retry.

### Verification checklist

- [ ] All four domain smoke tests return 200 via real DNS.
- [ ] Login + load wallet + create charge completes end-to-end.
- [ ] `docker compose ps` on droplet — every container `healthy`.
- [ ] Grafana: zero spike in Traefik 5xx during the first 15 min.
- [ ] K8s writers remain at 0 replicas for the 48h observation window.

### Signal "done"

Operator: *"Stage 14 complete. Droplet is serving production traffic; K8s quiesced at 0 replicas."*

---

## Stage 15 — 48h Observation + Decommission (OPERATOR-ONLY + [CLAUDE CODE] for docs)

**Goal:** After 48h incident-free, tear down DOKS, move workflows to `workflows.disabled/`, rewrite `README.md`.

### Phase A — 48h observation (OPERATOR passive)

- [ ] Monitor Grafana daily for anomalies.
- [ ] Any incident escalates: either fix on the droplet or roll back via §16 DNS flip.
- [ ] No K8s changes during this window.

### Phase B — Decommission (OPERATOR-ONLY)

1. **Delete K8s workloads:**
   ```bash
   kubectl delete namespace cash-track
   kubectl delete namespace telegram-bots
   kubectl delete namespace monitoring
   ```
2. **Tear down the DOKS cluster:**
   - Via DO dashboard: Kubernetes → select `cashtrack-prod` cluster → Destroy.
   - Or `doctl kubernetes cluster delete cashtrack-prod --dangerous`.
3. **Delete the old Load Balancer:** `doctl compute load-balancer delete <id>`.
4. **Release the old LB IP** `206.189.242.130` (or leave reserved if DO charges; it may be freed automatically on LB delete).

### Phase C — Repo cleanup ([CLAUDE CODE])

1. **Move disabled workflows to `workflows.disabled/`:**
   ```bash
   cd infra
   mkdir -p .github/workflows.disabled
   git mv .github/workflows/deploy*.yml .github/workflows.disabled/
   ```
   (Keeps git history; GitHub no longer even shows them as "manually runnable".)
2. **Rewrite `README.md`** — fresh content describing ONLY the new Docker Compose infra. No "migration" narrative. Structure:
   - Overview diagram (from design §2)
   - Prerequisites (1P vault, bucket, org secrets)
   - Daily commands (`make plan`, `make apply`, `make replace`, `make deploy`)
   - Adding a new service (design §10, summarized)
   - Troubleshooting / day-2 ops (design §18, summarized)
   - Emergency SSH (design §14)
   - DR runbook pointer (design §17)
   - References: link to `README-kubernetes.md` for archival context.
3. **Delete or archive the migration design doc?** Operator decision. Default: keep `infra/migration/2026-04-21-kubernetes-to-docker-compose-design.md` as a historical architecture record. Append a line at top: `> Status: Implemented 2026-04-??. See ./README.md for current operations.`

### Verification checklist

- [ ] `doctl kubernetes cluster list` — cashtrack-prod cluster gone.
- [ ] `doctl compute load-balancer list` — old LB gone.
- [ ] `kubectl config current-context` no longer points at DOKS (optional cleanup).
- [ ] `./infra/.github/workflows/` contains only NEW workflows (ansible-apply, replace-droplet, bootstrap, quality).
- [ ] `./infra/.github/workflows.disabled/` contains the old K8s deploy workflows.
- [ ] New `README.md` makes no reference to migration, Kubernetes, or "new" infra (as if the Docker Compose stack has always been there).

### Commit

`docs(infra): replace README with docker-compose-focused content; archive old K8s workflows`

### Signal "done"

Operator: *"Migration complete."*

---

## Post-migration checkpoints

- [ ] **2 weeks out:** schedule a cleanup pass — prune unused container images on droplet, review Grafana dashboards for obvious broken panels, rotate 1P Service Account token if quarterly anniversary.
- [ ] **1 month out:** review memory pressure / IOPS alerts; if PSI has fired or IOPS sustained >50%, reconsider resize per design §5.
- [ ] **3 months out:** test a `make replace` drill — pick a low-traffic window, execute, measure actual RTO vs the 5-8 min target.

---

## Self-review notes

**Spec coverage check:** every one of design §§1-22 is represented in at least one stage above. §19 (risks) and §20 (out-of-scope) are informational — they don't map to tasks, correctly.

**Stage-sizing sanity:** stages 1, 3, 4, 5, 9 are the largest [CLAUDE CODE] stages. Stage 4 (compose + configs + env templates) is the biggest single-session load — roughly 500 lines across ~15 files. Still well under a context window. If Stage 4 bumps against limits in practice, split: 4a (compose files + Traefik config), 4b (observability configs), 4c (env templates). Don't pre-split — handle on encounter.

**Secret-handling audit:** Claude Code never reads, writes, or transits a secret value. Every secret action is either:
- Operator pastes into 1Password desktop app (Stage 0)
- Operator exports from `op` into their shell env (Stages 2, 7, 8)
- `op inject` runs on the CI runner with `OP_SERVICE_ACCOUNT_TOKEN` provided by GitHub Actions (post Stage 11)

Claude Code writes only:
- `op://` reference strings in `.env.tpl` files
- Variable names in shell/YAML (`${MYSQL_ROOT_PASSWORD}`, `secrets.OP_SERVICE_ACCOUNT_TOKEN`)
- Documentation telling the operator what to paste where

**What could slip:** the handoff between stages depends on operator signals. Without a confirmed "Stage N done", Claude Code must not start Stage N+1 assuming N worked. Build this into the session prompts: *"Before starting Stage X, confirm Stage X-1 is done by checking git log for the expected commit and asking the operator to confirm."*

---

## Future work: Bot repo workflow consolidation (post-cutover)

**Goal:** Fold `vokomarov/crashers-bot` and `vokomarov/home-exporter` onto the org reusable `ship-service.yml` so both bots ship through the same `tag → build → push → infra version bump → droplet pulls` pipeline as the cash-track-org services. **Preserve every operation the current K8s pipeline performs** — no manual hooks left dangling on the operator.

**Why deferred:** the bot repos live under a personal account (`vokomarov`), so `cash-track`'s org-level secrets cannot reach them, and the cross-org version-bump PR needs a PAT/GitHub App token. Doing this during cutover would add 4–5 secrets per repo plus a token-rotation surface to a week that already has enough moving parts. After cutover (target: 2–4 weeks post-migration), pick this up as one focused session.

### Current ops to preserve (audit of what the K8s release pipeline does today)

#### crashers-bot (Laravel HTTP bot)
From `vokomarov/crashers-bot/.github/workflows/release.yml`:

1. **Build & push** `vovanms/crashers_bot_api:<semver>` to Docker Hub on tag.
2. **Pre-deploy:** `php artisan webhook:unset` — tells Telegram to stop POSTing to the bot URL while the new pod rolls.
3. **Deploy:** new image picked up by the orchestrator (in K8s today, by `compose up -d` post-migration).
4. **Post-deploy migration:** `php artisan migrate --force` — Laravel DB migrations against the shared MySQL.
5. **Post-deploy:** `php artisan webhook:set` — re-registers the public webhook URL so Telegram resumes delivery.

Everything between (1) and (5) is mandatory per release; skip any of (2)–(5) and the bot either misses messages, runs against an outdated schema, or never re-registers.

#### home-exporter (Go ICMP exporter)
The repo currently has **no** `.github/workflows/`. Today the operator builds and pushes by hand (`make build && make push`) and edits the K8s deployment YAML. There are no Laravel-style migration or webhook hooks — just build + push + redeploy.

### Required changes in the org reusable `ship-service.yml`

Stage 11 builds `ship-service.yml` for the cash-track-org case. To accept external-repo callers without forking the workflow, generalize three things:

1. **Image namespace input.** Add an `image` input that defaults to `cashtrack/${{ inputs.service }}` but can be overridden — e.g. `vovanms/crashers_bot_api`, `vovanms/home_exporter`. The current Stage 12 template already passes `image:` explicitly, so this is mostly a matter of *not* hardcoding the namespace internally.
2. **Pre/post-deploy hook inputs.** Add optional `pre_deploy_command` and `post_deploy_command` string inputs. When set, the workflow runs them via Tailscale SSH + `docker compose exec <service> sh -c "<command>"` against the droplet. For services that don't need them (`api`, `gateway`, `frontend`, `website`, `home-exporter`), they stay empty. Only `crashers-bot` populates them.
3. **`infra` repo bump path.** The version-bump-PR step writes to `cash-track/infra`. For org-callers, the workflow's default `GITHUB_TOKEN` plus a `cash-track`-scoped GitHub App is enough. For external callers, the caller passes an `infra_pat` secret (fine-grained PAT with `contents: write` + `pull-requests: write` on `cash-track/infra`); the workflow uses it for the PR step only. Make the input optional with the GitHub App as the default.

These three generalizations also benefit the cash-track-org services — keep the inputs in the shared workflow even if no current consumer uses them yet.

### Per-bot-repo plumbing

#### Secrets to mirror into each bot repo

| Secret | Source | Used by | Notes |
|---|---|---|---|
| `DOCKER_HUB_USER` | shared `vovanms` Docker Hub account | build/push step | already configured in `vokomarov/crashers-bot` |
| `DOCKER_HUB_TOKEN` | shared `vovanms` Docker Hub account | build/push step | already configured in `vokomarov/crashers-bot` |
| `TAILSCALE_OAUTH_CLIENT_ID` | cash-track Tailscale tailnet OAuth client | SSH-into-droplet step | scoped to ephemeral nodes with the `tag:ci` ACL tag |
| `TAILSCALE_OAUTH_CLIENT_SECRET` | same | SSH-into-droplet step | rotate if either repo's secret-store is compromised |
| `INFRA_REPO_PAT` | fine-grained PAT, `vokomarov` user | infra version-bump PR | scope: `cash-track/infra` repo only, `contents: write` + `pull-requests: write`; 90-day expiry; calendar reminder to rotate |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password Service Account | only if `op inject` runs from this workflow | not needed for build/push; only needed if a future hook reads secrets |

Add these as **repository secrets** (not environment secrets) unless you're doing per-environment promotion. crashers-bot already has `DOCKER_HUB_*` and `DIGITALOCEAN_ACCESS_TOKEN` — drop the DO token after cutover, add the four new ones.

#### Container-side hooks for crashers-bot (recommended)

Bake the migration and webhook calls into the container itself, so the deploy workflow stays generic:

1. **DB migrations on container start.** Modify the entrypoint (`run` or the Dockerfile `CMD`) to run `php artisan migrate --force` before starting the worker. Idempotent; takes <2s when there are no new migrations.
2. **Webhook registration on container start.** Run `php artisan webhook:set` after migrations. Telegram's `setWebhook` is idempotent (re-registering the same URL is a no-op apart from a 200 response).
3. **Webhook unregistration on graceful shutdown.** Optional. Compose's default `SIGTERM` + 10s grace gives Laravel enough time to run a registered shutdown hook (`pcntl_signal(SIGTERM, ...)` calling `php artisan webhook:unset`). In practice this is *not* strictly required — when the new container comes up it re-registers the same URL, and Telegram retries undelivered updates for 24h. Skip this and you lose ~1–3s of message responsiveness during deploy; acceptable for a personal bot.

This eliminates the need for `pre_deploy_command` / `post_deploy_command` in the shared workflow *for crashers-bot specifically*. Keep those inputs in the shared workflow anyway — they're cheap and useful as an escape hatch for future services that can't bake hooks into the image.

#### Fallback: post-deploy hooks via the shared workflow

If you don't want to touch the bot's container image, populate the workflow inputs instead:

```yaml
# vokomarov/crashers-bot/.github/workflows/release.yml
jobs:
  ship:
    uses: cash-track/.github/.github/workflows/ship-service.yml@main
    with:
      service:              crashers-bot
      image:                vovanms/crashers_bot_api
      tag:                  ${{ github.ref_name }}
      pre_deploy_command:   "php artisan webhook:unset"
      post_deploy_command:  "php artisan migrate --force && php artisan webhook:set"
    secrets:
      DOCKER_HUB_USER:               ${{ secrets.DOCKER_HUB_USER }}
      DOCKER_HUB_TOKEN:              ${{ secrets.DOCKER_HUB_TOKEN }}
      TAILSCALE_OAUTH_CLIENT_ID:     ${{ secrets.TAILSCALE_OAUTH_CLIENT_ID }}
      TAILSCALE_OAUTH_CLIENT_SECRET: ${{ secrets.TAILSCALE_OAUTH_CLIENT_SECRET }}
      INFRA_REPO_PAT:                ${{ secrets.INFRA_REPO_PAT }}
```

Note that `secrets: inherit` does **not** work cross-account — secrets must be passed explicitly when the caller is in a different account/org from the callee.

#### home-exporter release.yml (new, doesn't exist today)

```yaml
# vokomarov/home-exporter/.github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*.*.*']
jobs:
  ship:
    uses: cash-track/.github/.github/workflows/ship-service.yml@main
    with:
      service: home-exporter
      image:   vovanms/home_exporter
      tag:     ${{ github.ref_name }}
    secrets:
      DOCKER_HUB_USER:               ${{ secrets.DOCKER_HUB_USER }}
      DOCKER_HUB_TOKEN:              ${{ secrets.DOCKER_HUB_TOKEN }}
      TAILSCALE_OAUTH_CLIENT_ID:     ${{ secrets.TAILSCALE_OAUTH_CLIENT_ID }}
      TAILSCALE_OAUTH_CLIENT_SECRET: ${{ secrets.TAILSCALE_OAUTH_CLIENT_SECRET }}
      INFRA_REPO_PAT:                ${{ secrets.INFRA_REPO_PAT }}
```

### `cash-track/.github` repo visibility

Reusable workflows can be called cross-account **only when the workflow's repo is public** (or both caller and callee are in the same org). Confirm `cash-track/.github` is public before this work starts. The deploy choreography becomes world-readable — that's fine, it contains no secret material, only how the steps are wired. Sensitive material flows in via inputs/secrets at call time.

### Action items (when ready to do this work)

1. **Generalize `ship-service.yml`** in `cash-track/.github`:
   - Add `image` input (default `cashtrack/${{ inputs.service }}`).
   - Add `pre_deploy_command` / `post_deploy_command` string inputs (default empty).
   - Add `INFRA_REPO_PAT` secret input (default empty); use the cash-track GitHub App when empty, else use the PAT.
   - Confirm `cash-track/.github` is public.
2. **(Optional but recommended)** in `vokomarov/crashers-bot`: bake `php artisan migrate --force` + `php artisan webhook:set` into the container entrypoint, ship a release, verify on the droplet.
3. **Mint the cross-org PAT.** Create a fine-grained PAT under the `vokomarov` GitHub user, scoped only to the `cash-track/infra` repo, permissions `Contents: Read and write` + `Pull requests: Read and write`, expiry 90 days. Store under both repos as `INFRA_REPO_PAT`.
4. **Mirror the four shared secrets** (`DOCKER_HUB_*`, `TAILSCALE_OAUTH_*`) into both bot repos.
5. **Replace `vokomarov/crashers-bot/.github/workflows/release.yml`** with the new `ship-service.yml`-calling version. Delete `DIGITALOCEAN_ACCESS_TOKEN` afterward.
6. **Create `vokomarov/home-exporter/.github/workflows/release.yml`** (didn't exist before) using the template above.
7. **Smoke test on a scratch tag** (`v0.0.0-test`) in each repo: confirm image push to Docker Hub, confirm PR opened against `cash-track/infra` bumping the version, confirm pre/post hooks fire on the droplet (for crashers-bot only).
8. **Document the rotation cadence** for `INFRA_REPO_PAT` in `cash-track/infra/README.md` — calendar reminder, owner, where the secret lives.

### Verification checklist

- [ ] `ship-service.yml` accepts `image`, `pre_deploy_command`, `post_deploy_command`, `INFRA_REPO_PAT` inputs without breaking existing cash-track-org callers (api/gateway/frontend/website still work).
- [ ] `cash-track/.github` is public.
- [ ] Both bot repos have `DOCKER_HUB_USER`, `DOCKER_HUB_TOKEN`, `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`, `INFRA_REPO_PAT` configured.
- [ ] crashers-bot scratch-tag run: image at `vovanms/crashers_bot_api:0.0.0-test` exists on Docker Hub; PR open against `cash-track/infra` bumping `crashers_bot`; webhook is reachable post-deploy (curl `https://crashers-bot.<DOMAIN>/` returns 200).
- [ ] crashers-bot DB migrations confirmed running (either via container entrypoint logs or post-deploy hook output in the workflow run).
- [ ] home-exporter scratch-tag run: image at `vovanms/home_exporter:0.0.0-test` exists; PR open against `cash-track/infra` bumping `home_exporter`; metrics endpoint reachable post-deploy (`curl http://home-exporter:2112/metrics` from a sibling compose service returns 200).
- [ ] Old `release.yml` in `vokomarov/crashers-bot` (with kubectl/doctl steps) deleted, not just disabled.
- [ ] `DIGITALOCEAN_ACCESS_TOKEN` removed from `vokomarov/crashers-bot` repo secrets.
- [ ] PAT rotation reminder filed in operator's calendar.

### Acceptance: 100% ops parity

The pipeline is "done" when, for both bots, a `git push --tags` triggers everything below without manual operator intervention:

- ✅ Image built and pushed to `vovanms/*` on Docker Hub.
- ✅ `cash-track/infra/ansible/group_vars/all/main.yml` bumped via auto-PR (operator merges to deploy).
- ✅ On infra PR merge: droplet pulls the new image and restarts the service via the existing `compose-up` role.
- ✅ For crashers-bot: DB migrations applied; Telegram webhook re-registered (via container entrypoint or post-deploy hook).
- ✅ Old workflow steps that only existed for K8s (`doctl`, `kubectl apply`, `kubectl exec`, `kubectl rollout status`, MySQL pod restart) are gone — the new pipeline does not depend on K8s being reachable.

If any of those bullets isn't met, the consolidation isn't done and the operator is still doing manual ops somewhere.
