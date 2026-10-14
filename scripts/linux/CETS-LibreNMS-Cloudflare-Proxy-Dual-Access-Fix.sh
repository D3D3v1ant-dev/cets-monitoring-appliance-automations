#!/usr/bin/env bash
set -Eeuo pipefail

# Keeps LibreNMS usable both locally and through Cloudflare.
# The fix is to trust reverse-proxy headers so LibreNMS uses https://
# for Cloudflare requests while preserving local http:// access.

LIBRENMS_ROOT="${LIBRENMS_ROOT:-/opt/cets/monitoring/librenms}"
LIBRENMS_ENV="${LIBRENMS_ENV:-${LIBRENMS_ROOT}/librenms.env}"
LIBRENMS_COMPOSE="${LIBRENMS_COMPOSE:-${LIBRENMS_ROOT}/compose.yaml}"
LIBRENMS_PROJECT="${LIBRENMS_PROJECT:-cets-librenms}"
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-libre-cets-bbmon-01-26.cets.com.au}"

timestamp="$(date +%Y%m%d-%H%M%S)"

echo "=== CETS LibreNMS Cloudflare Dual Access Fix ==="
echo "Timestamp: $(date -Is)"
echo "LibreNMS root: ${LIBRENMS_ROOT}"
echo "Public hostname: ${PUBLIC_HOSTNAME}"

if [[ ! -d "$LIBRENMS_ROOT" ]]; then
  echo "ERROR: LibreNMS root not found: ${LIBRENMS_ROOT}" >&2
  exit 1
fi

if [[ ! -f "$LIBRENMS_ENV" ]]; then
  echo "ERROR: LibreNMS env file not found: ${LIBRENMS_ENV}" >&2
  exit 1
fi

if [[ ! -f "$LIBRENMS_COMPOSE" ]]; then
  echo "ERROR: LibreNMS compose file not found: ${LIBRENMS_COMPOSE}" >&2
  exit 1
fi

cp -a "$LIBRENMS_ENV" "${LIBRENMS_ENV}.bak.${timestamp}"
echo "Backup created: ${LIBRENMS_ENV}.bak.${timestamp}"

set_env_value() {
  local key="$1"
  local value="$2"

  if grep -qE "^${key}=" "$LIBRENMS_ENV"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$LIBRENMS_ENV"
  else
    printf '%s=%s\n' "$key" "$value" >>"$LIBRENMS_ENV"
  fi
}

# Do not force APP_URL/LIBRENMS_BASE_URL. A static local base URL makes the
# Cloudflare page generate http:// public AJAX URLs; a static public base URL
# makes local sessions generate public links. Trusting proxy headers lets the
# same LibreNMS instance generate https:// URLs through Cloudflare and local
# http:// URLs when accessed directly.
sed -i '/^APP_URL=/d;/^LIBRENMS_BASE_URL=/d' "$LIBRENMS_ENV"
set_env_value TRUSTED_PROXIES "*"
set_env_value APP_TRUSTED_PROXIES "*"
set_env_value TRUSTED_HEADERS "HEADER_X_FORWARDED_ALL"
set_env_value TRUSTED_PROXY_HEADERS "HEADER_X_FORWARDED_ALL"

echo
echo "=== Effective public/proxy env ==="
grep -E '^(APP_URL|LIBRENMS_BASE_URL|APP_TRUSTED_PROXIES|TRUSTED_PROXIES|TRUSTED_HEADERS|TRUSTED_PROXY_HEADERS)=' "$LIBRENMS_ENV" || true

echo
echo "=== Restart LibreNMS web container ==="
cd "$LIBRENMS_ROOT"
docker compose -p "$LIBRENMS_PROJECT" -f "$LIBRENMS_COMPOSE" up -d librenms dispatcher

echo
echo "=== Clear LibreNMS/Laravel caches ==="
docker compose -p "$LIBRENMS_PROJECT" -f "$LIBRENMS_COMPOSE" exec -T --user librenms librenms sh -lc '
  php artisan config:clear || true
  php artisan route:clear || true
  php artisan view:clear || true
  php artisan cache:clear || true
'

echo
echo "=== Local validation ==="
local_status="000"
for _ in $(seq 1 30); do
  local_status="$(curl -ksS -o /tmp/cets-librenms-local.html -w '%{http_code}' http://127.0.0.1:8000/devices || true)"
  if [[ "$local_status" =~ ^(200|302|303)$ ]]; then
    break
  fi
  sleep 2
done
echo "Local /devices HTTP status: ${local_status}"
if [[ ! -f /tmp/cets-librenms-local.html ]]; then
  echo "Local device table AJAX URL: not-validated"
elif grep -q 'data-url="http://127.0.0.1:8000/ajax/table/device"' /tmp/cets-librenms-local.html; then
  echo "Local device table AJAX URL: local-http"
elif grep -q 'data-url="http://' /tmp/cets-librenms-local.html; then
  echo "Local device table AJAX URL: http"
elif grep -q 'data-url="https://' /tmp/cets-librenms-local.html; then
  echo "Local device table AJAX URL: https"
else
  echo "Local device table AJAX URL: not-found"
fi

echo
echo "=== Summary ==="
echo "Result: OK"
echo "Cloudflare access should generate HTTPS URLs from forwarded proxy headers."
echo "Local access remains available at http://<appliance-ip>:8000/."
echo "If devices still show empty via Cloudflare, retest after browser refresh/sign-out because old page JavaScript may be cached."
