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
# Required for unattended RustDesk access:
#   RUSTDESK_PERMANENT_PASSWORD={{global.cets_rd_perm_pass}}
#
# Optional for self-hosted RustDesk infrastructure:
#   RUSTDESK_RENDEZVOUS_SERVER={{global.cets_rd_rendezvous}}
#   RUSTDESK_RELAY_SERVER={{global.cets_rd_relay}}
#   RUSTDESK_API_SERVER={{global.cets_rd_api}}
#   RUSTDESK_KEY={{global.cets_rd_key}}
#
# Optional package pinning / override:
#   RUSTDESK_VERSION={{global.cets_rd_version}}
#   RUSTDESK_DEB_URL={{global.cets_rd_deb_url}}

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

default_if_zero() {
  local value="$1"
  if [[ "${value,,}" == "zero" ]]; then
    printf ''
  else
    printf '%s' "$value"
  fi
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
RUSTDESK_VERSION="$(default_if_zero "$RUSTDESK_VERSION")"
RUSTDESK_DEB_URL="$(default_if_zero "$RUSTDESK_DEB_URL")"
RUSTDESK_RENDEZVOUS_SERVER="$(default_if_zero "$RUSTDESK_RENDEZVOUS_SERVER")"
RUSTDESK_RELAY_SERVER="$(default_if_zero "$RUSTDESK_RELAY_SERVER")"
RUSTDESK_API_SERVER="$(default_if_zero "$RUSTDESK_API_SERVER")"
RUSTDESK_KEY="$(default_if_zero "$RUSTDESK_KEY")"
if [[ -z "$RUSTDESK_VERSION" ]]; then
  RUSTDESK_VERSION="latest"
fi
RUSTDESK_CONFIG_DIR="/root/.config/rustdesk"
RUSTDESK_CONFIG_FILE="${RUSTDESK_CONFIG_DIR}/RustDesk2.toml"
SHORTCUT_IP="${SHORTCUT_IP:-}"

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
echo "=== DESKTOP SHORTCUTS ==="
if [[ -z "$SHORTCUT_IP" || "${SHORTCUT_IP,,}" == "zero" ]]; then
  SHORTCUT_IP="$(
    hostname -I 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\\./) {print $i; exit}}'
  )"
fi
if [[ -z "$SHORTCUT_IP" ]]; then
  SHORTCUT_IP="$hostname_value"
fi

create_desktop_shortcut() {
  local target_dir="$1"
  local owner="$2"
  local group="$3"
  local file_name="$4"
  local display_name="$5"
  local url="$6"

  install -d -o "$owner" -g "$group" -m 0755 "$target_dir"
  cat >"${target_dir}/${file_name}" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${display_name}
Comment=Open ${display_name}
Exec=firefox-esr ${url}
Icon=firefox-esr
Terminal=false
Categories=Network;WebBrowser;
EOF
  chmod 0755 "${target_dir}/${file_name}"
  chown "$owner:$group" "${target_dir}/${file_name}"
}

shortcut_targets=("/etc/skel/Desktop:root:root")
while IFS=: read -r user_name _ uid gid _ home_dir shell_path; do
  if (( uid >= 1000 && uid < 60000 )) && [[ -d "$home_dir" ]] && [[ "$shell_path" != */nologin && "$shell_path" != */false ]]; then
    group_name="$(getent group "$gid" | cut -d: -f1)"
    shortcut_targets+=("${home_dir}/Desktop:${user_name}:${group_name:-$user_name}")
  fi
done </etc/passwd

for target in "${shortcut_targets[@]}"; do
  IFS=: read -r target_dir owner group <<<"$target"
  create_desktop_shortcut "$target_dir" "$owner" "$group" "librenms.desktop" "LibreNMS" "http://${SHORTCUT_IP}:8000/"
  create_desktop_shortcut "$target_dir" "$owner" "$group" "checkmk.desktop" "Checkmk" "http://${SHORTCUT_IP}:8080/cmk/check_mk/"
done
echo "Desktop shortcuts installed for LibreNMS and Checkmk using ${SHORTCUT_IP}."

echo
echo "=== FIREFOX BOOKMARKS POLICY ==="
FIREFOX_BIN="$(readlink -f "$(command -v firefox-esr)")"
FIREFOX_POLICY_DIR="$(dirname "$FIREFOX_BIN")/distribution"
FIREFOX_POLICY_FILE="${FIREFOX_POLICY_DIR}/policies.json"
install -d -o root -g root -m 0755 "$FIREFOX_POLICY_DIR"
python3 - "$FIREFOX_POLICY_FILE" "$SHORTCUT_IP" <<'PY'
import json
import sys

path, host = sys.argv[1:3]
payload = {
    "policies": {
        "DisplayBookmarksToolbar": "always",
        "ManagedBookmarks": [
            {"toplevel_name": "CETS"},
            {"name": "LibreNMS", "url": f"http://{host}:8000/"},
            {"name": "Checkmk", "url": f"http://{host}:8080/cmk/check_mk/"},
        ],
    }
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
chmod 0644 "$FIREFOX_POLICY_FILE"
echo "Firefox managed bookmarks policy: ${FIREFOX_POLICY_FILE}"

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
echo "RustDesk permanent password supplied: $(test -n "$RUSTDESK_PERMANENT_PASSWORD" && echo yes || echo no)"
echo "Desktop shortcut host: ${SHORTCUT_IP}"
echo "Firefox bookmarks policy: ${FIREFOX_POLICY_FILE}"
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
