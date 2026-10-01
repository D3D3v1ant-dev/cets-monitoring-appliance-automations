#!/usr/bin/env bash
set -euo pipefail

# Tactical exit-code convention used by this script:
# 0 = OK / pass
# 2 = Warning
# 5 = Informational
# any other non-zero = Error / fail
# 98 is reserved by Tactical for timeout handling.

# Tactical global key store inputs for this phase:
#
# Add these as Tactical global custom fields / key-store entries, then map them
# into the script action as environment variables exactly as shown below.
#
# LibreNMS database credentials:
#   LIBRENMS_DB_USERNAME={{global.cets_lnms_db_user}}
#   LIBRENMS_DB_PASSWORD={{global.cets_lnms_db_pass}}
#
# LibreNMS web admin bootstrap credentials:
#   LIBRENMS_ADMIN_USERNAME={{global.cets_lnms_admin_user}}
#   LIBRENMS_ADMIN_PASSWORD={{global.cets_lnms_admin_pass}}
#
# Checkmk web login credentials:
#   CHECKMK_USERNAME={{global.cets_cmk_user}}
#   CHECKMK_PASSWORD={{global.cets_cmk_pass}}
#
# Shared monitoring alert recipient:
#   ALERT_RECIPIENT={{global.cets_alert_email}}
#
# Note: Checkmk's official Docker image uses CMK_PASSWORD for the built-in
# cmkadmin user. CHECKMK_USERNAME is kept visible here for operator notes and
# should normally be set to cmkadmin.

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
    status="$(
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

TACTICAL_LIBRENMS_DB_USERNAME="${LIBRENMS_DB_USERNAME:-${LIBRENMS_DB_USER:-}}"
TACTICAL_LIBRENMS_DB_PASSWORD="${LIBRENMS_DB_PASSWORD:-}"
TACTICAL_LIBRENMS_ADMIN_USERNAME="${LIBRENMS_ADMIN_USERNAME:-}"
TACTICAL_LIBRENMS_ADMIN_PASSWORD="${LIBRENMS_ADMIN_PASSWORD:-}"
TACTICAL_CHECKMK_USERNAME="${CHECKMK_USERNAME:-cmkadmin}"
TACTICAL_CHECKMK_PASSWORD="${CHECKMK_PASSWORD:-${CMK_PASSWORD:-}}"
ALERT_RECIPIENT="${ALERT_RECIPIENT:-it@cets.com.au}"
LOCAL_SMTP_RELAY_HOST="${LOCAL_SMTP_RELAY_HOST:-host.docker.internal}"
LOCAL_SMTP_RELAY_PORT="${LOCAL_SMTP_RELAY_PORT:-25}"

librenms_env_created="no"
checkmk_env_created="no"
librenms_admin_bootstrap="not-requested"

for dir in "$STACK_ROOT" "$LIBRENMS_ROOT" "$CHECKMK_ROOT"; do
  install -d -o root -g root -m 0750 "$dir"
done

librenms_db_username=""
librenms_db_password=""
librenms_admin_username="$TACTICAL_LIBRENMS_ADMIN_USERNAME"
librenms_admin_password="$TACTICAL_LIBRENMS_ADMIN_PASSWORD"
checkmk_username="$TACTICAL_CHECKMK_USERNAME"
checkmk_password=""

