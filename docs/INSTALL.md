---
title: Dispatcher - Installation and Operations
subtitle: Platform requirements, setup, configuration, and operational reference
brand: odcc
---

# Dispatcher - Installation and Operations


## Platform Requirements

Supported platforms:

Debian / Ubuntu
: `apt` package manager, systemd for service management. All Perl dependencies
  available as system packages - no CPAN required.

Alpine Linux
: `apk` package manager. No systemd - services run directly or in Docker.
  See `DOCKER.md` for container deployment.

The installer detects the platform automatically and uses the correct package
names and commands. For RPM-based systems (RHEL, Rocky, Alma), install
dependencies manually and copy files according to the file layout in
`DEVELOPER.md`.


## Dependencies

Agent (`--agent`)

- Debian: `libio-socket-ssl-perl`, `libjson-perl`
- Alpine: `perl-io-socket-ssl`, `perl-json`

Dispatcher (`--dispatcher`)

- Debian: `libwww-perl`, `libio-socket-ssl-perl`, `libjson-perl`
- Alpine: `perl-libwww`, `perl-io-socket-ssl`, `perl-json`

API (`--api`)
: No additional packages beyond the dispatcher role.

All roles require `openssl` (present on any standard installation) and `perl`.

The installer checks all dependencies before making any changes and prints the
correct install command if anything is missing.


## Installation

The installer must be run as root. A role must be specified.

```bash
sudo ./install.sh --agent        # on each remote host
sudo ./install.sh --dispatcher   # on the control host
sudo ./install.sh --api          # on the control host, after --dispatcher
sudo ./install.sh --uninstall    # remove files (preserves config and certs)
sudo ./install.sh --run-tests    # run test suite from source directory
```

`--run-tests` may be combined with a role flag to run tests after installation,
or used alone to test without installing.

### Installed paths

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
/etc/systemd/system/dispatcher-agent.service   (systemd platforms only)
/etc/systemd/system/dispatcher-api.service     (systemd platforms only)
```

The installer stamps the release version from the `VERSION` file into the three
binaries at install time. The source files in the distribution carry the
sentinel value `UNINSTALLED` until the installer runs. After installation,
`dispatcher --version` reports the version of the release that was installed.

### Dispatcher group

The installer creates a `dispatcher` system group. Add yourself to it for
CLI access without sudo:

```bash
sudo usermod -aG dispatcher $USER
# Log out and back in for the group to take effect
```


## Running the Tests

Run from the project root before or after installing:

```bash
prove -Ilib t/
```

Or via the installer:

```bash
sudo ./install.sh --agent --run-tests
```

`t/lock.t` requires `t/lock-holder.pl` to be present alongside it.
`t/auth.t` and `t/pairing-dispatcher.t` require `libjson-perl` / `perl-json`
and are skipped automatically if not available.


## Initial Setup

### 1. Dispatcher host - CA and certificates

Initialise the CA (once only - do not repeat on an existing installation):

```bash
sudo dispatcher setup-ca
```

Generate the dispatcher's own certificate:

```bash
sudo dispatcher setup-dispatcher
```

Both commands write to `/etc/dispatcher/`. The CA private key (`ca.key`) is
set 0600 and must not leave this host. Back it up to encrypted offline storage.

### 2. Configure the dispatcher

Edit `/etc/dispatcher/dispatcher.conf`:

```ini
port      = 7443
cert      = /etc/dispatcher/dispatcher.crt
key       = /etc/dispatcher/dispatcher.key
ca        = /etc/dispatcher/ca.crt
auth_hook = /etc/dispatcher/auth-hook

# Cert lifetime for new and renewed agent certs (days)
cert_days = 365
```

`auth_hook` is optional. Remove or comment it out to authorise all requests
unconditionally. Appropriate for isolated networks; not recommended for
production deployments accessible from outside.

### 3. Agent host - configure before pairing

Edit `/etc/dispatcher-agent/agent.conf`:

```ini
port = 7443
cert = /etc/dispatcher-agent/agent.crt
key  = /etc/dispatcher-agent/agent.key
ca   = /etc/dispatcher-agent/ca.crt

# Restrict scripts to approved directories (recommended)
script_dirs = /opt/dispatcher-scripts

# Optional: agent-side auth hook for independent token validation
# auth_hook = /etc/dispatcher-agent/auth-hook

# Optional tags - reported in discovery responses
[tags]
env  = prod
role = db
site = london
```

Edit the allowlist `/etc/dispatcher-agent/scripts.conf`:

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

This blocks until interrupted. When run in a terminal it is interactive -
incoming requests are displayed immediately and you are prompted to approve
or deny.

On the agent host:

```bash
sudo dispatcher-agent request-pairing --dispatcher <dispatcher-hostname>
```

The agent connects and waits. A prompt appears in the pairing mode terminal:

```
Pairing request from agent-host-01 (192.0.2.10) - ID: 00c9845e0001
  Received: 2026-03-05T18:38:09Z
