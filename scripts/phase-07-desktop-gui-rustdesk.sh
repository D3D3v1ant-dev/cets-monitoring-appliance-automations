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
  echo "ERROR: Desktop GUI and RustDesk phase failed at line ${line}: ${cmd}" >&2
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

EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-cets-mon-poc-01}"
hostname_value="$(hostname -s)"
if [[ -n "$EXPECTED_HOSTNAME" && "$hostname_value" != "$EXPECTED_HOSTNAME" ]]; then
  echo "ERROR: Expected hostname ${EXPECTED_HOSTNAME}, found ${hostname_value}." >&2
  exit "$EXIT_ERROR"
fi

export DEBIAN_FRONTEND=noninteractive

DESKTOP_PACKAGES=(
  dbus-x11
  firefox-esr
  libayatana-appindicator3-1
  lightdm
  polkitd
  task-xfce-desktop
  x11-xserver-utils
  xdg-utils
)

RUSTDESK_VERSION="${RUSTDESK_VERSION:-latest}"
RUSTDESK_DEB_URL="${RUSTDESK_DEB_URL:-}"
RUSTDESK_PERMANENT_PASSWORD="${RUSTDESK_PERMANENT_PASSWORD:-}"
RUSTDESK_RENDEZVOUS_SERVER="${RUSTDESK_RENDEZVOUS_SERVER:-}"
RUSTDESK_RELAY_SERVER="${RUSTDESK_RELAY_SERVER:-}"
RUSTDESK_API_SERVER="${RUSTDESK_API_SERVER:-}"
RUSTDESK_KEY="${RUSTDESK_KEY:-}"
RUSTDESK_CONFIG_DIR="/root/.config/rustdesk"
RUSTDESK_CONFIG_FILE="${RUSTDESK_CONFIG_DIR}/RustDesk2.toml"

desktop_missing=()
desktop_installed_now=()
for pkg in "${DESKTOP_PACKAGES[@]}"; do
  if ! package_installed "$pkg"; then
    desktop_missing+=("$pkg")
  fi
done

echo "=== CETS MONITORING APPLIANCE DESKTOP GUI AND RUSTDESK ==="
echo "Hostname: ${hostname_value}"
echo "Timestamp: $(date --iso-8601=seconds)"

echo
echo "=== PACKAGE PLAN ==="
echo "Desktop packages missing before run: ${#desktop_missing[@]}"
printf '%s\n' "${desktop_missing[@]:-none}"

echo
echo "=== APT UPDATE ==="
apt-get update

echo
echo "=== DESKTOP INSTALL ==="
apt-get install -y --no-install-recommends "${DESKTOP_PACKAGES[@]}"

for pkg in "${DESKTOP_PACKAGES[@]}"; do
  if package_installed "$pkg"; then
    if [[ " ${desktop_missing[*]} " == *" ${pkg} "* ]]; then
      desktop_installed_now+=("$pkg")
    fi
  else
    echo "ERROR: Package ${pkg} is still not installed after apt-get." >&2
    exit "$EXIT_ERROR"
  fi
done
echo "Desktop packages installed during this run: ${#desktop_installed_now[@]}"
printf '%s\n' "${desktop_installed_now[@]:-none}"

echo
echo "=== RUSTDESK INSTALL ==="
arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64) rustdesk_asset_regex='rustdesk-[0-9][^/"]*-x86_64\.deb$' ;;
  arm64) rustdesk_asset_regex='rustdesk-[0-9][^/"]*-aarch64\.deb$' ;;
  *)
    echo "ERROR: Unsupported RustDesk architecture ${arch}." >&2
    exit "$EXIT_ERROR"
    ;;
esac

if [[ -z "$RUSTDESK_DEB_URL" ]]; then
  if [[ "$RUSTDESK_VERSION" == "latest" ]]; then
    releases_url="https://api.github.com/repos/rustdesk/rustdesk/releases/latest"
  else
    releases_url="https://api.github.com/repos/rustdesk/rustdesk/releases/tags/${RUSTDESK_VERSION}"
  fi
  RUSTDESK_DEB_URL="$(
    python3 - "$releases_url" "$rustdesk_asset_regex" <<'PY'
import json
import re
import sys
import urllib.request

url, pattern = sys.argv[1:3]
with urllib.request.urlopen(url, timeout=30) as response:
    payload = json.load(response)
regex = re.compile(pattern)
for asset in payload.get("assets") or []:
    name = asset.get("name") or ""
    download = asset.get("browser_download_url") or ""
    if regex.search(name) and download:
        print(download)
        raise SystemExit(0)
raise SystemExit("no matching RustDesk .deb asset found")
PY
  )"
fi

rustdesk_before="not-installed"
if package_installed rustdesk; then
  rustdesk_before="$(dpkg-query -W -f='${Version}' rustdesk)"
fi

tmp_deb="$(mktemp --suffix=.deb)"
curl -fsSL "$RUSTDESK_DEB_URL" -o "$tmp_deb"
apt-get install -y --no-install-recommends "$tmp_deb"
rm -f "$tmp_deb"

if ! package_installed rustdesk; then
  echo "ERROR: RustDesk package is not installed after apt-get." >&2
  exit "$EXIT_ERROR"
