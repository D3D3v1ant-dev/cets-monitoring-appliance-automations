#!/usr/bin/env bash
set -euo pipefail

# Tactical exit-code convention used by this script:
# 0 = OK / pass
# 2 = Warning
# 5 = Informational
# any other non-zero = Error / fail
# 98 is reserved by Tactical for timeout handling.

on_error() {
  local line="$1"
  local cmd="$2"
  echo "ERROR: Monitoring stack phase failed at line ${line}: ${cmd}" >&2
  exit 1
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR

EXIT_OK=0
EXIT_WARN=2
EXIT_INFO=5
EXIT_ERROR=1

overall_code="$EXIT_OK"
overall_label="OK"
overall_rank=0

set_status() {
  local code="$1"
  local label="$2"
  local rank=0

  case "$label" in
    INFO) rank=1 ;;
    WARNING) rank=2 ;;
    ERROR) rank=3 ;;
  esac

  if (( rank > overall_rank )); then
    overall_rank="$rank"
    overall_code="$code"
    overall_label="$label"
  fi
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: This script must run as root." >&2
    exit "$EXIT_ERROR"
  fi
}

generate_secret() {
  python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(32)))
PY
}

wait_for_http() {
  local url="$1"
  local expected_regex="$2"
  local attempts="$3"
  local sleep_seconds="$4"
  local status=""

  for ((i = 1; i <= attempts; i++)); do
    status="$ (
      curl \
        --connect-timeout 2 \
        --max-time 10 \
        -k -L -s \
        -o /dev/null \
        -w '%{http_code}' \
        "$url" || true
    )"
    if [[ "$status" =~ $expected_regex ]]; then
      printf '%s' "$status"
      return 0
    fi
    sleep "$sleep_seconds"
  done

  echo "ERROR: HTTP readiness check failed for ${url}. Last status: ${status:-none}" >&2
  return 1
}

require_root

TARGET_HOSTNAME="cets-mon-poc-01"
hostname_value="$(hostname)"
if [[ "$hostname_value" != "$TARGET_HOSTNAME" ]]; then
  echo "ERROR: Expected hostname ${TARGET_HOSTNAME}, found ${hostname_value}." >&2
  exit "$EXIT_ERROR"
fi

STACK_ROOT="/opt/cets/monitoring"
LIBRENMS_ROOT="${STACK_ROOT}/librenms"
CHECKMK_ROOT="${STACK_ROOT}/checkmk"
LIBRENMS_COMPOSE="${LIBRENMS_ROOT}/compose.yaml"
CHECKMK_COMPOSE="${CHECKMK_ROOT}/compose.yaml"
LIBRENMS_ENV="${LIBRENMS_ROOT}/librenms.env"
CHECKMK_ENV="${CHECKMK_ROOT}/checkmk.env"
BOOTSTRAP_NOTE="${STACK_ROOT}/bootstrap-notes.txt"

LIBRENMS_PROJECT="cets-librenms"
CHECKMK_PROJECT="cets-checkmk"
LIBRENMS_IMAGE="librenms/librenms:latest"
CHECKMK_IMAGE="checkmk/check-mk-community:2.5.0-latest"

librenms_env_created="no"
checkmk_env_created="no"

for dir in "$STACK_ROOT" "$LIBRENMS_ROOT" "$CHECKMK_ROOT"; do
  install -d -o root -g root -m 0750 "$dir"
done

librenms_db_password=""
checkmk_password=""

