{# Mirrors infra/services/gateway/{config.yml,deployment.yml}. The K8s gateway
   pulls CAPTCHA_SECRET from the common-secret. Domain-derived URLs are
   hardcoded for the same reason as api.env.tpl. #}
GATEWAY_ADDRESS=:8081
GATEWAY_COMPRESS=true
DEBUG_HTTP=false
TRACE_CAPTURE_BODY=true
HTTPS_ENABLED=false
CORS_ALLOWED_ORIGINS=https://cash-track.app,https://my.cash-track.app
REDIS_CONNECTION=redis:6379
CSRF_ENABLED=true

# Traefik and gateway share the same Compose bridge network.
TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128

# Cross-service URLs (matches K8s common-config bindings)
GATEWAY_URL=https://gateway.cash-track.app
API_URL=http://api:8080
WEBSITE_URL=https://cash-track.app
WEBAPP_URL=https://my.cash-track.app

# OpenTelemetry → local Tempo (OTLP gRPC, insecure within the docker network)
OTEL_SERVICE_NAME=gateway
OTEL_SERVICE_NAMESPACE=cash-track
OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4317
OTEL_EXPORTER_OTLP_INSECURE=true
OTEL_SERVICE_INSTANCE_ID=gateway

# common vault — GATEWAY_SECRET must match the api's.
CAPTCHA_SECRET={{ op_prefix }}/common/CAPTCHA_SECRET_KEY
GATEWAY_SECRET={{ op_prefix }}/common/GATEWAY_SECRET
