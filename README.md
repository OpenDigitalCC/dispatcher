---
title: Dispatcher and agent - user manual
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
: CLI tool that connects to one or more agents, sends signed requests, collects results.
  Runs a pairing server during the initial certificate exchange.

dispatcher-agent (remote hosts)
: HTTP server listening on port 7443 (mTLS). Accepts `run` and `ping` requests.
  Executes only scripts named in the allowlist. Reloads the allowlist on SIGHUP.

pairing
: One-time certificate exchange on port 7444. The agent generates a key and CSR,
  connects to the dispatcher, and waits. The operator approves on the dispatcher
  host, which signs the CSR with the private CA and delivers the cert.
  After pairing, all communication uses mTLS on port 7443.

private CA
: Created on the dispatcher host with `dispatcher setup-ca`. All agent certs are
  signed by this CA. The CA key never leaves the dispatcher host.


## Dependencies

All Debian trixie system packages - no CPAN required.

Agent (`--agent`)
: `libio-socket-ssl-perl`, `libjson-perl`

Dispatcher (`--dispatcher`)
: `libwww-perl`, `libio-socket-ssl-perl`, `libjson-perl`

Both roles also require `openssl` (usually already present).

The installer checks dependencies and lists any missing packages before aborting.
It does not install packages automatically.


## Source Layout

```
bin/
  dispatcher          CLI for the control host
  dispatcher-agent    Server daemon for remote hosts

lib/Dispatcher/
  CA.pm               CA and CSR signing via openssl
  Log.pm              Structured syslog: ACTION=value format
  Pairing.pm          Dispatcher-side pairing server and approval queue
  Agent/
    Config.pm         Config and allowlist loading
    Pairing.pm        Agent-side pairing: key/CSR generation, cert storage
    Runner.pm         Script execution via fork/exec (no shell)

etc/
  agent.conf.example
  dispatcher.conf.example
  scripts.conf.example
  dispatcher-agent.service

t/
  agent-config.t
  agent-run.t
  dispatcher-args.t
  log.t
  pairing-csr.t

install.sh
```


## Installation

The installer must be run as root. A role must be specified - there is no default.

```bash
sudo ./install.sh --agent        # on each remote host
sudo ./install.sh --dispatcher   # on the control host
sudo ./install.sh --uninstall    # remove files (preserves config and certs)
```

If any Perl dependencies are missing the installer prints the `apt-get install`
command and exits without making any changes.

Installed paths:

- `/usr/local/bin/dispatcher` or `/usr/local/bin/dispatcher-agent`
- `/usr/local/lib/dispatcher/` - Perl library modules
- `/etc/dispatcher/` - dispatcher config and CA material
- `/etc/dispatcher-agent/` - agent config and certs
- `/opt/dispatcher-scripts/` - managed scripts on agent hosts
- `/var/lib/dispatcher/pairing/` - pending pairing requests
- `/etc/systemd/system/dispatcher-agent.service`


## Running the Tests

Run tests from the project root before installing. All tests use relative lib paths.

```bash
perl -Ilib t/agent-config.t
perl -Ilib t/agent-run.t
perl -Ilib t/dispatcher-args.t
perl -Ilib t/log.t
perl -Ilib t/pairing-csr.t
```

Or run all at once:

```bash
prove -Ilib t/
```


## Initial Setup

### 1. Dispatcher host

Initialise the CA (once only):

```bash
dispatcher setup-ca
```

Generate the dispatcher's own certificate:

```bash
cd /etc/dispatcher
openssl genrsa -out dispatcher.key 4096
openssl req -new -key dispatcher.key -out dispatcher.csr -subj '/CN=dispatcher'
openssl x509 -req -in dispatcher.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out dispatcher.crt -days 825
chmod 600 dispatcher.key
rm dispatcher.csr
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

On the dispatcher host, start pairing mode:

```bash
sudo dispatcher pairing-mode
```

On the agent host, request pairing:

```bash
sudo dispatcher-agent request-pairing --dispatcher <dispatcher-hostname>
```

The agent prints `Connecting to dispatcher...` and waits. On the dispatcher host
in a second terminal, list and approve the request:

```bash
dispatcher list-requests
dispatcher approve <reqid>
```

The agent prints `Pairing complete. Certificates stored.` and exits.

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
HOST                            STATUS    RTT       CERT EXPIRY   VERSION
---------------------------------------------------------------------------
agent-hostname                  ok        45ms      Jun  7 ...    0.1
```


## Adding a Test Script

The following script is useful as an initial end-to-end test. It exercises argument
passing, stdout, stderr, and exit code reporting without requiring any real
infrastructure.

Create `/opt/dispatcher-scripts/hello` on the agent host:

```bash
sudo tee /opt/dispatcher-scripts/hello << 'EOF'
#!/bin/bash
# dispatcher test script
# Usage: hello [--name <name>]
NAME="world"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done
echo "Hello, ${NAME}!"
echo "Host: $(hostname)" >&2
exit 0
EOF
sudo chmod 750 /opt/dispatcher-scripts/hello
sudo chown root:dispatcher-agent /opt/dispatcher-scripts/hello
```

Add it to the allowlist on the agent host (`/etc/dispatcher-agent/scripts.conf`):

```ini
hello = /opt/dispatcher-scripts/hello
```

Reload the allowlist without restarting the agent:

```bash
sudo systemctl kill --signal=HUP dispatcher-agent
```

Run it from the dispatcher host:

```bash
# Basic call
dispatcher run <agent-hostname> hello

# With arguments
dispatcher run <agent-hostname> hello -- --name Stuart
```

Expected output:

```
=== <agent-hostname> ===
exit: 0
stdout:
  Hello, Stuart!
stderr:
  Host: <agent-hostname>
```

Run against multiple agents at once:

```bash
dispatcher run host-a host-b hello -- --name Stuart
```


## Day-to-day Usage

```bash
# Ping one or more hosts
dispatcher ping host-a
dispatcher ping host-a host-b host-c

# Run a script on one host
dispatcher run host-a backup-mysql

# Run with arguments (everything after -- is passed to the script)
dispatcher run host-a add-dns -- --zone example.com --name mail --type MX --value '10 mail.example.com'

# Run on multiple hosts in parallel
dispatcher run host-a host-b host-c check-disk

# JSON output (for scripting)
dispatcher ping host-a --json
dispatcher run host-a check-disk --json
```


## Security Notes

allowlist enforcement
: Scripts are validated server-side against the allowlist. Requests for unlisted
  scripts return exit code -1 without execution. The script name may only contain
  alphanumerics and hyphens.

no shell
: Scripts are executed via `fork`/`exec` without a shell. Arguments are passed as
  an array, preventing injection.

file permissions
: Scripts in `/opt/dispatcher-scripts/` should be owned `root:dispatcher-agent`
  mode 750. The agent runs as the `dispatcher-agent` system user with no login
  shell.

CA key
: The CA key lives only in `/etc/dispatcher/ca.key` on the dispatcher host.
  Back it up securely. Loss of the CA key means re-pairing all agents.

cert expiry
: Agent certs are signed for 825 days. The `dispatcher ping` output shows expiry.
  Re-pair before expiry using the same `pairing-mode` / `request-pairing` flow -
  the existing config and allowlist are preserved.


## Reloading the Allowlist

The agent reloads its allowlist on SIGHUP without dropping connections:

```bash
sudo systemctl kill --signal=HUP dispatcher-agent
```

Or via systemd if you have a reload target configured:

```bash
sudo systemctl reload dispatcher-agent
```


## Uninstalling

```bash
sudo ./install.sh --uninstall
```

Config directories and certs are preserved. Remove manually if desired:

```bash
sudo rm -rf /etc/dispatcher-agent /etc/dispatcher /opt/dispatcher-scripts
sudo userdel dispatcher-agent
```