fi
rustdesk_after="$(dpkg-query -W -f='${Version}' rustdesk)"
echo "RustDesk before: ${rustdesk_before}"
echo "RustDesk after: ${rustdesk_after}"
echo "RustDesk package source: ${RUSTDESK_DEB_URL}"

echo
echo "=== RUSTDESK CONFIGURATION ==="
install -d -o root -g root -m 0700 "$RUSTDESK_CONFIG_DIR"
if [[ -n "$RUSTDESK_RENDEZVOUS_SERVER" || -n "$RUSTDESK_RELAY_SERVER" || -n "$RUSTDESK_API_SERVER" || -n "$RUSTDESK_KEY" ]]; then
  python3 - "$RUSTDESK_CONFIG_FILE" "$RUSTDESK_RENDEZVOUS_SERVER" "$RUSTDESK_RELAY_SERVER" "$RUSTDESK_API_SERVER" "$RUSTDESK_KEY" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
values = {
    "rendezvous_server": sys.argv[2],
    "relay_server": sys.argv[3],
    "api_server": sys.argv[4],
    "key": sys.argv[5],
}
lines = []
if path.exists():
    lines = path.read_text(encoding="utf-8").splitlines()
kept = []
managed = set(values)
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line else ""
    if key not in managed:
        kept.append(line)
for key, value in values.items():
    if value:
        kept.append(f'{key} = "{value}"')
path.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")
PY
  chmod 0600 "$RUSTDESK_CONFIG_FILE"
  echo "RustDesk server configuration file ensured."
else
  echo "RustDesk server configuration not supplied; using RustDesk defaults."
fi

if [[ -n "$RUSTDESK_PERMANENT_PASSWORD" ]]; then
  if rustdesk --password "$RUSTDESK_PERMANENT_PASSWORD" >/dev/null 2>&1; then
    echo "RustDesk permanent password configured."
  else
    echo "WARNING: RustDesk password command did not complete successfully." >&2
    set_status "$EXIT_WARN" "WARNING"
  fi
else
  echo "RustDesk permanent password not supplied; leaving password unchanged."
  set_status "$EXIT_INFO" "INFO"
fi

echo
echo "=== SERVICES ==="
if systemctl list-unit-files lightdm.service >/dev/null 2>&1; then
  systemctl enable lightdm.service
  if [[ "$(systemctl is-active lightdm.service 2>/dev/null || true)" != "active" ]]; then
    systemctl restart lightdm.service || systemctl start lightdm.service
  fi
fi

if systemctl list-unit-files rustdesk.service >/dev/null 2>&1; then
  systemctl enable rustdesk.service
  if [[ "$(systemctl is-active rustdesk.service 2>/dev/null || true)" != "active" ]]; then
    systemctl restart rustdesk.service || systemctl start rustdesk.service
  fi
else
  echo "WARNING: rustdesk.service was not found after installation." >&2
  set_status "$EXIT_WARN" "WARNING"
fi

echo "lightdm enabled: $(systemctl is-enabled lightdm.service 2>/dev/null || echo missing)"
echo "lightdm active: $(systemctl is-active lightdm.service 2>/dev/null || echo missing)"
echo "rustdesk enabled: $(systemctl is-enabled rustdesk.service 2>/dev/null || echo missing)"
echo "rustdesk active: $(systemctl is-active rustdesk.service 2>/dev/null || echo missing)"

echo
echo "=== POST-CHECKS ==="
echo "Display manager: $(cat /etc/X11/default-display-manager 2>/dev/null || echo unknown)"
echo "XFCE session file: $(test -f /usr/share/xsessions/xfce.desktop && echo present || echo missing)"
echo "Firefox ESR: $(command -v firefox-esr >/dev/null 2>&1 && firefox-esr --version 2>/dev/null | head -n 1 || echo missing)"
echo "RustDesk binary: $(command -v rustdesk || echo missing)"
echo "RustDesk version: $(rustdesk --version 2>/dev/null || echo unknown)"
echo "Listening TCP ports:"
ss -ltnp | awk 'NR == 1 || /rustdesk|lightdm|xrdp|vnc|5900|2111[5-9]/'

if [[ -f /var/run/reboot-required ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "Desktop packages installed during run: ${#desktop_installed_now[@]}"
echo "RustDesk installed: yes"
echo "RustDesk version: ${rustdesk_after}"
echo "RustDesk service active: $(systemctl is-active rustdesk.service 2>/dev/null || echo missing)"
echo "LightDM active: $(systemctl is-active lightdm.service 2>/dev/null || echo missing)"
echo "Reboot required: $(test -f /var/run/reboot-required && echo yes || echo no)"

echo
case "$overall_label" in
  OK)
    echo "Desktop GUI and RustDesk phase completed successfully."
    ;;
  INFO)
    echo "Desktop GUI and RustDesk phase completed with informational findings."
    ;;
  WARNING)
    echo "Desktop GUI and RustDesk phase completed with warning findings."
    ;;
  *)
    echo "Desktop GUI and RustDesk phase completed with error findings."
    ;;
esac

exit "$overall_code"
