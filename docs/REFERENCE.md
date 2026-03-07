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

Output shows per-host status, exit code, round-trip time, request ID, stdout, and stderr.
Exit code is 0 if all hosts succeeded, 1 if any host failed or returned
a non-zero exit.

The request ID (`req:`) in the output header matches the `REQID` field in
syslog on both the dispatcher and agent. Use it to correlate CLI output with
log entries:

```bash
grep REQID=a1b2c3d4 /var/log/syslog
```

The dispatcher waits up to `read_timeout` seconds (default 60) for each
script to complete. Scripts that exceed this are reported as
`read timeout after Ns`. Set `read_timeout` in `dispatcher.conf` to adjust:

```
read_timeout = 120
```

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

The prompt shows the requesting agent's hostname, IP, and request ID.
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

Output columns: request ID, hostname, IP, received timestamp.

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
Run after `setup-ca`.

```bash
dispatcher setup-dispatcher
```

Writes to `/etc/dispatcher/`. Does not overwrite existing credentials.

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

The agent reloads `scripts.conf` on SIGHUP without restarting:

```bash
kill -HUP $(pgrep -f dispatcher-agent)
```

---

### request-pairing

Submit a pairing request to a dispatcher host. Generates a key and CSR
for this agent, connects to the dispatcher's pairing port (7444), and
waits for the operator to approve the request.

```bash
dispatcher-agent request-pairing --dispatcher <host>
```

`--dispatcher <host>`
: Hostname or IP of the dispatcher host. Required.

`--port <n>`
: Override the pairing port on the dispatcher (default 7444).

The command blocks until the dispatcher approves or denies the request,
or until the connection times out. On approval, the signed certificate
and CA certificate are written to the config directory and the agent is
ready to serve.

If the connection fails with a configuration error, check that the
dispatcher host is reachable, that `pairing-mode` is active on the
dispatcher, and that the correct address was specified.

---

### pairing-status

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

Exit code is 0 if all checks pass. Use this after installation or
configuration changes to confirm the agent will start cleanly.

---

## Syslog

Both binaries log structured key=value records to syslog under the
`daemon` facility. The agent logs script execution under the tag
`dispatcher-agent`; scripts themselves may log under any tag they choose.

Key fields logged on `run`:

```
ACTION=run EXIT=<n> PEER=<ip> REQID=<id> SCRIPT=<name>
```

Key fields logged on `ping`:

```
ACTION=ping STATUS=ok|error PEER=<ip> REQID=<id> RTT=<ms>
```

See DEVELOPER.md for the full syslog field reference.

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
# On the agent host
kill -HUP $(pgrep -f dispatcher-agent)
```

Then run the script directly on the agent host to see all available
subcommands and the exact dispatcher invocations that exercise them:

```bash
/opt/dispatcher-scripts/dispatcher-demonstrator.sh
```
