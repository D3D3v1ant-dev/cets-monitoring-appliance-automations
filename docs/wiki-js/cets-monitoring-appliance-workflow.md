# CETS Linux Monitoring Appliance

## Engineering User Guide, Deployment Workflow, And Maintenance Runbook

**Audience:** CETS IT engineers, infrastructure administrators, monitoring
engineers, and future maintainers  
**Platform:** Debian 13, Tactical RMM, Docker, LibreNMS, Checkmk, Postfix, and
Cloudflare Tunnel  
**Document status:** POC workflow validated through Phase 6 on 2026-09-02  
**Source repository:** <https://github.com/D3D3v1ant-dev/cets-monitoring-appliance-automations>

> This page must not contain credentials. Secret values belong in Tactical's
> global key store or protected files on the appliance, never in Wiki.js, Git,
> tickets, screenshots, or chat transcripts.

## 1. Overview

The CETS Linux Monitoring Appliance is a repeatable, remotely managed Debian
system that provides:

- LibreNMS network monitoring.
- Checkmk infrastructure monitoring.
- A local unauthenticated SMTP relay for approved devices such as Avid NEXIS.
- Authenticated Gmail delivery for outbound alert email.
- Cloudflare Tunnel publication without inbound Internet port forwarding.
- Cloudflare Access authentication in front of the monitoring web interfaces.
- Tactical RMM orchestration, audit output, and repeatable remediation.

The implementation is intentionally divided into small, idempotent phases. Each
phase is developed in Git, published to Tactical, run only against the intended
agent, independently verified, and run a second time before acceptance.

## 2. Responsibility Boundary

```text
OPSI
  -> unattended Debian installation
  -> Tactical agent bootstrap

Tactical RMM
  -> Linux configuration
  -> packages and updates
  -> Docker
  -> monitoring applications
  -> SMTP relay
  -> Cloudflare Tunnel
  -> future firewall, watchdog, and validation phases

GitHub
  -> authoritative reusable scripts and documentation

SSH
  -> independent verification and diagnostics
```

Do not use SSH-only fixes as the final solution. Diagnose with SSH, correct the
source script, republish it through Tactical, rerun it, and verify the result.

## 3. Current POC Inventory

| Item | Current value |
| --- | --- |
| Hostname | `cets-mon-poc-01` |
| Operating system | Debian GNU/Linux 13.6 Trixie, amd64 |
| POC address observed during validation | `10.96.17.159/22` |
| Connected subnet observed during validation | `10.96.16.0/22` |
| Tactical category | `DDELANEY (Linux):Automations` |
| Tactical serial task | `CETS Monitoring Appliance Serial Run` |
| Tactical serial task ID | `112` |
| Appliance configuration root | `/opt/cets` |
| LibreNMS host port | TCP `8000` |
| Checkmk host port | TCP `8080` |
| SMTP relay listener | TCP `25` |
| SMTP upstream | `smtp.gmail.com:587` with TLS and authentication |

The current POC agent ID is recorded in the repository serial profile. Always
perform an exact live hostname lookup before execution; do not rely on a copied
identifier without validating it.

## 4. Safety Rules

1. Target exactly one agent whose hostname is `cets-mon-poc-01` during the POC.
2. Stop if zero or multiple agents match.
3. Never use Tactical bulk execution for this workflow.
4. Never modify `rmm.cets.com.au`, `api.cets.com.au`, or `mesh.cets.com.au`.
5. Never print, log, commit, or document credential values.
6. Treat unexpected non-published exit codes as failures.
7. Preserve existing application data and Cloudflare resources during reruns.
8. Do not progress to the next phase until execution, SSH validation, and
   idempotency checks pass.

## 5. Source Layout

The GitHub repository is arranged as follows:

```text
scripts/
  phase-00-poc-roundtrip.sh
  phase-01-baseline-audit.sh
  phase-02-linux-baseline.sh
  phase-03-docker-engine.sh
  phase-04-monitoring-stack.sh
  phase-05-smtp-relay.sh
  phase-06-cloudflare-tunnel.sh

profiles/
  cets-monitoring-appliance-phase-series.yaml

reports/
  point-in-time phase validation reports

docs/pathfinder/
  resumable engineering handoffs

docs/wiki-js/
  Wiki.js-ready engineering documentation
```

