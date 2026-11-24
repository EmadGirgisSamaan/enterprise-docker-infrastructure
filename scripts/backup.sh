#!/usr/bin/env bash
# Back up the MariaDB database and the RabbitMQ data volume.
# Usage:  scripts/backup.sh
# Restore (database):
#   gunzip -c backups/accounts_<timestamp>.sql.gz | \
#     docker compose exec -T db sh -c 'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" accounts'
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP=$(date +%F_%H%M)
mkdir -p backups
umask 077

echo "==> Dumping MariaDB (accounts)"
docker compose exec -T db sh -c \
  'mariadb-dump -uroot -p"$(cat /run/secrets/db_root_password)" --single-transaction --routines accounts' \
  | gzip > "backups/accounts_${STAMP}.sql.gz"

echo "==> Archiving RabbitMQ data volume"
VOL="$(docker compose ps -q rabbitmq | xargs docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/rabbitmq"}}{{.Name}}{{end}}{{end}}')"
docker run --rm -v "${VOL}:/data:ro" -v "$PWD/backups:/backup" alpine \
  tar czf "/backup/rabbitmq_${STAMP}.tar.gz" -C /data .

# Keep the 7 most recent backups of each kind
for kind in accounts rabbitmq; do
  ls -1t backups/${kind}_* 2>/dev/null | tail -n +8 | xargs -r rm --
done

ls -lh backups/*_"${STAMP}"*
echo "==> Backup finished"
