---
title: Dispatcher - Docker Deployment
subtitle: Running dispatcher and agents in Alpine Linux containers
brand: cloudient
---

# Dispatcher - Docker Deployment

This document covers deploying dispatcher and dispatcher-agent as Alpine Linux
Docker containers. The application has no awareness of containers - the
differences from a bare-metal installation are in how services are started,
how configuration is persisted, and how pairing is performed between containers.

For bare-metal or VM installation see `INSTALL.md`.


## Overview

dispatcher container
: Runs `dispatcher-api` in the foreground. Exposes port 7445 (API) and
  optionally 7444 (pairing, only when pairing mode is active). The CA, registry,
  and dispatcher cert are stored on a named volume so they persist across
  container restarts and image rebuilds.

agent container
: Runs `dispatcher-agent serve` in the foreground. Exposes port 7443. Agent
  cert and config are stored on a named volume. The container pairs with the
  dispatcher on first start and then serves normally on subsequent starts.

Volumes hold all state. Containers are otherwise stateless and can be rebuilt
from the image without loss of pairing or configuration.


## Dispatcher Container

### Dockerfile

```dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    perl \
    perl-io-socket-ssl \
    perl-json \
    perl-libwww \
    openssl

WORKDIR /opt/dispatcher

COPY . .

RUN ./install.sh --dispatcher --api

COPY docker/dispatcher-entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

EXPOSE 7444 7445

ENTRYPOINT ["/entrypoint.sh"]
```

### Entrypoint script

`docker/dispatcher-entrypoint.sh`:

```bash
#!/bin/sh
set -e

CONF_DIR=/etc/dispatcher

# First-start initialisation: create CA and dispatcher cert if absent.
# On subsequent starts the volume already contains these files and this
# block is skipped entirely.
if [ ! -f "$CONF_DIR/ca.crt" ]; then
    echo "[entrypoint] First start: initialising CA..."
    dispatcher setup-ca
    dispatcher setup-dispatcher
    echo "[entrypoint] CA and dispatcher cert created."
fi

echo "[entrypoint] Starting dispatcher-api..."
exec dispatcher-api
```

The entrypoint uses `exec` so `dispatcher-api` runs as PID 1 and receives
signals directly from Docker.

### docker-compose.yml (dispatcher only)

```yaml
services:
  dispatcher:
    build: .
    container_name: dispatcher
    restart: unless-stopped
    ports:
      - "7444:7444"   # pairing - expose only when actively pairing
      - "7445:7445"   # API
    volumes:
      - dispatcher-data:/etc/dispatcher
      - dispatcher-registry:/var/lib/dispatcher

volumes:
  dispatcher-data:
  dispatcher-registry:
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

WORKDIR /opt/dispatcher

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

CONF_DIR=/etc/dispatcher-agent
CERT="$CONF_DIR/agent.crt"

# DISPATCHER_HOST must be set in the container environment or compose file.
if [ -z "$DISPATCHER_HOST" ]; then
    echo "[entrypoint] ERROR: DISPATCHER_HOST environment variable not set." >&2
    exit 1
fi

# First start: no cert means we have not paired yet.
# Request pairing and then exit. The operator approves on the dispatcher,
# then the container is restarted to begin serving.
if [ ! -f "$CERT" ]; then
    echo "[entrypoint] No cert found - requesting pairing with $DISPATCHER_HOST..."
    dispatcher-agent request-pairing --dispatcher "$DISPATCHER_HOST"
    echo "[entrypoint] Pairing request sent. Approve on the dispatcher, then restart this container."
    exit 0
fi

echo "[entrypoint] Cert found - starting dispatcher-agent serve..."
exec dispatcher-agent serve
```

The two-phase entrypoint separates the pairing request (a one-shot operation
that exits) from normal service operation. The container exits after requesting
pairing - Docker's restart policy does not apply to a deliberate `exit 0`, so
the container stays stopped until the operator approves and restarts it.

### docker-compose.yml (full stack)

```yaml
services:
  dispatcher:
    build:
      context: .
      dockerfile: docker/Dockerfile.dispatcher
    container_name: dispatcher
    restart: unless-stopped
    ports:
      - "7445:7445"
    volumes:
      - dispatcher-data:/etc/dispatcher
      - dispatcher-registry:/var/lib/dispatcher
    networks:
      - dispatcher-net

  agent:
    build:
      context: .
      dockerfile: docker/Dockerfile.agent
    container_name: agent
    restart: on-failure
    environment:
      DISPATCHER_HOST: dispatcher   # Docker DNS resolves service name
    ports:
      - "7443:7443"
    volumes:
      - agent-data:/etc/dispatcher-agent
      - agent-scripts:/opt/dispatcher-scripts
    networks:
      - dispatcher-net
    depends_on:
      - dispatcher

volumes:
  dispatcher-data:
  dispatcher-registry:
  agent-data:
  agent-scripts:

networks:
  dispatcher-net:
```