The production-style folder for scripts inside Tactical is:

```text
DDELANEY (Linux):Automations
```

## 6. Tactical Exit Codes And Audit Output

Every script uses the published Tactical result convention:

| Code | Meaning | Operator action |
| ---: | --- | --- |
| `0` | OK | Continue |
| `2` | Warning | Continue only after reviewing the warning |
| `5` | Informational | Continue after recording the finding |
| `98` | Tactical timeout | Investigate timeout and host state |
| Other non-zero | Error | Stop, diagnose, correct automation, rerun |

Each phase prints a structured audit summary including the hostname, result,
important state, and any warning or informational condition. A Tactical launch
acknowledgement is not proof of success; inspect the resulting history entry and
its return code.

## 7. Secrets And Runtime Variables

### Tactical Global Keys

The workflow expects these key names:

| Key | Purpose |
| --- | --- |
| `cets_gmail_smtp_user` | Gmail SMTP account address |
| `cets_gmail_smtp_app_pw` | Gmail SMTP app password |
| `cets_cf_tunnels_api` | Cloudflare account API token |
| `cets_cf_account_id` | Cloudflare account ID |

Do not place their values in scripts. Tactical task actions map the values into
environment variables only at execution time.

### On-Host Secret Files

| Path | Content | Required protection |
| --- | --- | --- |
| `/opt/cets/monitoring/librenms/librenms.env` | LibreNMS database settings | Root-controlled, never commit |
| `/opt/cets/monitoring/checkmk/checkmk.env` | Checkmk bootstrap password | Root-controlled, never commit |
| `/etc/postfix/sasl_passwd` | Gmail relay credential | Mode `0600`, never print |
| `/etc/postfix/sasl_passwd.db` | Postfix credential map | Protect with source file |
| `/etc/cets/cloudflared.env` | Cloudflare connector token | `root:root`, mode `0600` |

## 8. Provisioning Phases

### Phase 0 - POC Roundtrip

**Tactical script:** `CETS Monitoring Appliance - 00 POC Roundtrip`  
**Script ID:** `240`

Purpose:

- Prove exact agent discovery.
- Prove Tactical script publication and execution.
- Report host, user, kernel, architecture, OS, time, and Tactical service state.
- Establish the Tactical and SSH comparison loop without changing the host.

Acceptance requires Tactical and SSH results to agree.

### Phase 1 - Baseline Audit

**Tactical script:** `CETS Monitoring Appliance - 01 Baseline Audit`  
**Script ID:** `241`

This phase is read-only. It inventories:

- OS, kernel, architecture, hostname, timezone, and NTP.
- CPU, RAM, swap, disks, filesystems, and free space.
- Interfaces, addresses, routes, and DNS.
- Tactical, Mesh, SSH, and failed systemd services.
- Listening ports, packages, APT sources, Docker, firewall, and AppArmor.
- Unattended-upgrades state and outbound DNS/HTTPS.

Use the baseline report to compare later changes and identify regressions.

### Phase 2 - Linux Baseline

**Tactical script:** `CETS Monitoring Appliance - 02 Linux Baseline`  
**Script ID:** `242`

This phase installs the core package set, creates the `/opt/cets` hierarchy,
configures unattended upgrades, enables APT timers, and verifies outbound HTTPS.

The appliance layout is:

```text
/opt/cets/
  monitoring/
  cloudflare/
  postfix/
  scripts/
  state/
  logs/
```

`state` and `logs` use restricted directory permissions.

### Phase 3 - Docker Engine

**Tactical script:** `CETS Monitoring Appliance - 03 Docker Engine`  
**Script ID:** `243`

This phase:

- Removes or detects conflicting Docker packages safely.
- Configures Docker's official Debian repository and signing key.
- Installs Docker Engine, CLI, containerd, Buildx, and Compose.
- Enables Docker and containerd.
- Validates the engine with a test container.

