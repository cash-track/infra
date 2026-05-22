# Operator-facing entry points. Targets stay thin — real logic lives in
# `terraform/`, `ansible/`, and `scripts/`.
#
# Run from the `infra/` repo root. Ansible targets cd into `ansible/` so
# `ansible.cfg` (relative inventory + roles_path) resolves correctly.

TF = terraform -chdir=terraform
AP = cd ansible && ansible-playbook
OP_RUN = DIGITALOCEAN_TOKEN=op://cash-track-prod/do-api/TOKEN \
	TF_VAR_tailscale_oauth_client_id=op://cash-track-prod/tailscale/OAUTH_CLIENT_ID \
	TF_VAR_tailscale_oauth_client_secret=op://cash-track-prod/tailscale/OAUTH_CLIENT_SECRET \
	op run --

.PHONY: plan apply wait-tailnet bootstrap replace deploy ssh-open ssh-close backup-verify backup-verify-crashers firewall-refresh traefik-cf-refresh restore-to-new-volume

plan:
	$(TF) plan

apply:
	$(TF) apply

wait-tailnet:
	@HOST=$$($(TF) output -raw tailscale_hostname) && \
	echo "Waiting for $$HOST to appear on Tailnet (5 min timeout)..." && \
	for i in $$(seq 1 60); do \
		tailscale status 2>/dev/null | grep -q "$$HOST" && echo "$$HOST is online." && exit 0; \
		echo "  [$$(date +%H:%M:%S)] not yet (attempt $$i/60)"; \
		sleep 5; \
	done; \
	echo "ERROR: $$HOST did not join Tailnet within 5 minutes." && exit 1

bootstrap:
	$(AP) site.yml

replace:
	./scripts/replace-preflight.sh
	$(TF) apply -replace='digitalocean_droplet.host[0]' -auto-approve
	$(AP) site.yml

deploy:
	$(AP) site.yml --tags compose

ssh-open:
	@IP=$${IP:-$$(curl -sf https://ifconfig.me)} && \
	test -n "$$IP" || { echo "ERROR: could not detect public IP; set IP=<addr>"; exit 1; } && \
	echo "Opening SSH for $$IP ..." && \
	cd ansible && ansible-playbook ops/ssh-open.yml -e ip=$$IP

ssh-close:
	@IP=$${IP:-$$(curl -sf https://ifconfig.me)} && \
	test -n "$$IP" || { echo "ERROR: could not detect public IP; set IP=<addr>"; exit 1; } && \
	echo "Closing SSH for $$IP ..." && \
	cd ansible && ansible-playbook ops/ssh-close.yml -e ip=$$IP

backup-verify:
	$(AP) ops/backup-restore.yml -e backup_id=latest -e verify_only=true

backup-verify-crashers:
	$(AP) ops/backup-restore-crashers.yml -e backup_id=latest -e verify_only=true

firewall-refresh:
	$(OP_RUN) $(TF) apply \
	  -target=module.firewall \
	  -refresh=false \
	  -auto-approve

traefik-cf-refresh:
	$(AP) ops/traefik-refresh-cf.yml

restore-to-new-volume:
	./scripts/restore-to-new-volume.sh
