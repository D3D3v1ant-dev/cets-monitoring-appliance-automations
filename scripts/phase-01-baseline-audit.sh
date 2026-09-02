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
  echo "ERROR: Baseline audit failed at line ${line}: ${cmd}" >&2
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

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

print_section() {
  local title="$1"
  shift

  echo
  echo "=== ${title} ==="
  "$@"
}

print_block() {
  local title="$1"
  local content="$2"

  echo
  echo "=== ${title} ==="
  printf '%s\n' "$content"
}

capture_cmd() {
  local fallback="$1"
  shift

  if "$@" >/tmp/cets_baseline_cmd.$$ 2>&1; then
    cat /tmp/cets_baseline_cmd.$$
    rm -f /tmp/cets_baseline_cmd.$$
    return 0
  fi

  cat /tmp/cets_baseline_cmd.$$ || true
  rm -f /tmp/cets_baseline_cmd.$$
  printf '%s\n' "$fallback"
  return 0
}

hostname_value="$(hostname)"
os_release_contents="$(cat /etc/os-release)"
kernel_value="$(uname -r)"
arch_value="$(uname -m)"
timezone_value="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")"
time_now="$(date --iso-8601=seconds)"
tactical_enabled="$(systemctl is-enabled tacticalagent.service 2>/dev/null || echo "unknown")"
tactical_active="$(systemctl is-active tacticalagent.service 2>/dev/null || echo "unknown")"
mesh_enabled="$(systemctl is-enabled meshagent.service 2>/dev/null || echo "missing")"
mesh_active="$(systemctl is-active meshagent.service 2>/dev/null || echo "missing")"
ssh_enabled="$(systemctl is-enabled ssh.service 2>/dev/null || echo "missing")"
ssh_active="$(systemctl is-active ssh.service 2>/dev/null || echo "missing")"
failed_services_count="$(systemctl --failed --no-legend 2>/dev/null | wc -l | awk '{print $1}')"
docker_state="not-installed"
docker_info_note="Docker binary not present"
apparmor_active="$(systemctl is-active apparmor.service 2>/dev/null || echo "missing")"
apparmor_enabled="$(systemctl is-enabled apparmor.service 2>/dev/null || echo "missing")"
unattended_state="not-installed"
dns_test_summary="unavailable"
https_test_summary="unavailable"

if have_cmd docker; then
  docker_state="installed"
  docker_info_note="Docker binary present"
else
  set_status "$EXIT_INFO" "INFO"
fi

if [[ "$hostname_value" != "cets-mon-poc-01" ]]; then
  set_status "$EXIT_ERROR" "ERROR"
fi

if [[ "$tactical_active" != "active" || "$tactical_enabled" != "enabled" ]]; then
  set_status "$EXIT_ERROR" "ERROR"
fi

