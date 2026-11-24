#!/bin/sh
# Load credentials from Docker secret files into the environment,
# then start Tomcat in the foreground (exec keeps signals working).
set -eu

export DB_PASSWORD="$(cat /run/secrets/db_password)"
export RABBITMQ_PASSWORD="$(cat /run/secrets/rabbitmq_password)"

exec catalina.sh run