if [[ -f "$LIBRENMS_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$LIBRENMS_ENV"
  librenms_db_username="${MYSQL_USER:-${DB_USER:-}}"
  librenms_db_password="${MYSQL_PASSWORD:-${DB_PASSWORD:-}}"
else
  librenms_env_created="yes"
fi

if [[ -n "$TACTICAL_LIBRENMS_DB_USERNAME" ]]; then
  librenms_db_username="$TACTICAL_LIBRENMS_DB_USERNAME"
fi

if [[ -z "$librenms_db_username" ]]; then
  librenms_db_username="librenms"
fi

if [[ -n "$TACTICAL_LIBRENMS_DB_PASSWORD" ]]; then
  librenms_db_password="$TACTICAL_LIBRENMS_DB_PASSWORD"
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
MYSQL_USER=${librenms_db_username}
MYSQL_PASSWORD=${librenms_db_password}
DB_HOST=db
DB_NAME=librenms
DB_USER=${librenms_db_username}
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

if [[ -n "$TACTICAL_CHECKMK_PASSWORD" ]]; then
  checkmk_password="$TACTICAL_CHECKMK_PASSWORD"
fi

if [[ -z "$checkmk_password" ]]; then
  checkmk_password="$(generate_secret)"
fi

if [[ "$checkmk_username" != "cmkadmin" ]]; then
  echo "WARNING: Checkmk Docker login user is cmkadmin; requested CHECKMK_USERNAME=${checkmk_username} will be recorded only." >&2
  set_status "$EXIT_WARN" "WARNING"
fi

cat >"$CHECKMK_ENV" <<EOF
TZ=Etc/UTC
CHECKMK_USERNAME=${checkmk_username}
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
    extra_hosts:
      - host.docker.internal:host-gateway
    volumes:
      - cets_librenms_db:/var/lib/mysql
    restart: unless-stopped

  redis:
    image: redis:7.2-alpine
    container_name: cets_librenms_redis
    env_file:
      - ./librenms.env
    extra_hosts:
      - host.docker.internal:host-gateway
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
    extra_hosts:
      - host.docker.internal:host-gateway
    ports:
      - 0.0.0.0:8000:8000
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
    extra_hosts:
      - host.docker.internal:host-gateway
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
    extra_hosts:
      - host.docker.internal:host-gateway
    environment:
      MAIL_RELAY_HOST: host.docker.internal
    tmpfs:
      - /opt/omd/sites/cmk/tmp:uid=1000,gid=1000
    ports:
      - 0.0.0.0:8080:5000
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
- Published URL: http://<any-interface-ip>:8000
- Env file: ${LIBRENMS_ENV}
- Database username: ${librenms_db_username}
- Database password is stored in the env file above.
- Web admin username: ${librenms_admin_username:-not configured by this phase}
- Web admin password source: $(test -n "$librenms_admin_password" && echo "Tactical global key store" || echo "not configured by this phase")
- SMTP relay: ${LOCAL_SMTP_RELAY_HOST}:${LOCAL_SMTP_RELAY_PORT}
- Alert recipient: ${ALERT_RECIPIENT}

Checkmk:
- Base URL: http://127.0.0.1:8080/cmk/check_mk/
- Published URL: http://<any-interface-ip>:8080/cmk/check_mk/
- Env file: ${CHECKMK_ENV}
- Web login username: cmkadmin
- Requested username value: ${checkmk_username}
- Initial cmkadmin password is stored in the env file above.
- SMTP relay: ${LOCAL_SMTP_RELAY_HOST}
- Alert recipient: ${ALERT_RECIPIENT}

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
echo "LibreNMS DB username: ${librenms_db_username}"
echo "LibreNMS DB password source: $(test -n "$TACTICAL_LIBRENMS_DB_PASSWORD" && echo "Tactical global key store" || echo "existing/generated env file")"
echo "LibreNMS admin username supplied: $(test -n "$librenms_admin_username" && echo yes || echo no)"
echo "LibreNMS admin password supplied: $(test -n "$librenms_admin_password" && echo yes || echo no)"
echo "Checkmk username: cmkadmin"
echo "Checkmk password source: $(test -n "$TACTICAL_CHECKMK_PASSWORD" && echo "Tactical global key store" || echo "existing/generated env file")"
echo "Local SMTP relay: ${LOCAL_SMTP_RELAY_HOST}:${LOCAL_SMTP_RELAY_PORT}"
echo "Alert recipient: ${ALERT_RECIPIENT}"
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

librenms_mail_config="not-run"
if (cd "$LIBRENMS_ROOT" && docker compose -p "$LIBRENMS_PROJECT" -f "$LIBRENMS_COMPOSE" exec -T --user librenms librenms sh -lc "
  lnms config:set email_backend 'smtp' &&
  lnms config:set email_from 'librenms@cets.com.au' &&
  lnms config:set email_smtp_host '${LOCAL_SMTP_RELAY_HOST}' &&
  lnms config:set email_smtp_port ${LOCAL_SMTP_RELAY_PORT} &&
  lnms config:set email_smtp_timeout 10 &&
  lnms config:set email_smtp_auth false &&
  lnms config:set email_smtp_username NULL &&
  lnms config:set email_smtp_password NULL &&
  lnms config:set alert.default_mail '${ALERT_RECIPIENT}' --ignore-checks &&
  lnms config:set alert.fixed-contacts false --ignore-checks
" >/dev/null 2>&1); then
  echo "LibreNMS mail relay configured for ${LOCAL_SMTP_RELAY_HOST}:${LOCAL_SMTP_RELAY_PORT}."
  librenms_mail_config="configured"
else
  echo "WARNING: LibreNMS mail relay configuration did not complete." >&2
  librenms_mail_config="failed"
  set_status "$EXIT_WARN" "WARNING"
fi

if [[ -n "$librenms_admin_username" || -n "$librenms_admin_password" ]]; then
  if [[ -z "$librenms_admin_username" || -z "$librenms_admin_password" ]]; then
    echo "WARNING: LibreNMS admin username/password must both be supplied to bootstrap a web admin." >&2
    librenms_admin_bootstrap="incomplete"
    set_status "$EXIT_WARN" "WARNING"
  else
    if (cd "$LIBRENMS_ROOT" && docker compose -p "$LIBRENMS_PROJECT" -f "$LIBRENMS_COMPOSE" exec -T --user librenms librenms lnms user:add --password="$librenms_admin_password" --role=admin "$librenms_admin_username" >/dev/null 2>&1); then
      echo "LibreNMS admin user ensured from Tactical global key store."
      librenms_admin_bootstrap="created"
    else
      echo "WARNING: LibreNMS admin user bootstrap did not complete; user may already exist or LibreNMS may not be ready for user management." >&2
      librenms_admin_bootstrap="not-updated"
      set_status "$EXIT_WARN" "WARNING"
    fi
  fi
fi

echo
echo "=== CHECKMK DEPLOY ==="
timeout --foreground 900 docker pull "$CHECKMK_IMAGE"
(cd "$CHECKMK_ROOT" && docker compose -p "$CHECKMK_PROJECT" -f "$CHECKMK_COMPOSE" up -d)
checkmk_http_status="$(wait_for_http "http://127.0.0.1:8080/cmk/check_mk/login.py" '^(200|302|303)$' 120 5)"
echo "Checkmk HTTP status: ${checkmk_http_status}"

checkmk_mail_config="not-run"
if (cd "$CHECKMK_ROOT" && docker compose -p "$CHECKMK_PROJECT" -f "$CHECKMK_COMPOSE" exec -T checkmk python3 - "$ALERT_RECIPIENT" <<'PY'
from pathlib import Path
from pprint import pformat
import sys

recipient = sys.argv[1]
path = Path("/omd/sites/cmk/etc/check_mk/multisite.d/wato/users.mk")
namespace = {"multisite_users": {}}
if path.exists():
    exec(path.read_text(encoding="utf-8"), namespace)
users = namespace.get("multisite_users", {})
cmkadmin = users.setdefault("cmkadmin", {"alias": "cmkadmin", "roles": ["admin"], "connector": "htpasswd", "locked": False})
cmkadmin["email"] = recipient
cmkadmin["contactgroups"] = ["all"]
cmkadmin["notifications_enabled"] = True
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text("multisite_users.update(%s)\n" % pformat(users, sort_dicts=True), encoding="utf-8")
PY
); then
  if (cd "$CHECKMK_ROOT" && docker compose -p "$CHECKMK_PROJECT" -f "$CHECKMK_COMPOSE" exec -T --user cmk checkmk cmk -R >/dev/null 2>&1); then
    echo "Checkmk cmkadmin contact email configured for ${ALERT_RECIPIENT}."
    checkmk_mail_config="configured"
  else
    echo "WARNING: Checkmk contact email was written, but configuration reload did not complete." >&2
    checkmk_mail_config="reload-failed"
    set_status "$EXIT_WARN" "WARNING"
  fi
else
  echo "WARNING: Checkmk contact email configuration did not complete." >&2
  checkmk_mail_config="failed"
  set_status "$EXIT_WARN" "WARNING"
fi

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
echo "LibreNMS URL: http://${hostname_value}:8000"
echo "Checkmk URL: http://${hostname_value}:8080/cmk/check_mk/"
echo "LibreNMS HTTP status: ${librenms_http_status}"
echo "Checkmk HTTP status: ${checkmk_http_status}"
echo "LibreNMS env created this run: ${librenms_env_created}"
echo "Checkmk env created this run: ${checkmk_env_created}"
echo "LibreNMS DB username: ${librenms_db_username}"
echo "LibreNMS admin bootstrap: ${librenms_admin_bootstrap}"
echo "LibreNMS mail config: ${librenms_mail_config}"
echo "Checkmk username: cmkadmin"
echo "Checkmk mail config: ${checkmk_mail_config}"
echo "Alert recipient: ${ALERT_RECIPIENT}"
echo "Credential password values printed: no"
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
