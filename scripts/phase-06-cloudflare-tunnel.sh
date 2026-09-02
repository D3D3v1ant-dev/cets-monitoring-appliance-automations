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
  echo "ERROR: Cloudflare Tunnel phase failed at line ${line}." >&2
  exit 1
}

trap 'on_error "${LINENO}"' ERR

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

EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"
hostname_value="$(hostname -s)"
if [[ -n "$EXPECTED_HOSTNAME" && "$hostname_value" != "$EXPECTED_HOSTNAME" ]]; then
  echo "ERROR: Expected hostname ${EXPECTED_HOSTNAME}, found ${hostname_value}." >&2
  exit "$EXIT_ERROR"
fi

CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-latest}"
CLOUDFLARED_DOWNLOAD_URL="${CLOUDFLARED_DOWNLOAD_URL:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-${CETS_CF_TUNNELS_API:-}}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-${CETS_CF_ACCOUNT_ID:-}}"
CLOUDFLARE_TUNNEL_NAME_OVERRIDE="${CLOUDFLARE_TUNNEL_NAME_OVERRIDE:-}"
CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-}"
CLOUDFLARE_TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
CLOUDFLARE_PUBLIC_PREFIX_LIBRE="${CLOUDFLARE_PUBLIC_PREFIX_LIBRE:-libre}"
CLOUDFLARE_PUBLIC_PREFIX_CMK="${CLOUDFLARE_PUBLIC_PREFIX_CMK:-cmk}"
CLOUDFLARE_PUBLIC_HOSTNAMES="${CLOUDFLARE_PUBLIC_HOSTNAMES:-}"
CLOUDFLARE_LIBRE_ORIGIN="${CLOUDFLARE_LIBRE_ORIGIN:-http://127.0.0.1:8000}"
CLOUDFLARE_CMK_ORIGIN="${CLOUDFLARE_CMK_ORIGIN:-http://127.0.0.1:8080}"
CLOUDFLARE_ACCESS_EMAIL="${CLOUDFLARE_ACCESS_EMAIL:-ddelaney@cets.com.au}"
CLOUDFLARE_ACCESS_SESSION_DURATION="${CLOUDFLARE_ACCESS_SESSION_DURATION:-24h}"
CLOUDFLARE_ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-cets.com.au}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"
CLOUDFLARE_CONFIG_DIR="${CLOUDFLARE_CONFIG_DIR:-/opt/cets/cloudflare}"
CLOUDFLARE_CONFIG_FILE="${CLOUDFLARE_CONFIG_FILE:-${CLOUDFLARE_CONFIG_DIR}/config.yml}"
CLOUDFLARE_LOG_FILE="${CLOUDFLARE_LOG_FILE:-/var/log/cets-cloudflare-tunnel.log}"
CLOUDFLARE_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
CLOUDFLARE_TOKEN_ENV_FILE="${CLOUDFLARE_TOKEN_ENV_FILE:-/etc/cets/cloudflared.env}"
CLOUDFLARE_UPDATE_MODE="${CLOUDFLARE_UPDATE_MODE:-install}"

if [[ -z "$CLOUDFLARE_API_TOKEN" || -z "$CLOUDFLARE_ACCOUNT_ID" ]]; then
  echo "ERROR: Cloudflare API token or account ID missing from Tactical global key store." >&2
  exit "$EXIT_ERROR"
fi

if [[ -z "$CLOUDFLARE_TUNNEL_NAME" ]]; then
  if [[ -n "$CLOUDFLARE_TUNNEL_NAME_OVERRIDE" ]]; then
    CLOUDFLARE_TUNNEL_NAME="$CLOUDFLARE_TUNNEL_NAME_OVERRIDE"
  else
    tunnel_year="$(date +%y)"
    CLOUDFLARE_TUNNEL_NAME="${hostname_value}-${tunnel_year}.${CLOUDFLARE_ZONE_NAME}"
  fi
fi

