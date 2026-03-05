---
title: Dispatcher and agent - Developer document
subtitle: Purpose, contents, protocol, logging, security model and extending
brand: cloudient
---

# Dispatcher - Developer Documentation

## Purpose and Design Criteria

Dispatcher is a Perl machine-to-machine remote script execution system. It
allows a control host (the dispatcher) to run scripts on remote hosts (agents)
over mTLS-authenticated HTTPS, with no SSH involved.

The design criteria were:

no SSH
: The system must not rely on SSH. Agents expose a purpose-built HTTPS server
  with an explicit allowlist of callable scripts.

locked-down execution
: Agents execute only scripts named in a per-host allowlist. Script names are
  validated against an alphanumeric pattern before allowlist lookup. Scripts are
  executed via `fork`/`exec` with no shell, preventing injection via arguments.

mTLS trust
: All operational traffic uses mutual TLS. Both dispatcher and agent present
  certificates signed by a private CA. The CA is created once on the dispatcher
  host; the CA key never leaves that host.

pairing workflow
: The initial certificate exchange uses a separate TLS port (7444) where the
  agent connects to the dispatcher to submit a CSR. The dispatcher holds the
  connection open while waiting for operator approval. On approval the CSR is
  signed and the cert is delivered back over the open connection. Approved
  agents are recorded in a persistent registry.

argument support
: Scripts can receive arguments. Arguments are passed as a JSON array and
  forwarded to `exec` as a list, never interpolated into a shell command.

structured logging
: All actions are logged to syslog in a consistent `ACTION=value KEY=value`
  format with a request ID that correlates dispatcher and agent log lines for
  the same operation.

auth hook
: An optional external executable is called before every `run` and `ping`
  request, from both the CLI and the API. It receives request context as
  environment variables and JSON on stdin. Exit codes map to authorisation
  outcomes. No hook configured means unconditional pass.

HTTP REST API
: An optional API server (`dispatcher-api`) exposes the same run, ping, and
  discovery operations as HTTP endpoints with JSON request and response bodies.
  Auth hook and lock checking apply identically to CLI and API.

Debian trixie system packages only
: No CPAN. All dependencies are available as `apt` packages on Debian trixie.
  The installer checks for missing packages and exits with the install command
  rather than attempting to install them automatically.

function-based design
: Each module exposes discrete, testable functions. Business logic is in the
  library modules; the `bin/` scripts handle argument parsing and output only.


## File Map

```
bin/
  dispatcher              CLI for the control host
  dispatcher-agent        Daemon for remote hosts
  dispatcher-api          HTTP API server for the control host

lib/Dispatcher/
  Log.pm                  Structured syslog
  CA.pm                   CA and cert signing via openssl subprocess
  Pairing.pm              Dispatcher-side pairing server and approval queue
  Registry.pm             Persistent agent store (written at pairing, read by API)
  Engine.pm               Parallel dispatch, ping, and capabilities query
  Auth.pm                 Auth hook runner
  Lock.pm                 flock-based host:script concurrency control
  API.pm                  HTTP API server (fork-per-request)
  Agent/
    Config.pm             Config and allowlist loading and validation
    Pairing.pm            Agent-side: key/CSR generation, pairing request, cert storage
    Runner.pm             Script execution via fork/exec

etc/
  agent.conf.example           Template for /etc/dispatcher-agent/agent.conf
  dispatcher.conf.example      Template for /etc/dispatcher/dispatcher.conf
  scripts.conf.example         Template for /etc/dispatcher-agent/scripts.conf
  auth-hook.example            Always-authorise hook template
  dispatcher-agent.service     Systemd unit for agent
  dispatcher-api.service       Systemd unit for API server

t/
  agent-config.t          Tests for Dispatcher::Agent::Config
  agent-run.t             Tests for Dispatcher::Agent::Runner
  auth.t                  Tests for Dispatcher::Auth
  dispatcher-cli.t        Tests for CLI argument parsing and output formatting
  engine.t                Tests for Dispatcher::Engine
  lock.t                  Tests for Dispatcher::Lock
  lock-holder.pl          Test helper: acquires a lock and holds until stdin closes
  log.t                   Tests for Dispatcher::Log
  pairing-csr.t           Tests for Dispatcher::Agent::Pairing (key/CSR generation)
  registry.t              Tests for Dispatcher::Registry

install.sh                Installer: --agent | --dispatcher | --api | --uninstall
README.md                 User-facing install, test, and configuration guide
DEVELOPER.md              This file
```


## Ports

7443
: Operational mTLS port. The agent listens here for `run`, `ping`, and
  `capabilities` requests. Both sides present certificates signed by the
  private CA.

