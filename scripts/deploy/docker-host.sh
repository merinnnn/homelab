#!/bin/bash
# Deploy Docker Host LXC Container on vmbr0
set -euo pipefail

CT_ID="${CT_ID:-101}"
CT_IP="${CT_IP:-192.168.1.54}"

echo "Deploying Docker Host (CT $CT_ID)"

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

pct create $CT_ID "local:vztmpl/$TEMPLATE" \
    --hostname docker-host \
    --password "ChangeMe123!" \
    --storage local \
    --disk0 size=10G \
    --memory 2048 \
    --cores 2 \
    --net0 name=eth0,bridge=vmbr0,gw=192.168.1.1,ip=$CT_IP/24,type=veth \
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
echo "  IP Address: $CT_IP"
echo "  SSH:        ssh root@$CT_IP"
echo "========================================="