Accept, Deny, or Skip? [a/d/s]:
```

Type `a` to approve. The agent stores its cert and exits. Press Ctrl-C to
stop pairing mode.

If multiple requests arrive simultaneously they are numbered:

```
1. agent-host-01 (192.0.2.10) - ID: 00c9845e0001 - 2026-03-05T18:38:09Z
2. prod-db-01  (192.0.2.12) - ID: 1a4f2e330001 - 2026-03-05T18:38:22Z
Command (a1/d1/a2/d2/list/quit):
```

Use `a1`, `d2` etc. to act individually, `list` to redisplay, `quit` to exit.

For non-interactive use (scripted or from a service), use separate commands
from another terminal while pairing mode runs:

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

On systemd platforms:

```bash
sudo systemctl enable dispatcher-agent
sudo systemctl start dispatcher-agent
sudo systemctl status dispatcher-agent
```

On Alpine or without systemd:

```bash
dispatcher-agent serve
```

### 6. Verify from the dispatcher

```bash
dispatcher ping <agent-hostname>
```

Expected output:

```
HOST             STATUS    RTT    CERT EXPIRY                   VERSION
-----------------------------------------------------------------------
agent-hostname   ok        45ms   Jun  7 16:28:00 2027 GMT      0.1
```

### 7. Start the API server (optional)

On systemd platforms:

```bash
sudo systemctl enable dispatcher-api
sudo systemctl start dispatcher-api
```

On Alpine or without systemd:

```bash
dispatcher-api
```

Verify:

```bash
curl -s http://localhost:7445/health | python3 -m json.tool
```


## CLI Reference

### Run

```bash
# Run a script on one host
dispatcher run host-a backup-mysql

# With arguments (everything after -- is passed to the script)
dispatcher run host-a logger -- -t my-tag "hello from dispatcher"

# Multiple hosts in parallel
dispatcher run host-a host-b host-c check-disk

# Custom port on one host
dispatcher run host-a:7450 host-b backup-mysql

# JSON output
dispatcher run host-a backup-mysql --json

# With auth token (preferred: via environment, does not appear in ps)
DISPATCHER_TOKEN=mytoken dispatcher run host-a backup-mysql
dispatcher run host-a backup-mysql --token mytoken --username deploy
```

### Ping

```bash
dispatcher ping host-a
dispatcher ping host-a host-b host-c
dispatcher ping host-a --json
```

### Agent management

```bash
dispatcher list-agents                  # all paired agents with cert expiry
dispatcher list-requests                # pending pairing requests
dispatcher approve <reqid>              # approve a pairing request
dispatcher deny <reqid>                 # deny a pairing request
dispatcher unpair <hostname>            # remove agent from registry
```

`unpair` removes the registry entry. The agent cert remains valid until its
natural expiry - decommission the host promptly.


## API Reference

The API server listens on port 7445. All bodies are JSON with
`Content-Type: application/json`.

### Endpoints

`GET /health`
: Liveness check. No auth. Returns `{ "ok": true, "version": "0.1" }`.

`POST /ping`
: Body: `{ "hosts": [...], "username": "...", "token": "..." }`.
  Returns `{ "ok": true, "results": [...] }`.

`POST /run`
: Body: `{ "hosts": [...], "script": "...", "args": [...], "username": "...", "token": "..." }`.
  Returns `{ "ok": true, "results": [...] }`.

`GET /discovery` or `POST /discovery`
: Optional body: `{ "hosts": [...] }`. If hosts omitted, queries all registered
  agents. Returns `{ "ok": true, "hosts": { hostname: { scripts, tags, ... } } }`.

### HTTP status codes

```
200   Success
400   Bad request
403   Auth denied
404   Unknown endpoint
409   Lock conflict (script already running on host)
500   Server error
```

### Examples

```bash
# Ping
curl -s -X POST http://localhost:7445/ping \
  -H 'Content-Type: application/json' \
  -d '{"hosts":["agent-host-01"]}' | python3 -m json.tool

# Run
curl -s -X POST http://localhost:7445/run \
  -H 'Content-Type: application/json' \
  -d '{"hosts":["agent-host-01"],"script":"backup-mysql","args":["--db","myapp"]}' \
  | python3 -m json.tool

