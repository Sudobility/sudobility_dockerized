# CLAUDE.md

> **Git policy — never auto-commit or auto-push.** Leave work in the working tree.
> Run `git commit`/`git push`/`gh pr create` **only when the user explicitly asks in
> that turn**. Finishing a task is not permission to commit it. Stay on the current
> branch; do not create feature branches for code changes.

## What this is

A **bash-script-driven Docker deployment toolkit** — NOT a single `docker compose up`
stack. Interactive scripts generate and manage a separate compose file per service
under `config-generated/` (git-ignored). Each service runs behind a shared Traefik
reverse proxy with host-based routing, Let's Encrypt SSL, and Doppler-sourced secrets.

There is no top-level stack to bring up. The entry points are the scripts below.

## Commands (verified)

| Command | What it does |
|---------|--------------|
| `./add.sh [--dry-run]` | Add a service: ensure Traefik, prompt (name/host/image/health/token), fetch Doppler secrets, generate + start the service |
| `./upgrade.sh [--dry-run]` | Re-fetch secrets, update `PORT` if changed, pull latest image, restart |
| `./remove.sh` | Remove a service (double confirm: y/n + retype the name); stops container, deletes config + token |
| `./status.sh` | Table of Traefik + all services (status/health/version/uptime/hostname) |
| `./test.sh` | Offline tests: `bash -n` + checks `common.sh` functions/constants (stubs docker/curl) |
| `./lint.sh` | ShellCheck (`shellcheck -x -S warning`) over all scripts; needs `shellcheck` |
| `./scripts/apply-service-template.sh [--check] [repo…]` | Stamp the canonical bun-API `Dockerfile`/`.dockerignore` into sibling service repos (`--check` = report drift, exit 1) |

There is no build step. `--dry-run` exists only on `add.sh` and `upgrade.sh`.

## Shared service Dockerfile template (source of truth)

The plain Bun HTTP APIs share one Dockerfile (port-only difference) + one
`.dockerignore`. The canonical copies live here, not hand-maintained per repo:
`templates/Dockerfile.bun-api` (`__PORT__` placeholder; token via BuildKit
secret, never baked), `templates/dockerignore`, and `services.manifest`
(`repo port` list). `scripts/apply-service-template.sh` stamps them into the
sibling repos (`../<repo>`); `--check` reports drift (wire into CI to prevent
re-drift). Each repo keeps its own generated `Dockerfile` because CI
(`johnqh/workflows`) builds each from its own context. Structurally-different
services are excluded from the manifest and listed in its header comment
(`screenwriter_api`, `svgr_api`, `haraka-plugin-wildduck`, the `*_indexer` pair,
`sudojo_bot`).

## Layout

- `add.sh` / `upgrade.sh` / `remove.sh` / `status.sh` — main scripts; each sources
  `setup-scripts/common.sh`.
- `setup-scripts/common.sh` — the **only** shared library actually sourced. Holds all
  Traefik, Doppler, and service functions.
- `default-config/<service>/.env.defaults` — reference docs for non-sensitive defaults
  (read only by the unused `doppler.sh`); live values come from Doppler.
- `docs/TRAEFIK.md` — networking / discovery / SSL deep dive.
- `config-generated/` (runtime, git-ignored):
  - `traefik/docker-compose.yml`
  - `services/<name>/{docker-compose.yml, .env, .service.conf}`
  - `.doppler-tokens/<name>`

## How a service is wired

`add.sh` writes `config-generated/services/<name>/docker-compose.yml` with host-based
Traefik labels (NO path prefix):

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<name>.rule=Host(`<hostname>`)"
  - "traefik.http.routers.<name>.entrypoints=websecure"
  - "traefik.http.routers.<name>.tls.certresolver=letsencrypt"
  - "traefik.http.services.<name>.loadbalancer.server.port=<PORT>"
networks:
  sudobility_network:
    external: true
```

- All services + Traefik share the `sudobility_network` bridge network. Services join it
  as `external: true`, so it must exist first — `install_traefik()` calls
  `ensure_network()` before anything starts.
- Traefik is generated/started by `install_traefik()` in `common.sh` (ports 80/443,
  `exposedbydefault=false`, dashboard disabled). ACME email is hardcoded there as
  `admin@sudobility.com`; HTTP-01 challenge needs public port 80.

## Doppler

- `PORT` is the only variable the toolkit requires; `add.sh` aborts if it is absent.
  It is also used as the Traefik load-balancer port.
- Download endpoint: `https://api.doppler.com/v3/configs/config/secrets/download?format=env`
  (`-u "<token>:"`). Token saved per service for upgrades.

## Conventions

- Source `common.sh` at the top; main scripts (except `status.sh`) use `set -e`.
- Output via `print_success` / `print_error` / `print_warning` / `print_info` / `print_header`.
- Docker Compose via `$(get_docker_compose_cmd)` (v2, falls back to `docker-compose` v1).
- Bash 3.x compatible (macOS): no `mapfile` — use `read_services_array` (sets `$SERVICES`).
- Permissions: `.doppler-tokens/` dir `700`, token/`.env`/`.service.conf` files `600`.

## Gotchas

1. **Stale/legacy files — do not rely on or document them as current:**
   - Top-level `docker-compose.yml` and `.env.example` — templates for an old monolithic
     `setup.sh` design (path-prefix routing, `API_HOSTNAME` placeholder). Unused by any script.
   - `versions.sh` — expects old `config-generated/docker-compose.yml`, `.deployment-config`,
     and an undefined `CONTAINERS` array / `get_container_display_name`; exits early. Use
     `./status.sh`. (It is still covered by `test.sh`/`lint.sh` for syntax only.)
   - `setup-scripts/traefik.sh`, `doppler.sh`, `deps_setup.sh` — supplementary helpers for
     the old `setup.sh`; NOT sourced by the main scripts.
2. Service name = container name; must be unique and match `^[a-zA-Z][a-zA-Z0-9_]*$`.
3. Hostname DNS must point to the server before SSL can be issued (ACME HTTP-01).
4. `dynamic_conf/dynamic.yml` is only referenced by the legacy top-level compose; the
   generated Traefik config does not use the file provider.
5. Changes to scripts affect every managed service — run `./test.sh` (and `./lint.sh`)
   before and after editing.

## Workspace context

Part of the larger ShapeShyft multi-project workspace but operates independently as a
deployment tool. See `../CLAUDE.md` for the services this tool deploys.
</content>
