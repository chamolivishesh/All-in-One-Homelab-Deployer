# AGENTS.md

## Repository Purpose

This repository is an interactive Bash installer for a small Docker Compose homelab. It generates a deployable subset of the Compose files in `compose-files/`, writes a shared environment file, optionally configures Caddy as an HTTPS reverse proxy, and optionally starts the selected containers.

The intended execution environment is a Linux host or a Linux environment such as WSL with Docker Engine, Docker Compose v2, Bash, OpenSSL, and `yq`. The scripts are not native PowerShell scripts and should not be tested by running them directly in Windows Command Prompt or PowerShell.

## Files and Ownership

- `deploy.sh` is the main interactive workflow and the primary source of deployment behavior. In Portainer mode it generates selected service files plus Caddy artifacts, but starts only Portainer.
- `cert-manager.sh` independently creates local CAs, server certificates, and PKCS#12 files. It is not called by `deploy.sh`.
- `compose-files/*-compose.yml` are service templates. `deploy.sh` copies selected templates into `outfiles/` and mutates those copies.
- `compose-files/hwaccel.*.yml` are Immich extension files and are copied only when Immich is selected.
- `compose-files/extras/` contains reference or obsolete templates and is not included automatically.
- `outfiles/` is generated state and should be treated as disposable output, not as the source of truth.

## `deploy.sh` Execution Flow

1. Resolve the repository directory and change into it.
2. Require root privileges before changing generated output.
3. Delete generated `outfiles/*.yml`, create `outfiles/`, back up an existing `stack.env`, and truncate `stack.env`.
4. Check for Docker Compose v2; on Ubuntu or Debian, install Docker and `yq` if needed.
5. Optionally create or reuse an external Docker network and collect one of four TLS modes:
   - generated self-signed certificate;
   - certificate signed by an existing CA;
   - imported certificate and key;
   - Caddy internal CA.
6. Ask which services to install. `0` selects all currently advertised services.
7. Collect global and service-specific values, write them to `outfiles/stack.env`, and copy selected Compose templates.
8. Use `yq` to add host port mappings when Caddy is disabled, or mark `app-net` as external when Caddy is enabled.
9. Remove Immich Machine Learning from the generated Immich file unless ML was requested.
10. In Caddy mode, collect domains, create certificates and a Caddyfile under `SERVER_DATA_FOLDER`, and copy the Caddyfile into `outfiles/`.
11. Either stop after generating files, deploy only Portainer for Portainer-managed setup, or start stacks with Docker Compose.
12. Start Immich first, AdGuard second, then iterate over remaining generated Compose files. Caddy is started before the service loop.

## Service Matrix

| Menu item | Template | Important generated variables or behavior |
| --- | --- | --- |
| Portainer | `portainer-compose.yml` | `PORTAINER_PORT_HTTP`, `PORTAINER_PORT_HTTPS`, optional edge-agent port `8000` |
| Homepage | `homepage-compose.yml` | Required `HOMEPAGE_ALLOWED_HOSTS_CSV`; HTTP port when Caddy is disabled |
| Authentik | `authentik-compose.yml` | Generates `PG_PASS` and `AUTHENTIK_SECRET_KEY`; optional HTTP/HTTPS ports |
| Vaultwarden | `vaultwarden-compose.yml` | `VAULTWARDEN_DOMAIN`; requires HTTPS in practical use |
| AdGuard Home | `adguard-compose.yml` | DNS ports are template-defined; web ports are added by the script when Caddy is disabled |
| Immich | `immich-compose.yml` plus hardware extensions | Generates `DB_PASSWORD`; optionally includes ML; asks for transcoding and ML accelerators |
| Jellyfin | `jellyfin-compose.yml` | Generates `JELLYFIN_MEDIA_FOLDER`; maps host HTTP `8096` and HTTPS `8192` to container ports `8096` and `8920` when Caddy is disabled; Caddy proxies to port `8096` |
| Syncthing | `syncthing-compose.yml` | HTTP port when Caddy is disabled |
| Stirling PDF | `stirling-compose.yml` | HTTP port when Caddy is disabled; Caddy path also writes frontend/CORS variables |
| Home Assistant | `homeassistant-compose.yml` | Uses host networking; native HTTPS can use mounted `/ssl_certs` files and port `8123` |
| Wallos | `wallos-compose.yml` | Generates shared `TZ`; HTTP port when Caddy is disabled; Caddy proxies to port `80` |

