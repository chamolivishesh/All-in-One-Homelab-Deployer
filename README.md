# All-in-One Homelab Deployer

An interactive Bash toolkit that generates Docker Compose configurations for a small homelab stack. It can optionally configure Caddy as an HTTPS reverse proxy and start the selected services.

---

## Features

* **Environment Checks:** Checks for Docker Compose v2, OpenSSL, and `yq`; on Ubuntu or Debian it can install missing packages.
* **Optional Caddy Reverse Proxy:** Creates or reuses an external Docker network and supports self-signed certificates, certificates signed by an existing CA, imported certificates, or Caddy's internal CA.
* **Standalone Certificate Manager:** Creates local CAs, server certificates, and PKCS#12 (`.pfx`) files.
* **Modular Service Selection:** Select individual services or all currently advertised services.
* **Environment Backups:** Backs up an existing `outfiles/stack.env` before generating a new one.
* **Portainer Mode:** Generates the selected Compose files and supporting artifacts for manual deployment through Portainer.

---

## Included Scripts

### 1. Main Deployment Script (`deploy.sh`)
Handles OS package setup, network creation, Docker stack selection, `.env` file generation, Caddyfile generation, and automated container orchestration.

### 2. Standalone SSL / CA Certificate Manager (`cert_manager.sh`)
An interactive CLI tool for managing local PKI. It stores CA files in `ssl_ca/`, server certificates in `ssl_cert/`, and PKCS#12 files in `ssl_cert_pfx/`.

**Supported Metadata Fields:**
* **Common Name (CN):** Domain or FQDN
* **Organization (O):** Custom organization name
* **Country (C):** Two-letter country code
* **Validity Period:** Configurable expiration in days
* **Subject Alternative Names:** Additional DNS names or IP addresses for server certificates

**Menu Capabilities:**
1. **Create a self-signed SSL certificate:** Creates a local CA key and certificate.
2. **Create a new CA:** Creates a CA key and certificate.
3. **Create a new CA and SSL certificate:** Creates a CA and signs a server certificate with it.
4. **Create an SSL certificate with an existing CA:** Signs a server certificate using supplied CA files.
5. **Convert existing files to PKCS#12:** Converts a `.crt` and `.key` pair to `.pfx`.

---

## Supported Services

| Menu | Service | Purpose | Container ports |
| :---: | :--- | :--- | :--- |
| 1 | Portainer | Container management | 9000 / 9443; optional edge agent 8000 |
| 2 | Homepage | Dashboard | 3000 |
| 3 | Authentik | Identity provider / SSO | 9000 / 9443 |
| 4 | Vaultwarden | Password management | 80 |
| 5 | AdGuard Home | DNS and ad blocking | 53, 80, 443, 3000 |
| 6 | Immich | Photo and video backup | 2283 |
| 7 | Jellyfin | Media server | 8096 / 8920 |
| 8 | Syncthing | File synchronization | 8384 |
| 9 | Stirling PDF | PDF editing and management | 8080 |
| 10 | Home Assistant | Home automation | 8123 using host networking |
| 11 | Wallos | Subscription tracking | 80 |

Enter `0` to select all services. Immich can optionally include its Machine Learning service and hardware acceleration extensions.

---

## Prerequisites

* **Operating System:** Linux host, or a Linux environment such as WSL. The scripts are not native PowerShell scripts.
* **Distribution:** Ubuntu or Debian if automatic package installation is required.
* **Privileges:** Root or `sudo` access required by `deploy.sh`.
* **Required tools:** Bash, Docker Engine, Docker Compose v2, OpenSSL, and `yq`.
* **Repository layout:** Run the scripts from this repository so `compose-files/` is available.

---

## Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-username/all-in-one-homelab-deployer.git
   cd all-in-one-homelab-deployer
   ```

2. **Make the scripts executable:**
   ```bash
   chmod +x deploy.sh cert_manager.sh
   ```

3. **Run the certificate manager (optional):**
   ```bash
   ./cert_manager.sh
   ```

4. **Run the main deployment menu:**
   ```bash
   sudo ./deploy.sh
   ```

---

## Usage Flow

1. **Prerequisites and privileges:** `deploy.sh` requires root and checks Docker Compose v2, OpenSSL, and `yq`.
2. **Network and TLS:** Optionally creates or reuses the external Docker network named by `NETWORK_NAME`, then configures one of four TLS modes for Caddy.
3. **Service selection:** Enter space-separated menu numbers, such as `1 3 5`, or `0` for all services.
4. **Configuration:** Sets the shared data directory, timezone where needed, service ports, generated secrets, domains, and Immich acceleration options.
5. **Generated output:** Copies selected templates to `outfiles/`, writes `outfiles/stack.env`, and mutates generated Compose files with `yq`.
6. **Deployment:** Starts Caddy and the selected services in dependency-aware order, or stops after generation when requested. In Portainer mode, only Portainer is started; the remaining stacks are handed off for manual management.

When Caddy is disabled, the script adds host port mappings to the generated files. When Caddy is enabled, participating Compose files use the shared external network and Caddy routes to container service names and ports. Home Assistant intentionally uses host networking.

---

## Output File Architecture

Generated deployment configurations live in `./outfiles/`:

```text
outfiles/
├── backup_env/         # Timestamped stack.env backups
├── certs/              # Certificates and keys generated or imported for Caddy
├── Caddyfile           # Generated Caddy configuration, when enabled
├── stack.env           # Shared generated environment file
└── *.yml               # Selected and mutated Compose files
```

Generated files are disposable output. Permanent changes belong in `deploy.sh` or the source templates under `compose-files/`. Re-running the installer deletes generated YAML files and recreates `stack.env`, while backing up an existing environment file first.

Keep `stack.env`, private keys, certificates, and service data private. Do not commit `outfiles/`, generated secrets, certificates, or data directories.

## Validation

Run these checks from a Linux shell in the repository root:

```bash
bash -n deploy.sh cert_manager.sh
shellcheck deploy.sh cert_manager.sh
```

When Docker and `yq` are available, validate the Compose templates without starting containers:

```bash
yq -e '.' compose-files/*.yml
docker compose --env-file outfiles/stack.env -f outfiles/<generated-compose-file>.yml config
```
