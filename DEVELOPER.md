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
  signed and the cert is delivered back over the open connection.

argument support
: Scripts can receive arguments. Arguments are passed as a JSON array and
  forwarded to `exec` as a list, never interpolated into a shell command.

structured logging
: All actions are logged to syslog in a consistent `ACTION=value KEY=value`
  format with a request ID that correlates dispatcher and agent log lines for
  the same operation.

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

lib/Dispatcher/
  Log.pm                  Structured syslog
  CA.pm                   CA and cert signing via openssl subprocess
  Pairing.pm              Dispatcher-side pairing server and approval queue
  Agent/
    Config.pm             Config and allowlist loading and validation
    Pairing.pm            Agent-side: key/CSR generation, pairing request, cert storage
    Runner.pm             Script execution via fork/exec

etc/
  agent.conf.example      Template for /etc/dispatcher-agent/agent.conf
  dispatcher.conf.example Template for /etc/dispatcher/dispatcher.conf
  scripts.conf.example    Template for /etc/dispatcher-agent/scripts.conf
  dispatcher-agent.service Systemd unit

t/
  agent-config.t          Tests for Dispatcher::Agent::Config
  agent-run.t             Tests for Dispatcher::Agent::Runner
  dispatcher-args.t       Tests for dispatcher bin argument parsing
  log.t                   Tests for Dispatcher::Log
  pairing-csr.t           Tests for Dispatcher::Agent::Pairing (key/CSR generation)

install.sh                Installer: role must be specified (--agent or --dispatcher)
README.md                 User-facing install, test, and configuration guide
DEVELOPER.md              This file
```


## Ports

7443
: Operational mTLS port. The agent listens here for `run` and `ping` requests.
  Both sides present certificates signed by the private CA.

7444
: Pairing port. Only open when the dispatcher is in `pairing-mode`. TLS server
  cert only (no client cert required) since the agent has no cert yet. Agents
  connect here to submit a CSR and wait for the signed cert.


## Certificate Layout

Dispatcher host (`/etc/dispatcher/`)

```
ca.key          CA private key (0600, root only, never leaves this host)
ca.crt          CA certificate (distributed to agents during pairing)
ca.serial       Serial counter for issued certs
dispatcher.key  Dispatcher's own private key (0600)
dispatcher.crt  Dispatcher's own cert, signed by CA
```

Agent host (`/etc/dispatcher-agent/`)

```
agent.key       Agent's private key (0640, root:dispatcher-agent)
agent.crt       Agent's cert, signed by dispatcher CA (0640, root:dispatcher-agent)
ca.crt          CA cert from dispatcher (0644)
agent.conf      Port, cert paths
scripts.conf    Allowlist: name = /absolute/path
```


## Module Reference

### `Dispatcher::Log`

Structured syslog. Call `init()` once at startup, then `log_action()` for each event.

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

If `init()` has not been called, `log_action()` falls back to stderr. This
allows library functions to log without requiring a syslog context (e.g. in tests).

Functions:

`init($program_name)`
: Opens syslog with `LOG_DAEMON` facility. Must be called before `log_action`.

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
  writes the signed cert and CA cert to `{reqid}.approved`. The waiting child
  picks this up within 2 seconds and delivers it to the agent.
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


### `Dispatcher::Agent::Config`

Config and allowlist loading for the agent. Both functions die on unrecoverable
errors (missing file, required key absent) and warn on recoverable issues
(malformed allowlist line, non-absolute path).

Functions:

`load_config($path)`
: Parses `agent.conf`. Returns hashref. Required keys: `port`, `cert`, `key`, `ca`.
  Format: `key = value`, `#` comments, blank lines ignored.

`load_allowlist($path)`
: Parses `scripts.conf`. Returns hashref of `{ name => /absolute/path }`.
  Non-absolute paths are skipped with a warning. Malformed lines are skipped
  with a warning.

`validate_script($name, $allowlist)`
: Returns the script path if `$name` matches `/^[\w-]+$/` and exists in the
  allowlist, `undef` otherwise. This is the security gate - called on every
  `run` request before execution.

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

Using `exec { $path } $path, @args` (the two-argument form with a block) means:

- the PATH is not searched
- no shell is invoked
- arguments are passed as a list directly to `execve()`
- shell metacharacters in arguments have no effect

