#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
RED='\033[0;31m'

# Ensure script is run from the correct directory or handle paths relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Define the output env file
OUTFILES_LOCATION="$SCRIPT_DIR/outfiles"
ENV_FILE="$OUTFILES_LOCATION/stack.env"

rm -f $OUTFILES_LOCATION/*.yml
# Ensure the outfiles directory exists
mkdir -p "$OUTFILES_LOCATION"

# If the env file already exists, back it up with a unique timestamp
if [ -f "$ENV_FILE" ]; then
    TIMESTAMP=$(date +"%d-%m-%Y_%H-%M-%S")
    mkdir -p $OUTFILES_LOCATION/backup_env
    BACKUP_FILE="$OUTFILES_LOCATION/backup_env/stack_$TIMESTAMP.env"
    cp "$ENV_FILE" "$BACKUP_FILE"
    echo -e "${CYAN}--> Note: Existing stack.env backed up to: outfiles/backup_env/stack_$TIMESTAMP.env${NC}"
fi

# Initialize or overwrite the fresh env file for the current run
> "$ENV_FILE"
# Assigning variables for each compose files
AUTHENTIK_COMPOSE="authentik-compose.yml"
HOMEPAGE_COMPOSE="homepage-compose.yml"
IMMICH_COMPOSE="immich-compose.yml"
JELLYFIN_COMPOSE="jellyfin-compose.yml"
PIHOLE_COMPOSE="pihole-compose.yml"
PORTAINER_COMPOSE="portainer-compose.yml"
SYNCTHING_COMPOSE="syncthing-compose.yml"
VAULTWARDEN_COMPOSE="vaultwarden-compose.yml"
CADDY_COMPOSE="caddy-compose.yml"

echo
echo -e "${CYAN}=== Homelab Setup Menu ===${NC}"

# 0. Check if script is run with sudo/root privileges
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo -e "${RED}[Error] This script must be run with sudo privileges.${NC}"
    echo -e "Please run: \033[1msudo ./$(basename "$0")\033[0m"
    exit 1
fi

# 1. Automatic Docker & Docker Compose Check/Install
echo -e "\n${YELLOW}[Step 1] Checking Docker & Docker Compose...${NC}"

if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}Docker or Docker Compose not found. Starting automatic installation...${NC}"

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo -e "${RED}[Error] Cannot detect operating system.${NC}"
        exit 1
    fi

    if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
        echo -e "${CYAN}Detected supported OS: $OS. Installing Docker...${NC}"

        # Add Docker's official GPG key and repo
        apt-get update
        apt-get install -y ca-certificates curl yq
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/$OS/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Add the repository to Apt sources
        echo "Types: deb
URIs: https://download.docker.com/linux/$OS
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc" > /etc/apt/sources.list.d/docker.sources

        # Install Docker Engine and Compose plugin
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        echo -e "${GREEN}Docker installed successfully!${NC}"
    else
        echo -e "${RED}[Error] Unsupported Linux distribution ($OS).${NC}"
        echo -e "Please check official instructions at: ${CYAN}http://docs.docker.com/engine/install/${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Docker and Docker Compose are already installed!${NC}"
fi

echo

# 2. Network Creation
echo "# Network Configuration..." >> "$ENV_FILE"
echo -e "\n${YELLOW}[Step 2] Setting up Caddy Reverse Proxy for SSL implementation...${NC}"

echo -e "${CYAN}--> Note: Vaultwarden does not work at all without an SSL connection.${NC}"
read -p "Do you want to configure Caddy reverse proxy for SSL? (y/N): " run_caddy

execute_caddy=false

if [[ "$run_caddy" =~ ^[Yy]$ ]]; then
    read -p "Enter Docker Network Name (default: labnetwork): " net_name
    net_name=${net_name:-labnetwork}

    if docker network inspect "$net_name" >/dev/null 2>&1; then
        echo -e "${YELLOW}Network '$net_name' already exists. Skipping creation.${NC}"
        echo -e "NETWORK_NAME=$net_name\n" >> "$ENV_FILE"
        execute_caddy=true
    else
        echo -e "${CYAN}Creating Docker network '$net_name'...${NC}"
        if docker network create "$net_name"; then
            echo -e "${GREEN}Network '$net_name' created successfully!${NC}"
            echo -e "NETWORK_NAME=$net_name\n" >> "$ENV_FILE"
            execute_caddy=true
        else
            echo -e "${RED}[Error] Failed to create network.${NC}"
            exit 1
        fi
    fi

    echo -e "\n${CYAN}--> Note:At least one of the options is required for setting up SSL${NC} \n"
    echo "  1) Generate Self-Signed Certificate"
    echo "  2) Use an Existing CA to Create a New Certificate"
    echo "  3) Import Already Created SSL Certificate"
    echo "  4) Let Caddy Reverse Proxy Create a Certificate using its Internal CA"
    read -p "Select SSL option (1-4): " ssl_choice

    certdir=$OUTFILES_LOCATION/certs
    mkdir -p $certdir
    rm -f $certdir/*

    caddy_certificate_option=0
    case $ssl_choice in
        1)
            echo -e "${CYAN}--> Generating a Self-Signed SSL Certificate...${NC}"

            read -p "Enter common name or domain (e.g., localhost or example.local): " common_name
            common_name=${common_name:?Error: Common Name/Domain cannot be blank}

            # Generate a self-signed root CA / certificate with SAN support in one command
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$certdir/selfsigned.key" \
                -out "$certdir/selfsigned.crt" \
                -days 365 \
                -subj "/CN=$common_name" \
                -addext "subjectAltName=DNS:$common_name,IP:127.0.0.1"

            certkey="$certdir/selfsigned.key"
            certfile="$certdir/selfsigned.crt"

            if [ -f "$certdir/selfsigned.crt" ] && [ -f "$certdir/selfsigned.key" ]; then
                echo -e "${GREEN}Successfully generated self-signed certificate and private key under $certdir${NC}"
                caddy_certificate_option=1
            else
                echo -e "${RED}[Error] Failed to generate certificates.${NC}"
                exit 1
            fi

            sleep 0.1
            ;;
        2)
            echo -e "${CYAN}--> Generating a Certificate with an existing CA...${NC}"

            read -p "Enter path to your existing CA private key (.key): " ca_key
            read -p "Enter path to your existing CA certificate (.crt / .pem): " ca_cert
            read -p "Enter common name or domain (e.g., localhost or example.local): " common_name

            common_name=${common_name:?Error: Common Name/Domain cannot be blank}

            if [ -f "$ca_key" ] && [ -f "$ca_cert" ]; then

                echo -e "${CYAN}Generating private key and signing request...${NC}"
                openssl genpkey -algorithm RSA -out "$certdir/server.key"

                openssl req -new -key "$certdir/server.key" \
                    -out "$certdir/server.csr" \
                    -subj "/CN=$common_name" \
                    -addext "subjectAltName=DNS:$common_name,IP:127.0.0.1"

                echo -e "${CYAN}Signing the certificate with your existing CA...${NC}"
                openssl x509 -req -days 365 -in "$certdir/server.csr" \
                    -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
                    -out "$certdir/server.crt" \
                    -copy_extensions copyall

                # Cleanup intermediate CSR file
                rm -f "$certdir/server.csr"

            fi

            if [ -f "$certdir/server.crt" ] && [ -f "$certdir/server.key" ]; then
                echo -e "${GREEN}Certificate successfully created and signed by the CA under $certdir${NC}"
                caddy_certificate_option=2
            else
                echo -e "${RED}[Error] Provided CA key or certificate files could not be found.${NC}"
                exit 1
            fi

            sleep 0.1
            ;;
        3)
            echo -e "${CYAN}--> Importing existing SSL certificate...${NC}"
            read -p "Enter path to your certificate file (.crt / .pem): " cert_path
            read -p "Enter path to your private key file (.key): " key_path

            if [ -f "$cert_path" ] && [ -f "$key_path" ]; then
                echo -e "${GREEN}Certificates located. Ready to integrate into Caddy setup.${NC}"
                cp "$cert_path" $certdir/imported.crt
                cp "$key_path" $certdir/imported.key
                caddy_certificate_option=3
                sleep 0.1
            else
                echo -e "${RED}[Error] One or both certificate files could not be found.${NC}"
                exit 1
            fi
            ;;
        4)
            echo -e "${CYAN}--> Caddy will create a Self-Signed Certificate using its Internal CA...${NC}"
            caddy_certificate_option=4
            sleep 0.1
            ;;
        *)
            echo -e "${RED}Invalid option. Exiting...${NC}"
            exit 1
            ;;
    esac
fi

# 3. Service Selection Menu
echo -e "\n${YELLOW}[Step 3] Select Services to Install${NC}"
echo "Toggle your choices. Enter space-separated numbers (e.g., 0 for all, or 1 3 5) or press Enter to skip."
echo ""
echo "  0) Install All"
echo ""
echo "  1) Portainer     (Management UI)"
echo "  2) Homepage      (Dashboard)"
echo "  3) Authentik     (Identity Provider / SSO)"
echo "  4) Vaultwarden   (Password Manager)"
echo "  5) Pi-hole       (DNS Ad-blocker)"
echo "  6) Immich        (Photo Backup & ML)"
echo "  7) Jellyfin      (Media Server)"
echo "  8) Syncthing     (File Syncing)"
echo ""

read -p "Enter your choices (e.g., 0 or 1 2 5): " -a choices

# Map numbers to service names for friendly output (Sorted as requested)
declare -A service_names=(
    [1]="Portainer"
    [2]="Homepage"
    [3]="Authentik"
    [4]="Vaultwarden"
    [5]="Pi-hole"
    [6]="Immich"
    [7]="Jellyfin"
    [8]="Syncthing"
)

# Build a list of selected service names
selected_names=()

# Check if user chose '0' (Install All)
install_all=false
for choice in "${choices[@]}"; do
    if [ "$choice" -eq 0 ]; then
        install_all=true
        break
    fi
done

if [ "$install_all" = true ]; then
    # Automatically select all keys 1 through 8 in order
    for i in {1..8}; do
        selected_names+=("${service_names[$i]}")
    done
else
    for choice in "${choices[@]}"; do
        if [ -n "${service_names[$choice]}" ]; then
            selected_names+=("${service_names[$choice]}")
        fi
    done
fi

if [ ${#selected_names[@]} -gt 0 ]; then
    echo -e "${GREEN}Selected: ${selected_names[*]}${NC}"
else
    echo -e "${YELLOW}No services selected.${NC}"
    exit 1
fi

# 4. Service Configuration Setup
echo -e "\n${YELLOW}[Step 4] Setting configuration for selected services...${NC}"

# Helper function to prompt for variables
get_var() {
    local var_name=$1
    local default_val=$2
    local prompt_msg=$3
    read -p "$prompt_msg (default: $default_val): " input
    echo "${input:-$default_val}"
}

# --- Global Configs ---
echo -e "\n# Global Configuration..." >> "$ENV_FILE"

echo -e "\n--- Global Configuration ---"

SERVER_DATA_FOLDER=$(get_var "SERVER_DATA_FOLDER" "/root/labdata" "Enter container data folder path")
echo "SERVER_DATA_FOLDER=$SERVER_DATA_FOLDER" >> "$ENV_FILE"
echo -e "${CYAN}All your container files (configs, DBs) will be stored in $SERVER_DATA_FOLDER ${NC}"


if [[ " ${selected_names[*]} " =~ "Immich" ]] || [[ " ${selected_names[*]} " =~ "Pi-hole" ]] || [[ " ${selected_names[*]} " =~ "Syncthing" ]]; then
    echo "TZ=$(get_var "TZ" "Europe/London" "Enter Timezone (See \"https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List\")")" >> "$ENV_FILE"
fi

echo ""

# --- Portainer ---
echo -e "\n# Portainer Configuration..." >> "$ENV_FILE"

use_portainer_compose=false

if [[ " ${selected_names[*]} " =~ "Portainer" ]]; then

    cp "$SCRIPT_DIR/compose-files/$PORTAINER_COMPOSE" "$OUTFILES_LOCATION/"

    echo -e "\n--- Portainer Configuration ---"
    read -p "Do you want to use Portainer to manually deploy and manage your containers? (y/N): " portainer_choice
    if [[ "$portainer_choice" =~ ^[Yy]$ ]]; then
        use_portainer_compose=true
        echo -e "${CYAN}--> Note: Portainer mode enabled. This installer will generate the required environment configuration (stack.env) files only, without automatically deploying the containers via CLI. But of course, Portainer will be installed with open ports while Caddy Reverse Proxy will NOT!${NC}\n"
        execute_caddy=false
    fi

    if [[ "$execute_caddy" == "false" ]]; then
        echo "PORTAINER_PORT_HTTP=$(get_var "PORTAINER_PORT_HTTP" "8010" "Enter HTTP Port")" >> "$ENV_FILE"
        echo "PORTAINER_PORT_HTTPS=$(get_var "PORTAINER_PORT_HTTPS" "8011" "Enter HTTPS Port")" >> "$ENV_FILE"
    fi
    echo -e "${CYAN}Tip: Opening this port allows other remote containers (running the Portainer Edge Agent) to be managed by your Portainer container.${NC}"
    read -p "Do you want to enable Portainer Edge Agent support? (y/N) (Port 8000): " portainer_edge_choice

    if [[ "$portainer_edge_choice" =~ ^[Yy]$ ]]; then
        echo "PORTAINER_PORT_EDGE_AGENTS=8000" >> "$ENV_FILE"
    fi
fi

# --- Homepage ---
echo -e "\n# Homepage Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Homepage" ]]; then

    cp "$SCRIPT_DIR/compose-files/$HOMEPAGE_COMPOSE" "$OUTFILES_LOCATION/"

    echo -e "\n--- Homepage Configuration ---"
    if [[ "$execute_caddy" == "false" ]]; then
        echo "HOMEPAGE_PORT_HTTP=$(get_var "HOMEPAGE_PORT_HTTP" "80" "Enter HTTP Port")" >> "$ENV_FILE"
    fi
    echo -e "${CYAN}Tip: Homepage requires allowed hosts for its API proxy (which you will enter in the browser to access homepage dashboard). Must be comma-separated with NO spaces (e.g., mydomain.com,192.168.1.50 | May need port).${NC}"

    read -p "Enter allowed hosts (CSV, no spaces, required): " homepage_hosts

    if [ -z "$homepage_hosts" ]; then
        echo -e "${RED}[Error] Allowed hosts are required for Homepage. Exiting setup.${NC}"
        exit 1
    fi

    echo "HOMEPAGE_ALLOWED_HOSTS_CSV=${homepage_hosts}" >> "$ENV_FILE"
fi

# --- Authentik ---
echo -e "\n# Authentik Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Authentik" ]]; then

    cp "$SCRIPT_DIR/compose-files/$AUTHENTIK_COMPOSE" "$OUTFILES_LOCATION/"

    echo -e "\n--- Authentik Configuration ---"

    echo "AUTHENTIK_PG_DB=authentik	# pre-configured" >> "$ENV_FILE"
    echo "AUTHENTIK_PG_USER=authentik	# pre-configured" >> "$ENV_FILE"

    read -p "Enter custom DB password (leave blank to auto-generate: RECOMMENDED): " custom_pass
    echo "PG_PASS=${custom_pass:-$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | tr -d '\n' | head -c 36)}" >> "$ENV_FILE"
    echo -e "${GREEN}Password Generated... Saved to outfiles/stack.env${NC}"

    read -p "Enter custom Secret Key (leave blank to auto-generate: RECOMMENDED): " custom_key
    echo "AUTHENTIK_SECRET_KEY=${custom_key:-$(openssl rand -base64 80 | tr -dc 'a-zA-Z0-9' | tr -d '\n' | head -c 64)}" >> "$ENV_FILE"
    echo -e "${GREEN}Password Generated... Saved to outfiles/stack.env${NC}"

    if [[ "$execute_caddy" == "false" ]]; then
        echo "AUTHENTIK_PORT_HTTP=$(get_var "AUTHENTIK_PORT_HTTP" "8020" "Enter HTTP Port")" >> "$ENV_FILE"
        echo "AUTHENTIK_PORT_HTTPS=$(get_var "AUTHENTIK_PORT_HTTPS" "8021" "Enter HTTPS Port")" >> "$ENV_FILE"
    fi
fi

# --- Vaultwarden ---
echo -e "\n# Vaultwarden Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Vaultwarden" ]]; then

    cp "$SCRIPT_DIR/compose-files/$VAULTWARDEN_COMPOSE" "$OUTFILES_LOCATION/"

    echo -e "\n--- Vaultwarden Configuration ---"

    if [[ "$execute_caddy" == "false" ]]; then
        echo "VAULTWARDEN_PORT_HTTP=$(get_var "VAULTWARDEN_PORT_HTTP" "8030" "Enter HTTP Port")" >> "$ENV_FILE"
    fi

    echo -e "${CYAN}Tip: Vaultwarden requires a Domain (with port if not 443) which users will open to access the UI (e.g., https://mydomain.com \"NO IP\").${NC}"
    echo "VAULTWARDEN_DOMAIN=$(get_var "VAULTWARDEN_DOMAIN" "https://localhost" "Enter Domain(s) (comma-separated)")" >> "$ENV_FILE"
fi

# --- Pi-hole ---
echo -e "\n# Pi-Hole Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Pi-hole" ]]; then

    cp "$SCRIPT_DIR/compose-files/$PIHOLE_COMPOSE" "$OUTFILES_LOCATION/"

    echo -e "\n--- Pi-hole Configuration ---"
    read -p "Enter Pi-hole Web Admin Password (leave blank to auto-generate: RECOMMENDED): " pihole_pass

    # Generate a secure random password if left blank
    echo "PIHOLE_WEBSERVER_API_PASSWORD=${pihole_pass:-$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | tr -d '\n' | head -c 36)}" >> "$ENV_FILE"
    echo -e "${GREEN}Password Generated... Saved to outfiles/stack.env${NC}"

    read -p "Do you want to use Pi-Hole as a DHCP server? (y/N): " pihole_as_dhcp
    read -p "Do you want to use Pi-Hole as an NTP server? (y/N): " pihole_as_ntp

    if [[ "$execute_caddy" == "false" ]]; then
        echo "PIHOLE_PORT_HTTP=$(get_var "PIHOLE_PORT_HTTP" "8040" "Enter HTTP Port")" >> "$ENV_FILE"
        echo "PIHOLE_PORT_HTTPS=$(get_var "PIHOLE_PORT_HTTPS" "8041" "Enter HTTPS Port")" >> "$ENV_FILE"
    fi

fi

# --- Immich ---
echo -e "\n# Immich Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Immich" ]]; then

    cp "$SCRIPT_DIR/compose-files/$IMMICH_COMPOSE" "$OUTFILES_LOCATION/"

    cp "$SCRIPT_DIR/compose-files/hwaccel.transcoding.yml" "$OUTFILES_LOCATION/"

    echo -e "\n--- Immich Configuration ---"

    echo "IMMICH_DB_DATABASE_NAME=immich  # pre-configured" >> "$ENV_FILE"
    echo "IMMICH_DB_USERNAME=postgres	# pre-configured" >> "$ENV_FILE"

    echo "IMMICH_HW_TRANSCODING_SERVICE=$(get_var "IMMICH_HW_TRANSCODING_SERVICE" "cpu" "Enter Hardware Transcoding device [nvenc, quicksync, rkmpp, vaapi, vaapi-wsl]")" >> "$ENV_FILE"

    read -p "Do you want to create the Immich Machine Learning container? (Press 'n' if you will use remote ML? (y/N):" immich_ml_create
    if [[ "$immich_ml_create" =~ ^[yY]$ ]]; then

        cp "$SCRIPT_DIR/compose-files/hwaccel.ml.yml" "$OUTFILES_LOCATION/"

        ml_accel=$(get_var "IMMICH_HW_ACC_FOR_ML" "cpu" "Enter Hardware Acceleration device for Machine Learning [armnn, cuda, rocm, openvino, openvino-wsl, rknn]")

        echo "IMMICH_HW_ACC_FOR_ML=$ml_accel" >> "$ENV_FILE"

        # Check if the input/default value is NOT "cpu"
        if [[ "$ml_accel" != "cpu" ]]; then
            echo "IMMICH_ML_RELEASE=-${ml_accel%-wsl}" >>  "$ENV_FILE"
        fi
    fi

    echo "IMMICH_VERSION=$(get_var "IMMICH_VERSION" "release" "Enter Version")" >> "$ENV_FILE"
    echo "IMMICH_DB_STORAGE_TYPE=$(get_var "IMMICH_DB_STORAGE_TYPE" "SSD" "Enter Storage Type [HDD, SSD]")" >> "$ENV_FILE"

    read -p "Enter custom DB password (leave blank to auto-generate:RECOMMENDED): " custom_immich_pass
    echo "DB_PASSWORD=${custom_immich_pass:-$(openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | tr -d '\n' | head -c 36)}" >> "$ENV_FILE"
    echo -e "${GREEN}Password Generated... Saved to outfiles/stack.env${NC}"

    if [[ "$execute_caddy" == "false" ]]; then
        echo "IMMICH_PORT_HTTP=$(get_var "IMMICH_PORT_HTTP" "8050" "Enter HTTP Port")" >> "$ENV_FILE"
    fi
fi

# --- Jellyfin ---
echo -e "\n# Jellyfin Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Jellyfin" ]]; then

    cp "$SCRIPT_DIR/compose-files/$JELLYFIN_COMPOSE" "$OUTFILES_LOCATION/"

    echo -e "\n--- Jellyfin Configuration ---"
    echo "WORK IN PROGRESS..."
fi

# --- Syncthing ---
echo -e "\n# Syncthing Configuration..." >> "$ENV_FILE"

if [[ " ${selected_names[*]} " =~ "Syncthing" ]]; then

    cp "$SCRIPT_DIR/compose-files/$SYNCTHING_COMPOSE" "$OUTFILES_LOCATION/"

    if [[ "$execute_caddy" == "false" ]]; then
        echo -e "\n--- Syncthing Configuration ---"
        echo "SYNCTHING_PORT_HTTP=$(get_var "SYNCTHING_PORT_HTTP" "8070" "Enter HTTP Port")" >> "$ENV_FILE"
    fi
fi

echo ""
echo -e "${GREEN}Environment file has been created: $ENV_FILE${NC}"
echo -e "${RED}Please keep the environment file somewhere safe always if you DO NOT want to lose your data!${NC}"
echo ""
echo -e "${GREEN}Ready to deploy containers...${NC}"

echo ""

# Code to edit outfiles before deploying containers
if [[ "$execute_caddy" == "false" ]]; then

    # Portainer
    if [ -f "$OUTFILES_LOCATION/$PORTAINER_COMPOSE" ]; then
        yq -iy '.services.portainer.ports += ["${PORTAINER_PORT_HTTP:-}:9000", "${PORTAINER_PORT_HTTPS:-}:9443"]' "$OUTFILES_LOCATION/$PORTAINER_COMPOSE"
        # If Edge Agents enabled at 8000
        if [[ "$portainer_edge_choice" =~ ^[yY]$ ]]; then
            yq -iy '.services.portainer.ports += ["${PORTAINER_PORT_EDGE_AGENTS:-}:8000"]' "$OUTFILES_LOCATION/$PORTAINER_COMPOSE"
        fi
    fi

    # Homepage
    if [ -f "$OUTFILES_LOCATION/$HOMEPAGE_COMPOSE" ]; then
        yq -iy '.services.homepage.ports += ["${HOMEPAGE_PORT_HTTP:-}:3000"]' "$OUTFILES_LOCATION/$HOMEPAGE_COMPOSE"
    fi

    # Authentik
    if [ -f "$OUTFILES_LOCATION/$AUTHENTIK_COMPOSE" ]; then
        yq -iy '.services.server.ports += ["${AUTHENTIK_PORT_HTTP:-}:9000", "${AUTHENTIK_PORT_HTTPS:-}:9443"]' "$OUTFILES_LOCATION/$AUTHENTIK_COMPOSE"
    fi

    # Vaultwarden
    if [ -f "$OUTFILES_LOCATION/$VAULTWARDEN_COMPOSE" ]; then
        yq -iy '.services.vaultwarden.ports += ["${VAULTWARDEN_PORT_HTTP:-127.0.0.1:8000}:80"]' "$OUTFILES_LOCATION/$VAULTWARDEN_COMPOSE"
    fi

    # Pi-hole
    if [ -f "$OUTFILES_LOCATION/$PIHOLE_COMPOSE" ]; then
        yq -iy '.services.pihole.ports += ["${PIHOLE_PORT_HTTP:-}:80/tcp", "${PIHOLE_PORT_HTTPS:-}:443/tcp"]' "$OUTFILES_LOCATION/$PIHOLE_COMPOSE"

        # If using Pi-Hole as DHCP server, open 67 UDP
        if [[ "$pihole_as_dhcp" =~ ^[yY]$ ]]; then
            yq -iy '.services.pihole.ports += ["67:67/udp"]' "$OUTFILES_LOCATION/$PIHOLE_COMPOSE"
        fi

        # If using Pi-Hole as NTP server, open 123 UDP
        if [[ "$pihole_as_ntp" =~ ^[yY]$ ]]; then
            yq -iy '.services.pihole.ports += ["123:123/udp"]' "$OUTFILES_LOCATION/$PIHOLE_COMPOSE"
        fi
    fi

    # Immich
    if [ -f "$OUTFILES_LOCATION/$IMMICH_COMPOSE" ]; then
        yq -iy '.services."immich-server".ports += ["${IMMICH_PORT_HTTP:-}:2283"]' "$OUTFILES_LOCATION/$IMMICH_COMPOSE"
    fi

    # Jellyfin
    echo -e "${RED}JELLYFIN  WIP\n${NC}"

    # Syncthing
    if [ -f "$OUTFILES_LOCATION/$SYNCTHING_COMPOSE" ]; then
        yq -iy '.services.syncthing.ports += ["${SYNCTHING_PORT_HTTP:-}:8384"]' "$OUTFILES_LOCATION/$SYNCTHING_COMPOSE"
    fi

elif [[ "$execute_caddy" == "true" ]]; then

    # Add `external: true` if network was created
    yq -iy '.networks."app-net".external = true' $OUTFILES_LOCATION/*compose.yml
fi

# Immich: Remove ML from compose if not present
if [ -f "$OUTFILES_LOCATION/$IMMICH_COMPOSE" ]; then

    # If ML is not being installed, remove `immich-machine-learning` from compose file
    if [[ ! "$immich_ml_create" =~ ^[yY]$ ]]; then
        yq -iy 'del(.services."immich-machine-learning")' "$OUTFILES_LOCATION/$IMMICH_COMPOSE"
    fi
fi

# Requesting information for Caddy Reverse Proxy
if [[ "$execute_caddy" == "true" ]]; then
    echo -e "${YELLOW}Enter Domains for the following:\n${NC}"

    if [ -f "$OUTFILES_LOCATION/$HOMEPAGE_COMPOSE" ]; then
        read -r -e -p " Homepage (default: 'server.home'): " caddy_homepage
        caddy_homepage=${caddy_homepage:-server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$AUTHENTIK_COMPOSE" ]; then
        read -r -e -p " Authentik (default: 'auth.server.home'): " caddy_authentik
        caddy_authentik=${caddy_authentik:-auth.server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$PORTAINER_COMPOSE" ]; then
        read -r -e -p " Portainer (default: 'portainer.server.home'): " caddy_portainer
        caddy_portainer=${caddy_portainer:-portainer.server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$PIHOLE_COMPOSE" ]; then
        read -r -e -p " Pi-hole (default: 'dns.server.home'): " caddy_pihole
        caddy_pihole=${caddy_pihole:-dns.server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$VAULTWARDEN_COMPOSE" ]; then
        read -r -e -p " Vaultwarden (default: 'vault.server.home'): " caddy_vaultwarden
        caddy_vaultwarden=${caddy_vaultwarden:-vault.server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$IMMICH_COMPOSE" ]; then
        read -r -e -p " Immich (default: 'immich.server.home'): " caddy_immich
        caddy_immich=${caddy_immich:-immich.server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$JELLYFIN_COMPOSE" ]; then
        read -r -e -p " Jellyfin (default: 'jellyfin.server.home'): " caddy_jellyfin
        caddy_jellyfin=${caddy_jellyfin:-jellyfin.server.home}
    fi

    if [ -f "$OUTFILES_LOCATION/$SYNCTHING_COMPOSE" ]; then
        read -r -e -p " Syncthing (default: 'sync.server.home'): " caddy_syncthing
        caddy_syncthing=${caddy_syncthing:-sync.server.home}
    fi
fi

echo ""

# Create caddy files before deploying any container (so that if user wants to build using portainer, they have Caddy files ready
if [[ "$execute_caddy" == "true" ]]; then
    # Preparing Caddy Compose file to outfiles folder
    cp $SCRIPT_DIR/compose-files/$CADDY_COMPOSE $OUTFILES_LOCATION

    CADDY_DEST_DIR="${SERVER_DATA_FOLDER:-/root/labdata}/caddy/certs"
    mkdir -p "$CADDY_DEST_DIR"

    echo -e "{\n    # Optional global options here\n}\n" > ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile



    # Initialize file path variables
    caddy_key_file=""
    caddy_cert_file=""

    # Determine key and certificate filenames based on the selected option
    case $caddy_certificate_option in
        1)
            caddy_key_file="selfsigned.key"
            caddy_cert_file="selfsigned.crt"
            ;;
        2)
            caddy_key_file="server.key"
            caddy_cert_file="server.crt"
            ;;
        3)
            caddy_key_file="imported.key"
            caddy_cert_file="imported.crt"
            ;;
    esac

    if [ "$caddy_certificate_option" -ge 1 ] && [ "$caddy_certificate_option" -le 3 ]; then
        # Ensure CERT_DIR points to wherever your temporary or generated files are stored
        cp "$certdir"/* "$CADDY_DEST_DIR/"

        echo -e "(tls_settings) {\n    tls /etc/caddy/certs/$caddy_cert_file /etc/caddy/certs/$caddy_key_file\n}\n" >> "${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile"

    elif [ "$caddy_certificate_option" -eq 4 ]; then
        echo -e "(internal_tls) {\n    tls internal\n}\n" >> "${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile"
    fi

    if [[ " ${selected_names[*]} " =~ "Homepage" ]]; then
        echo -e "$caddy_homepage {\n    import tls_settings\n    reverse_proxy homepage:3000\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    if [[ " ${selected_names[*]} " =~ "Authentik" ]]; then
        echo -e "$caddy_authentik {\n    import tls_settings\n    reverse_proxy authentik-stack-server-1:9000\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    if [[ " ${selected_names[*]} " =~ "Portainer" ]]; then
        echo -e "$caddy_portainer {\n    import tls_settings\n    reverse_proxy portainer:9000\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    if [[ " ${selected_names[*]} " =~ "Pi-hole" ]]; then
        echo -e "$caddy_pihole {\n    import tls_settings\n    reverse_proxy pihole:80\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    if [[ " ${selected_names[*]} " =~ "Vaultwarden" ]]; then
        echo -e "$caddy_vaultwarden {\n    import tls_settings\n    reverse_proxy vaultwarden:80\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    if [[ " ${selected_names[*]} " =~ "Immich" ]]; then
        echo -e "$caddy_immich {\n    import tls_settings\n    reverse_proxy immich-server:2283\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    if [[ " ${selected_names[*]} " =~ "Jellyfin" ]]; then
        echo -e "${RED}JELLYFIN WIP${NC}"
    fi

    if [[ " ${selected_names[*]} " =~ "Syncthing" ]]; then
        echo -e "$caddy_syncthing {\n    import tls_settings\n    reverse_proxy syncthing:8384\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile
    fi

    cp ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile $OUTFILES_LOCATION/Caddyfile
    echo -e "${GREEN}Caddyfile created...${NC}"
fi


# If user wants to user portainer manually, composing only Portainer.
if [[ "$use_portainer_compose" == "true" ]]; then
    echo -e "${CYAN}You can use the outfiles/stack.env to create containers through portainer.${NC}"
    echo -e "${CYAN}Additionally, you can find 'Caddyfile' and SSL Certificates in '$SERVER_DATA_FOLDER/caddy' directory.${NC}"
    echo
    read -e -r -p "${YELLOW}Start building Portainer?${NC}" build_portainer

    if [[ ! "$build_portainer" =~ ^[yY]$ ]]; then
        echo -e "${CYAN}Exiting...${NC}"

        exit 0
    fi
else
    # --- Final Question 1 ---
    read -r -p "$(echo -e "${YELLOW}Do you want to start all containers at once? (NOT RECOMMENDED!!!) [other option: one-by-one, select 'y' if you have a powerful server, still things could break] [y/N] ${NC}")" all_at_once

    # Check if user said yes
    if [[ "$all_at_once" == "y" || "$all_at_once" == "Y" ]]; then
       ONE_BY_ONE=""
        echo -e "\n${CYAN}This will be done by the time you finish your poop, so don't even bother getting comfortable.${NC}"
    else
        ONE_BY_ONE="--wait"
        echo -e "\n${CYAN}This will take time. If we don't complete it in five minutes, assume I've unplugged everything and started staring at a wall.${NC}"
    fi

    # --- Final Question 2 ---
    read -r -p "$(echo -e "${YELLOW}Ready to start composing docker containers? [y/N] ${NC}")" start_compose

    # Check if user said 'y' or 'Y'
    if [[ ! "$start_compose" =~ ^[yY]$ ]]; then
        echo
        echo -e "${CYAN}Exiting... File 'stack.env' saved in outfiles folder."
        echo -e "You can start the containers manually on either Portainer (if installed) or using the following command:${NC}"
        echo -e "\t${GREEN}docker compose --env-file $OUTFILES_LOCATION/stack.env -f $OUTFILES_LOCATION/<compose_file> up -d $ONE_BY_ONE"
        exit 0
    fi
fi

# 5. Deploying Docker containers using a clean loop
echo -e "\n${YELLOW}[Step 5] Deploying Container Stacks...${NC}"

# If Portainer mode, compose only portainer
if [[ "$use_portainer_compose" =~ ^[yY]$ ]]; then
    docker compose --env-file $OUTFILES_LOCATION/stack.env -f "$OUTFILES_LOCATION/$PORTAINER_COMPOSE" up -d
    echo ""
    echo -e "\n${GREEN}Done... Hopefully :)${NC}"
    echo -e "${GREEN}All relevant files created in $OUTFILES_LOCATION.${NC}"

    exit 0
fi

# a. Start immich-compose.yml first
if [ -f "$OUTFILES_LOCATION/immich-compose.yml" ]; then
    docker compose --env-file $OUTFILES_LOCATION/stack.env -f "$OUTFILES_LOCATION/immich-compose.yml" up -d $ONE_BY_ONE
fi

# b. Process all other compose files sequentially (case-insensitive, excluding immich and caddy)
for i in $(ls $OUTFILES_LOCATION | grep -i compose | grep -vi immich | grep -vi caddy)
do
    docker compose --env-file $OUTFILES_LOCATION/stack.env -f "$OUTFILES_LOCATION/$i" up -d $ONE_BY_ONE
done

# 6. Deploying Caddy Reverse Proxy with SSL
if [[ "$execute_caddy" == "true" ]]; then

    echo -e "\n${YELLOW}[Step 6] Deploying Caddy Reverse Proxy with SSL...${NC}"
    docker compose --env-file $OUTFILES_LOCATION/stack.env -f "$OUTFILES_LOCATION/$CADDY_COMPOSE" up -d $ONE_BY_ONE

fi

echo -e "\n${GREEN}Done... Hopefully :)${NC}"
echo -e "\n${CYAN}--> Note: Authentik and Immich compose are notorious while composing. If any of them cause problems, use one of the following commands to delete them and compose again (BEFORE RUNNING THIS SCRIPT, OTHERWISE RELEVANT INFORMATION WILL BE DELETED!${NC}"
echo ""
echo -e "\t${GREEN}docker rm authentik-stack-server-1 authentik-stack-worker-1 authentik-stack-postgresql-1${NC}"
echo -e "\tOR"
echo -e "\t${GREEN}docker rm immich-server immich-postgres immich-machine-learning immich-redis${NC}"
echo ""
echo -e "${CYAN}Edit the Caddyfile with this command (if selected Caddy Reverse Proxy earlier):\n${NC}"
echo -e "${GREEN}  For Immich:\n\techo -e "$caddy_immich {\n    import tls_settings\n    reverse_proxy immich-server:2283\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile"
echo -d "${GREEN}  For Authentik:\n\techo -e "$caddy_authentik {\n    import tls_settings\n    reverse_proxy authentik-stack-server-1:9000\n}\n" >> ${SERVER_DATA_FOLDER:-/root/labdata}/caddy/Caddyfile\n${NC}"
echo -e "${CYAN}Then to compose:\n${NC}"
echo -e "\t${GREEN}docker compose --env-file $OUTFILES_LOCATION/stack.env -f \"$OUTFILES_LOCATION/$AUTHENTIK_COMPOSE\" up -d $ONE_BY_ONE${NC}"
echo -e "\tOR"
echo -e "\t${GREEN}docker compose --env-file $OUTFILES_LOCATION/stack.env -f \"$OUTFILES_LOCATION/$IMMICH_COMPOSE\" up -d $ONE_BY_ONE${NC}"
echo ""