7444
: Pairing port. Only open when the dispatcher is in `pairing-mode`. TLS server
  cert only (no client cert required) since the agent has no cert yet. Agents
  connect here to submit a CSR and wait for the signed cert.

7445
: API port. The `dispatcher-api` HTTP server listens here. Plain HTTP by
  default; TLS enabled if `api_cert` and `api_key` are set in
  `dispatcher.conf`. No mTLS - auth is delegated to the auth hook.


## Certificate Layout

Dispatcher host (`/etc/dispatcher/`)

```
ca.key          CA private key (0600, root only, never leaves this host)
ca.crt          CA certificate (distributed to agents during pairing)
ca.serial       Serial counter for issued certs
dispatcher.key  Dispatcher's own private key (0600)
dispatcher.crt  Dispatcher's own cert, signed by CA
auth-hook       Auth hook executable (0755)
```

Agent host (`/etc/dispatcher-agent/`)

```
agent.key       Agent's private key (0640, root:dispatcher-agent)
agent.crt       Agent's cert, signed by dispatcher CA (0640, root:dispatcher-agent)
ca.crt          CA cert from dispatcher (0644)
agent.conf      Port, cert paths
scripts.conf    Allowlist: name = /absolute/path
```

Runtime directories

```
/var/lib/dispatcher/pairing/    Pairing queue ({reqid}.json, .approved, .denied)
/var/lib/dispatcher/agents/     Agent registry ({hostname}.json, written at pairing)
/var/lib/dispatcher/locks/      flock files for host:script concurrency control
```


## Module Reference

### `Dispatcher::Log`

Structured syslog. Call `init()` once at startup, then `log_action()` for each
event. If `init()` has not been called, `log_action()` falls back to stderr,
allowing library functions to log without requiring a syslog context.

```perl
Dispatcher::Log::init('dispatcher-agent');

Dispatcher::Log::log_action('INFO', {
    ACTION => 'run',
    SCRIPT => 'backup',
    EXIT   => 0,
    PEER   => '10.0.1.5',
    REQID  => 'a3f9b2c1',
});
```

Output format: `ACTION=run EXIT=0 PEER=10.0.1.5 REQID=a3f9b2c1 SCRIPT=backup`

`ACTION` is always first. All other keys follow in alphabetical order. Values
containing spaces are quoted. Levels: `INFO`, `WARNING`, `ERR`.

Functions:

`init($program_name)`
: Opens syslog with `LOG_DAEMON` facility. Sets the ident used in all
  subsequent log lines.

`log_action($level, \%fields)`
: Writes one structured syslog line. `ACTION` key is required.

`close_log()`
: Closes the syslog handle. Not usually needed explicitly.


### `Dispatcher::CA`

CA management and CSR signing via `openssl` subprocesses. All crypto is
delegated to the system `openssl` binary - no Perl crypto modules used.

Functions:

`generate_ca(%opts)`
: Generates `ca.key` and `ca.crt` in `ca_dir` (default `/etc/dispatcher`).
  Dies if CA already exists unless `force => 1`. Sets `ca.key` to mode 0600.
  Options: `days` (default 3650), `bits` (default 4096), `cn`, `ca_dir`, `force`.

`sign_csr(%opts)`
: Accepts a CSR as a PEM string, writes it to a temp file, calls
  `openssl x509 -req` to sign it, returns the signed cert PEM.
  Options: `csr_pem` (required), `ca_dir`, `days` (default 825), `out_path`.

`read_ca_cert(%opts)`
: Returns the CA cert PEM from `ca_dir/ca.crt`. Used during pairing to send
  the CA cert to the agent alongside the signed agent cert.


### `Dispatcher::Pairing`

Dispatcher-side pairing server and approval queue. Handles the initial
certificate exchange from the dispatcher's perspective.

The pairing flow uses the filesystem as a message queue between the main
dispatcher process (which the operator interacts with via `approve`/`deny`)
and the forked child processes (which hold connections open to waiting agents).

File states in `/var/lib/dispatcher/pairing/`:

```
{reqid}.json      Pending request (CSR, hostname, IP, timestamp)
{reqid}.approved  Written by approve_request(); read by waiting child
{reqid}.denied    Written by deny_request(); read by waiting child
```

The child polls every 2 seconds for up to 10 minutes. On finding an `.approved`
or `.denied` file it sends the response and exits.

`approve_request` also calls `Dispatcher::Registry::register_agent()` to write
a persistent record of the approved agent before cleaning up the pairing files.

Functions:

`run_pairing_mode(%opts)`
: Starts a TLS server on port 7444. Accepts connections, forks a child per
  connection. Each child calls `_handle_pair_request()`. Blocks until SIGINT
  or SIGTERM. Options: `port`, `cert`, `key`, `ca_dir`, `log_fn`.

