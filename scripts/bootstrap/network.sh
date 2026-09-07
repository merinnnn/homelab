#!/bin/bash
# Network Bridge Setup: vmbr0 (Main) & vmbr1 (Isolated Test)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root."
   exit 1
fi

echo "Proxmox Network Setup"

# 1. Always backup first
BACKUP_FILE="/etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/network/interfaces "$BACKUP_FILE"
echo "Backed up current network config to $BACKUP_FILE"

# 2. Check if vmbr0 already exists
if grep -q "auto vmbr0" /etc/network/interfaces; then
    echo "vmbr0 already exists. Preserving your existing configuration."
else
    echo "vmbr0 not found. Attempting to auto-detect current network settings..."
    
    # Detect current default route
    DEFAULT_ROUTE=$(ip route show default || true)
    if [[ -z "$DEFAULT_ROUTE" ]]; then
        echo "ERROR: Could not detect default route. Please configure network manually."
        exit 1
    fi
    
    CURRENT_GATEWAY=$(echo "$DEFAULT_ROUTE" | awk '{print $3}')
    CURRENT_IFACE=$(echo "$DEFAULT_ROUTE" | awk '{print $5}')
    CURRENT_CIDR=$(ip -4 addr show "$CURRENT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n 1)
    
    if [[ -z "$CURRENT_GATEWAY" || -z "$CURRENT_IFACE" || -z "$CURRENT_CIDR" ]]; then
        echo "ERROR: Could not auto-detect network settings."
        echo "Please run with explicit variables: sudo PROXMOX_IP=x.x.x.x/24 GATEWAY=x.x.x.x PHYSICAL_IFACE=eth0 bash $0"
        exit 1
    fi
    
    # Allow explicit override via environment variables
    if [[ -n "${PROXMOX_IP:-}" && -n "${GATEWAY:-}" && -n "${PHYSICAL_IFACE:-}" ]]; then
        echo "Using provided environment variables for migration."
        TARGET_IFACE="$PHYSICAL_IFACE"
        TARGET_IP="$PROXMOX_IP"
        TARGET_GW="$GATEWAY"
    else
        echo ""
        echo "WARNING: The script will migrate your current detected configuration:"
        echo "  Interface: $CURRENT_IFACE"
        echo "  IP/CIDR:   $CURRENT_CIDR"
        echo "  Gateway:   $CURRENT_GATEWAY"
        echo ""
        echo "This will rewrite /etc/network/interfaces."
        echo "To run non-interactively, set PROXMOX_IP, GATEWAY, and PHYSICAL_IFACE."
        echo ""
        read -p "Proceed with migration? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        TARGET_IFACE="$CURRENT_IFACE"
        TARGET_IP="$CURRENT_CIDR"
        TARGET_GW="$CURRENT_GATEWAY"
    fi

    # Write the new configuration
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

iface $TARGET_IFACE inet manual

# Main production network
auto vmbr0
iface vmbr0 inet static
    address $TARGET_IP
    gateway $TARGET_GW
    bridge-ports $TARGET_IFACE
    bridge-stp off
    bridge-fd 0
EOF
    echo "vmbr0 configured."
fi

# 3. Add vmbr1 if it doesn't exist
if grep -q "auto vmbr1" /etc/network/interfaces; then
    echo "vmbr1 already exists. Preserving existing configuration."
else
    echo "Adding vmbr1 (isolated test network)..."
    cat >> /etc/network/interfaces << EOF

# Isolated test network
auto vmbr1
iface vmbr1 inet static
    address 10.0.10.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    echo "vmbr1 configured."
fi

echo ""
echo "========================================="
echo "Network configuration updated."
echo "A reboot is REQUIRED for changes to take effect."
echo "Backup saved at: $BACKUP_FILE"
echo "========================================="