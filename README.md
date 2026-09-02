# CETS Monitoring Appliance Automations

Reusable automation assets for the CETS Linux Monitoring Appliance proof of concept.

## Purpose

This repository stores the reusable Tactical RMM automation scripts, helper tooling, baseline audit artifacts, and the serial phase profile used during the appliance engineering process.

## Current Contents

- `scripts/phase-00-poc-roundtrip.sh`
- `scripts/phase-01-baseline-audit.sh`
- `scripts/phase-02-linux-baseline.sh`
- `scripts/phase-03-docker-engine.sh`
- `scripts/phase-04-monitoring-stack.sh`
- `scripts/phase-05-smtp-relay.sh`
- `scripts/phase-06-cloudflare-tunnel.sh`
- `tools/tactical_phase0.py`
- `profiles/cets-monitoring-appliance-phase-series.yaml`
- `docs/pathfinder/cets-monitoring-appliance-handoff-2026-09-02.md`
- `docs/wiki-js/cets-monitoring-appliance-workflow.md`
- `reports/baseline-report-2026-09-02.md`
- `reports/linux-baseline-report-2026-09-02.md`
- `reports/docker-engine-report-2026-09-02.md`
- `reports/monitoring-stack-report-2026-09-02.md`
- `reports/cloudflare-tunnel-report-2026-09-02.md`

## Tactical Conventions

- Tactical category: `DDELANEY (Linux):Automations`
- Tactical script type: `Shell`
- Exit codes:
  - `0` = OK
  - `2` = Warning
  - `5` = Informational
  - any other non-zero = Error
  - `98` is reserved by Tactical for timeout handling
- Serial phase profile:
  - continue on `0`, `2`, or `5`
  - stop on any other exit code

## Notes

- Secrets must never be stored in this repository.
- Scripts are designed to be idempotent and safe to rerun.
- Reports capture observed baseline state on specific dates and should be treated as point-in-time artifacts.
