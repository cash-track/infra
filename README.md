# Cash-Track Infrastructure

[![quality](https://github.com/cash-track/infra/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/cash-track/infra/actions/workflows/quality.yml)

Single-droplet Docker Compose deployment on DigitalOcean, provisioned by Terraform and configured by Ansible. Persistent state lives on an attached Block Volume; a Reserved IP fronts Cloudflare DNS.

## Layout

```
terraform/   DigitalOcean droplet, block volume, reserved IP, firewall
ansible/     Bootstrap, deploy, replace-droplet, ops playbooks
compose/     compose.{core,app,obs,telegram}.yml + service config
scripts/     bootstrap-buckets.sh, restore-to-new-volume.sh, replace-preflight.sh
```

## Commands

| Command | What it does |
|---|---|
| `make plan` | `terraform plan` — preview infra changes |
| `make apply` | `terraform apply` — apply infra changes |
| `make bootstrap` | Full `ansible-playbook site.yml` — provision or re-provision the droplet |
| `make deploy` | `ansible-playbook site.yml --tags compose` — re-render and restart Compose services only |
| `make replace` | Preflight check → replace droplet → re-bootstrap (operator action) |
| `make wait-tailnet` | Poll until the droplet joins Tailscale (used after `make apply`) |
| `make ssh-open` | Open firewall SSH for your current public IP |
| `make ssh-close` | Close firewall SSH for your current public IP |
| `make firewall-refresh` | Sync Cloudflare IP ranges into the DO firewall |
| `make traefik-cf-refresh` | Refresh Cloudflare IPs in the Traefik trusted-proxy list |
| `make backup-verify` | Restore latest backup into a scratch DB and verify integrity |
| `make restore-to-new-volume` | Restore a backup onto a new block volume (disaster recovery) |

## What changed → what to run

| Modified path | Command                     |
|---|-----------------------------|
| `terraform/` | `make plan` -> `make apply` |
| `compose/*.yml` | `make deploy`               |
| `compose/config/` | `make deploy`               |
| `ansible/roles/compose-render/` | `make deploy`               |
| `ansible/roles/compose-up/` | `make deploy`               |
| `ansible/roles/{base,docker,tailscale,volume,mysql-init}/` | `make bootstrap`            |

`make deploy` = `ansible-playbook site.yml --tags compose` — re-renders and restarts Compose services only, no system-level changes.

`make bootstrap` = full `ansible-playbook site.yml` — re-applies every role; safe to re-run but touches system packages, users, and mounts.

### `.env` and version pins

`/opt/cashtrack/.env` is a symlink to `/mnt/data/cashtrack.env` on the block volume. It survives droplet replacement; Ansible only seeds it on a fresh volume (`force: false`). After that, `deploy-service` is the sole writer — it updates individual `VERSION_*` lines in place on every CI deploy.

Consequence: if you add a new `VERSION_*` variable to `ansible/roles/compose-render/templates/env.tpl`, you must add it to the live `.env` manually after `make deploy`:

```bash
./ssh-prod # SSH into the droplet
echo "VERSION_NEWSERVICE=1.0.0" >> /mnt/data/cashtrack.env
```

Or wipe and re-seed (all version pins reset to `group_vars` values, then CI redeploys restore live tags):

```bash
./ssh-prod rm /mnt/data/cashtrack.env
make deploy
```

## Day-to-day

Working machine must be connected to Tailscale before calling any operational commands.

### Docker Compose

Five wrapper scripts are installed to `/usr/local/bin/` on the droplet. Each accepts the same arguments as `docker compose`.

| Command | Compose files |
|---|---|
| `docker-core` | `compose.core.yml` |
| `docker-app` | `compose.core.yml` + `compose.app.yml` |
| `docker-obs` | `compose.obs.yml` |
| `docker-telegram` | `compose.core.yml` + `compose.telegram.yml` |
| `docker-potwora` | `compose.core.yml` + `compose.potwora.yml` |
| `docker-all` | all five |


Examples:

```bash
docker-all ps
docker-core exec mysql mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SHOW DATABASES"
docker-obs logs -f prometheus
docker-app restart api
```

## Production

### Secrets

Secrets defined in 1Password vault `cash-track-prod`. Rendered during `make bootstrap`.

Render Terraform `backend.hcl` and init required credentials before initial cloud provisioning.

```shell
eval "$(op signin)"
cat > infra/terraform/backend.hcl <<EOF
endpoints = { s3 = "https://ams3.digitaloceanspaces.com" }
access_key                  = "$(op read op://cash-track-prod/cash-track-tfstate/ACCESS_KEY_ID)"
secret_key                  = "$(op read op://cash-track-prod/cash-track-tfstate/SECRET_ACCESS_KEY)"
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
skip_region_validation      = true
skip_s3_checksum            = true
use_path_style              = true
EOF
chmod 600 infra/terraform/backend.hcl
export DIGITALOCEAN_TOKEN="$(op read op://cash-track-prod/do-api/TOKEN)"
export TF_VAR_tailscale_api_key="$(op read op://cash-track-prod/tailscale/API_KEY)"
cd infra/terraform && terraform init -backend-config=backend.hcl
terraform plan -out=tfplan.out
```

Check `tfplan.out` for the rendered values.

### Initial Deployment

```shell
make plan
make apply
make wait-tailnet
make bootstrap
```

### Deployment

Deployment and operational processes for every service in the stack.

#### Infrastructure

```shell
make deploy               # (re) deploy docker compose stack only
make bootstrap            # fully provision server with docker compose stack and dependencies
make replace              # replace droplet with new one, reattach volume, and re-bootstrap
make firewall-refresh     # sync Cloudflare IP ranges into the DO firewall
make traefik-cf-refresh   # Refresh Cloudflare IPs in the Traefik trusted-proxy list
```

#### API

```shell
./ssh-prod deploy-service api 1.0.0    # deploy new version of docker image
./ssh-prod docker-app logs api      # get all container logs
./ssh-prod docker-app restart api      # restart backup container without redeploying
./ssh-prod docker-app exec api bash    # connect to bash shell inside container
```

Commands

```shell
./ssh-prod docker-app exec api php app.php cache:clean
./ssh-prod docker-app exec api php app.php migrate
./ssh-prod docker-app exec api php app.php newsletter:send Newsletter\\TelegramChannelMail --test 1
```

#### Gateway

```shell
./ssh-prod deploy-service gateway 1.0.0    # deploy new version of docker image
./ssh-prod docker-app logs gateway         # get all container logs
./ssh-prod docker-app restart gateway      # restart backup container without redeploying
./ssh-prod docker-app exec gateway bash    # connect to bash shell inside container
```

#### Website

```shell
./ssh-prod deploy-service website 1.0.0    # deploy new version of docker image
./ssh-prod docker-app logs website         # get all container logs
./ssh-prod docker-app restart website      # restart backup container without redeploying
./ssh-prod docker-app exec website bash    # connect to bash shell inside container
```

#### Frontend

```shell
./ssh-prod deploy-service frontend 1.0.0    # deploy new version of docker image
./ssh-prod docker-app logs frontend         # get all container logs
./ssh-prod docker-app restart frontend      # restart backup container without redeploying
./ssh-prod docker-app exec frontend bash    # connect to bash shell inside container
```

#### MySQL

```shell
./ssh-prod deploy-service mysql 1.0.0     # deploy new version of docker image
./ssh-prod docker-core logs mysql         # get all container logs
./ssh-prod docker-core restart mysql      # restart backup container without redeploying
./ssh-prod docker-core exec mysql bash    # connect to bash shell inside container
```

#### MySQL Backup

```shell
./ssh-prod deploy-service mysql-backup 1.0.0    # deploy new version of docker image
./ssh-prod docker-all logs mysql-backup         # get all container logs
./ssh-prod docker-all restart mysql-backup      # restart backup container without redeploying
```

Commands:

```bash
./ssh-prod docker-all exec mysql-backup php app.php list            # List available backups
./ssh-prod docker-all exec mysql-backup php app.php backup          # Backup right now
./ssh-prod docker-all exec mysql-backup php app.php restore <id>    # restore backup by <id>
./ssh-prod docker-all exec mysql-backup php app.php clear --days=7  # delete backups older than 7 days
./ssh-prod docker-all exec mysql-backup bash                        # connect to bash shell inside container
```

#### Redis

```shell
./ssh-prod deploy-service redis 1.0.0     # deploy new version of docker image
./ssh-prod docker-core logs redis         # get all container logs
./ssh-prod docker-core restart redis      # restart backup container without redeploying
./ssh-prod docker-core exec redis bash    # connect to bash shell inside container
```

#### Third Party Services

These services are deployed in a separate Docker Compose stack. Use `docker-telegram` wrapper to access them.

##### Crashers Bot

```shell
./ssh-prod deploy-service crashers-bot 1.0.0         # deploy new version of docker image
./ssh-prod docker-telegram logs crashers-bot         # get all container logs
./ssh-prod docker-telegram restart crashers-bot      # restart backup container without redeploying
./ssh-prod docker-telegram exec crashers-bot bash    # connect to bash shell inside
```

Launch after every deployment

```shell
./ssh-prod docker-telegram exec crashers-bot php artisan migrate --force
./ssh-prod docker-telegram exec crashers-bot php artisan webhook:set
```

##### MySQL Backup Crashers

```shell
./ssh-prod deploy-service mysql-backup-crashers 1.0.0    # deploy new version of docker image
./ssh-prod docker-telegram logs mysql-backup-crashers         # get all container logs
./ssh-prod docker-telegram restart mysql-backup-crashers      # restart backup container without redeploying
```

Commands:

```bash
./ssh-prod docker-telegram exec mysql-backup-crashers php app.php list            # List available backups
./ssh-prod docker-telegram exec mysql-backup-crashers php app.php backup          # Backup right now
./ssh-prod docker-telegram exec mysql-backup-crashers php app.php restore <id>    # restore backup by <id>
./ssh-prod docker-telegram exec mysql-backup-crashers php app.php clear --days=7  # delete backups older than 7 days
./ssh-prod docker-telegram exec mysql-backup-crashers bash                        # connect to bash shell inside container
```

##### Home Exporter

```shell
./ssh-prod deploy-service home-exporter 1.0.0         # deploy new version of docker image
./ssh-prod docker-telegram logs home-exporter         # get all container logs
./ssh-prod docker-telegram restart home-exporter      # restart backup container without redeploying
./ssh-prod docker-telegram exec home-exporter bash    # connect to bash shell inside
```

## Troubleshooting

### SSH

SSH via Tailscale as the `ops` user. The shell drops into `/opt/cashtrack` automatically on login.

```bash
tailscale ssh ops@cashtrack-prod-0
# or just
./ssh-prod

./ssh-prod docker-all ps           # docker compose ps inside the droplet
./ssh-prod docker-all logs api     # check logs of specific service
./ssh-prod docker-all logs traefik # check logs related to traffic distribution
./ssh-prod docker-all logs ofelia  # check logs related to scheduled jobs
```

If Tailscale is not working, you can open SSH to the droplet's public IP temporarily:

```bash
make ssh-open                   # Open firewall SSH for your current public IP
ssh root@<droplet-public-ip>    # SSH using the droplet's public IP
make ssh-close                  # Close firewall SSH for your current public IP
```

### Exposed Services via Tailscale

The list of exposed services available via Tailscale.

- AlertManager: [http://ct-prod-alertmanager](http://ct-prod-alertmanager)
- Grafana: [http://ct-prod-grafana:8081](http://ct-prod-grafana:8081)
- Prometheus: [http://ct-prod-prometheus](http://ct-prod-prometheus)
- MySQL: `tcp://ct-prod-mysql:3306`
- Redis: `tcp://ct-prod-redis:6379`