## Configuration Invariants

- Every generated Compose file reads `stack.env` from its working directory. Do not move or rename `outfiles/stack.env` without updating the deployment commands and templates.
- `SERVER_DATA_FOLDER` is the persistent-data root and defaults to `/root/labdata`. Changing it changes bind-mount locations for all services.
- Caddy mode requires all participating Compose files to use the same external Docker network. The network name is stored as `NETWORK_NAME`.
- Caddy routes use Docker service names, not host ports. A route added to the Caddyfile must target a service and container port reachable on `app-net`.
- Home Assistant intentionally uses host networking. Prefer its native UI SSL/TLS configuration with the mounted `/ssl_certs` directory rather than adding a Caddy bridge route for its web UI.
- Generated output must be edited through the source template or `deploy.sh`, never manually as a permanent fix. Re-running the installer deletes generated YAML files and recreates `stack.env`.
- Secrets in `stack.env`, certificate private keys, and data directories are sensitive. Do not commit them or print them in diagnostics.
- Keep service names, Compose service keys, Caddy upstream names, container names, and generated filenames synchronized. The script currently relies on several of these names as string literals.

## Development Workflow

Before changing deployment behavior:

1. Read the relevant branch in `deploy.sh` and its Compose template together.
2. Check whether the change affects both Caddy and non-Caddy paths, and both automatic and Portainer modes.
3. Preserve the generated-output model: copy the template first, then mutate only the copy.
4. Keep prompts, environment variable names, Compose interpolation, and Caddy routes consistent.
5. Update this file when adding or removing a service, changing required tools, changing generated paths, or changing deployment order.

For a new service, add its Compose filename variable, menu entry, service-name mapping, copy/configuration block, non-Caddy port mutation if needed, Caddy domain prompt and route if supported, and deployment-order handling if it has startup dependencies. Also add its persistent-data and required-environment details to the service matrix above.

## Validation

Run these checks from a Linux shell in the repository root:

```bash
bash -n deploy.sh cert-manager.sh
shellcheck deploy.sh cert-manager.sh
```

When Docker and `yq` are available, validate templates without starting containers. Use a temporary output directory or a disposable checkout because the installer deletes and regenerates files:

```bash
yq -e '.' compose-files/*.yml
docker compose --env-file outfiles/stack.env -f outfiles/<generated-compose-file>.yml config
```

For changes to a service, inspect the generated YAML and run `docker compose ... config` for that service. Do not require a live deployment for syntax-only changes. A live test needs root, Docker, free host ports, network access for image pulls, and a disposable data directory.

## Known Hazards and Current Gaps

These are existing behaviors to preserve deliberately or fix explicitly with focused tests:

- AdGuard, Authentik, Immich, and Home Assistant have special networking or startup assumptions. Changes to their Compose files should be tested with the corresponding script branch, not only with generic YAML parsing.

## Style and Safety

- Use Bash-compatible syntax and quote paths and expansions, especially paths derived from user input.
- Prefer `[[ ... ]]`, explicit command checks, and clear nonzero failure handling for new code.
- Do not add secrets, generated certificates, `outfiles/`, or host-specific data to version control.
- Avoid changing image tags, container names, network names, or persistent mount paths casually; they can affect existing data and reverse-proxy routes.
- Keep changes focused. Do not reformat all Compose files or rewrite the interactive workflow when a local change is sufficient.