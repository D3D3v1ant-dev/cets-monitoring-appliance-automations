# Cloudflare Tunnel Report - 2026-09-02

## Scope

- Target: `cets-mon-poc-01`
- Tactical script: `CETS Monitoring Appliance - 06 Cloudflare Tunnel`
- Tactical script ID: `246`
- Tactical serial task: `CETS Monitoring Appliance Serial Run` (`112`)
- Tunnel: `cets-mon-poc-01-26.cets.com.au`
- Tunnel ID: `bc29d14d-d5fd-4072-a5a2-c8d0df74cc37`

## Published Applications

- LibreNMS: `https://libre-cets-mon-poc-01-26.cets.com.au`
- Checkmk: `https://cmk-cets-mon-poc-01-26.cets.com.au`
- LibreNMS origin: `http://127.0.0.1:8000`
- Checkmk origin: `http://127.0.0.1:8080`

The generated public hostnames use one subdomain level so they are covered by
Cloudflare Universal SSL. Explicit hostnames remain configurable through
`CLOUDFLARE_PUBLIC_HOSTNAMES`.

## Tactical Validation

The corrected script ran through the serial task and completed with the
published Tactical informational exit code `5`. A second direct Tactical run
also returned `5` and completed in approximately six seconds.

The second run reused the same resources:

- Tunnel ID: `bc29d14d-d5fd-4072-a5a2-c8d0df74cc37`
- LibreNMS Access application ID: `afb226c6-1c0e-4b3f-b75e-c50b6e2a6ec6`
- Checkmk Access application ID: `8d069bea-1876-4ec2-b238-f84847d887eb`
- LibreNMS DNS record ID: `ab53cad0bbc81236c55c6a0b931140e9`
- Checkmk DNS record ID: `c1acf713a5c3c75e91006658c277be0e`

No duplicate tunnel, Access application, or DNS record was created.

## Independent Verification

- Public DNS returned Cloudflare addresses for both hostnames through
  `1.1.1.1`.
- HTTPS certificate verification succeeded for both hostnames.
- Both anonymous requests returned HTTP `302` to the Cloudflare Access login
  flow, confirming that the origins are not anonymously exposed.
- `cloudflared.service` was enabled, active, and running after both executions.
- Four QUIC tunnel connections registered successfully in Brisbane and Sydney.
- `/etc/cets/cloudflared.env` was owned by `root:root` with mode `0600`.
- The connector token was absent from the process command line and systemd unit.
- Checkmk remained healthy and both monitoring applications responded locally.

## DNS Caveat

CETS uses split-horizon DNS for `cets.com.au`. Public resolvers return the new
Cloudflare records, but the current internal CETS resolver does not. Internal
clients will need matching records in the internal DNS zone or suitable DNS
forwarding before these public names resolve from the CETS corporate network.

## Result

Phase 6 passed Tactical execution, independent host validation, public HTTPS and
Access validation, and the required idempotency rerun. No credentials are stored
in this repository; the Cloudflare API token and account ID continue to be
supplied by Tactical global keys at runtime.
