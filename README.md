# Sudobility Dockerized

A script-driven Docker deployment toolkit for running multiple independent backend
services behind a shared [Traefik](https://traefik.io/) reverse proxy, with automatic
SSL via Let's Encrypt and secrets pulled from [Doppler](https://doppler.com/).

> **This is not a single `docker compose up` stack.** You never run a top-level
> compose file. Instead, interactive scripts (`add.sh`, `upgrade.sh`, `remove.sh`,
> `status.sh`) generate and manage a per-service compose file for each service under
> `config-generated/` (git-ignored). See [Legacy files](#legacy-files) for the unused
> top-level `docker-compose.yml`.

## Features

- **Per-service management**: Add, upgrade, and remove services independently
- **Host-based routing**: Each service is routed by its own hostname (e.g. `api.example.com`)
- **Automatic SSL**: Let's Encrypt certificates via the ACME HTTP-01 challenge
- **Secrets management**: Environment variables fetched from Doppler per service
- **Health checks**: Optional `/health` endpoint monitoring per service
- **Cloudflare compatible**: Works with Cloudflare proxy enabled (Full/Strict SSL)

## Prerequisites

- Docker and Docker Compose v2+ (scripts fall back to `docker-compose` v1 if needed)
- `curl` (used to call the Doppler API)
- `bash` 3.2+ (macOS) or 4+ (Linux) — scripts are bash 3.x compatible
- `jq` (only needed by `versions.sh`; not required for the core add/upgrade/remove flow)
- A domain name with DNS pointing to your server
- A Doppler account with a service token per service

## Architecture

```
                           Internet
                              |
        +---------------------+---------------------+
        | api.shapeshyft.ai   |   api.other.com     |
        v                     v                     v
+-------------------------------------------------------------+
|                    Traefik (Reverse Proxy)                  |
|  - SSL termination (Let's Encrypt ACME HTTP-01)             |
|  - Host-based routing (Host header, no path prefix)         |
|  - HTTP -> HTTPS redirect                                   |
|  - Docker label-based service discovery                     |
+-------------------------------------------------------------+
                              |
             sudobility_network (Docker bridge)
                              |
        +---------------------+---------------------+
        | Host: api.shapeshyft.ai                   | Host: api.other.com
        v                                           v
+-------------------+                       +-------------------+
|  shapeshyft_api   |                       |    other_api      |
+-------------------+                       +-------------------+
```

All traffic enters through Traefik on ports 80 and 443. Traefik routes requests to the
correct backend container by `Host` header and forwards to each container's internal
`PORT` (the port is never published on the host). Traefik discovers services through
Docker labels on the containers the scripts generate.

For a deeper explanation of the network, service discovery, and certificate
provisioning, see [`docs/TRAEFIK.md`](docs/TRAEFIK.md).

## Quick Start

### Add your first service

```bash
./add.sh
```

You will be prompted for:

1. **Service name** — used as the container name (e.g. `shapeshyft_api`); must start with a letter, letters/digits/underscores only
2. **Hostname** — public URL (e.g. `api.shapeshyft.ai`)
3. **Docker image** — image to pull (e.g. `docker.io/username/image:latest`)
4. **Health check** — use the `/health` endpoint, or skip
5. **Doppler service token** — validated against the Doppler API before use

The script will:

- Install and start Traefik if it is not already running
- Fetch environment variables from Doppler (the secrets **must** include `PORT`)
- Generate `config-generated/services/<name>/` (compose file, `.env`, `.service.conf`)
- Save the Doppler token for future upgrades
- Pull the image and start the container with SSL enabled

Use `./add.sh --dry-run` to preview every action without creating anything, fetching
secrets, or starting containers.

## Commands

| Script | Purpose |
|--------|---------|
| `./add.sh [--dry-run]` | Interactively add a new service (installs Traefik if needed) |
| `./upgrade.sh [--dry-run]` | Refresh secrets from Doppler, pull the latest image, restart a service |
| `./remove.sh` | Remove a service (double confirmation: y/n + type the service name) |
| `./status.sh` | Show Traefik + all services with status, health, version, uptime, hostname |

### Example status output

```
Infrastructure:
  Traefik:  Status: running  Health: no healthcheck  Uptime: 11h 41m

Services:

#    SERVICE              STATUS       HEALTH       VERSION    UPTIME       HOSTNAME
1    shapeshyft_api       running      healthy      latest     6s           api.shapeshyft.ai
```

## Development

```bash
./test.sh    # bash -n syntax checks + verifies common.sh functions/constants (no Docker required)
./lint.sh    # runs ShellCheck (shellcheck -x -S warning) over all scripts; requires shellcheck
```

`test.sh` runs entirely offline using stubbed `docker`/`curl`, so it is safe in CI.

## Directory Structure

```
sudobility_dockerized/
├── add.sh                       # Add a new service
├── upgrade.sh                   # Upgrade an existing service
├── remove.sh                    # Remove a service
├── status.sh                    # Show all services' status
├── test.sh                      # Syntax + function tests (offline)
├── lint.sh                      # ShellCheck wrapper
├── versions.sh                  # Legacy/stale — see "Legacy files" below
├── docker-compose.yml           # Legacy template — NOT used by the scripts
├── .env.example                 # Legacy template — NOT used by the scripts
├── setup-scripts/
│   ├── common.sh                # The shared library actually sourced by all scripts
│   ├── traefik.sh               # Supplementary helpers — NOT sourced by main scripts
│   ├── doppler.sh               # Supplementary helpers — NOT sourced by main scripts
│   └── deps_setup.sh            # Supplementary helpers — NOT sourced by main scripts
├── default-config/
│   └── <service>/.env.defaults  # Reference list of non-sensitive defaults (documentation)
├── dynamic_conf/
│   └── dynamic.yml              # Traefik file-provider examples (referenced only by legacy compose)
├── docs/
│   └── TRAEFIK.md               # Networking, discovery, and SSL deep dive
├── plans/
│   └── IMPROVEMENTS.md          # Backlog / improvement notes
└── config-generated/            # Auto-generated at runtime, git-ignored
    ├── traefik/
    │   └── docker-compose.yml   # Traefik config (generated by install_traefik)
    ├── services/
    │   └── <service_name>/
    │       ├── docker-compose.yml
    │       ├── .env             # Secrets fetched from Doppler (chmod 600)
    │       └── .service.conf    # name/hostname/image/port/health metadata (chmod 600)
    └── .doppler-tokens/
        └── <service_name>       # Doppler token for upgrades (chmod 600, dir chmod 700)
```

Only `setup-scripts/common.sh` is sourced by the main scripts. `traefik.sh`,
`doppler.sh`, and `deps_setup.sh` are supplementary/legacy and are referenced only by
`test.sh`/`lint.sh` (for syntax/lint coverage); they are not part of the add/upgrade/
remove flow.

## Doppler Configuration

Each service pulls its environment from Doppler as an `.env`-formatted download. The
only variable the toolkit itself requires is `PORT`; everything else is
service-specific. `add.sh` aborts if `PORT` is missing from the fetched secrets.

| Variable | Required | Description |
|----------|----------|-------------|
| `PORT` | Yes | Internal port the container listens on; also set as the Traefik load-balancer port |
| Others | Varies | Service-specific secrets |

Download endpoint used by the scripts:

```
https://api.doppler.com/v3/configs/config/secrets/download?format=env
```

### Generating a service token

1. Open the [Doppler Dashboard](https://dashboard.doppler.com)
2. Select your project and config (e.g. `prd`)
3. Go to **Access → Service Tokens** and generate a token
4. Provide the token when `add.sh` prompts for it

`default-config/<service>/.env.defaults` documents the non-sensitive defaults and the
expected secret names for known services (`shapeshyft_api`, `testomniac_runner`). These
files are reference material; the live values always come from Doppler.

## Cloudflare Integration

Works with Cloudflare proxy enabled:

1. **Add a DNS `A` record** pointing your subdomain to the server IP (proxy can be OFF initially)
2. **Run `./add.sh`** to deploy the service and provision the certificate
3. **Turn on the Cloudflare proxy** (orange cloud)
4. **Set SSL mode to Full (Strict)** under SSL/TLS → Overview

Use **Full (Strict)**, not Flexible: Flexible connects to the origin over HTTP, which
Traefik redirects to HTTPS and breaks the request. Let's Encrypt renewal continues to
work through the proxy because Cloudflare forwards the HTTP-01 challenge to the origin.

## Manual Operations

```bash
# View a service's logs
cd config-generated/services/<service_name> && docker compose logs -f

# Restart a service
cd config-generated/services/<service_name> && docker compose restart

# View Traefik logs
cd config-generated/traefik && docker compose logs -f

# Check the served SSL certificate
curl -vI https://<hostname> 2>&1 | grep -A5 "Server certificate"
```

## Troubleshooting

### Service won't start
```bash
cd config-generated/services/<service_name> && docker compose logs
```
Common causes: missing `PORT` in Doppler, invalid Doppler token, image not found.

### SSL certificate errors
1. Ensure DNS points to your server IP
2. If using Cloudflare, temporarily turn the proxy OFF while the cert is issued
3. Check Traefik ACME logs:
   ```bash
   cd config-generated/traefik && docker compose logs | grep -i acme
   ```

### 502 / 503 / 404 at the hostname
- Service container may not be running — check `./status.sh`
- Verify `PORT` matches what the app actually listens on
- Confirm the container is on `sudobility_network` and has Traefik labels

### Connection refused
- Ensure ports 80 and 443 are open in the firewall and not used by another process

### Doppler token invalid
Re-add the service with a fresh token:
```bash
./remove.sh   # select the service
./add.sh      # re-add with the new token
```

### Reset everything
```bash
# Stop all services
cd config-generated/services && for dir in */; do (cd "$dir" && docker compose down); done
# Stop Traefik
cd ../traefik && docker compose down
# Remove all generated config
cd ../.. && rm -rf config-generated
# Start fresh
./add.sh
```

More Traefik/TLS/networking troubleshooting is in [`docs/TRAEFIK.md`](docs/TRAEFIK.md).

## Security Notes

- Doppler tokens live in `config-generated/.doppler-tokens/` (dir `700`, files `600`)
- Service `.env` and `.service.conf` files contain secrets (chmod `600`) — never commit
- The entire `config-generated/` directory is git-ignored
- HTTPS is enforced (HTTP redirects to HTTPS); the Traefik dashboard is disabled

## Adding Custom Services

Any Docker image works, provided it:

1. Reads `PORT` from the environment (defined in Doppler) and listens on it
2. Optionally implements `GET /health` returning `200` (for the health check option)

Example (Node.js):
```javascript
const port = process.env.PORT || 3000;
app.get('/health', (req, res) => res.status(200).json({ status: 'healthy' }));
app.listen(port);
```

## Legacy files

The following files are leftovers from an earlier, monolithic single-stack design and
are **not used** by the current script-driven workflow. They are kept for reference but
should not be relied on:

- **`docker-compose.yml`** (top level) — a template with path-prefix routing and an
  `API_HOSTNAME` placeholder that a non-existent `setup.sh` was meant to customize. The
  scripts generate their own per-service compose files instead.
- **`.env.example`** — documents the old `setup.sh` / `.doppler-token-<name>` scheme.
- **`versions.sh`** — expects the old `config-generated/docker-compose.yml`,
  `.deployment-config`, and a `CONTAINERS` array that the current code never creates, so
  it exits early. Use `./status.sh` instead.
- **`setup-scripts/traefik.sh`, `doppler.sh`, `deps_setup.sh`** — supplementary helpers
  tied to the old `setup.sh`; not sourced by the current scripts.

## License

Private — Sudobility
</content>
</invoke>
