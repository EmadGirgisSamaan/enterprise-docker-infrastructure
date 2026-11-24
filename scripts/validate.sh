#!/usr/bin/env bash
# Validate the deployment against the project acceptance criteria.
# Usage:  scripts/validate.sh          read-only checks
#         scripts/validate.sh --full   also tests persistence and restart (briefly restarts services)
set -u
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

SERVICES="nginx app db memcached rabbitmq"
set -a; [ -f .env ] && . ./.env; set +a

echo "== AC-01/AC-09 Containers running and healthy"
for s in $SERVICES; do
  h=$(docker compose ps --format '{{.Service}} {{.Health}}' | awk -v s="$s" '$1==s{print $2}')
  [ "$h" = "healthy" ] && ok "$s is healthy" || bad "$s health: ${h:-not running}"
done

echo "== AC-02/AC-03 Application reachable through NGINX on port 80"
code=$(curl -sL -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/ || true)
[ "$code" = "200" ] && ok "GET http://localhost/ -> 200" || bad "GET http://localhost/ -> $code"
check "NGINX health endpoint answers" \
  'docker compose exec -T nginx wget -qO- http://127.0.0.1:8080/nginx-health'

echo "== AC-04/05/06 Tomcat can reach MariaDB, Memcached, RabbitMQ"
check "app -> db01:3306"       "docker compose exec -T app bash -c 'echo > /dev/tcp/db01/3306'"
check "app -> mc01:11211"      "docker compose exec -T app bash -c 'echo > /dev/tcp/mc01/11211'"
check "app -> rmq01:5672"      "docker compose exec -T app bash -c 'echo > /dev/tcp/rmq01/5672'"
check "app DB user can query the accounts database" \
  "docker compose exec -T db sh -c 'mariadb -u\"\$MARIADB_USER\" -p\"\$(cat /run/secrets/db_password)\" accounts -e \"select count(*) from user\"'"

echo "== AC-07 Non-root execution (UID must not be 0)"
for s in $SERVICES; do
  uid=$(docker compose exec -T "$s" id -u 2>/dev/null | tr -d '\r')
  [ -n "$uid" ] && [ "$uid" != "0" ] && ok "$s runs as UID $uid" || bad "$s runs as UID '${uid:-?}'"
done

echo "== AC-08 Hardening flags"
for s in $SERVICES; do
  cid=$(docker compose ps -q "$s")
  caps=$(docker inspect -f '{{.HostConfig.CapDrop}}' "$cid")
  nnp=$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$cid")
  [[ "$caps" == *ALL* ]] && ok "$s: cap_drop ALL" || bad "$s: cap_drop is $caps"
  [[ "$nnp" == *no-new-privileges* ]] && ok "$s: no-new-privileges" || bad "$s: security_opt is $nnp"
done
for s in nginx app memcached; do
  ro=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$(docker compose ps -q "$s")")
  [ "$ro" = "true" ] && ok "$s: read-only root filesystem" || bad "$s: read-only is $ro"
done

echo "== AC-10 Network isolation"
published=$(docker compose ps --format '{{.Service}}|{{.Publishers}}' | awk -F'|' '$2 ~ /0\.0\.0\.0|::/ {print $1}' | sort -u | tr '\n' ' ')
[ "$published" = "nginx " ] && ok "only nginx publishes a host port" || bad "published services: ${published:-none}"
check "nginx cannot reach the database network (db01 must not resolve)" \
  "! docker compose exec -T nginx wget -T3 -qO- http://db01:3306"
net=$(docker network inspect "$(basename "$PWD" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '_')_backend" -f '{{.Internal}}' 2>/dev/null || echo unknown)
[ "$net" = "true" ] && ok "backend network is internal" || bad "backend network internal=$net"

echo "== AC-12 Resource limits"
for s in $SERVICES; do
  cid=$(docker compose ps -q "$s")
  mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid")
  cpu=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$cid")
  [ "$mem" != "0" ] && [ "$cpu" != "0" ] && ok "$s: memory=$mem nanocpus=$cpu" || bad "$s: missing limit (mem=$mem cpu=$cpu)"
done
docker stats --no-stream --format '    {{.Name}}: {{.MemUsage}} ({{.CPUPerc}})'

echo "== AC-13 Restart policy"
for s in $SERVICES; do
  rp=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$(docker compose ps -q "$s")")
  [ "$rp" = "unless-stopped" ] && ok "$s: restart=$rp" || bad "$s: restart=$rp"
done

echo "== AC-14 No credentials in source tree"
if grep -rIl --exclude-dir=.git --exclude-dir=secrets --exclude=db_backup.sql \
     -E '(PASSWORD|PASS)=[^$ ]+' . 2>/dev/null | grep -v '\.example$' | grep -q .; then
  bad "possible hardcoded credential found (run: grep -rnE '(PASSWORD|PASS)=' .)"
else
  ok "no hardcoded passwords in tracked files"
fi
git check-ignore -q secrets/db_password.txt 2>/dev/null && ok "secrets/ is git-ignored" || bad "secrets/ is not git-ignored (or not a git repo)"

if [ "${1:-}" = "--full" ]; then
  echo "== AC-11 Persistence (recreate containers, keep volumes)"
  before=$(docker compose exec -T db sh -c 'mariadb -u"$MARIADB_USER" -p"$(cat /run/secrets/db_password)" accounts -N -e "select count(*) from user"' | tr -d '\r')
  docker compose down >/dev/null 2>&1 && docker compose up -d >/dev/null 2>&1
  for _ in $(seq 1 60); do
    [ "$(docker compose ps --format '{{.Health}}' | grep -vc '^healthy$')" = "0" ] && break; sleep 5
  done
  after=$(docker compose exec -T db sh -c 'mariadb -u"$MARIADB_USER" -p"$(cat /run/secrets/db_password)" accounts -N -e "select count(*) from user"' | tr -d '\r')
  [ -n "$before" ] && [ "$before" = "$after" ] && ok "DB rows preserved ($before -> $after)" || bad "DB rows changed ($before -> $after)"

  echo "== AC-13 Recovery after process kill"
  docker compose kill app >/dev/null 2>&1
  sleep 10
  st=$(docker inspect -f '{{.State.Status}}' "$(docker compose ps -q app)")
  [ "$st" = "running" ] && ok "app restarted automatically" || bad "app state after kill: $st"
fi

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
