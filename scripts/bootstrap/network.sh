#!/usr/bin/env bash
set -euo pipefail

# Lab configuration
LAB_BRIDGE="vmbr1"
LAB_ADDR="10.0.10.1/24"
LAB_IP="${LAB_ADDR%/*}"
LAB_NET="10.0.10.0/24"
DHCP_START="10.0.10.100"
DHCP_END="10.0.10.200"
DHCP_MASK="255.255.255.0"

# Discover existing management/uplink network
UPLINK="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
MAIN_NET="$(ip route show dev "$UPLINK" proto kernel scope link | awk 'NR==1 {print $1}')"

echo "Uplink:   $UPLINK"
echo "Main LAN: $MAIN_NET"
echo "Lab:      $LAB_NET via $LAB_BRIDGE"

# Create isolated bridge
if ! grep -q "^iface $LAB_BRIDGE " /etc/network/interfaces; then
    cp -a /etc/network/interfaces /etc/network/interfaces.pre-homelab

    cat >> /etc/network/interfaces <<EOF

auto $LAB_BRIDGE
iface $LAB_BRIDGE inet static
        address $LAB_ADDR
        bridge-ports none
        bridge-stp off
        bridge-fd 0
EOF

    ifup "$LAB_BRIDGE"
fi

# Enable IPv4 routing
cat > /etc/sysctl.d/99-homelab-routing.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl -w net.ipv4.ip_forward=1

# Runtime NAT and isolation; only the project-owned tables are replaced.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_BRIDGE="$LAB_BRIDGE" LAB_IP="$LAB_IP" LAB_NET="$LAB_NET" \
UPLINK="$UPLINK" MAIN_NET="$MAIN_NET" \
    bash "$SCRIPT_DIR/apply-lab-firewall.sh" --apply
echo "Boot firewall persistence requires reviewed integration; see docs/firewall.md."

# DHCP + DNS for lab
apt-get update
apt-get install -y dnsmasq

cat > /etc/dnsmasq.d/homelab.conf <<EOF
interface=$LAB_BRIDGE
bind-interfaces
dhcp-range=$DHCP_START,$DHCP_END,$DHCP_MASK,12h
dhcp-option=option:router,$LAB_IP
dhcp-option=option:dns-server,$LAB_IP
EOF

# Prefer IPv4 when IPv6 is unavailable
if ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf; then
    cp -an /etc/gai.conf /etc/gai.conf.pre-homelab
    printf '\n# Prefer IPv4 when both IPv4 and IPv6 are available\nprecedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
fi

dnsmasq --test
systemctl enable --now dnsmasq
systemctl restart dnsmasq

echo
echo "Network runtime setup complete; firewall persistence still requires reviewed integration."
echo "$LAB_BRIDGE: $LAB_ADDR"
echo "DHCP: $DHCP_START - $DHCP_END"
echo "Uplink: $UPLINK"
echo "Main LAN blocked from lab: $MAIN_NET"
