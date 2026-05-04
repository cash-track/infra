{# Top-level .env consumed by `docker compose -f ... ${VAR}` substitution.
   No secrets — pure version pins + the deploy domain. Rendered by Ansible
   without `op inject` (no op:// references). #}
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
VERSION_POTWORA_BACKUP={{ versions.potwora_backup }}
