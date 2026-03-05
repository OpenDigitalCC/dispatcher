---
title: Dispatcher and agent - User manual
subtitle: Installation, testing, set‐up and first run
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
  certificate exchange. Maintains a registry of all paired agents.

dispatcher-agent (remote hosts)
: HTTPS server listening on port 7443 (mTLS). Accepts `run`, `ping`, and
  `capabilities` requests. Executes only scripts named in the allowlist.
  Reloads the allowlist on SIGHUP without dropping connections.

dispatcher-api (control host, optional)
: HTTP API server listening on port 7445. Exposes run, ping, and discovery
  operations as JSON endpoints. Uses the same auth hook and lock checking as
  the CLI. Suitable for integration with monitoring tools, dashboards, or
  automation pipelines.

pairing
: One-time certificate exchange on port 7444. The agent generates a key and CSR,
  connects to the dispatcher, and waits. The operator approves on the dispatcher
  host, which signs the CSR with the private CA and delivers the cert back over
  the same connection. Approved agents are recorded in a persistent registry.
  After pairing, all operational communication uses mTLS on port 7443.

private CA
: Created on the dispatcher host with `dispatcher setup-ca`. All agent certs are
  signed by this CA. The CA key never leaves the dispatcher host.

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


## Source Layout

```
bin/
  dispatcher              CLI for the control host
  dispatcher-agent        Server daemon for remote hosts
  dispatcher-api          HTTP API server for the control host

lib/Dispatcher/
  CA.pm                   CA and CSR signing via openssl
  Log.pm                  Structured syslog: ACTION=value format
  Pairing.pm              Dispatcher-side pairing server and approval queue
  Registry.pm             Persistent agent store
  Engine.pm               Parallel dispatch, ping, and capabilities query
  Auth.pm                 Auth hook runner
  Lock.pm                 flock-based concurrency control
  API.pm                  HTTP API server
  Agent/
    Config.pm             Config and allowlist loading
    Pairing.pm            Agent-side pairing: key/CSR generation, cert storage
    Runner.pm             Script execution via fork/exec (no shell)

etc/
  agent.conf.example
  dispatcher.conf.example
  scripts.conf.example
  auth-hook.example
  dispatcher-agent.service
  dispatcher-api.service

t/
  agent-config.t
  agent-run.t
  auth.t
  dispatcher-cli.t
  engine.t
  lock.t
  lock-holder.pl
  log.t
  pairing-csr.t
  registry.t

install.sh
```


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

Note: `t/lock.t` uses `t/lock-holder.pl` as a subprocess helper and requires
both files to be present.


## Initial Setup

### 1. Dispatcher host - CA and certificate

Initialise the CA (once only):

```bash
sudo dispatcher setup-ca
```

Generate the dispatcher's own certificate:

```bash
cd /etc/dispatcher

sudo openssl genrsa -out dispatcher.key 4096
sudo openssl req -new -key dispatcher.key -out dispatcher.csr -subj '/CN=dispatcher'
sudo openssl x509 -req -in dispatcher.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out dispatcher.crt -days 825
sudo chmod 600 dispatcher.key
sudo rm dispatcher.csr
```

### 2. Agent host - before pairing

Edit the allowlist:

```bash
sudo $EDITOR /etc/dispatcher-agent/scripts.conf
```

Place scripts in `/opt/dispatcher-scripts/`:

```bash
sudo cp your-script.sh /opt/dispatcher-scripts/
sudo chmod 750 /opt/dispatcher-scripts/your-script.sh
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/your-script.sh
```

### 3. Pairing

On the dispatcher host, start pairing mode (blocks until interrupted):

```bash
sudo dispatcher pairing-mode
```

On the agent host, request pairing:

```bash
sudo dispatcher-agent request-pairing --dispatcher <dispatcher-hostname>
```

The agent prints `Connecting to dispatcher...` and waits. On the dispatcher
host in a second terminal, list and approve the request:

```bash
dispatcher list-requests
dispatcher approve <reqid>
```

The agent prints `Pairing complete. Certificates stored.` and exits. The agent
is now recorded in the dispatcher's registry - confirm with:

```bash
dispatcher list-agents
```

### 4. Start the agent

```bash
sudo systemctl enable dispatcher-agent
sudo systemctl start dispatcher-agent
sudo systemctl status dispatcher-agent
```

### 5. Verify from the dispatcher

```bash
dispatcher ping <agent-hostname>
```

Expected output:

```
HOST                            STATUS    RTT       CERT EXPIRY                   VERSION
-----------------------------------------------------------------------------------------
agent-hostname                  ok        45ms      Jun  7 16:28:00 2028 GMT      0.1
```

### 6. Start the API server (optional)

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

# With auth token
DISPATCHER_TOKEN=mytoken dispatcher run host-a backup-mysql
dispatcher run host-a backup-mysql --token mytoken
```

### Agent management

```bash
# List all paired agents
dispatcher list-agents

# List pending pairing requests
dispatcher list-requests

# Approve or deny a pairing request
dispatcher approve <reqid>
dispatcher deny <reqid>
```


## API Usage

The API server must be running (`systemctl start dispatcher-api`). By default
it listens on port 7445 with plain HTTP. TLS can be enabled by setting
`api_cert` and `api_key` in `dispatcher.conf`.

All request bodies are JSON with `Content-Type: application/json`.
All responses are JSON.

### Health check

```bash
curl -s http://localhost:7445/health | python3 -m json.tool
```

```json
{ "ok": true, "version": "0.1" }
```

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
      "host": "sjm-explore",
      "status": "ok",
      "version": "0.1",
      "expiry": "Jun  7 16:28:00 2028 GMT",
      "rtt": "83ms",
      "reqid": "3a58dd30"
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
    "script": "logger",
    "args":   ["-t", "dispatcher-test", "hello from api"]
  }' | python3 -m json.tool
```

```json
{
  "ok": true,
  "results": [
    {
      "host":   "sjm-explore",
      "script": "logger",
      "exit":   0,
      "stdout": "",
      "stderr": "",
      "rtt":    "76ms",
      "reqid":  "b00c104c"
    }
  ]
}
```

### Discovery

Query all registered agents for their capabilities:

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
      "scripts": [
        { "name": "logger", "path": "/usr/bin/logger", "executable": true }
      ]
    }
  }
}
```

### API with auth token

If the auth hook checks tokens, pass credentials in the request body:

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

### API with TLS

Add to `/etc/dispatcher/dispatcher.conf`:

```ini
api_cert = /etc/dispatcher/dispatcher.crt
api_key  = /etc/dispatcher/dispatcher.key
```

Restart the API service, then use `--cacert`:

```bash
curl -s --cacert /etc/dispatcher/ca.crt \
  https://<dispatcher-host>:7445/health | python3 -m json.tool
```


## Auth Hook

The auth hook controls who can run what. It is called before every `run` and
`ping` from both the CLI and the API. The default hook (`/etc/dispatcher/auth-hook`)
authorises everything - replace it with real logic for production use.

The hook receives:

- Environment variables: `DISPATCHER_ACTION`, `DISPATCHER_SCRIPT`,
  `DISPATCHER_HOSTS`, `DISPATCHER_USERNAME`, `DISPATCHER_TOKEN`,
  `DISPATCHER_SOURCE_IP`, and others.
- Full request context as JSON on stdin.

Exit codes:

```
0   authorised
1   denied
2   denied - bad credentials
3   denied - insufficient privilege
```

The hook must not produce output on stdout or stderr. Use syslog for audit
logging within the hook.

Example hook that checks a static token:

```bash
#!/bin/bash
if [[ "$DISPATCHER_TOKEN" != "mysecrettoken" ]]; then
    exit 2
fi
exit 0
```

To disable auth entirely, remove or comment out `auth_hook` in `dispatcher.conf`.


## Adding Scripts to an Agent

```bash
# Place script
sudo cp check-disk.sh /opt/dispatcher-scripts/
sudo chmod 750 /opt/dispatcher-scripts/check-disk.sh
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/check-disk.sh

# Add to allowlist
echo "check-disk = /opt/dispatcher-scripts/check-disk.sh" \
    | sudo tee -a /etc/dispatcher-agent/scripts.conf

# Reload allowlist without restart
sudo systemctl kill --signal=HUP dispatcher-agent

# Verify it appears in discovery
curl -s http://localhost:7445/discovery | python3 -m json.tool
```

Scripts receive positional arguments exactly as passed by the dispatcher.
They should exit 0 on success, non-zero on failure. stdout and stderr are
both captured and returned in the response.


## Security Notes

allowlist enforcement
: Scripts are validated server-side on the agent. Requests for unlisted scripts
  are rejected without execution. Script names may only contain alphanumerics
  and hyphens.

no shell execution
: Scripts are executed via `fork`/`exec` without a shell. Arguments are passed
  as a list directly to the OS, preventing injection via script arguments.

mTLS
: Port 7443 requires mutual certificate authentication. Both the dispatcher and
  agent must present certs signed by the private CA. An uncertificated client
  cannot connect.

API authentication
: Port 7445 has no mTLS. For internet-facing deployments, replace the default
  auth hook with real credential checking, or place the API behind a reverse
  proxy that handles authentication.

auth token
: Pass tokens via the `DISPATCHER_TOKEN` environment variable rather than
  `--token` to avoid the value appearing in `ps` output.

CA key
: The CA key lives only in `/etc/dispatcher/ca.key`. Back it up securely.
  Loss of the CA key means re-pairing all agents.

cert expiry
: Agent certs are signed for 825 days. The `dispatcher ping` and
  `dispatcher list-agents` output shows expiry dates. Re-pair before expiry
  using the same `pairing-mode` / `request-pairing` flow - existing config
  and allowlists are preserved.


## Reloading and Restarting

Agent allowlist reload (no downtime):

```bash
sudo systemctl kill --signal=HUP dispatcher-agent
```

Restart agent (drops in-flight connections):

```bash
sudo systemctl restart dispatcher-agent
```

Restart API server:

```bash
sudo systemctl restart dispatcher-api
```


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
