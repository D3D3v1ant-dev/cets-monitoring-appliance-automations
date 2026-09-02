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
  echo "ERROR: Docker engine phase failed at line ${line}: ${cmd}" >&2
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

arch="$(dpkg --print-architecture)"
codename="$(
  . /etc/os-release
  printf '%s' "${VERSION_CODENAME:-}"
)"

case "$arch" in
  amd64|arm64|armhf|ppc64el) ;;
  *)
    echo "ERROR: Unsupported Docker architecture ${arch}." >&2
    exit "$EXIT_ERROR"
    ;;
esac

case "$codename" in
  trixie|bookworm|bullseye) ;;
  *)
    echo "ERROR: Unsupported Debian release codename ${codename}." >&2
    exit "$EXIT_ERROR"
    ;;
esac

DOCKER_PACKAGES=(
  docker-ce
  docker-ce-cli
  containerd.io
  docker-buildx-plugin
  docker-compose-plugin
)

CONFLICTING_PACKAGES=(
  docker.io
  docker-compose
  docker-doc
  docker-buildx
  podman-docker
  containerd
  runc
)

docker_packages_before=()
docker_packages_missing=()
docker_packages_installed_now=()
for pkg in "${DOCKER_PACKAGES[@]}"; do
  if package_installed "$pkg"; then
    docker_packages_before+=("$pkg")
  else
    docker_packages_missing+=("$pkg")
  fi
done

conflicting_installed=()
for pkg in "${CONFLICTING_PACKAGES[@]}"; do
  if package_installed "$pkg"; then
    conflicting_installed+=("$pkg")
  fi
done

DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCE="/etc/apt/sources.list.d/docker.sources"
DOCKER_SOURCE_CONTENT="Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: ${DOCKER_KEYRING}
"

nft_rules_present="no"
if command -v nft >/dev/null 2>&1; then
  if nft list ruleset 2>/dev/null | grep -q '[^[:space:]]'; then
    nft_rules_present="yes"
    set_status "$EXIT_WARN" "WARNING"
  fi
fi

echo "=== CETS MONITORING APPLIANCE DOCKER ENGINE ==="
echo "Hostname: ${hostname_value}"
echo "Timestamp: $(date --iso-8601=seconds)"
echo "Architecture: ${arch}"
echo "Debian codename: ${codename}"

echo
echo "=== PRE-FLIGHT ==="
echo "Installed Docker packages before run: ${#docker_packages_before[@]}"
printf '%s\n' "${docker_packages_before[@]:-none}"
echo
echo "Missing Docker packages before run: ${#docker_packages_missing[@]}"
printf '%s\n' "${docker_packages_missing[@]:-none}"
echo
echo "Conflicting packages installed: ${#conflicting_installed[@]}"
printf '%s\n' "${conflicting_installed[@]:-none}"
echo "nftables rules present: ${nft_rules_present}"
if [[ "$nft_rules_present" == "yes" ]]; then
  echo "WARNING: Docker's published firewall guidance prefers iptables rules over nftables rulesets."
fi

export DEBIAN_FRONTEND=noninteractive

if ((${#conflicting_installed[@]} > 0)); then
  echo
  echo "=== REMOVE CONFLICTING PACKAGES ==="
  apt-get remove -y "${conflicting_installed[@]}"
fi

echo
echo "=== DOCKER REPOSITORY ==="
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o "${DOCKER_KEYRING}"
chmod 0644 "${DOCKER_KEYRING}"
printf '%s' "${DOCKER_SOURCE_CONTENT}" > "${DOCKER_SOURCE}"
chmod 0644 "${DOCKER_SOURCE}"
echo "--- ${DOCKER_SOURCE} ---"
cat "${DOCKER_SOURCE}"

echo
echo "=== APT UPDATE ==="
apt-get update

echo
echo "=== DOCKER INSTALL ==="
apt-get install -y --no-install-recommends "${DOCKER_PACKAGES[@]}"

for pkg in "${DOCKER_PACKAGES[@]}"; do
  if package_installed "$pkg"; then
    if [[ " ${docker_packages_missing[*]} " == *" ${pkg} "* ]]; then
      docker_packages_installed_now+=("$pkg")
    fi
  else
    echo "ERROR: Package ${pkg} is still not installed after apt-get." >&2
    exit "$EXIT_ERROR"
  fi
done

echo "Installed during this run: ${#docker_packages_installed_now[@]}"
printf '%s\n' "${docker_packages_installed_now[@]:-none}"

echo
echo "=== SERVICES ==="
if [[ "$(systemctl is-enabled containerd.service 2>/dev/null || true)" != "enabled" ]]; then
  systemctl enable containerd.service
fi
if [[ "$(systemctl is-active containerd.service 2>/dev/null || true)" != "active" ]]; then
  systemctl start containerd.service
fi
if [[ "$(systemctl is-enabled docker.service 2>/dev/null || true)" != "enabled" ]]; then
  systemctl enable docker.service
fi
if [[ "$(systemctl is-active docker.service 2>/dev/null || true)" != "active" ]]; then
  systemctl start docker.service
fi

echo "containerd enabled: $(systemctl is-enabled containerd.service)"
echo "containerd active: $(systemctl is-active containerd.service)"
echo "docker enabled: $(systemctl is-enabled docker.service)"
echo "docker active: $(systemctl is-active docker.service)"

echo
echo "=== DOCKER VALIDATION ==="
docker_version="$(docker --version)"
compose_version="$(docker compose version)"
buildx_version="$(docker buildx version | head -n 1)"
server_version="$(docker version --format '{{.Server.Version}}')"
info_driver="$(docker info --format 'Storage={{.Driver}} Cgroup={{.CgroupDriver}} Logging={{.LoggingDriver}}')"
printf '%s\n' "$docker_version"
printf '%s\n' "$compose_version"
printf '%s\n' "$buildx_version"
printf 'ServerVersion=%s\n' "$server_version"
printf '%s\n' "$info_driver"

hello_world_status="validated"
hello_world_output="$(docker run --rm --pull=missing hello-world 2>&1)"
printf '%s\n' "$hello_world_output"
if [[ "$hello_world_output" != *"Hello from Docker!"* ]]; then
  echo "ERROR: hello-world validation did not produce the expected confirmation." >&2
  exit "$EXIT_ERROR"
fi

if [[ -f /var/run/reboot-required ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "Docker packages installed during run: ${#docker_packages_installed_now[@]}"
echo "Docker repository configured: yes"
echo "docker.service enabled: $(systemctl is-enabled docker.service)"
echo "docker.service active: $(systemctl is-active docker.service)"
echo "containerd.service enabled: $(systemctl is-enabled containerd.service)"
echo "containerd.service active: $(systemctl is-active containerd.service)"
echo "hello-world validation: ${hello_world_status}"
echo "nftables rules present: ${nft_rules_present}"
echo "Reboot required: $(test -f /var/run/reboot-required && echo yes || echo no)"

echo
case "$overall_label" in
  OK)
    echo "Docker engine baseline completed successfully."
    ;;
  INFO)
    echo "Docker engine baseline completed with informational findings."
    ;;
  WARNING)
    echo "Docker engine baseline completed with warning findings."
    ;;
  *)
    echo "Docker engine baseline completed with error findings."
    ;;
esac

exit "$overall_code"
