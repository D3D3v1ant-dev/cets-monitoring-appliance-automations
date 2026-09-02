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
  echo "ERROR: SMTP relay phase failed at line ${line}: ${cmd}" >&2
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

SMTP_SERVER="${SMTP_SERVER:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_RELAY_DOMAIN="${SMTP_RELAY_DOMAIN:-cets.com.au}"
SMTP_HOSTNAME="${SMTP_HOSTNAME:-${hostname_value}}"
SMTP_USE_TLS="${SMTP_USE_TLS:-yes}"
SMTP_LISTEN_PORT="${SMTP_LISTEN_PORT:-25}"
AUTO_DETECT_CLIENT_NETWORKS="${AUTO_DETECT_CLIENT_NETWORKS:-yes}"
DEFAULT_CLIENT_NETWORKS="${DEFAULT_CLIENT_NETWORKS:-127.0.0.0/8,10.96.17.0/22}"
ALLOWED_CLIENT_NETWORKS="${ALLOWED_CLIENT_NETWORKS:-}"
SMTP_AUTH_USERNAME="${SMTP_AUTH_USERNAME:-${CETS_GMAIL_SMTP_USER:-}}"
SMTP_AUTH_PASSWORD="${SMTP_AUTH_PASSWORD:-${CETS_GMAIL_SMTP_APP_PW:-}}"
POSTFIX_MAIN_CF="/etc/postfix/main.cf"
POSTFIX_SASL_PASSWD="/etc/postfix/sasl_passwd"
POSTFIX_CONFIG_BACKUP_DIR="/var/backups/cets-monitoring-appliance"
POSTFIX_TEST_RECIPIENT="${POSTFIX_TEST_RECIPIENT:-}"

if [[ -z "$SMTP_AUTH_USERNAME" ]]; then
  echo "ERROR: SMTP username is missing from Tactical global key store." >&2
  exit "$EXIT_ERROR"
fi

if [[ -z "$SMTP_AUTH_PASSWORD" ]]; then
  echo "ERROR: SMTP app password is missing from Tactical global key store." >&2
  exit "$EXIT_ERROR"
fi

detect_local_subnet() {
  local route_line=""
  route_line="$(ip -4 route show scope link 2>/dev/null | awk 'NR==1 {print $1; exit}')"
  if [[ -n "$route_line" && "$route_line" == */* ]]; then
    printf '%s' "$route_line"
    return 0
  fi
  return 1
}

if [[ -z "$ALLOWED_CLIENT_NETWORKS" ]]; then
  if [[ "$AUTO_DETECT_CLIENT_NETWORKS" == "yes" ]] && detected_subnet="$(detect_local_subnet)"; then
    ALLOWED_CLIENT_NETWORKS="127.0.0.0/8,${detected_subnet}"
  else
    ALLOWED_CLIENT_NETWORKS="$DEFAULT_CLIENT_NETWORKS"
  fi
fi

apt-get update
apt-get install -y --no-install-recommends postfix libsasl2-modules ca-certificates mailutils

install -d -o root -g root -m 0750 "$POSTFIX_CONFIG_BACKUP_DIR"
if [[ -f "$POSTFIX_MAIN_CF" ]]; then
  cp -a "$POSTFIX_MAIN_CF" "${POSTFIX_CONFIG_BACKUP_DIR}/main.cf.$(date +%Y%m%d%H%M%S)"
fi

cat >"$POSTFIX_SASL_PASSWD" <<EOF
[${SMTP_SERVER}]:${SMTP_PORT} ${SMTP_AUTH_USERNAME}:${SMTP_AUTH_PASSWORD}
EOF
chmod 0600 "$POSTFIX_SASL_PASSWD"
postmap "$POSTFIX_SASL_PASSWD"

postconf -e "relayhost = [${SMTP_SERVER}]:${SMTP_PORT}"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:${POSTFIX_SASL_PASSWD}"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = all"
postconf -e "myhostname = ${SMTP_HOSTNAME}"
postconf -e "myorigin = ${SMTP_RELAY_DOMAIN}"
postconf -e "mynetworks = ${ALLOWED_CLIENT_NETWORKS}"
postconf -e "smtpd_relay_restrictions = permit_mynetworks,reject_unauth_destination"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks,reject_unauth_destination"
postconf -e "master_service_disable = "

if [[ "$SMTP_LISTEN_PORT" != "25" ]]; then
  echo "INFO: SMTP listen port variable set to ${SMTP_LISTEN_PORT}, but Postfix will still use the standard submission service port 25." >&2
  set_status "$EXIT_INFO" "INFO"
fi

systemctl enable postfix
systemctl restart postfix

postfix_status="$(systemctl is-active postfix || true)"
if [[ "$postfix_status" != "active" ]]; then
  echo "ERROR: Postfix failed to start." >&2
  exit "$EXIT_ERROR"
fi

echo "=== CETS MONITORING APPLIANCE SMTP RELAY ==="
echo "Hostname: ${hostname_value}"
echo "Timestamp: $(date --iso-8601=seconds)"
echo "SMTP server: ${SMTP_SERVER}"
echo "SMTP port: ${SMTP_PORT}"
echo "SMTP listen port: ${SMTP_LISTEN_PORT}"
echo "Relay domain: ${SMTP_RELAY_DOMAIN}"
echo "Auto-detect client networks: ${AUTO_DETECT_CLIENT_NETWORKS}"
echo "Allowed client networks: ${ALLOWED_CLIENT_NETWORKS}"
echo "Postfix active: ${postfix_status}"
echo "Relay configuration file: ${POSTFIX_SASL_PASSWD}"
echo "Auth username source: Tactical global key store"
echo "SMTP TLS required: ${SMTP_USE_TLS}"

if [[ -n "$POSTFIX_TEST_RECIPIENT" ]]; then
  test_subject="CETS Monitoring Appliance SMTP relay test $(date --iso-8601=seconds)"
  test_body="SMTP relay for ${hostname_value} is configured and ready."
  if printf 'Subject: %s\nTo: %s\nFrom: %s\n\n%s\n' \
    "$test_subject" \
    "$POSTFIX_TEST_RECIPIENT" \
    "$SMTP_AUTH_USERNAME" \
    "$test_body" | sendmail -t; then
    echo "Test email submitted to sendmail queue for ${POSTFIX_TEST_RECIPIENT}."
    set_status "$EXIT_INFO" "INFO"
  else
    echo "WARNING: SMTP relay test message was not submitted." >&2
    set_status "$EXIT_WARN" "WARNING"
  fi
else
  echo "INFO: No test recipient configured; relay validation limited to service and configuration checks."
  set_status "$EXIT_INFO" "INFO"
fi

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "SMTP server: ${SMTP_SERVER}"
echo "SMTP port: ${SMTP_PORT}"
echo "Postfix status: ${postfix_status}"
echo "Configured relayhost: [${SMTP_SERVER}]:${SMTP_PORT}"
echo "Config backup directory: ${POSTFIX_CONFIG_BACKUP_DIR}"

case "$overall_label" in
  OK)
    echo "SMTP relay phase completed successfully."
    ;;
  INFO)
    echo "SMTP relay phase completed with informational findings."
    ;;
  WARNING)
    echo "SMTP relay phase completed with warning findings."
    ;;
  *)
    echo "SMTP relay phase completed with error findings."
    ;;
esac

exit "$overall_code"
