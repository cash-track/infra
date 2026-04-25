{# Stage 10 fills the body once the existing telegram_bots K8s secret schema is
   imported into the 1Password `crashers-bot` item. The placeholder field names
   below are the conventional ones; revise during Stage 10 to match the K8s
   secret 1:1. #}
DB_HOST=mysql:3306
DB_NAME=telegram_bots
DB_USER={{ op_prefix }}/mysql/MYSQL_USER
DB_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD

BOT_TOKEN={{ op_prefix }}/crashers-bot/BOT_TOKEN
