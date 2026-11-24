# Troubleshooting

Start with these two commands:

```bash
docker compose ps
docker compose logs --tail=100 <service>
```

## Startup and permissions

| Symptom | Likely cause | Fix |
|---|---|---|
| `variable is not set` warning | `.env` is missing | `cp .env.example .env`, or run `scripts/deploy.sh` |
| `secret file ... not found` | `secrets/*.txt` not generated | Run `scripts/deploy.sh` |
| NGINX exits with "Permission denied" on `/tmp` or the PID file | tmpfs owned by root | Keep `uid=101,gid=101` on the nginx `tmpfs` entry |
| Tomcat logs "Permission denied" for `work`, `temp` or `logs` | tmpfs owned by root | Keep `uid=10001,gid=10001` on the Tomcat `tmpfs` entries |
| Tomcat loops on startup after enabling `read_only` | A writable path is missing | Read the log for the path, then add it to `tmpfs` |
| MariaDB restarts after enabling `user: mysql` or `cap_drop` | Volume created earlier with root ownership, or a capability is needed | Test with `docker compose down -v` first (this deletes data). If it still fails, add `cap_add: [CHOWN, SETUID, SETGID, DAC_OVERRIDE]` to `db` |
| RabbitMQ restarts with `RABBITMQ_DEFAULT_PASS_FILE is set but deprecated` | This image rejects the `RABBITMQ_DEFAULT_*` variables | Already handled by `rabbitmq/entrypoint.sh`. Do not add those variables back |
| `Permission denied` reading `/run/secrets/...` (MariaDB, Tomcat or RabbitMQ restarting) | Secret files are mode 600 and owned by the host user | `chmod 644 secrets/*.txt` (keep `chmod 700 secrets`), then `docker compose up -d` |
| RabbitMQ exits with an Erlang cookie error | Old volume with different ownership | `docker compose down`, remove `rabbitmq_data`, start again |
| Port 80 already in use | Another service is listening | Change `"80:8080"` to `"8081:8080"` |

## Health checks

| Symptom | Likely cause | Fix |
|---|---|---|
| `app` stays `starting` for minutes | Maven-built app is slow on first boot | Wait for `start_period` (90s). Check `docker compose logs app` |
| `app` is `unhealthy` | `/login` does not return 200, or `curl` is missing | `docker compose exec app curl -i http://localhost:8080/login` |
| `memcached` is `unhealthy` | `nc` missing in the image | Use the `-alpine` tag, or switch the check to `/dev/tcp` |
| `db` never becomes healthy | Init script is still importing, or a credential mismatch | `docker compose logs db`. After a password change, recreate the volume |

## Connectivity

| Symptom | Likely cause | Fix |
|---|---|---|
| `502 Bad Gateway` | Tomcat is still starting or crashed | `docker compose logs app`, wait for `healthy` |
| Application cannot reach the database | Tomcat started before MariaDB recovered | `docker compose restart app` |
| Login page loads but login fails | Database was not initialised | The SQL runs only on an empty volume. `docker compose down -v` then `up -d` |
| `curl http://localhost` prints nothing | `/` redirects to `/login` | Use `curl -L http://localhost` |

## Useful diagnostics

```bash
docker compose exec app id                                  # must not be uid=0
docker compose exec app bash -c 'echo > /dev/tcp/db01/3306 && echo db ok'
docker compose exec nginx wget -qO- http://127.0.0.1:8080/nginx-health
docker inspect -f '{{.State.Health.Status}}' $(docker compose ps -q app)
docker inspect -f '{{json .State.Health.Log}}' $(docker compose ps -q app)
docker stats --no-stream
```

## Safe hardening workflow

If a service breaks after adding a restriction, relax one control at a time:

1. Remove `read_only: true` and check whether the service starts.
2. Remove `cap_drop`, then add back only the capabilities the logs ask for.
3. Check volume ownership with `docker run --rm -v <volume>:/d alpine ls -ln /d`.
4. Re-apply the restrictions one by one and re-run `scripts/validate.sh`.
