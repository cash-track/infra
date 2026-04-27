# Operator-facing entry points. Targets stay thin — real logic lives in
# `terraform/`, `ansible/`, and `scripts/`.
#
# Run from the `infra/` repo root. Ansible targets cd into `ansible/` so
# `ansible.cfg` (relative inventory + roles_path) resolves correctly.

TF = terraform -chdir=terraform
AP = cd ansible && ansible-playbook

.PHONY: plan apply bootstrap replace deploy ssh-open ssh-close backup-verify firewall-refresh restore-to-new-volume

plan:
	$(TF) plan

apply:
	$(TF) apply

bootstrap:
	$(AP) site.yml

replace:
	./scripts/replace-preflight.sh
	$(TF) apply -replace='digitalocean_droplet.host[0]' -auto-approve
	$(AP) site.yml

deploy:
	$(AP) site.yml --tags compose

ssh-open:
	@test -n "$(IP)" || { echo "Usage: make ssh-open IP=<addr>"; exit 1; }
	$(AP) ops/ssh-open.yml -e ip=$(IP)

ssh-close:
	@test -n "$(IP)" || { echo "Usage: make ssh-close IP=<addr>"; exit 1; }
	$(AP) ops/ssh-close.yml -e ip=$(IP)

backup-verify:
	$(AP) ops/backup-restore.yml -e backup_id=latest -e verify_only=true

firewall-refresh:
	$(AP) ops/firewall-refresh-cf.yml

restore-to-new-volume:
	./scripts/restore-to-new-volume.sh
