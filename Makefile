.PHONY: plan apply bootstrap ssh-open ssh-close replace deploy backup-verify

plan:
	terraform -chdir=terraform plan

apply:
	terraform -chdir=terraform apply

bootstrap:
	@echo "TODO: scripts/bootstrap-buckets.sh — implemented in a later stage"
	@false

ssh-open:
	@echo "TODO: ansible-playbook ansible/ops/ssh-open.yml -e ip=$(IP) — implemented in a later stage"
	@false

ssh-close:
	@echo "TODO: ansible-playbook ansible/ops/ssh-close.yml — implemented in a later stage"
	@false

replace:
	@echo "TODO: scripts/replace-preflight.sh && ansible-playbook ansible/replace-droplet.yml — implemented in a later stage"
	@false

deploy:
	@echo "TODO: ansible-playbook ansible/deploy.yml — implemented in a later stage"
	@false

backup-verify:
	@echo "TODO: backup freshness check — implemented in a later stage"
	@false
