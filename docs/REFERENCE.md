---
title: Dispatcher - Installation and Operations
subtitle: Platform requirements, setup, configuration, and operational reference
brand: odcc
---


This document is the authoritative reference for all `dispatcher` and
`dispatcher-agent` commands. It covers every mode, option, and environment
variable for both binaries.

For installation and initial setup, see INSTALL.md. For a hands-on
introduction to what the system can do, run the dispatcher-demonstrator
script on a paired agent - see INSTALL.md for instructions on enabling it.

## dispatcher

The `dispatcher` binary runs on the control host. It manages the CA,
handles agent pairing, and dispatches commands to paired agents.

### Synopsis

```bash
dispatcher <mode> [options] [args]
```

### Global options

These options apply to all modes.

`--config <path>`
: Path to `dispatcher.conf`. Default: `/etc/dispatcher/dispatcher.conf`.

`--port <n>`
: Override the default agent port (7443) for all hosts in this invocation.
  Individual hosts can also override their port with `<host>:<port>` syntax.

`--json`
: Output results as JSON. Applies to `run`, `ping`, and `list-agents`.

`--username <name>`
: Username to include in the request context sent to agents. Defaults to
  `$USER`. Consumed by auth hooks on the agent side for access control.
  Can also be set with `--username` on the command line to identify the
  operator explicitly.

`--token <token>`
: Auth token to include in the request context. Defaults to the
  `$DISPATCHER_TOKEN` environment variable if set. Consumed by auth hooks
  on the agent side.

### Environment variables

`DISPATCHER_TOKEN`
: Default auth token. Equivalent to `--token`. Useful for scripted or
  automated invocations where passing a token on the command line is
  undesirable.

`USER`
: Default username. Overridden by `--username`.

---

### run

Run an allowlisted script on one or more agents in parallel.

```bash
dispatcher run <host>[:<port>] [<host>...] <script> [-- <arg>...]
```

The script name must match an entry in the agent's `scripts.conf` allowlist.
Everything after `--` is passed to the script as positional arguments.
Arguments are evaluated on the dispatcher host before being sent - use
`--` to pass static strings, not shell expressions intended to run on
the agent.

The dispatcher sends a JSON context object to the script via stdin on the
agent. This includes the script name, username, token, arguments, timestamp,
peer IP, and request ID. See INSTALL.md for the full context structure.

```bash
# Single host
dispatcher run web-01 deploy-app

# Multiple hosts in parallel
dispatcher run web-01 web-02 web-03 deploy-app

# Pass arguments to the script
dispatcher run db-01 backup-mysql -- --database myapp

# Custom port for one host
dispatcher run web-01:7450 deploy-app

# Identify the operator explicitly
dispatcher run web-01 deploy-app --username alice

# Pass an auth token
dispatcher run web-01 deploy-app --token mytoken
DISPATCHER_TOKEN=mytoken dispatcher run web-01 deploy-app

# JSON output
dispatcher run web-01 deploy-app --json
```

Output shows per-host status, exit code, round-trip time, stdout, and stderr.
Exit code is 0 if all hosts succeeded, 1 if any host failed or returned
a non-zero exit.

---

### ping

Test mTLS connectivity to one or more agents and report cert expiry and
agent version.

```bash
dispatcher ping <host>[:<port>] [<host>...]
```

```bash
# Single host
dispatcher ping web-01

# Multiple hosts in parallel
dispatcher ping web-01 web-02 web-03

# JSON output
dispatcher ping web-01 --json
```

Output columns: host, status (ok/error), round-trip time, cert expiry,
agent version.

---

### pairing-mode

Start the pairing listener on port 7444. Agents call `request-pairing`
to submit a CSR; this mode receives the request, displays it for operator
approval, and signs and returns the certificate on approval.

```bash
dispatcher pairing-mode
```

The prompt shows the requesting agent's hostname, IP, request ID, and a
6-digit confirmation code. The agent displays the same code at submission
time. Verify both match before approving.
Enter `a` to approve, `d` to deny, or `s` to skip and leave the request
pending. Press Ctrl-C to stop pairing mode.

Pairing mode processes one request at a time interactively. For
unattended approval workflows, use `list-requests` and `approve`.

---

### list-requests

List pending pairing requests that have not yet been approved or denied.

```bash
dispatcher list-requests
```

Output columns: request ID, hostname, IP, confirmation code, received timestamp.
Verify the confirmation code matches the 6-digit code displayed on the agent
before approving.

---

### approve

Approve a pending pairing request by ID. Signs the agent's CSR and
delivers the certificate on the agent's next poll.

```bash
dispatcher approve <reqid>
```

The request ID is shown by `list-requests` and `pairing-mode`.

---

### deny

Deny a pending pairing request by ID. Removes the request without
signing.

```bash
dispatcher deny <reqid>
```

---

### list-agents

List all registered (paired) agents.

```bash
dispatcher list-agents
dispatcher list-agents --json
```

Output columns: hostname, IP address, paired timestamp, cert expiry.

With `--json`, returns an array of objects with fields:

`hostname`
: Agent hostname as registered at pairing time.

`ip`
: IP address of the agent at last contact.

`paired_at`
: ISO 8601 timestamp of when the agent was paired.

`cert_expiry`
: ISO 8601 timestamp of the agent certificate's notAfter date.

`serial`
: Truncated hex serial of the agent's current certificate.

---

### setup-ca

One-time initialisation of the dispatcher CA. Generates the CA key and
self-signed certificate used to sign all agent certificates. Run once
on the dispatcher host before any pairing.

```bash
dispatcher setup-ca
```

Writes to `/etc/dispatcher/`. Does not overwrite an existing CA.

---

### setup-dispatcher

Generate the dispatcher's own key and certificate, signed by the CA.
Run after `setup-ca`. If an existing cert is found and registered agents
exist, the command displays the agent count and requires confirmation before
proceeding - replacing the cert changes its serial and agents will need
re-pairing if they miss the rotation broadcast.

```bash
dispatcher setup-dispatcher
```

Writes to `/etc/dispatcher/`.

---

### rotate-cert

Rotate the dispatcher certificate immediately. Generates a new cert, marks
all registered agents as pending, broadcasts the new serial to all agents
in parallel, and reports per-agent results.

```bash
dispatcher rotate-cert
```

Agents that were unreachable during the broadcast are retried automatically
by the internal check loop. Agents that remain unreachable after
`cert_overlap_days` are marked `stale` and require re-pairing.

The `update-dispatcher-serial` script must be in the agent's `scripts.conf`
allowlist for the broadcast to succeed. See `scripts.conf.example`.

---

### serial-status

Show the current dispatcher serial, previous serial, rotation timestamps,
overlap expiry, and per-agent serial state.

```bash
dispatcher serial-status
dispatcher serial-status --json
```

Output columns: hostname, status (current/pending/stale/unknown), last
confirmed timestamp, serial (truncated).

Status values:

- `current` - agent has confirmed the current serial
- `pending` - broadcast attempted but not yet confirmed (agent may be offline)
- `stale` - overlap window expired without confirmation; re-pair required
- `unknown` - agent has never received a serial update

---

## dispatcher.conf

Configuration file for the dispatcher and dispatcher-api processes.
Default path: `/etc/dispatcher/dispatcher.conf`.

Key settings:

`cert`, `key`, `ca`
: Paths to the dispatcher's TLS certificate, private key, and CA
  certificate. Required for all mTLS operations.

`read_timeout`
: How long (in seconds) the dispatcher waits for a response from an agent
  before reporting a timeout error. Default: 60. The script continues
  running on the agent after a timeout - only the dispatcher's ability to
  receive the output is affected. Raise this value for scripts that are
  expected to take longer than 60 seconds.

  ```
  read_timeout = 120
  ```

`timeout`
: Deprecated alias for `read_timeout`. Accepted for backward compatibility.

`api_port`
: Port for the `dispatcher-api` HTTP server. Default: 7445.

`api_cert`, `api_key`
: TLS certificate and key for the API server. If both are present and
  readable, the API server uses TLS. If absent, plain HTTP is used.

`api_bind`
: Network address the API server binds to. Default: `127.0.0.1` (localhost
  only). Set to `0.0.0.0` to accept connections on all interfaces, or to a
  specific interface address. Only change this if external clients need direct
  access; prefer a reverse proxy for internet-facing deployments.

  ```
  api_bind = 0.0.0.0
  ```

`api_auth_default`
: Controls API behaviour when no `auth_hook` is configured. Accepts `deny`
  (default) or `allow`. With `deny`, all requests are rejected until a hook
  is configured. With `allow`, all requests are authorised without a hook -
  suitable only for isolated networks. When a hook is configured this setting
  has no effect.

  ```
  api_auth_default = allow
  ```

### Cert rotation settings

`cert_days`
: Lifetime of the dispatcher certificate in days. Default: 365. Applied when
  generating a new cert via `setup-dispatcher` or automatic rotation.

`cert_renewal_days`
: Begin renewal this many days before the dispatcher cert expires. Default: 90.
  With `cert_days = 365`, renewal begins at day 275 of the cert's life.

`cert_overlap_days`
: After rotation, continue retrying agents that missed the serial broadcast for
  this many days before marking them `stale` (requiring re-pair). Default: 30.
  Configurable to accommodate fleets with agents that are offline for extended
  periods.

  ```
  cert_overlap_days = 60
  ```

`cert_check_interval`
: Seconds between internal cert expiry checks. Default: 14400 (4 hours). Reduce
  for testing. The check is lightweight: read the cert, compare notAfter to now.

`auth_hook`
: Path to an executable called before every `run` and `ping` operation.
  Receives request context as JSON on stdin. See INSTALL.md for the full
  interface contract.

Configuration file for the `dispatcher-agent` process.
Default path: `/etc/dispatcher-agent/agent.conf`.

Key settings:

`port`
: Port the agent listens on for mTLS connections from the dispatcher. Default: 7443.

`cert`, `key`, `ca`
: Paths to the agent's TLS certificate, private key, and CA certificate.

`revoked_serials`
: Path to a file listing revoked TLS certificate serial numbers, one per line.
  Connections presenting a revoked cert are rejected immediately after the mTLS
  handshake, before any request is processed. Reloaded on SIGHUP without restart.

  Accepted serial formats (all normalised to lowercase hex on load):

  - Plain hex: `deadbeef`
  - Colon-separated: `DE:AD:BE:EF` (as returned by some tools and `IO::Socket::SSL`)
  - `0x`-prefixed: `0xdeadbeef`
  - `serial=`-prefixed: `serial=DEADBEEF` (as output by `openssl x509 -serial`)
  - Decimal integer: `3735928559`

  Lines beginning with `#` are treated as comments.

  Default: `/etc/dispatcher-agent/revoked-serials`. A missing or empty file
  means no certs are revoked.

  ```
  revoked_serials = /etc/dispatcher-agent/revoked-serials
  ```

`dispatcher_serial_path`
: Path to the stored dispatcher cert serial file. Written automatically by
  `request-pairing` - do not edit manually. The `/capabilities` endpoint
  rejects peers whose cert serial does not match the stored value. Re-pair
  the agent to update after a dispatcher cert rotation.

  Default: `/etc/dispatcher-agent/dispatcher-serial`. Reloaded on SIGHUP.

`dispatcher_cn`
: Removed. Previously used to restrict `/capabilities` by cert CN. Replaced
  by serial tracking via `dispatcher_serial_path`.

`script_dirs`
: Colon-separated list of absolute directory paths. If set, any script in
  `scripts.conf` whose path does not fall under one of these directories is
  rejected at load time and re-validated at execution time.

  ```
  script_dirs = /opt/dispatcher-scripts:/usr/local/lib/dispatcher-scripts
  ```

`auth_hook`
: Path to an executable called before every `run` request on the agent,
  after allowlist validation. Enables independent downstream token validation
  separate from the dispatcher's own hook. Exit 0 = authorised, 1/2/3 = denied.

`pairing_port`
: Port the agent listens on during pairing. Default: 7444. Must match the
  `--port` value passed to `dispatcher-agent request-pairing` and the port
  used by `dispatcher pairing-mode`.

  ```
  pairing_port = 7444
  ```

`allowed_ips`
: Comma-separated list of IP addresses or CIDR prefixes (/8, /16, /24)
  permitted to connect to the agent's mTLS port. Connections from addresses
  not on the list are dropped immediately after the TCP accept, before the
  TLS handshake. If unset, all source addresses are accepted.

  ```
  allowed_ips = 192.168.1.0/24, 10.0.0.1
  ```

  Invalid entries are logged as `ACTION=config-warn` at load time and
  silently skipped.

### Rate limiting settings

The agent applies two independent rate limits per source IP. Both are
tracked in memory and reset on agent restart or SIGHUP.

The volume threshold blocks IPs that open an unusually high number of
connections in a short window — consistent with port scanning or connection
flooding. The probe threshold blocks IPs that repeatedly fail TLS
handshakes — consistent with certificate probing or brute-force attempts.

`rate_limit_volume`
: Volume threshold in the format `limit/window/block`. Blocks a source IP
  for `block` seconds when it opens more than `limit` connections within
  `window` seconds. Default: `10/60/300` (10 connections in 60 seconds
  triggers a 5-minute block).

  ```
  rate_limit_volume = 10/60/300
  ```

`rate_limit_probe`
: Probe threshold in the format `limit/window/block`. Blocks a source IP
  for `block` seconds when it produces more than `limit` TLS handshake
  failures within `window` seconds. Default: `3/600/3600` (3 failures in
  10 minutes triggers a 1-hour block).

  ```
  rate_limit_probe = 3/600/3600
  ```

`rate_limit_disable`
: Set to `1` to disable all rate limiting. Intended for use during the
  integration test suite, which opens many connections rapidly from
  localhost. Do not set in production.

  ```
  rate_limit_disable = 1
  ```

---

## dispatcher-agent

The `dispatcher-agent` binary runs on each managed host. It serves the
mTLS listener, handles pairing, and executes allowlisted scripts on
request from the dispatcher.

### Synopsis

```bash
dispatcher-agent <mode> [options]
```

### Global options

`--config <path>`
: Path to `agent.conf`. Default: `/etc/dispatcher-agent/agent.conf`.

`--allowlist <path>`
: Path to `scripts.conf`. Default: `/etc/dispatcher-agent/scripts.conf`.

`--port <n>`
: Override the pairing port (default 7444). Applies to `request-pairing`
  only; the serve port is set in `agent.conf`.

---

### serve

Start the agent server. Listens on the port configured in `agent.conf`
(default 7443) for incoming mTLS connections from the dispatcher.

```bash
dispatcher-agent serve
```

Under normal operation this is started and managed by the init system
(systemd or procd). Run directly for debugging or on systems without
a supported init system.

The agent reloads `scripts.conf` and the revocation list on SIGHUP without
restarting:

```bash
# On systemd hosts (preferred)
systemctl reload dispatcher-agent

# On systems without systemd
kill -HUP $(pidof dispatcher-agent)
```

---

### request-pairing

Submit a pairing request to a dispatcher host. Generates a key and CSR
for this agent, connects to the dispatcher's pairing port (7444), and
waits for the operator to approve the request.

```bash
dispatcher-agent request-pairing --dispatcher <host>
dispatcher-agent request-pairing --dispatcher <host> --background [--timeout <n>]
```

`--dispatcher <host>`
: Hostname or IP of the dispatcher host. Required.

`--port <n>`
: Override the pairing port on the dispatcher (default 7444).

`--background`
: Non-interactive mode for orchestrated installations. Prints the request
  ID to stdout and exits immediately, leaving a background process to wait
  for approval and store the certificate on receipt. See
  [Orchestrated pairing](#orchestrated-pairing) below.

`--timeout <n>`
: How long (in seconds) the background process waits for approval before
  giving up. Default: 30. Maximum: 600. If the timeout expires the
  background process exits with code 2 and logs `ACTION=pair-timeout`.
  Only valid with `--background`.

The command blocks until the dispatcher approves or denies the request,
or until the connection times out. On approval, the signed certificate
and CA certificate are written to the config directory and the agent is
ready to serve.

If the connection fails with a configuration error, check that the
dispatcher host is reachable, that `pairing-mode` is active on the
dispatcher, and that the correct address was specified.

---

### Orchestrated pairing

For automated provisioning workflows where interactive approval is not
possible, `--background` separates the pairing request submission from the
approval wait. The foreground process exits as soon as the dispatcher
acknowledges the request, printing the request ID to stdout. A background
process holds the connection open and writes the certificate when approval
arrives.

The orchestrator's responsibility is to capture the request ID and call
`dispatcher approve` on the dispatcher host before the timeout expires.

#### Flow

On the agent host (as part of a provisioning script):

```bash
# Start pairing-mode on the dispatcher first, then:
REQID=$(dispatcher-agent request-pairing --dispatcher dispatcher.example.com \
    --background --timeout 60)
echo "Request ID: $REQID"
```

The command exits 0 immediately, printing the request ID. The background
process is now waiting for approval.

On the dispatcher host (or via the orchestrator calling it remotely):

```bash
dispatcher approve "$REQID"
```

The background process receives the certificate, writes it to
`/etc/dispatcher-agent/`, logs `ACTION=pair-complete`, and exits 0.

Confirm pairing succeeded on the agent host:

```bash
dispatcher-agent pairing-status
# Exits 0 if paired, 1 if not yet paired
```

#### Exit codes (background process)

`0`
: Approval received and certificates stored successfully.

`2`
: Timeout expired before approval arrived. Key and CSR have been
  cleaned up. Re-run `request-pairing` to try again.

`3`
: Request was explicitly denied by the operator.

#### Timing

The background process holds the connection open for up to `--timeout`
seconds (default 30, maximum 600). The dispatcher's own polling window is
600 seconds — approval must arrive within whichever is shorter. For
orchestrated workflows where the approval step may take time, increase
`--timeout` accordingly:

```bash
REQID=$(dispatcher-agent request-pairing --dispatcher dispatcher.example.com \
    --background --timeout 120)
```

#### Notes

The background process inherits the connection socket from the foreground
process — no reconnection occurs. The maximum `--timeout` of 600 seconds
is enforced because the dispatcher closes the connection after its own
600-second polling window, making longer waits unreliable.

The request ID printed to stdout is the same ID shown by
`dispatcher list-requests` on the dispatcher host. Both the confirmation
code and the request ID are available via `list-requests` for verification
before approving.

---

Report whether the agent is paired and show the certificate expiry date.

```bash
dispatcher-agent pairing-status
```

Exits 0 if paired, 1 if not paired. Suitable for use in scripts and
health checks.

---

### ping-self

Validate the local configuration, allowlist, and certificates without
making any network connections. Reports each check individually.

```bash
dispatcher-agent ping-self
```

Checks performed:

- `agent.conf` parses without error and required keys are present
- `scripts.conf` allowlist loads and all listed scripts are executable
- Pairing certificates are present and not expired
- If `script_dirs` is configured, all scripts in `scripts.conf` fall under
  one of the permitted directories
- If `revoked_serials` is configured, the file is readable and all entries
  are valid serial formats

Exit code is 0 if all checks pass. Use this after installation or
configuration changes to confirm the agent will start cleanly.

---

## dispatcher-api

The `dispatcher-api` binary exposes the dispatcher's run, ping, and
discovery operations as an HTTP REST API. It is installed as a systemd
service (`dispatcher-api.service`) and listens on `api_port` (default 7445).

Start manually for testing:

```bash
dispatcher-api --config /etc/dispatcher/dispatcher.conf
```

TLS is enabled if `api_cert` and `api_key` are set in `dispatcher.conf`
and the files exist. Plain HTTP is used otherwise.

Full endpoint documentation is in API.md. Summary:

`GET /`
: Returns a JSON index of all endpoints and spec URLs. No auth required.

`GET /health`
: Returns `{ ok: true, version: "..." }`. Use for liveness checks.

`POST /ping`
: Body: `{ hosts, username?, token? }`. Pings all specified hosts in parallel.

`POST /run`
: Body: `{ hosts, script, args?, username?, token? }`. Runs an allowlisted
  script on all specified hosts. Returns results including a top-level
  `reqid` for status polling and syslog correlation.

`GET /discovery` or `POST /discovery`
: Returns registered agents and their allowlisted scripts. Optional body:
  `{ hosts?, username?, token? }`.

`GET /status/{reqid}`
: Returns the stored result for a completed run. Results are retained for
  24 hours. Returns 404 if the reqid is unknown or has expired.

`GET /openapi.json`
: Serves the static OpenAPI 3.1 spec as installed.

`GET /openapi-live.json`
: Generates and serves a dynamic spec augmented with live host and script
  enumerations from the registry and a capabilities scan.

HTTP status codes: 200 success, 400 bad request, 403 auth denied, 404 not
found, 409 lock conflict, 500 server error.

---

## Syslog

Both binaries log structured key=value records to syslog under the
`daemon` facility. The agent logs script execution under the tag
`dispatcher-agent`; scripts themselves may log under any tag they choose.

Key fields logged on `run` (dispatcher side, logged on response received):

```
ACTION=run EXIT=<n> SCRIPT=<n> TARGET=<host:port> RTT=<ms> REQID=<id>
```

Key fields logged on `run` (agent side, logged at script completion):

```
ACTION=run EXIT=<n> SCRIPT=<n> PEER=<ip> REQID=<id>
```

The agent logs `ACTION=run` only when the script exits. There is no
start-of-execution log entry. If the dispatcher's `read_timeout` fires
before the script exits, the dispatcher logs a timeout error and moves
on, but the agent logs nothing until the script completes. An operator
cannot determine from syslog alone that a script is currently running on
an agent.

Key fields logged on `ping`:

```
ACTION=ping STATUS=ok|error PEER=<ip> REQID=<id> RTT=<ms>
```

Key fields logged on lock events (dispatcher side):

```
ACTION=lock-acquire SCRIPT=<n> HOST=<host>
ACTION=lock-release SCRIPT=<n> HOST=<host>
ACTION=lock-conflict SCRIPT=<n> HOSTS=<host,...>
```

`lock-acquire` is logged when a dispatch begins. `lock-release` is logged
when all per-host results have been collected. `lock-conflict` is logged
when a run is rejected because the script is already locked on one or more
of the requested hosts.

Key fields logged on security and access events (agent side):

```
ACTION=rate-block PEER=<ip> REASON="volume threshold"|"probe threshold"
ACTION=cert-revoked PEER=<ip> SERIAL=<hex>
ACTION=serial-reject PEER=<ip> REQID=<id>
ACTION=ip-block PEER=<ip>
```

`rate-block` is logged when a source IP is blocked by the volume or probe
rate limiter. `cert-revoked` is logged when a connecting peer presents a
certificate whose serial appears in the revocation list. `serial-reject` is
logged when the dispatcher's cert serial does not match the stored value on
`/run` or `/ping` requests. `ip-block` is logged when a source IP is
rejected by the `allowed_ips` allowlist.

Key fields logged on pairing events (agent side):

```
ACTION=pair-complete PEER=<ip> REQID=<id>
ACTION=pair-denied PEER=<ip> REQID=<id>
```

Key fields logged on configuration and startup events:

```
ACTION=start PORT=<n>
ACTION=config-warn PATH=<path> REASON=<text>
ACTION=rate-evict PEER=<ip>
```

`config-warn` is logged at startup when `agent.conf` or `scripts.conf`
contains an entry that is invalid but non-fatal — for example, an
unrecognised CIDR prefix length in `allowed_ips`, or an invalid serial
format in the revocation list. The entry is skipped and the agent
continues loading. `rate-evict` is logged when an entry is removed from
the in-memory rate limit table to make room for a new source IP (LRU
eviction).

To correlate a dispatcher log entry with agent log entries, filter both
sides by `REQID`:

```bash
grep 'REQID=a1b2c3d4' /var/log/syslog
```

See DEVELOPER.md for the full syslog field reference.

---

## Managing long-running processes

When a script is expected to run longer than `read_timeout`, the dispatcher
will report a timeout and return a non-zero exit, but the script continues
running on the agent. There is no mechanism to cancel it remotely.

To run a long-lived process and retrieve its output later:

- Have the script start the process in the background (e.g. with `nohup` or
  `systemd-run`) and return immediately with a job identifier or PID written
  to a known path.
- Use a second allowlisted script to poll status or retrieve output by
  reading that path.
- Raise `read_timeout` in `dispatcher.conf` if the script must complete
  within a single dispatcher invocation and the runtime is known and bounded.

The agent logs `ACTION=run` only when the script process exits. If the
dispatcher times out before the script completes, no `ACTION=run` entry
appears in the agent's syslog until the script eventually exits. An operator
cannot determine from syslog alone that a script is currently running —
only that it was started (from the dispatcher-side `ACTION=run` entry) and
has not yet completed.

---

## Getting started with examples

The dispatcher-demonstrator script exercises all core dispatcher
capabilities from a single agent-side script: stdout and stderr capture,
exit code propagation, argument passing, JSON context logging, and
agent-side information. It is installed on every agent host by the
installer and is disabled in `scripts.conf` by default.

To enable it, uncomment the entry in `/etc/dispatcher-agent/scripts.conf`
on the agent host and reload the allowlist:

```bash
# On systemd hosts (preferred)
systemctl reload dispatcher-agent

# On systems without systemd
kill -HUP $(pidof dispatcher-agent)
```

Then run the script directly on the agent host to see all available
subcommands and the exact dispatcher invocations that exercise them:

```bash
/opt/dispatcher-scripts/dispatcher-demonstrator.sh
```
