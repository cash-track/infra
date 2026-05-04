# Cash-Track Infrastructure

Single-droplet Docker Compose deployment on DigitalOcean (`ams3`), provisioned by Terraform and configured by Ansible. Persistent state lives on an attached Block Volume; a Reserved IP fronts Cloudflare DNS so the droplet is replaceable without DNS changes.

## Layout

```
terraform/   DigitalOcean droplet, block volume, reserved IP, firewall
ansible/     Bootstrap, deploy, replace-droplet, ops playbooks
compose/     compose.{core,app,obs,telegram}.yml + service config
scripts/     bootstrap-buckets.sh, restore-to-new-volume.sh, replace-preflight.sh
```

The previous Kubernetes documentation is preserved in `README-kubernetes.md`; the K8s manifests under `common/` and `services/` remain dormant until decommission.

## Day-to-day

`make plan`, `make apply`, `make deploy` — full operational reference is filled in once the cutover is complete.

### Droplet shell

SSH via Tailscale as the `ops` user. The shell drops into `/opt/cashtrack` automatically on login.

```bash
tailscale ssh ops@cashtrack-prod-0
```

Shorthand command

```bash
./ssh-prod
```

### Docker Compose shorthands

Five wrapper scripts are installed to `/usr/local/bin/` on the droplet. Each accepts the same arguments as `docker compose`.

| Command | Compose files |
|---|---|
| `docker-core` | `compose.core.yml` |
| `docker-app` | `compose.core.yml` + `compose.app.yml` |
| `docker-obs` | `compose.obs.yml` |
| `docker-telegram` | `compose.core.yml` + `compose.telegram.yml` |
| `docker-all` | all four |

`docker-app` and `docker-telegram` include `compose.core.yml` because their services declare `depends_on: mysql/redis`. `docker-obs` is self-contained.

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