if [[ -f "$LIBRENMS_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$LIBRENMS_ENV"
  librenms_db_password="${MYSQL_PASSWORD:-${DB_PASSWORD:-}}"
else
  librenms_env_created="yes"
fi

if [[ -z "$librenms_db_password" ]]; then
  librenms_db_password="$(generate_secret)"
fi

cat >"$LIBRENMS_ENV" <<EOF
TZ=Etc/UTC
PUID=1000
PGID=1000
MARIADB_RANDOM_ROOT_PASSWORD=yes
MYSQL_DATABASE=librenms
MYSQL_USER=librenms
MYSQL_PASSWORD=${librenms_db_password}
DB_HOST=db
DB_NAME=librenms
DB_USER=librenms
DB_PASSWORD=${librenms_db_password}
DB_TIMEOUT=60
REDIS_HOST=redis
LIBRENMS_BASE_URL=http://127.0.0.1:8000
EOF
chmod 0640 "$LIBRENMS_ENV"

if [[ -f "$CHECKMK_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$CHECKMK_ENV"
  checkmk_password="${CMK_PASSWORD:-}"
else
  checkmk_env_created="yes"
fi

if [[ -z "$checkmk_password" ]]; then
  checkmk_password="$(generate_secret)"
fi

cat >"$CHECKMK_ENV" <<EOF
TZ=Etc/UTC
CMK_PASSWORD=${checkmk_password}
EOF
chmod 0640 "$CHECKMK_ENV"

cat >"$LIBRENMS_COMPOSE" <<'EOF'
services:
  db:
    image: mariadb:10
    container_name: cets_librenms_db
    command:
      - mysqld
      - --innodb-file-per-table=1
      - --lower-case-table-names=0
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
    env_file:
      - ./librenms.env
    volumes:
      - cets_librenms_db:/var/lib/mysql
    restart: unless-stopped

  redis:
    image: redis:7.2-alpine
    container_name: cets_librenms_redis
    env_file:
      - ./librenms.env
    restart: unless-stopped

  librenms:
    image: librenms/librenms:latest
    container_name: cets_librenms
    hostname: librenms
    cap_add:
      - NET_ADMIN
      - NET_RAW
    depends_on:
      - db
      - redis
    env_file:
      - ./librenms.env
    ports:
      - 127.0.0.1:8000:8000
    volumes:
      - cets_librenms_data:/data
    restart: unless-stopped

  dispatcher:
    image: librenms/librenms:latest
    container_name: cets_librenms_dispatcher
    hostname: librenms-dispatcher
    cap_add:
      - NET_ADMIN
      - NET_RAW
    depends_on:
      - librenms
      - redis
    env_file:
      - ./librenms.env
    environment:
      DISPATCHER_NODE_ID: dispatcher1
      SIDECAR_DISPATCHER: "1"
    volumes:
      - cets_librenms_data:/data
    restart: unless-stopped

volumes:
  cets_librenms_db:
  cets_librenms_data:
EOF
chmod 0640 "$LIBRENMS_COMPOSE"

cat >"$CHECKMK_COMPOSE" <<'EOF'
services:
  checkmk:
    image: checkmk/check-mk-community:2.5.0-latest
    container_name: cets_checkmk
    env_file:
      - ./checkmk.env
    tmpfs:
      - /opt/omd/sites/cmk/tmp:uid=1000,gid=1000
    ports:
      - 127.0.0.1:8080:5000
    volumes:
      - cets_checkmk_sites:/omd/sites
    restart: unless-stopped

volumes:
  cets_checkmk_sites:
EOF
chmod 0640 "$CHECKMK_COMPOSE"

cat >"$BOOTSTRAP_NOTE" <<EOF
CETS Monitoring Appliance bootstrap notes
Generated on: $(date --iso-8601=seconds)

LibreNMS:
- Base URL: http://127.0.0.1:8000
- Env file: ${LIBRENMS_ENV}
- Database password is stored in the env file above.

Checkmk:
- Base URL: http://127.0.0.1:8080/cmk/check_mk/
- Env file: ${CHECKMK_ENV}
- Initial cmkadmin password is stored in the env file above.

These files are root-readable only and must not be committed to version control.
EOF
chmod 0640 "$BOOTSTRAP_NOTE"

memory_total_mb="$(free -m | awk '/^Mem:/ {print $2}')"
available_mb="$(free -m | awk '/^Mem:/ {print $7}')"
if (( memory_total_mb < 3072 )); then
  set_status "$EXIT_INFO" "INFO"
fi

echo "=== CETS MONITORING APPLIANCE MONITORING STACK ==="
echo "Hostname: ${hostname_value}"
echo "Timestamp: $(date --iso-8601=seconds)"
echo "Stack root: ${STACK_ROOT}"

echo
echo "=== PRE-FLIGHT ==="
echo "Docker version: $(docker --version)"
echo "Docker compose version: $(docker compose version)"
echo "Memory total (MiB): ${memory_total_mb}"
echo "Memory available before deploy (MiB): ${available_mb}"
echo "LibreNMS env created this run: ${librenms_env_created}"
echo "Checkmk env created this run: ${checkmk_env_created}"
echo "Bootstrap note: ${BOOTSTRAP_NOTE}"
if (( memory_total_mb < 3072 )); then
  echo "INFO: Host memory is below 3 GiB; stack was deployed for POC validation but should be watched for capacity pressure."
fi

echo
echo "=== LIBRENMS DEPLOY ==="
timeout --foreground 900 docker pull "$LIBRENMS_IMAGE"
(cd "$LIBRENMS_ROOT" && docker compose -p "$LIBRENMS_PROJECT" -f "$LIBRENMS_COMPOSE" up -d)
librenms_http_status="$(wait_for_http "http://127.0.0.1:8000/" '^(200|302|303)$' 90 5)"
echo "LibreNMS HTTP status: ${librenms_http_status}"

echo
echo "=== CHECKMK DEPLOY ==="
timeout --foreground 900 docker pull "$CHECKMK_IMAGE"
(cd "$CHECKMK_ROOT" && docker compose -p "$CHECKMK_PROJECT" -f "$CHECKMK_COMPOSE" up -d)
checkmk_http_status="$(wait_for_http "http://127.0.0.1:8080/cmk/check_mk/login.py" '^(200|302|303)$' 120 5)"
echo "Checkmk HTTP status: ${checkmk_http_status}"

echo
echo "=== STACK STATUS ==="
docker ps --format 'NAME={{.Names}} IMAGE={{.Image}} STATUS={{.Status}} PORTS={{.Ports}}' | grep '^NAME='
echo "--- LibreNMS compose ps ---"
(cd "$LIBRENMS_ROOT" && docker compose -p "$LIBRENMS_PROJECT" -f "$LIBRENMS_COMPOSE" ps)
echo "--- Checkmk compose ps ---"
(cd "$CHECKMK_ROOT" && docker compose -p "$CHECKMK_PROJECT" -f "$CHECKMK_COMPOSE" ps)

if [[ -f /var/run/reboot-required ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "LibreNMS URL: http://127.0.0.1:8000"
echo "Checkmk URL: http://127.0.0.1:8080/cmk/check_mk/"
echo "LibreNMS HTTP status: ${librenms_http_status}"
echo "Checkmk HTTP status: ${checkmk_http_status}"
echo "LibreNMS env created this run: ${librenms_env_created}"
echo "Checkmk env created this run: ${checkmk_env_created}"
echo "Low-memory advisory: $( (( memory_total_mb < 3072 )) && echo yes || echo no )"
echo "Reboot required: $(test -f /var/run/reboot-required && echo yes || echo no)"

echo
case "$overall_label" in
  OK)
    echo "Monitoring stack deployment completed successfully."
    ;;
  INFO)
    echo "Monitoring stack deployment completed with informational findings."
    ;;
  WARNING)
    echo "Monitoring stack deployment completed with warning findings."
    ;;
  *)
    echo "Monitoring stack deployment completed with error findings."
    ;;
esac

exit "$overall_code"
