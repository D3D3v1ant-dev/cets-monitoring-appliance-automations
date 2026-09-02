# CETS Monitoring Appliance Baseline Report

Date: 2026-09-02
Host: cets-mon-poc-01
Phase: 01 Baseline Audit
Tactical Script: CETS Monitoring Appliance - 01 Baseline Audit
Tactical Category: DDELANEY (Linux):Automations
Agent ID: uKvvRrkLkMGYcdguEuDzzYgySzWUxMqBdtegkXIx
Overall Audit Result: INFO

## Summary

The baseline audit completed successfully through Tactical and was independently validated over SSH.
The script returned an informational result rather than a failure because Docker is not yet installed and `unattended-upgrades` is not installed, which is consistent with the current pre-provisioning state for this POC on 2026-09-02.

## Validated Findings

- Operating system: Debian GNU/Linux 13.6 (trixie)
- Kernel: 6.12.107+deb13-amd64
- Architecture: x86_64
- Timezone: Etc/UTC
- NTP: enabled and synchronised
- CPU: 4 vCPU, QEMU Virtual CPU version 2.5+
- Memory: 1.9 GiB RAM
- Swap: 2.0 GiB configured, 0 used during audit
- Root filesystem: 60G ext4 with 2.1G used and 55G available
- Boot filesystem: 943M ext4 with 139M used and 739M available
- Primary interface: ens18 with 10.96.17.159/22
- Default route: via 10.96.16.1 on ens18
- DNS resolver: 10.96.16.2
- Tactical agent service: enabled and active
- Mesh agent service: enabled and active
- SSH service: enabled and active
- Failed systemd units: 0
- Listening TCP ports: 22/ssh and 4441/opsiclientd
- Package count: 365 installed packages
- Docker: not installed
- Firewall: nftables present, no rules currently loaded
- AppArmor: enabled and active
- Unattended upgrades: not installed
- Outbound DNS: success for `api.cets.com.au`
- Outbound HTTPS: HTTP 200 from `https://api.cets.com.au`

## APT Sources

- `http://ftp.aarnet.edu.au/debian/` for `trixie`
- `http://security.debian.org/debian-security` for `trixie-security`
- `http://ftp.aarnet.edu.au/debian/` for `trixie-updates`

## Acceptance

- Tactical execution: PASS
- SSH validation: PASS
- Second-run idempotency: PASS

## Notes For Next Phase

- Docker is not yet installed, which is expected before Phase 03.
- No firewall rules are currently loaded.
- `unattended-upgrades` is not installed in the current baseline.