`list_requests(%opts)`
: Returns an arrayref of pending request hashrefs from `pairing_dir`, sorted
  by `received` timestamp. Each hashref has: `id`, `hostname`, `ip`, `csr`, `received`.

`approve_request(%opts)`
: Reads the `.json` file, signs the CSR with `Dispatcher::CA::sign_csr()`,
  writes the signed cert and CA cert to `{reqid}.approved`, then calls
  `Dispatcher::Registry::register_agent()`. The waiting child picks this up
  within 2 seconds and delivers it to the agent.
  Options: `reqid` (required), `ca_dir`, `pairing_dir`, `log_fn`.

`deny_request(%opts)`
: Writes `{reqid}.denied`. The waiting child delivers a denial response to
  the agent. Options: `reqid` (required), `pairing_dir`, `log_fn`.

Important SSL note - `SSL_no_shutdown => 1` on parent close
: When the parent process calls `$conn->close` after forking, `IO::Socket::SSL`
  by default sends a TLS close-notify to the remote end, which closes the
  child's connection too. Passing `SSL_no_shutdown => 1` releases the parent's
  file descriptor without sending close-notify, leaving the child's copy intact.
  This pattern is required anywhere a forked server hands off an SSL connection
  to a child.


### `Dispatcher::Registry`

Persistent store of all paired agents. Written by `Dispatcher::Pairing::approve_request`
at pairing time. Read by `bin/dispatcher list-agents` and by `Dispatcher::API`
for the `/discovery` endpoint.

One JSON file per agent in `/var/lib/dispatcher/agents/{hostname}.json`.
Re-pairing the same hostname overwrites its registry entry. Files are written
atomically via temp file and rename.

Record format:

```json
{
  "hostname": "sjm-explore",
  "ip":       "192.168.125.125",
  "paired":   "2026-03-05T14:30:00Z",
  "expiry":   "Jun  7 16:28:00 2028 GMT",
  "reqid":    "1a15334d"
}
```

Functions:

`register_agent(%opts)`
: Writes or overwrites the registry entry for `hostname`. Required: `hostname`,
  `ip`, `paired`, `expiry`, `reqid`. Optional: `registry_dir`.

`get_agent(%opts)`
: Returns the hashref for a single agent, or `undef` if not found.
  Required: `hostname`. Optional: `registry_dir`.

`list_agents(%opts)`
: Returns an arrayref of all agent hashrefs, sorted by hostname.

`list_hostnames(%opts)`
: Returns an arrayref of hostname strings only. Convenience wrapper for
  passing directly to Engine functions.


### `Dispatcher::Engine`

Parallel dispatch, ping, and capabilities query. Uses fork-per-host with pipes
to collect results. No threads.

Pattern: for each host, fork a child that performs the operation and writes a
JSON result to a pipe, then exits. The parent loops `waitpid -1, 0` collecting
children and reading their pipes as they finish.

Functions:

`dispatch_all(%opts)`
: Required: `hosts` (arrayref), `script`, `config`. Optional: `args`, `reqid`, `port`.
  Returns arrayref of `{ host, script, exit, stdout, stderr, reqid, rtt }`.

`ping_all(%opts)`
: Required: `hosts`, `config`. Optional: `reqid`, `port`.
  Returns arrayref of `{ host, status, version, expiry, rtt, reqid }`.

`capabilities_all(%opts)`
: Required: `hosts`, `config`. Optional: `port`.
  Queries each host's `/capabilities` endpoint. Returns arrayref of
  `{ host, status, version, scripts => [{name, path, executable}, ...], rtt }`.

`parse_host($host_str, $default_port)`
: Parses `"hostname"` or `"hostname:port"`. Returns `($host, $port)`.

`gen_reqid()`
: Returns an 8-hex-digit random ID.


### `Dispatcher::Auth`

Auth hook runner. Called before every `run` and `ping` operation from both
the CLI and the API. If no hook is configured, all requests pass unconditionally.

The hook is an external executable called with request context as environment
variables and a JSON object on stdin. Its exit code determines the outcome.

Exit codes:

```
0   authorised
1   denied - generic
2   denied - bad credentials
3   denied - insufficient privilege
```

Environment variables passed to hook:

```
DISPATCHER_ACTION     run | ping
DISPATCHER_SCRIPT     script name (empty for ping)
DISPATCHER_HOSTS      comma-separated host list
DISPATCHER_ARGS       space-separated script args
DISPATCHER_USERNAME   username from request (may be empty)
DISPATCHER_TOKEN      token from request (may be empty)
DISPATCHER_SOURCE_IP  originating IP address
DISPATCHER_TIMESTAMP  ISO8601 UTC timestamp
```

