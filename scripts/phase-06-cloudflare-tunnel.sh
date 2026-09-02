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
  echo "ERROR: Cloudflare Tunnel phase failed at line ${line}: ${cmd}" >&2
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

require_root

TARGET_HOSTNAME="cets-mon-poc-01"
hostname_value="$(hostname)"
if [[ "$hostname_value" != "$TARGET_HOSTNAME" ]]; then
  echo "ERROR: Expected hostname ${TARGET_HOSTNAME}, found ${hostname_value}." >&2
  exit "$EXIT_ERROR"
fi

CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"
CLOUDFLARED_DOWNLOAD_URL="${CLOUDFLARED_DOWNLOAD_URL:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-${CETS_CF_TUNNELS_API:-}}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-${CETS_CF_ACCOUNT_ID:-}}"
CLOUDFLARE_TUNNEL_NAME_OVERRIDE="${CLOUDFLARE_TUNNEL_NAME_OVERRIDE:-}"
CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
CLOUDFLARE_EXISTING_TUNNEL_ID="${CLOUDFLARE_EXISTING_TUNNEL_ID:-}"
CLOUDFLARE_EXISTING_LIBRE_APP_ID="${CLOUDFLARE_EXISTING_LIBRE_APP_ID:-}"
CLOUDFLARE_EXISTING_CMK_APP_ID="${CLOUDFLARE_EXISTING_CMK_APP_ID:-}"
CLOUDFLARE_EXISTING_LIBRE_DNS_ID="${CLOUDFLARE_EXISTING_LIBRE_DNS_ID:-}"
CLOUDFLARE_EXISTING_CMK_DNS_ID="${CLOUDFLARE_EXISTING_CMK_DNS_ID:-}"
CLOUDFLARE_PUBLIC_PREFIX_LIBRE="${CLOUDFLARE_PUBLIC_PREFIX_LIBRE:-libre}"
CLOUDFLARE_PUBLIC_PREFIX_CMK="${CLOUDFLARE_PUBLIC_PREFIX_CMK:-cmk}"
CLOUDFLARE_PUBLIC_HOSTNAMES="${CLOUDFLARE_PUBLIC_HOSTNAMES:-}"
CLOUDFLARE_ORIGINS="${CLOUDFLARE_ORIGINS:-}"
CLOUDFLARE_ACCESS_EMAIL="${CLOUDFLARE_ACCESS_EMAIL:-ddelaney@cets.com.au}"
CLOUDFLARE_ACCESS_SESSION_DURATION="${CLOUDFLARE_ACCESS_SESSION_DURATION:-24h}"
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-cets.com.au}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_CONFIG_DIR="${CLOUDFLARE_CONFIG_DIR:-/opt/cets/cloudflare}"
CLOUDFLARE_CONFIG_FILE="${CLOUDFLARE_CONFIG_FILE:-${CLOUDFLARE_CONFIG_DIR}/config.yml}"
CLOUDFLARE_LOG_FILE="${CLOUDFLARE_LOG_FILE:-/var/log/cets-cloudflare-tunnel.log}"
CLOUDFLARE_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
CLOUDFLARE_UPDATE_MODE="${CLOUDFLARE_UPDATE_MODE:-install}"

if [[ -z "$CLOUDFLARE_TUNNEL_NAME" ]]; then
  if [[ -n "$CLOUDFLARE_TUNNEL_NAME_OVERRIDE" ]]; then
    CLOUDFLARE_TUNNEL_NAME="$CLOUDFLARE_TUNNEL_NAME_OVERRIDE"
  else
    tunnel_year="$(date +%y)"
    CLOUDFLARE_TUNNEL_NAME="${hostname_value}-${tunnel_year}.cets.com.au"
  fi
fi

if [[ -z "$CLOUDFLARE_PUBLIC_HOSTNAMES" ]]; then
  tunnel_base="${hostname_value}-$(date +%y).cets.com.au"
  CLOUDFLARE_PUBLIC_HOSTNAMES="${CLOUDFLARE_PUBLIC_PREFIX_LIBRE}.${tunnel_base},${CLOUDFLARE_PUBLIC_PREFIX_CMK}.${tunnel_base}"
fi

install -d -o root -g root -m 0750 "$CLOUDFLARE_CONFIG_DIR"
install -d -o root -g root -m 0750 "$(dirname "$CLOUDFLARE_LOG_FILE")"

if command -v cloudflared >/dev/null 2>&1; then
  echo "INFO: cloudflared is already installed." >&2
  set_status "$EXIT_INFO" "INFO"
else
  tmp_deb="/tmp/cloudflared.deb"
  curl -fsSL "$CLOUDFLARED_DOWNLOAD_URL" -o "$tmp_deb"
  apt-get update
  apt-get install -y --no-install-recommends "$tmp_deb"
  rm -f "$tmp_deb"
fi

