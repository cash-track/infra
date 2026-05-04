{# Mirrors infra/services/mysql-backup/{config.yml,deployment.yml}. Backup runs
   as root against mysql, uploads to Spaces. Bucket is non-secret. #}
MYSQL_HOST=mysql
MYSQL_PORT=3306
MYSQL_USER=root
MYSQL_DATABASE={{ op_prefix }}/mysql/MYSQL_DATABASE
MYSQL_PASSWORD={{ op_prefix }}/mysql/MYSQL_ROOT_PASSWORD

# Spaces / S3 destination
S3_ENDPOINT=https://ams3.digitaloceanspaces.com
S3_BUCKET=cash-track-backups
S3_REGION=us-east-1
AWS_ACCESS_KEY_ID={{ op_prefix }}/common/S3_KEY
AWS_SECRET_ACCESS_KEY={{ op_prefix }}/common/S3_SECRET