stdin: full request context as a JSON object (same fields, hosts and args as arrays).

The hook must not produce output. Use syslog for audit logging in the hook.

SIGCHLD note
: `_run_hook` sets `local $SIG{CHLD} = 'DEFAULT'` before forking the hook
  process. This is required when running inside a forked server child (such as
  an API request handler) that has inherited a SIGCHLD reaper from the parent.
  Without it, the parent's reaper can collect the hook grandchild before
  `waitpid` in `_run_hook` can, causing `waitpid` to return -1 and `$?` to be
  -1, which decodes as exit code 255 via `($? >> 8) & 0xff`.

Functions:

`check(%opts)`
: Required: `action`, `config`. Optional: `script`, `hosts`, `args`, `username`,
  `token`, `source_ip`. Returns `{ ok => 1 }` or `{ ok => 0, reason => $str, code => $n }`.


### `Dispatcher::Lock`

flock-based concurrency control. Prevents two concurrent requests from running
the same script on the same host simultaneously. Lock files live in
`/var/lib/dispatcher/locks/`.

The pattern is check-then-acquire in two separate calls:

- `check_available` is called in the parent process (or API handler) before
  forking. It tests all locks non-blocking and returns the conflict list immediately.
- `acquire` is called in the child process that will actually execute the script.
  It re-tests and acquires atomically within the child.

There is a small TOCTOU window between `check_available` and `acquire`. If
another request acquires the lock in that window, `acquire` detects it and
returns a conflict. The caller treats this as a lock error.

Locks are held for the duration of script execution. Releasing the filehandle
(by going out of scope or calling `release`) releases the flock automatically.

Test note
: Lock tests use an exec'd subprocess (`t/lock-holder.pl`) rather than a
  forked child. flock locks are per open-file-description; a forked child
  shares the parent's file table, so the parent's `check_available` sees its
  own child's lock as "already held by this process" and reports no conflict.
  An exec'd process has an independent file table and behaves as a true peer.

Functions:

`check_available(%opts)`
: Required: `hosts`, `script`. Optional: `lock_dir`.
  Returns `{ ok => 1 }` or `{ ok => 0, conflicts => \@pairs }`.

`acquire(%opts)`
: Required: `hosts`, `script`. Optional: `lock_dir`.
  Returns `{ ok => 1, handles => \@fh_list }` or `{ ok => 0, conflicts => \@pairs }`.
  On partial conflict, releases any locks already acquired before returning.

`release(%opts)`
: Required: `handles`. Optional: `hosts`, `script` (for logging).
  Closes all filehandles, releasing all flocks.


### `Dispatcher::API`

HTTP API server. Listens on `api_port` (default 7445). TLS is enabled if
`api_cert` and `api_key` are present in config; plain HTTP otherwise.

Fork-per-request model: the parent accepts connections and forks a child per
request. The child handles the request and exits. The parent reaps children
with a SIGCHLD handler calling `waitpid(-1, WNOHANG)`.

`SSL_no_shutdown => 1` is used on both parent and child connection close, for
the same reason as in the pairing server - see the note in `Dispatcher::Pairing`.

Endpoints:

`GET /health`
: No auth. Returns `{ ok: true, version: "0.1" }`. Use for liveness checks.

`POST /ping`
: Body: `{ hosts, username?, token? }`. Runs auth hook, then pings all hosts
  in parallel via `Engine::ping_all`. Returns `{ ok: true, results: [...] }`.

`POST /run`
: Body: `{ hosts, script, args?, username?, token? }`. Runs auth hook, checks
  locks via `Lock::check_available`, dispatches via `Engine::dispatch_all`.
  Returns `{ ok: true, results: [...] }` or on lock conflict:
  `{ ok: false, error: "locked", code: 4, conflicts: [...] }`.

`GET /discovery` or `POST /discovery`
: Optional body: `{ hosts?, username?, token? }`. If hosts omitted, uses
  `Registry::list_hostnames()` to query all registered agents. Auth uses ping
  privilege level. Returns `{ ok: true, hosts: { hostname: { scripts, version, rtt, ... } } }`.

HTTP status codes:

```
200   Success
400   Bad request (missing body, invalid JSON, missing required fields)
403   Auth denied
404   Unknown route
409   Lock conflict
500   Server error
```

Functions:

`run(%opts)`
: Required: `config`. Starts the server and blocks until SIGTERM or SIGINT.


### `Dispatcher::Agent::Config`

