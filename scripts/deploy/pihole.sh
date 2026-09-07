#!/bin/bash
# Deploy Pi-hole LXC Container on vmbr0
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root."
   exit 1
fi

CT_ID="${CT_ID:-100}"
CT_IP="${CT_IP:-}"
CT_PASS="${CT_PASS:-}"

# Enforce explicit configuration
if [[ -z "$CT_IP" || -z "$CT_PASS" ]]; then
    echo "ERROR: CT_IP and CT_PASS environment variables are required."
    echo "Example: sudo CT_IP=192.168.1.53 CT_PASS=MySecretPass bash $0"
    exit 1
fi

# Auto-detect gateway from current default route
GATEWAY=$(ip route show default | awk '{print $3}' | head -n 1)
if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: Could not auto-detect default gateway."
    echo "Please ensure your Proxmox host has internet access."
    exit 1
fi

echo "=== Deploying Pi-hole (CT $CT_ID) ==="
echo "  IP:       $CT_IP"
echo "  Gateway:  $GATEWAY"
echo "  Password: $CT_PASS"
echo ""

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
    echo "Downloading Debian 12 template..."
    mkdir -p /var/lib/vz/template/cache
    wget -q --show-progress -O "$TEMPLATE_PATH" "https://download.proxmox.com/images/system/$TEMPLATE"
fi

if pct status $CT_ID &>/dev/null; then
    echo "ERROR: Container $CT_ID already exists."
    exit 1
fi

pct create $CT_ID "local:vztmpl/$TEMPLATE" \
    --hostname pihole \
    --password "$CT_PASS" \
    --storage local \
    --disk0 size=4G \
    --memory 512 \
    --cores 1 \
    --net0 name=eth0,bridge=vmbr0,gw=$GATEWAY,ip=$CT_IP/24,type=veth \
    --nameserver 1.1.1.1 \
    --ostype debian \
    --onboot 1 \
    --features nesting=1,keyctl=1 \
    --unprivileged 1

echo "Container created. Starting..."
pct start $CT_ID
sleep 10

echo "Installing Pi-hole..."
pct exec $CT_ID -- bash -c "
    curl -sSL https://install.pi-hole.net | PIHOLE_SKIP_OS_CHECK=true bash -s -- \
        --unattended \
        --upstream-dns '1.1.1.1' \
        --admin-password '$CT_PASS'
"

echo "========================================="
echo "Pi-hole deployed successfully!"
echo "  Web Interface: http://$CT_IP/admin"
echo "========================================="