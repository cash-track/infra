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



## Problem 3

Consider moving all non-cash-track app related services to different DigitalOcean droplet. Possibly linked to a different IP address. Estimate the cost of this solution comparing to a single droplet. Use the smallest droplet size possible for the other services: crashers-bot (Laravel app for telegram bot), home-exporter (small Go daemon for home internet monitoring), potwora.com.ua (wordpress app with low traffic). The apps which require DB can connect via internal DigitalOcean network to cash-track DB using different user to save resources for DB access. Observability of these apps are not so important.