if [[ "$mesh_active" != "active" || "$mesh_enabled" != "enabled" ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

if [[ "$ssh_active" != "active" || "$ssh_enabled" != "enabled" ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

if [[ "$failed_services_count" != "0" ]]; then
  set_status "$EXIT_WARN" "WARNING"
fi

if have_cmd timedatectl; then
  ntp_sync="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")"
  ntp_service="$(timedatectl show --property=NTP --value 2>/dev/null || echo "unknown")"
  if [[ "$ntp_sync" != "yes" ]]; then
    set_status "$EXIT_WARN" "WARNING"
  fi
else
  ntp_sync="unknown"
  ntp_service="unknown"
  set_status "$EXIT_INFO" "INFO"
fi

if dpkg-query -W -f='${Status}' unattended-upgrades >/tmp/cets_baseline_pkg.$$ 2>/dev/null; then
  unattended_state="$(cat /tmp/cets_baseline_pkg.$$)"
else
  unattended_state="not-installed"
  set_status "$EXIT_INFO" "INFO"
fi
rm -f /tmp/cets_baseline_pkg.$$ || true

if have_cmd dig; then
  dns_test_output="$(capture_cmd "DNS lookup failed" dig +time=3 +tries=1 +short api.cets.com.au A)"
  if [[ -n "$dns_test_output" && "$dns_test_output" != "DNS lookup failed" ]]; then
    dns_test_summary="success"
  else
    dns_test_summary="failed"
    set_status "$EXIT_WARN" "WARNING"
  fi
else
  dns_test_output="dig not installed"
  dns_test_summary="unavailable"
  set_status "$EXIT_INFO" "INFO"
fi

if have_cmd curl; then
  https_test_output="$(capture_cmd "HTTPS request failed" curl -I --silent --show-error --max-time 10 https://api.cets.com.au)"
  if printf '%s\n' "$https_test_output" | grep -q '^HTTP/'; then
    https_test_summary="success"
  else
    https_test_summary="failed"
    set_status "$EXIT_WARN" "WARNING"
  fi
elif have_cmd python3; then
  https_test_output="$(capture_cmd "HTTPS request failed" python3 -c 'import urllib.request; response = urllib.request.urlopen("https://api.cets.com.au", timeout=10); print("HTTP", response.status); print("Content-Type:", response.headers.get("Content-Type", "unknown"))')"
  if printf '%s\n' "$https_test_output" | grep -q '^HTTP '; then
    https_test_summary="success"
  else
    https_test_summary="failed"
    set_status "$EXIT_WARN" "WARNING"
  fi
elif have_cmd wget; then
  https_test_output="$(capture_cmd "HTTPS request failed" wget -S -O /dev/null --timeout=10 https://api.cets.com.au)"
  if printf '%s\n' "$https_test_output" | grep -q 'HTTP/'; then
    https_test_summary="success"
  else
    https_test_summary="failed"
    set_status "$EXIT_WARN" "WARNING"
  fi
else
  https_test_output="No supported HTTPS client installed"
  https_test_summary="unavailable"
  set_status "$EXIT_INFO" "INFO"
fi

print_block "BASELINE AUDIT HEADER" "Hostname: ${hostname_value}
Timestamp: ${time_now}
Overall Result: ${overall_label}"

print_block "OS RELEASE" "$os_release_contents"
print_block "KERNEL" "$kernel_value"
print_block "ARCHITECTURE" "$arch_value"
print_block "TIMEZONE" "$timezone_value"
print_block "TIME SYNCHRONISATION" "NTP enabled: ${ntp_service}
NTP synchronised: ${ntp_sync}"

print_section "CPU" lscpu
print_section "MEMORY" free -h
print_section "SWAP" swapon --show
print_section "BLOCK DEVICES" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
print_section "FILESYSTEMS" df -hT
print_section "INTERFACES" ip -brief link
print_section "ADDRESSES" ip -brief addr
print_section "ROUTES" ip route show
print_block "DNS CONFIG" "$(capture_cmd "Unable to read DNS configuration" bash -lc 'cat /etc/resolv.conf; if command -v resolvectl >/dev/null 2>&1; then echo; resolvectl status; fi')"
print_block "TACTICAL SERVICE" "Enabled: ${tactical_enabled}
Active: ${tactical_active}"
print_block "MESH AGENT SERVICE" "Enabled: ${mesh_enabled}
Active: ${mesh_active}"
print_block "SSH SERVICE" "Enabled: ${ssh_enabled}
Active: ${ssh_active}"
print_section "FAILED SYSTEMD SERVICES" systemctl --failed --no-pager
print_section "LISTENING PORTS" ss -tulpn
print_block "APT SOURCES" "$(capture_cmd "Unable to read APT sources" bash -lc 'found=0; for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do [ -e "$file" ] || continue; found=1; echo "--- $file ---"; cat "$file"; echo; done; if [ "$found" -eq 0 ]; then echo "No APT source files found"; fi')"
print_block "PACKAGE COUNT" "$(dpkg-query -f '.' -W 2>/dev/null | wc -c | awk '{print "Installed packages: " $1}')"

if have_cmd docker; then
  print_block "DOCKER STATE" "State: ${docker_state}
Note: ${docker_info_note}"
  print_section "DOCKER VERSION" docker version
  print_section "DOCKER PS" docker ps -a
else
  print_block "DOCKER STATE" "State: ${docker_state}
Note: ${docker_info_note}"
fi

if have_cmd ufw; then
  firewall_output="$(capture_cmd "ufw status unavailable" ufw status verbose)"
elif have_cmd firewall-cmd; then
  firewall_output="$(capture_cmd "firewalld status unavailable" firewall-cmd --state)"
elif have_cmd nft; then
  firewall_output="$(capture_cmd "nft ruleset unavailable" nft list ruleset)"
  if [[ -z "$firewall_output" ]]; then
    firewall_output="nftables present but no rules are currently loaded"
  fi
else
  firewall_output="No supported firewall tool detected"
  set_status "$EXIT_INFO" "INFO"
fi
print_block "FIREWALL STATE" "$firewall_output"

if have_cmd aa-status; then
  apparmor_detail="$(capture_cmd "AppArmor status unavailable" aa-status)"
else
  apparmor_detail="aa-status command not installed"
  set_status "$EXIT_INFO" "INFO"
fi
print_block "APPARMOR STATE" "Enabled: ${apparmor_enabled}
Active: ${apparmor_active}

${apparmor_detail}"

print_block "UNATTENDED-UPGRADES STATE" "$unattended_state"
print_block "OUTBOUND DNS" "Result: ${dns_test_summary}

${dns_test_output}"
print_block "OUTBOUND HTTPS" "Result: ${https_test_summary}

${https_test_output}"

echo
echo "=== AUDIT SUMMARY ==="
echo "Result: ${overall_label}"
echo "Hostname: ${hostname_value}"
echo "Kernel: ${kernel_value}"
echo "Architecture: ${arch_value}"
echo "Timezone: ${timezone_value}"
echo "NTP synchronised: ${ntp_sync}"
echo "Tactical active: ${tactical_active}"
echo "Mesh active: ${mesh_active}"
echo "SSH active: ${ssh_active}"
echo "Failed services count: ${failed_services_count}"
echo "Docker state: ${docker_state}"
echo "Unattended upgrades: ${unattended_state}"
echo "Outbound DNS: ${dns_test_summary}"
echo "Outbound HTTPS: ${https_test_summary}"

echo
case "$overall_label" in
  OK)
    echo "Baseline audit completed successfully."
    ;;
  INFO)
    echo "Baseline audit completed with informational findings."
    ;;
  WARNING)
    echo "Baseline audit completed with warning findings."
    ;;
  *)
    echo "Baseline audit completed with error findings."
    ;;
esac

exit "${overall_code}"
