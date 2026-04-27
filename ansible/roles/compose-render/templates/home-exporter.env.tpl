{# Rendered by ansible/roles/compose-render. Mirrors the K8s telegram-bots
   `home-exporter-secret` Secret and the env literal from the deployment.
   The non-secret `homes:` config lives in compose/config/home-exporter/config.yml,
   mounted read-only at /app/config (see compose.telegram.yml). home-exporter
   does not touch MySQL — DB_* are intentionally absent. #}
CONFIG_PATH=/app/config/config.yml

# home-exporter vault — single field, matches home-exporter-secret 1:1
TELEGRAM_BOT_TOKEN={{ op_prefix }}/home-exporter/TELEGRAM_BOT_TOKEN
