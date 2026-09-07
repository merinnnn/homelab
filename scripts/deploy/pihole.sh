#!/bin/bash
# Deploy Pi-hole LXC Container on vmbr0
set -euo pipefail

CT_ID="${CT_ID:-100}"
CT_IP="${CT_IP:-192.168.1.53}"
CT_PASS="${CT_PASS:-ChangeMe123!}"

echo "Deploying Pi-hole (CT $CT_ID)"

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
    echo "Downloading Debian 12 template..."
    mkdir -p /var/lib/vz/template/cache
    wget -q --show-progress -O "$TEMPLATE_PATH" "https://download.proxmox.com/images/system/$TEMPLATE"
fi

pct create $CT_ID "local:vztmpl/$TEMPLATE" \
    --hostname pihole \
    --password "$CT_PASS" \
    --storage local \
    --disk0 size=4G \
    --memory 512 \
    --cores 1 \
    --net0 name=eth0,bridge=vmbr0,gw=192.168.1.1,ip=$CT_IP/24,type=veth \
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
echo "  Password:      $CT_PASS"
echo "  Next Step: Set your router's DNS to $CT_IP"
echo "========================================="