# Discovery
curl -s http://localhost:7445/discovery | python3 -m json.tool
```

### API TLS

Add to `/etc/dispatcher/dispatcher.conf`:

```ini
api_cert = /etc/dispatcher/dispatcher.crt
api_key  = /etc/dispatcher/dispatcher.key
```

Restart the API service. Clients use `--cacert /etc/dispatcher/ca.crt` or a
certificate from a public CA if clients do not have the private CA cert.


## Auth Hook

The auth hook is called before every `run` and `ping` from both CLI and API.
It is the sole policy engine - dispatcher has no built-in ACLs.

The hook receives request context as environment variables and as a JSON object
on stdin. Tokens and usernames are forwarded through to agent hooks and to
scripts via JSON stdin, enabling token validation at every stage of an
execution pipeline.

### Environment variables

```
DISPATCHER_ACTION      run | ping
DISPATCHER_SCRIPT      script name (empty for ping)
DISPATCHER_HOSTS       comma-separated host list
DISPATCHER_ARGS        space-joined args (ambiguous if args contain spaces)
DISPATCHER_ARGS_JSON   args as a JSON array string (use this for arg inspection)
DISPATCHER_USERNAME    username from request (may be empty)
DISPATCHER_TOKEN       token from request (may be empty)
DISPATCHER_SOURCE_IP   127.0.0.1 for CLI, caller IP for API
DISPATCHER_TIMESTAMP   ISO 8601 UTC timestamp
```

### Exit codes

```
0   authorised
1   denied - generic
2   denied - bad credentials
3   denied - insufficient privilege
```

The hook must not produce output. Use syslog for audit logging.

### Examples

Static token check:

```bash
#!/bin/bash
[[ "$DISPATCHER_TOKEN" == "mysecrettoken" ]] || exit 2
exit 0
```

Per-token script restriction:

```bash
#!/bin/bash
case "$DISPATCHER_TOKEN" in
    backup-token)
        [[ "$DISPATCHER_SCRIPT" == backup-* ]] || exit 3
        exit 0 ;;
    ops-token)
        exit 0 ;;
    *)
        exit 2 ;;
