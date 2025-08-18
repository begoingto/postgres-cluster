#!/usr/bin/env bash
set -euo pipefail

: "${NODE_NAME:?NODE_NAME not set}"
: "${PATRONI_SCOPE:?PATRONI_SCOPE not set}"
: "${ETCD_NODES:?ETCD_NODES not set}"
: "${SUPERUSER_PASSWORD:?SUPERUSER_PASSWORD not set}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD not set}"
: "${APP_USER:?APP_USER not set}"
: "${APP_PASSWORD:?APP_PASSWORD not set}"
: "${POSTGRESQL_DATA_DIR:=/var/lib/postgresql/data}"

echo "[entrypoint] Ensuring ownership of $POSTGRESQL_DATA_DIR is set to postgres:postgres"
chown -R postgres:postgres /var/lib/postgresql
chmod 700 -R /var/lib/postgresql/data/

CONFIG_TEMPLATE="/etc/patroni/patroni.yml.template"
CONFIG_RENDERED="/etc/patroni/patroni.yml"

mkdir -p "$(dirname "$CONFIG_RENDERED")" "$POSTGRESQL_DATA_DIR"

sed \
  -e "s|\${NODE_NAME}|${NODE_NAME}|g" \
  -e "s|\${PATRONI_SCOPE}|${PATRONI_SCOPE}|g" \
  -e "s|\${ETCD_NODES}|${ETCD_NODES}|g" \
  -e "s|\${POSTGRESQL_DATA_DIR}|${POSTGRESQL_DATA_DIR}|g" \
  -e "s|\${SUPERUSER_PASSWORD}|${SUPERUSER_PASSWORD}|g" \
  -e "s|\${REPLICATION_PASSWORD}|${REPLICATION_PASSWORD}|g" \
  -e "s|\${APP_USER}|${APP_USER}|g" \
  -e "s|\${APP_PASSWORD}|${APP_PASSWORD}|g" \
  "$CONFIG_TEMPLATE" > "$CONFIG_RENDERED"

echo "[entrypoint] Starting Patroni as user: $(id -un) (uid=$(id -u)) node=${NODE_NAME}"
exec patroni "$CONFIG_RENDERED"
