# CETS Monitoring Appliance Linux Baseline Report

Date: 2026-09-02
Host: cets-mon-poc-01
Phase: 02 Linux Baseline
Tactical Script: CETS Monitoring Appliance - 02 Linux Baseline
Tactical Category: DDELANEY (Linux):Automations
Agent ID: uKvvRrkLkMGYcdguEuDzzYgySzWUxMqBdtegkXIx
Overall Result: OK

## Summary

The Linux baseline phase completed successfully through Tactical and was independently validated over SSH on Wednesday, September 2, 2026.
The script established the reusable Debian base needed before Docker, monitoring applications, SMTP relay, Cloudflare Tunnel, and firewall policy phases.

## Changes Applied

- Installed core packages:
  - `curl`
  - `git`
  - `gnupg`
  - `jq`
  - `python3-venv`
  - `unattended-upgrades`
  - `unzip`
- Confirmed already-present baseline packages:
  - `apt-listchanges`
  - `ca-certificates`
  - `lsb-release`
  - `python3`
  - `wget`
- Created the appliance directory layout:
  - `/opt/cets`
  - `/opt/cets/monitoring`
  - `/opt/cets/cloudflare`
  - `/opt/cets/postfix`
  - `/opt/cets/scripts`
  - `/opt/cets/state`
  - `/opt/cets/logs`
- Applied unattended-upgrades configuration in `/etc/apt/apt.conf.d/20auto-upgrades`
- Enabled:
  - `unattended-upgrades.service`
  - `apt-daily.timer`
  - `apt-daily-upgrade.timer`

## Validated State

- Hostname: `cets-mon-poc-01`
- Operating system: Debian GNU/Linux 13.6 (trixie)
- Kernel: `6.12.107+deb13-amd64`
- `curl` available at `/usr/bin/curl`
- `jq` available at `/usr/bin/jq`
- Git version: `2.47.3`
- Python version: `3.13.5`
- `/opt/cets` layout present with root ownership
- `/opt/cets/state` and `/opt/cets/logs` created with restricted `0750` permissions
- Unattended upgrades enabled and active
- `https://api.cets.com.au` reachable from the host with `HTTP 200`
- No reboot required after the baseline run

## Acceptance

- Tactical execution: PASS
- SSH validation: PASS
- Second-run idempotency: PASS

## Notes For Next Phase

- Docker is still intentionally not installed in this phase.
- Firewall rules are still intentionally deferred to the firewall phase.
- `/opt/cets` is now ready for later phase-owned templates, state, and logs.
