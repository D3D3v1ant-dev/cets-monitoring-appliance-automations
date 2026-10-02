# CETS Monitoring Appliance Deployment And Operations Runbook

**Audience:** CETS IT engineers, monitoring administrators, support engineers,
and future maintainers

**Platform:** Debian 13, Tactical RMM, Docker, LibreNMS, Checkmk, Postfix,
Cloudflare Tunnel, Cloudflare Access, XFCE, Firefox, and RustDesk

**Current validation host:** `cets-bbmon-01` at `10.236.8.10`

**Primary repository:** <https://github.com/D3D3v1ant-dev/cets-monitoring-appliance-automations>

> Do not put credentials in Wiki.js, Git, tickets, screenshots, or chat
> transcripts. Secret values belong in Tactical global keys, application
> credential stores, or protected root-only files on the appliance.

## 1. Purpose

The CETS monitoring appliance is a repeatable Debian-based monitoring box that
can be deployed at customer or production sites without requiring an inbound
firewall rule, CETS firewall, or VPN path back to the site.

It provides:

- LibreNMS for network and device monitoring.
- Checkmk for host, service, Windows agent, and application-aware monitoring.
- A local SMTP relay for services that cannot authenticate directly to Gmail,
  especially Avid NEXIS.
- Cloudflare Tunnel for outbound-only remote web access.
- Cloudflare Access in front of the monitoring web applications.
- A desktop GUI and RustDesk for emergency remote access.
- Tactical RMM orchestration, reruns, audit output, and recovery.

The intended deployment style is: install Debian 13, install the Tactical
agent, run the CETS monitoring appliance automation, then onboard monitored
devices into LibreNMS and Checkmk.

## 2. Architecture

```text
Local editorial/site network
  -> Avid suites, Avid NEXIS, switches, workstations, servers
  -> Monitoring appliance
       -> LibreNMS on local TCP 8000
       -> Checkmk on local TCP 8080
       -> Postfix SMTP relay on local TCP 25
       -> Docker containers for monitoring applications
       -> Cloudflare Tunnel outbound to Cloudflare
       -> Tactical RMM and Mesh agent
       -> RustDesk service

Remote engineer
  -> Cloudflare Access
  -> Cloudflare Tunnel
  -> LibreNMS or Checkmk
```

No inbound Internet port forward is required. This is particularly useful where
we do not control the firewall, do not have a CETS firewall on site, or do not
currently have VPN connectivity.

## 3. Deployment Summary

1. Install Debian 13 on the appliance hardware.
2. Ensure network access, DNS, NTP, and outbound Internet are working.
3. Install the Tactical RMM Linux agent.
4. Confirm the appliance appears online in Tactical.
5. Run the CETS monitoring appliance serial automation.
6. Review the final handover summary at the end of the script output.
7. Test internal web access from the site network.
8. Test Cloudflare Access from an external network, such as a phone on mobile
   data.
9. Add monitored hosts to LibreNMS and Checkmk.
10. Build dashboards that show useful operational state with minimal noise.

## 4. Installing Debian 13

Install Debian 13 Trixie using the normal OPSI workflow where possible. If OPSI
is unavailable or unreliable for the hardware, installing Debian from a USB
stick is acceptable.

Recommended base choices:

- Debian GNU/Linux 13 Trixie, amd64.
- Standard system utilities.
- SSH server.
- Desktop environment is optional at install time because Phase 7 can install
  the GUI, Firefox, and RustDesk.
- A stable hostname that identifies the site or role, for example
  `cets-bbmon-01`.
- Timezone: `Australia/Brisbane`.

The automation is designed to run on different hostnames. `EXPECTED_HOSTNAME`
can be set as a safety guard for a specific run, but should be left unset when
the same script needs to be reusable across multiple appliances.

After the OS install, verify:

```bash
hostname
ip addr
ip route
resolvectl status || cat /etc/resolv.conf
timedatectl
ssh localhost
```

The appliance must be able to reach Debian repositories, Docker repositories,
GitHub, Gmail SMTP, Cloudflare, Tactical, and MeshCentral.

