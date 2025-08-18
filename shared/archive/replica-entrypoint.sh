#!/usr/bin/env bash
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:?PRIMARY_HOST not set}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICATION_USER="${REPLICATION_USER:?REPLICATION_USER not set}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:?REPLICATION_PASSWORD not set}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

ORIGINAL_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

# If PGDATA is empty (no PG_VERSION), perform a base backup from primary
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
  echo "[replica] Initializing replica data directory via pg_basebackup..."
  rm -rf "${PGDATA}"/*
  export PGPASSWORD="${REPLICATION_PASSWORD}"

  # Wait for primary to accept connections
  until pg_isready -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}"; do
    echo "[replica] Waiting for primary at ${PRIMARY_HOST}:${PRIMARY_PORT}..."
    sleep 2
  end

  pg_basebackup -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -D "${PGDATA}" -U "${REPLICATION_USER}" -Fp -Xs -P --no-slot

  # Create a replication slot name based on hostname (optional)
  SLOT_NAME="$(hostname | tr '-' '_')_slot"

  # Configure primary_conninfo & create standby.signal
  cat >> "${PGDATA}/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=${PRIMARY_HOST} port=${PRIMARY_PORT} user=${REPLICATION_USER} password=${REPLICATION_PASSWORD} application_name=$(hostname)'
primary_slot_name = '${SLOT_NAME}'
hot_standby = on
EOF

  touch "${PGDATA}/standby.signal"

  # Create slot on primary if it doesn't exist yet (best-effort)
  psql -h "${PRIMARY_HOST}" -p "${PRIMARY_PORT}" -U "${REPLICATION_USER}" -d postgres -v ON_ERROR_STOP=0 <<SQL
SELECT case when NOT EXISTS (
  SELECT 1 FROM pg_replication_slots WHERE slot_name='${SLOT_NAME}'
) THEN pg_create_physical_replication_slot('${SLOT_NAME}') END;
SQL

  echo "[replica] Base backup complete."
fi

# Ensure correct permissions
chown -R postgres:postgres "${PGDATA}"

# Exec original entrypoint (which will run postgres)
exec ${ORIGINAL_ENTRYPOINT} "$@"
