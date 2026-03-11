---
title: Dispatcher - Security Operations
subtitle: Operational security guidance, monitoring, incident response, and known limitations
brand: odcc
---

# Dispatcher - Security Operations

This document covers the operational security posture of a running Dispatcher
deployment: what to monitor, how to respond to incidents, known limitations,
and deployment-specific guidance. For the system's security model and
architecture, see SECURITY.md.


## Dispatcher Host Security

The security of the entire fleet depends on the security of the dispatcher
host. The CA key, dispatcher cert and key, full agent registry, and lock files
all reside there. An attacker with root access to the dispatcher host can issue
arbitrary agent certificates and connect to any agent.

Treat the dispatcher host as a privileged infrastructure node:

- Restrict interactive login to named administrators only; no shared accounts
- Audit all access via system auth logs (`/var/log/auth.log` or equivalent)
- Keep the dispatcher host off the general network; access via bastion or VPN
- Apply OS-level hardening (no unnecessary services, up-to-date packages)
- Do not run untrusted workloads on the dispatcher host

The `dispatcher` group grants CLI access to the dispatcher binary and read
access to the agent registry at `/var/lib/dispatcher/agents/`. This includes
each agent's hostname and IP address. Membership of the `dispatcher` group
is a privilege; treat it accordingly.


## Token and Credential Lifecycle

Dispatcher has no built-in token management. Tokens are arbitrary strings that
callers include in requests; they are forwarded to the auth hook as
`DISPATCHER_TOKEN` and to agents via the request body. All token issuance,
validation, expiry, and revocation logic lives in the auth hook.

The `username` field is a caller-supplied string with no structural meaning
within Dispatcher. The dispatcher does not authenticate it, and it is not
verified to match any local or remote identity. Its purpose is to carry an
identity assertion that an auth hook can forward to an external authentication
service alongside the token. A hook that grants elevated permissions based
solely on the value of `username`, without verifying it through the token or
another mechanism, can be trivially bypassed by any caller that sets the field
to a privileged value.

The recommended pattern for identity-bearing requests:

- The caller supplies a `token` that encodes or binds to an identity (e.g. a
  signed JWT, an opaque token registered in an identity service, or an API key
  issued to a specific service account)
- The caller also supplies `username` as an advisory hint
- The hook validates the token against an identity service; the service returns
  the authorised identity associated with that token
- The hook compares the authorised identity against the asserted `username`
  only as an additional consistency check, not as the primary access control
  basis
- Privilege decisions are made on the validated token identity, not the
  asserted username

This pattern allows hooks to go beyond static local accounts: any identity
service that can validate a token can be used. The hook does not need to
maintain its own user database; it delegates to the identity service.

Token revocation for a compromised service: update the auth hook to reject the
service's token. If the hook validates against a central service, revoke the
token there. No Dispatcher restart is required; the hook's own logic takes
effect on the next request.


## Auth Hook Security

Hook update path
: Do not push auth hook updates via `dispatcher run`. If the hook is replaced
  by a script that a compromised token can invoke, the hook that validates that
  token can be overwritten. Update hooks through direct filesystem access,
  configuration management tooling (Ansible, Salt, Puppet), or a dedicated
  privileged deployment channel that does not pass through Dispatcher itself.

Token exposure in hook logging
: The token is available in the hook's `DISPATCHER_TOKEN` environment variable
  and in the JSON object on stdin. Do not log environment variables within the
  hook; log only specific fields from stdin. A hook that logs `env` output
  exposes the token in syslog, where it may be accessible to non-root users
  depending on syslog permissions.

External validation service availability
: If the hook validates tokens against an external service, failure to reach
  that service must result in a denied request (exit code 1 or 2). Do not
  fail open. The operational impact of blocking all requests during a
  validation service outage is preferable to authorising unvalidated requests.
  Design the validation service for high availability if Dispatcher operations
  are time-critical.

Two-token pattern
: The dispatcher-side hook and the agent-side hook are independent and can
  validate different tokens. A higher-assurance deployment can issue separate
  credentials for the dispatcher-to-hook path and the agent-to-hook path.
  The dispatcher validates a dispatcher-level token; the agent validates a
  forwarded per-operation token. This is a supported configuration - the
  token is forwarded from dispatcher to agent in the request body and is
  available to both hooks.

Agent hook scope
: The agent hook only runs for `run` requests. `ping` requests do not invoke
  the agent hook. An agent hook cannot restrict which sources may call the
  `ping` endpoint; source-based restrictions on the agent use `allowed_ips`
  in `agent.conf` or `DISPATCHER_SOURCE_IP` in the hook for `run` requests.
  The absence of a `hosts` field on the agent side is intentional: the agent
  is unaware of which other agents are targeted in the same invocation.

Allowlist information in hook responses
: The agent hook is called after allowlist validation. A denied hook response
  therefore confirms to the caller that the script name exists in the allowlist
  (a non-existent script would have been rejected earlier with a different
  error code). This is a known characteristic of the execution order. Operators
  who need to conceal allowlist contents should note that hook denial does not
  prevent an authorised caller from querying `/capabilities` to enumerate the
  full allowlist.