## 5. Installing The Tactical Agent

Install the Tactical Linux agent using the current CETS Tactical agent install
method.

After installation, confirm:

```bash
systemctl is-enabled tacticalagent.service
systemctl is-active tacticalagent.service
```

In Tactical:

- Confirm the agent is online.
- Confirm the hostname and IP address are correct.
- Do not run the appliance automation in bulk.
- Select only the intended appliance agent.

## 6. Tactical Automation Phases

The automation is split into phases so each part is idempotent and easy to
diagnose.

| Phase | Tactical script | Purpose |
| ---: | --- | --- |
| 00 | `CETS Monitoring Appliance - 00 POC Roundtrip` | Proves Tactical execution and basic host identity |
| 01 | `CETS Monitoring Appliance - 01 Baseline Audit` | Read-only host, OS, service, network, and package audit |
| 02 | `CETS Monitoring Appliance - 02 Linux Baseline` | Core packages, timezone, unattended upgrades, `/opt/cets` layout |
| 03 | `CETS Monitoring Appliance - 03 Docker Engine` | Docker repository, Docker Engine, Compose, validation |
| 04 | `CETS Monitoring Appliance - 04 Monitoring Stack` | LibreNMS, Checkmk, MariaDB, Redis, Docker Compose |
| 05 | `CETS Monitoring Appliance - 05 SMTP Relay` | Postfix local SMTP relay to authenticated Gmail SMTP |
| 06 | `CETS Monitoring Appliance - 06 Cloudflare Tunnel` | Cloudflare tunnel, DNS records, Access apps and policies |
| 07 | `CETS Monitoring Appliance - 07 Desktop GUI and RustDesk` | XFCE, LightDM, Firefox bookmarks, RustDesk |

Exit-code convention:

| Code | Meaning | Action |
| ---: | --- | --- |
| `0` | OK | Continue |
| `2` | Warning | Review warning, then continue if understood |
| `5` | Informational | Record the finding |
| `98` | Tactical timeout | Investigate host and task state |
| Other non-zero | Error | Stop, diagnose, fix automation, rerun |

The scripts should be safe to rerun. Rerunning should preserve existing
containers, Docker volumes, Cloudflare resources, generated credentials, and
configuration unless a script variable explicitly requests a change.

## 7. Tactical Key Store Variables

Keep key names short enough for Tactical key-store field limits.

Core variables:

| Tactical key | Purpose |
| --- | --- |
| `cets_gmail_smtp_user` | Gmail SMTP username |
| `cets_gmail_smtp_app_pw` | Gmail SMTP app password |
| `cets_cf_tunnels_api` | Cloudflare API token |
| `cets_cf_account_id` | Cloudflare account ID |
| `cets_lnms_db_user` | LibreNMS database username |
| `cets_lnms_db_pass` | LibreNMS database password |
| `cets_lnms_admin_user` | LibreNMS administrator username |
| `cets_lnms_admin_pass` | LibreNMS administrator password |
| `cets_cmk_user` | Checkmk operator username note |
| `cets_cmk_pass` | Checkmk `cmkadmin` password |
| `cets_alert_email` | Default alert recipient |

RustDesk variables:

| Tactical key | Purpose |
| --- | --- |
| `cets_rd_rendezvous` | RustDesk rendezvous server |
| `cets_rd_relay` | RustDesk relay server |
| `cets_rd_api` | RustDesk API/server field if required |
| `cets_rd_key` | RustDesk public key |
| `cets_rd_version` | RustDesk version |
| `cets_rd_deb_url` | Explicit RustDesk `.deb` URL |
| `cets_rd_password` | RustDesk permanent password |

If a RustDesk optional key contains the literal text `zero`, the automation
treats that value as "use the default". This lets placeholder keys exist
without forcing a custom RustDesk server or package URL.

## 8. Post-Run Handover Summary

The end of the serial task should include a clear handover summary every time.
Use this summary before closing the deployment task.

It should include:

- Appliance hostname and IP address.
- LibreNMS internal URL.
- Checkmk internal URL.
- Cloudflare LibreNMS URL.
- Cloudflare Checkmk URL.
- LibreNMS username to use.
- Checkmk username to use.
- SMTP relay host, port, allowed client networks, upstream server, and alert
  recipient.
- RustDesk installation state and whether custom/default server settings are in
  use.
- Reminder that password values are not printed.

If the summary is missing, rerun the current automation after confirming the
Git source and Tactical script entries are current.

## 9. Local Web Access

From the same editorial/site network, use the internal URLs:

```text
LibreNMS: http://<appliance-ip>:8000/
Checkmk:  http://<appliance-ip>:8080/cmk/check_mk/
```

For the current validation appliance:

```text
LibreNMS: http://10.236.8.10:8000/
Checkmk:  http://10.236.8.10:8080/cmk/check_mk/
```

Use the local URLs when you are physically on the editorial network or connected
through a working site VPN. This avoids internal DNS ambiguity and is usually
the fastest management path.

## 10. Cloudflare Access

Cloudflare provides remote HTTPS access without opening inbound ports.

Generated public naming:

```text
Tunnel:   <short-hostname>-<two-digit-year>.cets.com.au
LibreNMS: libre-<short-hostname>-<two-digit-year>.cets.com.au
Checkmk:  cmk-<short-hostname>-<two-digit-year>.cets.com.au
```

For the current validation appliance:

```text
LibreNMS: https://libre-cets-bbmon-01-26.cets.com.au
Checkmk:  https://cmk-cets-bbmon-01-26.cets.com.au
```

Access flow:

1. Open the Cloudflare URL.
2. Cloudflare Access prompts for authentication.
3. Enter `it@cets.com.au` unless a different approved account has been added.
4. Wait for the one-time code email.
5. Enter the code.
6. Continue to the LibreNMS or Checkmk application login page.
7. Log in with the application credentials from the deployment handover.

Cloudflare Access authenticates the outer web path. LibreNMS and Checkmk still
have their own application logins. Both layers are expected.

### When Cloudflare Is Most Useful

Use Cloudflare access when:

- There is no CETS firewall at the site.
- There is no working VPN to the site.
- The site firewall is not under CETS control.
- Remote support needs access without asking for an inbound port forward.
- A temporary POC or event site needs monitoring access quickly.

### Internal Split DNS Caveat

CETS uses split DNS in some environments. This can cause confusion when testing
Cloudflare names from inside the same network as the appliance.

The public Cloudflare DNS record may exist, but the internal DNS server for
`cets.com.au` may not know about it. From inside the network, the public
hostname can fail with DNS errors even though it works from mobile data or an
external network.

Symptoms:

- Cloudflare URL works on a phone using mobile data.
- The same URL fails on the local LAN.
- Direct internal URLs using the appliance IP still work.
- `dig @1.1.1.1 cmk-...cets.com.au` resolves, but normal local DNS does not.

Useful checks:

```bash
dig +short cmk-cets-bbmon-01-26.cets.com.au
dig @1.1.1.1 +short cmk-cets-bbmon-01-26.cets.com.au
```

Preferred fixes:

- Add matching internal CNAME records.
- Delegate or conditionally forward the relevant namespace.
- Use the internal appliance IP when working from the editorial network.

Do not use local hosts-file edits as the permanent fix.

## 11. SMTP Relay And NEXIS Notifications

The appliance runs Postfix as a local SMTP relay.

Purpose:

- Avid NEXIS and some appliances can send simple unauthenticated SMTP but
  cannot authenticate directly to Gmail.
- The monitoring appliance accepts SMTP from trusted local networks only.
- The appliance then relays outbound mail to Gmail using TLS and authenticated
  credentials from Tactical.

Default flow:

```text
Avid NEXIS or local device
  -> monitoring appliance TCP 25, no authentication
  -> Postfix trusted network check
  -> smtp.gmail.com TCP 587 with STARTTLS and authentication
  -> it@cets.com.au or configured recipients
```

