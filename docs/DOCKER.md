---
title: ctrl-exec - Docker Deployment
subtitle: Running ctrl-exec and agents in Alpine Linux containers
brand: odcc
---

# ctrl-exec - Docker Deployment

This document covers deploying ctrl-exec and ctrl-exec-agent as Alpine Linux
Docker containers. The application has no awareness of containers - the
differences from a bare-metal installation are in how services are started,
how configuration is persisted, and how pairing is performed between containers.

For bare-metal or VM installation see `INSTALL.md`.


## Overview

ctrl-exec container
: Runs `ctrl-exec-api` in the foreground. Exposes port 7445 (API) and
  optionally 7444 (pairing, only when pairing mode is active). The CA, registry,
  and ctrl-exec cert are stored on a named volume so they persist across
  container restarts and image rebuilds.

agent container
: Runs `ctrl-exec-agent serve` in the foreground. Exposes port 7443. Agent
  cert and config are stored on a named volume. The container pairs with the
  ctrl-exec on first start and then serves normally on subsequent starts.

Volumes hold all state. Containers are otherwise stateless and can be rebuilt
from the image without loss of pairing or configuration.


## ctrl-exec Container

### Dockerfile

```dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    perl \
    perl-io-socket-ssl \
    perl-json \
    perl-libwww \
    openssl

WORKDIR /opt/ctrl-exec

COPY . .

RUN ./install.sh --ctrl-exec --api

COPY docker/ctrl-exec-entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

EXPOSE 7444 7445

ENTRYPOINT ["/entrypoint.sh"]
```

### Entrypoint script

`docker/ctrl-exec-entrypoint.sh`:

```bash
#!/bin/sh
set -e

CONF_DIR=/etc/ctrl-exec

# First-start initialisation: create CA and ctrl-exec cert if absent.
# On subsequent starts the volume already contains these files and this
# block is skipped entirely.
if [ ! -f "$CONF_DIR/ca.crt" ]; then
    echo "[entrypoint] First start: initialising CA..."
    ctrl-exec setup-ca
    ctrl-exec setup-ctrl-exec
    echo "[entrypoint] CA and ctrl-exec cert created."
fi

echo "[entrypoint] Starting ctrl-exec-api..."
exec ctrl-exec-api
```

The entrypoint uses `exec` so `ctrl-exec-api` runs as PID 1 and receives
signals directly from Docker.

### docker-compose.yml (ctrl-exec only)

```yaml
services:
  ctrl-exec:
    build: .
    container_name: ctrl-exec
    restart: unless-stopped
    ports:
      - "7444:7444"   # pairing - expose only when actively pairing
      - "7445:7445"   # API
    volumes:
      - ctrl-exec-data:/etc/ctrl-exec
      - ctrl-exec-registry:/var/lib/ctrl-exec

volumes:
  ctrl-exec-data:
  ctrl-exec-registry:
```

Port 7444 is the pairing port. If agents are on the same Docker network and
pairing is done container-to-container, 7444 does not need to be published to
the host. Publish it only when pairing agents on external hosts.


## Agent Container

### Dockerfile

```dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    perl \
    perl-io-socket-ssl \
    perl-json \
    openssl

WORKDIR /opt/ctrl-exec

COPY . .

RUN ./install.sh --agent

COPY docker/agent-entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

EXPOSE 7443

ENTRYPOINT ["/entrypoint.sh"]
```

### Entrypoint script

`docker/agent-entrypoint.sh`:

```bash
#!/bin/sh
set -e

CONF_DIR=/etc/ctrl-exec-agent
CERT="$CONF_DIR/agent.crt"

# CTRL_EXEC_HOST must be set in the container environment or compose file.
if [ -z "$CTRL_EXEC_HOST" ]; then
    echo "[entrypoint] ERROR: CTRL_EXEC_HOST environment variable not set." >&2
    exit 1
fi

# First start: no cert means we have not paired yet.
# Request pairing and then exit. The operator approves on the ctrl-exec,
# then the container is restarted to begin serving.
if [ ! -f "$CERT" ]; then
    echo "[entrypoint] No cert found - requesting pairing with $CTRL_EXEC_HOST..."
    ctrl-exec-agent request-pairing --dispatcher "$CTRL_EXEC_HOST"
    echo "[entrypoint] Pairing request sent. Approve on the ctrl-exec, then restart this container."
    exit 0
fi

echo "[entrypoint] Cert found - starting ctrl-exec-agent serve..."
exec ctrl-exec-agent serve
```

