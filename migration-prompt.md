Use superpowers brainstorming skill

Generate step by step the migration plan to move existing infrastructure from Kubernetes to standalone Docker setup (maybe Docker Compose) in a single DigitalOcean droplet for cost saving. Split the plan for functional stages for smooth migration without data loss and seamless experience. Do not overcomplicate the resulting infrastructure. Before generating a plan, describe the end state of the infrastructure and key details for working with the infrastructure after migration.

To understand better what is expected - investigate current infrastructure in `./infra` directory. You can use `kubectl` or `doctl` command line tools for current inrastructure lookup (local access configured) (read only !).

Existing infrastructure uses DigitalOcean Kubernetes for workload deployment. Incoming requests coming from CloudFlage to Digital Ocean Load balancer (mapped with Kubernetes Ingress) then routed to workload pods.

Infrastructure Requirements:
- DigitalOcean Droplet for workload deployment (configurable amount with configurable size, starting with a single droplet).
- DigitalOcean Spaces for static resources and DB backups storage (already created and used).
- DigitalOcean reserved IP that can be assigned to a Droplet. To avoid CloudFlage DNS modification in case of Droplet replacement.
- Propose a solution for persistent storage like MySQL/Redis DB.

Functional Requirements:
- Ability to configure basic infrastructure parameters: Digital Ocean region, Droplet size, amount of Droplets, etc.
- Ability to quickly redeploy entire infrastructure in case Droplet replacement is needed. Minimal commands.
- Ability to implement a CI / CD pipeline using GitHub Actions as it is working today with Kubernetes.
- No need to use Github Actions Runner anymore, we will switch back to Github Runners.
- No data loss is expected during droplet replacement. Explore the best way for persistent storage like MySQL/Redis DB.
- A way to organise GitHub Actions workflows in a single place reused in other repositories of the same GitHub organisation. 
- Secured and automated way to deliver secrets to workload containers.
- TLS certificates are managed by Cloud Flare
- External access allowed only from CloudFlare.
- Access to the services inside DrigitalOcean network is allowed through TailScale (already used in Kubernetes).

Technical Suggestions:

Consider using next tools / technologies:
- use `terraform` for infrastructure provisioning.
- use `ansible` for server configuration.
- use `docker` for workload deployment.
- Prometheus, Grafana, Loki, Tempo, Alertmanager for observability.

Local tools has already access configured to respective accounts where everything would be provisioned:
- `doctl` for DigitalOcean
- `kubectl` for Kubernetes (for existing infrastructure check)

Use devops-engineer, sre-engineer, terraform-engineer, terraform-skill skills.

Output end result in `./infra/migration/` directory for review.



## Problem 1 (after final stages before applying migration)

I found many differences between observability services configuration created for Docker env comparing with existing configuration in Kubernetes env. Specifically `alertmanager`, `grafana`, `grafana-loki`, `grafana-tempo`, `prometheus`, `promtail. Review observability services configuration and compare old kubernetes configuration with new docker configuration. Execute full configuration audit. The services should have exactly the same configuration except different networking configurations and new environment resources aspects.

## Problem 2

Existing kubernetes infrastructure serves traffic for two domains: `cash-track.app`, `potwora.com.ua`. The infrastructure for the first domain is the original target of the migration plan, this includes security enforcements like TLS certificate pinning between CloudFlare and DigitalOcean (Origin Certificate). Whereas second domain is Wordpress website with single docker container (planned to be migrated after, but architecture needs to consider the fact of one more domain). Both domains configured in CloudFlare as separated projects, so their Origin Certificates also different (currently no origin certificates created for `potwora.com.ua`). When Traefic will be configured to allow traffic from Cloudflare only for one Origin Certificate created under `cash-track.app`, the traffic for `potwora.com.ua` should be still allowed to go through from CloudFlare to DigitalOcean. It is acceptable to use Origin Certificate for `cash-track.app` and omit for `potwora.com.ua` if possible. Preferrable to create two Origin Certificates and use in Traefik (if possible technically). Consider the best approach to comply with the requirements.
