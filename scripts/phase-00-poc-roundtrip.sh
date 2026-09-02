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
  echo "ERROR: POC roundtrip failed at line ${line}: ${cmd}" >&2
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

hostname_value="$(hostname)"
user_value="$(id -un)"
kernel_value="$(uname -r)"
arch_value="$(uname -m)"
time_value="$(date --iso-8601=seconds)"
tactical_enabled="$(systemctl is-enabled tacticalagent.service 2>/dev/null || true)"
tactical_active="$(systemctl is-active tacticalagent.service 2>/dev/null || true)"
os_release_contents="$(cat /etc/os-release)"

if [[ "$hostname_value" != "cets-mon-poc-01" ]]; then
  set_status "$EXIT_ERROR" "ERROR"
fi

if [[ "$tactical_enabled" != "enabled" ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

if [[ "$tactical_active" != "active" ]]; then
  set_status "$EXIT_ERROR" "ERROR"
fi

echo "=== CETS MONITORING APPLIANCE POC ==="
echo "Hostname: ${hostname_value}"
echo "User: ${user_value}"
echo "Kernel: ${kernel_value}"
echo "Architecture: ${arch_value}"

echo
echo "=== OS ==="
printf '%s\n' "$os_release_contents"

echo
echo "=== TIME ==="
echo "${time_value}"

echo
echo "=== TACTICAL ==="
echo "${tactical_enabled}"
echo "${tactical_active}"

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "User: ${user_value}"
echo "Kernel: ${kernel_value}"
echo "Architecture: ${arch_value}"
echo "Timestamp: ${time_value}"
echo "Tactical enabled: ${tactical_enabled}"
echo "Tactical active: ${tactical_active}"

echo
if (( overall_code == EXIT_INFO )); then
  echo "POC roundtrip completed with informational status."
elif (( overall_code == EXIT_WARN )); then
  echo "POC roundtrip completed with warning status."
elif (( overall_code == EXIT_OK )); then
  echo "POC roundtrip completed successfully."
else
  echo "POC roundtrip completed with errors."
fi

exit "${overall_code}"
