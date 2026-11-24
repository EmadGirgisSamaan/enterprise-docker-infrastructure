# Security Design

Each control below maps to a requirement of the project and shows how to verify it.
`scripts/validate.sh` runs most of these checks automatically.

## Controls

| Control | Where it is configured | How to verify |
|---|---|---|
| Non-root execution | `user:` on every service. Tomcat uses UID 10001 (created in `app/Dockerfile`). NGINX uses 101. MariaDB, Memcached and RabbitMQ use the user that ships inside their official image. | `docker compose exec app id` must not print `uid=0` |
| Linux capabilities dropped | `cap_drop: [ALL]` through the shared `x-hardened` block | `docker inspect -f '{{.HostConfig.CapDrop}}' <container>` |
| No privilege escalation | `security_opt: no-new-privileges:true` | `docker inspect -f '{{.HostConfig.SecurityOpt}}' <container>` |
| Read-only root filesystem | `read_only: true` on NGINX, Tomcat and Memcached, with `tmpfs` for the paths that need writes | `docker compose exec app touch /x` must fail |
| Network isolation | `frontend` (NGINX, Tomcat) and `backend` (Tomcat, MariaDB, Memcached, RabbitMQ). `backend` is `internal: true`. | `docker network inspect <project>_backend` shows `Internal: true` |
| Single entry point | Only NGINX has `ports:`. Nothing else publishes a host port. | `docker compose ps` |
| Secrets outside images | Compose `secrets:` read from `secrets/*.txt`. Tomcat reads them in `entrypoint.sh`. MariaDB uses the `*_FILE` variables. RabbitMQ writes them into a config file at start (`rabbitmq/entrypoint.sh`), because the image rejects `RABBITMQ_DEFAULT_PASS_FILE` as deprecated. | `docker history <image>` and `grep -r PASSWORD .` show no real values |
| Dedicated database user | The application uses `${DB_USER}`, not root. The root password is used only for backups. | `select user from mysql.user` |
| Resource limits | `mem_limit` and `cpus` on every service | `docker stats --no-stream` |
| Restart policy | `restart: unless-stopped` | `docker compose kill app`, then `docker compose ps` |
| Reproducible builds | The application source is pinned to a commit (`VPROFILE_REF`). Base images use explicit tags. | Build twice and compare |

## Writable paths on read-only containers

| Service | Writable `tmpfs` paths |
|---|---|
| nginx | `/tmp` |
| app (Tomcat) | `/tmp`, `/usr/local/tomcat/temp`, `/usr/local/tomcat/work`, `/usr/local/tomcat/logs` |
| memcached | none |

tmpfs mounts belong to root by default, so the compose file sets `uid=` and `gid=` to match the container user. Without that, a non-root process gets "permission denied".

MariaDB and RabbitMQ are not read-only because they must write to their data directories (`db_data`, `rabbitmq_data`).

## Known limitations

- **HTTP only.** TLS termination is outside the project scope. Traffic between the client and NGINX is not encrypted. Deploy in a trusted lab network, or add TLS and a certificate before any real use.
- **Docker Compose `depends_on` only orders startup.** It does not keep services available afterwards. vprofile does not implement connection retries, so restart `app` if a dependency was down while it started.
- **Restart policies do not react to `unhealthy`.** They only restart a container whose main process exits.
- **The application has no `/health` endpoint.** The Tomcat healthcheck uses `/login`, which returns HTTP 200 when the application is up.
- **The demo application ships with default accounts.** The `admin_vp` user in the vprofile sample data is for lab use only.

## Secret handling

1. `scripts/deploy.sh` generates random passwords into `secrets/*.txt`. The files are mode 644 and the `secrets/` directory is mode 700. Compose bind-mounts each file with its host permissions, and the containers run as non-root users, so a mode 600 file owned by your host user cannot be read inside the container. The private directory keeps other host users away from the files.
2. `.gitignore` excludes `.env` and `secrets/*` (only `.gitkeep` is tracked).
3. Docker mounts each secret at `/run/secrets/<name>` as a file, so the value does not appear in `docker inspect` environment output.
4. To rotate a password: stop the stack, replace the file, change the password inside MariaDB or RabbitMQ (`ALTER USER` or `rabbitmqctl change_password`), then start the stack.
5. If a credential is ever committed, rotate it immediately and remove it from the Git history with `git filter-repo`.
