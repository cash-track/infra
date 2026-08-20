{# Rendered by ansible/roles/compose-render into
   /opt/cashtrack/secrets/recipes-bot.env (0600, ops:ops). Non-secret values
   are literals; secrets are op:// references resolved by `op inject`. #}
APP_ENV=production
LOG_LEVEL=info
HTTP_ADDR=:8080
TEMP_DIR=/tmp/recipes

TELEGRAM_WEBHOOK_BASE_URL=https://recipes-bot.cash-track.app
TELEGRAM_DROP_PENDING_UPDATES=true

OPENAI_BASE_URL=https://api.openai.com/v1
OPENAI_MODEL=gpt-5.2
TRANSCRIBE_BASE_URL=https://api.openai.com/v1
TRANSCRIBE_MODEL=gpt-4o-transcribe

NOTION_DATABASE_TITLE=Рецепти
NOTION_VERSION=2026-03-11

WORKER_CONCURRENCY=1
WORKER_QUEUE_SIZE=8
WORKER_JOB_TIMEOUT=10m

# recipes-bot vault item
TELEGRAM_BOT_TOKEN={{ op_prefix }}/recipes-bot/TELEGRAM_BOT_TOKEN
TELEGRAM_BOT_USERNAME={{ op_prefix }}/recipes-bot/TELEGRAM_BOT_USERNAME
TELEGRAM_WEBHOOK_PATH_SECRET={{ op_prefix }}/recipes-bot/TELEGRAM_WEBHOOK_PATH_SECRET
TELEGRAM_WEBHOOK_SECRET_TOKEN={{ op_prefix }}/recipes-bot/TELEGRAM_WEBHOOK_SECRET_TOKEN
TELEGRAM_ALLOWED_CHAT_IDS={{ op_prefix }}/recipes-bot/TELEGRAM_ALLOWED_CHAT_IDS
TELEGRAM_ADMIN_CHAT_ID={{ op_prefix }}/recipes-bot/TELEGRAM_ADMIN_CHAT_ID
OPENAI_API_KEY={{ op_prefix }}/recipes-bot/OPENAI_API_KEY
TRANSCRIBE_API_KEY={{ op_prefix }}/recipes-bot/TRANSCRIBE_API_KEY
NOTION_API_KEY={{ op_prefix }}/recipes-bot/NOTION_API_KEY
NOTION_ROOT_PAGE_ID={{ op_prefix }}/recipes-bot/NOTION_ROOT_PAGE_ID
NOTION_DATA_SOURCE_ID={{ op_prefix }}/recipes-bot/NOTION_DATA_SOURCE_ID