Check both `docker.service` and `containerd.service` after execution.

### Phase 4 - Monitoring Stack

**Tactical script:** `CETS Monitoring Appliance - 04 Monitoring Stack`  
**Script ID:** `244`

Deployed containers:

| Container | Function |
| --- | --- |
| `cets_librenms` | LibreNMS web application and poller |
| `cets_librenms_dispatcher` | LibreNMS dispatcher sidecar |
| `cets_librenms_db` | MariaDB data store |
| `cets_librenms_redis` | Redis service |
| `cets_checkmk` | Checkmk Community site |

Persistent named volumes protect monitoring and database data across container
replacement. Passwords are generated on the host only when absent, then reused
on subsequent runs.

Local URLs:

```text
LibreNMS: http://<appliance-interface-address>:8000/
Checkmk:  http://<appliance-interface-address>:8080/cmk/check_mk/
```

The services deliberately bind to all interfaces so a DHCP address change does
not require rebuilding the compose files. Phase 7 must apply the approved
network access policy around these listeners.

### Phase 5 - SMTP Relay

**Tactical script:** `CETS Monitoring Appliance - 05 SMTP Relay`  
**Script ID:** `245`

Use case:

- An Avid **NEXIS** on the local subnet cannot authenticate to SMTP.
- NEXIS submits mail anonymously to the appliance on TCP `25`.
- Postfix accepts relay only from the trusted directly attached subnet.
- Postfix authenticates to Gmail and forwards mail using TLS on TCP `587`.

Default flow:

```text
Avid NEXIS
  -> appliance DHCP address, TCP 25, no SMTP authentication
  -> Postfix trusted-subnet check
  -> smtp.gmail.com:587, STARTTLS and authentication
  -> recipient
```

Important variables:

| Variable | Default or purpose |
| --- | --- |
| `SMTP_SERVER` | `smtp.gmail.com` |
| `SMTP_PORT` | `587` |
| `SMTP_RELAY_DOMAIN` | `cets.com.au` |
| `SMTP_HOSTNAME` | Appliance hostname |
| `SMTP_LISTEN_PORT` | `25` |
| `AUTO_DETECT_CLIENT_NETWORKS` | `yes` |
| `DEFAULT_CLIENT_NETWORKS` | Fallback trusted networks |
| `ALLOWED_CLIENT_NETWORKS` | Explicit override |
| `SMTP_AUTH_USERNAME` | Tactical global key injection |
| `SMTP_AUTH_PASSWORD` | Tactical global key injection |
| `POSTFIX_TEST_RECIPIENT` | Optional live test recipient |

The script detects the connected IPv4 subnet where possible. If detection is
not appropriate at a site, set `ALLOWED_CLIENT_NETWORKS` explicitly using CIDR
notation. Never configure `0.0.0.0/0`; that would create an open relay.

### Phase 6 - Cloudflare Tunnel

**Tactical script:** `CETS Monitoring Appliance - 06 Cloudflare Tunnel`  
**Script ID:** `246`

This phase:

- Installs `cloudflared` if needed.
- Looks up or creates one remotely managed tunnel.
- Retrieves the connector token at runtime.
- Looks up or creates Access applications.
- Updates remotely managed ingress rules.
- Looks up, creates, or corrects proxied CNAME records.
- Installs and starts a systemd service.
- Stores the connector token outside the unit command line.

One tunnel serves both applications. Separate tunnels are unnecessary because
ingress maps each hostname to a different local origin.

Generated naming:

```text
Tunnel label: <short-hostname>-<two-digit-year>.<zone>
LibreNMS:     libre-<short-hostname>-<two-digit-year>.<zone>
Checkmk:      cmk-<short-hostname>-<two-digit-year>.<zone>
```

For the current POC:

```text
Tunnel:   cets-mon-poc-01-26.cets.com.au
LibreNMS: https://libre-cets-mon-poc-01-26.cets.com.au
Checkmk:  https://cmk-cets-mon-poc-01-26.cets.com.au
```