esac
```

Argument count check using `DISPATCHER_ARGS_JSON`:

```bash
#!/bin/bash
ARG_COUNT=$(echo "$DISPATCHER_ARGS_JSON" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[[ "$ARG_COUNT" -le 2 ]] || exit 3
exit 0
```

### Agent-side auth hook

Agents can also run an auth hook, configured via `auth_hook` in `agent.conf`.
This runs after allowlist validation and receives the same context including
token and username forwarded from the dispatcher. Useful for independent token
validation in zero-trust or multi-dispatcher deployments.


## Configuration Reference

### `/etc/dispatcher/dispatcher.conf`

```ini
port      = 7443                          # mTLS port agents connect to
cert      = /etc/dispatcher/dispatcher.crt
key       = /etc/dispatcher/dispatcher.key
ca        = /etc/dispatcher/ca.crt
auth_hook = /etc/dispatcher/auth-hook     # optional
api_port  = 7445                          # API server port
api_cert  = /etc/dispatcher/dispatcher.crt  # optional, enables TLS on API
api_key   = /etc/dispatcher/dispatcher.key  # optional
cert_days = 365                           # lifetime for new/renewed agent certs
```

### `/etc/dispatcher-agent/agent.conf`

```ini
port = 7443
cert = /etc/dispatcher-agent/agent.crt
key  = /etc/dispatcher-agent/agent.key
ca   = /etc/dispatcher-agent/ca.crt

# Colon-separated list of approved script directories (optional)
script_dirs = /opt/dispatcher-scripts

# Agent-side auth hook executable (optional)
# auth_hook = /etc/dispatcher-agent/auth-hook

# Pairing port (default: 7444)
# pairing_port = 7444

# Restrict connections to known dispatcher IPs (optional)
# allowed_ips = 192.168.1.10, 10.0.0.0/8

# Rate limiting (defaults shown - omit to use defaults)
# rate_limit_volume = 10/60/300
# rate_limit_probe  = 3/600/3600
# rate_limit_disable = 1   # disable for testing only

[tags]
env  = prod
role = db
site = london
```

### `/etc/dispatcher-agent/scripts.conf`

```ini
# name = /absolute/path/to/script
backup-mysql  = /opt/dispatcher-scripts/backup-mysql.sh
check-disk    = /opt/dispatcher-scripts/check-disk.sh
```


## Adding Scripts to an Agent

```bash
sudo cp check-disk.sh /opt/dispatcher-scripts/
sudo chmod 750 /opt/dispatcher-scripts/check-disk.sh
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/check-disk.sh

echo "check-disk = /opt/dispatcher-scripts/check-disk.sh" \
    | sudo tee -a /etc/dispatcher-agent/scripts.conf

# Reload without restart
sudo systemctl kill --signal=HUP dispatcher-agent
```

Scripts receive positional arguments as passed. They should exit 0 on success,
non-zero on failure. stdout and stderr are both captured and returned.

Full request context (script name, args, reqid, peer IP, username, token,
timestamp) is also piped to the script as a JSON object on stdin. Scripts that
do not need it can redirect stdin: add `exec 0</dev/null` at the top of the
script.

### Script permissions and privilege

The agent process runs as root by default. Scripts that should not run as root
can drop privileges explicitly:

```bash
#!/bin/bash
exec sudo -u appuser /usr/local/bin/my-script.sh "$@"
```

Add a targeted sudoers rule:

```
dispatcher-agent ALL=(appuser) NOPASSWD: /usr/local/bin/my-script.sh
```

This hands privilege management to `sudo`, which has exactly that job.


## Automatic Cert Renewal

Renewal is triggered automatically after every successful ping when remaining
cert validity is less than half the configured `cert_days`. With the default
365 days, renewal begins at approximately 182 days remaining.

No operator action is needed during normal operation. To check cert status:

```bash
# On the agent host
sudo dispatcher-agent pairing-status

# From the dispatcher (CERT EXPIRY column)
dispatcher ping host-a host-b
```

Renewal failure is logged at ERR level on the dispatcher and retried on the
next ping. A cert that fails repeatedly will eventually expire and require
re-pairing.

To change cert lifetime, update `cert_days` in `dispatcher.conf`. Existing
certs are unaffected until their next renewal.


## Dispatcher Redundancy

Two dispatcher installations can share a CA and manage the same agent fleet
independently. Each dispatcher signs certs and maintains its own registry.
Agents accept connections from any dispatcher that shares the CA.

On the primary dispatcher after `setup-ca` and `setup-dispatcher`:

```bash
# Transfer CA material to secondary over a secure channel
sudo scp /etc/dispatcher/ca.key root@secondary:/etc/dispatcher/ca.key
sudo scp /etc/dispatcher/ca.crt root@secondary:/etc/dispatcher/ca.crt
```

On the secondary:

```bash
sudo dispatcher setup-dispatcher
```

Each dispatcher then pairs with agents independently. Agents must pair with
each dispatcher separately. This is active-active with independent registries -
registry synchronisation is an operational responsibility.


## Reloading and Restarting

Agent config and allowlist reload without downtime:

```bash
sudo systemctl kill --signal=HUP dispatcher-agent
# or on Alpine/non-systemd: kill -HUP <pid>
```

Reloads `agent.conf` and `scripts.conf` including `script_dirs`, `auth_hook`,
and `[tags]`. Changes take effect for subsequent requests.

Restart agent (drops in-flight connections):

```bash
sudo systemctl restart dispatcher-agent
```

Restart API server:

```bash
sudo systemctl restart dispatcher-api
```


## Troubleshooting

Agent unreachable after pairing
: Check the service is running: `systemctl status dispatcher-agent`.
  Check port 7443 is open: `ss -tlnp | grep 7443`.
  Verify cert: `sudo dispatcher-agent pairing-status`.

Connection refused
: The agent service is not running. `sudo systemctl start dispatcher-agent`.

SSL handshake failure
: Cert or CA mismatch. Re-pair the agent.

Script not found
: Check `scripts.conf` - path must be absolute and the file must be executable
  by the `dispatcher-agent` user. Check syslog for `ACTION=deny` lines.
  If `script_dirs` is set, confirm the path is under an approved directory.

Auth denied unexpectedly
: Confirm `auth_hook` is absent or commented out in `dispatcher.conf` if no
  hook is intended. Restart the API service after config changes.

Pairing request missing from `list-requests`
: Agent may have failed mid-pairing (run `sudo dispatcher-agent request-pairing`
  to retry). Stale requests older than 10 minutes are cleaned automatically.
  Check dispatcher syslog for `ACTION=pair-request`.

Cert renewal not occurring
: Renewal is triggered by ping. Check `CERT EXPIRY` in ping output.
  Check dispatcher syslog for `ACTION=renew` and `ERR` lines.

Connection blocked unexpectedly (`ACTION=rate-block` in syslog)
: The agent has rate-limited the source IP. The volume threshold (default: 10
  connections in 60 seconds) can be triggered by the integration test suite or
  rapid repeated pings. The block expires automatically (default: 5 minutes for
  volume, 1 hour for probe). To clear immediately, reload the agent:
  `sudo systemctl reload dispatcher-agent` (rate limit state is held in memory
  and reset on SIGHUP). To disable rate limiting during testing, set
  `rate_limit_disable = 1` in `agent.conf` and reload. Remove it before
  returning to production use.


## Uninstalling

```bash
sudo ./install.sh --uninstall
```

Config, certs, and the agent registry are preserved. To remove everything:

```bash
sudo rm -rf /etc/dispatcher-agent /etc/dispatcher
sudo rm -rf /var/lib/dispatcher /opt/dispatcher-scripts
# Debian
sudo userdel dispatcher-agent && sudo groupdel dispatcher
# Alpine
sudo deluser dispatcher-agent && sudo delgroup dispatcher
```