`DISPATCHER_HOST: dispatcher` uses Docker's internal DNS to resolve the
dispatcher service by name. No IP addresses required.


## Pairing Workflow in Docker

Pairing between containers follows the same protocol as bare-metal but uses
`docker exec` instead of separate terminal sessions.

### Step 1 - Start the dispatcher

```bash
docker compose up -d dispatcher
```

Wait for the first-start initialisation to complete:

```bash
docker logs dispatcher
# [entrypoint] First start: initialising CA...
# [entrypoint] CA and dispatcher cert created.
# [entrypoint] Starting dispatcher-api...
```

### Step 2 - Start pairing mode on the dispatcher

```bash
docker exec -it dispatcher dispatcher pairing-mode
```

This blocks, waiting for requests. Leave it running.

### Step 3 - Start the agent container

In another terminal:

```bash
docker compose up agent
```

The entrypoint finds no cert and sends a pairing request:

```
[entrypoint] No cert found - requesting pairing with dispatcher...
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
docker exec dispatcher dispatcher list-requests
docker exec dispatcher dispatcher approve <reqid>
```

### Step 5 - Restart the agent

```bash
docker compose up -d agent
```

The entrypoint finds the cert this time and starts serving:

```
[entrypoint] Cert found - starting dispatcher-agent serve...
```

### Step 6 - Verify

```bash
docker exec dispatcher dispatcher ping agent
docker exec dispatcher dispatcher run agent check-disk
```


## Agent Scripts

Scripts run by the agent are stored in the `agent-scripts` volume. To add a
script to a running agent container:

```bash
# Copy script into the volume via the running container
docker cp check-disk.sh agent:/opt/dispatcher-scripts/
docker exec agent chmod 750 /opt/dispatcher-scripts/check-disk.sh
docker exec agent chown root:dispatcher-agent /opt/dispatcher-scripts/check-disk.sh

# Add to allowlist
docker exec agent sh -c \
    'echo "check-disk = /opt/dispatcher-scripts/check-disk.sh" \
    >> /etc/dispatcher-agent/scripts.conf'

# Reload config without restart
docker exec agent kill -HUP 1
```

Alternatively, pre-populate scripts in the Dockerfile or bake them into the
image for immutable deployments. For mutable agent fleets, maintain scripts
on a separate volume that is populated by a provisioning step before the agent
starts.


## Encrypted Credentials

Container volumes hold the CA key, dispatcher cert, and agent cert. For
production deployments these should be protected at rest.

### Docker secrets

Docker Swarm supports secrets natively. For standalone Docker, a common
pattern is to populate the config volume from a secrets manager at container
start via the entrypoint script:

```bash
#!/bin/sh
# Retrieve CA key from secrets manager before starting
if [ ! -f /etc/dispatcher/ca.key ]; then
    echo "[entrypoint] Fetching CA key from secrets manager..."
    # Example: AWS Secrets Manager
    aws secretsmanager get-secret-value \
        --secret-id dispatcher/ca-key \
        --query SecretString \
        --output text > /etc/dispatcher/ca.key
    chmod 600 /etc/dispatcher/ca.key
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

- The host running the dispatcher container has restricted access
- The `dispatcher-data` volume is not world-readable
- The CA key is backed up to encrypted offline storage immediately after
  first-start initialisation

```bash
# Backup CA key after first start
docker exec dispatcher cat /etc/dispatcher/ca.key \
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
      DISPATCHER_HOST: dispatcher
    volumes:
      - agent-db-data:/etc/dispatcher-agent
      - agent-db-scripts:/opt/dispatcher-scripts
    networks:
      - dispatcher-net

  agent-web:
    build:
      context: .
      dockerfile: docker/Dockerfile.agent
    environment:
      DISPATCHER_HOST: dispatcher
    volumes:
      - agent-web-data:/etc/dispatcher-agent
      - agent-web-scripts:/opt/dispatcher-scripts
    networks:
      - dispatcher-net
```

Each agent pairs independently and appears separately in `dispatcher list-agents`.
The agent hostname in the registry is taken from the hostname reported in the
pairing request - set `hostname` in each container to something meaningful:

```yaml
agent-db:
  hostname: agent-db
```


## Rebuilding Images

Because all state is on volumes, images can be rebuilt without losing pairing
or configuration:

```bash
docker compose build dispatcher
docker compose up -d dispatcher
# Volumes are reattached - CA and registry are intact
```

If a volume is deleted (e.g. `docker compose down -v`), the dispatcher loses
its CA and all agents must be re-paired. The CA backup covers this case.