Functions:

`run_script($script_path, $args_arrayref)`
: Executes the script, returns `{ stdout => '', stderr => '', exit => N }`.
  Exit code 126 if the process was killed by a signal. Exit code -1 with an
  error in `stderr` if `fork` or `pipe` failed. The caller is responsible for
  allowlist validation before calling this function.


### `Dispatcher::Agent::Pairing`

Agent-side pairing. Generates key and CSR, connects to the dispatcher pairing
port, submits the CSR and waits (up to 11 minutes) for the signed cert.

The 11-minute timeout on the socket is intentionally longer than the
dispatcher's 10-minute poll window, so the agent gets a proper denial response
from the dispatcher rather than a socket timeout.

Functions:

`generate_key_and_csr(%opts)`
: Generates a 4096-bit RSA key and a CSR in a temporary directory (cleaned up
  on return). Returns `{ key_pem => '...', csr_pem => '...' }`.
  Options: `hostname` (required), `bits` (default 4096).

`request_pairing(%opts)`
: Connects to the dispatcher's pairing port (TLS, no cert verification since
  the CA does not exist yet), sends a JSON payload with `hostname` and `csr`,
  then reads the HTTP response by parsing headers line-by-line and reading
  exactly `Content-Length` bytes for the body. Returns
  `{ ok => 1, cert_pem => '...', ca_pem => '...' }` or `{ ok => 0, error => '...' }`.
  Options: `dispatcher` (required), `csr_pem` (required), `hostname` (required),
  `port` (default 7444), `ca_cert` (optional, enables dispatcher cert verification).

`store_certs(%opts)`
: Writes `agent.crt` (0640), `agent.key` (0640), `ca.crt` (0644) to `cert_dir`.
  After writing, sets group ownership to `group` (default `dispatcher-agent`)
  so the service user can read them. Uses atomic rename via temp file.
  Options: `cert_pem`, `ca_pem`, `key_pem` (all required), `cert_dir`, `group`.

`pairing_status(%opts)`
: Checks for the three cert files. If all present, reads the expiry date from
  `agent.crt` using `openssl x509 -noout -enddate`. Returns
  `{ paired => 1, expiry => '...' }` or `{ paired => 0, reason => '...' }`.

HTTP response reading
: `request_pairing` reads the response by reading the status line, then looping
  line-by-line until the blank line separating headers from body, extracting
  `Content-Length`, then calling `read()` for exactly that many bytes. This is
  necessary because reading to EOF would block - the dispatcher child holds the
  connection open while polling for approval and does not close it when sending
  the response.


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

`ping <host>...`
: Calls `ping_all()` which forks one child per host. Each child calls
  `ping_one()` which uses `LWP::UserAgent` (mTLS configured) to POST to
  `/ping`. Results are collected via pipes, formatted as a table or JSON.

`run <host>... <script> [-- <args>]`
: Calls `dispatch_all()` which forks one child per host. Each child calls
  `dispatch_one()` which POSTs to `/run` with `{ script, args, reqid }`.
  Results are collected via pipes, formatted per-host or as JSON.

Parallel execution
: Both `dispatch_all` and `ping_all` use the same pattern: fork one child per
  host, each child writes a JSON result to its end of a pipe and exits. The
  parent collects all children via `waitpid -1, 0` in a loop, reading each
  child's pipe as it finishes. This gives true parallelism with no threads.

Arg parsing for `run`
: `parse_run_args()` splits `@ARGV` on `--`. Everything after `--` becomes
  script args; before `--`, the last element is the script name and the rest
  are hosts. Host strings of the form `host:port` are parsed by `parse_host()`.

Request ID
: `gen_reqid()` generates an 8-hex-digit random ID. This is included in the
  JSON request payload and echoed back by the agent in its response. Both sides
  log the REQID, allowing dispatcher and agent syslog lines for the same
  operation to be correlated.

mTLS client (`build_ua`)
: `LWP::UserAgent` is configured with `ssl_opts` pointing to the dispatcher's
  cert, key, and CA. `verify_hostname => 0` because agents are identified by
  CA-signed cert, not hostname - the hostname in the cert is the agent's
  hostname at pairing time and may not match DNS.


## `bin/dispatcher-agent`