Config and allowlist loading for the agent. Both functions die on unrecoverable
errors (missing file, required key absent) and warn on recoverable issues
(malformed allowlist line, non-absolute path).

Functions:

`load_config($path)`
: Parses `agent.conf`. Returns hashref. Required keys: `port`, `cert`, `key`, `ca`.

`load_allowlist($path)`
: Parses `scripts.conf`. Returns hashref of `{ name => /absolute/path }`.

`validate_script($name, $allowlist)`
: Returns the script path if `$name` matches `/^[\w-]+$/` and exists in the
  allowlist, `undef` otherwise. Security gate called on every `run` request.

Config format (`agent.conf`):

```ini
port = 7443
cert = /etc/dispatcher-agent/agent.crt
key  = /etc/dispatcher-agent/agent.key
ca   = /etc/dispatcher-agent/ca.crt
```

Allowlist format (`scripts.conf`):

```ini
# name = /absolute/path/to/script
check-disk    = /opt/dispatcher-scripts/check-disk.sh
backup-mysql  = /opt/dispatcher-scripts/backup-mysql.sh
```


### `Dispatcher::Agent::Runner`

Script execution. Forks a child, redirects stdout and stderr to pipes, calls
`exec { $path } $path, @args` (no shell). The parent reads both pipes to
completion then waits for the child.

Using `exec { $path } $path, @args` (the two-argument form with a block) means
the PATH is not searched, no shell is invoked, arguments are passed directly to
`execve()`, and shell metacharacters in arguments have no effect.

Functions:

`run_script($script_path, $args_arrayref)`
: Executes the script, returns `{ stdout => '', stderr => '', exit => N }`.
  Exit code 126 if the process was killed by a signal. Exit code -1 with an
  error in `stderr` if `fork` or `pipe` failed.


### `Dispatcher::Agent::Pairing`

Agent-side pairing. Generates key and CSR, connects to the dispatcher pairing
port, submits the CSR and waits (up to 11 minutes) for the signed cert.

The 11-minute timeout on the socket is intentionally longer than the
dispatcher's 10-minute poll window, so the agent gets a proper denial response
rather than a socket timeout.

Functions:

`generate_key_and_csr(%opts)`
: Generates a 4096-bit RSA key and a CSR. Returns `{ key_pem, csr_pem }`.
  Options: `hostname` (required), `bits` (default 4096).

`request_pairing(%opts)`
: Connects to the dispatcher's pairing port, sends `{ hostname, csr }`, waits
  for response. Returns `{ ok => 1, cert_pem, ca_pem }` or `{ ok => 0, error }`.
  Options: `dispatcher` (required), `csr_pem`, `hostname`, `port` (default 7444).

`store_certs(%opts)`
: Writes `agent.crt` (0640), `agent.key` (0640), `ca.crt` (0644) to `cert_dir`.
  Uses atomic rename via temp file.

`pairing_status(%opts)`
: Checks cert files, reads expiry via `openssl x509 -noout -enddate`.
  Returns `{ paired => 1, expiry }` or `{ paired => 0, reason }`.

HTTP response reading
: `request_pairing` reads headers line-by-line until the blank separator,
  extracts `Content-Length`, then calls `read()` for exactly that many bytes.
  Reading to EOF would block - the dispatcher child holds the connection open
  while polling and does not close it when sending the response.


## `bin/dispatcher`

The dispatcher CLI. Argument parsing and output formatting only; all business
logic is in the library modules.

Modes:

`setup-ca`
: Calls `Dispatcher::CA::generate_ca()`. One-time operation.

`pairing-mode`
: Calls `Dispatcher::Pairing::run_pairing_mode()`. Blocks until interrupted.

`list-requests`
: Calls `Dispatcher::Pairing::list_requests()` and prints a table.

`approve <reqid>` / `deny <reqid>`
: Calls `Dispatcher::Pairing::approve_request()` or `deny_request()`.
  `approve` also triggers registry write via `Dispatcher::Registry`.

`list-agents`
: Calls `Dispatcher::Registry::list_agents()` and prints a table of all
  paired agents with hostname, IP, paired timestamp, and cert expiry.

`ping <host>...`
: Calls `Engine::ping_all()`. Auth hook checked first.

`run <host>... <script> [-- <args>]`
: Auth hook checked, then `Lock::check_available`, then `Engine::dispatch_all`.

Auth options
: `--token` reads from the flag or `$DISPATCHER_TOKEN` env var (never appears
  in `ps` output when set via env). `--username` defaults to `$ENV{USER}`.
  Source IP is hardcoded to `127.0.0.1` for CLI calls.

Parallel execution
: `dispatch_all` and `ping_all` fork one child per host. Each child writes a
  JSON result to a pipe and exits. The parent collects all via `waitpid -1, 0`.

