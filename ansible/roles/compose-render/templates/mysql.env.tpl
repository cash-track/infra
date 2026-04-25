{# Consumed by cashtrack/mysql image entrypoint. Matches infra/services/mysql/.secret.yml.example. #}
MYSQL_DATABASE={{ op_prefix }}/mysql/MYSQL_DATABASE
MYSQL_USER={{ op_prefix }}/mysql/MYSQL_USER
MYSQL_PASSWORD={{ op_prefix }}/mysql/MYSQL_PASSWORD
MYSQL_ROOT_PASSWORD={{ op_prefix }}/mysql/MYSQL_ROOT_PASSWORD
