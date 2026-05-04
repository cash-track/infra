{# Backup agent for the WordPress / potwora.com.ua site.
   Dumps the `potwora` MySQL database and archives /var/www/html/public
   into a single tar, then uploads to the `wp-backups-storage` Spaces bucket.
   Separate from the cash-track backup pipeline (different bucket, s3cmd not awscli). #}
MYSQL_HOST=mysql
MYSQL_PORT=3306
MYSQL_USER={{ op_prefix }}/potwora-mysql/MYSQL_USER
MYSQL_DATABASE=potwora
MYSQL_PASSWORD={{ op_prefix }}/potwora-mysql/MYSQL_PASSWORD

# DigitalOcean Spaces — dedicated bucket for WordPress backups (wp-backups-storage).
# Uses a dedicated S3 key pair scoped to this bucket only (not the shared common key).
BACKUP_BUCKET=wp-backups-storage
S3_ENDPOINT=ams3.digitaloceanspaces.com
S3_REGION=ams3
ACCESS_KEY={{ op_prefix }}/potwora-s3/S3_KEY
SECRET_KEY={{ op_prefix }}/potwora-s3/S3_SECRET
