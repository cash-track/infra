{# Rendered by ansible/roles/compose-render. Mirrors the K8s telegram-bots
   `crashers-bot-config` ConfigMap, `crashers-bot-secret` Secret, and the
   shared `mysql-secret` (DB_DATABASE / DB_USERNAME / DB_PASSWORD remapping).
   In compose, the mysql + redis hostnames are service-name-on-the-app-network. #}
# crashers-bot-config (non-secret)
APP_DEBUG=false
APP_ENV=production
APP_NAME=CrasherBot
APP_URL=https://crashers-bot.cash-track.app
BROADCAST_DRIVER=null
CACHE_DRIVER=redis
DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
FILESYSTEM_DISK=local
LOG_CHANNEL=stderr
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=info
OPENAI_BASE_URL=https://api.x.ai/v1
OPENAI_MODEL=grok-3-beta
QUEUE_CONNECTION=sync
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PREFIX=CB:
SESSION_DRIVER=array
SESSION_LIFETIME=120

# crashers-bot vault — fields mirror crashers-bot-secret 1:1
APP_KEY={{ op_prefix }}/crashers-bot/APP_KEY
OPENAI_API_KEY={{ op_prefix }}/crashers-bot/OPENAI_API_KEY
OPENAI_API_KEY_CHATGPT={{ op_prefix }}/crashers-bot/OPENAI_API_KEY_CHATGPT
TELEGRAM_BOT_TOKEN={{ op_prefix }}/crashers-bot/TELEGRAM_BOT_TOKEN
TELEGRAM_BOT_USERNAME={{ op_prefix }}/crashers-bot/TELEGRAM_BOT_USERNAME
TELEGRAM_BOT_WEBHOOK={{ op_prefix }}/crashers-bot/TELEGRAM_BOT_WEBHOOK
TELEGRAM_BOT_WEBHOOK_TOKEN={{ op_prefix }}/crashers-bot/TELEGRAM_BOT_WEBHOOK_TOKEN

# mysql vault — shared cashtrack app user (K8s remap: MYSQL_DATABASE → DB_DATABASE,
# MYSQL_USER → DB_USERNAME, MYSQL_PASSWORD → DB_PASSWORD).
DB_DATABASE=telegram_bots
DB_USERNAME={{ op_prefix }}/mysql/MYSQL_USER
DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD
