#!/usr/bin/env bash
#
# Simple helper script to connect to your Patroni + HAProxy PostgreSQL cluster via psql.
#
# Features:
#  - Connect to RW (leader) or RO (replica) using HAProxy endpoints (default).
#  - Optional direct multi-host failover (bypassing HAProxy) using libpq multi-host syntax.
#  - Optional Patroni REST API based discovery (to pick leader or replicas directly).
#  - Run an ad‑hoc SQL query (-q/--query) or drop into an interactive psql shell.
#  - Supports password from env var, .env file, or password file.
#  - Can generate a temporary ~/.pgpass entry.
#
# Prerequisites:
#  - psql (PostgreSQL client) installed on the machine executing this script.
#  - curl + jq if you use --discover mode (Patroni REST).
#
# Default expectations (override via arguments or env):
#  - RW endpoint: localhost:5000 (HAProxy leader)
#  - RO endpoint: localhost:5001 (HAProxy replicas)
#  - Database: postgres
#  - User: app
#
# Usage Examples:
#   ./connect.sh --mode rw                       # interactive session to leader via HAProxy
#   ./connect.sh --mode ro                       # interactive session to replica pool via HAProxy
#   ./connect.sh --mode rw --query "SELECT now();"   # run single query
#   ./connect.sh --mode auto --query "show transaction_read_only;"  # try RW then fallback to RO
#   ./connect.sh --mode rw --direct --hosts "pg-node1,pg-node2,pg-node3"
#   ./connect.sh --discover --mode rw            # ask Patroni which node is leader (direct connect)
#
# Environment overrides (can be placed in a .env file and loaded via --env-file):
#   PG_APP_USER=app
#   PG_APP_PASSWORD=app_password
#   PG_DB=postgres
#   PG_RW_ENDPOINT=localhost:5000
#   PG_RO_ENDPOINT=localhost:5001
#   PATRONI_API_NODES=pg-node1:8008,pg-node2:8008,pg-node3:8008
#
set -euo pipefail

############################
# Defaults
############################
MODE="rw"                     # rw | ro | auto
QUERY=""
DIRECT=0                      # 0 = use HAProxy endpoints, 1 = use multi-host direct libpq
DISCOVER=0                    # 1 = use Patroni REST to pick host
HOSTS=""                      # multi-host list (e.g. "pg-node1,pg-node2,pg-node3")
ENV_FILE=""
DB="${PG_DB:-postgres}"
USER_NAME="${PG_APP_USER:-app}"
PASSWORD="${PG_APP_PASSWORD:-}"
RW_ENDPOINT="${PG_RW_ENDPOINT:-localhost:5438}"
RO_ENDPOINT="${PG_RO_ENDPOINT:-localhost:5001}"
PATRONI_API_NODES="${PATRONI_API_NODES:-pg-node1:8008,pg-node2:8008,pg-node3:8008}"
PSQL_OPTS=""
NO_PGPASS=0
VERBOSE=0

SCRIPT_NAME="$(basename "$0")"

############################
usage() {
cat <<EOF
$SCRIPT_NAME - Convenience psql connector for Patroni/HAProxy cluster.

Options:
  --mode {rw|ro|auto}     Connection intent (default: rw)
  -q, --query SQL         Execute a single SQL statement then exit
  --direct                Bypass HAProxy; use multi-host libpq connection string
  --hosts LIST            Comma-separated hostnames (with implicit same port 5432) for --direct
  --hosts-with-ports LIST Comma-separated host:port entries (e.g. pg-node1:5432,pg-node2:5432)
  --discover              Use Patroni REST to discover leader or replicas (implies --direct)
  --patroni-apis LIST     Comma-separated Patroni REST endpoints (host:port) (default from env)
  --db NAME               Database name (default: ${DB})
  -U, --user USER         Username (default: ${USER_NAME})
  -W, --password PASS     Password (discouraged on CLI; prefer env or file)
  --password-file FILE    Read password from file (first line)
  --env-file FILE         Source environment variable overrides from FILE
  --psql-opts "..."       Extra options passed to psql verbatim
  --no-pgpass             Do not create ~/.pgpass entry (use PGPASSWORD inline)
  -v, --verbose           Verbose logging
  -h, --help              This help

Environment (can be in --env-file):
  PG_APP_USER, PG_APP_PASSWORD, PG_DB
  PG_RW_ENDPOINT (e.g. localhost:5000)
  PG_RO_ENDPOINT (e.g. localhost:5001)
  PATRONI_API_NODES (e.g. pg-node1:8008,pg-node2:8008,pg-node3:8008)

Examples:
  $SCRIPT_NAME --mode rw
  $SCRIPT_NAME --mode ro --query "SELECT pg_is_in_recovery();"
  $SCRIPT_NAME --discover --mode rw --query "SELECT current_setting('server_version');"
  $SCRIPT_NAME --direct --hosts "pg-node1,pg-node2,pg-node3" --mode rw
EOF
}

log() {
  if [ "$VERBOSE" -eq 1 ]; then
    echo "[$(date +'%H:%M:%S')] $*" >&2
  fi
}

fatal() {
  echo "ERROR: $*" >&2
  exit 1
}

############################
# Parse args
############################
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    -q|--query) QUERY="$2"; shift 2;;
    --direct) DIRECT=1; shift;;
    --hosts) HOSTS="$2"; shift 2;;
    --hosts-with-ports) HOSTS="$2"; shift 2;;
    --discover) DISCOVER=1; DIRECT=1; shift;;
    --patroni-apis) PATRONI_API_NODES="$2"; shift 2;;
    --db) DB="$2"; shift 2;;
    -U|--user) USER_NAME="$2"; shift 2;;
    -W|--password) PASSWORD="$2"; shift 2;;
    --password-file)
        PASSWORD="$(head -n1 "$2")"
        shift 2
        ;;
    --env-file)
        ENV_FILE="$2"
        shift 2
        ;;
    --psql-opts)
        PSQL_OPTS="$2"
        shift 2
        ;;
    --no-pgpass) NO_PGPASS=1; shift;;
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *)
        fatal "Unknown argument: $1"
        ;;
  esac
done

############################
# Load env file if specified
############################
if [ -n "$ENV_FILE" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    fatal "Env file $ENV_FILE not found"
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # Re-apply overrides if env file altered them
  DB="${PG_DB:-$DB}"
  USER_NAME="${PG_APP_USER:-$USER_NAME}"
  PASSWORD="${PG_APP_PASSWORD:-$PASSWORD}"
  RW_ENDPOINT="${PG_RW_ENDPOINT:-$RW_ENDPOINT}"
  RO_ENDPOINT="${PG_RO_ENDPOINT:-$RO_ENDPOINT}"
  PATRONI_API_NODES="${PATRONI_API_NODES:-$PATRONI_API_NODES}"
fi

############################
# Validate mode
############################
case "$MODE" in
  rw|ro|auto) ;;
  *) fatal "--mode must be rw|ro|auto";;
esac

############################
# Ensure password
############################
if [ -z "$PASSWORD" ]; then
  # Non-interactive fallback: try env PGPASSWORD set externally.
  if [ -z "${PGPASSWORD:-}" ]; then
    read -r -s -p "Password for user $USER_NAME: " PASSWORD
    echo
  fi
fi

############################
# Patroni discovery (if requested)
############################
discover_leader() {
  local api_nodes_csv="$1"
  IFS=',' read -r -a nodes <<<"$api_nodes_csv"
  for n in "${nodes[@]}"; do
    log "Querying Patroni REST at http://$n/"
    if out="$(curl -fsS "http://$n/" 2>/dev/null)"; then
      leader="$(echo "$out" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null | head -n1)"
      if [ -n "$leader" ] && [ "$leader" != "null" ]; then
        echo "$leader"
        return 0
      fi
    fi
  done
  return 1
}

discover_replicas() {
  local api_nodes_csv="$1"
  IFS=',' read -r -a nodes <<<"$api_nodes_csv"
  for n in "${nodes[@]}"; do
    if out="$(curl -fsS "http://$n/" 2>/dev/null)"; then
      echo "$out" | jq -r '.members[] | select(.role=="replica") | .name'
      return 0
    fi
  done
  return 1
}

if [ "$DISCOVER" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || fatal "jq is required for --discover"
  command -v curl >/dev/null 2>&1 || fatal "curl is required for --discover"
fi

############################
# Build connection string
############################
CONN_URL=""
if [ "$DIRECT" -eq 0 ]; then
  # Use HAProxy endpoints
  case "$MODE" in
    rw)
      host_port="$RW_ENDPOINT"
      ;;
    ro)
      host_port="$RO_ENDPOINT"
      ;;
    auto)
      # Try RW first, fallback to RO
      host_port="$RW_ENDPOINT"
      ;;
  esac
  host="${host_port%%:*}"
  port="${host_port##*:}"
  # Add target_session_attrs when connecting to RW path
  if [ "$MODE" = "rw" ] || [ "$MODE" = "auto" ]; then
    CONN_URL="postgresql://$USER_NAME:${PASSWORD}@${host}:${port}/${DB}?target_session_attrs=read-write"
  else
    CONN_URL="postgresql://$USER_NAME:${PASSWORD}@${host}:${port}/${DB}"
  fi
else
  # Direct multi-host
  if [ "$DISCOVER" -eq 1 ]; then
    leader=""
    replicas=""
    if leader="$(discover_leader "$PATRONI_API_NODES")"; then
      log "Discovered leader: $leader"
    else
      fatal "Could not discover leader via Patroni REST"
    fi
    if replicas="$(discover_replicas "$PATRONI_API_NODES")"; then
      log "Discovered replicas: $(echo "$replicas" | tr '\n' ' ')"
    fi
    case "$MODE" in
      rw)
        HOSTS="$leader"
        ;;
      ro)
        # Use replicas list; fallback to leader if none
        HOSTS="$(echo "$replicas" | paste -sd',' -)"
        [ -z "$HOSTS" ] && HOSTS="$leader"
        ;;
      auto)
        # Provide all (leader first)
        HOSTS="$leader"
        rep_line="$(echo "$replicas" | paste -sd',' -)"
        [ -n "$rep_line" ] && HOSTS="$HOSTS,$rep_line"
        ;;
    esac
  fi

  if [ -z "$HOSTS" ]; then
    fatal "--direct requires --hosts or --discover"
  fi

  # If any host has :port we assume explicit; else default 5432
  IFS=',' read -r -a host_array <<<"$HOSTS"
  host_port_list=()
  for h in "${host_array[@]}"; do
    if [[ "$h" == *:* ]]; then
      host_port_list+=("$h")
    else
      host_port_list+=("$h:5432")
    fi
  done

  # Build libpq multi-host keywords:
  # host=h1,h2 port=p1,p2 must align by position if ports differ
  hosts_csv=$(printf "%s," "${host_port_list[@]}" | sed 's/,$//')
  # Split into separate host and port lists
  hosts_only=()
  ports_only=()
  for hp in "${host_port_list[@]}"; do
    hosts_only+=("${hp%%:*}")
    ports_only+=("${hp##*:}")
  done
  host_csv=$(printf "%s," "${hosts_only[@]}" | sed 's/,$//')
  port_csv=$(printf "%s," "${ports_only[@]}" | sed 's/,$//')

  tsa_param=""
  case "$MODE" in
    rw|auto) tsa_param="target_session_attrs=read-write";;
    ro) tsa_param="target_session_attrs=any";;
  esac

  # NOTE: Putting password in URL; if you dislike this you can rely on .pgpass by using --no-pgpass=0 (default).
  CONN_URL="postgresql://${USER_NAME}:${PASSWORD}@${hosts_only[0]}:${ports_only[0]}/${DB}?${tsa_param}"
  # For multi-host libpq it's usually better to use keyword syntax; we will use psql -d "..."
  # but keep URL form for simplicity. The client will failover only if multiple hosts given
  # via keywords; so provide KEYWORD style in PSQL_CMD.
