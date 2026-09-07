#!/bin/bash
# NAT Setup for Isolated Test Network (vmbr1) using nftables
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root."
   exit 1
fi

echo "Setting up NAT for vmbr1"

# Determine external interface (default to vmbr0, but allow override)
EXT_IFACE="${EXT_IFACE:-vmbr0}"

# Validate that the external interface actually exists
if ! ip link show "$EXT_IFACE" &>/dev/null; then
    echo "ERROR: External interface '$EXT_IFACE' does not exist."
    echo "Please set the EXT_IFACE environment variable to your main network bridge."
    echo "Example: sudo EXT_IFACE=vmbr0 bash $0"
    exit 1
fi

# Enable IP forwarding permanently
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null

# Configure nftables safely (check if rules already exist to allow re-runs)
if ! nft list tables | grep -q "ip nat"; then
    nft add table ip nat
fi

if ! nft list chain ip nat postrouting &>/dev/null; then
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
fi

if ! nft list ruleset | grep -q "oifname \"$EXT_IFACE\" ip saddr 10.0.10.0/24 masquerade"; then
    nft add rule ip nat postrouting oifname "$EXT_IFACE" ip saddr 10.0.10.0/24 masquerade
    echo "Added NAT masquerade rule for 10.0.10.0/24 via $EXT_IFACE"
else
    echo "NAT masquerade rule already exists."
fi

# Save rules persistently
cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "$EXT_IFACE" ip saddr 10.0.10.0/24 masquerade
    }
}
EOF

systemctl enable --now nftables
echo "NAT configured and saved."