NEXIS SMTP settings:

| Setting | Value |
| --- | --- |
| SMTP server | Appliance internal IP or local DNS name |
| SMTP port | `25` |
| Authentication | None |
| Encryption to appliance | None unless later configured |
| Sender | A valid CETS sender address |
| Recipient | At minimum `it@cets.com.au` |

Important caveats:

- The relay must never be open to the world.
- `mynetworks` should include only loopback, the connected site subnet, Docker
  networks where required, and any explicitly approved source subnet.
- Do not configure `0.0.0.0/0`.
- If NEXIS cannot send, first verify it is on an allowed subnet.
- If the appliance can queue mail but not deliver, check Gmail credentials,
  DNS, outbound TCP `587`, and Postfix logs.

Useful commands on the appliance:

```bash
postconf relayhost mynetworks inet_interfaces smtp_tls_security_level
ss -lntp 'sport = :25'
journalctl -u postfix --since today --no-pager
mailq
```

## 12. Desktop GUI And RustDesk

Phase 7 installs:

- XFCE desktop.
- LightDM display manager.
- Firefox ESR.
- Firefox managed bookmarks for LibreNMS and Checkmk.
- RustDesk.

Desktop shortcuts can be inconsistent depending on desktop policies, so Firefox
managed bookmarks are the preferred simple operator path. The bookmarks bar
should contain local LibreNMS and Checkmk links.

RustDesk should:

- Be installed from the configured or default package source.
- Run as a system service.
- Use Tactical key-store values for permanent password and optional server
  configuration.
- Avoid printing password values in output.

Use RustDesk as a fallback remote access method, not as the primary management
model. Tactical, SSH, Cloudflare, and the monitoring UIs remain the normal
operational paths.

## 13. Adding Devices To LibreNMS

Use LibreNMS primarily for network-style monitoring:

- Switches.
- Routers.
- UPS devices.
- Storage appliances that expose SNMP.
- Avid NEXIS management interfaces if SNMP is enabled and supported.
- Other SNMP-capable infrastructure devices.

Basic workflow:

1. Confirm the target device is reachable from the appliance.
2. Confirm SNMP is enabled on the device.
3. In LibreNMS, add the device by hostname or IP.
4. Select the correct SNMP version and community or credentials.
5. Let LibreNMS discover ports, sensors, storage, and system data.
6. Review discovered ports and disable noisy or irrelevant ones.
7. Set device groups, location, and alert rules.
8. Confirm alert delivery through the appliance SMTP path.

For NEXIS, use LibreNMS where the appliance exposes SNMP or useful network
metrics. Use Checkmk for Windows edit-suite agents and host/service health.

## 14. Adding Hosts To Checkmk

Use Checkmk primarily for:

- Windows workstations and servers.
- Linux hosts.
- Application service state.
- Agent-based metrics.
- Event logs.
- Custom local checks.

For a Windows Avid edit suite:

1. Install the Checkmk Windows agent on the workstation.
2. Confirm the agent is reachable from the appliance on TCP `6556`.
3. In Checkmk, add the host by hostname where possible.
4. Set the IP address attribute if DNS does not resolve correctly.
5. Use a folder such as `Avid Edit Suites` or a site-specific folder.
6. Add labels, for example:
   - `cets/role: avid-media-composer-edit-suite`
   - `cets/service: big-brother`
   - `cets/location: editorial-network`
7. Run service discovery.
8. Accept the relevant discovered services.
9. Activate changes.

For the current validation group, hosts were initially added by IP:

| Friendly role | Current address |
| --- | --- |
| `bb-online02` | `10.236.8.150` |
| `bb-online01` | `10.236.8.151` |
| `bb-screening` | `10.236.8.152` |
| `bb-playout` | `10.236.8.153` |
| `bb-spare` | `10.236.8.230` |

Checkmk can display friendly hostnames while still monitoring fixed IPs. The
preferred model is a readable host object name with the IP stored as an
attribute, rather than using IP addresses as display names forever.

## 15. Avid Editorial Checkmk Tuning

The Avid editorial monitoring is layered.

### Standard Windows Agent Metrics

Checkmk already collects general system health, including:

- Host up/down.
- Checkmk agent health.
- CPU load and processor utilisation.
- Memory usage.
- Filesystem usage.
- Physical disk/performance counters.
- Network interfaces.
- Uptime.
- Windows time status.
- Selected Windows services.
- Event log/logwatch findings.
- Discovery status.

### Tuned Windows Services

For Avid Media Composer suites, monitor Avid/NEXIS/licensing/audio/GPU-related
services that should exist and run automatically.

Current required service set in the local check:

| Service | Purpose |
| --- | --- |
| `AvidFosFS` | Avid/NEXIS filesystem component |
| `AvidNEXISClientLoggingService` | NEXIS client logging |
| `AvidSearchDb` | Avid search database |
| `AudioEndpointBuilder` | Windows audio endpoint service |
| `Audiosrv` | Windows audio service |
| `dvhlp` | Avid helper/service component observed on suites |
| `NVDisplay.ContainerLocalSystem` | NVIDIA display container |
| `PaceLicenseDServices` | PACE licensing |
| `SentinelKeysServer` | Sentinel licensing |
| `SentinelProtectionServer` | Sentinel licensing |
| `SentinelSecurityRuntime` | Sentinel licensing |

Optional Avid helper services are reported as informational detail only when not
present, because they are not installed as Windows services on every observed
Media Composer build:

- `Avid_Editor_Broker`
- `Avid_Editor_Db_Engine`
- `Avid_Editor_Transcode_Status`
- `Avid_NEXIS_Benchmark_Agent`

Do not make optional or on-demand helper services CRIT unless there is a site
requirement proving they must always exist and run.

### CETS Avid Local Check

The custom local check is installed on each Windows client at:

```text
C:\ProgramData\checkmk\agent\local\CETS-Checkmk-Avid-Media-Composer-Local.ps1
```

Source file:

```text
scripts/windows/CETS-Checkmk-Avid-Media-Composer-Local.ps1
```

Checkmk runs this automatically through the Windows agent. It does not require a
Windows scheduled task. The script caches results for 300 seconds so repeated
polls do not repeatedly query Windows services, processes, adapters, and event
logs.

It creates four services per host:

| Checkmk service | What it reports |
| --- | --- |
| `CETS Avid Required Services` | Required Avid/NEXIS/licensing/audio/GPU service health |
| `CETS Avid Media Composer Application` | Media Composer install/version and whether the app process is open |
| `CETS Avid Recent Events` | Recent Avid/NEXIS/licensing-related warnings/errors |
| `CETS Avid Edit Network Adapters` | Likely edit/NEXIS 10GbE adapter link state |

The local check is read-only. It does not start Media Composer, stop services,
modify NEXIS settings, or change Windows configuration.

### Current Useful Findings

During validation the new check found:

- Media Composer `24.12.6` installed on the edit suites.
- Required Avid/NEXIS/licensing/audio/GPU services running.
- 10GbE edit/NEXIS adapters up on most hosts.
- Repeated `CE-AVID :1d` NetBT name conflict events across several suites.
- One likely edit/NEXIS adapter reported as `Not Present` on `bb-screening`.

The `CE-AVID` NetBT conflict is worth investigating separately. It is a useful
warning, but it should not be allowed to drown the dashboard in unrelated noise.

## 16. Deploying The Avid Local Check With Tactical

The Tactical script is:

```text
CETS Checkmk - Install Avid Media Composer Local Check
```

It:

1. Writes the PowerShell local-check file to the Checkmk Windows agent local
   directory.
2. Clears the local check cache.
3. Confirms the Checkmk Windows service exists.
4. Runs the local check once and prints the resulting Checkmk services.

After deployment, run Checkmk service discovery for the target hosts and accept
the four new local services.

On the Checkmk appliance:

```bash
docker exec cets_checkmk su - cmk -c 'cmk -IIv <host1> <host2> && cmk -R'
```