if [[ -z "$CLOUDFLARE_PUBLIC_HOSTNAMES" ]]; then
  deployment_label="${hostname_value}-$(date +%y)"
  # Keep generated routes at one subdomain level so Cloudflare Universal SSL covers them.
  CLOUDFLARE_PUBLIC_HOSTNAMES="${CLOUDFLARE_PUBLIC_PREFIX_LIBRE}-${deployment_label}.${CLOUDFLARE_ZONE_NAME},${CLOUDFLARE_PUBLIC_PREFIX_CMK}-${deployment_label}.${CLOUDFLARE_ZONE_NAME}"
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
  local -a curl_args
  response_file="$(mktemp)"
  curl_args=(
    -sS
    -o "$response_file"
    -w '%{http_code}'
    -X "$method"
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    -H 'Content-Type: application/json'
  )
  if [[ -n "$data" ]]; then
    curl_args+=(--data "$data")
  fi
  http_code="$(
    curl "${curl_args[@]}" "$url" || true
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

find_result_id() {
  local field="$1"
  local expected="$2"
  python3 -c '
import json
import sys

field, expected = sys.argv[1:3]
expected = expected.rstrip(".").lower()
for item in (json.load(sys.stdin).get("result") or []):
    value = str(item.get(field, "")).rstrip(".").lower()
    item_id = item.get("id")
    if value == expected and item_id:
        print(item_id)
        raise SystemExit(0)
raise SystemExit(1)
' "$field" "$expected"
}

extract_result_id() {
  python3 -c '
import json
import sys

item_id = (json.load(sys.stdin).get("result") or {}).get("id")
if not item_id:
    raise SystemExit(1)
print(item_id)
'
}

create_tunnel_via_api() {
  local request_body response tunnel_id
  request_body="$(printf '{"name":"%s","config_src":"cloudflare"}' "$CLOUDFLARE_TUNNEL_NAME")"
  if response="$(cf_api_request POST "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "$request_body")"; then
    tunnel_id="$(printf '%s' "$response" | extract_result_id)"
  else
    if tunnel_id="$(lookup_tunnel_id)"; then
      echo "INFO: Tunnel appeared during creation; reusing ${tunnel_id}." >&2
    else
      return 1
    fi
  fi
  printf '%s\n' "$tunnel_id"
}

lookup_tunnel_id() {
  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&name=${CLOUDFLARE_TUNNEL_NAME}")"
  printf '%s' "$response" | find_result_id name "$CLOUDFLARE_TUNNEL_NAME"
}

get_tunnel_token() {
  local tunnel_id="$1"
  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/token")"
  printf '%s' "$response" | python3 -c '
import json
import sys

token = json.load(sys.stdin).get("result")
if not isinstance(token, str) or not token:
    raise SystemExit(1)
print(token)
'
}

create_access_app() {
  local hostname="$1"
  local app_name="$2"
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
    app_id="$(printf '%s' "$response" | extract_result_id)"
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
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps?exact=true&domain=${hostname}")"
  printf '%s' "$response" | find_result_id domain "$hostname"
}

lookup_zone_id() {
  if [[ -n "$CLOUDFLARE_ZONE_ID" ]]; then
    printf '%s\n' "$CLOUDFLARE_ZONE_ID"
    return 0
  fi

  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE_NAME}&status=active&account.id=${CLOUDFLARE_ACCOUNT_ID}")"
  printf '%s' "$response" | find_result_id name "$CLOUDFLARE_ZONE_NAME"
}

lookup_dns_record_id() {
  local zone_id="$1"
  local hostname="$2"
  local response
  response="$(cf_api_request GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=CNAME&name=${hostname}&match=all")"
  printf '%s' "$response" | find_result_id name "$hostname"
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
  if record_id="$(lookup_dns_record_id "$zone_id" "$hostname")"; then
    echo "INFO: Reusing existing DNS record for ${hostname}." >&2
    response="$(cf_api_request PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" "$payload")"
    record_id="$(printf '%s' "$response" | extract_result_id)"
  elif response="$(cf_api_request POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" "$payload")"; then
    record_id="$(printf '%s' "$response" | extract_result_id)"
  else
    return 1
  fi
  printf '%s\n' "$record_id"
}

configure_tunnel_ingress() {
  local tunnel_id="$1"
  local libre_hostname="$2"
  local cmk_hostname="$3"
  local current_config payload
  current_config="$(cf_api_request GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations")"
  payload="$(printf '%s' "$current_config" | python3 -c '
import json
import sys