## Sensitive Script Output

Scripts that return credentials, key material, or other sensitive data will
have that data included in the API response and stored in the result file at
`/var/lib/dispatcher/runs/<reqid>.json` for 24 hours. The result directory
is 0770 root:dispatcher - readable by all members of the `dispatcher` group.

Options for handling sensitive output:

- Write sensitive data to a local file on the agent rather than stdout; return
  only a status code and path from the script
- Have the script encrypt the output before writing to stdout; the caller
  decrypts client-side
- Restrict `GET /status/{reqid}` callers to the original caller only via the
  auth hook (not built in; hook logic required)

Result retrieval at `GET /status/{reqid}` is not currently logged with the
caller's identity. All authenticated API callers can retrieve any result by
reqid. A hook that restricts this must infer the original caller from the
token and compare it to the stored result's caller context (not provided by
the API directly - requires a lookup in the hook's own store).


## `update-dispatcher-serial` Security

The `update-dispatcher-serial` script validates that its argument is a
lowercase hex string of 8–40 characters before writing to
`/etc/dispatcher-agent/dispatcher-serial`. Arguments that fail the hex pattern
check or fall outside the length range are rejected with a non-zero exit and
an error message; no file is written.

Despite this validation, an API caller with access to this script can still
write a plausible-looking but incorrect hex serial, causing all subsequent
`/run` and `/ping` operations to return 403 until the correct serial is
restored. The auth hook should restrict invocation of `update-dispatcher-serial`
to privileged tokens only. A standard operator token should not be able to call
this script. Use a separate token issued to the dispatcher's own rotation
machinery, and block it for all other callers in the hook.


## CA Compromise Recovery

If the CA private key is compromised, every cert signed by it must be treated
as untrusted. An attacker with the CA key can issue valid agent certificates
and connect to any agent as if they were the dispatcher.

Recovery procedure:

1. Take agents offline or isolate them immediately from all network sources.
   The priority is preventing the attacker from using newly-issued certs before
   recovery completes.

2. On the dispatcher host, regenerate the CA:

   ```bash
   # Back up the compromised material first for forensics
   cp -a /etc/dispatcher /etc/dispatcher.compromised.$(date +%Y%m%d)

   dispatcher setup-ca   # generates new CA key and cert
   dispatcher setup-dispatcher  # generates new dispatcher cert signed by new CA
   ```

3. Distribute the new CA cert to all agents. This cannot be done via Dispatcher
   (the agents do not trust the new CA yet). Use SSH or configuration
   management tooling to push `/etc/dispatcher/ca.crt` to
   `/etc/dispatcher-agent/ca.crt` on each agent.

4. Re-pair every agent. The agent certs signed by the old CA are no longer
   valid:

   ```bash
   # On each agent host
   rm /etc/dispatcher-agent/agent.{key,crt}
   dispatcher-agent request-pairing --dispatcher <dispatcher>
   ```

5. Once all agents are re-paired, decommission the compromised CA material.
   Ensure the old CA cert is removed from all trust stores.

6. Investigate how the CA key was accessed: review dispatcher host auth logs,
   check for unauthorised access to `/etc/dispatcher/ca.key`, and determine
   the scope of the compromise before returning to normal operations.

This procedure affects the entire fleet. Test the re-pairing path before a
real incident - the orchestrated pairing flow (`--background` mode) is
designed for bulk re-pairing scenarios.


## Monitoring and Alerting

Dispatcher's structured logging provides the data for detection. Alerting
must be configured in the operator's log management tooling (Graylog,
Elasticsearch, Loki, syslog-ng filters, etc.). Dispatcher does not include
a monitoring component.

Security-relevant `ACTION=` values to alert on:

`ACTION=rate-block`
: A source IP has been blocked by the volume or probe rate limiter. Occasional
  occurrences may indicate misconfigured clients or cert errors. Sustained
  occurrences from the same IP indicate active scanning or probing.

`ACTION=serial-reject`
: The dispatcher's cert serial does not match the stored value on the agent.
  This should not occur during normal operation after a complete rotation
  broadcast. Occurrences may indicate a stale agent or, in the worst case,
  a connection attempt from a cert that is not the current dispatcher cert.

`ACTION=cert-revoked`
: A connecting peer presented a cert that is in the revocation list. This
  indicates an active connection attempt from a revoked credential. Treat
  as a security event and investigate the source IP.

`ACTION=ip-block`
: A connection from an IP outside the `allowed_ips` allowlist. Expected if
  `allowed_ips` is configured and a misconfigured or unexpected source
  attempts a connection. Unexpected occurrences on a network where source
  IPs should be stable indicate traffic from an unexpected source.

`ACTION=deny` (repeated, same PEER)
: Repeated script denials from the same dispatcher IP indicate a dispatcher
  attempting to run a script that is not in the agent's allowlist. May
  indicate misconfiguration or an attempt to reach a script that has been
  removed.

`ACTION=config-warn`
: Configuration problems at load time. Should not occur in a healthy
  deployment after initial setup. Investigate immediately.

Operational signals worth alerting on:

- All agents returning `ACTION=serial-reject` simultaneously after a rotation
  indicates the rotation broadcast failed or was corrupted. Run
  `dispatcher serial-status` and `dispatcher rotate-cert` immediately.
- A sudden increase in `ACTION=run EXIT=non-zero` across multiple agents may
  indicate a script was modified or a dependency broke. Correlate with
  deployment events.

`cert_overlap_days` calibration
: The default overlap window is 30 days. If agents in your fleet are routinely
  offline for maintenance or hibernation longer than this, `stale` status
  becomes normal background noise rather than a signal. Set `cert_overlap_days`
  in `dispatcher.conf` to a value above the maximum observed downtime for your
  fleet. A stale alert only has diagnostic value if it is unexpected.


## Known Limitations

Script stdin pipe
: The agent writes JSON context to the script's stdin pipe before waiting for
  the script to exit. If the script does not read stdin and the pipe buffer
  fills, the agent child process blocks on the write until the script exits or
  the pipe is drained. Scripts that do not use stdin context must include
  `exec 0</dev/null` to prevent this. This is documented in SECURITY.md but
  bears repeating: it is a script author responsibility, not something the
  agent can enforce.

Request result access
: `GET /status/{reqid}` returns stored run results to any authenticated caller,
  not only the original submitter. Result access is not logged with the caller's
  identity. Reqid format provides limited enumeration resistance (see reqid
  entropy below). Sensitive results should not be left in the result store;
  design scripts to minimise what they return via stdout if the results will be
  stored.

Rate state persistence
: Rate limit state is held in memory and cleared on SIGHUP or agent restart.
  `update-dispatcher-serial` sends SIGHUP as part of normal rotation, which
  clears all rate blocks. The window between the SIGHUP and the next connection
  is milliseconds in practice - not operationally meaningful - but operators
  should be aware that a serial update resets rate state on all agents.
  Persistent rate state across reloads is not currently supported.

`MemoryDenyWriteExecute` and JIT runtimes
: The agent systemd unit sets `MemoryDenyWriteExecute=yes`. This is safe for
  the current bash-only script inventory but will cause silent failures if a
  JIT-compiled runtime (Java, Node.js, Python with JIT) is added to the
  allowlist. There is no mechanism to detect this conflict at allowlist load
  time. When adding a new script whose interpreter is a JIT runtime, remove
  `MemoryDenyWriteExecute=yes` from the unit file before deploying.

No dispatcher-side agent cert revocation
: The revocation list on agents covers certs presented *to* the agent. There
  is no equivalent mechanism on the dispatcher side to block a stolen agent
  cert from connecting to the dispatcher. An agent that has been decommissioned
  via `dispatcher unpair` has its cert left technically valid until natural
  expiry. Decommission the host promptly after unpairing.


## Docker-Specific Security

Docker socket access
: Any user or process with access to the Docker socket on the dispatcher host
  can start a container with the `dispatcher-data` volume mounted and read the
  CA private key. Restrict Docker socket access to root and any explicitly
  designated operators. Do not grant Docker socket access to services running
  on the dispatcher host that do not require it. This is the most significant
  additional risk of a containerised deployment versus a bare-metal install.

Stale pairing request
: The dispatcher's pairing queue automatically cleans up requests older than
  10 minutes. In the Docker workflow, the agent container exits after sending
  its pairing request and must be restarted by the operator after approval.
  If the 10-minute window expires before the container is restarted and
  re-triggers the pairing, the request is silently deleted. Recovery: restart
  the agent container; it will send a fresh pairing request.

`DISPATCHER_HOST` trust
: The `DISPATCHER_HOST` environment variable in the agent container determines
  which host receives the pairing request including the agent's CSR. If this
  variable is misconfigured to point at an attacker-controlled host, the
  attacker receives the CSR and can return a certificate signed by their own
  CA. The agent stores whatever cert is returned. All subsequent operations use
  the attacker's CA as the trust anchor. Verify `DISPATCHER_HOST` points at
  the correct dispatcher before starting agent containers. For production
  deployments, consider setting `DISPATCHER_HOST` in a compose file under
  version control rather than passing it as a runtime variable.

`allowed_ips` in containerised deployments
: In a Docker network, all containers on the same network can reach port 7443
  on the agent container. Set `allowed_ips` in `agent.conf` to the dispatcher
  container's IP or subnet to limit which containers can connect to the agent.
  The dispatcher container's IP is stable within a compose deployment (Docker
  assigns IPs deterministically by service name). Example:

  ```ini
  allowed_ips = 172.18.0.0/16
  ```

  For tighter control, use Docker network policies or pin the dispatcher
  container's IP in the compose file and use an exact IP in `allowed_ips`.

Volume backup
: All persistent state is on named volumes. Back up both `dispatcher-data`
  (CA key, dispatcher cert) and `dispatcher-registry` (agent registry) on the
  dispatcher side. On the agent side, `agent-data` contains the agent cert and
  key. Loss of `agent-data` requires re-pairing that agent. Loss of
  `dispatcher-data` requires regenerating the CA and re-pairing the entire
  fleet. Treat volume backup with the same priority as the CA key backup
  described in SECURITY.md.
