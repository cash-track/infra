# Alertmanager 0.27 config. Rendered by Ansible compose-render via op inject:
# `chat_id` is inlined as an integer (Alertmanager does not expand templates in
# YAML keys), and the bot token is read from a sibling file via the standard
# `bot_token_file` field. Both files live under the read-only bind-mount at
# /etc/alertmanager-secrets/ inside the container.

global:
  resolve_timeout: 5m

templates:
  - /etc/alertmanager/templates/*.tmpl

route:
  receiver: telegram
  group_by: ["alertname", "severity"]
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 30m
  routes:
    # Critical: page faster (re-send every 15m until resolved).
    - matchers:
        - severity = "critical"
      receiver: telegram
      group_wait: 0s
      repeat_interval: 15m
      continue: false
    # Warning: default cadence inherited from root, kept explicit for clarity.
    - matchers:
        - severity = "warning"
      receiver: telegram
      repeat_interval: 30m
      continue: false
    # Info: low-noise channel — re-send only every 6h.
    - matchers:
        - severity = "info"
      receiver: telegram
      repeat_interval: 6h
      continue: false

receivers:
  - name: telegram
    telegram_configs:
      - bot_token_file: /etc/alertmanager-secrets/bot_token
        chat_id: {{ op_prefix }}/alertmanager-telegram/CHAT_ID
        api_url: https://api.telegram.org
        parse_mode: HTML
        message: '{% raw %}{{ template "telegram.cash-track.message" . }}{% endraw %}'
        send_resolved: true

# Suppress lower-severity duplicates of the same alert on the same instance
# (e.g. silence HostMemoryPressure warning while a NodeHighMemoryUsage critical
# is firing for the same droplet).
inhibit_rules:
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "warning"]
    equal: ["alertname", "instance"]
  - source_matchers: [severity = "critical"]
    target_matchers: [severity = "info"]
    equal: ["alertname", "instance"]
  - source_matchers: [severity = "warning"]
    target_matchers: [severity = "info"]
    equal: ["alertname", "instance"]
