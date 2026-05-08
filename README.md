# Cash-Track Infrastructure

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
./ssh-prod                                          # SSH into the droplet
echo "VERSION_NEWSERVICE=1.0.0" >> /mnt/data/cashtrack.env
```

Or wipe and re-seed (all version pins reset to `group_vars` values, then CI redeploys restore live tags):

```bash
./ssh-prod rm /mnt/data/cashtrack.env
make deploy
```

## Day-to-day

Working machine must be connected to Tailscale before calling any operational commands.

### Droplet shell

SSH via Tailscale as the `ops` user. The shell drops into `/opt/cashtrack` automatically on login.

```bash
tailscale ssh ops@cashtrack-prod-0
# or just
./ssh-prod
```

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

### Services

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

## Troubleshooting

### SSH

```bash 
./ssh-prod                     # SSH into the droplet via Tailscale.
./ssh-prod docker-all ps       # docker compose ps inside the droplet
./ssh-prod docker-all logs api # check logs of specific service
```

### Exposed Services via Tailscale

The list of exposed services available via Tailscale.

- AlertManager: [http://cashtrack-prod-0:9093](http://cashtrack-prod-0:9093)
- Grafana: [http://cashtrack-prod-0:8081](http://cashtrack-prod-0:8081)
- Prometheus: [http://cashtrack-prod-0:9090](http://cashtrack-prod-0:9090)
- MySQL: `tcp://cashtrack-prod-0:3306`
- Redis: `tcp://cashtrack-prod-0:6379`
