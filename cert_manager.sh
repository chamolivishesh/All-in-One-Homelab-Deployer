#!/usr/bin/env bash

set -e

DIR_CA="./ssl_ca"
DIR_SSL="./ssl_cert"
mkdir -p "$DIR_CA" "$DIR_SSL"

# Helper: Collect details for CA
get_ca_details() {
    read -p "Enter CA Common Name [My Local Root CA]: " CA_CN
    CA_CN=${CA_CN:-"My Local Root CA"}

    read -p "Enter CA Organization [My Local Org]: " CA_O
    CA_O=${CA_O:-"My Local Org"}

    read -p "Enter CA Country Code (2 letters) [US]: " CA_C
    CA_C=${CA_C:-"US"}

    read -p "Enter CA Validity in Days [3650]: " CA_DAYS
    CA_DAYS=${CA_DAYS:-3650}
}

# Helper: Collect details for SSL Certificate
get_cert_details() {
    read -p "Enter Server Domain / Common Name (e.g., 'localhost' or 'app.local'): " SSL_CN
    if [[ -z "$SSL_CN" ]]; then
        echo "❌ Error: Common Name is required for SSL certificate."
        return 1
    fi

    read -p "Enter Organization Name [My Local Org]: " SSL_O
    SSL_O=${SSL_O:-"My Local Org"}

    read -p "Enter Country Code (2 letters) [US]: " SSL_C
    SSL_C=${SSL_C:-"US"}

    read -p "Enter Certificate Validity in Days [365]: " SSL_DAYS
    SSL_DAYS=${SSL_DAYS:-365}

    read -p "Enter additional SANs (separated by spaces, e.g. 'IP:127.0.0.1 DNS:*.app.local'): " SAN_INPUT

    SANS="DNS:$SSL_CN"
    if [[ -n "$SAN_INPUT" ]]; then
        for item in $SAN_INPUT; do
            if [[ "$item" =~ ^(DNS:|IP:) ]]; then
                SANS="$SANS,$item"
            else
                SANS="$SANS,DNS:$item"
            fi
        done
    fi
}

# Core Function: Create Root CA
create_ca() {
    echo ""
    echo "--- Generating Local Root CA ---"
    get_ca_details

    CA_KEY="$DIR_CA/localCA.key"
    CA_CRT="$DIR_CA/localCA.crt"

    echo ""
    echo "[+] Generating CA Private Key (4096-bit)..."
    openssl genrsa -out "$CA_KEY" 4096

    echo "[+] Generating Self-Signed Root CA Certificate..."
    openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" -out "$CA_CRT" \
        -subj "/C=$CA_C/O=$CA_O/CN=$CA_CN"

    echo ""
    echo "✔ Root CA created successfully!"
    echo "  - CA Key: $CA_KEY"
    echo "  - CA Cert: $CA_CRT"
}

# Core Function: Create SSL Cert signed by CA
create_cert_with_ca() {
    local ca_key_path="$1"
    local ca_crt_path="$2"

    if [[ ! -f "$ca_key_path" || ! -f "$ca_crt_path" ]]; then
        echo "❌ Error: CA files not found!"
        echo "  Missing: $ca_key_path or $ca_crt_path"
        return 1
    fi

    echo ""
    echo "--- Generating SSL Certificate ---"
    get_cert_details || return 1

    SSL_KEY="$DIR_SSL/$SSL_CN.key"
    SSL_CSR="$DIR_SSL/$SSL_CN.csr"
    SSL_CRT="$DIR_SSL/$SSL_CN.crt"
    EXT_FILE="$DIR_SSL/$SSL_CN.ext"

    echo ""
    echo "[+] Generating Server Private Key (2048-bit)..."
    openssl genrsa -out "$SSL_KEY" 2048

    echo "[+] Generating Certificate Signing Request (CSR)..."
    openssl req -new -key "$SSL_KEY" -out "$SSL_CSR" \
        -subj "/C=$SSL_C/O=$SSL_O/CN=$SSL_CN"

    # SAN extension configuration block
    cat <<EOF > "$EXT_FILE"
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = $SANS
EOF

    echo "[+] Signing Server Certificate with CA..."
    openssl x509 -req -in "$SSL_CSR" -CA "$ca_crt_path" -CAkey "$ca_key_path" \
        -CAcreateserial -out "$SSL_CRT" -days "$SSL_DAYS" -sha256 \
        -extfile "$EXT_FILE"

    rm "$SSL_CSR" "$EXT_FILE"

    echo ""
    echo "✔ SSL Certificate generated successfully!"
    echo "  - Server Key:  $SSL_KEY"
    echo "  - Server Cert: $SSL_CRT"
}

# Main Menu Loop
while true; do
    echo ""
    echo "=========================================="
    echo "      SSL / CA Certificate Manager        "
    echo "=========================================="
    echo "1. Generate a self-signed CA (Same as option 2)"
    echo "2. Generate only a new Root CA"
    echo "3. Generate new CA & Cert signed by it"
    echo "4. Generate Cert with a pre-made CA"
    echo "5. Exit"
    echo "=========================================="
    read -p "Select an option [1-5]: " CHOICE

    case $CHOICE in
        1|2)
            create_ca
            ;;
        3)
            create_ca
            create_cert_with_ca "$DIR_CA/localCA.key" "$DIR_CA/localCA.crt"
            ;;
        4)
            read -p "Enter path to pre-made CA Certificate [$DIR_CA/localCA.crt]: " USER_CA_CRT
            USER_CA_CRT=${USER_CA_CRT:-"$DIR_CA/localCA.crt"}

            read -p "Enter path to pre-made CA Private Key [$DIR_CA/localCA.key]: " USER_CA_KEY
            USER_CA_KEY=${USER_CA_KEY:-"$DIR_CA/localCA.key"}

            create_cert_with_ca "$USER_CA_KEY" "$USER_CA_CRT"
            ;;
        5)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "❌ Invalid choice! Please select a number between 1 and 5."
            ;;
    esac
done