libre_hostname, libre_origin, cmk_hostname, cmk_origin = sys.argv[1:5]
result = json.load(sys.stdin).get("result") or {}
config = result.get("config") or {}
existing = config.get("ingress") or []
managed = {libre_hostname.lower(), cmk_hostname.lower()}

preserved = []
fallback = None
for rule in existing:
    hostname = str(rule.get("hostname", "")).lower()
    if not hostname:
        fallback = fallback or rule
    elif hostname not in managed:
        preserved.append(rule)

preserved.extend([
    {"hostname": libre_hostname, "service": libre_origin},
    {"hostname": cmk_hostname, "service": cmk_origin},
    fallback or {"service": "http_status:404"},
])

updated = {"ingress": preserved}
if "originRequest" in config:
    updated["originRequest"] = config["originRequest"]
print(json.dumps({"config": updated}, separators=(",", ":")))
' "$libre_hostname" "$CLOUDFLARE_LIBRE_ORIGIN" "$cmk_hostname" "$CLOUDFLARE_CMK_ORIGIN")"
  cf_api_request PUT "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${tunnel_id}/configurations" "$payload" >/dev/null
}

if [[ -z "$CLOUDFLARE_TUNNEL_ID" ]]; then
  if CLOUDFLARE_TUNNEL_ID="$(lookup_tunnel_id)"; then
    echo "INFO: Reusing existing Cloudflare tunnel ${CLOUDFLARE_TUNNEL_ID}." >&2
  else
    CLOUDFLARE_TUNNEL_ID="$(create_tunnel_via_api)"
    echo "INFO: Created Cloudflare tunnel via API." >&2
  fi
fi
if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
  CLOUDFLARE_TUNNEL_TOKEN="$(get_tunnel_token "$CLOUDFLARE_TUNNEL_ID")"
fi

libre_hostname="${CLOUDFLARE_PUBLIC_HOSTNAMES%%,*}"
cmk_hostname="${CLOUDFLARE_PUBLIC_HOSTNAMES##*,}"
zone_id="$(lookup_zone_id)"
if libre_app_id="$(lookup_access_app_id "$libre_hostname")"; then
  echo "INFO: Reusing existing Access app for LibreNMS." >&2
else
  libre_app_id="$(create_access_app "$libre_hostname" "LibreNMS Access for ${hostname_value}")"
fi
if cmk_app_id="$(lookup_access_app_id "$cmk_hostname")"; then
  echo "INFO: Reusing existing Access app for Checkmk." >&2
else
  cmk_app_id="$(create_access_app "$cmk_hostname" "Checkmk Access for ${hostname_value}")"
fi
configure_tunnel_ingress "$CLOUDFLARE_TUNNEL_ID" "$libre_hostname" "$cmk_hostname"
libre_dns_id="$(create_dns_record "$zone_id" "$libre_hostname" "${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com")"
cmk_dns_id="$(create_dns_record "$zone_id" "$cmk_hostname" "${CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com")"

install -d -o root -g root -m 0750 "$(dirname "$CLOUDFLARE_TOKEN_ENV_FILE")"
install -o root -g root -m 0600 /dev/null "$CLOUDFLARE_TOKEN_ENV_FILE"
printf 'TUNNEL_TOKEN=%s\n' "$CLOUDFLARE_TUNNEL_TOKEN" >"$CLOUDFLARE_TOKEN_ENV_FILE"
cat >"$CLOUDFLARE_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CLOUDFLARE_TOKEN_ENV_FILE}
ExecStart=/usr/bin/cloudflared tunnel run
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
echo "Tunnel ingress configured: ${libre_hostname} -> ${CLOUDFLARE_LIBRE_ORIGIN}"
echo "Tunnel ingress configured: ${cmk_hostname} -> ${CLOUDFLARE_CMK_ORIGIN}"
echo "Access app ensured for LibreNMS: ${libre_hostname} (${libre_app_id})"
echo "Access app ensured for Checkmk: ${cmk_hostname} (${cmk_app_id})"
echo "DNS record ensured for LibreNMS: ${libre_hostname} (${libre_dns_id})"
echo "DNS record ensured for Checkmk: ${cmk_hostname} (${cmk_dns_id})"

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
echo "Origins: ${CLOUDFLARE_LIBRE_ORIGIN},${CLOUDFLARE_CMK_ORIGIN}"

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
