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
  echo "ERROR: Linux baseline failed at line ${line}: ${cmd}" >&2
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

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

require_root

TARGET_HOSTNAME="cets-mon-poc-01"
hostname_value="$(hostname)"
if [[ "$hostname_value" != "$TARGET_HOSTNAME" ]]; then
  echo "ERROR: Expected hostname ${TARGET_HOSTNAME}, found ${hostname_value}." >&2
  exit "$EXIT_ERROR"
fi

PACKAGES=(
  apt-listchanges
  ca-certificates
  curl
  git
  gnupg
  jq
  lsb-release
  python3
  python3-venv
  unattended-upgrades
  unzip
  wget
)

DIRECTORIES=(
  /opt/cets
  /opt/cets/monitoring
  /opt/cets/cloudflare
  /opt/cets/postfix
  /opt/cets/scripts
)

SECURE_DIRECTORIES=(
  /opt/cets/state
  /opt/cets/logs
)

AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"
AUTO_UPGRADES_CONTENT='APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
'

packages_before=()
packages_missing=()
packages_installed_now=()
for pkg in "${PACKAGES[@]}"; do
  if package_installed "$pkg"; then
    packages_before+=("$pkg")
  else
    packages_missing+=("$pkg")
  fi
done

echo "=== CETS MONITORING APPLIANCE LINUX BASELINE ==="
echo "Hostname: ${hostname_value}"
echo "Timestamp: $(date --iso-8601=seconds)"

echo
echo "=== PACKAGE PLAN ==="
echo "Already installed: ${#packages_before[@]}"
printf '%s\n' "${packages_before[@]:-none}"
echo
echo "Missing before run: ${#packages_missing[@]}"
printf '%s\n' "${packages_missing[@]:-none}"

echo
echo "=== APT UPDATE ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update

echo
echo "=== PACKAGE INSTALL ==="
apt-get install -y --no-install-recommends "${PACKAGES[@]}"

for pkg in "${PACKAGES[@]}"; do
  if package_installed "$pkg"; then
    if [[ " ${packages_missing[*]} " == *" ${pkg} "* ]]; then
      packages_installed_now+=("$pkg")
    fi
  else
    echo "ERROR: Package ${pkg} is still not installed after apt-get." >&2
    exit "$EXIT_ERROR"
  fi
done

echo "Installed during this run: ${#packages_installed_now[@]}"
printf '%s\n' "${packages_installed_now[@]:-none}"

echo
echo "=== DIRECTORY LAYOUT ==="
for dir in "${DIRECTORIES[@]}"; do
  install -d -o root -g root -m 0755 "$dir"
  stat -c '%A %U:%G %n' "$dir"
done
for dir in "${SECURE_DIRECTORIES[@]}"; do
  install -d -o root -g root -m 0750 "$dir"
  stat -c '%A %U:%G %n' "$dir"
done

echo
echo "=== UNATTENDED UPGRADES ==="
printf '%s' "$AUTO_UPGRADES_CONTENT" > "$AUTO_UPGRADES_FILE"
chmod 0644 "$AUTO_UPGRADES_FILE"

if [[ "$(systemctl is-enabled unattended-upgrades.service 2>/dev/null || true)" != "enabled" ]]; then
  systemctl enable unattended-upgrades.service
fi
if [[ "$(systemctl is-active unattended-upgrades.service 2>/dev/null || true)" != "active" ]]; then
  systemctl start unattended-upgrades.service
fi
if [[ "$(systemctl is-enabled apt-daily.timer 2>/dev/null || true)" != "enabled" ]]; then
  systemctl enable apt-daily.timer
fi
if [[ "$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)" != "enabled" ]]; then
  systemctl enable apt-daily-upgrade.timer
fi

echo "Enabled service: $(systemctl is-enabled unattended-upgrades.service)"
echo "Active service: $(systemctl is-active unattended-upgrades.service)"
echo "Enabled apt-daily.timer: $(systemctl is-enabled apt-daily.timer)"
echo "Enabled apt-daily-upgrade.timer: $(systemctl is-enabled apt-daily-upgrade.timer)"
echo "--- ${AUTO_UPGRADES_FILE} ---"
cat "$AUTO_UPGRADES_FILE"

echo
echo "=== POST-CHECKS ==="
curl_version="$(curl --version | head -n 1)"
jq_version="$(jq --version)"
git_version="$(git --version)"
python_version="$(python3 --version)"
https_check="$(python3 -c 'import urllib.request; response = urllib.request.urlopen("https://api.cets.com.au", timeout=10); print("HTTP", response.status); print("Content-Type:", response.headers.get("Content-Type", "unknown"))')"
echo "$curl_version"
echo "$jq_version"
echo "$git_version"
echo "$python_version"
printf '%s\n' "$https_check"

if [[ -f /var/run/reboot-required ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "Packages installed during run: ${#packages_installed_now[@]}"
echo "Core package set present: yes"
echo "Directory root present: $(test -d /opt/cets && echo yes || echo no)"
echo "Unattended upgrades enabled: $(systemctl is-enabled unattended-upgrades.service)"
echo "Unattended upgrades active: $(systemctl is-active unattended-upgrades.service)"
echo "apt-daily.timer enabled: $(systemctl is-enabled apt-daily.timer)"
echo "apt-daily-upgrade.timer enabled: $(systemctl is-enabled apt-daily-upgrade.timer)"
echo "Reboot required: $(test -f /var/run/reboot-required && echo yes || echo no)"

echo
case "$overall_label" in
  OK)
    echo "Linux baseline completed successfully."
    ;;
  INFO)
    echo "Linux baseline completed with informational findings."
    ;;
  WARNING)
    echo "Linux baseline completed with warning findings."
    ;;
  *)
    echo "Linux baseline completed with error findings."
    ;;
esac

exit "$overall_code"
