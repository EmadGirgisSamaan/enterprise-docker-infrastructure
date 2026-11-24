#!/bin/sh
# Write the RabbitMQ default user and password into a config file from the
# Docker secret, then hand over to the image's normal entrypoint.
# (RABBITMQ_DEFAULT_USER / RABBITMQ_DEFAULT_PASS[_FILE] are rejected by this image.)
set -eu
umask 077

cat > /etc/rabbitmq/conf.d/10-credentials.conf <<EOC
default_user = ${MQ_USER}
default_pass = $(cat /run/secrets/rabbitmq_password)
EOC

exec docker-entrypoint.sh "$@"
