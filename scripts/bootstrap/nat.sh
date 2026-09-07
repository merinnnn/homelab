#!/bin/bash
# NAT Setup for Isolated Test Network (vmbr1) using nftables
set -euo pipefail

echo "Setting up NAT for vmbr1"

# Enable IP forwarding permanently
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

# Configure nftables
nft add table ip nat
nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
nft add rule ip nat postrouting oifname "vmbr0" ip saddr 10.0.10.0/24 masquerade

# Save rules persistently
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset
table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname "vmbr0" ip saddr 10.0.10.0/24 masquerade
    }
}
EOF

systemctl enable --now nftables
echo "NAT configured: 10.0.10.0/24 can reach internet via vmbr0"