The application hostnames intentionally use one subdomain level. On a full DNS
zone, Cloudflare Universal SSL covers the apex and first-level subdomains; a
name such as `libre.host.cets.com.au` requires additional certificate coverage.
See [Cloudflare Universal SSL limitations](https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/).

Important variables:

| Variable | Default or purpose |
| --- | --- |
| `EXPECTED_HOSTNAME` | Optional in-script safety assertion |
| `CLOUDFLARE_API_TOKEN` | Tactical global key injection |
| `CLOUDFLARE_ACCOUNT_ID` | Tactical global key injection |
| `CLOUDFLARE_TUNNEL_NAME_OVERRIDE` | Optional tunnel label override |
| `CLOUDFLARE_PUBLIC_PREFIX_LIBRE` | `libre` |
| `CLOUDFLARE_PUBLIC_PREFIX_CMK` | `cmk` |
| `CLOUDFLARE_PUBLIC_HOSTNAMES` | Optional explicit pair, comma-separated |
| `CLOUDFLARE_LIBRE_ORIGIN` | `http://127.0.0.1:8000` |
| `CLOUDFLARE_CMK_ORIGIN` | `http://127.0.0.1:8080` |
| `CLOUDFLARE_ACCESS_EMAIL` | Identity allowed by a newly created Access app |
| `CLOUDFLARE_ACCESS_SESSION_DURATION` | `24h` |
| `CLOUDFLARE_ZONE_NAME` | `cets.com.au` |
| `CLOUDFLARE_ZONE_ID` | Optional explicit zone ID |

The API token requires the account-level Tunnel and Access permissions used by
the script plus DNS Write scoped to the intended zone. Follow least privilege
and do not grant unrelated account resources unless required.

## 9. End-User Instructions

### Access LibreNMS Or Checkmk Remotely

1. Open the supported HTTPS URL.
2. Complete the Cloudflare Access login or one-time PIN flow using an approved
   identity.
3. Continue to the application's own login page.
4. Use the application account issued by the monitoring administrator.

An anonymous request should be redirected to Cloudflare Access. If the
application login page appears without Cloudflare authentication, treat that as
a security defect.

### Access On The Local Subnet

Use the appliance's current DHCP address:

```text
http://<appliance-address>:8000/
http://<appliance-address>:8080/cmk/check_mk/
```

Local access is currently available on all interfaces. This is intentional for
the POC and must be reviewed in Phase 7.

### Configure Avid NEXIS Email Alerts

Use these NEXIS SMTP settings:

| Setting | Value |
| --- | --- |
| SMTP server | Current appliance interface IP or resolvable local hostname |
| Port | `25` |
| Authentication | None |
| Encryption from NEXIS to appliance | None unless later configured |
| Sender | A valid address accepted by the Gmail relay policy |
| Recipient | Intended alert recipient |

NEXIS must be on a subnet included in Postfix `mynetworks`. A device outside the
trusted subnet should be rejected from relaying.

## 10. Standard Engineering Workflow

For every change:

1. Pull the latest `main` branch.
2. Inspect the current script and relevant report.
3. Change the authoritative local script.
4. Run syntax and static checks.
5. Confirm no secret value appears in the diff.
6. Query Tactical and confirm exactly one intended agent.
7. Update the corresponding Tactical Script Manager entry through the API.
8. Verify the Tactical script body matches the Git source checksum.
9. Execute with full output during development.
10. Inspect the return code and audit summary.
11. Verify actual state independently over SSH.
12. Correct the automation if desired and actual state differ.
13. Run the same phase again through Tactical.
14. Confirm IDs, files, services, containers, and data were reused.
15. Update the report, profile, handoff, and Wiki.js page.
16. Commit and push only after all acceptance checks pass.

## 11. Running The Automation

### Full Serial Run

In Tactical:

1. Locate `CETS Monitoring Appliance Serial Run`.
2. Select only the exact intended agent.
3. Start the task.
4. Wait for a new history timestamp.
5. Open the task output and inspect each phase heading and audit summary.

The task launch message only confirms queuing. The history result confirms
execution.

### Single-Phase Development Run