The agent daemon. Listens on port 7443 using `IO::Socket::SSL` directly.

`HTTP::Daemon::SSL` was originally used but removed: version 1.05_01 (the
current Debian trixie package) does not interoperate reliably with modern
`IO::Socket::SSL`. The agent now reads raw HTTP/1.0 requests from the SSL
socket directly.

Modes:

`serve` (default)
: Starts the `IO::Socket::SSL` server. Forks one child per connection. The
  child calls `handle_connection()` and exits. The parent closes its copy with
  `SSL_no_shutdown => 1` and reaps children with `waitpid -1, WNOHANG`.
  SIGHUP reloads the allowlist without restart.

`request-pairing`
: Calls `Dispatcher::Agent::Pairing::generate_key_and_csr()` then
  `request_pairing()` then `store_certs()`. Prints progress to stdout.

`pairing-status`
: Calls `Dispatcher::Agent::Pairing::pairing_status()` and prints the result.

`ping-self`
: Loads config, allowlist, and cert status without starting the server.
  Validates each allowlisted script is executable.

HTTP parsing in `handle_connection`
: Reads the request line, then headers line-by-line until blank line,
  extracting `Content-Length`. Reads the body with `read()`. Dispatches
  to `handle_run` or `handle_ping`. Sends responses via `_send_raw()` which
  writes a raw `HTTP/1.0` response with correct `Content-Length`.

`handle_run`
: Decodes JSON body, validates args is an arrayref, calls
  `Dispatcher::Agent::Config::validate_script()`. If denied, logs and returns
  `{ exit: -1, error: 'script not permitted' }`. If permitted, calls
  `Dispatcher::Agent::Runner::run_script()`, logs result, returns
  `{ script, exit, stdout, stderr, reqid }`.

`handle_ping`
: Calls `Dispatcher::Agent::Pairing::pairing_status()` for the cert expiry,
  returns `{ status: 'ok', host, version, expiry, reqid }`.


## Request/Response Wire Format

All JSON over HTTP/1.0. The agent always returns HTTP 200; errors are
indicated by the `exit` or `status` field in the JSON body.

Run request (dispatcher → agent POST `/run`):

```json
{ "script": "backup-mysql", "args": ["--db", "myapp"], "reqid": "a3f9b2c1" }
```

Run response (agent → dispatcher):

```json
{ "script": "backup-mysql", "exit": 0, "stdout": "...", "stderr": "", "reqid": "a3f9b2c1" }
```

Ping request (dispatcher → agent POST `/ping`):

```json
{ "reqid": "b7c3d1e4" }
```

Ping response (agent → dispatcher):

```json
{ "status": "ok", "host": "prod-db-01", "version": "0.1", "expiry": "Jun  7 13:59:08 2028 GMT", "reqid": "b7c3d1e4" }
```

Pairing request (agent → dispatcher POST `/pair`):

```json
{ "hostname": "sjm-explore", "csr": "-----BEGIN CERTIFICATE REQUEST-----\n..." }
```

Pairing response (dispatcher → agent):

```json
{ "status": "approved", "cert": "-----BEGIN CERTIFICATE-----\n...", "ca": "-----BEGIN CERTIFICATE-----\n..." }
```

or on denial:

```json
{ "status": "denied", "reason": "rejected by operator" }
```


## Syslog Format

All log lines follow `ACTION=value KEY=value KEY=value` with ACTION first and
all remaining keys alphabetical. Values containing spaces are quoted.

Dispatcher examples:

```
dispatcher[1234]: ACTION=dispatch HOSTS=prod-db-01 REQID=a3f9b2c1 SCRIPT=backup-mysql
dispatcher[1234]: ACTION=run EXIT=0 REQID=a3f9b2c1 RTT=87ms SCRIPT=backup-mysql TARGET=prod-db-01:7443
dispatcher[1234]: ACTION=pairing-mode-start PORT=7444
dispatcher[1234]: ACTION=pair-approve AGENT=sjm-explore REQID=fa5e7463
```

Agent examples:

```
dispatcher-agent[5678]: ACTION=start PORT=7443
dispatcher-agent[5678]: ACTION=run EXIT=0 PEER=192.168.125.189 REQID=a3f9b2c1 SCRIPT=backup-mysql
dispatcher-agent[5678]: ACTION=deny PEER=192.168.125.189 REQID=b1c2d3e4 SCRIPT=not-in-allowlist
dispatcher-agent[5678]: ACTION=ping PEER=192.168.125.189 REQID=b7c3d1e4
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
  The dispatcher presents its own cert, but the agent does not verify it (no CA
  yet). This is a bootstrap problem: the first connection is unauthenticated.
  Mitigation: the operator reviews the hostname and IP in `list-requests` before
  approving. The pairing port is only open when `pairing-mode` is running; it
  is not a persistent listener.

file permissions
: CA key: 0600 root. Dispatcher cert/key: 0600 root. Agent cert/key: 0640
  root:dispatcher-agent. Scripts: 0750 root:dispatcher-agent. The
  `dispatcher-agent` system user has no login shell and no home directory.

systemd hardening
: The unit sets `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`,
  `PrivateTmp`, `PrivateDevices`. The agent cannot escalate privileges or
  write outside its designated directories.


## Known Limitations and Future Work

cert expiry
: Agent certs are signed for 825 days. There is no automated renewal.
  The `ping` output shows expiry; a separate monitoring check on cert expiry
  is advisable. Re-pairing uses the same `pairing-mode` / `request-pairing`
  flow and overwrites the existing certs.

pairing TOFU
: The first pairing connection is unauthenticated. A future improvement would
  be to display a fingerprint of the dispatcher's cert during `pairing-mode`
  and require the operator to confirm it on the agent side before submitting
  the CSR.

single CA
: All agents share one CA. Revoking a single agent requires either re-issuing
  all certs with a new CA, or implementing CRL/OCSP checking. For the current
  use case (small number of trusted hosts) this is acceptable.

reqid entropy
: `gen_reqid()` uses `rand()` seeded by Perl's default seeding. For high-volume
  environments, `Time::HiRes` combined with PID and a counter would give better
  uniqueness guarantees.

output module
: `format_results()` and `format_ping_results()` in `bin/dispatcher` are not
  independently testable. Extracting them to `Dispatcher::Output` would allow
  unit tests without invoking the CLI.

`HTTP::Daemon::SSL`
: Removed from the agent. The package `libhttp-daemon-ssl-perl` is no longer
  needed and can be removed from agent hosts. `libhttp-daemon-perl` is still
  present as a transitive dependency but is not used directly.


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
```

Scripts receive positional arguments from the dispatcher exactly as passed.
They should exit 0 on success, non-zero on failure. stdout and stderr are
both captured and returned to the dispatcher.


## Extending the System

Adding a new agent endpoint
: Add a new route check in `handle_connection()` in `bin/dispatcher-agent`.
  Add the corresponding handler function following the `handle_run`/`handle_ping`
  pattern: decode JSON body, do work, call `_send_json()`.

Adding a new dispatcher mode
: Add an entry to the `%dispatch` hash in `main()` in `bin/dispatcher` pointing
  to a new mode function. Add argument parsing and output formatting in the
  mode function; keep network logic in a separate `*_one` / `*_all` function
  pair to keep output formatting and error handling consistent.

Adding a new library module
: Place in `lib/Dispatcher/` or `lib/Dispatcher/Agent/`. Follow the existing
  pattern: `use strict; use warnings;`, named exports, no symbols exported by
  default (all callers use `Module::function()` syntax), private helpers
  prefixed `_`. Add a corresponding test file in `t/`.


## Dependencies

Agent role

```
libio-socket-ssl-perl    IO::Socket::SSL   TLS server and client sockets
libjson-perl             JSON              encode_json / decode_json
openssl                  (binary)          Key, CSR, and cert operations
```

Dispatcher role

```
libwww-perl              LWP::UserAgent    HTTP client for run/ping requests
libio-socket-ssl-perl    IO::Socket::SSL   TLS for pairing server
libjson-perl             JSON              encode_json / decode_json
openssl                  (binary)          CA and cert operations
```

Both roles also use core Perl modules (`Sys::Syslog`, `File::Temp`, `File::Path`,
`Getopt::Long`, `Sys::Hostname`, `POSIX`, `Time::HiRes`, `Carp`) which are in
`perl-base` or `perl` and present on any Debian system.