The two-phase entrypoint separates the pairing request (a one-shot operation
that exits) from normal service operation. The container exits after requesting
pairing - Docker's restart policy does not apply to a deliberate `exit 0`, so
the container stays stopped until the operator approves and restarts it.

For automated or orchestrated deployments, `--background` mode can be used
instead. This prints the `reqid` and pairing code to stdout, then waits for
approval without requiring an interactive terminal:

```bash
ctrl-exec-agent request-pairing --dispatcher "$CTRL_EXEC_HOST" --background
```

The container still exits after pairing; the `reqid` can be captured by the
orchestration layer and passed to `ctrl-exec approve <reqid>` on the
ctrl-exec. See REFERENCE.md `### Orchestrated pairing` for the full flow.

### docker-compose.yml (full stack)

```yaml
services:
  ctrl-exec:
    build:
      context: .
      dockerfile: docker/Dockerfile.ctrl-exec
    container_name: ctrl-exec
    restart: unless-stopped
    ports:
      - "7445:7445"
    volumes:
      - ctrl-exec-data:/etc/ctrl-exec
      - ctrl-exec-registry:/var/lib/ctrl-exec
    networks:
      - ctrl-exec-net

  agent:
    build:
      context: .
      dockerfile: docker/Dockerfile.agent
    container_name: agent
    restart: on-failure
    environment:
      CTRL_EXEC_HOST: ctrl-exec   # Docker DNS resolves service name
    ports:
      - "7443:7443"
    volumes:
      - agent-data:/etc/ctrl-exec-agent
      - agent-scripts:/opt/ctrl-exec-scripts
    networks:
      - ctrl-exec-net
    depends_on:
      - ctrl-exec

volumes:
  ctrl-exec-data:
  ctrl-exec-registry:
  agent-data:
  agent-scripts:

networks:
  ctrl-exec-net:
```

`CTRL_EXEC_HOST: ctrl-exec` uses Docker's internal DNS to resolve the
ctrl-exec service by name. No IP addresses required.


## Pairing Workflow in Docker

Pairing between containers follows the same protocol as bare-metal but uses
`docker exec` instead of separate terminal sessions.

### Step 1 - Start the ctrl-exec

```bash
docker compose up -d ctrl-exec
```

Wait for the first-start initialisation to complete:

```bash
docker logs ctrl-exec
# [entrypoint] First start: initialising CA...
# [entrypoint] CA and ctrl-exec cert created.
# [entrypoint] Starting ctrl-exec-api...
```

### Step 2 - Start pairing mode on the ctrl-exec

```bash
docker exec -it ctrl-exec ctrl-exec pairing-mode
```

This blocks, waiting for requests. Leave it running.

### Step 3 - Start the agent container

In another terminal:

```bash
docker compose up agent
```

The entrypoint finds no cert and sends a pairing request:

```
[entrypoint] No cert found - requesting pairing with ctrl-exec...
```

The agent container exits after sending the request. This is expected.

### Step 4 - Approve the request

Back in the pairing mode terminal, the request appears:

```
Pairing request from agent (172.18.0.3) - ID: 00c9845e0001
  Received: 2026-03-06T12:00:00Z
Accept, Deny, or Skip? [a/d/s]:
```

Type `a` to approve.

Alternatively, from a third terminal without interactive pairing mode:

```bash
docker exec ctrl-exec ctrl-exec list-requests
docker exec ctrl-exec ctrl-exec approve <reqid>
```

### Step 5 - Restart the agent

```bash
docker compose up -d agent
```

The entrypoint finds the cert this time and starts serving:

```
[entrypoint] Cert found - starting ctrl-exec-agent serve...
```

### Step 6 - Verify

```bash
docker exec ctrl-exec ctrl-exec ping agent
docker exec ctrl-exec ctrl-exec run agent check-disk
```


## Agent Scripts

Scripts run by the agent are stored in the `agent-scripts` volume. To add a
script to a running agent container:

```bash
# Copy script into the volume via the running container
docker cp check-disk.sh agent:/opt/ctrl-exec-scripts/
docker exec agent chmod 750 /opt/ctrl-exec-scripts/check-disk.sh
docker exec agent chown root:ctrl-exec-agent /opt/ctrl-exec-scripts/check-disk.sh

# Add to allowlist
docker exec agent sh -c \
    'echo "check-disk = /opt/ctrl-exec-scripts/check-disk.sh" \
    >> /etc/ctrl-exec-agent/scripts.conf'

# Reload config without restart
docker exec agent kill -HUP 1
```

Alternatively, pre-populate scripts in the Dockerfile or bake them into the
image for immutable deployments. For mutable agent fleets, maintain scripts
on a separate volume that is populated by a provisioning step before the agent
starts.