Arg parsing for `run`
: `_parse_run_args()` splits `@ARGV` on `--`. Everything after `--` becomes
  script args; before `--`, the last element is the script name and the rest
  are hosts. `Getopt::Long` is configured with `:config pass_through` so that
  `--` is not consumed by the option parser.


## `bin/dispatcher-agent`

The agent daemon. Listens on port 7443 using `IO::Socket::SSL` directly.

`HTTP::Daemon::SSL` was originally used but removed: version 1.05_01 (the
current Debian trixie package) does not interoperate reliably with modern
`IO::Socket::SSL`. The agent reads raw HTTP/1.0 requests from the SSL socket.

Modes:

`serve` (default)
: Starts the `IO::Socket::SSL` server. Forks one child per connection. The
  child calls `handle_connection()` and exits. The parent closes its copy with
  `SSL_no_shutdown => 1` and reaps children with `waitpid -1, WNOHANG`.
  SIGHUP reloads the allowlist without restart.

`request-pairing`
: Calls `Agent::Pairing::generate_key_and_csr()`, `request_pairing()`,
  `store_certs()`. Prints progress to stdout.

`pairing-status`
: Calls `Agent::Pairing::pairing_status()` and prints the result.

`ping-self`
: Loads config, allowlist, and cert status without starting the server.
  Validates each allowlisted script is executable.

Endpoints handled in `handle_connection`:

`POST /run`
: Validates script name and allowlist, executes via `Agent::Runner::run_script`,
  returns `{ script, exit, stdout, stderr, reqid }`.

`POST /ping`
: Returns `{ status: "ok", host, version, expiry, reqid }`.

`GET /capabilities`
: Returns `{ status: "ok", host, version, scripts: [{name, path, executable}, ...] }`.
  Iterates the loaded allowlist, checks `-x` on each path.
  Used by `Engine::capabilities_all` and the API `/discovery` endpoint.


## `bin/dispatcher-api`

Entry point for the HTTP API server. Loads config, calls `Dispatcher::API::run`.
Installed as a systemd service (`dispatcher-api.service`).

The service runs as `root:dispatcher` with `ProtectSystem=strict` and
`ReadWritePaths=/var/lib/dispatcher`. The `dispatcher` group is created by the
installer and grants CLI access without sudo to users added to it.


## Request/Response Wire Format

All JSON over HTTP/1.0.

Agent endpoints (dispatcher → agent, mTLS on port 7443):

Run request (POST `/run`):

```json
{ "script": "backup-mysql", "args": ["--db", "myapp"], "reqid": "a3f9b2c1" }
```

Run response:

```json
{ "script": "backup-mysql", "exit": 0, "stdout": "...", "stderr": "", "reqid": "a3f9b2c1" }
```

Ping request (POST `/ping`):

```json
{ "reqid": "b7c3d1e4" }
```

Ping response:

```json
{ "status": "ok", "host": "prod-db-01", "version": "0.1", "expiry": "Jun  7 2028 GMT", "reqid": "b7c3d1e4" }
```

Capabilities response (GET `/capabilities`):

```json
{
  "status": "ok", "host": "sjm-explore", "version": "0.1",
  "scripts": [
    { "name": "logger", "path": "/usr/bin/logger", "executable": true }
  ]
}
```

Pairing request (agent → dispatcher, port 7444, POST `/pair`):

```json
{ "hostname": "sjm-explore", "csr": "-----BEGIN CERTIFICATE REQUEST-----\n..." }
```

Pairing response:

```json
{ "status": "approved", "cert": "-----BEGIN CERTIFICATE-----\n...", "ca": "-----BEGIN CERTIFICATE-----\n..." }
```

API endpoints (caller → dispatcher-api, port 7445):

POST `/ping` request:

```json
{ "hosts": ["sjm-explore", "prod-db-01"], "username": "stuart", "token": "..." }
```

POST `/run` request:

```json
{ "hosts": ["sjm-explore"], "script": "logger", "args": ["-t", "test", "hello"], "username": "stuart", "token": "..." }
```

GET `/discovery` response:

```json
{
  "ok": true,
  "hosts": {
    "sjm-explore": {
      "status": "ok", "version": "0.1", "rtt": "68ms",
      "scripts": [{ "name": "logger", "path": "/usr/bin/logger", "executable": true }]
    }
  }
}
```

Lock conflict response (409):

```json
{ "ok": false, "error": "locked", "code": 4, "conflicts": ["sjm-explore:backup-mysql"] }
```


## Syslog Format

All log lines follow `ACTION=value KEY=value KEY=value` with ACTION first and
all remaining keys alphabetical. Values containing spaces are quoted.