Run the individual Tactical script with full output and the same global-key
environment mappings used by the serial task. Never paste the resolved secret
values into the script editor or ad-hoc arguments.

## 12. Validation Runbook

### Host Services

```bash
systemctl is-active tacticalagent.service
systemctl is-active docker.service
systemctl is-active postfix.service
systemctl is-active cloudflared.service
systemctl is-enabled cloudflared.service
```

### Monitoring Containers

```bash
docker ps --filter name=cets_ --format '{{.Names}} | {{.Status}} | {{.Ports}}'
curl -I http://127.0.0.1:8000/
curl -I http://127.0.0.1:8080/cmk/check_mk/
```

### SMTP Relay

```bash
postconf relayhost mynetworks inet_interfaces smtp_tls_security_level
ss -lntp 'sport = :25'
journalctl -u postfix --since today --no-pager
```

To submit an intentional test through Phase 5, provide
`POSTFIX_TEST_RECIPIENT` as a temporary Tactical environment variable. Confirm
receipt and then inspect the Postfix log for successful Gmail delivery.

### Cloudflare Tunnel

```bash
systemctl status cloudflared --no-pager
journalctl -u cloudflared -n 100 --no-pager
stat -c '%U:%G %a %n' /etc/cets/cloudflared.env
ps -o args= -p "$(systemctl show cloudflared -p MainPID --value)"
```

Expected results:

- The service is active and enabled.
- Multiple tunnel connections are registered.
- The environment file is `root:root` and `0600`.
- The process command does not contain a token.
- Public HTTPS returns a Cloudflare Access redirect for an unauthenticated
  request.

## 13. Troubleshooting

### Public Name Does Not Resolve Internally

The CETS environment uses split-horizon DNS. Cloudflare's public authoritative
servers contain the application records, while the internal `cets.com.au` zone
does not currently contain matching records.

Verify separately:

```bash
dig +short libre-cets-mon-poc-01-26.cets.com.au
dig @1.1.1.1 +short libre-cets-mon-poc-01-26.cets.com.au
```

If only the public query succeeds, correct internal DNS with approved CNAMEs,
delegation, or conditional forwarding. Do not use hosts files as the permanent
solution.

### TLS Handshake Fails

Confirm the hostname has only one label before `cets.com.au`. Two-level names
are not covered by standard Universal SSL on a full zone without Advanced
Certificate Manager or Total TLS.

Also confirm the DNS record is proxied and allow time for certificate
provisioning after first creation.

### Cloudflare Returns 502 Or 1033

- Confirm `cloudflared` is active.
- Confirm the tunnel ID matches the intended tunnel.
- Inspect registered connection logs.
- Confirm each local origin responds on `127.0.0.1`.
- Confirm the remote ingress configuration contains both supported hostnames and
  ends with a `404` fallback.

### Access Is Not Prompting For Authentication

- Confirm a self-hosted Access application exactly matches the hostname.
- Confirm it has an allow policy for the approved identity or group.
- Test from a private browser session with no existing Access cookie.
- Do not disable Access merely to make the page load.

### Cloudflare API Returns Duplicate Errors

The current Phase 6 script performs exact lookups before creation. Confirm
Tactical script `246` matches GitHub before rerunning. Do not automatically
delete a tunnel or Access application to resolve a lookup defect.

### Cloudflare API Returns Permission Errors

Confirm the Tactical global key contains the intended account token and that the
token has:

- Required Tunnel read/write access.
- Required Access application and policy read/write access.
- DNS Write scoped to `cets.com.au`.

Do not hardcode a replacement token into the script.

### NEXIS Cannot Send Mail

- Confirm the appliance's current DHCP address.
- Confirm TCP `25` is listening on the expected interface.
- Confirm the NEXIS source address belongs to Postfix `mynetworks`.
- Inspect the Postfix log while sending a test.
- Confirm Gmail credentials are still valid in Tactical's key store.
- Confirm outbound TCP `587` and DNS are permitted.
- Check Gmail sender and relay restrictions.

### Monitoring Containers Restart Or Become Slow

