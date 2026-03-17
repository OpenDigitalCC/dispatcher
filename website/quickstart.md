---
title: Quickstart
subtitle: Dispatcher and agent running, PKI configured, first remote execution in under ten minutes.
updated: 2026-03-16
github_url: https://github.com/OpenDigitalCC/ctrl-exec/blob/main/docs/QUICKSTART.md
current_page: /quickstart
---

# Prerequisites

On the control host (where `ced` will run):

```bash
# Debian / Ubuntu
sudo apt-get install libwww-perl libio-socket-ssl-perl libjson-perl openssl perl

# Alpine
sudo apk add perl-libwww perl-io-socket-ssl perl-json openssl perl
```

On each agent host (where `cea` will run):

```bash
# Debian / Ubuntu
sudo apt-get install libio-socket-ssl-perl libjson-perl openssl perl

# Alpine
sudo apk add perl-io-socket-ssl perl-json openssl perl
```

# Install

Clone the repository on each host and run the installer:

```bash
git clone https://github.com/OpenDigitalCC/ctrl-exec.git
cd ctrl-exec
```

On the control host:

```bash
sudo ./install.sh --ctrl-exec
```

On each agent host:

```bash
sudo ./install.sh --agent
```

Add yourself to the `ctrl-exec` group for CLI access without sudo:

```bash
sudo usermod -aG ctrl-exec $USER
newgrp ctrl-exec
```

# Initialise the CA

Run once on the control host. This generates the CA key and certificate and the ctrl-exec's own TLS certificate.

```bash
sudo ctrl-exec setup-ca
sudo ctrl-exec setup-ctrl-exec
```

The CA key at `/etc/ctrl-exec/ca.key` is the root of trust for the deployment. Back it up to encrypted offline storage before proceeding.

# Start Pairing Mode

On the control host, open the pairing listener:

```bash
sudo ctrl-exec pairing-mode
```

Leave this running. Open a second terminal for the next steps.

# Pair an Agent

On the agent host, submit a pairing request. Replace `ctrl-exec.example.com` with the hostname or IP of your control host:

```bash
sudo ctrl-exec-agent request-pairing --dispatcher ctrl-exec.example.com
```

The agent generates a key pair, submits a CSR, and prints a 6-digit verification code:

```
Pairing code: 482 917
Waiting for approval...
```

Back on the control host, the pairing-mode terminal displays the same code:

```
New request from agent-host.example.com (192.168.1.42)
Pairing code: 482 917
Approve? [a/d]:
```

Verify the codes match. Type `a` and press Enter to approve.

The agent stores its signed certificate, the CA certificate, and the ctrl-exec serial. Pairing is complete.

# Start the Agent

On the agent host:

```bash
sudo systemctl enable ctrl-exec-agent
sudo systemctl start ctrl-exec-agent
```

Or without systemd:

```bash
sudo ctrl-exec-agent serve &
```

# Confirm Connectivity

From the control host:

```bash
ced ping agent-host.example.com
```

Expected output:

```
agent-host.example.com  ok  12ms  cert expires 2027-03-16
```

# Add a Script to the Allowlist

On the agent host, create a script:

```bash
sudo mkdir -p /opt/ctrl-exec-scripts
sudo tee /opt/ctrl-exec-scripts/check-disk.sh > /dev/null <<'EOF'
#!/bin/bash
df -h /
EOF
sudo chmod +x /opt/ctrl-exec-scripts/check-disk.sh
```

Add it to the allowlist at `/etc/ctrl-exec-agent/scripts.conf`:

```ini
check-disk = /opt/ctrl-exec-scripts/check-disk.sh
```

Reload the agent to pick up the change:

```bash
sudo systemctl kill --signal=HUP ctrl-exec-agent
```

# Run a Script

From the control host:

```bash
ced run agent-host.example.com check-disk
```

Expected output:

```
agent-host.example.com  exit=0
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        40G   12G   26G  32% /
```

# Next Steps

[Install](/install)
: Full installation reference for all platforms including OpenWrt and Docker.

[Architecture](/architecture)
: How the dispatcher, agent, and API server work and interact.

[Configuration](/config)
: All configuration keys for `ctrl-exec.conf` and `agent.conf`.

[Auth hooks](/auth)
: Restricting which users and tokens can run which scripts.
