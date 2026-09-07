#!/bin/bash
# Deploy Docker Host LXC Container on vmbr0
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root."
   exit 1
fi

CT_ID="${CT_ID:-101}"
CT_IP="${CT_IP:-}"
CT_PASS="${CT_PASS:-}"

# Enforce explicit configuration
if [[ -z "$CT_IP" || -z "$CT_PASS" ]]; then
    echo "ERROR: CT_IP and CT_PASS environment variables are required."
    echo "Example: sudo CT_IP=192.168.1.54 CT_PASS=MySecretPass bash $0"
    exit 1
fi

# Auto-detect gateway from current default route
GATEWAY=$(ip route show default | awk '{print $3}' | head -n 1)
if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: Could not auto-detect default gateway."
    exit 1
fi

echo "=== Deploying Docker Host (CT $CT_ID) ==="
echo "  IP:       $CT_IP"
echo "  Gateway:  $GATEWAY"
echo "  Password: $CT_PASS"
echo ""

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

if pct status $CT_ID &>/dev/null; then
    echo "ERROR: Container $CT_ID already exists."
    exit 1
fi

pct create $CT_ID "local:vztmpl/$TEMPLATE" \
    --hostname docker-host \
    --password "$CT_PASS" \
    --storage local \
    --disk0 size=10G \
    --memory 2048 \
    --cores 2 \
    --net0 name=eth0,bridge=vmbr0,gw=$GATEWAY,ip=$CT_IP/24,type=veth \
    --nameserver 1.1.1.1 \
    --ostype debian \
    --onboot 1 \
    --features nesting=1,keyctl=1 \
    --unprivileged 0

echo "Container created. Starting..."
pct start $CT_ID
sleep 10

echo "Installing Docker..."
pct exec $CT_ID -- bash -c "
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker root
    systemctl enable docker
"

echo "========================================="
echo "Docker Host deployed successfully!"
echo "  SSH: ssh root@$CT_IP"
echo "========================================="