Then confirm:

```bash
docker exec cets_checkmk su - cmk -c 'cmk -D <host> | grep -F "CETS Avid"'
```

## 17. Building A Useful Low-Noise Dashboard

A good dashboard should show what an operator can act on. Avoid dumping every
metric onto the first screen.

Recommended dashboard sections:

| Section | Include |
| --- | --- |
| Overall status | Host problems, service problems, unhandled criticals |
| Avid suites | Five edit-suite hosts, their state, and only non-OK services |
| Avid app health | The four `CETS Avid ...` services |
| NEXIS path | NEXIS monitoring, SMTP relay status, switch/uplink status |
| Infrastructure | Appliance health, Docker containers, disk, memory, CPU |
| Network | 10GbE/edit interfaces and key switch ports |
| Alerts | Recent notifications and acknowledgement state |

Noise-reduction rules:

- Show problems first, not all services.
- Use host labels for Avid suites and filter dashboards by label.
- Keep Windows event log checks scoped to actionable providers/patterns.
- Ignore or downgrade known benign warnings after they are reviewed.
- Do not alert on Media Composer not running unless the machine is expected to
  be in an active operational state.
- Do not alert on optional Avid helper services that are not present on a
  particular build.
- Review vanished services after software updates before accepting them as
  normal.

Suggested Checkmk views/bookmarks:

- `Avid Edit Suites - Hosts`
- `Avid Edit Suites - Problems`
- `Avid Edit Suites - All Services`
- `Avid/NEXIS Events`
- `Monitoring Appliance Health`

## 18. Alerting Guidelines

At minimum, alert to:

```text
it@cets.com.au
```

Recommended alert categories:

- Appliance down.
- Checkmk or LibreNMS container down.
- Disk space critical.
- SMTP relay failure.
- Cloudflare tunnel down.
- Avid required services stopped.
- NEXIS service or network path problems.
- Edit-suite 10GbE adapter down.
- Repeated Avid/NEXIS/licensing critical event log entries.

Avoid paging for:

- Media Composer simply not open.
- One-off informational Windows events.
- Optional helper services absent on hosts where they are not installed.
- Discovery warnings that are already under active setup.

## 19. Validation Commands

On the appliance:

```bash
systemctl is-active tacticalagent.service
systemctl is-active docker.service
systemctl is-active postfix.service
systemctl is-active cloudflared.service
systemctl is-active rustdesk.service
docker ps --filter name=cets_ --format '{{.Names}} | {{.Status}} | {{.Ports}}'
curl -I http://127.0.0.1:8000/
curl -I http://127.0.0.1:8080/cmk/check_mk/
postconf relayhost mynetworks
journalctl -u cloudflared -n 100 --no-pager
journalctl -u postfix --since today --no-pager
```

For Checkmk host discovery:

```bash
docker exec cets_checkmk su - cmk -c 'cmk -IIv <host>'
docker exec cets_checkmk su - cmk -c 'cmk -R'
docker exec cets_checkmk su - cmk -c 'cmk -D <host>'
```

For Windows agent reachability from the appliance:

```bash
nc -zvw5 <windows-host-or-ip> 6556
```

## 20. Troubleshooting

### Cloudflare URL Does Not Work On The Local Network

Test from mobile data first. If it works externally but not internally, suspect
split DNS.

Use internal appliance IP URLs from the editorial network, or add proper
internal DNS records.

### Cloudflare Prompts But No Email Arrives

Confirm the entered address is allowed by the Cloudflare Access policy. Use
`it@cets.com.au` unless another identity has been explicitly added.

Also check spam/quarantine and confirm the Access app policy includes the
expected email or group.

### Cloudflare Shows The App Without Access Login

Treat this as a security defect. Confirm the Access application hostname
exactly matches the public hostname and that the DNS record is proxied.

### Cloudflare Shows 502 Or 1033

Check:

- `cloudflared` service is active.
- Local LibreNMS and Checkmk URLs respond on `127.0.0.1`.
- The tunnel ID matches the intended tunnel.
- The remote ingress rules point to the correct local origins.