The POC has approximately 2 GiB RAM and has used swap. Check:

```bash
free -h
docker stats --no-stream
docker ps -a --filter name=cets_
journalctl -k --since today --no-pager
```

Increase production sizing rather than treating sustained swap or OOM events as
normal.

### Docker Compose Variable Warnings

Warnings for `LIBRENMS_BIND_HOST` or `CHECKMK_BIND_HOST` are currently cosmetic;
the deployed compose files bind to `0.0.0.0`. Remove the stale variable
references or define them consistently in a future maintenance revision so task
history remains clean.

## 14. Security Model

- Internet clients reach Cloudflare, not an inbound forwarded appliance port.
- Cloudflare Access authenticates before requests reach LibreNMS or Checkmk.
- The tunnel is outbound-only from the appliance.
- The Cloudflare API token stays in Tactical's global key store.
- The connector token is root-only and absent from process arguments.
- SMTP submission is anonymous only from explicitly trusted local networks.
- Gmail submission is authenticated and requires TLS.
- Application credentials are generated and retained on the appliance.
- GitHub stores reusable logic but no credentials.

Review logs before sharing them. Error output, process listings, environment
files, Postfix maps, and Tactical action payloads can expose credentials if
handled carelessly.

## 15. Backup And Recovery

At minimum, protect:

- Docker named volumes for LibreNMS data, MariaDB, and Checkmk sites.
- `/opt/cets/monitoring` compose and environment files.
- `/etc/postfix/main.cf` and the protected relay credential material.
- `/opt/cets/cloudflare/config.yml` and systemd unit configuration.
- Tactical script definitions, task ordering, and global-key names.
- GitHub repository history and validation reports.

Do not back up secret files into an unencrypted repository. Use the approved
backup system with access control and encryption.

Recovery order:

1. Restore Debian and Tactical connectivity through OPSI.
2. Run Phases 0-3.
3. Restore application volumes and protected configuration where required.
4. Run Phase 4 and validate application data.
5. Run Phase 5 and send a controlled email test.
6. Run Phase 6 and confirm the existing Cloudflare resources are reused.
7. Complete firewall, watchdog, and full validation phases.

## 16. Current Status And Next Work

| Phase | Status |
| --- | --- |
| 00 POC Roundtrip | Passed |
| 01 Baseline Audit | Passed |
| 02 Linux Baseline | Passed |
| 03 Docker Engine | Passed |
| 04 Monitoring Stack | Passed with capacity information |
| 05 SMTP Relay | Passed; live email received |
| 06 Cloudflare Tunnel | Passed; HTTPS and Access validated; rerun passed |
| 07 Firewall | Next |
| 08 Watchdogs | Not started |
| 09 Validation | Not started |

Before Phase 7, decide how internal DNS will resolve the supported Cloudflare
names. Then design the firewall around the actual Docker forwarding behaviour,
Tactical and Mesh connectivity, SSH management, NEXIS SMTP, and Cloudflare
egress. Validate every required path before and after applying rules.

## 17. Change Acceptance Template

Record this for every phase or maintenance revision:

```text
SCRIPT: <name and ID>

TACTICAL:
PASS / FAIL
History ID, timestamp, return code, duration, and relevant audit output

SSH VERIFICATION:
PASS / FAIL
Observed services, files, permissions, listeners, containers, and logs

IDEMPOTENCY:
NOT TESTED / PASS / FAIL
Resource IDs and state before and after the second run

DEFECT:
Description or none

CORRECTION:
Source change and reason

SECURITY REVIEW:
Confirmation that no credential value entered output, Git, or documentation

NEXT:
Exact next action and any required decision
```

## 18. References

- [CETS monitoring automation repository](https://github.com/D3D3v1ant-dev/cets-monitoring-appliance-automations)
- [Cloudflare Tunnel setup](https://developers.cloudflare.com/tunnel/setup/)
- [Cloudflare Tunnel published applications](https://developers.cloudflare.com/tunnel/routing/)
- [Cloudflare Universal SSL limitations](https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/)
- [Cloudflare Access self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
