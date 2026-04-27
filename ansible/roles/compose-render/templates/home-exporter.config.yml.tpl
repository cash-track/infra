{# Rendered by ansible/roles/compose-render via the same Jinja → op-inject path
   used for env templates: Jinja substitutes `op_prefix`, `op inject` resolves
   each op:// URI, and the resulting plaintext config.yml ships to
   /opt/cashtrack/secrets/home-exporter/config.yml (mode 0600). The home-exporter
   binary reads it via CONFIG_PATH=/app/config/config.yml; the file is bound from
   the secrets directory in compose.telegram.yml.

   Mirrors the K8s `home-exporter-config` ConfigMap; the per-home telegram chat
   id and probe host live in 1Password (item `home-exporter`) so they don't
   sit in plaintext under git. #}
homes:
  - name: Shulgy 1/8
    telegramChatId: {{ op_prefix }}/home-exporter/HOME_TELEGRAM_CHAT_ID
    internetStatus:
      enabled: true
      host: {{ op_prefix }}/home-exporter/HOME_PROBE_HOST
      method: icmp
      retries: 2
      timeout: 5
      interval: 5
