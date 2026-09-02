# CETS Monitoring Appliance Automations

Reusable automation assets for the CETS Linux Monitoring Appliance proof of concept.

## Purpose

This repository stores the reusable Tactical RMM automation scripts, helper tooling, and baseline audit artifacts developed during the appliance engineering process.

## Current Contents

- `scripts/phase-00-poc-roundtrip.sh`
- `scripts/phase-01-baseline-audit.sh`
- `tools/tactical_phase0.py`
- `reports/baseline-report-2026-09-02.md`

## Tactical Conventions

- Tactical category: `DDELANEY (Linux):Automations`
- Tactical script type: `Shell`
- Exit codes:
  - `0` = OK
  - `2` = Warning
  - `5` = Informational
  - any other non-zero = Error
  - `98` is reserved by Tactical for timeout handling

## Notes

- Secrets must never be stored in this repository.
- Scripts are designed to be idempotent and safe to rerun.
- Reports capture observed baseline state on specific dates and should be treated as point-in-time artifacts.
