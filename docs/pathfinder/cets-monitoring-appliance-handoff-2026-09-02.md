# Pathfinder Handoff - CETS Monitoring Appliance POC

**Log date:** 2026-09-02  
**Prepared for:** CETS IT engineering  
**Status at handoff:** Phases 0-6 deployed and validated; Phase 7 is next  
**Authoritative repository:** <https://github.com/D3D3v1ant-dev/cets-monitoring-appliance-automations>  
**Branch:** `main`

## Purpose

This log captures the complete state of the CETS Linux Monitoring Appliance POC
at the end of the 2026-09-02 engineering session. It is intended to make the
work safely resumable from another computer without relying on chat history.

No credential values are recorded here. Obtain access through the approved
credential stores before continuing.

## Scope And Safety Boundary

- The only authorised target is `cets-mon-poc-01`.
- The target is a disposable Debian 13 POC at `10.96.17.159`.
- Confirm exactly one Tactical agent matches the hostname before every run.
- Do not use bulk actions or substitute a similar agent.
- Do not modify the production Tactical hostnames `rmm.cets.com.au`,
  `api.cets.com.au`, or `mesh.cets.com.au`.
- Persistent corrections belong in automation, not as undocumented manual host
  changes.
- Never commit API tokens, app passwords, SSH passwords, generated application
  credentials, or Cloudflare connector tokens.

## Important Identifiers

| Item | Value |
| --- | --- |
| POC hostname | `cets-mon-poc-01` |
| Operating system | Debian 13.6 Trixie, amd64 |
| POC address observed today | `10.96.17.159/22` |
| Tactical agent ID | `uKvvRrkLkMGYcdguEuDzzYgySzWUxMqBdtegkXIx` |
| Tactical category | `DDELANEY (Linux):Automations` |
| Tactical serial task | `CETS Monitoring Appliance Serial Run` |
| Tactical serial task ID | `112` |
| Cloudflare account ID source | Tactical global key `cets_cf_account_id` |
| Cloudflare API token source | Tactical global key `cets_cf_tunnels_api` |
| Gmail SMTP user source | Tactical global key `cets_gmail_smtp_user` |
| Gmail app password source | Tactical global key `cets_gmail_smtp_app_pw` |

## Architecture Established

The provisioning boundary is now:

```text
OPSI
  -> Debian unattended deployment
  -> Tactical agent bootstrap and check-in
  -> Tactical serial post-install automation
  -> Linux baseline
  -> Docker Engine
  -> LibreNMS and Checkmk
  -> Postfix SMTP relay
  -> Cloudflare Tunnel and Access
```

- OPSI owns the OS installation and Tactical bootstrap.
- Tactical owns post-install configuration and orchestration.
- GitHub holds the reusable source of truth.
- SSH is the independent inspection and diagnostic path.
- Cloudflare provides outbound-only publication and Access authentication.

## Tactical Automation State

The serial task contains these actions in order:

| Order | Phase | Tactical script ID | Result |
| ---: | --- | ---: | --- |
| 0 | `00 POC Roundtrip` | `240` | Passed |
| 1 | `01 Baseline Audit` | `241` | Passed |
| 2 | `02 Linux Baseline` | `242` | Passed |
| 3 | `03 Docker Engine` | `243` | Passed |
| 4 | `04 Monitoring Stack` | `244` | Passed with informational finding |
| 5 | `05 SMTP Relay` | `245` | Passed with informational finding |
| 6 | `06 Cloudflare Tunnel` | `246` | Passed with informational finding |

The task references secrets rather than storing values in scripts:

```text
Phase 05:
SMTP_AUTH_USERNAME={{global.cets_gmail_smtp_user}}
SMTP_AUTH_PASSWORD={{global.cets_gmail_smtp_app_pw}}

Phase 06:
CLOUDFLARE_API_TOKEN={{global.cets_cf_tunnels_api}}
CLOUDFLARE_ACCOUNT_ID={{global.cets_cf_account_id}}
```

Tactical result codes used by every phase are:

- `0`: OK
- `2`: Warning
- `5`: Informational
- Any other non-zero value: Error
- `98`: Tactical timeout reservation

The current Tactical task is configured to continue through phases that return
`0`, `2`, or `5`. Review this behaviour before using it as a production
remediation workflow because its current `continue_on_error` setting is broader
than the desired final stop-on-error policy.

## Work Completed Today

### Phase 0 - POC Roundtrip

- Located exactly one Tactical agent named `cets-mon-poc-01`.
- Proved Tactical API script publication and execution.
- Confirmed host identity, OS, kernel, architecture, time, and Tactical service.
- Independently matched the results over SSH.

### Phase 1 - Baseline Audit

- Built and ran a read-only baseline audit.
- Captured CPU, memory, storage, interfaces, routes, DNS, packages, services,
  listening ports, APT, firewall, AppArmor, Docker state, and outbound access.
- Confirmed Debian 13.6, four vCPUs, approximately 2 GiB RAM, a 60 GiB root
  filesystem, and the `10.96.16.0/22` connected network.