fi

############################
# .pgpass handling
############################
maybe_write_pgpass() {
  [ "$NO_PGPASS" -eq 1 ] && return 0
  local pgpass="$HOME/.pgpass"
  touch "$pgpass"
  chmod 600 "$pgpass"

  if [ "$DIRECT" -eq 0 ]; then
    # Add RW and RO endpoints
    {
      IFS=':' read -r rwhost rwport <<<"$RW_ENDPOINT"
      IFS=':' read -r rohost roport <<<"$RO_ENDPOINT"
      grep -q "^$rwhost:$rwport:$DB:$USER_NAME:" "$pgpass" || echo "$rwhost:$rwport:$DB:$USER_NAME:$PASSWORD"
      grep -q "^$rohost:$roport:$DB:$USER_NAME:" "$pgpass" || echo "$rohost:$roport:$DB:$USER_NAME:$PASSWORD"
    } >>"$pgpass"
  else
    IFS=',' read -r -a host_array <<<"$HOSTS"
    for h in "${host_array[@]}"; do
      if [[ "$h" == *:* ]]; then
        host_part="${h%%:*}"
        port_part="${h##*:}"
      else
        host_part="$h"; port_part="5432"
      fi
      grep -q "^$host_part:$port_part:$DB:$USER_NAME:" "$pgpass" || echo "$host_part:$port_part:$DB:$USER_NAME:$PASSWORD" >>"$pgpass"
    done
  fi
}

maybe_write_pgpass

############################
# Execute (auto mode fallback)
############################
run_psql() {
  local url="$1"
  if [ -n "$QUERY" ]; then
    log "Executing query on $MODE endpoint..."
    PGPASSWORD="$PASSWORD" psql $PSQL_OPTS "$url" -v ON_ERROR_STOP=1 -c "$QUERY"
  else
    log "Opening interactive psql..."
    PGPASSWORD="$PASSWORD" psql $PSQL_OPTS "$url"
  fi
}

if [ "$MODE" = "auto" ] && [ "$DIRECT" -eq 0 ]; then
  # Try RW first
  if ! run_psql "$CONN_URL"; then
    log "RW attempt failed; falling back to RO endpoint"
    CONN_URL="postgresql://$USER_NAME:${PASSWORD}@${RO_ENDPOINT%%:*}:${RO_ENDPOINT##*:}/${DB}"
    run_psql "$CONN_URL"
  fi
else
  if [ "$DIRECT" -eq 1 ]; then
    # For multi-host direct we prefer keyword syntax for real failover:
    IFS=',' read -r -a host_array <<<"$HOSTS"
    hosts_only=()
    ports_only=()
    for hp in "${host_array[@]}"; do
      hosts_only+=("${hp%%:*}")
      ports_only+=("${hp##*:}")
    done
    host_csv=$(printf "%s," "${hosts_only[@]}" | sed 's/,$//')
    port_csv=$(printf "%s," "${ports_only[@]}" | sed 's/,$//')
    case "$MODE" in
      rw|auto) tsa="read-write";;
      ro) tsa="any";;
    esac
    # Use libpq keyword DSN (safer for multiple hosts)
    KEYWORD_DSN="host=${host_csv} port=${port_csv} user=${USER_NAME} dbname=${DB} target_session_attrs=${tsa}"
    if [ -n "$QUERY" ]; then
      log "Connecting (direct multi-host) with target_session_attrs=${tsa}"
      PGPASSWORD="$PASSWORD" psql $PSQL_OPTS "$KEYWORD_DSN" -v ON_ERROR_STOP=1 -c "$QUERY"
    else
      log "Interactive multi-host connection. Hosts: $host_csv"
      PGPASSWORD="$PASSWORD" psql $PSQL_OPTS "$KEYWORD_DSN"
    fi
  else
    run_psql "$CONN_URL"
  fi
fi
