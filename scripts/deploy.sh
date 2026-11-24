#!/usr/bin/env bash
# Prepare secrets and configuration, then build and start the stack.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Generating secrets (existing files are kept)"
mkdir -p secrets
# Compose bind-mounts secret files with their host permissions. The containers run
# as non-root users, so the files must be world-readable. The secrets/ directory
# stays private (700), which keeps other host users away from them.
chmod 700 secrets
for f in db_password db_root_password rabbitmq_password; do
  if [ ! -s "secrets/$f.txt" ]; then
    openssl rand -base64 24 | tr -d '\n=+/' > "secrets/$f.txt"
    echo "    created secrets/$f.txt"
  fi
  chmod 644 "secrets/$f.txt"
done

if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> Created .env from .env.example"
fi

echo "==> Building and starting containers"
docker compose up -d --build

echo "==> Waiting for all services to become healthy (max 5 minutes)"
for _ in $(seq 1 60); do
  unhealthy=$(docker compose ps --format '{{.Service}} {{.Health}}' | grep -vc ' healthy$' || true)
  [ "$unhealthy" -eq 0 ] && break
  sleep 5
done

docker compose ps
echo "==> Done. Open http://localhost"
