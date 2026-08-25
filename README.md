# All-in-One Homelab Deployer

An interactive, menu-driven Bash toolkit designed to automate the deployment, networking, SSL management, and configuration of popular self-hosted homelab services using Docker Compose and Caddy Reverse Proxy.

---

## Features

* **Automated Environment Checks:** Automatically detects Ubuntu/Debian host OS and installs Docker, Docker Compose, and required CLI tools (`yq`, `openssl`).
* **Dynamic SSL & Reverse Proxy:** Full support for Caddy reverse proxy integrated with multiple SSL options (Self-signed, Custom CA signing, Imported certs, or Caddy's internal CA).
* **Standalone Certificate Manager:** Included dedicated utility script for creating, managing, and signing SSL certificates and custom Root CAs.
* **Modular Service Selection:** Choose specific services to install or deploy the entire stack at once.
* **Env Backup System:** Automatically backs up previous `stack.env` configurations with timestamping before writing new runs.
* **Portainer-Only Deployment Mode:** Option to generate configurations only and hand off stack management to a lightweight Portainer UI instance.

---

## Included Scripts

### 1. Main Deployment Script (`deploy.sh`)
Handles OS package setup, network creation, Docker stack selection, `.env` file generation, Caddyfile generation, and automated container orchestration.

### 2. Standalone SSL / CA Certificate Manager (`cert_manager.sh`)
An interactive CLI tool to manage custom Public Key Infrastructure (PKI) for your local network. Allows complete customization of certificate metadata.

**Supported Metadata Fields:**
* **Common Name (CN):** Domain or FQDN (e.g., `*.home.lab` or `vault.local`)
* **Organization (O):** Custom Org Name
* **Organizational Unit (OU):** Department / Division
* **Country (C), State (S), Locality (L):** Geographic identity parameters
* **Validity Period:** Configurable expiration (in days)

**Menu Capabilities:**
1. **Generate Self-Signed CA & Certificate:** Quickly provisions a root authority and an initial server certificate in a single flow.
2. **Generate Only a New Root CA:** Creates an isolated `rootCA.crt` and `rootCA.key` pair to import into host browsers/trust stores.
3. **Generate New CA & Signed Cert:** Spins up a fresh Root CA and immediately issues a signed domain certificate against it.
4. **Generate Cert with Pre-made CA:** Signs new domain/service certificates using your existing Root CA key and certificate.

---

## Supported Services

| Service | Category | Default Internal Port |
| :--- | :--- | :--- |
| **Portainer** | Container Management | 9000 / 9443 |
| **Homepage** | Application Dashboard | 3000 |
| **Authentik** | Identity & Access (SSO) | 9000 / 9443 |
| **Vaultwarden** | Password Management | 80 |
| **Pi-hole** | DNS & Ad-blocking | 80 / 443 |
| **Immich** | Photo & Video Backup | 2283 |
| **Jellyfin** | Media Server | *WIP* |
| **Syncthing** | File Synchronization | 8384 |

---

## Prerequisites

* **Operating System:** Ubuntu or Debian-based Linux distribution.
* **Privileges:** Root or `sudo` access required.
* **Directory Structure:** Make sure your compose files are stored in a relative `./compose-files/` directory before running the setup script.

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

3. **Run the certificate manager (Optional - pre-deployment):**
   ```bash
   sudo ./cert_manager.sh
   ```

4. **Run the main deployment menu:**
   ```bash
   sudo ./deploy.sh
   ```

---

## Usage Flow

1. **Prerequisites & Privileges:** Validates execution via `sudo` and checks for existing Docker installations.
2. **Reverse Proxy & SSL Setup:** Prompts whether to isolate container traffic behind a single Caddy instance on a shared Docker bridge network (`labnetwork`).
3. **Interactive Service Selection:** Choose services via a space-separated numerical menu (e.g., `1 3 5` or `0` for all).
4. **Environment Generation:** Interactively configures paths, secure secrets, hardware acceleration flags (e.g., GPU transcoding for Immich), and writes out to `./outfiles/stack.env`.
5. **Deployment:** Provisions services sequentially or in batch using `docker compose`.

---

## Output File Architecture

Generated deployment configurations live in `./outfiles/`:

```text
outfiles/
├── backup_env/         # Automatic timestamped env backups
├── certs/              # SSL Keys, CSRs, and Certificates generated or imported
├── Caddyfile           # Dynamic Caddy configuration
├── stack.env           # Conserved variables for all services
└── *.yml               # Mutated compose files ready for deployment
```

> **Warning:** Never delete or overwrite `outfiles/stack.env` without a backup if you plan to update or re-compose existing volume paths.