## Encrypted Credentials

Container volumes hold the CA key, ctrl-exec cert, and agent cert. For
production deployments these should be protected at rest.

### Docker secrets

Docker Swarm supports secrets natively. For standalone Docker, a common
pattern is to populate the config volume from a secrets manager at container
start via the entrypoint script:

```bash
#!/bin/sh
# Retrieve CA key from secrets manager before starting
if [ ! -f /etc/ctrl-exec/ca.key ]; then
    echo "[entrypoint] Fetching CA key from secrets manager..."
    # Example: AWS Secrets Manager
    aws secretsmanager get-secret-value \
        --secret-id ctrl-exec/ca-key \
        --query SecretString \
        --output text > /etc/ctrl-exec/ca.key
    chmod 600 /etc/ctrl-exec/ca.key
fi
```

The specific mechanism depends on the secrets manager available in the
deployment environment (Vault, AWS Secrets Manager, Azure Key Vault, etc.).

### Encrypted volumes

LUKS-encrypted volumes or encrypted filesystem layers (dm-crypt) can protect
volume contents at rest. This is a host-level concern - the container has no
awareness of whether its volume is encrypted.

For cloud deployments, encrypted EBS volumes (AWS), managed disks (Azure), or
persistent disks (GCP) provide at-rest encryption with minimal operational
overhead. Enable encryption when creating the volume and the platform handles
key management.

### Minimum viable protection

At minimum, ensure:

- The host running the ctrl-exec container has restricted access
- The `ctrl-exec-data` volume is not world-readable
- The CA key is backed up to encrypted offline storage immediately after
  first-start initialisation

```bash
# Backup CA key after first start
docker exec ctrl-exec cat /etc/ctrl-exec/ca.key \
    | gpg --symmetric --cipher-algo AES256 \
    > ca.key.gpg
# Store ca.key.gpg in offline/offsite storage
```


## Multiple Agents

To run multiple agent containers, give each a unique name and volume:

```yaml
services:
  agent-db:
    build:
      context: .
      dockerfile: docker/Dockerfile.agent
    environment:
      CTRL_EXEC_HOST: ctrl-exec
    volumes:
      - agent-db-data:/etc/ctrl-exec-agent
      - agent-db-scripts:/opt/ctrl-exec-scripts
    networks:
      - ctrl-exec-net

  agent-web:
    build:
      context: .
      dockerfile: docker/Dockerfile.agent
    environment:
      CTRL_EXEC_HOST: ctrl-exec
    volumes:
      - agent-web-data:/etc/ctrl-exec-agent
      - agent-web-scripts:/opt/ctrl-exec-scripts
    networks:
      - ctrl-exec-net
```

Each agent pairs independently and appears separately in `ctrl-exec list-agents`.
The agent hostname in the registry is taken from the hostname reported in the
pairing request - set `hostname` in each container to something meaningful:

```yaml
agent-db:
  hostname: agent-db
```


## Agent Tags

Tags let you label agents with arbitrary key/value metadata - for example,
environment, role, or location. They are returned in the `/capabilities`
response and propagate through API discovery, making it straightforward to
filter or identify agents without maintaining separate inventory.

For container deployments, add a `[tags]` section to `agent.conf` on the
config volume, or inject it via the entrypoint before starting the agent:

```bash
# In agent-entrypoint.sh, before exec ctrl-exec-agent serve
cat >> /etc/ctrl-exec-agent/agent.conf <<EOF

[tags]
env  = ${AGENT_ENV:-production}
role = ${AGENT_ROLE:-agent}
EOF
```

Then pass values via container environment:

```yaml
agent-db:
  hostname: agent-db
  environment:
    CTRL_EXEC_HOST: ctrl-exec
    AGENT_ENV: production
    AGENT_ROLE: database
```

Tags appear in API discovery responses:

```json
{
  "agent-db": {
    "host": "agent-db",
    "status": "ok",
    "tags": { "env": "production", "role": "database" },
    "scripts": [...]
  }
}
```

An agent with no `[tags]` section returns `"tags": {}`. Tag values are
plain strings; no reserved keys.


## Rebuilding Images

Because all state is on volumes, images can be rebuilt without losing pairing
or configuration:

```bash
docker compose build ctrl-exec
docker compose up -d ctrl-exec
# Volumes are reattached - CA and registry are intact
```

If a volume is deleted (e.g. `docker compose down -v`), the ctrl-exec loses
its CA and all agents must be re-paired. The CA backup covers this case.