### NEXIS Cannot Send Email

Check:

- NEXIS SMTP server is the appliance internal IP.
- NEXIS uses TCP `25`.
- No authentication is configured on NEXIS.
- NEXIS source IP is inside Postfix `mynetworks`.
- Appliance can resolve DNS and connect to `smtp.gmail.com:587`.
- Gmail SMTP key-store credentials are current.
- Mail is not stuck in `mailq`.

### Checkmk Does Not Show New Local Checks

Check:

- The Windows agent is installed and reachable on TCP `6556`.
- The script exists in `C:\ProgramData\checkmk\agent\local`.
- Tactical installer output shows four `CETS Avid ...` lines.
- Checkmk discovery has been run after installing the script.
- Changes have been activated/reloaded.

### Too Many Warnings

Do not disable monitoring wholesale. Instead:

- Identify whether the warning is actionable.
- Scope the rule to the Avid host label or folder.
- Downgrade known benign patterns.
- Exclude non-actionable services from discovery.
- Create a dashboard view that starts from unhandled CRIT/WARN states only.

## 21. Backup And Recovery

Protect:

- Docker named volumes for LibreNMS, MariaDB, Redis where applicable, and
  Checkmk.
- `/opt/cets/monitoring`.
- `/opt/cets/state`.
- `/opt/cets/cloudflare`.
- Postfix configuration and protected SASL maps.
- Tactical script definitions and key names.
- GitHub repository history.

Recovery outline:

1. Reinstall Debian 13 if required.
2. Restore Tactical connectivity.
3. Run Phases 00-03.
4. Restore monitoring volumes/configuration if recovering existing data.
5. Run Phase 04 and verify LibreNMS and Checkmk.
6. Run Phase 05 and send a controlled email test.
7. Run Phase 06 and confirm Cloudflare resources are reused.
8. Run Phase 07 and confirm RustDesk/GUI.
9. Re-run Checkmk discovery for restored hosts if needed.

## 22. Security Notes

- Do not expose LibreNMS or Checkmk directly to the Internet.
- Use Cloudflare Access for public access.
- Keep application logins enabled behind Cloudflare Access.
- Keep Cloudflare and SMTP secrets in Tactical key store only.
- Keep protected on-host files root-owned and non-world-readable.
- Do not create an open SMTP relay.
- Do not publish screenshots or logs containing tokens, app passwords, tunnel
  tokens, or generated application passwords.
- Review Cloudflare Access membership whenever staff or support requirements
  change.

## 23. Current Implementation Notes

- Current appliance: `cets-bbmon-01`.
- Current internal address observed during validation: `10.236.8.10`.
- Current Checkmk Avid suite hosts:
  - `bb-online02` / `10.236.8.150`
  - `bb-online01` / `10.236.8.151`
  - `bb-screening` / `10.236.8.152`
  - `bb-playout` / `10.236.8.153`
  - `bb-spare` / `10.236.8.230`
- Current custom Avid check is deployed through Tactical and source-controlled
  in Git.
- Repeated `CE-AVID :1d` NetBT name conflicts are currently the most prominent
  Avid-related warning.
- Checkmk TLS registration is worth completing later so Windows agent transport
  is encrypted and the TLS warning disappears.

## 24. References

- [CETS monitoring automation repository](https://github.com/D3D3v1ant-dev/cets-monitoring-appliance-automations)
- [Cloudflare Tunnel setup](https://developers.cloudflare.com/tunnel/setup/)
- [Cloudflare Tunnel routing](https://developers.cloudflare.com/tunnel/routing/)
- [Cloudflare Access self-hosted apps](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Cloudflare Universal SSL limitations](https://developers.cloudflare.com/ssl/edge-certificates/universal-ssl/limitations/)
- [Checkmk Windows agent](https://docs.checkmk.com/latest/en/agent_windows.html)
- [Checkmk local checks](https://docs.checkmk.com/latest/en/localchecks.html)