cat >"$CLOUDFLARE_CONFIG_FILE" <<EOF
logfile: ${CLOUDFLARE_LOG_FILE}
EOF
chmod 0640 "$CLOUDFLARE_CONFIG_FILE"

cf_api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"
  local response_file http_code response_body
  response_file="$(mktemp)"
  http_code="$(
    curl -sS -o "$response_file" -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      ${data:+--data "$data"} \
      "$url" || true
  )"
  response_body="$(cat "$response_file")"
  rm -f "$response_file"
  if [[ "$http_code" != 2* ]]; then
    echo "$http_code" >&2
    printf '%s' "$response_body" >&2
    return 1
  fi
  printf '%s' "$response_body"
}

create_tunnel_via_api() {
  if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ACCOUNT_ID" ]]; then
    echo "ERROR: Cloudflare API token or account ID missing from Tactical global key store." >&2
    exit "$EXIT_ERROR"
  fi

  local request_body response tunnel_id tunnel_token
  request_body="$(printf '{"name":"%s","config_src":"cloudflare"}' "$CLOUDFLARE_TUNNEL_NAME")"
  if response="$(cf_api_request POST "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "$request_body")"; then
    tunnel_id="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
  else
    if tunnel_id="$(lookup_tunnel_id)"; then
      echo "INFO: Reusing existing Cloudflare tunnel ${tunnel_id}." >&2
    else
      return 1
    fi
  fi
  tunnel_token="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')"
  printf '%s\n' "$tunnel_id:$tunnel_token"
}

lookup_tunnel_id() {
  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel")"
  printf '%s' "$response" | python3 - "$CLOUDFLARE_TUNNEL_NAME" <<'PY'
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("result", []):
    if item.get("name") == name:
        print(item.get("id", ""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

create_access_app() {
  local hostname="$1"
  local service_url="$2"
  local app_name="$3"
  local payload response app_id
  payload="$(cat <<EOF
{
  "name": "${app_name}",
  "domain": "${hostname}",
  "type": "self_hosted",
  "session_duration": "${CLOUDFLARE_ACCESS_SESSION_DURATION}",
  "policies": [
    {
      "decision": "allow",
      "include": [
        {
          "email": {
            "email": "${CLOUDFLARE_ACCESS_EMAIL}"
          }
        }
      ]
    }
  ]
}
EOF
)"
  if response="$(cf_api_request POST "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" "$payload")"; then
    app_id="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
  else
    if app_id="$(lookup_access_app_id "$hostname")"; then
      echo "INFO: Reusing existing Access app for ${hostname}." >&2
    else
      return 1
    fi
  fi
  printf '%s\n' "$app_id"
}

lookup_access_app_id() {
  local hostname="$1"
  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps")"
  printf '%s' "$response" | python3 - "$hostname" <<'PY'
import json, sys
hostname = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("result", []):
    if item.get("domain") == hostname:
        print(item.get("id", ""))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

lookup_zone_id() {
  if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
    printf '%s\n' "$CLOUDFLARE_ZONE_ID"
    return 0
  fi

  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE_NAME}&status=active")"
  printf '%s' "$response" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["result"][0]["id"])'
}

create_dns_record() {
  local zone_id="$1"
  local hostname="$2"
  local target="$3"
  local payload response record_id
  payload="$(cat <<EOF
{
  "type": "CNAME",
  "name": "${hostname}",
  "content": "${target}",
  "proxied": true,
  "ttl": 1
}
EOF
)"
  if response="$(cf_api_request POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" "$payload")"; then
    record_id="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
  else
    record_id="$(printf '%s' "$hostname")"
    echo "INFO: Reusing existing DNS record for ${hostname}." >&2
  fi
  printf '%s\n' "$record_id"
}

if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
  if [[ -n "$CLOUDFLARE_EXISTING_TUNNEL_ID" ]]; then
    CLOUDFLARE_TUNNEL_ID="$CLOUDFLARE_EXISTING_TUNNEL_ID"
    echo "INFO: Reusing explicit Cloudflare tunnel ${CLOUDFLARE_TUNNEL_ID}." >&2
  elif CLOUDFLARE_TUNNEL_ID="$(lookup_tunnel_id)"; then
    CLOUDFLARE_TUNNEL_TOKEN=""
    echo "INFO: Reusing existing Cloudflare tunnel ${CLOUDFLARE_TUNNEL_ID}." >&2
  else
    tunnel_creds="$(create_tunnel_via_api)"
    CLOUDFLARE_TUNNEL_ID="${tunnel_creds%%:*}"
    CLOUDFLARE_TUNNEL_TOKEN="${tunnel_creds#*:}"
    echo "INFO: Created Cloudflare tunnel via API." >&2
  fi
else
  CLOUDFLARE_TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-unknown}"
fi