Dispatcher examples:

```
dispatcher[1234]: ACTION=dispatch HOSTS=prod-db-01 REQID=a3f9b2c1 SCRIPT=backup-mysql
dispatcher[1234]: ACTION=run EXIT=0 REQID=a3f9b2c1 RTT=87ms SCRIPT=backup-mysql TARGET=prod-db-01:7443
dispatcher[1234]: ACTION=pair-approve AGENT=sjm-explore REQID=fa5e7463
dispatcher[1234]: ACTION=auth AUTHACTION=run IP=127.0.0.1 RESULT=pass USER=stuart
dispatcher[1234]: ACTION=lock-acquire HOST=sjm-explore SCRIPT=backup-mysql
```

Agent examples:

```
dispatcher-agent[5678]: ACTION=start PORT=7443
dispatcher-agent[5678]: ACTION=run EXIT=0 PEER=192.168.125.189 REQID=a3f9b2c1 SCRIPT=backup-mysql
dispatcher-agent[5678]: ACTION=deny PEER=192.168.125.189 REQID=b1c2d3e4 SCRIPT=not-in-allowlist
dispatcher-agent[5678]: ACTION=ping PEER=192.168.125.189 REQID=b7c3d1e4
dispatcher-agent[5678]: ACTION=capabilities PEER=192.168.125.189 SCRIPTS=3
```

API examples:

```
dispatcher-api[9012]: ACTION=api-start PORT=7445 TLS=no
dispatcher-api[9012]: ACTION=api-request LEN=25 METHOD=POST PATH=/ping PEER=127.0.0.1
dispatcher-api[9012]: ACTION=auth AUTHACTION=ping IP=127.0.0.1 RESULT=pass USER=(none)
```

The REQID field appears in both dispatcher and agent log lines for the same
operation, enabling cross-host log correlation.


## Security Model

allowlist validation
: `validate_script()` checks the name against `/^[\w-]+$/` before allowlist
  lookup. This prevents path traversal (no `/` or `..` can pass). The allowlist
  maps names to absolute paths; relative paths are rejected at load time.

no shell execution
: `exec { $path } $path, @args` passes the argument list directly to the OS.
  Shell metacharacters in arguments have no effect.

mTLS on port 7443
: `SSL_verify_mode => SSL_VERIFY_PEER` on both sides means both dispatcher and
  agent must present a cert signed by the CA. An agent with no cert, or a cert
  signed by a different CA, cannot connect.

pairing port security
: Port 7444 uses `SSL_VERIFY_NONE` for the client - the agent has no cert yet.
  This is a bootstrap problem: the first connection is unauthenticated.
  Mitigation: the operator reviews the hostname and IP in `list-requests` before
  approving. The pairing port is only open when `pairing-mode` is running.

API security
: Port 7445 has no mTLS. Auth is delegated entirely to the auth hook. The
  default hook authorises everything; operators must replace it with real
  token or credential checking for any internet-facing deployment.

auth hook token
: The token is passed to the hook via `DISPATCHER_TOKEN` env var and as a JSON
  field on stdin. It is never logged by the dispatcher. The CLI reads it from
  `--token` or `$DISPATCHER_TOKEN` env var; using the env var prevents the
  token appearing in `ps` output.

file permissions
: CA key: 0600 root. Dispatcher cert/key: 0600 root. Agent cert/key: 0640
  root:dispatcher-agent. Scripts: 0750 root:dispatcher-agent. The
  `dispatcher-agent` system user has no login shell and no home directory.
  Runtime dirs: 0770 root:dispatcher.

