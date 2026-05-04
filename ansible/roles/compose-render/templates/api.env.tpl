{# Rendered by ansible/roles/compose-render. Jinja substitutes `op_prefix`
   (defaults to `op://cash-track-prod`) at template-render time; `op inject`
   then resolves every op:// URI into the final .env shipped to
   /opt/cashtrack/secrets/api.env (mode 0600).

   docker compose env_file lines are NOT subject to ${VAR} interpolation, so
   domain-derived URLs are hardcoded here. They mirror the K8s common-config
   bindings (`APP_URL`, `WEBSITE_URL`, `WEB_APP_URL`) and the api-config
   ConfigMap from infra/services/api/config.yml. #}
# api-config (non-secret)
APP_ENV=prod
DEBUG=false
SAFE_MIGRATIONS=true
CACHE_STORAGE=file
SCHEDULER_MUTEX_CACHE_STORAGE=file
MONOLOG_DEFAULT_LEVEL=INFO
MONOLOG_DEFAULT_CHANNEL=roadrunner
QUEUE_CONNECTION=sync
CYCLE_SCHEMA_CACHE=true
CYCLE_SCHEMA_WARMUP=true
JWT_TTL=3600
JWT_REFRESH_TTL=604800
CDN_HOST=https://storage.cash-track.app
CDN_BUCKET=cash-track-storage
MAIL_DRIVER=smtp
MAIL_SENDER_NAME=Cash Track
MAIL_SENDER_ADDRESS=support@mail.cash-track.app
CORS_ALLOWED_ORIGINS=https://cash-track.app,https://my.cash-track.app
RR_HTTP_NUM_WORKERS=6
AUTH_PASSKEY_SERVICE_ID=cash-track.app
AUTH_PASSKEY_SERVICE_NAME=Cash Track

# OpenTelemetry → local Tempo (OTLP gRPC)
TELEMETRY_DRIVER=otel
OTEL_SERVICE_NAME=api
OTEL_SERVICE_NAMESPACE=cash-track
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_EXPORTER_OTLP_CLIENT=grpc
OTEL_PHP_TRACES_PROCESSOR=simple
OTEL_EXPORTER_OTLP_ENDPOINT=tempo:4317
OTEL_SERVICE_INSTANCE_ID=api

# Cross-service URLs (matches K8s common-config)
APP_URL=https://api.cash-track.app
WEBSITE_URL=https://cash-track.app
WEB_APP_URL=https://my.cash-track.app

# In-stack endpoints
DB_HOST=mysql:3306
REDIS_CONNECTION=redis:6379

# api vault — api-only keys
JWT_SECRET={{ op_prefix }}/api/JWT_SECRET
JWT_PUBLIC_KEY={{ op_prefix }}/api/JWT_PUBLIC_KEY
JWT_PRIVATE_KEY={{ op_prefix }}/api/JWT_PRIVATE_KEY
ENCRYPTER_KEY={{ op_prefix }}/api/ENCRYPTER_KEY
DB_ENCRYPTER_KEY={{ op_prefix }}/api/DB_ENCRYPTER_KEY

# common vault — shared with gateway / website / mysql-backup
CAPTCHA_CLIENT_KEY={{ op_prefix }}/common/CAPTCHA_CLIENT_KEY
CAPTCHA_SECRET_KEY={{ op_prefix }}/common/CAPTCHA_SECRET_KEY
GOOGLE_API_CLIENT_ID={{ op_prefix }}/common/GOOGLE_API_CLIENT_ID
GOOGLE_API_CLIENT_SECRET={{ op_prefix }}/common/GOOGLE_API_CLIENT_SECRET
GOOGLE_API_PROJECT_ID={{ op_prefix }}/common/GOOGLE_API_PROJECT_ID
GOOGLE_API_AUTH_URI={{ op_prefix }}/common/GOOGLE_API_AUTH_URI
GOOGLE_API_TOKEN_URI={{ op_prefix }}/common/GOOGLE_API_TOKEN_URI
GOOGLE_API_REDIRECT_URI={{ op_prefix }}/common/GOOGLE_API_REDIRECT_URI
GOOGLE_API_AUTH_PROVIDER_X509_CERT_URL={{ op_prefix }}/common/GOOGLE_API_AUTH_PROVIDER_X509_CERT_URL
MAIL_HOST={{ op_prefix }}/common/MAIL_HOST
MAIL_PORT={{ op_prefix }}/common/MAIL_PORT
MAIL_USERNAME={{ op_prefix }}/common/MAIL_USERNAME
MAIL_PASSWORD={{ op_prefix }}/common/MAIL_PASSWORD
S3_ENDPOINT={{ op_prefix }}/common/S3_ENDPOINT
S3_REGION={{ op_prefix }}/common/S3_REGION
S3_KEY={{ op_prefix }}/common/S3_KEY
S3_SECRET={{ op_prefix }}/common/S3_SECRET

# mysql vault — api's dedicated MySQL user, scoped to cashtrack DB only (K8s remap: MYSQL_USER → DB_USER)
DB_NAME={{ op_prefix }}/mysql/MYSQL_DATABASE
DB_USER={{ op_prefix }}/mysql/MYSQL_USER
DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD
