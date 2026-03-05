---
title: Dispatcher and agent - User manual
subtitle: Installation, testing, set-up and first run
brand: cloudient
---

# Dispatcher

A Perl machine-to-machine remote script execution system using mTLS for trust.
The dispatcher host runs scripts on agent hosts via HTTPS with mutual certificate
authentication. No SSH involved; agents expose only an explicit allowlist of
permitted scripts.


## Architecture

dispatcher (control host)
: CLI tool (`dispatcher`) that connects to one or more agents, sends signed
  requests, and collects results. Runs a pairing server during the initial
  certificate exchange. Maintains a registry of all paired agents. Initiates
  automatic cert renewal for agents approaching expiry.

dispatcher-agent (remote hosts)
: HTTPS server listening on port 7443 (mTLS). Accepts `run`, `ping`,
  `capabilities`, and cert renewal requests. Executes only scripts named in
  the allowlist. Reloads config and allowlist on SIGHUP without dropping
  connections.

dispatcher-api (control host, optional)
: HTTP API server listening on port 7445. Exposes run, ping, and discovery
  operations as JSON endpoints. Uses the same auth hook and lock checking as
  the CLI. Suitable for integration with monitoring tools, dashboards, or
  automation pipelines.

pairing
: One-time certificate exchange on port 7444. The agent generates a key and
  CSR, connects to the dispatcher, and waits. The operator approves on the
  dispatcher host, which signs the CSR with the private CA and delivers the
  cert back over the same connection. Approved agents are recorded in a
  persistent registry. After pairing, all operational communication uses mTLS
  on port 7443.

private CA
: Created on the dispatcher host with `dispatcher setup-ca`. All agent certs
  are signed by this CA. The CA key never leaves the dispatcher host.

automatic cert renewal
: Agent certs are renewed automatically by the dispatcher. When a ping response
  shows that an agent's cert has less than half its configured lifetime
  remaining, the dispatcher initiates renewal over the established mTLS
  connection. No operator involvement is required. The agent keeps its existing
  key; only the cert is replaced.

auth hook
: An optional executable called before every `run` and `ping` request, from
  both the CLI and the API. Receives request context as environment variables
  and JSON on stdin. The default hook authorises everything; replace with real
  credential checking for production use.


## Dependencies

All Debian trixie system packages - no CPAN required.

Agent (`--agent`)
: `libio-socket-ssl-perl`, `libjson-perl`

Dispatcher (`--dispatcher`)
: `libwww-perl`, `libio-socket-ssl-perl`, `libjson-perl`

API (`--api`, installed after `--dispatcher`)
: No additional packages beyond the dispatcher role.

All roles also require `openssl` (present on any standard Debian installation).

The installer checks dependencies and lists any missing packages before
aborting. It does not install packages automatically.


## Installation

The installer must be run as root. A role must be specified - there is no default.

```bash
sudo ./install.sh --agent        # on each remote host
sudo ./install.sh --dispatcher   # on the control host
sudo ./install.sh --api          # on the control host, after --dispatcher
sudo ./install.sh --uninstall    # remove files (preserves config and certs)
```

If any Perl dependencies are missing the installer prints the `apt install`
command and exits without making any changes.

Installed paths:

```
/usr/local/bin/dispatcher
/usr/local/bin/dispatcher-agent
/usr/local/bin/dispatcher-api
/usr/local/lib/dispatcher/          Perl library modules
/etc/dispatcher/                    Dispatcher config, CA material, auth hook
/etc/dispatcher-agent/              Agent config and certs
/opt/dispatcher-scripts/            Managed scripts on agent hosts
/var/lib/dispatcher/pairing/        Pending pairing requests
/var/lib/dispatcher/agents/         Agent registry
/var/lib/dispatcher/locks/          Concurrency lock files (transient)
/etc/systemd/system/dispatcher-agent.service
/etc/systemd/system/dispatcher-api.service
```

The installer creates a `dispatcher` system group. Add yourself to it to run
the CLI without sudo:

```bash
sudo usermod -aG dispatcher $USER
# log out and back in for the group to take effect
```


## Running the Tests

Run from the project root before installing. All tests use relative lib paths.

```bash
prove -Ilib t/
```

Or individually:

```bash
perl -Ilib t/agent-config.t
perl -Ilib t/auth.t
perl -Ilib t/lock.t
perl -Ilib t/registry.t
perl -Ilib t/log.t
perl -Ilib t/pairing-csr.t
```

`t/lock.t` uses `t/lock-holder.pl` as a subprocess helper and requires both
files to be present. `t/auth.t` and `t/pairing-dispatcher.t` require
`libjson-perl` installed; they are skipped if not available.


## Initial Setup

### 1. Dispatcher host - CA and certificates

Initialise the CA (once only):

```bash
sudo dispatcher setup-ca
```

Generate the dispatcher's own certificate:

```bash
sudo dispatcher setup-dispatcher
```

Both commands write to `/etc/dispatcher/`. The CA key (`ca.key`) is set 0600
and must not leave this host.

### 2. Configure the dispatcher

Edit `/etc/dispatcher/dispatcher.conf`:

```ini
port     = 7443
cert     = /etc/dispatcher/dispatcher.crt
key      = /etc/dispatcher/dispatcher.key
ca       = /etc/dispatcher/ca.crt
auth_hook = /etc/dispatcher/auth-hook

# Cert lifetime for new and renewed agent certs (days)
cert_days = 365
```

`auth_hook` is optional. Remove or comment it out to authorise all requests
unconditionally (safe for isolated networks; not recommended otherwise).

### 3. Agent host - configure before pairing

Edit the agent config (`/etc/dispatcher-agent/agent.conf`):

```ini
port = 7443
cert = /etc/dispatcher-agent/agent.crt
key  = /etc/dispatcher-agent/agent.key
ca   = /etc/dispatcher-agent/ca.crt

# Restrict scripts to approved directories (recommended)
script_dirs = /opt/dispatcher-scripts

# Optional tags for grouping and discovery
[tags]
env  = prod
role = db
site = london
```

Edit the allowlist (`/etc/dispatcher-agent/scripts.conf`):

```ini
# name = /absolute/path/to/script
backup-mysql  = /opt/dispatcher-scripts/backup-mysql.sh
check-disk    = /opt/dispatcher-scripts/check-disk.sh
```

Place scripts in the managed directory:

```bash
sudo cp your-script.sh /opt/dispatcher-scripts/
sudo chmod 750 /opt/dispatcher-scripts/your-script.sh
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/your-script.sh
```

### 4. Pairing

On the dispatcher host, start pairing mode:

```bash
sudo dispatcher pairing-mode
```

This blocks until interrupted. When run in a terminal, it is interactive:
incoming requests are displayed and you are prompted to accept or deny.

On the agent host:

```bash
sudo dispatcher-agent request-pairing --dispatcher <dispatcher-hostname>
```

The agent prints `Connecting to dispatcher...` and waits.

In the pairing mode terminal, a prompt appears when the request arrives:

```
Pairing request from sjm-explore (192.168.125.125) - ID: 00c9845e0001
  Received: 2026-03-05T18:38:09Z
Accept, Deny, or Skip? [a/d/s]:
```

Type `a` to approve. The agent prints `Pairing complete. Certificates stored.`
and exits. Press Ctrl-C to stop pairing mode.

If multiple requests arrive simultaneously, they are listed and numbered:

```
1. sjm-explore (192.168.125.125) - ID: 00c9845e0001 - 2026-03-05T18:38:09Z
2. prod-db-01  (192.168.125.200) - ID: 1a4f2e330001 - 2026-03-05T18:38:22Z
Command (a1/d1/a2/d2/list/quit):
```

Use `a1`, `d2`, etc. to act on individual requests, `list` to redisplay, `quit`
to stop pairing mode.

If running pairing mode non-interactively (from a script or service), use the
separate `approve`/`deny` commands from another terminal:

```bash
dispatcher list-requests
dispatcher approve <reqid>
dispatcher deny <reqid>
```

Confirm the agent is registered:

```bash
dispatcher list-agents
```

### 5. Start the agent

```bash
sudo systemctl enable dispatcher-agent
sudo systemctl start dispatcher-agent
sudo systemctl status dispatcher-agent
```

### 6. Verify from the dispatcher

```bash
dispatcher ping <agent-hostname>
```

Expected output:

```
HOST                            STATUS    RTT       CERT EXPIRY                   VERSION
-------------------------------------------------------------------------------------
agent-hostname                  ok        45ms      Jun  7 16:28:00 2027 GMT      0.1
```

### 7. Start the API server (optional)

```bash
sudo systemctl enable dispatcher-api
sudo systemctl start dispatcher-api

curl -s http://localhost:7445/health | python3 -m json.tool
```

Expected:

```json
{ "ok": true, "version": "0.1" }
```


## CLI Usage

### Ping

```bash
# Single host
dispatcher ping host-a

# Multiple hosts (parallel)
dispatcher ping host-a host-b host-c

# JSON output
dispatcher ping host-a --json
```

### Run

```bash
# Run a script
dispatcher run host-a backup-mysql

# With arguments (everything after -- is passed to the script)
dispatcher run host-a logger -- -t my-tag "hello from dispatcher"

# Multiple hosts in parallel
dispatcher run host-a host-b host-c check-disk

# Custom port for one host
dispatcher run host-a:7450 host-b backup-mysql

# JSON output
dispatcher run host-a backup-mysql --json
```

Auth options (applicable to both `ping` and `run`):

```bash
# Via flag (token appears in ps output)
dispatcher run host-a backup-mysql --token mytoken

# Via environment variable (preferred - does not appear in ps)
DISPATCHER_TOKEN=mytoken dispatcher run host-a backup-mysql

# Username (defaults to $USER if not set)
dispatcher run host-a backup-mysql --username deploy
```

### Agent management

```bash
# List all paired agents with cert expiry dates
dispatcher list-agents

# List pending pairing requests
dispatcher list-requests

# Approve or deny a pairing request
dispatcher approve <reqid>
dispatcher deny <reqid>

# Remove an agent from the registry
dispatcher unpair <hostname>
```

`unpair` removes the agent from the registry. The agent's certificate remains
technically valid until its expiry date - decommission the host promptly after
unpairing.


## Agent Tags

Tags are key-value pairs defined in the `[tags]` section of `agent.conf`. They
are reported in discovery responses and can be used by tooling to group,
filter, or route operations.

```ini
[tags]
env  = prod
role = db
site = london
```

Tags are visible in the API `/discovery` response. The dispatcher does not
interpret them - they are for operator and integration use only. To update
tags, edit `agent.conf` and send SIGHUP to reload without restart:

```bash
sudo systemctl kill --signal=HUP dispatcher-agent
```


## Script Directory Restriction

The `script_dirs` setting in `agent.conf` restricts the directories from which
scripts may be loaded. Entries in `scripts.conf` pointing outside an approved
directory are rejected at load time and logged as warnings.

```ini
# Single directory
script_dirs = /opt/dispatcher-scripts

# Multiple directories (colon-separated)
script_dirs = /opt/dispatcher-scripts:/usr/local/lib/dispatcher-scripts
```

When not set, any absolute path in `scripts.conf` is accepted. Setting
`script_dirs` is recommended for production deployments as a defence against
allowlist misconfiguration pointing to arbitrary system paths.


## Automatic Cert Renewal

Agent certs are renewed automatically. No operator action is required during
normal operation.

Renewal is triggered when a ping shows that a cert has less than half its
configured lifetime remaining. With the default `cert_days = 365`, renewal
begins when approximately 182 days of validity remain.

To check current cert status on an agent:

```bash
sudo dispatcher-agent pairing-status
```

To check all agents from the dispatcher:

```bash
dispatcher ping host-a host-b host-c
```

The `CERT EXPIRY` column shows the current expiry. If renewal has occurred
recently, `dispatcher list-agents` will show the updated expiry date.

If renewal fails (network issue, agent unreachable), it is logged at ERR level
on the dispatcher host and retried on the next ping. A cert that repeatedly
fails renewal will eventually expire - the agent will then need to be re-paired
using the standard pairing flow.

To change the cert lifetime, update `cert_days` in `dispatcher.conf`. New and
renewed certs will use the new value. Existing certs are unaffected until their
next renewal.


## API Usage

The API server must be running (`systemctl start dispatcher-api`). By default
it listens on port 7445 with plain HTTP. See TLS configuration below for
encrypted deployments.

All request bodies are JSON with `Content-Type: application/json`.
All responses are JSON.

### Health check

```bash
curl -s http://localhost:7445/health | python3 -m json.tool
```

```json
{ "ok": true, "version": "0.1" }
```

No authentication required. Use for liveness checks.

### Ping

```bash
curl -s -X POST http://localhost:7445/ping \
  -H 'Content-Type: application/json' \
  -d '{"hosts":["sjm-explore"]}' | python3 -m json.tool
```

```json
{
  "ok": true,
  "results": [
    {
      "host":    "sjm-explore",
      "status":  "ok",
      "version": "0.1",
      "expiry":  "Jun  7 16:28:00 2027 GMT",
      "rtt":     "83ms",
      "reqid":   "3a58dd300001"
    }
  ]
}
```

### Run

```bash
curl -s -X POST http://localhost:7445/run \
  -H 'Content-Type: application/json' \
  -d '{
    "hosts":  ["sjm-explore"],
    "script": "backup-mysql",
    "args":   ["--db", "myapp"]
  }' | python3 -m json.tool
```

```json
{
  "ok": true,
  "results": [
    {
      "host":   "sjm-explore",
      "script": "backup-mysql",
      "exit":   0,
      "stdout": "Backup complete: myapp_2026-03-05.sql.gz",
      "stderr": "",
      "rtt":    "312ms",
      "reqid":  "b00c104c0001"
    }
  ]
}
```

A non-zero `exit` code means the script ran but failed. The `stdout` and
`stderr` fields contain the script's output regardless of exit code.

### Discovery

Query all registered agents for their capabilities and tags:

```bash
curl -s http://localhost:7445/discovery | python3 -m json.tool
```

Query specific agents only:

```bash
curl -s -X POST http://localhost:7445/discovery \
  -H 'Content-Type: application/json' \
  -d '{"hosts":["sjm-explore"]}' | python3 -m json.tool
```

```json
{
  "ok": true,
  "hosts": {
    "sjm-explore": {
      "host":    "sjm-explore",
      "status":  "ok",
      "version": "0.1",
      "rtt":     "68ms",
      "tags": { "env": "prod", "role": "db", "site": "london" },
      "scripts": [
        { "name": "backup-mysql", "path": "/opt/dispatcher-scripts/backup-mysql.sh", "executable": true },
        { "name": "check-disk",   "path": "/opt/dispatcher-scripts/check-disk.sh",   "executable": true }
      ]
    }
  }
}
```

An agent that cannot be reached will appear with `"status": "error"` rather
than causing the whole request to fail.

### API with authentication

If the auth hook checks credentials, include them in the request body:

```bash
curl -s -X POST http://localhost:7445/run \
  -H 'Content-Type: application/json' \
  -d '{
    "hosts":    ["sjm-explore"],
    "script":   "backup-mysql",
    "username": "stuart",
    "token":    "mytoken"
  }' | python3 -m json.tool
```

`username` and `token` are both optional. They are passed to the auth hook
as `DISPATCHER_USERNAME` and `DISPATCHER_TOKEN` environment variables and as
fields in the JSON stdin payload.

### API error responses

Auth denied (403):

```json
{ "ok": false, "error": "bad credentials", "code": 2 }
```

Lock conflict - script already running on that host (409):

```json
{ "ok": false, "error": "locked", "code": 4, "conflicts": ["sjm-explore:backup-mysql"] }
```

Bad request (400):

```json
{ "ok": false, "error": "bad request", "detail": "hosts must be a non-empty array" }
```

### HTTP status codes

```
200   Success
400   Bad request (missing or invalid body)
403   Auth denied
404   Unknown endpoint
409   Lock conflict (script already running)
500   Server error
```

### API with TLS

Add to `/etc/dispatcher/dispatcher.conf`:

```ini
api_cert = /etc/dispatcher/dispatcher.crt
api_key  = /etc/dispatcher/dispatcher.key
```

Restart the API service, then use `--cacert` for verification:

```bash
curl -s --cacert /etc/dispatcher/ca.crt \
  https://<dispatcher-host>:7445/health | python3 -m json.tool
```

For external clients that do not have the CA cert, use a certificate issued
by a public CA for the API server rather than the dispatcher's private CA.


## Auth Hook

The auth hook controls who can run what. It is called before every `run` and
`ping` from both the CLI and the API. No hook configured means all requests
are authorised unconditionally.

The hook is the intended policy engine for all access control decisions.
Dispatcher does not implement config-based ACLs - all restriction logic belongs
in the hook, which the operator controls entirely.

### What the hook receives

Environment variables:

```
DISPATCHER_ACTION      run | ping
DISPATCHER_SCRIPT      script name (empty for ping)
DISPATCHER_HOSTS       comma-separated host list
DISPATCHER_ARGS        space-joined args (ambiguous if args contain spaces)
DISPATCHER_ARGS_JSON   args as a JSON array string (use this for arg inspection)
DISPATCHER_USERNAME    username from request (may be empty)
DISPATCHER_TOKEN       token from request (may be empty)
DISPATCHER_SOURCE_IP   originating IP (127.0.0.1 for CLI, caller IP for API)
DISPATCHER_TIMESTAMP   ISO 8601 UTC timestamp
```

Full request context is also available as a JSON object on stdin. This
includes `hosts` and `args` as proper arrays, which is more reliable than
the comma- and space-separated env vars for multi-value fields.

### Exit codes

```
0   authorised
1   denied - generic
2   denied - bad credentials
3   denied - insufficient privilege
```

The hook must not produce output on stdout or stderr. Use syslog for audit
logging within the hook.

### Example: static token check

```bash
#!/bin/bash
if [[ "$DISPATCHER_TOKEN" != "mysecrettoken" ]]; then
    exit 2
fi
exit 0
```

### Example: per-token script restriction

```bash
#!/bin/bash
# backup-token may only run backup-* scripts
if [[ "$DISPATCHER_TOKEN" == "backup-token" ]]; then
    if [[ "$DISPATCHER_SCRIPT" != backup-* ]]; then
        exit 3
    fi
    exit 0
fi

# ops-token may run anything
if [[ "$DISPATCHER_TOKEN" == "ops-token" ]]; then
    exit 0
fi

# No valid token
exit 2
```

### Example: argument inspection using JSON stdin

`DISPATCHER_ARGS_JSON` is a JSON array string. For shell hooks, parse it via
Python or `jq`. For hooks needing reliable argument inspection:

```bash
#!/bin/bash
# Read full context from stdin
INPUT=$(cat)

# Check token first
TOKEN=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" <<< "$INPUT")
if [[ "$TOKEN" != "mytoken" ]]; then
    exit 2
fi

# Inspect args as a proper array
ARGS=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('args',[])[0] if json.load(sys.stdin).get('args') else '')" 2>/dev/null)
exit 0
```

Or use `DISPATCHER_ARGS_JSON` directly:

```bash
#!/bin/bash
# DISPATCHER_ARGS_JSON is a JSON array, e.g. '["--db","myapp"]'
ARG_COUNT=$(echo "$DISPATCHER_ARGS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [[ "$ARG_COUNT" -gt 2 ]]; then
    exit 3   # too many arguments
fi
exit 0
```

### Disabling the hook

Remove or comment out `auth_hook` in `dispatcher.conf`. All requests will
be authorised unconditionally. Appropriate for isolated networks or development.


## Adding Scripts to an Agent

```bash
# Place script
sudo cp check-disk.sh /opt/dispatcher-scripts/
sudo chmod 750 /opt/dispatcher-scripts/check-disk.sh
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/check-disk.sh

# Add to allowlist
echo "check-disk = /opt/dispatcher-scripts/check-disk.sh" \
    | sudo tee -a /etc/dispatcher-agent/scripts.conf

# Reload without restart
sudo systemctl kill --signal=HUP dispatcher-agent

# Verify from dispatcher
dispatcher ping <agent-hostname>
dispatcher run <agent-hostname> check-disk
```

Scripts receive positional arguments exactly as passed by the dispatcher.
They should exit 0 on success, non-zero on failure. stdout and stderr are
both captured and returned in the response.

If `script_dirs` is configured, the new script path must be under an approved
directory, otherwise it will be skipped at reload with a warning in syslog.


## Dispatcher Redundancy

Two dispatcher installations can manage the same fleet of agents by sharing
the same CA. Both dispatchers can sign agent certs and agents will accept
connections from either, because trust is anchored to the CA rather than to
an individual dispatcher cert.

### Setup

On the primary dispatcher, after running `setup-ca` and `setup-dispatcher`:

```bash
# Copy the CA key material to the secondary over a secure channel
sudo scp /etc/dispatcher/ca.key root@secondary:/etc/dispatcher/ca.key
sudo scp /etc/dispatcher/ca.crt root@secondary:/etc/dispatcher/ca.crt
```

On the secondary dispatcher:

```bash
# Generate the secondary's own identity cert using the shared CA
sudo dispatcher setup-dispatcher
```

Each dispatcher then pairs with agents independently using the normal pairing
flow. Because the agent already trusts the shared CA, the TLS connection to
the secondary's pairing port succeeds without any changes to the agent's
`ca.crt`.

### How it works

Each dispatcher maintains its own registry. An agent must pair separately with
each dispatcher. After pairing, either dispatcher can run scripts on any agent
it has paired with.

Cert renewal is handled independently by whichever dispatcher initiates the
ping that triggers it. Both dispatchers update their own registry records.

This is an active-active model with independent registries, not shared-state
failover. Keeping both registries in sync is an operational responsibility.

### CA key security

The CA key must be transferred securely. Use `scp` with host key verification
or an encrypted channel. Do not transfer via pairing - the pairing port is for
agent CSRs only.


## Security Model

mTLS on port 7443
: Both dispatcher and agent must present certificates signed by the private CA.
  A host with no cert, an expired cert, or a cert from a different CA cannot
  connect. This is enforced by `IO::Socket::SSL` with `SSL_verify_mode =>
  SSL_VERIFY_PEER` on both sides.

pairing port security
: Port 7444 does not require a client certificate - the agent has no cert yet
  when it connects. The operator must verify the displayed hostname and IP
  before approving. The pairing port is only open when `pairing-mode` is
  running; there is no persistent listener.

pairing nonce
: Each pairing request includes a random nonce generated by the agent. The
  dispatcher echoes it in the approval response. The agent verifies the nonce
  matches before storing any certs. This prevents misrouted or replayed
  approvals from a concurrent pairing session.

cert renewal security
: Renewal uses the existing authenticated mTLS connection on port 7443. The
  agent reuses its existing key - no new key material is generated. The
  dispatcher only renews certs for agents in its registry.

allowlist enforcement
: Scripts are validated server-side on the agent. Requests for unlisted scripts
  are rejected before any execution. Script names may only contain
  alphanumerics, underscores, and hyphens - path traversal characters cannot
  pass validation.

