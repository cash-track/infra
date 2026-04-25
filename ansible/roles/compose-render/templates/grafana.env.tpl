{# Grafana provisioning admin credentials + SMTP password. The grafana vault item
   only stores secrets; non-secret server settings live in the compose service
   `environment:` block or grafana.ini. #}
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD={{ op_prefix }}/grafana/ADMIN_PASSWORD
GF_SMTP_PASSWORD={{ op_prefix }}/grafana/SMTP_PASSWORD
GF_ANALYTICS_REPORTING_ENABLED=false
GF_ANALYTICS_CHECK_FOR_UPDATES=false
