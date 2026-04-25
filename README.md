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
