---
title: Dispatcher
subtitle: Perl machine-to-machine remote script execution over mTLS
brand: odcc
---

# Dispatcher

A Perl machine-to-machine remote script execution system. The dispatcher host
runs scripts on remote agent hosts via HTTPS with mutual certificate
authentication. No SSH involved; agents expose only an explicit allowlist of
permitted scripts.

Designed for infrastructure automation pipelines where a control host needs
to trigger operations on a fleet of managed hosts with strong identity
guarantees and a minimal attack surface.


## How It Works

dispatcher (control host)
: CLI tool and optional HTTP API. Connects to agents, sends signed requests,
  collects results. Manages the private CA, agent registry, and cert lifecycle.

dispatcher-agent (remote hosts)
: mTLS HTTPS server on port 7443. Executes only scripts named in a per-host
  allowlist. No shell - arguments are passed directly to the OS. Reloads
  config on SIGHUP without dropping connections.

pairing
: One-time certificate exchange. The agent generates a key and CSR, connects
  to the dispatcher on port 7444, and waits for operator approval. The
  dispatcher signs the CSR with its private CA and returns the cert. After
  pairing, all traffic uses mTLS on port 7443.

auth hook
: An optional executable called before every `run` and `ping`. Receives full
  request context including token, username, script, args, and source IP.
  Tokens are forwarded through the pipeline so downstream components can
  independently verify authority. The hook is the policy engine - dispatcher
  has no built-in ACLs.

automatic cert renewal
: Certs are renewed automatically over the live mTLS connection when remaining
  validity drops below half the configured lifetime. No operator involvement
  during normal operation.


## Documents

`INSTALL.md`
: Platform requirements, installer flags, initial setup, all configuration
  options, operational reference, troubleshooting.

`DOCKER.md`
: Deploying dispatcher and agents in Alpine Docker containers, including
  entrypoint patterns, volume mounts, and the pairing workflow in Docker.

`SECURITY.md`
: Security model, trust boundaries, file permissions, and operational
  security guidance.

`DEVELOPER.md`
: Module reference, wire format, protocol details, and how to extend the
  system.


## Quick Start

Full detail is in `INSTALL.md`. The sequence below gets dispatcher running
between two hosts in about ten minutes.

### Dispatcher host

```bash
sudo ./install.sh --dispatcher
sudo dispatcher setup-ca
sudo dispatcher setup-dispatcher
sudo usermod -aG dispatcher $USER
# Log out and back in for group membership to take effect
```

### Agent host

```bash
sudo ./install.sh --agent
```

Edit `/etc/dispatcher-agent/scripts.conf` - add at least one script:

```ini
check-disk = /opt/dispatcher-scripts/check-disk.sh
```

```bash
sudo systemctl enable dispatcher-agent
sudo systemctl start dispatcher-agent
```

### Pair the agent

On the dispatcher host:

```bash
sudo dispatcher pairing-mode
```

On the agent host:

```bash
sudo dispatcher-agent request-pairing --dispatcher <dispatcher-hostname>
```

Type `a` in the pairing mode terminal to approve. The agent stores its cert
and is ready.

### Verify

```bash
dispatcher ping <agent-hostname>
dispatcher run <agent-hostname> check-disk
```

### Optional: API server

```bash
sudo ./install.sh --api
sudo systemctl enable dispatcher-api
sudo systemctl start dispatcher-api
curl -s http://localhost:7445/health
```


## Platform Support

Debian / Ubuntu
: `apt` packages, systemd service management.

Alpine Linux
: `apk` packages, no systemd. Run binaries directly or use Docker - see
  `DOCKER.md`.

All dependencies are system packages on both platforms. No CPAN required.