systemd hardening
: The agent unit sets `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
  `PrivateTmp`, `PrivateDevices`. The API unit sets the same and restricts
  writes to `/var/lib/dispatcher`.


## Known Issues and Bugs Fixed

SIGCHLD race in auth hook (fixed)
: The API server sets a SIGCHLD reaper that calls `waitpid(-1, WNOHANG)` in a
  loop to clean up request-handling children. Request handlers are themselves
  forked children. When `_run_hook` in `Auth.pm` forks the hook executable, the
  inherited reaper could collect the hook grandchild before `_run_hook`'s own
  `waitpid` could. `waitpid` on an already-reaped PID returns -1, `$?` stays
  -1, and `(-1 >> 8) & 0xff = 255`, appearing as a hook failure.
  Fixed by setting `local $SIG{CHLD} = 'DEFAULT'` before the fork in `_run_hook`.

`HTTP::Daemon::SSL` interoperability (fixed)
: Version 1.05_01 does not reliably interoperate with modern `IO::Socket::SSL`
  on Debian trixie. Replaced with direct `IO::Socket::SSL` and raw HTTP/1.0
  parsing in the agent.

`Getopt::Long` consuming `--` separator (fixed)
: `GetOptions` strips `--` from `@ARGV` by default, causing all args after `--`
  to be treated as hosts. Fixed with `:config pass_through`.


## Todo

unpairing
: Remove an agent from the registry and revoke trust. Requires deleting the
  registry entry, and ideally invalidating the agent cert (CRL or re-issuing
  all certs with a new CA serial range). Currently re-pairing overwrites the
  registry entry but the old cert remains valid until expiry.

multiple dispatcher support
: Allow an agent to trust more than one dispatcher CA. The PEM format supports
  multiple certs in one file by concatenation. `IO::Socket::SSL` accepts a
  multi-cert CA file. The change required is in `Agent::Pairing::store_certs`:
  merge the new CA into the existing `ca.crt` bundle rather than overwriting it.
  The allowlist does not distinguish by dispatcher - any trusted dispatcher can
  run any allowed script.

installer: `apt-get` → `apt`
: Replace all `apt-get install` suggestions in installer output with `apt install`.

installer: `sudo` prefix on suggested commands
: Prefix suggested post-install commands with `sudo` since the operator is not
  necessarily root at that point.

installer: `setup-ca` helper
: Add a helper function to the installer (or a separate `dispatcher setup-ca`
  subcommand improvement) that generates the dispatcher cert in one step, replacing
  the current four manual `openssl` commands in the next-steps output.

cert renewal
: Agent certs are signed for 825 days with no automated renewal. A `renew`
  mode on both agent and dispatcher would re-run the pairing flow and overwrite
  certs without requiring operator intervention beyond approving the new CSR.

reqid entropy
: `gen_reqid()` uses `rand()` with Perl's default seeding. For higher-volume
  environments, combining `Time::HiRes`, PID, and a counter would give better
  uniqueness guarantees.

output module
: `_format_run_results()` and `_format_ping_results()` in `bin/dispatcher` are
  not independently testable without invoking the CLI. Extracting to a
  `Dispatcher::Output` module would allow unit tests.


## Adding a New Script to an Agent

On the agent host:

```bash
# Place script in the managed directory
sudo cp my-script.sh /opt/dispatcher-scripts/
sudo chmod 750 /opt/dispatcher-scripts/my-script.sh
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/my-script.sh

# Add to allowlist
echo "my-script = /opt/dispatcher-scripts/my-script.sh" \
    | sudo tee -a /etc/dispatcher-agent/scripts.conf

# Reload allowlist without restart
sudo systemctl kill --signal=HUP dispatcher-agent

# Verify discovery sees the new script
curl -s http://localhost:7445/discovery | python3 -m json.tool
```

Scripts receive positional arguments exactly as passed. They should exit 0 on
success, non-zero on failure. stdout and stderr are both captured and returned.


## Extending the System

Adding a new agent endpoint
: Add a route check in `handle_connection()` in `bin/dispatcher-agent`.
  Add the handler following the `handle_run`/`handle_ping` pattern: decode
  body, do work, call `_send_json()`.

Adding a new API endpoint
: Add a route in `_handle_connection()` in `Dispatcher::API`. Add a
  `_handle_*` function following the existing pattern: parse body, auth check,
  do work, call `_send_json()`.

Adding a new dispatcher CLI mode
: Add an entry to the `%dispatch` hash in `main()` in `bin/dispatcher`.
  Keep network logic in Engine; keep output formatting in the mode function.

Adding a new library module
: Place in `lib/Dispatcher/` or `lib/Dispatcher/Agent/`. Use `use strict;
  use warnings;`. All callers use `Module::function()` syntax - nothing exported
  by default. Private helpers prefixed `_`. Add a corresponding test in `t/`.


## Dependencies

Agent role

```
libio-socket-ssl-perl    IO::Socket::SSL   TLS server and client sockets
libjson-perl             JSON              encode_json / decode_json
openssl                  (binary)          Key, CSR, and cert operations
```

Dispatcher role

```
libwww-perl              LWP::UserAgent    HTTP client for run/ping/capabilities
libio-socket-ssl-perl    IO::Socket::SSL   TLS for pairing server and API
libjson-perl             JSON              encode_json / decode_json
openssl                  (binary)          CA and cert operations
```

Both roles also use core Perl modules (`Sys::Syslog`, `File::Temp`, `File::Path`,
`File::Basename`, `Getopt::Long`, `Sys::Hostname`, `POSIX`, `Time::HiRes`,
`Fcntl`, `IPC::Open2`, `Carp`) which are in `perl-base` or `perl` and present
on any Debian system.