- Confirmed Tactical, Mesh, SSH, NTP, and AppArmor were active.
- Confirmed Docker and unattended upgrades were not yet installed, as expected.

### Phase 2 - Linux Baseline

- Installed the reusable package baseline including `curl`, `git`, `gnupg`,
  `jq`, Python tooling, `unattended-upgrades`, `unzip`, and `wget`.
- Created the standard `/opt/cets` directory layout.
- Enabled unattended upgrades and the APT maintenance timers.
- Verified outbound HTTPS to the Tactical API.
- Passed a second-run idempotency check.

### Phase 3 - Docker Engine

- Installed Docker Engine from Docker's official Debian repository.
- Installed Docker Compose and Buildx plugins.
- Enabled Docker and containerd.
- Validated the engine with `hello-world`.
- Passed SSH validation and a second-run idempotency check.

### Phase 4 - Monitoring Stack

- Deployed LibreNMS and Checkmk with Docker Compose under
  `/opt/cets/monitoring`.
- Corrected LibreNMS database and Redis configuration.
- Persisted application data in named Docker volumes.
- Generated bootstrap credentials only on the appliance.
- Published LibreNMS on all interfaces at TCP `8000`.
- Published Checkmk on all interfaces at TCP `8080`.
- Confirmed Checkmk healthy and both web applications responding.
- Passed a second-run idempotency check.
- Retained an informational capacity finding because the POC has only about
  2 GiB RAM.

### Phase 5 - SMTP Relay

- Installed and configured Postfix as a local unauthenticated relay for the
  directly attached client subnet.
- Configured Postfix to listen on all appliance interfaces on TCP `25`.
- Auto-detected the connected DHCP subnet as `10.96.16.0/22`.
- Restricted unauthenticated relay permission to loopback and that subnet.
- Configured authenticated TLS forwarding through Gmail at
  `smtp.gmail.com:587`.
- Sourced the Gmail address and app password from Tactical global keys.
- Sent a live test to `ddelaney@cets.com.au`; receipt was confirmed by the user.
- The intended unauthenticated source device is an Avid **NEXIS**.

### Phase 6 - Cloudflare Tunnel

- Installed and enabled `cloudflared` on the appliance.
- Created a remotely managed tunnel through the Cloudflare API.
- Kept the API token in Tactical's global key store.
- Updated the Cloudflare token to include zone-scoped DNS Write access for
  `cets.com.au` while retaining the required Tunnel and Access permissions.
- Added safe lookup-first handling for tunnels, Access apps, and DNS records.
- Corrected JSON parsing that had previously caused existing objects to be
  mistaken for missing objects.
- Added race-safe create handling without deleting existing objects.
- Added remotely managed ingress configuration for both monitoring services.
- Stored the connector token at `/etc/cets/cloudflared.env` with root-only
  `0600` permissions.
- Removed the connector token from the systemd command line.
- Removed failing command text from the Bash error trap to reduce secret-leak
  risk.
- Made hostname validation optional through `EXPECTED_HOSTNAME` so the script is
  reusable, while Tactical targeting remains the external POC safety control.
- Made the zone and service origins configurable.

The current tunnel is:

```text
cets-mon-poc-01-26.cets.com.au
Tunnel ID: bc29d14d-d5fd-4072-a5a2-c8d0df74cc37
```

The working public applications are:

```text
LibreNMS: https://libre-cets-mon-poc-01-26.cets.com.au
Checkmk:  https://cmk-cets-mon-poc-01-26.cets.com.au
```

The original two-level names were not compatible with Universal SSL on this
full Cloudflare DNS zone. The automation now generates one-level names using:

```text
<service>-<short-hostname>-<two-digit-year>.cets.com.au
```

Cloudflare currently retains the earlier protected two-level DNS, Access, and
ingress objects as a deliberate non-destructive safety measure. They are not the
supported URLs and can be reviewed for manual retirement later.

## Final Phase 6 Validation Evidence

The corrected serial run completed at `2026-09-02T07:22:20Z` and returned the
Tactical informational result. The mandatory second Phase 6 run completed at
`2026-09-02T07:26:49Z` in approximately six seconds.

The second run reused all identifiers:

| Resource | ID |
| --- | --- |
| Tunnel | `bc29d14d-d5fd-4072-a5a2-c8d0df74cc37` |
| LibreNMS Access app | `afb226c6-1c0e-4b3f-b75e-c50b6e2a6ec6` |
| Checkmk Access app | `8d069bea-1876-4ec2-b238-f84847d887eb` |
| LibreNMS DNS record | `ab53cad0bbc81236c55c6a0b931140e9` |
| Checkmk DNS record | `c1acf713a5c3c75e91006658c277be0e` |

Verification results:

- Public DNS resolved both supported names through `1.1.1.1`.
- TLS verification returned success for both names.
- Anonymous HTTPS requests returned `302` to Cloudflare Access.
- Direct origin content was not anonymously exposed through Cloudflare.
- The tunnel registered four QUIC connections in Brisbane and Sydney.
- `cloudflared.service` remained enabled and active after the rerun.
- The process command was only `/usr/bin/cloudflared tunnel run`; no token was
  visible in the process list.
- Checkmk remained healthy and the monitoring containers retained their data.

## Current Host State

| Component | Current state |
| --- | --- |
| Tactical agent | Online |
| Mesh agent | Active |
| SSH | Active on TCP `22` |
| Docker | Active |
| LibreNMS | Running, host TCP `8000` |
| Checkmk | Running and healthy, host TCP `8080` |
| Postfix | Active, listening on TCP `25` |
| cloudflared | Enabled and active |
| Unattended upgrades | Enabled |

Important paths:

```text
/opt/cets/monitoring/
/opt/cets/monitoring/librenms/compose.yaml
/opt/cets/monitoring/librenms/librenms.env
/opt/cets/monitoring/checkmk/compose.yaml
/opt/cets/monitoring/checkmk/checkmk.env
/opt/cets/monitoring/bootstrap-notes.txt
/opt/cets/cloudflare/config.yml
/etc/cets/cloudflared.env
/etc/systemd/system/cloudflared.service
/etc/postfix/main.cf
/etc/postfix/sasl_passwd
/var/backups/cets-monitoring-appliance/
```

## Known Issues And Decisions Pending

### Internal Split DNS

Public DNS is correct, but the CETS internal resolver is authoritative for its
own `cets.com.au` view and does not currently contain the new records. Therefore
the supported public names may not resolve from a workstation using internal
CETS DNS even though they work externally.

Choose one of these approaches before general internal use:

1. Add matching CNAME records to the internal `cets.com.au` zone.
2. Delegate or conditionally forward the relevant namespace to Cloudflare.
3. Use an approved public DNS path on the client network where policy permits.

Do not work around this permanently with per-machine hosts-file entries.

### Cloudflare Access Membership

The current Access applications allow the configured address supplied through
`CLOUDFLARE_ACCESS_EMAIL`, presently the engineering test user. For production,
replace this with the approved identity group or access policy. Existing Access
applications are reused by Phase 6; changing the variable alone does not yet
reconcile an existing application's policy.

### Monitoring Capacity

The POC has approximately 2 GiB RAM and already used swap during the later
serial run. Treat the current sizing as functional POC capacity, not the final
production recommendation.

### Monitoring Port Exposure

Phase 4 intentionally publishes TCP `8000` and `8080` on all interfaces so the
appliance remains reachable after DHCP subnet changes. Phase 7 must restrict
these ports appropriately while preserving local administration and Cloudflare
origin access.

### Compose Warnings

The serial run still reports informational Docker Compose warnings that
`LIBRENMS_BIND_HOST` and `CHECKMK_BIND_HOST` are unset in the deployed compose
context. The effective port mappings are `0.0.0.0`, and both services work, but
the warning source should be normalised during the next maintenance pass.

## Exact Continuation Point For Tomorrow

1. Clone or pull the authoritative GitHub repository and inspect `main`.
2. Confirm the final pushed commit contains this handoff, the Wiki.js guide,
   Phase 6, the Phase 6 report, and the updated serial profile.
3. Confirm exactly one online Tactical agent matches `cets-mon-poc-01` before
   any execution.
4. Confirm Tactical script `246` still matches the repository Phase 6 checksum.
5. Resolve or formally document the internal split-DNS approach.
6. Begin **Phase 7 - Firewall** as a new idempotent script.
7. Preserve SSH, Tactical, NEXIS-to-SMTP, and Cloudflare egress while reducing
   unnecessary direct exposure.
8. Publish Phase 7 to Tactical under `DDELANEY (Linux):Automations`, add it to
   serial task `112`, execute it, verify over SSH, and rerun it for idempotency.
9. Continue with Phase 8 Watchdogs and Phase 9 Validation only after Phase 7
   passes.

## Recommended Phase 7 Acceptance Tests

- Tactical and Mesh agents remain online.
- SSH remains available from approved management networks.
- NEXIS clients on the detected local subnet can reach TCP `25`.
- Untrusted networks cannot use the appliance as an SMTP relay.
- Docker forwarding rules do not bypass the intended host policy.
- LibreNMS and Checkmk remain reachable through Cloudflare Access.
- Direct TCP `8000` and `8080` access matches the approved local-access policy.
- DNS, HTTPS, NTP, APT, Gmail SMTP submission, and Cloudflare Tunnel egress work.
- A second Phase 7 run produces no duplicate rules and no outage.

## Resume Checklist

```bash
git clone https://github.com/D3D3v1ant-dev/cets-monitoring-appliance-automations.git
cd cets-monitoring-appliance-automations
git status
git log -1 --oneline
bash -n scripts/phase-06-cloudflare-tunnel.sh
```

Before using Tactical or SSH, load credentials through the approved secure
method. Do not place them in shell history, source files, documentation, or Git.