script directory restriction
: With `script_dirs` configured, even a valid allowlist entry pointing to a
  path outside the approved directories is rejected. The check runs both at
  agent startup and at execution time.

no shell execution
: Scripts are executed via `fork`/`exec` without a shell. Arguments are passed
  as a list directly to the OS. Shell metacharacters in arguments have no
  effect.

API authentication
: Port 7445 has no mTLS. For internet-facing deployments, replace the default
  auth hook with real credential checking, or place the API behind a reverse
  proxy that handles authentication.

auth token handling
: Pass tokens via the `DISPATCHER_TOKEN` environment variable rather than
  `--token` to avoid the value appearing in `ps` output. Tokens are never
  logged by the dispatcher.

CA key
: The CA key lives only in `/etc/dispatcher/ca.key` (mode 0600, readable only
  by root). Loss of the CA key means re-issuing all agent certs. Back it up
  to encrypted offline storage.

unpairing
: `dispatcher unpair <hostname>` removes the registry entry. The agent's cert
  remains technically valid until its natural expiry - there is no cert
  revocation mechanism. Decommission the agent host promptly after unpairing.

file permissions
: CA key: 0600 root. Agent cert and key: 0640 root:dispatcher-agent.
  Agent scripts: 0750 root:dispatcher-agent. The `dispatcher-agent` system user
  has no login shell and no home directory. Runtime directories: 0770
  root:dispatcher.

systemd hardening
: The agent service sets `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `PrivateTmp`, and `PrivateDevices`. The API service sets the
  same and restricts writes to `/var/lib/dispatcher`.


## Reloading and Restarting

Agent config and allowlist reload (no downtime, no dropped connections):

```bash
sudo systemctl kill --signal=HUP dispatcher-agent
```

This reloads both `agent.conf` (including `script_dirs` and `[tags]`) and
`scripts.conf`. Changes to tags and script directory restrictions take effect
immediately for subsequent requests.

Restart agent (drops in-flight connections):

```bash
sudo systemctl restart dispatcher-agent
```

Restart API server:

```bash
sudo systemctl restart dispatcher-api
```


## Troubleshooting

Agent is unreachable after pairing

: Check that the agent service is running (`systemctl status dispatcher-agent`).
  Check that port 7443 is open (`ss -tlnp | grep 7443`). Confirm the cert is
  valid (`sudo dispatcher-agent pairing-status`).

Ping shows `error` with "Connection refused"

: The agent service is not running on that host. Start it with
  `sudo systemctl start dispatcher-agent`.

Ping shows `error` with "SSL handshake failure"

: The cert or CA cert is mismatched. Re-pair the agent using the standard
  pairing flow.

Script not found on agent

: Check `scripts.conf` on the agent. Check that the path is absolute, that the
  file exists, and that it is executable by the `dispatcher-agent` user.
  Check syslog on the agent for `ACTION=deny` lines. If `script_dirs` is
  configured, ensure the script path is under an approved directory.

Auth denied when no hook should be running

: Confirm that `auth_hook` is absent or commented out in `dispatcher.conf`.
  Restart the dispatcher-api service after editing config.

Pairing request does not appear in `list-requests`

: The agent may have failed to write the request (run `sudo dispatcher-agent
  request-pairing`). Stale requests older than 10 minutes are automatically
  cleaned. Check syslog on the dispatcher for `ACTION=pair-request` lines.

Cert renewal not occurring

: Renewal is triggered by ping. Run `dispatcher ping <hostname>` and check the
  CERT EXPIRY column. Check syslog on the dispatcher host for `ACTION=renew`
  lines. If renewal is failing, check for `ERR` level log lines.


## Uninstalling

```bash
sudo ./install.sh --uninstall
```

Config directories, certs, and the agent registry are preserved. To remove
everything:

```bash
sudo rm -rf /etc/dispatcher-agent /etc/dispatcher
sudo rm -rf /var/lib/dispatcher /opt/dispatcher-scripts
sudo userdel dispatcher-agent
sudo groupdel dispatcher
```

