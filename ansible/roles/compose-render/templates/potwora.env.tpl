{# WordPress service env. The serversideup/php image does not auto-consume DB_*
   env vars — wp-config.php must call getenv() explicitly.
   Migration step (OPERATOR-ONLY): edit /mnt/data/potwora/public/wp-config.php
   and replace the four hardcoded define('DB_*', '...') lines with:
     define( 'DB_NAME',     getenv('DB_NAME')     ?: 'potwora' );
     define( 'DB_USER',     getenv('DB_USER')     ?: '' );
     define( 'DB_PASSWORD', getenv('DB_PASSWORD') ?: '' );
     define( 'DB_HOST',     getenv('DB_HOST')     ?: 'mysql' );
   Until then, wp-config.php continues to use its hardcoded values. #}
DB_NAME=potwora
DB_USER={{ op_prefix }}/potwora-mysql/MYSQL_USER
DB_PASSWORD={{ op_prefix }}/potwora-mysql/MYSQL_PASSWORD
DB_HOST=mysql
