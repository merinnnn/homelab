#!/bin/bash
# Network Bridge Setup: vmbr0 (Main) & vmbr1 (Isolated Test)
set -euo pipefail

PROXMOX_IP="${PROXMOX_IP:-192.168.1.50}"
GATEWAY="${GATEWAY:-192.168.1.1}"

echo "Proxmox Network Setup"

# Auto-detect physical interface connected to gateway
PHYSICAL_IF=$(ip route | grep "$GATEWAY" | awk '{print $3}' | head -1)
if [[ -z "$PHYSICAL_IF" ]]; then
    PHYSICAL_IF=$(ip route | grep default | awk '{print $5}' | head -1)
fi

if [[ -z "$PHYSICAL_IF" ]]; then
    echo "ERROR: Could not detect physical interface."
    exit 1
fi
echo "Detected physical interface: $PHYSICAL_IF"

# Backup current config
cp /etc/network/interfaces "/etc/network/interfaces.backup.$(date +%Y%m%d)"

# Write modern configuration
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

iface $PHYSICAL_IF inet manual

# Main production network (Connected to TP-Link RE220)
auto vmbr0
iface vmbr0 inet static
    address $PROXMOX_IP/24
    gateway $GATEWAY
    bridge-ports $PHYSICAL_IF
    bridge-stp off
    bridge-fd 0

# Isolated test network (Internal only)
auto vmbr1
iface vmbr1 inet static
    address 10.0.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

echo "Network configuration written."
echo "REBOOT REQUIRED: sudo reboot"