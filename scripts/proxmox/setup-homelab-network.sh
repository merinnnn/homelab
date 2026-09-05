#!/bin/bash
set -e

HOMELAB_NETWORK="10.0.10.0/24"
HOMELAB_GATEWAY="10.0.10.1"
BRIDGE_NAME="vmbr1"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root."
   exit 1
fi

echo "Setting up homelab network..."

# Backup current configuration
cp /etc/network/interfaces "/etc/network/interfaces.backup.$(date +%Y%m%d_%H%M%S)"

# Add bridge configuration if it does not exist
if ! grep -q "auto $BRIDGE_NAME" /etc/network/interfaces; then
    cat >> /etc/network/interfaces << EOF

# Homelab internal network
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
        address $HOMELAB_GATEWAY/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up iptables -t nat -A POSTROUTING -s '$HOMELAB_NETWORK' -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s '$HOMELAB_NETWORK' -o vmbr0 -j MASQUERADE
EOF
fi

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

# Apply NAT rules
iptables -t nat -A POSTROUTING -s "$HOMELAB_NETWORK" -o vmbr0 -j MASQUERADE
iptables -A FORWARD -s "$HOMELAB_NETWORK" -j ACCEPT
iptables -A FORWARD -d "$HOMELAB_NETWORK" -j ACCEPT

# Save rules persistently
if ! dpkg -l | grep -q iptables-persistent; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
fi
iptables-save > /etc/iptables/rules.v4

# Restart networking to apply
systemctl restart networking

echo "Network setup complete."


# Display summary
sleep 5

echo ""
echo "Homelab Network Setup Complete!"
echo ""
echo "Network Configuration Summary:"
echo "  Bridge Name: $BRIDGE_NAME"
echo "  Network Range: $HOMELAB_NETWORK"
echo "  Gateway IP: $HOMELAB_GATEWAY"
echo "  Internet Access: Enabled via NAT"
echo ""
echo "Next Steps:"
echo "1. Create VMs using $BRIDGE_NAME as network interface"
echo "2. Assign static IPs in range 10.0.10.10-10.0.10.250"
echo "3. Use $HOMELAB_GATEWAY as gateway in VM network config"
echo "4. Use 8.8.8.8,1.1.1.1 as DNS servers in VMs"
echo ""
echo "VM Network Configuration Example:"
echo "  IP: 10.0.10.10 (for Pi-hole)"
echo "  Netmask: 255.255.255.0 (/24)"
echo "  Gateway: $HOMELAB_GATEWAY"
echo "  DNS: 8.8.8.8,1.1.1.1"