libre_hostname="${CLOUDFLARE_PUBLIC_HOSTNAMES%%,*}"
cmk_hostname="${CLOUDFLARE_PUBLIC_HOSTNAMES##*,}"
zone_id="$(lookup_zone_id)"
if [[ -n "$CLOUDFLARE_EXISTING_LIBRE_APP_ID" ]]; then
  libre_app_id="$CLOUDFLARE_EXISTING_LIBRE_APP_ID"
  echo "INFO: Reusing explicit Access app for LibreNMS." >&2
elif libre_app_id="$(lookup_access_app_id "$libre_hostname")"; then
  echo "INFO: Reusing existing Access app for LibreNMS." >&2
else
  libre_app_id="$(create_access_app "$libre_hostname" "http://127.0.0.1:8000" "LibreNMS Access for ${hostname_value}")"
fi
if [[ -n "$CLOUDFLARE_EXISTING_CMK_APP_ID" ]]; then
  cmk_app_id="$CLOUDFLARE_EXISTING_CMK_APP_ID"
  echo "INFO: Reusing explicit Access app for Checkmk." >&2
elif cmk_app_id="$(lookup_access_app_id "$cmk_hostname")"; then
  echo "INFO: Reusing existing Access app for Checkmk." >&2
else
  cmk_app_id="$(create_access_app "$cmk_hostname" "http://127.0.0.1:8080" "Checkmk Access for ${hostname_value}")"
fi
if [[ -n "$CLOUDFLARE_EXISTING_LIBRE_DNS_ID" ]]; then
  libre_dns_id="$CLOUDFLARE_EXISTING_LIBRE_DNS_ID"
  echo "INFO: Reusing explicit DNS record for LibreNMS." >&2
else
  libre_dns_id="$(create_dns_record "$zone_id" "$libre_hostname" "${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com")"
fi
if [[ -n "$CLOUDFLARE_EXISTING_CMK_DNS_ID" ]]; then
  cmk_dns_id="$CLOUDFLARE_EXISTING_CMK_DNS_ID"
  echo "INFO: Reusing explicit DNS record for Checkmk." >&2
else
  cmk_dns_id="$(create_dns_record "$zone_id" "$cmk_hostname" "${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com")"
fi

cat >"$CLOUDFLARE_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel run --token ${CLOUDFLARE_TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$CLOUDFLARE_SERVICE_FILE"
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared
tunnel_status="$(systemctl is-active cloudflared || true)"
if [[ "$tunnel_status" != "active" ]]; then
  echo "ERROR: Cloudflared failed to start." >&2
  exit "$EXIT_ERROR"
fi
echo "Cloudflare tunnel started."
echo "Tunnel name: ${CLOUDFLARE_TUNNEL_NAME}"
echo "Tunnel id: ${CLOUDFLARE_TUNNEL_ID}"
echo "Tunnel status: ${tunnel_status}"
set_status "$EXIT_OK" "OK"
echo "Access app created for LibreNMS: ${libre_hostname} (${libre_app_id})"
echo "Access app created for Checkmk: ${cmk_hostname} (${cmk_app_id})"
echo "DNS record created for LibreNMS: ${libre_hostname} (${libre_dns_id})"
echo "DNS record created for Checkmk: ${cmk_hostname} (${cmk_dns_id})"

echo
echo "=== CETS MONITORING APPLIANCE CLOUDFLARE TUNNEL ==="
echo "Hostname: ${hostname_value}"
echo "Timestamp: $(date --iso-8601=seconds)"
echo "Cloudflared version target: ${CLOUDFLARED_VERSION}"
echo "Tunnel name: ${CLOUDFLARE_TUNNEL_NAME}"
echo "Tunnel id: ${CLOUDFLARE_TUNNEL_ID:-unknown}"
echo "Config directory: ${CLOUDFLARE_CONFIG_DIR}"
echo "Config file: ${CLOUDFLARE_CONFIG_FILE}"
echo "Log file: ${CLOUDFLARE_LOG_FILE}"
echo "Public hostnames: ${CLOUDFLARE_PUBLIC_HOSTNAMES:-none}"
echo "Origins: ${CLOUDFLARE_ORIGINS:-none}"

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "Tunnel name: ${CLOUDFLARE_TUNNEL_NAME}"
echo "Tunnel id: ${CLOUDFLARE_TUNNEL_ID:-unknown}"
echo "Config directory: ${CLOUDFLARE_CONFIG_DIR}"
echo "Token provided: $( [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]] && echo yes || echo no )"

case "$overall_label" in
  OK)
    echo "Cloudflare Tunnel phase completed successfully."
    ;;
  INFO)
    echo "Cloudflare Tunnel phase completed with informational findings."
    ;;
  WARNING)
    echo "Cloudflare Tunnel phase completed with warning findings."
    ;;
  *)
    echo "Cloudflare Tunnel phase completed with error findings."
    ;;
esac

exit "$overall_code"
