{# Backup agent for the crashers_bot database. Uses the dedicated crashers-bot
   MySQL user (read/write scope to crashers_bot only) and a separate Spaces bucket. #}
MYSQL_HOST=mysql
MYSQL_PORT=3306
MYSQL_USER={{ op_prefix }}/crashers-bot-mysql/MYSQL_USER
MYSQL_DATABASE=crashers_bot
MYSQL_PASSWORD={{ op_prefix }}/crashers-bot-mysql/MYSQL_PASSWORD

# Spaces / S3 destination
S3_ENDPOINT=https://ams3.digitaloceanspaces.com
S3_BUCKET=crashers-bot-backups
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID={{ op_prefix }}/common/S3_KEY
AWS_SECRET_ACCESS_KEY={{ op_prefix }}/common/S3_SECRET
